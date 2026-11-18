-- =====================================================================
--  DL COMANDA PRO · Base de datos (Supabase)
--  Pedidos de mesero → cocina/caja en tiempo real.
--  Desarrollado por DL COMPANY -TECHNOLOGY-
--  Se puede ejecutar varias veces sin dañar nada.
-- =====================================================================

create extension if not exists pgcrypto with schema extensions;

-- ---------------------------------------------------------------------
-- 1. Tablas
-- ---------------------------------------------------------------------
create table if not exists public.empresas (
  id         uuid primary key default gen_random_uuid(),
  nombre     text not null,
  nit        text not null default '',
  tipo       text not null default 'negocio',
  plan       text not null default 'gratis',
  activa     boolean not null default true,
  creado_por uuid,
  creado     timestamptz not null default now()
);
create unique index if not exists empresas_nit_unico
  on public.empresas ((regexp_replace(nit, '[^0-9]', '', 'g')))
  where regexp_replace(nit, '[^0-9]', '', 'g') <> '';

create table if not exists public.personal (
  id              uuid primary key default gen_random_uuid(),
  empresa_id      uuid not null references public.empresas(id) on delete cascade,
  usuario         text not null,
  rol             text not null check (rol in ('mesero', 'cocina')),
  pin_hash        text not null,
  activo          boolean not null default true,
  intentos        integer not null default 0,
  bloqueado_hasta timestamptz,
  creado          timestamptz not null default now()
);
create unique index if not exists personal_usuario_unico on public.personal (empresa_id, lower(btrim(usuario)));

create table if not exists public.perfiles (
  user_id     uuid primary key references auth.users(id) on delete cascade,
  empresa_id  uuid not null references public.empresas(id) on delete cascade,
  rol         text not null check (rol in ('dueno', 'mesero', 'cocina')),
  personal_id uuid references public.personal(id) on delete cascade,
  creado      timestamptz not null default now()
);
create index if not exists perfiles_empresa_idx on public.perfiles (empresa_id);
create index if not exists perfiles_personal_idx on public.perfiles (personal_id);

create table if not exists public.login_fallos (
  id         bigint generated always as identity primary key,
  empresa_id uuid,
  ts         timestamptz not null default now()
);
create index if not exists login_fallos_idx on public.login_fallos (empresa_id, ts);

create table if not exists public.mesas (
  id         uuid primary key default gen_random_uuid(),
  empresa_id uuid not null references public.empresas(id) on delete cascade,
  nombre     text not null,
  orden      integer not null default 0,
  activa     boolean not null default true,
  creado     timestamptz not null default now()
);
create index if not exists mesas_empresa_idx on public.mesas (empresa_id);

create table if not exists public.productos (
  id         uuid primary key default gen_random_uuid(),
  empresa_id uuid not null references public.empresas(id) on delete cascade,
  nombre     text not null,
  categoria  text not null default 'General',
  precio     integer not null default 0 check (precio >= 0),
  activo     boolean not null default true,
  orden      integer not null default 0,
  creado     timestamptz not null default now()
);
create index if not exists productos_empresa_idx on public.productos (empresa_id);

create table if not exists public.pedidos (
  id            uuid primary key default gen_random_uuid(),
  empresa_id    uuid not null references public.empresas(id) on delete cascade,
  numero        integer not null,
  fecha         date not null,
  mesa_id       uuid references public.mesas(id) on delete set null,
  mesa          text not null,
  mesero_id     uuid references public.personal(id) on delete set null,
  mesero        text not null,
  estado        text not null default 'nuevo'
                check (estado in ('nuevo', 'preparando', 'listo', 'entregado', 'cancelado')),
  nota          text,
  total         integer not null default 0,
  pagado        boolean not null default false,
  metodo        text,
  cocina        text,
  creado        timestamptz not null default now(),
  actualizado   timestamptz not null default now(),
  preparando_en timestamptz,
  listo_en      timestamptz,
  entregado_en  timestamptz,
  pagado_en     timestamptz
);
create index if not exists pedidos_empresa_fecha_idx on public.pedidos (empresa_id, fecha);
create index if not exists pedidos_abiertos_idx on public.pedidos (empresa_id) where not pagado;
create index if not exists pedidos_mesa_idx on public.pedidos (mesa_id);
create index if not exists pedidos_mesero_idx on public.pedidos (mesero_id);

