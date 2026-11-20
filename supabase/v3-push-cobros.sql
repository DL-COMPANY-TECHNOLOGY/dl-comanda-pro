-- DL COMANDA PRO v1.3 — Avisos con la app cerrada (Web Push), cobros con propina/descuento y cambio de mesa
create extension if not exists pg_net with schema extensions;

-- ---------------------------------------------------------------------
-- Configuración privada (solo la lee el servidor; nadie desde la app)
-- ---------------------------------------------------------------------
create table if not exists public.config_privada (clave text primary key, valor text not null);
alter table public.config_privada enable row level security;
revoke all on public.config_privada from anon, authenticated;
insert into public.config_privada (clave, valor) values
  ('hook_secret', encode(extensions.gen_random_bytes(24), 'hex')),
  ('push_url', 'https://bezuvyjchyyloatnwrad.supabase.co/functions/v1/comanda-push')
on conflict (clave) do nothing;

-- ---------------------------------------------------------------------
-- Suscripciones push (un registro por celular)
-- ---------------------------------------------------------------------
create table if not exists public.push_subs (
  id          bigint generated always as identity primary key,
  empresa_id  uuid not null references public.empresas(id) on delete cascade,
  user_id     uuid not null references auth.users(id) on delete cascade,
  personal_id uuid references public.personal(id) on delete cascade,
  rol         text not null,
  endpoint    text not null unique,
  p256dh      text not null,
  auth        text not null,
  actualizado timestamptz not null default now()
);
create index if not exists push_subs_empresa_idx on public.push_subs (empresa_id, rol);
create index if not exists push_subs_personal_idx on public.push_subs (personal_id);
create index if not exists push_subs_user_idx on public.push_subs (user_id);
alter table public.push_subs enable row level security;
revoke all on public.push_subs from anon, authenticated;

create or replace function public.guardar_push(p_endpoint text, p_p256dh text, p_auth text)
returns void language plpgsql security definer set search_path = public as $$
declare v_emp uuid := mi_empresa(); v_rol text := mi_rol(); v_per uuid;
begin
  if v_emp is null then raise exception 'Sesión no válida'; end if;
  if coalesce(p_endpoint, '') !~ '^https://' or length(p_endpoint) > 1000 then raise exception 'Suscripción no válida'; end if;
  select personal_id into v_per from perfiles where user_id = auth.uid();
  insert into push_subs (empresa_id, user_id, personal_id, rol, endpoint, p256dh, auth)
  values (v_emp, auth.uid(), v_per, v_rol, p_endpoint, left(p_p256dh, 200), left(p_auth, 100))
  on conflict (endpoint) do update set empresa_id = excluded.empresa_id, user_id = excluded.user_id,
    personal_id = excluded.personal_id, rol = excluded.rol, p256dh = excluded.p256dh, auth = excluded.auth, actualizado = now();
end $$;

create or replace function public.borrar_push(p_endpoint text)
returns void language sql security definer set search_path = public as $$
  delete from push_subs where endpoint = p_endpoint and user_id = auth.uid();
$$;

-- Al cambiar PIN, desactivar o eliminar a alguien, sus celulares dejan de recibir avisos
create or replace function public.limpiar_push_perfil() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  delete from push_subs where user_id = old.user_id;
  return old;
end $$;
drop trigger if exists limpiar_push_perfil on public.perfiles;
create trigger limpiar_push_perfil after delete on public.perfiles
  for each row execute function public.limpiar_push_perfil();

-- ---------------------------------------------------------------------
-- Disparador: nuevo pedido → cocina; listo / cancelado → mesero
-- ---------------------------------------------------------------------
create or replace function public.avisar_push() returns trigger
language plpgsql security definer set search_path = public, extensions as $$
declare v_tipo text; v_url text; v_sec text;
begin
  if tg_op = 'INSERT' then v_tipo := 'nuevo';
  elsif new.estado is distinct from old.estado and new.estado = 'listo' then v_tipo := 'listo';
  elsif new.estado is distinct from old.estado and new.estado = 'cancelado' and old.estado <> 'nuevo' then v_tipo := 'cancelado';
  else return new;
  end if;
  if not exists (select 1 from push_subs where empresa_id = new.empresa_id) then return new; end if;
  select valor into v_url from config_privada where clave = 'push_url';
  select valor into v_sec from config_privada where clave = 'hook_secret';
  if v_url is null or v_sec is null then return new; end if;
  perform net.http_post(
    url := v_url,
    body := jsonb_build_object('tipo', v_tipo, 'pedido_id', new.id),
    headers := jsonb_build_object('Content-Type', 'application/json', 'x-hook-secret', v_sec),
    timeout_milliseconds := 8000);
  return new;
exception when others then
  return new;   -- un aviso fallido nunca debe impedir guardar el pedido
end $$;
drop trigger if exists avisar_push on public.pedidos;
create trigger avisar_push after insert or update of estado on public.pedidos
  for each row execute function public.avisar_push();

-- ---------------------------------------------------------------------
-- Cobros: propina voluntaria, descuento, efectivo recibido
-- ---------------------------------------------------------------------
create table if not exists public.cobros (
  id         uuid primary key default gen_random_uuid(),
  empresa_id uuid not null references public.empresas(id) on delete cascade,
  fecha      date not null,
  mesa_id    uuid references public.mesas(id) on delete set null,
  mesa       text not null,
  subtotal   integer not null,
  descuento  integer not null default 0,
  propina    integer not null default 0,
  total      integer not null,
  metodo     text not null check (metodo in ('efectivo', 'tarjeta', 'transferencia')),
  recibido   integer,
  cajero     text not null,
  pedidos    integer not null,
  creado     timestamptz not null default now()
);
create index if not exists cobros_empresa_fecha_idx on public.cobros (empresa_id, fecha);
create index if not exists cobros_mesa_idx on public.cobros (mesa_id);
alter table public.cobros enable row level security;
drop policy if exists cob_sel on public.cobros;
create policy cob_sel on public.cobros for select to authenticated
  using (empresa_id = (select mi_empresa()) and (select mi_rol()) in ('dueno', 'cocina'));
