-- DL COMANDA PRO v1.4 — Estaciones: cocina y bar
-- Si el dueño las activa, cada pedido se divide: los platos van a Cocina y las bebidas al Bar,
-- cada uno con su propio tablero, su aviso y su "listo".

alter table public.empresas add column if not exists estaciones boolean not null default false;
alter table public.productos add column if not exists estacion text check (estacion in ('cocina', 'bar'));
alter table public.pedidos add column if not exists estacion text not null default 'cocina' check (estacion in ('cocina', 'bar'));
alter table public.push_subs add column if not exists estacion text check (estacion in ('cocina', 'bar'));

-- Estación por defecto según la categoría (bebidas, licores, cocteles… → bar)
create or replace function public.estacion_por_defecto() returns trigger
language plpgsql set search_path = public as $$
begin
  if new.estacion is null then
    new.estacion := case when norm_txt(new.categoria) ~ '(bebida|licor|trago|coctel|cocktail|cerveza|vino|jugo|gaseosa|cafe)' then 'bar' else 'cocina' end;
  end if;
  return new;
end $$;
drop trigger if exists estacion_por_defecto on public.productos;
create trigger estacion_por_defecto before insert or update of estacion, categoria on public.productos
  for each row execute function public.estacion_por_defecto();
update public.productos set estacion = null where estacion is null;   -- aplica el valor por defecto a los que ya existen

create or replace function public.config_estaciones(p_activar boolean)
returns void language plpgsql security definer set search_path = public as $$
begin
  if mi_empresa() is null or not es_dueno() then raise exception 'Solo el dueño puede cambiar esto'; end if;
  update empresas set estaciones = coalesce(p_activar, false) where id = mi_empresa();
end $$;

-- Crear pedido: valida stock y, con estaciones activas, separa cocina y bar
create or replace function public.crear_pedido(p_mesa uuid, p_items jsonb, p_nota text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_emp uuid := mi_empresa(); m mesas; v_split boolean; v_mesero_id uuid; v_mesero text;
        it jsonb; pr productos; v_cant integer; v_est text; v_pid uuid; v_num integer; v_tot integer;
        v_ids jsonb := '[]'::jsonb; v_nota text := nullif(left(btrim(coalesce(p_nota, '')), 300), '');
        v_list jsonb := '[]'::jsonb; st text;
begin
  if v_emp is null then raise exception 'Sesión no válida'; end if;
  select * into m from mesas where id = p_mesa and empresa_id = v_emp;
  if not found then raise exception 'Mesa no válida'; end if;
  if jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) = 0 then raise exception 'El pedido está vacío'; end if;
  if jsonb_array_length(p_items) > 80 then raise exception 'Demasiados productos en un solo pedido'; end if;

  select c.id, c.usuario into v_mesero_id, v_mesero
  from perfiles p join personal c on c.id = p.personal_id where p.user_id = auth.uid();
  if v_mesero is null then v_mesero := 'Dueño'; end if;

  select estaciones into v_split from empresas where id = v_emp for update;   -- numeración del día sin choques

  -- 1) validar y descontar stock
  for it in select * from jsonb_array_elements(p_items) loop
    select * into pr from productos where id = (it->>'pid')::uuid and empresa_id = v_emp and activo for update;
    if not found then raise exception 'Un producto ya no está disponible. Actualiza el menú.'; end if;
    v_cant := coalesce((it->>'cant')::integer, 0);
    if v_cant < 1 or v_cant > 99 then raise exception 'Cantidad no válida en %', pr.nombre; end if;
    if pr.stock is not null then
      if pr.stock < v_cant then
        if pr.stock = 0 then raise exception '% está agotado. Ya no está disponible.', pr.nombre; end if;
        raise exception 'No hay suficiente %: solo quedan %. Ya no está disponible esa cantidad.', pr.nombre, pr.stock;
      end if;
      update productos set stock = stock - v_cant where id = pr.id;
    end if;
    v_list := v_list || jsonb_build_object('pid', pr.id, 'nombre', pr.nombre, 'precio', pr.precio, 'cant', v_cant,
      'nota', nullif(left(btrim(coalesce(it->>'nota', '')), 160), ''), 'est', case when v_split then coalesce(pr.estacion, 'cocina') else 'cocina' end,
      'ord', jsonb_array_length(v_list));
  end loop;

  -- 2) un pedido por estación
  for st in select distinct x->>'est' from jsonb_array_elements(v_list) x order by 1 desc loop   -- 'cocina' primero, luego 'bar'
    select coalesce(max(numero), 0) + 1 into v_num from pedidos where empresa_id = v_emp and fecha = hoy();
    insert into pedidos (empresa_id, numero, fecha, mesa_id, mesa, mesero_id, mesero, nota, estacion)
    values (v_emp, v_num, hoy(), m.id, m.nombre, v_mesero_id, v_mesero, v_nota, st)
    returning id into v_pid;
    insert into pedido_items (pedido_id, empresa_id, producto_id, nombre, precio, cant, nota)
    select v_pid, v_emp, r.pid, r.nombre, r.precio, r.cant, r.nota
    from jsonb_to_recordset(v_list) as r(pid uuid, nombre text, precio integer, cant integer, nota text, est text, ord integer)
    where r.est = st order by r.ord;
    select coalesce(sum(precio * cant), 0) into v_tot from pedido_items where pedido_id = v_pid;
    update pedidos set total = v_tot where id = v_pid;
    v_ids := v_ids || jsonb_build_object('id', v_pid, 'numero', v_num, 'estacion', st, 'total', v_tot);
  end loop;

  return jsonb_build_object('id', v_ids->0->>'id', 'numero', (v_ids->0->>'numero')::integer,
    'total', (select sum((x->>'total')::integer) from jsonb_array_elements(v_ids) x), 'pedidos', v_ids);
end $$;

-- Avisos push: cada celular de cocina puede escoger su estación
drop function if exists public.guardar_push(text, text, text);
create or replace function public.guardar_push(p_endpoint text, p_p256dh text, p_auth text, p_estacion text default null)
returns void language plpgsql security definer set search_path = public as $$
declare v_emp uuid := mi_empresa(); v_rol text := mi_rol(); v_per uuid;
begin
  if v_emp is null then raise exception 'Sesión no válida'; end if;
  if coalesce(p_endpoint, '') !~ '^https://' or length(p_endpoint) > 1000 then raise exception 'Suscripción no válida'; end if;
  if p_estacion is not null and p_estacion not in ('cocina', 'bar') then p_estacion := null; end if;
  select personal_id into v_per from perfiles where user_id = auth.uid();
  insert into push_subs (empresa_id, user_id, personal_id, rol, endpoint, p256dh, auth, estacion)
  values (v_emp, auth.uid(), v_per, v_rol, p_endpoint, left(p_p256dh, 200), left(p_auth, 100), p_estacion)
  on conflict (endpoint) do update set empresa_id = excluded.empresa_id, user_id = excluded.user_id,
    personal_id = excluded.personal_id, rol = excluded.rol, p256dh = excluded.p256dh, auth = excluded.auth,
    estacion = excluded.estacion, actualizado = now();
end $$;

revoke execute on function public.config_estaciones(boolean) from public, anon;
revoke execute on function public.guardar_push(text, text, text, text) from public, anon;
revoke execute on function public.estacion_por_defecto() from public, anon, authenticated;
grant execute on function public.config_estaciones(boolean) to authenticated;
grant execute on function public.guardar_push(text, text, text, text) to authenticated;
grant execute on function public.crear_pedido(uuid, jsonb, text) to authenticated;