create table if not exists public.pedido_items (
  id          bigint generated always as identity primary key,
  pedido_id   uuid not null references public.pedidos(id) on delete cascade,
  empresa_id  uuid not null references public.empresas(id) on delete cascade,
  producto_id uuid references public.productos(id) on delete set null,
  nombre      text not null,
  precio      integer not null,
  cant        integer not null check (cant > 0),
  nota        text
);
create index if not exists pedido_items_pedido_idx on public.pedido_items (pedido_id);
create index if not exists pedido_items_empresa_idx on public.pedido_items (empresa_id);
create index if not exists pedido_items_producto_idx on public.pedido_items (producto_id);

-- ---------------------------------------------------------------------
-- 2. Quién soy
-- ---------------------------------------------------------------------
create or replace function public.hoy() returns date
language sql stable set search_path = public as $$ select (now() at time zone 'America/Bogota')::date $$;

create or replace function public.norm_txt(t text) returns text
language sql immutable set search_path = public as $$
  select regexp_replace(translate(lower(btrim(coalesce(t, ''))), 'áéíóúüñàèìòù', 'aeiouunaeiou'), '\s+', ' ', 'g')
$$;

create or replace function public.mi_empresa() returns uuid
language sql stable security definer set search_path = public as $$
  select p.empresa_id from perfiles p
  join empresas e on e.id = p.empresa_id and e.activa
  left join personal c on c.id = p.personal_id
  where p.user_id = auth.uid() and (p.rol = 'dueno' or c.activo)
$$;

create or replace function public.mi_rol() returns text
language sql stable security definer set search_path = public as $$
  select p.rol from perfiles p left join personal c on c.id = p.personal_id
  where p.user_id = auth.uid() and (p.rol = 'dueno' or c.activo)
$$;

create or replace function public.es_dueno() returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce(mi_rol() = 'dueno', false)
$$;

-- ---------------------------------------------------------------------
-- 3. Seguridad (RLS): cada empresa solo ve lo suyo
-- ---------------------------------------------------------------------
alter table public.empresas     enable row level security;
alter table public.personal     enable row level security;
alter table public.perfiles     enable row level security;
alter table public.login_fallos enable row level security;
alter table public.mesas        enable row level security;
alter table public.productos    enable row level security;
alter table public.pedidos      enable row level security;
alter table public.pedido_items enable row level security;

drop policy if exists emp_sel on public.empresas;
create policy emp_sel on public.empresas for select to authenticated using (id = (select mi_empresa()));

drop policy if exists per_sel on public.personal;
create policy per_sel on public.personal for select to authenticated
  using (empresa_id = (select mi_empresa()) and (select es_dueno()));
revoke all on public.personal from anon, authenticated;
grant select (id, empresa_id, usuario, rol, activo, bloqueado_hasta, creado) on public.personal to authenticated;

drop policy if exists prf_sel on public.perfiles;
create policy prf_sel on public.perfiles for select to authenticated using (user_id = (select auth.uid()));

drop policy if exists mes_sel on public.mesas;
drop policy if exists mes_ins on public.mesas;
drop policy if exists mes_upd on public.mesas;
drop policy if exists mes_del on public.mesas;
create policy mes_sel on public.mesas for select to authenticated using (empresa_id = (select mi_empresa()));
create policy mes_ins on public.mesas for insert to authenticated with check (empresa_id = (select mi_empresa()) and (select es_dueno()));
create policy mes_upd on public.mesas for update to authenticated using (empresa_id = (select mi_empresa()) and (select es_dueno())) with check (empresa_id = (select mi_empresa()));
create policy mes_del on public.mesas for delete to authenticated using (empresa_id = (select mi_empresa()) and (select es_dueno()));

