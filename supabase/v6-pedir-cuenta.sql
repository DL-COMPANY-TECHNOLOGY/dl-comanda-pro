-- DL COMANDA PRO v1.6 — Pedir la cuenta con propina voluntaria preguntada al cliente
-- El mesero pide la cuenta y registra si el cliente ACEPTA o NO la propina voluntaria del 10%.
-- Caja recibe el aviso y cobra con esa respuesta ya cargada.

alter table public.mesas add column if not exists cuenta_en timestamptz;
alter table public.mesas add column if not exists cuenta_propina boolean;
alter table public.mesas add column if not exists cuenta_por text;

create or replace function public.pedir_cuenta(p_mesa uuid, p_propina boolean)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_emp uuid := mi_empresa(); v_quien text; v_n integer;
begin
  if v_emp is null then raise exception 'Sesión no válida'; end if;
  if p_propina is null then raise exception 'Pregúntale al cliente si desea incluir la propina'; end if;
  select count(*) into v_n from pedidos where empresa_id = v_emp and mesa_id = p_mesa and not pagado and estado <> 'cancelado';
  if v_n = 0 then raise exception 'Esa mesa no tiene nada por cobrar'; end if;
  select coalesce(c.usuario, 'Dueño') into v_quien from perfiles x left join personal c on c.id = x.personal_id where x.user_id = auth.uid();
  update mesas set cuenta_en = now(), cuenta_propina = p_propina, cuenta_por = v_quien
  where id = p_mesa and empresa_id = v_emp;
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.anular_cuenta(p_mesa uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  if mi_empresa() is null then raise exception 'Sesión no válida'; end if;
  update mesas set cuenta_en = null, cuenta_propina = null, cuenta_por = null where id = p_mesa and empresa_id = mi_empresa();
end $$;

-- al cobrar, la mesa queda libre y sin cuenta pedida
create or replace function public.limpiar_cuenta_mesa() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  update mesas set cuenta_en = null, cuenta_propina = null, cuenta_por = null where id = new.mesa_id;
  return new;
end $$;
drop trigger if exists limpiar_cuenta_mesa on public.cobros;
create trigger limpiar_cuenta_mesa after insert on public.cobros for each row execute function public.limpiar_cuenta_mesa();

-- al cambiar / juntar mesas, la cuenta pedida viaja con los pedidos
create or replace function public.mover_mesa(p_origen uuid, p_destino uuid)
returns integer language plpgsql security definer set search_path = public as $$
declare v_emp uuid := mi_empresa(); d mesas; o mesas; n integer;
begin
  if v_emp is null then raise exception 'Sesión no válida'; end if;
  if p_origen = p_destino then raise exception 'Escoge otra mesa'; end if;
  select * into d from mesas where id = p_destino and empresa_id = v_emp and activa;
  if not found then raise exception 'Mesa de destino no válida'; end if;
  select * into o from mesas where id = p_origen and empresa_id = v_emp;
  update pedidos set mesa_id = d.id, mesa = d.nombre, actualizado = now()
  where empresa_id = v_emp and mesa_id = p_origen and not pagado and estado <> 'cancelado';
  get diagnostics n = row_count;
  if n = 0 then raise exception 'Esa mesa no tiene pedidos abiertos'; end if;
  if o.cuenta_en is not null and d.cuenta_en is null then
    update mesas set cuenta_en = o.cuenta_en, cuenta_propina = o.cuenta_propina, cuenta_por = o.cuenta_por where id = d.id;
  end if;
  update mesas set cuenta_en = null, cuenta_propina = null, cuenta_por = null where id = p_origen;
  return n;
end $$;

-- aviso push a caja cuando una mesa pide la cuenta
create or replace function public.avisar_cuenta() returns trigger
language plpgsql security definer set search_path = public, extensions as $$
declare v_url text; v_sec text;
begin
  if new.cuenta_en is null or new.cuenta_en is not distinct from old.cuenta_en then return new; end if;
  if not exists (select 1 from push_subs where empresa_id = new.empresa_id and rol = 'cocina') then return new; end if;
  select valor into v_url from config_privada where clave = 'push_url';
  select valor into v_sec from config_privada where clave = 'hook_secret';
  if v_url is null or v_sec is null then return new; end if;
  perform net.http_post(url := v_url, body := jsonb_build_object('tipo', 'cuenta', 'mesa_id', new.id),
    headers := jsonb_build_object('Content-Type', 'application/json', 'x-hook-secret', v_sec), timeout_milliseconds := 8000);
  return new;
exception when others then return new;
end $$;
drop trigger if exists avisar_cuenta on public.mesas;
create trigger avisar_cuenta after update of cuenta_en on public.mesas for each row execute function public.avisar_cuenta();

revoke execute on function public.pedir_cuenta(uuid, boolean) from public, anon;
revoke execute on function public.anular_cuenta(uuid) from public, anon;
revoke execute on function public.limpiar_cuenta_mesa() from public, anon, authenticated;
revoke execute on function public.avisar_cuenta() from public, anon, authenticated;
grant execute on function public.pedir_cuenta(uuid, boolean) to authenticated;
grant execute on function public.anular_cuenta(uuid) to authenticated;
grant execute on function public.mover_mesa(uuid, uuid) to authenticated;
