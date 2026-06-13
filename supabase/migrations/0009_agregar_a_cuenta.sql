-- 0009_agregar_a_cuenta — multi-tanda: agregar una ronda a una mesa abierta.
-- Cada ronda = comanda nueva (ticket de cocina). La cocina pasa a trabajar POR COMANDA;
-- el estado del pedido se DERIVA de sus comandas. Total del pedido = suma de todas las tandas.

-- estado del pedido derivado de sus comandas (no toca terminales ni por_confirmar)
create or replace function recalc_estado_pedido(p_pedido_id uuid)
returns void language plpgsql security definer set search_path = public
as $$
declare v_estado estado_pedido; v_tot int; v_ent int; v_proc int;
begin
  select estado into v_estado from pedidos where id = p_pedido_id;
  if v_estado is null or v_estado in ('cobrado','enviado','cancelado','por_confirmar') then return; end if;
  select count(*), count(*) filter (where estado='entregado'), count(*) filter (where estado='en_proceso')
    into v_tot, v_ent, v_proc from comandas where pedido_id = p_pedido_id;
  if v_tot = 0 then return; end if;
  if v_tot = v_ent then update pedidos set estado='listo' where id = p_pedido_id;
  elsif v_proc > 0 then update pedidos set estado='en_proceso' where id = p_pedido_id;
  else update pedidos set estado='confirmado' where id = p_pedido_id;
  end if;
end; $$;

-- cocina avanza UNA comanda (ticket): pendiente -> en_proceso -> entregado; recalcula el pedido
create or replace function cocina_comanda(p_comanda_id uuid, p_a text)
returns jsonb language plpgsql security definer set search_path = public
as $$
declare v_rol rol_equipo; v_emp uuid; v_ped uuid; v_cest estado_comanda; v_a estado_comanda := p_a::estado_comanda;
begin
  select id, rol into v_emp, v_rol from empleados where auth_user_id = auth.uid() and activo limit 1;
  if v_rol not in ('cocina','admin') then raise exception 'solo cocina o admin'; end if;
  select pedido_id, estado into v_ped, v_cest from comandas where id = p_comanda_id for update;
  if v_ped is null then raise exception 'comanda inexistente'; end if;
  if not ((v_cest='pendiente' and v_a='en_proceso') or (v_cest='en_proceso' and v_a='entregado')) then
    raise exception 'transicion de cocina no permitida: % a %', v_cest, v_a;
  end if;
  if v_a='en_proceso' then update comandas set estado='en_proceso', en_proceso_at=now() where id=p_comanda_id;
  else update comandas set estado='entregado', entregada_at=now() where id=p_comanda_id; end if;
  perform recalc_estado_pedido(v_ped);
  insert into pedido_eventos (pedido_id, estado_nuevo, actor_id, actor_rol, meta)
  values (v_ped, (select estado from pedidos where id=v_ped), v_emp, v_rol, jsonb_build_object('comanda',p_comanda_id,'comanda_estado',v_a::text));
  return jsonb_build_object('ok',true);
end; $$;
grant execute on function cocina_comanda(uuid, text) to authenticated;

-- agregar una ronda a una mesa abierta (nueva tanda) + recalcular total y estado
create or replace function agregar_a_cuenta(p_pedido_id uuid, p_items jsonb)
returns jsonb language plpgsql security definer set search_path = public
as $$
declare
  v_rol rol_equipo; v_emp uuid; v_tipo tipo_pedido; v_estado estado_pedido;
  v_comanda uuid; v_tanda int; v_item jsonb; v_prod uuid; v_qty int; v_precio int; v_nombre text; v_total int;
begin
  select id, rol into v_emp, v_rol from empleados where auth_user_id = auth.uid() and activo limit 1;
  if v_rol not in ('mesera','admin') then raise exception 'solo mesera o admin'; end if;
  if p_items is null or jsonb_array_length(p_items) = 0 then raise exception 'sin items'; end if;
  select tipo, estado into v_tipo, v_estado from pedidos where id = p_pedido_id for update;
  if v_estado is null then raise exception 'pedido inexistente'; end if;
  if v_tipo <> 'mesa' then raise exception 'agregar a la cuenta es solo para mesas'; end if;
  if v_estado not in ('confirmado','en_proceso','listo') then raise exception 'la cuenta no esta abierta'; end if;

  select coalesce(max(tanda),0)+1 into v_tanda from comandas where pedido_id = p_pedido_id;
  insert into comandas (pedido_id, tanda, estado) values (p_pedido_id, v_tanda, 'pendiente') returning id into v_comanda;
  for v_item in select * from jsonb_array_elements(p_items) loop
    v_prod := nullif(v_item->>'producto_id','')::uuid;
    v_qty := greatest(1, coalesce((v_item->>'qty')::int,1));
    select precio into v_precio from productos where id = v_prod;
    if v_precio is null then v_precio := coalesce((v_item->>'precio')::int,0); end if;
    v_nombre := coalesce(nullif(btrim(v_item->>'nombre'),''),'Item');
    insert into comanda_items (comanda_id, producto_id, nombre_snap, precio_snap, qty, subtotal)
    values (v_comanda, v_prod, v_nombre, v_precio, v_qty, v_precio*v_qty);
  end loop;
  select coalesce(sum(ci.subtotal),0) into v_total from comanda_items ci join comandas c on c.id=ci.comanda_id where c.pedido_id = p_pedido_id;
  update pedidos set total = v_total where id = p_pedido_id;
  perform recalc_estado_pedido(p_pedido_id);
  insert into pedido_eventos (pedido_id, estado_nuevo, actor_id, actor_rol, meta)
  values (p_pedido_id, (select estado from pedidos where id=p_pedido_id), v_emp, v_rol, jsonb_build_object('accion','agregar_ronda','tanda',v_tanda));
  return jsonb_build_object('ok',true,'tanda',v_tanda,'total',v_total);
end; $$;
grant execute on function agregar_a_cuenta(uuid, jsonb) to authenticated;
