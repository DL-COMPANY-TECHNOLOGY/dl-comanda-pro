-- v10: códigos de activación de planes y panel de administración de DL COMPANY
-- El administrador es d.l.company.2026@gmail.com (se vincula a su cuenta cuando se registra y confirma el correo).

-- ------------------- administradores de DL COMPANY -------------------
create table if not exists public.superadmins (
  email   text primary key,
  user_id uuid unique references auth.users(id) on delete set null
);
alter table public.superadmins enable row level security;
revoke all on public.superadmins from anon, authenticated;
insert into public.superadmins (email) values ('d.l.company.2026@gmail.com') on conflict do nothing;

create or replace function public.es_superadmin() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from superadmins where user_id = auth.uid() and auth.uid() is not null)
$$;
revoke execute on function public.es_superadmin() from public, anon;
grant execute on function public.es_superadmin() to authenticated;

-- vincula la cuenta del administrador cuando se registra (y su restaurante queda en Premium sin vencimiento)
create or replace function public.vincular_superadmin() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.email is not null and new.email_confirmed_at is not null then
    update superadmins set user_id = new.id where lower(email) = lower(new.email) and user_id is null;
    if found then
      update empresas set plan = 'premium', plan_vence = null, plan_prueba = false
      where id in (select empresa_id from perfiles where user_id = new.id and rol = 'dueno');
    end if;
  end if;
  return new;
end $$;
revoke execute on function public.vincular_superadmin() from public, anon, authenticated;
drop trigger if exists zz_vincular_superadmin on auth.users;
create trigger zz_vincular_superadmin after insert or update of email_confirmed_at on auth.users
  for each row execute function public.vincular_superadmin();

-- ------------------- aplicar un plan (lógica única para códigos, panel y SQL) -------------------
create or replace function public.aplicar_plan(p_emp uuid, p_plan text, p_meses integer)
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
  perform ajustar_plan(p_emp);
  return jsonb_build_object('nombre', e.nombre, 'plan', p_plan, 'vence', v_vence, 'bono', v_bono, 'bono_vence', case when v_bono then hoy() + 6 end);
end $$;
revoke execute on function public.aplicar_plan(uuid, text, integer) from public, anon, authenticated;

-- activar desde el SQL Editor (sigue funcionando):  select activar_plan('900123456', 'pro', 1);
create or replace function public.activar_plan(p_nit text, p_plan text, p_meses integer default 1)
returns text language plpgsql security definer set search_path = public as $$
declare v_id uuid; r jsonb;
begin
  select id into v_id from empresas where regexp_replace(nit, '[^0-9]', '', 'g') = regexp_replace(p_nit, '[^0-9]', '', 'g');
  if v_id is null then raise exception 'No existe un restaurante con ese NIT'; end if;
  r := aplicar_plan(v_id, p_plan, case when p_plan = 'gratis' then null else greatest(coalesce(p_meses, 1), 1) end);
  return format('%s → plan %s hasta %s%s', r->>'nombre', nombre_plan(p_plan), coalesce(r->>'vence', 'siempre'),
    case when (r->>'bono')::boolean then ' · bono: Premium gratis 7 días (hasta ' || (r->>'bono_vence') || ')' else '' end);
end $$;
revoke execute on function public.activar_plan(text, text, integer) from public, anon, authenticated;

-- ------------------- códigos de activación -------------------
create table if not exists public.codigos (
  codigo       text primary key,
  plan         text not null check (plan in ('pro', 'premium')),
  meses        integer not null check (meses between 1 and 36),
  nota         text,
  creado       timestamptz not null default now(),
  usado_por    uuid references public.empresas(id) on delete set null,
  usado_nombre text,
  usado_en     timestamptz,
  anulado      boolean not null default false
);
alter table public.codigos enable row level security;
revoke all on public.codigos from anon, authenticated;

create or replace function public.generar_codigos(p_plan text, p_meses integer, p_cant integer default 1, p_nota text default null)
returns text[] language plpgsql security definer set search_path = public as $$
declare abc text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789'; out text[] := '{}'; c text; i integer; k integer;
begin
  if not es_superadmin() then raise exception 'Solo el administrador de DL COMPANY'; end if;
  if p_plan not in ('pro', 'premium') then raise exception 'Plan no válido'; end if;
  if coalesce(p_meses, 0) not between 1 and 36 then raise exception 'Meses no válidos'; end if;
  for i in 1 .. least(greatest(coalesce(p_cant, 1), 1), 50) loop
    loop
      c := 'DLC-' || case p_plan when 'pro' then 'PRO' else 'PRE' end || '-' || p_meses || 'M-';
      for k in 1 .. 9 loop
        c := c || case when k = 5 then '-' else substr(abc, 1 + floor(random() * length(abc))::integer, 1) end;
      end loop;
      exit when not exists (select 1 from codigos where codigo = c);
    end loop;
    insert into codigos (codigo, plan, meses, nota) values (c, p_plan, p_meses, nullif(left(btrim(coalesce(p_nota, '')), 120), ''));
    out := out || c;
  end loop;
  return out;
