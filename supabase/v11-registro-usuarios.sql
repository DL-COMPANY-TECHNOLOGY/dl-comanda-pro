-- v11: registro de clientes para el panel DL COMPANY
-- Historial de compras/activaciones de planes y fecha en que se adquirió el plan actual.

create table if not exists public.plan_historial (
  id         bigserial primary key,
  empresa_id uuid not null references public.empresas(id) on delete cascade,
  plan       text not null,
  meses      integer,
  vence      date,
  origen     text not null,             -- 'Código DLC-…', 'Panel DL COMPANY', 'SQL'
  bono       boolean not null default false,
  creado     timestamptz not null default now()
);
create index if not exists plan_historial_emp on public.plan_historial (empresa_id, creado desc);
alter table public.plan_historial enable row level security;
revoke all on public.plan_historial from anon, authenticated;

-- aplicar_plan ahora anota cada activación en el historial
drop function if exists public.aplicar_plan(uuid, text, integer);
create or replace function public.aplicar_plan(p_emp uuid, p_plan text, p_meses integer, p_origen text default 'SQL')
returns jsonb language plpgsql security definer set search_path = public as $$
declare e empresas; v_bono boolean := false; v_vence date;
begin
  if p_plan not in ('gratis', 'pro', 'premium') then raise exception 'Plan no válido'; end if;
  select * into e from empresas where id = p_emp for update;
  if not found then raise exception 'No existe ese restaurante'; end if;
  v_bono := p_plan = 'pro' and not e.bono_usado;
  v_vence := case when p_plan = 'gratis' or p_meses is null then null
                  else (greatest(coalesce(case when e.plan = p_plan and not e.plan_prueba then e.plan_vence end, hoy()), hoy())
                        + make_interval(months => greatest(p_meses, 1)))::date end;
  update empresas set plan = p_plan, plan_prueba = false, plan_vence = v_vence,
    premium_hasta = case when v_bono then hoy() + 6 when p_plan = 'pro' then premium_hasta else null end,
    bono_usado = bono_usado or v_bono
  where id = p_emp;
  insert into plan_historial (empresa_id, plan, meses, vence, origen, bono)
  values (p_emp, p_plan, case when p_plan = 'gratis' then null else p_meses end, v_vence, coalesce(p_origen, 'SQL'), v_bono);
  perform ajustar_plan(p_emp);
  return jsonb_build_object('nombre', e.nombre, 'plan', p_plan, 'vence', v_vence, 'bono', v_bono, 'bono_vence', case when v_bono then hoy() + 6 end);
end $$;
revoke execute on function public.aplicar_plan(uuid, text, integer, text) from public, anon, authenticated;

create or replace function public.activar_plan(p_nit text, p_plan text, p_meses integer default 1)
returns text language plpgsql security definer set search_path = public as $$
declare v_id uuid; r jsonb;
begin
  select id into v_id from empresas where regexp_replace(nit, '[^0-9]', '', 'g') = regexp_replace(p_nit, '[^0-9]', '', 'g');
  if v_id is null then raise exception 'No existe un restaurante con ese NIT'; end if;
  r := aplicar_plan(v_id, p_plan, case when p_plan = 'gratis' then null else greatest(coalesce(p_meses, 1), 1) end, 'SQL');
  return format('%s → plan %s hasta %s%s', r->>'nombre', nombre_plan(p_plan), coalesce(r->>'vence', 'siempre'),
    case when (r->>'bono')::boolean then ' · bono: Premium gratis 7 días (hasta ' || (r->>'bono_vence') || ')' else '' end);
end $$;
revoke execute on function public.activar_plan(text, text, integer) from public, anon, authenticated;

create or replace function public.canjear_codigo(p_codigo text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_emp uuid := mi_empresa(); c codigos; r jsonb;
begin
  if v_emp is null or not es_dueno() then raise exception 'Solo el dueño del restaurante puede activar un código'; end if;
  select * into c from codigos where codigo = upper(regexp_replace(coalesce(p_codigo, ''), '\s+', '', 'g')) for update;
  if not found then raise exception 'Código no válido. Revísalo y vuelve a intentarlo.'; end if;
  if c.anulado then raise exception 'Este código fue anulado. Escríbenos por WhatsApp.'; end if;
  if c.usado_por is not null then raise exception 'Este código ya fue usado.'; end if;
  r := aplicar_plan(v_emp, c.plan, c.meses, 'Código ' || c.codigo);
  update codigos set usado_por = v_emp, usado_nombre = r->>'nombre', usado_en = now() where codigo = c.codigo;
  return r || jsonb_build_object('meses', c.meses);
end $$;
revoke execute on function public.canjear_codigo(text) from public, anon;
grant execute on function public.canjear_codigo(text) to authenticated;

create or replace function public.cambiar_plan_admin(p_emp uuid, p_plan text, p_meses integer)
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  if not es_superadmin() then raise exception 'Solo el administrador de DL COMPANY'; end if;
  return aplicar_plan(p_emp, p_plan, case when p_plan = 'gratis' then null else p_meses end, 'Panel DL COMPANY');
end $$;

-- registro de clientes: correo, cuenta creada, último ingreso, plan y fecha en que lo adquirió
create or replace function public.empresas_admin()
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  if not es_superadmin() then raise exception 'Solo el administrador de DL COMPANY'; end if;
  return coalesce((select jsonb_agg(x order by x->>'cuenta_creada' desc nulls last) from (
    select jsonb_build_object(
      'id', e.id, 'nombre', e.nombre, 'nit', e.nit, 'creado', e.creado,
      'plan', e.plan, 'activo', plan_de(e.id), 'vence', e.plan_vence, 'prueba', e.plan_prueba,
      'bono', e.plan = 'pro' and plan_de(e.id) = 'premium', 'bono_vence', e.premium_hasta,
      'correo', u.email, 'cuenta_creada', coalesce(u.created_at, e.creado), 'ultimo_ingreso', u.last_sign_in_at,
      'plan_desde', (select h.creado from plan_historial h where h.empresa_id = e.id and h.plan = e.plan order by h.creado desc limit 1),
      'plan_origen', (select h.origen from plan_historial h where h.empresa_id = e.id and h.plan = e.plan order by h.creado desc limit 1),
      'compras', (select count(*) from plan_historial h where h.empresa_id = e.id and h.plan <> 'gratis'),
      'historial', coalesce((select jsonb_agg(jsonb_build_object('plan', h.plan, 'meses', h.meses, 'vence', h.vence, 'origen', h.origen, 'bono', h.bono, 'fecha', h.creado) order by h.creado desc)
                             from plan_historial h where h.empresa_id = e.id), '[]'::jsonb),
      'mesas', (select count(*) from mesas where empresa_id = e.id and activa),
      'personal', (select count(*) from personal where empresa_id = e.id and activo),
      'pedidos30', (select count(*) from pedidos where empresa_id = e.id and fecha >= hoy() - 30)) x
    from empresas e
    left join lateral (select u.* from perfiles p join auth.users u on u.id = p.user_id where p.empresa_id = e.id and p.rol = 'dueno' order by u.created_at limit 1) u on true) t), '[]'::jsonb);
end $$;
revoke execute on function public.empresas_admin() from public, anon;
grant execute on function public.empresas_admin() to authenticated;
