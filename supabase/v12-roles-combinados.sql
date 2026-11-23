-- v12: roles combinables para el personal (Cocina, Bar, Caja)
-- El mesero sigue igual. El personal de "estación" (rol 'cocina') ahora tiene permisos: cocina, bar y/o caja.
-- Ej.: Bar + Caja, Cocina + Caja, solo Caja. Los usuarios que ya existían quedan con los tres (como antes).

alter table public.personal add column if not exists permisos text[];
update public.personal set permisos = array['cocina', 'bar', 'caja'] where rol = 'cocina' and permisos is null;
alter table public.personal drop constraint if exists personal_permisos_check;
alter table public.personal add constraint personal_permisos_check
  check (permisos is null or (permisos <@ array['cocina', 'bar', 'caja']::text[] and cardinality(permisos) between 1 and 3));

-- ¿el usuario de esta sesión tiene el permiso p? (el dueño tiene todos)
create or replace function public.tiene_permiso(p text) returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((
    select case when x.rol = 'dueno' then true
                when x.rol = 'mesero' then p = 'mesero'
                else p = any(coalesce(c.permisos, array['cocina', 'bar', 'caja'])) end
    from perfiles x left join personal c on c.id = x.personal_id
    where x.user_id = auth.uid() and (x.rol = 'dueno' or c.activo)), false)
$$;
revoke execute on function public.tiene_permiso(text) from public, anon;
grant execute on function public.tiene_permiso(text) to authenticated;

create or replace function public.mis_permisos() returns text[]
language sql stable security definer set search_path = public as $$
  select case when x.rol = 'dueno' then array['mesero', 'cocina', 'bar', 'caja']
              when x.rol = 'mesero' then array['mesero']
              else coalesce(c.permisos, array['cocina', 'bar', 'caja']) end
  from perfiles x left join personal c on c.id = x.personal_id
  where x.user_id = auth.uid() and (x.rol = 'dueno' or c.activo)
$$;
revoke execute on function public.mis_permisos() from public, anon;
grant execute on function public.mis_permisos() to authenticated;

-- ¿puede preparar un pedido de esta estación? (sin estaciones activas, cocina y bar ven todo)
create or replace function public.puede_estacion(p_emp uuid, p_est text) returns boolean
language sql stable security definer set search_path = public as $$
  select case when not coalesce((select estaciones from empresas where id = p_emp), false)
              then tiene_permiso('cocina') or tiene_permiso('bar')
              when coalesce(p_est, 'cocina') = 'bar' then tiene_permiso('bar')
              else tiene_permiso('cocina') end
$$;
revoke execute on function public.puede_estacion(uuid, text) from public, anon;
grant execute on function public.puede_estacion(uuid, text) to authenticated;

-- caja: lectura solo para quien tiene permiso de caja
drop policy if exists cob_sel on public.cobros;
create policy cob_sel on public.cobros for select using (empresa_id = (select mi_empresa()) and (select tiene_permiso('caja')));
drop policy if exists cpa_sel on public.cobro_pagos;
create policy cpa_sel on public.cobro_pagos for select using (empresa_id = (select mi_empresa()) and (select tiene_permiso('caja')));
drop policy if exists caj_sel on public.cajas;
create policy caj_sel on public.cajas for select using (empresa_id = (select mi_empresa()) and (select tiene_permiso('caja')));
drop policy if exists cmv_sel on public.caja_movs;
create policy cmv_sel on public.caja_movs for select using (empresa_id = (select mi_empresa()) and (select tiene_permiso('caja')));

-- abrir/cerrar caja, movimientos y cobrar: requieren permiso de caja
do $$
declare f text; d text; n text;
begin
  foreach f in array array['abrir_caja(integer,jsonb)', 'cerrar_caja(integer,jsonb,text)', 'mov_caja(text,integer,text)'] loop
    d := pg_get_functiondef(('public.' || f)::regprocedure);
    n := replace(d, $q$mi_rol() not in ('dueno', 'cocina')$q$, $q$not tiene_permiso('caja')$q$);
    if n = d then raise exception 'No se pudo ajustar %', f; end if;
    execute n;
  end loop;
  d := pg_get_functiondef('public.cobrar_mesa(uuid,text,integer,integer,integer,jsonb,text)'::regprocedure);
  n := replace(d, $q$if v_rol not in ('cocina', 'dueno') then$q$, $q$if not tiene_permiso('caja') then$q$);
  if n = d then raise exception 'No se pudo ajustar cobrar_mesa'; end if;
  execute n;
