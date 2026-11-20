-- DL COMANDA PRO v1.8 — Planes: Gratis, Pro y Premium
-- Los límites se aplican en el servidor (no se pueden saltar desde la app).
-- Cuentas nuevas: 14 días de Premium de prueba; al vencer pasan a Gratis.

alter table public.empresas add column if not exists plan_vence date;
alter table public.empresas add column if not exists plan_prueba boolean not null default false;

create or replace function public.plan_de(p_emp uuid) returns text
language sql stable security definer set search_path = public as $$
  select case when e.plan <> 'gratis' and e.plan_vence is not null and e.plan_vence < hoy() then 'gratis' else e.plan end
  from empresas e where e.id = p_emp
$$;

create or replace function public.plan_limites(p_plan text) returns jsonb
language sql immutable set search_path = public as $$
  select case p_plan
    when 'premium' then '{"mesas":null,"productos":null,"usuarios":null,"pedidos_dia":null,"historial":null,"push":true,"imprimir":true,"dividir":true,"caja":true,"excel":true,"mover":true,"estaciones":true,"stock":true,"soporte":true}'::jsonb
    when 'pro'     then '{"mesas":20,"productos":150,"usuarios":8,"pedidos_dia":null,"historial":90,"push":true,"imprimir":true,"dividir":true,"caja":true,"excel":true,"mover":true,"estaciones":false,"stock":false,"soporte":false}'::jsonb
    else                '{"mesas":5,"productos":20,"usuarios":2,"pedidos_dia":25,"historial":1,"push":false,"imprimir":false,"dividir":false,"caja":false,"excel":false,"mover":false,"estaciones":false,"stock":false,"soporte":false}'::jsonb
  end
$$;

create or replace function public.plan_feat(p_emp uuid, p_key text) returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((plan_limites(plan_de(p_emp))->>p_key)::boolean, false)
$$;
create or replace function public.plan_lim(p_emp uuid, p_key text) returns integer
language sql stable security definer set search_path = public as $$
  select (plan_limites(plan_de(p_emp))->>p_key)::integer
$$;

create or replace function public.nombre_plan(p text) returns text language sql immutable as $$
  select case p when 'premium' then 'Premium' when 'pro' then 'Pro' else 'Gratis' end
$$;

create or replace function public.mi_plan() returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'plan', plan_de(e.id), 'contratado', e.plan, 'vence', e.plan_vence, 'prueba', e.plan_prueba,
    'limites', plan_limites(plan_de(e.id)),
    'uso', jsonb_build_object(
      'mesas',     (select count(*) from mesas where empresa_id = e.id and activa),
      'productos', (select count(*) from productos where empresa_id = e.id and activo),
      'usuarios',  (select count(*) from personal where empresa_id = e.id and activo),
      'pedidos_hoy', (select count(*) from pedidos where empresa_id = e.id and fecha = hoy())))
  from empresas e where e.id = mi_empresa()
$$;

-- Prueba Premium de 14 días para cada cuenta nueva
create or replace function public.prueba_premium() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.plan = 'gratis' and new.plan_vence is null then
    new.plan := 'premium'; new.plan_vence := hoy() + 14; new.plan_prueba := true;
  end if;
  return new;
end $$;
drop trigger if exists prueba_premium on public.empresas;
create trigger prueba_premium before insert on public.empresas for each row execute function public.prueba_premium();

-- ------------------- límites -------------------
create or replace function public.lim_mesas() returns trigger
language plpgsql security definer set search_path = public as $$
declare l integer := plan_lim(new.empresa_id, 'mesas');
begin
  if new.activa and l is not null and (tg_op = 'INSERT' or not old.activa)
     and (select count(*) from mesas where empresa_id = new.empresa_id and activa and id <> new.id) >= l then
    raise exception 'PLAN: Tu plan % permite hasta % mesas. Mejora tu plan para agregar más.', nombre_plan(plan_de(new.empresa_id)), l;
  end if;
  return new;
end $$;
drop trigger if exists lim_mesas on public.mesas;
create trigger lim_mesas before insert or update of activa on public.mesas for each row execute function public.lim_mesas();

