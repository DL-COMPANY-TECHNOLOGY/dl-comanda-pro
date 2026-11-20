-- DL COMANDA PRO v1.7 — Caja: apertura con base, entradas/salidas de efectivo y cierre con arqueo

create table if not exists public.cajas (
  id            uuid primary key default gen_random_uuid(),
  empresa_id    uuid not null references public.empresas(id) on delete cascade,
  estado        text not null default 'abierta' check (estado in ('abierta', 'cerrada')),
  base          integer not null default 0 check (base >= 0),
  abierta_por   text not null,
  abierta_en    timestamptz not null default now(),
  cerrada_por   text,
  cerrada_en    timestamptz,
  efectivo      integer,   -- ventas en efectivo
  tarjeta       integer,
  transferencia integer,
  entradas      integer,
  salidas       integer,
  propinas      integer,
  descuentos    integer,
  cobros        integer,
  esperado      integer,   -- base + efectivo + entradas - salidas
  contado       integer,
  diferencia    integer,   -- contado - esperado (negativo = faltante)
  conteo        jsonb,     -- billetes y monedas contados
  nota          text
);
create unique index if not exists cajas_una_abierta on public.cajas (empresa_id) where estado = 'abierta';
create index if not exists cajas_empresa_idx on public.cajas (empresa_id, abierta_en desc);

create table if not exists public.caja_movs (
  id         bigint generated always as identity primary key,
  caja_id    uuid not null references public.cajas(id) on delete cascade,
  empresa_id uuid not null references public.empresas(id) on delete cascade,
  tipo       text not null check (tipo in ('entrada', 'salida')),
  monto      integer not null check (monto > 0),
  motivo     text not null,
  por        text not null,
  creado     timestamptz not null default now()
);
create index if not exists caja_movs_caja_idx on public.caja_movs (caja_id);
create index if not exists caja_movs_empresa_idx on public.caja_movs (empresa_id);

alter table public.cobros add column if not exists caja_id uuid references public.cajas(id) on delete set null;
create index if not exists cobros_caja_idx on public.cobros (caja_id);

alter table public.cajas enable row level security;
alter table public.caja_movs enable row level security;
drop policy if exists caj_sel on public.cajas;
create policy caj_sel on public.cajas for select to authenticated
  using (empresa_id = (select mi_empresa()) and (select mi_rol()) in ('dueno', 'cocina'));
drop policy if exists cmv_sel on public.caja_movs;
create policy cmv_sel on public.caja_movs for select to authenticated
  using (empresa_id = (select mi_empresa()) and (select mi_rol()) in ('dueno', 'cocina'));
revoke insert, update, delete on public.cajas, public.caja_movs from anon, authenticated;

-- cada cobro queda en la caja abierta en ese momento
create or replace function public.cobro_a_caja() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.caja_id is null then
    select id into new.caja_id from cajas where empresa_id = new.empresa_id and estado = 'abierta';
  end if;
  return new;
end $$;
drop trigger if exists cobro_a_caja on public.cobros;
create trigger cobro_a_caja before insert on public.cobros for each row execute function public.cobro_a_caja();

create or replace function public.quien_soy() returns text
language sql stable security definer set search_path = public as $$
  select coalesce(c.usuario, 'Dueño') from perfiles x left join personal c on c.id = x.personal_id where x.user_id = auth.uid()
$$;

create or replace function public.abrir_caja(p_base integer)
returns uuid language plpgsql security definer set search_path = public as $$
declare v_emp uuid := mi_empresa(); v_id uuid;
begin
  if v_emp is null or mi_rol() not in ('dueno', 'cocina') then raise exception 'Solo caja o el dueño pueden abrir la caja'; end if;
  if exists (select 1 from cajas where empresa_id = v_emp and estado = 'abierta') then raise exception 'Ya hay una caja abierta'; end if;
  insert into cajas (empresa_id, base, abierta_por) values (v_emp, greatest(coalesce(p_base, 0), 0), quien_soy()) returning id into v_id;
  return v_id;
end $$;

create or replace function public.mov_caja(p_tipo text, p_monto integer, p_motivo text)
returns void language plpgsql security definer set search_path = public as $$
declare v_emp uuid := mi_empresa(); v_caja uuid;
begin
  if v_emp is null or mi_rol() not in ('dueno', 'cocina') then raise exception 'Solo caja o el dueño'; end if;
  if p_tipo not in ('entrada', 'salida') then raise exception 'Tipo no válido'; end if;
  if coalesce(p_monto, 0) <= 0 then raise exception 'Escribe el valor'; end if;
  if length(btrim(coalesce(p_motivo, ''))) < 3 then raise exception 'Escribe el motivo'; end if;
  select id into v_caja from cajas where empresa_id = v_emp and estado = 'abierta';
  if v_caja is null then raise exception 'Primero abre la caja'; end if;
  insert into caja_movs (caja_id, empresa_id, tipo, monto, motivo, por) values (v_caja, v_emp, p_tipo, p_monto, left(btrim(p_motivo), 120), quien_soy());