end $$;

-- cambiar estado: preparar/listo según la estación del pedido
create or replace function public.cambiar_estado(p_id uuid, p_estado text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_emp uuid := mi_empresa(); v_rol text := mi_rol(); p pedidos; v_quien text;
begin
  if v_emp is null then raise exception 'Sesión no válida'; end if;
  select * into p from pedidos where id = p_id and empresa_id = v_emp for update;
  if not found then raise exception 'Pedido no encontrado'; end if;
  select coalesce(c.usuario, 'Dueño') into v_quien from perfiles x left join personal c on c.id = x.personal_id where x.user_id = auth.uid();

  if p_estado in ('nuevo', 'preparando', 'listo') then
    if not puede_estacion(v_emp, p.estacion) then
      raise exception 'Solo % puede cambiar este pedido', case when coalesce(p.estacion, 'cocina') = 'bar' then 'el bar' else 'la cocina' end;
    end if;
    if p.estado not in ('nuevo', 'preparando', 'listo') then raise exception 'Ese pedido ya fue %', p.estado; end if;
  elsif p_estado = 'entregado' then
    if p.estado not in ('listo', 'preparando', 'nuevo') then raise exception 'Ese pedido ya fue %', p.estado; end if;
    if p.estado <> 'listo' and v_rol = 'mesero' then raise exception 'El pedido aún no está listo'; end if;
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

  if p_estado = 'cancelado' then
    update productos pr set stock = pr.stock + x.cant
    from (select producto_id, sum(cant)::integer cant from pedido_items where pedido_id = p_id group by producto_id) x
    where pr.id = x.producto_id and pr.empresa_id = v_emp and pr.stock is not null;
  end if;
  return jsonb_build_object('ok', true, 'estado', p_estado);
end $$;

-- crear y editar personal con permisos
create or replace function public.limpiar_permisos(p_rol text, p_permisos text[]) returns text[]
language plpgsql immutable as $$
declare r text[];
begin
  if p_rol = 'mesero' then return null; end if;
  select array_agg(distinct x order by x) into r from unnest(coalesce(p_permisos, array['cocina', 'bar', 'caja'])) x where x in ('cocina', 'bar', 'caja');
  if r is null or cardinality(r) = 0 then raise exception 'Elige al menos una función: Cocina, Bar o Caja'; end if;
  return r;
end $$;

drop function if exists public.crear_personal(text, text);
create or replace function public.crear_personal(p_usuario text, p_rol text, p_permisos text[] default null)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare v_emp uuid := mi_empresa(); v_pin text; v_id uuid; v_usr text := regexp_replace(btrim(coalesce(p_usuario, '')), '\s+', ' ', 'g'); v_per text[];
begin
  if v_emp is null or not es_dueno() then raise exception 'Solo el dueño puede crear usuarios'; end if;
  if p_rol not in ('mesero', 'cocina') then raise exception 'Rol no válido'; end if;
  v_per := limpiar_permisos(p_rol, p_permisos);
  if length(v_usr) < 2 or length(v_usr) > 30 then raise exception 'Escribe un usuario de 2 a 30 letras'; end if;
  if exists (select 1 from personal where empresa_id = v_emp and lower(btrim(usuario)) = lower(v_usr)) then
    raise exception 'Ya existe un usuario con ese nombre';
  end if;
  if (select count(*) from personal where empresa_id = v_emp) >= 60 then raise exception 'Llegaste al máximo de usuarios'; end if;
  v_pin := generar_pin(v_emp);
  insert into personal (empresa_id, usuario, rol, permisos, pin_hash) values (v_emp, v_usr, p_rol, v_per, extensions.crypt(v_pin, extensions.gen_salt('bf', 8)))
  returning id into v_id;
  return jsonb_build_object('id', v_id, 'usuario', v_usr, 'rol', p_rol, 'permisos', v_per, 'pin', v_pin);
end $$;
revoke execute on function public.crear_personal(text, text, text[]) from public, anon;
grant execute on function public.crear_personal(text, text, text[]) to authenticated;

drop function if exists public.editar_personal(uuid, text, text, boolean);
create or replace function public.editar_personal(p_id uuid, p_usuario text, p_rol text, p_activo boolean, p_permisos text[] default null)
returns void language plpgsql security definer set search_path = public as $$
declare v_emp uuid := mi_empresa(); c personal; v_usr text := regexp_replace(btrim(coalesce(p_usuario, '')), '\s+', ' ', 'g'); v_per text[];
begin
  if v_emp is null or not es_dueno() then raise exception 'Solo el dueño puede editar usuarios'; end if;
  select * into c from personal where id = p_id and empresa_id = v_emp;
  if not found then raise exception 'Usuario no encontrado'; end if;
  if p_rol not in ('mesero', 'cocina') then raise exception 'Rol no válido'; end if;
  v_per := limpiar_permisos(p_rol, coalesce(p_permisos, c.permisos));
  if length(v_usr) < 2 or length(v_usr) > 30 then raise exception 'Escribe un usuario de 2 a 30 letras'; end if;
  if exists (select 1 from personal where empresa_id = v_emp and id <> p_id and lower(btrim(usuario)) = lower(v_usr)) then
    raise exception 'Ya existe un usuario con ese nombre';
  end if;
  update personal set usuario = v_usr, rol = p_rol, permisos = v_per, activo = p_activo,
    intentos = case when p_activo then 0 else intentos end,
    bloqueado_hasta = case when p_activo then null else bloqueado_hasta end
  where id = p_id;
  if not p_activo or p_rol <> c.rol then delete from perfiles where personal_id = p_id; end if;
  -- sus avisos se ajustan a las funciones nuevas
  update push_subs set cocina = coalesce(p_rol = 'cocina' and (v_per && array['cocina', 'bar']), false), caja = coalesce(p_rol = 'cocina' and 'caja' = any(v_per), false),
    estacion = case when p_rol = 'cocina' and 'cocina' = any(v_per) and not 'bar' = any(v_per) then 'cocina'
                    when p_rol = 'cocina' and 'bar' = any(v_per) and not 'cocina' = any(v_per) then 'bar' else estacion end
  where personal_id = p_id;
end $$;
revoke execute on function public.editar_personal(uuid, text, text, boolean, text[]) from public, anon;
grant execute on function public.editar_personal(uuid, text, text, boolean, text[]) to authenticated;

-- avisos: quién recibe pedidos nuevos (cocina/bar) y quién las cuentas (caja)
alter table public.push_subs add column if not exists cocina boolean not null default true;
alter table public.push_subs add column if not exists caja boolean not null default true;
update public.push_subs set cocina = false, caja = false where rol = 'mesero';

create or replace function public.guardar_push(p_endpoint text, p_p256dh text, p_auth text, p_estacion text default null)
returns void language plpgsql security definer set search_path = public as $$
declare v_emp uuid := mi_empresa(); v_rol text := mi_rol(); v_per uuid; v_p text[] := mis_permisos(); v_est text := p_estacion;
begin
  if v_emp is null then raise exception 'Sesión no válida'; end if;
  if coalesce(p_endpoint, '') !~ '^https://' or length(p_endpoint) > 1000 then raise exception 'Suscripción no válida'; end if;
  if v_est is not null and v_est not in ('cocina', 'bar') then v_est := null; end if;
  if 'cocina' = any(v_p) and not 'bar' = any(v_p) then v_est := 'cocina'; end if;
  if 'bar' = any(v_p) and not 'cocina' = any(v_p) then v_est := 'bar'; end if;
  select personal_id into v_per from perfiles where user_id = auth.uid();
  insert into push_subs (empresa_id, user_id, personal_id, rol, endpoint, p256dh, auth, estacion, cocina, caja)
  values (v_emp, auth.uid(), v_per, v_rol, p_endpoint, left(p_p256dh, 200), left(p_auth, 100), v_est,
          v_p && array['cocina', 'bar'], 'caja' = any(v_p))
  on conflict (endpoint) do update set empresa_id = excluded.empresa_id, user_id = excluded.user_id,
    personal_id = excluded.personal_id, rol = excluded.rol, p256dh = excluded.p256dh, auth = excluded.auth,
    estacion = excluded.estacion, cocina = excluded.cocina, caja = excluded.caja, actualizado = now();
end $$;
