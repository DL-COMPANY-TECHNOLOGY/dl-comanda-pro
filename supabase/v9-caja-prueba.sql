-- v9: conteo de caja, prueba Premium 3 días, bono Premium 7 días al comprar Pro y nuevos límites de planes
-- Compatible con la versión anterior: p_conteo es opcional.
alter table public.cajas add column if not exists conteo_base jsonb;

drop function if exists public.abrir_caja(integer);
create or replace function public.abrir_caja(p_base integer, p_conteo jsonb default null)
returns uuid language plpgsql security definer set search_path = public as $$
declare v_emp uuid := mi_empresa(); v_id uuid;
begin
  if v_emp is null or mi_rol() not in ('dueno', 'cocina') then raise exception 'Solo caja o el dueño pueden abrir la caja'; end if;
  if exists (select 1 from cajas where empresa_id = v_emp and estado = 'abierta') then raise exception 'Ya hay una caja abierta'; end if;
  insert into cajas (empresa_id, base, conteo_base, abierta_por)
  values (v_emp, greatest(coalesce(p_base, 0), 0), case when jsonb_typeof(p_conteo) = 'object' then p_conteo end, quien_soy())
  returning id into v_id;
  return v_id;
end $$;
revoke all on function public.abrir_caja(integer, jsonb) from public, anon;
grant execute on function public.abrir_caja(integer, jsonb) to authenticated;

-- v9b: prueba Premium de 3 días para cuentas nuevas (las cuentas ya creadas no cambian)
create or replace function public.prueba_premium() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.plan = 'gratis' and new.plan_vence is null then
    new.plan := 'premium'; new.plan_vence := hoy() + 2;  -- hoy + 2 días más = 3 días new.plan_prueba := true;
  end if;
  return new;
end $$;
revoke execute on function public.prueba_premium() from public, anon, authenticated;

-- v9c: quien compra el plan Pro por primera vez recibe 7 días de Premium gratis (bono de bienvenida)
alter table public.empresas add column if not exists premium_hasta date;
alter table public.empresas add column if not exists bono_usado boolean not null default false;

create or replace function public.plan_de(p_emp uuid) returns text
language sql stable security definer set search_path = public as $$
  select case
    when e.plan <> 'gratis' and e.plan_vence is not null and e.plan_vence < hoy() then 'gratis'
    when e.plan = 'pro' and e.premium_hasta is not null and e.premium_hasta >= hoy() then 'premium'
    else e.plan end
  from empresas e where e.id = p_emp
$$;

create or replace function public.mi_plan() returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'plan', plan_de(e.id), 'contratado', e.plan, 'vence', e.plan_vence, 'prueba', e.plan_prueba,
    'bono', (e.plan = 'pro' and plan_de(e.id) = 'premium'), 'bono_vence', case when e.plan = 'pro' and plan_de(e.id) = 'premium' then e.premium_hasta end,
    'limites', plan_limites(plan_de(e.id)),
    'uso', jsonb_build_object(
      'mesas',     (select count(*) from mesas where empresa_id = e.id and activa),
      'productos', (select count(*) from productos where empresa_id = e.id and activo),
      'usuarios',  (select count(*) from personal where empresa_id = e.id and activo),
      'pedidos_hoy', (select count(*) from pedidos where empresa_id = e.id and fecha = hoy())))
  from empresas e where e.id = mi_empresa()
$$;

-- Ejemplo:  select activar_plan('900123456', 'pro', 1);   -- NIT, plan, meses
create or replace function public.activar_plan(p_nit text, p_plan text, p_meses integer default 1)
returns text language plpgsql security definer set search_path = public as $$
declare e empresas; v_bono boolean := false;
begin
  if p_plan not in ('gratis', 'pro', 'premium') then raise exception 'Plan no válido: gratis, pro o premium'; end if;
  select * into e from empresas where regexp_replace(nit, '[^0-9]', '', 'g') = regexp_replace(p_nit, '[^0-9]', '', 'g');
  if not found then raise exception 'No existe un restaurante con ese NIT'; end if;
  v_bono := p_plan = 'pro' and not e.bono_usado;
  update empresas set plan = p_plan, plan_prueba = false,
    plan_vence = case when p_plan = 'gratis' then null
                      else greatest(coalesce(case when e.plan = p_plan and not e.plan_prueba then e.plan_vence end, hoy()), hoy()) + make_interval(months => greatest(coalesce(p_meses, 1), 1)) end,
    premium_hasta = case when v_bono then hoy() + 6 when p_plan = 'pro' then premium_hasta else null end,
    bono_usado = bono_usado or v_bono
  where id = e.id;
  perform ajustar_plan(e.id);
  return format('%s → plan %s hasta %s%s', e.nombre, nombre_plan(p_plan), coalesce((select plan_vence::text from empresas where id = e.id), 'siempre'),
    case when v_bono then ' · bono: Premium gratis 7 días (hasta ' || (hoy() + 6)::text || ')' else '' end);
end $$;
revoke execute on function public.activar_plan(text, text, integer) from public, anon, authenticated;
revoke execute on function public.plan_de(uuid) from public, anon;
revoke execute on function public.mi_plan() from public, anon;
grant execute on function public.mi_plan() to authenticated;

-- v9d: nuevos límites. Gratis: 15 pedidos al día. Pro: 8 mesas, 80 productos, 4 usuarios y 50 pedidos al día
create or replace function public.plan_limites(p_plan text) returns jsonb
language sql immutable set search_path = public as $$
  select case p_plan
    when 'premium' then '{"mesas":null,"productos":null,"usuarios":null,"pedidos_dia":null,"historial":null,"push":true,"imprimir":true,"dividir":true,"caja":true,"excel":true,"mover":true,"estaciones":true,"stock":true,"soporte":true}'::jsonb
    when 'pro'     then '{"mesas":8,"productos":80,"usuarios":4,"pedidos_dia":50,"historial":90,"push":true,"imprimir":true,"dividir":true,"caja":true,"excel":true,"mover":true,"estaciones":false,"stock":false,"soporte":false}'::jsonb
    else                '{"mesas":5,"productos":20,"usuarios":2,"pedidos_dia":15,"historial":1,"push":false,"imprimir":false,"dividir":false,"caja":false,"excel":false,"mover":false,"estaciones":false,"stock":false,"soporte":false}'::jsonb
  end
$$;

create or replace function public.lim_pedidos() returns trigger
language plpgsql security definer set search_path = public as $$
declare l integer := plan_lim(new.empresa_id, 'pedidos_dia');
begin
  if l is not null and (select count(*) from pedidos where empresa_id = new.empresa_id and fecha = new.fecha) >= l then
    raise exception 'PLAN: Llegaste a los % pedidos del día de tu plan %. Mejora tu plan para tomar más pedidos.', l, nombre_plan(plan_de(new.empresa_id));
  end if;
  if new.mesa_id is not null and not coalesce(dentro_del_plan(new.empresa_id, 'mesa', new.mesa_id), false) then
    raise exception 'PLAN: Esa mesa está fuera de tu plan %. Mejora tu plan para usar todas tus mesas.', nombre_plan(plan_de(new.empresa_id));
  end if;
  return new;
end $$;
revoke execute on function public.lim_pedidos() from public, anon, authenticated;
