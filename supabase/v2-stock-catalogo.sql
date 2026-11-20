-- DL COMANDA PRO v1.2 — Código de barras, stock opcional por producto y catálogo común
-- El stock es OPCIONAL: los platos preparados no lo usan (stock = null);
-- bebidas y productos empacados sí (se descuenta al enviar el pedido y vuelve si se cancela).

alter table public.productos add column if not exists codigo text
  check (codigo is null or codigo ~ '^[0-9]{8,14}$');
alter table public.productos add column if not exists stock integer
  check (stock is null or stock >= 0);
alter table public.productos add column if not exists stock_min integer
  check (stock_min is null or stock_min >= 0);
create unique index if not exists productos_codigo_uq
  on public.productos (empresa_id, codigo) where codigo is not null;

-- Crear pedido: valida y descuenta el stock de los productos que lo controlan
create or replace function public.crear_pedido(p_mesa uuid, p_items jsonb, p_nota text default null)
 returns jsonb language plpgsql security definer set search_path to 'public'
as $function$
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

  perform 1 from empresas where id = v_emp for update;
  select coalesce(max(numero), 0) + 1 into v_num from pedidos where empresa_id = v_emp and fecha = hoy();

  insert into pedidos (empresa_id, numero, fecha, mesa_id, mesa, mesero_id, mesero, nota)
  values (v_emp, v_num, hoy(), m.id, m.nombre, v_mesero_id, v_mesero, nullif(left(btrim(coalesce(p_nota, '')), 300), ''))
  returning id into v_pid;

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
    insert into pedido_items (pedido_id, empresa_id, producto_id, nombre, precio, cant, nota)
    values (v_pid, v_emp, pr.id, pr.nombre, pr.precio, v_cant, nullif(left(btrim(coalesce(it->>'nota', '')), 160), ''));
    n := n + 1;
  end loop;

  select coalesce(sum(precio * cant), 0) into v_tot from pedido_items where pedido_id = v_pid;
  update pedidos set total = v_tot where id = v_pid;
  return jsonb_build_object('id', v_pid, 'numero', v_num, 'total', v_tot);
end $function$;

-- Cambiar estado: si se cancela, el stock vuelve
create or replace function public.cambiar_estado(p_id uuid, p_estado text)
 returns jsonb language plpgsql security definer set search_path to 'public'
as $function$
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

  if p_estado = 'cancelado' then
    update productos pr set stock = pr.stock + x.cant
    from (select producto_id, sum(cant)::integer cant from pedido_items where pedido_id = p_id group by producto_id) x
    where pr.id = x.producto_id and pr.empresa_id = v_emp and pr.stock is not null;
  end if;
  return jsonb_build_object('ok', true, 'estado', p_estado);
end $function$;

-- Catálogo común por código de barras (sin precios ni stock)
create table if not exists public.catalogo (
  codigo     text primary key check (codigo ~ '^[0-9]{8,14}$'),
  nombre     text not null check (char_length(nombre) between 3 and 120),
  cat        text check (cat is null or char_length(cat) <= 40),
  creado_por uuid default auth.uid() references auth.users(id) on delete set null,
  creado     timestamptz not null default now()
);
alter table public.catalogo enable row level security;
drop policy if exists catalogo_leer on public.catalogo;
create policy catalogo_leer on public.catalogo for select to authenticated using (true);
drop policy if exists catalogo_agregar on public.catalogo;
create policy catalogo_agregar on public.catalogo for insert to authenticated with check (creado_por = (select auth.uid()));
