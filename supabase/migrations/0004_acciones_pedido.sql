-- 0004_acciones_pedido — Fase 2C: máquina de estados de pedidos domicilio + modificar
-- Modelo domicilio: paga al CONFIRMAR (pagado_at), cierra/venta al ENVIAR (cerrado_at).
-- NO se usa 'cobrado' en domicilio. Cada transición registra pedido_eventos (actor=empleado).
-- SECURITY DEFINER + guard es_staff(). Params enum como text (robustez con PostgREST).

create or replace function transicion_pedido(
  p_pedido_id uuid,
  p_a         text,
  p_medio     text default null,
  p_repartidor uuid default null
) returns jsonb
language plpgsql security definer set search_path = public
as $$
declare
  v_actual estado_pedido;
  v_a      estado_pedido := p_a::estado_pedido;
  v_medio  medio_pago := nullif(p_medio,'')::medio_pago;
  v_emp    uuid;
  v_rol    rol_equipo;
  v_ok     boolean;
begin
  if not es_staff() then raise exception 'no autorizado'; end if;
  select id, rol into v_emp, v_rol from empleados where auth_user_id = auth.uid() and activo limit 1;
  select estado into v_actual from pedidos where id = p_pedido_id for update;
  if v_actual is null then raise exception 'pedido inexistente'; end if;

  v_ok := (v_actual='por_confirmar' and v_a in ('confirmado','cancelado'))
       or (v_actual='confirmado'    and v_a in ('en_proceso','cancelado'))
       or (v_actual='en_proceso'    and v_a in ('listo','cancelado'))
       or (v_actual='listo'         and v_a in ('enviado','cancelado'));
  if not v_ok then raise exception 'transicion no permitida: % a %', v_actual, v_a; end if;

  if v_a = 'confirmado' then
    if v_medio is null then raise exception 'falta medio de pago'; end if;
    update pedidos set estado='confirmado', medio_pago=v_medio, pagado_at=now() where id=p_pedido_id;
  elsif v_a = 'enviado' then
    if p_repartidor is null then raise exception 'falta domiciliario'; end if;
    update pedidos set estado='enviado', repartidor_id=p_repartidor, enviado_at=now(), cerrado_at=now() where id=p_pedido_id;
  else
    update pedidos set estado=v_a where id=p_pedido_id;
  end if;

  insert into pedido_eventos (pedido_id, estado_nuevo, actor_id, actor_rol, meta)
  values (p_pedido_id, v_a, v_emp, v_rol, jsonb_build_object('medio_pago', v_medio, 'repartidor_id', p_repartidor));

  return jsonb_build_object('ok', true, 'estado', v_a::text);
end;
$$;
grant execute on function transicion_pedido(uuid, text, text, uuid) to authenticated;

-- Modificar ítems (solo en por_confirmar): reemplaza los ítems de la comanda y recalcula total.
create or replace function modificar_pedido(p_pedido_id uuid, p_items jsonb)
returns jsonb
language plpgsql security definer set search_path = public
as $$
declare
  v_actual estado_pedido;
  v_comanda uuid;
  v_emp uuid; v_rol rol_equipo;
  v_item jsonb; v_prod uuid; v_qty int; v_precio int; v_nombre text; v_total int := 0;
begin
  if not es_staff() then raise exception 'no autorizado'; end if;
  select id, rol into v_emp, v_rol from empleados where auth_user_id = auth.uid() and activo limit 1;
  select estado into v_actual from pedidos where id = p_pedido_id for update;
  if v_actual is null then raise exception 'pedido inexistente'; end if;
  if v_actual <> 'por_confirmar' then raise exception 'solo se puede modificar un pedido por confirmar'; end if;
  if p_items is null or jsonb_array_length(p_items) = 0 then raise exception 'el pedido no puede quedar vacio'; end if;

  select id into v_comanda from comandas where pedido_id = p_pedido_id order by tanda limit 1;
  if v_comanda is null then
    insert into comandas (pedido_id, tanda, estado) values (p_pedido_id, 1, 'pendiente') returning id into v_comanda;
  end if;
  delete from comanda_items where comanda_id = v_comanda;

  for v_item in select * from jsonb_array_elements(p_items) loop
    v_prod := nullif(v_item->>'producto_id','')::uuid;
    v_qty  := greatest(1, coalesce((v_item->>'qty')::int, 1));
    select precio into v_precio from productos where id = v_prod;
    if v_precio is null then v_precio := coalesce((v_item->>'precio')::int, 0); end if;
    v_nombre := coalesce(nullif(btrim(v_item->>'nombre'),''), 'Item');
    insert into comanda_items (comanda_id, producto_id, nombre_snap, precio_snap, qty, subtotal)
    values (v_comanda, v_prod, v_nombre, v_precio, v_qty, v_precio * v_qty);
    v_total := v_total + v_precio * v_qty;
  end loop;

  update pedidos set total = v_total where id = p_pedido_id;
  insert into pedido_eventos (pedido_id, estado_nuevo, actor_id, actor_rol, meta)
  values (p_pedido_id, 'por_confirmar', v_emp, v_rol, jsonb_build_object('accion','modificar','total',v_total));

  return jsonb_build_object('ok', true, 'total', v_total);
end;
$$;
grant execute on function modificar_pedido(uuid, jsonb) to authenticated;