create or replace function public.lim_productos() returns trigger
language plpgsql security definer set search_path = public as $$
declare l integer := plan_lim(new.empresa_id, 'productos');
begin
  if new.activo and l is not null and (tg_op = 'INSERT' or not old.activo)
     and (select count(*) from productos where empresa_id = new.empresa_id and activo and id <> new.id) >= l then
    raise exception 'PLAN: Tu plan % permite hasta % productos en el menú. Mejora tu plan para agregar más.', nombre_plan(plan_de(new.empresa_id)), l;
  end if;
  if new.stock is not null and (tg_op = 'INSERT' or old.stock is null) and not plan_feat(new.empresa_id, 'stock') then
    raise exception 'PLAN: El control de stock es del plan Premium.';
  end if;
  return new;
end $$;
drop trigger if exists lim_productos on public.productos;
create trigger lim_productos before insert or update of activo, stock on public.productos for each row execute function public.lim_productos();

create or replace function public.lim_personal() returns trigger
language plpgsql security definer set search_path = public as $$
declare l integer := plan_lim(new.empresa_id, 'usuarios');
begin
  if new.activo and l is not null and (tg_op = 'INSERT' or not old.activo)
     and (select count(*) from personal where empresa_id = new.empresa_id and activo and id <> new.id) >= l then
    raise exception 'PLAN: Tu plan % permite hasta % usuarios de personal. Mejora tu plan para agregar más.', nombre_plan(plan_de(new.empresa_id)), l;
  end if;
  return new;
end $$;
drop trigger if exists lim_personal on public.personal;
create trigger lim_personal before insert or update of activo on public.personal for each row execute function public.lim_personal();