end $$;

-- resumen de una caja (abierta o cerrada) calculado en el servidor
create or replace function public.resumen_caja(p_caja uuid)
returns jsonb language sql stable security definer set search_path = public as $$
  with c as (select * from cajas where id = p_caja and empresa_id = mi_empresa()),
  pg as (select cp.metodo, sum(cp.monto)::integer m from cobro_pagos cp join cobros co on co.id = cp.cobro_id
         where co.caja_id = p_caja group by cp.metodo),
  co as (select count(*)::integer n, coalesce(sum(propina), 0)::integer prop, coalesce(sum(descuento), 0)::integer des from cobros where caja_id = p_caja),
  mv as (select coalesce(sum(monto) filter (where tipo = 'entrada'), 0)::integer ent, coalesce(sum(monto) filter (where tipo = 'salida'), 0)::integer sal from caja_movs where caja_id = p_caja)
  select jsonb_build_object(
    'base', c.base,
    'efectivo', coalesce((select m from pg where metodo = 'efectivo'), 0),
    'tarjeta', coalesce((select m from pg where metodo = 'tarjeta'), 0),
    'transferencia', coalesce((select m from pg where metodo = 'transferencia'), 0),
    'entradas', mv.ent, 'salidas', mv.sal, 'propinas', co.prop, 'descuentos', co.des, 'cobros', co.n,
    'esperado', c.base + coalesce((select m from pg where metodo = 'efectivo'), 0) + mv.ent - mv.sal)
  from c, co, mv
$$;

create or replace function public.cerrar_caja(p_contado integer, p_conteo jsonb default null, p_nota text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_emp uuid := mi_empresa(); v_caja uuid; r jsonb;
begin
  if v_emp is null or mi_rol() not in ('dueno', 'cocina') then raise exception 'Solo caja o el dueño pueden cerrar la caja'; end if;
  if p_contado is null or p_contado < 0 then raise exception 'Escribe el efectivo contado'; end if;
  select id into v_caja from cajas where empresa_id = v_emp and estado = 'abierta' for update;
  if v_caja is null then raise exception 'No hay caja abierta'; end if;
  r := resumen_caja(v_caja);
  update cajas set estado = 'cerrada', cerrada_por = quien_soy(), cerrada_en = now(),
    efectivo = (r->>'efectivo')::integer, tarjeta = (r->>'tarjeta')::integer, transferencia = (r->>'transferencia')::integer,
    entradas = (r->>'entradas')::integer, salidas = (r->>'salidas')::integer, propinas = (r->>'propinas')::integer,
    descuentos = (r->>'descuentos')::integer, cobros = (r->>'cobros')::integer, esperado = (r->>'esperado')::integer,
    contado = p_contado, diferencia = p_contado - (r->>'esperado')::integer,
    conteo = p_conteo, nota = nullif(left(btrim(coalesce(p_nota, '')), 300), '')
  where id = v_caja;
  return r || jsonb_build_object('id', v_caja, 'contado', p_contado, 'diferencia', p_contado - (r->>'esperado')::integer);
end $$;

revoke execute on function public.cobro_a_caja() from public, anon, authenticated;
revoke execute on function public.quien_soy() from public, anon;
revoke execute on function public.abrir_caja(integer) from public, anon;
revoke execute on function public.mov_caja(text, integer, text) from public, anon;
revoke execute on function public.resumen_caja(uuid) from public, anon;
revoke execute on function public.cerrar_caja(integer, jsonb, text) from public, anon;
grant execute on function public.quien_soy() to authenticated;
grant execute on function public.abrir_caja(integer) to authenticated;
grant execute on function public.mov_caja(text, integer, text) to authenticated;
grant execute on function public.resumen_caja(uuid) to authenticated;
grant execute on function public.cerrar_caja(integer, jsonb, text) to authenticated;
do $$ begin
  begin alter publication supabase_realtime add table public.cajas; exception when duplicate_object then null; end;
  begin alter publication supabase_realtime add table public.caja_movs; exception when duplicate_object then null; end;
end $$;
