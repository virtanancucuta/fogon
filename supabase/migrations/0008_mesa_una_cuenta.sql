-- una mesa no puede tener dos cuentas abiertas a la vez (mapa del salon inequivoco)
create or replace function crear_pedido_mesa(p_mesa text, p_items jsonb)
returns jsonb language plpgsql security definer set search_path = public
as $$
declare
  v_rol rol_equipo; v_emp uuid;
  v_pedido uuid; v_comanda uuid; v_total int := 0;
  v_item jsonb; v_prod uuid; v_qty int; v_precio int; v_nombre text; v_mesa text := nullif(btrim(p_mesa),'');
begin
  select id, rol into v_emp, v_rol from empleados where auth_user_id = auth.uid() and activo limit 1;
  if v_rol not in ('mesera','admin') then raise exception 'solo mesera o admin'; end if;
  if p_items is null or jsonb_array_length(p_items) = 0 then raise exception 'pedido sin items'; end if;
  if v_mesa is null then raise exception 'falta la mesa'; end if;
  if exists (select 1 from pedidos where tipo='mesa' and mesa_numero = v_mesa and estado in ('confirmado','en_proceso','listo')) then
    raise exception 'esa mesa ya tiene un pedido abierto';
  end if;
  insert into pedidos (tipo, canal, estado, mesa_numero, mesera_id, total)
  values ('mesa','mesera','confirmado', v_mesa, v_emp, 0) returning id into v_pedido;
  insert into comandas (pedido_id, tanda, estado) values (v_pedido, 1, 'pendiente') returning id into v_comanda;
  for v_item in select * from jsonb_array_elements(p_items) loop
    v_prod := nullif(v_item->>'producto_id','')::uuid;
    v_qty := greatest(1, coalesce((v_item->>'qty')::int,1));
    select precio into v_precio from productos where id = v_prod;
    if v_precio is null then v_precio := coalesce((v_item->>'precio')::int,0); end if;
    v_nombre := coalesce(nullif(btrim(v_item->>'nombre'),''),'Item');
    insert into comanda_items (comanda_id, producto_id, nombre_snap, precio_snap, qty, subtotal)
    values (v_comanda, v_prod, v_nombre, v_precio, v_qty, v_precio*v_qty);
    v_total := v_total + v_precio*v_qty;
  end loop;
  update pedidos set total = v_total where id = v_pedido;
  insert into pedido_eventos (pedido_id, estado_nuevo, actor_id, actor_rol, meta)
  values (v_pedido, 'confirmado', v_emp, v_rol, jsonb_build_object('accion','crear_mesa','mesa',v_mesa));
  return jsonb_build_object('ok',true,'pedido_id',v_pedido,'codigo',upper(right(v_pedido::text,4)),'total',v_total);
end; $$;
grant execute on function crear_pedido_mesa(text, jsonb) to authenticated;