revoke insert, update, delete on public.cobros from anon, authenticated;

alter table public.pedidos add column if not exists cobro_id uuid references public.cobros(id) on delete set null;
create index if not exists pedidos_cobro_idx on public.pedidos (cobro_id);

drop function if exists public.cobrar_mesa(uuid, text);
create or replace function public.cobrar_mesa(p_mesa uuid, p_metodo text, p_propina integer default 0,
                                              p_descuento integer default 0, p_recibido integer default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_emp uuid := mi_empresa(); v_rol text := mi_rol(); v_sub integer; v_n integer; v_tot integer;
        v_cid uuid; v_quien text; v_mesa text;
begin
  if v_emp is null then raise exception 'Sesión no válida'; end if;
  if v_rol not in ('cocina', 'dueno') then raise exception 'Solo caja o el dueño pueden cobrar'; end if;
  if p_metodo not in ('efectivo', 'tarjeta', 'transferencia') then raise exception 'Medio de pago no válido'; end if;
  perform 1 from mesas where id = p_mesa and empresa_id = v_emp for update;
  select coalesce(sum(total), 0), count(*), max(mesa) into v_sub, v_n, v_mesa from pedidos
  where empresa_id = v_emp and mesa_id = p_mesa and not pagado and estado <> 'cancelado';
  if v_n = 0 then raise exception 'Esa mesa no tiene nada por cobrar'; end if;
  p_propina := greatest(coalesce(p_propina, 0), 0);
  p_descuento := greatest(coalesce(p_descuento, 0), 0);
  if p_descuento > v_sub then raise exception 'El descuento no puede ser mayor que la cuenta'; end if;
  if p_propina > v_sub then raise exception 'Revisa la propina'; end if;
  v_tot := v_sub - p_descuento + p_propina;
  if p_metodo = 'efectivo' and p_recibido is not null and p_recibido < v_tot then raise exception 'El efectivo recibido no alcanza'; end if;
  select coalesce(c.usuario, 'Dueño') into v_quien from perfiles x left join personal c on c.id = x.personal_id where x.user_id = auth.uid();
  insert into cobros (empresa_id, fecha, mesa_id, mesa, subtotal, descuento, propina, total, metodo, recibido, cajero, pedidos)
  values (v_emp, hoy(), p_mesa, v_mesa, v_sub, p_descuento, p_propina, v_tot, p_metodo,
          case when p_metodo = 'efectivo' then p_recibido end, v_quien, v_n)
  returning id into v_cid;
  update pedidos set pagado = true, metodo = p_metodo, pagado_en = now(), actualizado = now(), cobro_id = v_cid,
    estado = case when estado in ('nuevo', 'preparando', 'listo') then 'entregado' else estado end,
    entregado_en = coalesce(entregado_en, now())
  where empresa_id = v_emp and mesa_id = p_mesa and not pagado and estado <> 'cancelado';
  return jsonb_build_object('ok', true, 'id', v_cid, 'subtotal', v_sub, 'descuento', p_descuento, 'propina', p_propina,
                            'total', v_tot, 'pedidos', v_n, 'vueltas', case when p_recibido is not null then p_recibido - v_tot end);
end $$;

-- ---------------------------------------------------------------------
-- Cambiar de mesa / juntar mesas (cualquier rol)
-- ---------------------------------------------------------------------
create or replace function public.mover_mesa(p_origen uuid, p_destino uuid)
returns integer language plpgsql security definer set search_path = public as $$
declare v_emp uuid := mi_empresa(); d mesas; n integer;
begin
  if v_emp is null then raise exception 'Sesión no válida'; end if;
  if p_origen = p_destino then raise exception 'Escoge otra mesa'; end if;
  select * into d from mesas where id = p_destino and empresa_id = v_emp and activa;
  if not found then raise exception 'Mesa de destino no válida'; end if;
  update pedidos set mesa_id = d.id, mesa = d.nombre, actualizado = now()
  where empresa_id = v_emp and mesa_id = p_origen and not pagado and estado <> 'cancelado';
  get diagnostics n = row_count;
  if n = 0 then raise exception 'Esa mesa no tiene pedidos abiertos'; end if;
  return n;
end $$;

-- ---------------------------------------------------------------------
-- Permisos y tiempo real
-- ---------------------------------------------------------------------
revoke execute on function public.guardar_push(text, text, text) from public, anon;
revoke execute on function public.borrar_push(text) from public, anon;
revoke execute on function public.cobrar_mesa(uuid, text, integer, integer, integer) from public, anon;
revoke execute on function public.mover_mesa(uuid, uuid) from public, anon;
revoke execute on function public.avisar_push() from public, anon, authenticated;
revoke execute on function public.limpiar_push_perfil() from public, anon, authenticated;
grant execute on function public.guardar_push(text, text, text) to authenticated;
grant execute on function public.borrar_push(text) to authenticated;
grant execute on function public.cobrar_mesa(uuid, text, integer, integer, integer) to authenticated;
grant execute on function public.mover_mesa(uuid, uuid) to authenticated;
do $$ begin
  begin alter publication supabase_realtime add table public.cobros; exception when duplicate_object then null; end;
end $$;