drop policy if exists pro_sel on public.productos;
drop policy if exists pro_ins on public.productos;
drop policy if exists pro_upd on public.productos;
drop policy if exists pro_del on public.productos;
create policy pro_sel on public.productos for select to authenticated using (empresa_id = (select mi_empresa()));
create policy pro_ins on public.productos for insert to authenticated with check (empresa_id = (select mi_empresa()) and (select es_dueno()));
create policy pro_upd on public.productos for update to authenticated using (empresa_id = (select mi_empresa()) and (select es_dueno())) with check (empresa_id = (select mi_empresa()));
create policy pro_del on public.productos for delete to authenticated using (empresa_id = (select mi_empresa()) and (select es_dueno()));

drop policy if exists ped_sel on public.pedidos;
create policy ped_sel on public.pedidos for select to authenticated using (empresa_id = (select mi_empresa()));
drop policy if exists pit_sel on public.pedido_items;
create policy pit_sel on public.pedido_items for select to authenticated using (empresa_id = (select mi_empresa()));

-- pedidos e items solo se escriben con las funciones de abajo
revoke insert, update, delete on public.pedidos, public.pedido_items, public.empresas, public.perfiles from anon, authenticated;
revoke all on public.login_fallos from anon, authenticated;

-- ---------------------------------------------------------------------
-- 4. Pedidos
-- ---------------------------------------------------------------------
create or replace function public.crear_pedido(p_mesa uuid, p_items jsonb, p_nota text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_emp uuid := mi_empresa(); v_rol text := mi_rol(); m mesas; v_pid uuid; v_num integer; v_tot integer;
        v_mesero_id uuid; v_mesero text; it jsonb; pr productos; v_cant integer; n integer := 0;
begin
  if v_emp is null then raise exception 'Sesión no válida'; end if;
  select * into m from mesas where id = p_mesa and empresa_id = v_emp;
  if not found then raise exception 'Mesa no válida'; end if;
  if jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) = 0 then raise exception 'El pedido está vacío'; end if;
  if jsonb_array_length(p_items) > 80 then raise exception 'Demasiados productos en un solo pedido'; end if;

  select c.id, c.usuario into v_mesero_id, v_mesero
  from perfiles p join personal c on c.id = p.personal_id where p.user_id = auth.uid();
  if v_mesero is null then v_mesero := 'Dueño'; end if;

  perform 1 from empresas where id = v_emp for update;   -- numeración del día sin choques
  select coalesce(max(numero), 0) + 1 into v_num from pedidos where empresa_id = v_emp and fecha = hoy();

  insert into pedidos (empresa_id, numero, fecha, mesa_id, mesa, mesero_id, mesero, nota)
  values (v_emp, v_num, hoy(), m.id, m.nombre, v_mesero_id, v_mesero, nullif(left(btrim(coalesce(p_nota, '')), 300), ''))
  returning id into v_pid;

  for it in select * from jsonb_array_elements(p_items) loop
    select * into pr from productos where id = (it->>'pid')::uuid and empresa_id = v_emp and activo;
    if not found then raise exception 'Un producto ya no está disponible. Actualiza el menú.'; end if;
    v_cant := coalesce((it->>'cant')::integer, 0);
    if v_cant < 1 or v_cant > 99 then raise exception 'Cantidad no válida en %', pr.nombre; end if;
    insert into pedido_items (pedido_id, empresa_id, producto_id, nombre, precio, cant, nota)
    values (v_pid, v_emp, pr.id, pr.nombre, pr.precio, v_cant, nullif(left(btrim(coalesce(it->>'nota', '')), 160), ''));
    n := n + 1;
  end loop;

  select coalesce(sum(precio * cant), 0) into v_tot from pedido_items where pedido_id = v_pid;
  update pedidos set total = v_tot where id = v_pid;
  return jsonb_build_object('id', v_pid, 'numero', v_num, 'total', v_tot);
end $$;

