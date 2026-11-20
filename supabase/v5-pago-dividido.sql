-- DL COMANDA PRO v1.5 — Pago dividido y mixto
-- Un cobro puede tener varios pagos: por persona, partes iguales o mezcla de efectivo / tarjeta / transferencia.

create table if not exists public.cobro_pagos (
  id         bigint generated always as identity primary key,
  cobro_id   uuid not null references public.cobros(id) on delete cascade,
  empresa_id uuid not null references public.empresas(id) on delete cascade,
  metodo     text not null check (metodo in ('efectivo', 'tarjeta', 'transferencia')),
  monto      integer not null check (monto > 0),
  recibido   integer,
  persona    text,
  creado     timestamptz not null default now()
);
create index if not exists cobro_pagos_cobro_idx on public.cobro_pagos (cobro_id);
create index if not exists cobro_pagos_empresa_idx on public.cobro_pagos (empresa_id);
alter table public.cobro_pagos enable row level security;
drop policy if exists cpa_sel on public.cobro_pagos;
create policy cpa_sel on public.cobro_pagos for select to authenticated
  using (empresa_id = (select mi_empresa()) and (select mi_rol()) in ('dueno', 'cocina'));
revoke insert, update, delete on public.cobro_pagos from anon, authenticated;

alter table public.cobros drop constraint if exists cobros_metodo_check;
alter table public.cobros add constraint cobros_metodo_check check (metodo in ('efectivo', 'tarjeta', 'transferencia', 'mixto'));
alter table public.cobros add column if not exists dividido text;   -- null | 'iguales' | 'productos' | 'mixto'

-- los cobros que ya existían quedan con un solo pago
insert into public.cobro_pagos (cobro_id, empresa_id, metodo, monto, recibido, creado)
select c.id, c.empresa_id, c.metodo, c.total, c.recibido, c.creado from public.cobros c
where c.total > 0 and c.metodo <> 'mixto' and not exists (select 1 from public.cobro_pagos p where p.cobro_id = c.id);

drop function if exists public.cobrar_mesa(uuid, text, integer, integer, integer);
create or replace function public.cobrar_mesa(p_mesa uuid, p_metodo text, p_propina integer default 0,
                                              p_descuento integer default 0, p_recibido integer default null,
                                              p_pagos jsonb default null, p_dividido text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_emp uuid := mi_empresa(); v_rol text := mi_rol(); v_sub integer; v_n integer; v_tot integer;
        v_cid uuid; v_quien text; v_mesa text; x jsonb; v_sum integer := 0; v_mets text[] := '{}'; v_met text;
        v_m integer; v_r integer;
begin
  if v_emp is null then raise exception 'Sesión no válida'; end if;
  if v_rol not in ('cocina', 'dueno') then raise exception 'Solo caja o el dueño pueden cobrar'; end if;
  perform 1 from mesas where id = p_mesa and empresa_id = v_emp for update;
  select coalesce(sum(total), 0), count(*), max(mesa) into v_sub, v_n, v_mesa from pedidos
  where empresa_id = v_emp and mesa_id = p_mesa and not pagado and estado <> 'cancelado';
  if v_n = 0 then raise exception 'Esa mesa no tiene nada por cobrar'; end if;
  p_propina := greatest(coalesce(p_propina, 0), 0);
  p_descuento := greatest(coalesce(p_descuento, 0), 0);
  if p_descuento > v_sub then raise exception 'El descuento no puede ser mayor que la cuenta'; end if;
  if p_propina > v_sub then raise exception 'Revisa la propina'; end if;
  v_tot := v_sub - p_descuento + p_propina;

  -- pagos: si no vienen, es un solo pago con p_metodo
  if p_pagos is null or jsonb_typeof(p_pagos) <> 'array' or jsonb_array_length(p_pagos) = 0 then
    if p_metodo not in ('efectivo', 'tarjeta', 'transferencia') then raise exception 'Medio de pago no válido'; end if;
    if p_metodo = 'efectivo' and p_recibido is not null and p_recibido < v_tot then raise exception 'El efectivo recibido no alcanza'; end if;
    p_pagos := jsonb_build_array(jsonb_build_object('metodo', p_metodo, 'monto', v_tot,
                 'recibido', case when p_metodo = 'efectivo' then p_recibido end));
  end if;
  if jsonb_array_length(p_pagos) > 30 then raise exception 'Demasiados pagos'; end if;
  for x in select * from jsonb_array_elements(p_pagos) loop
    v_met := x->>'metodo'; v_m := coalesce((x->>'monto')::integer, 0); v_r := (x->>'recibido')::integer;
    if v_met not in ('efectivo', 'tarjeta', 'transferencia') then raise exception 'Medio de pago no válido'; end if;
    if v_m <= 0 then raise exception 'Hay un pago en cero'; end if;
    if v_r is not null and v_r < v_m then raise exception 'El efectivo recibido no alcanza en uno de los pagos'; end if;
    v_sum := v_sum + v_m;
    if not v_met = any(v_mets) then v_mets := v_mets || v_met; end if;
  end loop;
  if v_sum <> v_tot then raise exception 'Los pagos suman % y la cuenta es %', v_sum, v_tot; end if;

  select coalesce(c.usuario, 'Dueño') into v_quien from perfiles z left join personal c on c.id = z.personal_id where z.user_id = auth.uid();
  insert into cobros (empresa_id, fecha, mesa_id, mesa, subtotal, descuento, propina, total, metodo, recibido, cajero, pedidos, dividido)
  values (v_emp, hoy(), p_mesa, v_mesa, v_sub, p_descuento, p_propina, v_tot,
          case when array_length(v_mets, 1) = 1 then v_mets[1] else 'mixto' end,
          case when jsonb_array_length(p_pagos) = 1 then (p_pagos->0->>'recibido')::integer end,
          v_quien, v_n,
          case when jsonb_array_length(p_pagos) > 1 then coalesce(nullif(p_dividido, ''), 'mixto') end)
  returning id into v_cid;
  insert into cobro_pagos (cobro_id, empresa_id, metodo, monto, recibido, persona)
  select v_cid, v_emp, e->>'metodo', (e->>'monto')::integer, (e->>'recibido')::integer, nullif(left(btrim(coalesce(e->>'persona', '')), 40), '')
  from jsonb_array_elements(p_pagos) e;

  update pedidos set pagado = true, metodo = case when array_length(v_mets, 1) = 1 then v_mets[1] else 'mixto' end,
    pagado_en = now(), actualizado = now(), cobro_id = v_cid,
    estado = case when estado in ('nuevo', 'preparando', 'listo') then 'entregado' else estado end,
    entregado_en = coalesce(entregado_en, now())
  where empresa_id = v_emp and mesa_id = p_mesa and not pagado and estado <> 'cancelado';
  return jsonb_build_object('ok', true, 'id', v_cid, 'subtotal', v_sub, 'descuento', p_descuento, 'propina', p_propina,
                            'total', v_tot, 'pedidos', v_n, 'pagos', jsonb_array_length(p_pagos));
end $$;

revoke execute on function public.cobrar_mesa(uuid, text, integer, integer, integer, jsonb, text) from public, anon;
grant execute on function public.cobrar_mesa(uuid, text, integer, integer, integer, jsonb, text) to authenticated;