-- al pasar a un plan menor: solo las primeras mesas / usuarios dentro del límite siguen funcionando
create or replace function public.dentro_del_plan(p_emp uuid, p_tipo text, p_id uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select case p_tipo
    when 'mesa' then plan_lim(p_emp, 'mesas') is null or (select rk from (select id, row_number() over (order by orden, creado) rk from mesas where empresa_id = p_emp and activa) x where id = p_id) <= plan_lim(p_emp, 'mesas')
    when 'usuario' then plan_lim(p_emp, 'usuarios') is null or (select rk from (select id, row_number() over (order by creado) rk from personal where empresa_id = p_emp and activo) x where id = p_id) <= plan_lim(p_emp, 'usuarios')
    when 'producto' then plan_lim(p_emp, 'productos') is null or (select rk from (select id, row_number() over (order by categoria, orden, nombre) rk from productos where empresa_id = p_emp and activo) x where id = p_id) <= plan_lim(p_emp, 'productos')
  end
$$;

create or replace function public.lim_pedidos() returns trigger
language plpgsql security definer set search_path = public as $$
declare l integer := plan_lim(new.empresa_id, 'pedidos_dia');
begin
  if l is not null and (select count(*) from pedidos where empresa_id = new.empresa_id and fecha = new.fecha) >= l then
    raise exception 'PLAN: Llegaste a los % pedidos del día del plan Gratis. Mejora tu plan para pedidos ilimitados.', l;
  end if;
  if new.mesa_id is not null and not coalesce(dentro_del_plan(new.empresa_id, 'mesa', new.mesa_id), false) then
    raise exception 'PLAN: Esa mesa está fuera de tu plan %. Mejora tu plan para usar todas tus mesas.', nombre_plan(plan_de(new.empresa_id));
  end if;
  return new;
end $$;
drop trigger if exists lim_pedidos on public.pedidos;
create trigger lim_pedidos before insert on public.pedidos for each row execute function public.lim_pedidos();

create or replace function public.lim_items() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.producto_id is not null and not coalesce(dentro_del_plan(new.empresa_id, 'producto', new.producto_id), false) then
    raise exception 'PLAN: "%" está fuera de los productos de tu plan %. Mejora tu plan para usar todo tu menú.', new.nombre, nombre_plan(plan_de(new.empresa_id));
  end if;
  return new;
end $$;
drop trigger if exists lim_items on public.pedido_items;
create trigger lim_items before insert on public.pedido_items for each row execute function public.lim_items();

create or replace function public.lim_ingreso() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.personal_id is not null and not coalesce(dentro_del_plan(new.empresa_id, 'usuario', new.personal_id), false) then
    raise exception 'PLAN: Tu usuario está fuera del plan % del restaurante. Pídele al dueño que mejore el plan.', nombre_plan(plan_de(new.empresa_id));
  end if;
  return new;
end $$;
drop trigger if exists lim_ingreso on public.perfiles;
create trigger lim_ingreso before insert or update on public.perfiles for each row execute function public.lim_ingreso();

create or replace function public.lim_funcion() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if tg_table_name = 'push_subs' and not plan_feat(new.empresa_id, 'push') then
    raise exception 'PLAN: Los avisos con la app cerrada son del plan Pro o Premium.';
  elsif tg_table_name = 'cajas' and not plan_feat(new.empresa_id, 'caja') then
    raise exception 'PLAN: La caja con cierre y arqueo es del plan Pro o Premium.';
  elsif tg_table_name = 'cobros' and new.dividido is not null and not plan_feat(new.empresa_id, 'dividir') then
    raise exception 'PLAN: Dividir la cuenta y pagar con varios medios es del plan Pro o Premium.';
  elsif tg_table_name = 'empresas' and new.estaciones and not old.estaciones and not plan_feat(new.id, 'estaciones') then
    raise exception 'PLAN: Las estaciones cocina y bar son del plan Premium.';
  end if;
  return new;
end $$;
drop trigger if exists lim_funcion on public.push_subs;
create trigger lim_funcion before insert on public.push_subs for each row execute function public.lim_funcion();
drop trigger if exists lim_funcion on public.cajas;
create trigger lim_funcion before insert on public.cajas for each row execute function public.lim_funcion();
drop trigger if exists lim_funcion on public.cobros;
create trigger lim_funcion before insert on public.cobros for each row execute function public.lim_funcion();
drop trigger if exists lim_funcion on public.empresas;
create trigger lim_funcion before update of estaciones on public.empresas for each row execute function public.lim_funcion();

-- cambiar / juntar mesas: Pro o Premium
create or replace function public.lim_mover() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.mesa_id is distinct from old.mesa_id and not plan_feat(new.empresa_id, 'mover') then
    raise exception 'PLAN: Cambiar o juntar mesas es del plan Pro o Premium.';
  end if;
  return new;
end $$;
drop trigger if exists lim_mover on public.pedidos;
create trigger lim_mover before update of mesa_id on public.pedidos for each row execute function public.lim_mover();

-- al vencer un plan, se apagan las funciones que ya no incluye
create or replace function public.ajustar_plan(p_emp uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not plan_feat(p_emp, 'estaciones') then update empresas set estaciones = false where id = p_emp and estaciones; end if;
  if not plan_feat(p_emp, 'push') then delete from push_subs where empresa_id = p_emp; end if;
end $$;

-- la app lo llama al abrir: si el plan venció, apaga lo que ya no incluye
create or replace function public.revisar_plan() returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_emp uuid := mi_empresa();
begin
  if v_emp is null then return null; end if;
  perform ajustar_plan(v_emp);
  return mi_plan();
end $$;

-- ------------------- activar un plan (solo DL COMPANY, desde el SQL Editor de Supabase) -------------------
-- Ejemplo:  select activar_plan('900123456', 'pro', 1);   -- NIT, plan, meses
create or replace function public.activar_plan(p_nit text, p_plan text, p_meses integer default 1)
returns text language plpgsql security definer set search_path = public as $$
declare e empresas;
begin
  if p_plan not in ('gratis', 'pro', 'premium') then raise exception 'Plan no válido: gratis, pro o premium'; end if;
  select * into e from empresas where regexp_replace(nit, '[^0-9]', '', 'g') = regexp_replace(p_nit, '[^0-9]', '', 'g');
  if not found then raise exception 'No existe un restaurante con ese NIT'; end if;
  update empresas set plan = p_plan, plan_prueba = false,
    plan_vence = case when p_plan = 'gratis' then null
                      else greatest(coalesce(case when e.plan = p_plan and not e.plan_prueba then e.plan_vence end, hoy()), hoy()) + make_interval(months => greatest(coalesce(p_meses, 1), 1)) end
  where id = e.id;
  perform ajustar_plan(e.id);
  return format('%s → plan %s hasta %s', e.nombre, nombre_plan(p_plan), coalesce((select plan_vence::text from empresas where id = e.id), 'siempre'));
end $$;

-- permisos
revoke execute on function public.activar_plan(text, text, integer) from public, anon, authenticated;
revoke execute on function public.ajustar_plan(uuid) from public, anon, authenticated;
revoke execute on function public.prueba_premium() from public, anon, authenticated;
revoke execute on function public.lim_mesas() from public, anon, authenticated;
revoke execute on function public.lim_productos() from public, anon, authenticated;
revoke execute on function public.lim_personal() from public, anon, authenticated;
revoke execute on function public.lim_pedidos() from public, anon, authenticated;
revoke execute on function public.lim_items() from public, anon, authenticated;
revoke execute on function public.lim_ingreso() from public, anon, authenticated;
revoke execute on function public.lim_funcion() from public, anon, authenticated;
revoke execute on function public.lim_mover() from public, anon, authenticated;
revoke execute on function public.dentro_del_plan(uuid, text, uuid) from public, anon;
revoke execute on function public.plan_de(uuid) from public, anon;
revoke execute on function public.plan_feat(uuid, text) from public, anon;
revoke execute on function public.plan_lim(uuid, text) from public, anon;
revoke execute on function public.mi_plan() from public, anon;
revoke execute on function public.revisar_plan() from public, anon;
grant execute on function public.mi_plan() to authenticated;
grant execute on function public.revisar_plan() to authenticated;
grant execute on function public.dentro_del_plan(uuid, text, uuid) to authenticated;

-- el restaurante del dueño de DL COMPANY queda en Premium sin vencimiento
update public.empresas set plan = 'premium', plan_vence = null, plan_prueba = false where nombre = 'Asadero Dimelo Lenin';

-- v8b: una validación por tabla (evita errores de campos que no existen en otras tablas)
create or replace function public.lim_push() returns trigger language plpgsql security definer set search_path = public as $$
begin
  if not plan_feat(new.empresa_id, 'push') then raise exception 'PLAN: Los avisos con la app cerrada son del plan Pro o Premium.'; end if;
  return new;
end $$;
create or replace function public.lim_caja() returns trigger language plpgsql security definer set search_path = public as $$
begin
  if not plan_feat(new.empresa_id, 'caja') then raise exception 'PLAN: La caja con cierre y arqueo es del plan Pro o Premium.'; end if;
  return new;
end $$;
create or replace function public.lim_dividir() returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.dividido is not null and not plan_feat(new.empresa_id, 'dividir') then raise exception 'PLAN: Dividir la cuenta y pagar con varios medios es del plan Pro o Premium.'; end if;
  return new;
end $$;
create or replace function public.lim_estaciones() returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.estaciones and not old.estaciones and not plan_feat(new.id, 'estaciones') then raise exception 'PLAN: Las estaciones cocina y bar son del plan Premium.'; end if;
  return new;
end $$;
drop trigger if exists lim_funcion on public.push_subs;
drop trigger if exists lim_funcion on public.cajas;
drop trigger if exists lim_funcion on public.cobros;
drop trigger if exists lim_funcion on public.empresas;
drop function if exists public.lim_funcion();
create trigger lim_push before insert on public.push_subs for each row execute function public.lim_push();
create trigger lim_caja before insert on public.cajas for each row execute function public.lim_caja();
create trigger lim_dividir before insert on public.cobros for each row execute function public.lim_dividir();
create trigger lim_estaciones before update of estaciones on public.empresas for each row execute function public.lim_estaciones();