create or replace function public.cambiar_estado(p_id uuid, p_estado text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_emp uuid := mi_empresa(); v_rol text := mi_rol(); p pedidos; v_quien text;
begin
  if v_emp is null then raise exception 'Sesión no válida'; end if;
  select * into p from pedidos where id = p_id and empresa_id = v_emp for update;
  if not found then raise exception 'Pedido no encontrado'; end if;
  select coalesce(c.usuario, 'Dueño') into v_quien from perfiles x left join personal c on c.id = x.personal_id where x.user_id = auth.uid();

  if p_estado in ('nuevo', 'preparando', 'listo') then
    if v_rol not in ('cocina', 'dueno') then raise exception 'Solo cocina puede cambiar este estado'; end if;
    if p.estado not in ('nuevo', 'preparando', 'listo') then raise exception 'Ese pedido ya fue %', p.estado; end if;
  elsif p_estado = 'entregado' then
    if p.estado not in ('listo', 'preparando', 'nuevo') then raise exception 'Ese pedido ya fue %', p.estado; end if;
    if p.estado <> 'listo' and v_rol <> 'dueno' and v_rol <> 'cocina' then raise exception 'El pedido aún no está listo'; end if;
  elsif p_estado = 'cancelado' then
    if p.estado in ('entregado', 'cancelado') or p.pagado then raise exception 'Ese pedido ya no se puede cancelar'; end if;
    if v_rol = 'mesero' and p.estado <> 'nuevo' then raise exception 'La cocina ya lo está preparando. Pide a cocina que lo cancele.'; end if;
  else
    raise exception 'Estado no válido';
  end if;

  update pedidos set
    estado = p_estado, actualizado = now(),
    preparando_en = case when p_estado = 'preparando' then now() when p_estado = 'nuevo' then null else preparando_en end,
    listo_en      = case when p_estado = 'listo' then now() when p_estado in ('nuevo', 'preparando') then null else listo_en end,
    entregado_en  = case when p_estado = 'entregado' then now() else entregado_en end,
    cocina        = case when p_estado in ('preparando', 'listo') then v_quien else cocina end
  where id = p_id;
  return jsonb_build_object('ok', true, 'estado', p_estado);
end $$;

-- cobrar (cerrar la cuenta de una mesa): cocina/caja o dueño
create or replace function public.cobrar_mesa(p_mesa uuid, p_metodo text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_emp uuid := mi_empresa(); v_rol text := mi_rol(); v_tot integer; v_n integer;
begin
  if v_emp is null then raise exception 'Sesión no válida'; end if;
  if v_rol not in ('cocina', 'dueno') then raise exception 'Solo caja o el dueño pueden cobrar'; end if;
  if p_metodo not in ('efectivo', 'tarjeta', 'transferencia') then raise exception 'Medio de pago no válido'; end if;
  select coalesce(sum(total), 0), count(*) into v_tot, v_n from pedidos
  where empresa_id = v_emp and mesa_id = p_mesa and not pagado and estado <> 'cancelado';
  if v_n = 0 then raise exception 'Esa mesa no tiene nada por cobrar'; end if;
  update pedidos set pagado = true, metodo = p_metodo, pagado_en = now(), actualizado = now(),
    estado = case when estado in ('nuevo', 'preparando', 'listo') then 'entregado' else estado end,
    entregado_en = coalesce(entregado_en, now())
  where empresa_id = v_emp and mesa_id = p_mesa and not pagado and estado <> 'cancelado';
  return jsonb_build_object('ok', true, 'total', v_tot, 'pedidos', v_n);
end $$;

-- ---------------------------------------------------------------------
-- 5. Personal: meseros y cocina/caja (solo el dueño)
-- ---------------------------------------------------------------------
create or replace function public.generar_pin(p_emp uuid) returns text
language plpgsql volatile security definer set search_path = public, extensions as $$
declare v text; b bytea; i integer := 0;
begin
  loop
    i := i + 1;
    b := extensions.gen_random_bytes(2);
    v := lpad((((get_byte(b, 0) << 8) + get_byte(b, 1)) % 10000)::text, 4, '0');
    continue when v ~ '^(\d)\1{3}$' or v in ('1234','2345','3456','4567','5678','6789','0123','9876','8765','7654','6543','5432','4321','3210');
    exit when not exists (select 1 from personal where empresa_id = p_emp and pin_hash = extensions.crypt(v, pin_hash)) or i > 300;
  end loop;
  return v;
end $$;

create or replace function public.crear_personal(p_usuario text, p_rol text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare v_emp uuid := mi_empresa(); v_pin text; v_id uuid; v_usr text := regexp_replace(btrim(coalesce(p_usuario, '')), '\s+', ' ', 'g');
begin
  if v_emp is null or not es_dueno() then raise exception 'Solo el dueño puede crear usuarios'; end if;
  if p_rol not in ('mesero', 'cocina') then raise exception 'Rol no válido'; end if;
  if length(v_usr) < 2 or length(v_usr) > 30 then raise exception 'Escribe un usuario de 2 a 30 letras'; end if;
  if exists (select 1 from personal where empresa_id = v_emp and lower(btrim(usuario)) = lower(v_usr)) then
    raise exception 'Ya existe un usuario con ese nombre';
  end if;
  if (select count(*) from personal where empresa_id = v_emp) >= 60 then raise exception 'Llegaste al máximo de usuarios'; end if;
  v_pin := generar_pin(v_emp);
  insert into personal (empresa_id, usuario, rol, pin_hash) values (v_emp, v_usr, p_rol, extensions.crypt(v_pin, extensions.gen_salt('bf', 8)))
  returning id into v_id;
  return jsonb_build_object('id', v_id, 'usuario', v_usr, 'rol', p_rol, 'pin', v_pin);
end $$;

create or replace function public.regenerar_pin(p_id uuid)
returns text language plpgsql security definer set search_path = public, extensions as $$
declare v_emp uuid := mi_empresa(); v_pin text;
begin
  if v_emp is null or not es_dueno() or not exists (select 1 from personal where id = p_id and empresa_id = v_emp) then
    raise exception 'Solo el dueño puede cambiar el PIN';
  end if;
  v_pin := generar_pin(v_emp);
  update personal set pin_hash = extensions.crypt(v_pin, extensions.gen_salt('bf', 8)), intentos = 0, bloqueado_hasta = null where id = p_id;
  delete from perfiles where personal_id = p_id;   -- cierra sus sesiones abiertas
  return v_pin;
end $$;

create or replace function public.editar_personal(p_id uuid, p_usuario text, p_rol text, p_activo boolean)
returns void language plpgsql security definer set search_path = public as $$
declare v_emp uuid := mi_empresa(); c personal; v_usr text := regexp_replace(btrim(coalesce(p_usuario, '')), '\s+', ' ', 'g');
begin
  if v_emp is null or not es_dueno() then raise exception 'Solo el dueño puede editar usuarios'; end if;
  select * into c from personal where id = p_id and empresa_id = v_emp;
  if not found then raise exception 'Usuario no encontrado'; end if;
  if p_rol not in ('mesero', 'cocina') then raise exception 'Rol no válido'; end if;
  if length(v_usr) < 2 or length(v_usr) > 30 then raise exception 'Escribe un usuario de 2 a 30 letras'; end if;
  if exists (select 1 from personal where empresa_id = v_emp and id <> p_id and lower(btrim(usuario)) = lower(v_usr)) then
    raise exception 'Ya existe un usuario con ese nombre';
  end if;
  update personal set usuario = v_usr, rol = p_rol, activo = p_activo,
    intentos = case when p_activo then 0 else intentos end,
    bloqueado_hasta = case when p_activo then null else bloqueado_hasta end
  where id = p_id;
  if not p_activo or p_rol <> c.rol then delete from perfiles where personal_id = p_id; end if;
end $$;

create or replace function public.eliminar_personal(p_id uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  if mi_empresa() is null or not es_dueno() then raise exception 'Solo el dueño puede eliminar usuarios'; end if;
  delete from personal where id = p_id and empresa_id = mi_empresa();
end $$;

create or replace function public.editar_empresa(p_nombre text)
returns void language plpgsql security definer set search_path = public as $$
declare v text := left(regexp_replace(btrim(coalesce(p_nombre, '')), '\s+', ' ', 'g'), 60);
begin
  if mi_empresa() is null or not es_dueno() then raise exception 'Solo el dueño puede editar la empresa'; end if;
  if length(v) < 2 then raise exception 'Escribe el nombre'; end if;
  update empresas set nombre = v where id = mi_empresa();
end $$;

-- ---------------------------------------------------------------------
-- 6. Ingreso del personal: empresa + NIT + usuario + PIN (con bloqueo)
--    La app entra con un usuario anónimo de Supabase y esta función
--    lo convierte en mesero o cocina si los datos son correctos.
-- ---------------------------------------------------------------------
create or replace function public.ingresar_personal(p_empresa text, p_nit text, p_usuario text, p_pin text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare e empresas; c personal; v_fallos integer; v_dig text := regexp_replace(coalesce(p_nit, ''), '[^0-9]', '', 'g');
begin
  if auth.uid() is null then return jsonb_build_object('ok', false, 'error', 'sin_sesion'); end if;
  if coalesce((auth.jwt() ->> 'is_anonymous')::boolean, false) is not true then
    return jsonb_build_object('ok', false, 'error', 'es_dueno');
  end if;
  if length(v_dig) < 5 then return jsonb_build_object('ok', false, 'error', 'datos'); end if;
  select * into e from empresas
  where regexp_replace(nit, '[^0-9]', '', 'g') = v_dig and norm_txt(nombre) = norm_txt(p_empresa) and activa;
  if not found then return jsonb_build_object('ok', false, 'error', 'datos'); end if;

  select count(*) into v_fallos from login_fallos where empresa_id = e.id and ts > now() - interval '15 minutes';
  if v_fallos >= 30 then return jsonb_build_object('ok', false, 'error', 'espera', 'minutos', 15); end if;

  if p_usuario is null then return jsonb_build_object('ok', true, 'paso', 'empresa', 'empresa', e.nombre); end if;

  select * into c from personal where empresa_id = e.id and lower(btrim(usuario)) = lower(btrim(p_usuario)) for update;
  if not found then
    insert into login_fallos (empresa_id) values (e.id);
    return jsonb_build_object('ok', false, 'error', 'pin');
  end if;
  if not c.activo then return jsonb_build_object('ok', false, 'error', 'inactivo'); end if;
  if c.bloqueado_hasta is not null and c.bloqueado_hasta > now() then
    return jsonb_build_object('ok', false, 'error', 'bloqueado', 'minutos', ceil(extract(epoch from (c.bloqueado_hasta - now())) / 60));
  end if;
  if coalesce(p_pin, '') !~ '^\d{4}$' or c.pin_hash <> extensions.crypt(p_pin, c.pin_hash) then
    insert into login_fallos (empresa_id) values (e.id);
    if c.intentos + 1 >= 5 then
      update personal set intentos = 0, bloqueado_hasta = now() + interval '15 minutes' where id = c.id;
      return jsonb_build_object('ok', false, 'error', 'bloqueado', 'minutos', 15);
    end if;
    update personal set intentos = intentos + 1 where id = c.id;
    return jsonb_build_object('ok', false, 'error', 'pin', 'quedan', 5 - (c.intentos + 1));
  end if;

  update personal set intentos = 0, bloqueado_hasta = null where id = c.id;
  insert into perfiles (user_id, empresa_id, rol, personal_id) values (auth.uid(), e.id, c.rol, c.id)
    on conflict (user_id) do update set empresa_id = excluded.empresa_id, rol = excluded.rol, personal_id = excluded.personal_id;
  return jsonb_build_object('ok', true, 'empresa', e.nombre, 'usuario', c.usuario, 'rol', c.rol);
end $$;

create or replace function public.nit_disponible(p_nit text) returns boolean
language sql stable security definer set search_path = public as $$
  select length(regexp_replace(coalesce(p_nit, ''), '[^0-9]', '', 'g')) >= 6
     and not exists (select 1 from empresas where regexp_replace(nit, '[^0-9]', '', 'g') = regexp_replace(p_nit, '[^0-9]', '', 'g'))
$$;

-- ---------------------------------------------------------------------
-- 7. Registro del dueño: al crear la cuenta se crea la empresa con
--    mesas y un menú de ejemplo listos para probar.
-- ---------------------------------------------------------------------
create or replace function public.al_registrar_usuario()
returns trigger language plpgsql security definer set search_path = public as $$
declare m jsonb := coalesce(new.raw_user_meta_data, '{}'::jsonb); e uuid; v_nom text; v_nit text; v_tipo text; i integer;
begin
  if coalesce(new.is_anonymous, false) then return new; end if;
  v_nom := left(btrim(coalesce(m->>'negocio', '')), 60);
  if v_nom = '' then return new; end if;
  if exists (select 1 from perfiles where user_id = new.id) then return new; end if;
  v_tipo := case when m->>'tipo' = 'empresa' then 'empresa' else 'negocio' end;
  v_nit := left(btrim(coalesce(m->>'nit', '')), 20);
  if length(regexp_replace(v_nit, '[^0-9]', '', 'g')) < 6 then
    raise exception 'NIT_REQUERIDO';
  end if;
  if exists (select 1 from empresas where regexp_replace(nit, '[^0-9]', '', 'g') = regexp_replace(v_nit, '[^0-9]', '', 'g')) then
    raise exception 'NIT_REGISTRADO';
  end if;
  insert into empresas (nombre, nit, plan, tipo, creado_por) values (v_nom, v_nit, 'gratis', v_tipo, new.id) returning id into e;
  insert into perfiles (user_id, empresa_id, rol) values (new.id, e, 'dueno');
  for i in 1..8 loop insert into mesas (empresa_id, nombre, orden) values (e, 'Mesa ' || i, i); end loop;
  insert into mesas (empresa_id, nombre, orden) values (e, 'Barra', 9), (e, 'Para llevar', 10);
  insert into productos (empresa_id, nombre, categoria, precio, orden) values
    (e, 'Empanadas x3',          'Entradas',   9000, 1),
    (e, 'Patacones con hogao',   'Entradas',  12000, 2),
    (e, 'Bandeja paisa',         'Platos',    32000, 3),
    (e, 'Churrasco',             'Platos',    38000, 4),
    (e, 'Hamburguesa de la casa','Platos',    24000, 5),
    (e, 'Limonada de coco',      'Bebidas',    9000, 6),
    (e, 'Gaseosa',               'Bebidas',    4500, 7),
    (e, 'Cerveza nacional',      'Bebidas',    6000, 8),
    (e, 'Tres leches',           'Postres',    8000, 9);
  return new;
end $$;

drop trigger if exists al_registrar_usuario on auth.users;
create trigger al_registrar_usuario after insert on auth.users
  for each row execute function public.al_registrar_usuario();

-- ---------------------------------------------------------------------
-- 8. Permisos de ejecución
-- ---------------------------------------------------------------------
revoke execute on all functions in schema public from public, anon;
grant execute on function public.crear_pedido(uuid, jsonb, text)                 to authenticated;
grant execute on function public.cambiar_estado(uuid, text)                      to authenticated;
grant execute on function public.cobrar_mesa(uuid, text)                         to authenticated;
grant execute on function public.crear_personal(text, text)                      to authenticated;
grant execute on function public.regenerar_pin(uuid)                             to authenticated;
grant execute on function public.editar_personal(uuid, text, text, boolean)      to authenticated;
grant execute on function public.eliminar_personal(uuid)                         to authenticated;
grant execute on function public.editar_empresa(text)                            to authenticated;
grant execute on function public.ingresar_personal(text, text, text, text)       to authenticated;
grant execute on function public.nit_disponible(text)                            to anon, authenticated;
grant execute on function public.mi_empresa()                                    to authenticated;
grant execute on function public.mi_rol()                                        to authenticated;
grant execute on function public.es_dueno()                                      to authenticated;
grant execute on function public.hoy()                                           to authenticated;
revoke execute on function public.generar_pin(uuid)                              from authenticated;
revoke execute on function public.al_registrar_usuario()                         from authenticated;

-- ---------------------------------------------------------------------
-- 9. Tiempo real
-- ---------------------------------------------------------------------
do $$ begin
  begin alter publication supabase_realtime add table public.pedidos;   exception when duplicate_object then null; end;
  begin alter publication supabase_realtime add table public.mesas;     exception when duplicate_object then null; end;
  begin alter publication supabase_realtime add table public.productos; exception when duplicate_object then null; end;
  begin alter publication supabase_realtime add table public.empresas;  exception when duplicate_object then null; end;
end $$;