end $$;

create or replace function public.listar_codigos(p_limite integer default 300)
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  if not es_superadmin() then raise exception 'Solo el administrador de DL COMPANY'; end if;
  return coalesce((select jsonb_agg(to_jsonb(x) order by x.creado desc) from (select * from codigos order by creado desc limit least(coalesce(p_limite, 300), 1000)) x), '[]'::jsonb);
end $$;

create or replace function public.anular_codigo(p_codigo text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not es_superadmin() then raise exception 'Solo el administrador de DL COMPANY'; end if;
  update codigos set anulado = true where codigo = upper(btrim(p_codigo)) and usado_por is null;
  if not found then raise exception 'Ese código no existe o ya fue usado'; end if;
end $$;

-- el dueño activa su código desde la app
create or replace function public.canjear_codigo(p_codigo text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_emp uuid := mi_empresa(); c codigos; r jsonb;
begin
  if v_emp is null or not es_dueno() then raise exception 'Solo el dueño del restaurante puede activar un código'; end if;
  select * into c from codigos where codigo = upper(regexp_replace(coalesce(p_codigo, ''), '\s+', '', 'g')) for update;
  if not found then raise exception 'Código no válido. Revísalo y vuelve a intentarlo.'; end if;
  if c.anulado then raise exception 'Este código fue anulado. Escríbenos por WhatsApp.'; end if;
  if c.usado_por is not null then raise exception 'Este código ya fue usado.'; end if;
  r := aplicar_plan(v_emp, c.plan, c.meses);
  update codigos set usado_por = v_emp, usado_nombre = r->>'nombre', usado_en = now() where codigo = c.codigo;
  return r || jsonb_build_object('meses', c.meses);
end $$;

-- ------------------- panel: restaurantes -------------------
create or replace function public.empresas_admin()
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  if not es_superadmin() then raise exception 'Solo el administrador de DL COMPANY'; end if;
  return coalesce((select jsonb_agg(x order by x->>'creado' desc) from (
    select jsonb_build_object(
      'id', e.id, 'nombre', e.nombre, 'nit', e.nit, 'creado', e.creado,
      'plan', e.plan, 'activo', plan_de(e.id), 'vence', e.plan_vence, 'prueba', e.plan_prueba,
      'bono', e.plan = 'pro' and plan_de(e.id) = 'premium', 'bono_vence', e.premium_hasta,
      'correo', (select u.email from perfiles p join auth.users u on u.id = p.user_id where p.empresa_id = e.id and p.rol = 'dueno' limit 1),
      'mesas', (select count(*) from mesas where empresa_id = e.id and activa),
      'personal', (select count(*) from personal where empresa_id = e.id and activo),
      'pedidos30', (select count(*) from pedidos where empresa_id = e.id and fecha >= hoy() - 30)) x
    from empresas e) t), '[]'::jsonb);
end $$;

create or replace function public.cambiar_plan_admin(p_emp uuid, p_plan text, p_meses integer)
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  if not es_superadmin() then raise exception 'Solo el administrador de DL COMPANY'; end if;
  return aplicar_plan(p_emp, p_plan, case when p_plan = 'gratis' then null else p_meses end);
end $$;

revoke execute on function public.generar_codigos(text, integer, integer, text) from public, anon;
revoke execute on function public.listar_codigos(integer) from public, anon;
revoke execute on function public.anular_codigo(text) from public, anon;
revoke execute on function public.canjear_codigo(text) from public, anon;
revoke execute on function public.empresas_admin() from public, anon;
revoke execute on function public.cambiar_plan_admin(uuid, text, integer) from public, anon;
grant execute on function public.generar_codigos(text, integer, integer, text) to authenticated;
grant execute on function public.listar_codigos(integer) to authenticated;
grant execute on function public.anular_codigo(text) to authenticated;
grant execute on function public.canjear_codigo(text) to authenticated;
grant execute on function public.empresas_admin() to authenticated;
grant execute on function public.cambiar_plan_admin(uuid, text, integer) to authenticated;
