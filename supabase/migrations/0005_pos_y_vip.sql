-- 0005_pos_y_vip — POS mesera/cocina + cobro de mesa + Carnet VIP
-- Modelo:
--   MESA: mesera crea (estado=confirmado, va a cocina) -> cocina en_proceso -> listo
--         -> se COBRA aparte (medio_pago + cerrado_at) = venta (estado=cobrado).
--   DOMICILIO: admin confirma+cobra -> cocina en_proceso -> listo -> admin envia (cerrado) = venta.
--   Cocina maneja en_proceso/listo de AMBOS (y la comanda). Cada cambio -> pedido_eventos.
-- Guards por rol con rol_actual(); SECURITY DEFINER; enum como text.

-- ============ MESERA: crear pedido de mesa ============
create or replace function crear_pedido_mesa(p_mesa text, p_items jsonb)
returns jsonb language plpgsql security definer set search_path = public
as $$
declare
  v_rol rol_equipo; v_emp uuid;
  v_pedido uuid; v_comanda uuid; v_total int := 0;
  v_item jsonb; v_prod uuid; v_qty int; v_precio int; v_nombre text;
begin
  select id, rol into v_emp, v_rol from empleados where auth_user_id = auth.uid() and activo limit 1;
  if v_rol not in ('mesera','admin') then raise exception 'solo mesera o admin'; end if;
  if p_items is null or jsonb_array_length(p_items) = 0 then raise exception 'pedido sin items'; end if;

  insert into pedidos (tipo, canal, estado, mesa_numero, mesera_id, total)
  values ('mesa','mesera','confirmado', nullif(btrim(p_mesa),''), v_emp, 0)
  returning id into v_pedido;
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
  values (v_pedido, 'confirmado', v_emp, v_rol, jsonb_build_object('accion','crear_mesa','mesa',p_mesa));
  return jsonb_build_object('ok',true,'pedido_id',v_pedido,'codigo',upper(right(v_pedido::text,4)),'total',v_total);
end; $$;
grant execute on function crear_pedido_mesa(text, jsonb) to authenticated;

-- ============ COCINA: avanzar (en_proceso / listo) ============
create or replace function cocina_avanzar(p_pedido_id uuid, p_a text)
returns jsonb language plpgsql security definer set search_path = public
as $$
declare
  v_rol rol_equipo; v_emp uuid; v_actual estado_pedido; v_a estado_pedido := p_a::estado_pedido;
begin
  select id, rol into v_emp, v_rol from empleados where auth_user_id = auth.uid() and activo limit 1;
  if v_rol not in ('cocina','admin') then raise exception 'solo cocina o admin'; end if;
  select estado into v_actual from pedidos where id = p_pedido_id for update;
  if v_actual is null then raise exception 'pedido inexistente'; end if;
  if not ((v_actual='confirmado' and v_a='en_proceso') or (v_actual='en_proceso' and v_a='listo')) then
    raise exception 'transicion de cocina no permitida: % a %', v_actual, v_a;
  end if;
  update pedidos set estado = v_a where id = p_pedido_id;
  if v_a = 'en_proceso' then
    update comandas set estado='en_proceso', en_proceso_at=now() where pedido_id=p_pedido_id;
  else
    update comandas set estado='entregado', entregada_at=now() where pedido_id=p_pedido_id;
  end if;
  insert into pedido_eventos (pedido_id, estado_nuevo, actor_id, actor_rol)
  values (p_pedido_id, v_a, v_emp, v_rol);
  return jsonb_build_object('ok',true,'estado',v_a::text);
end; $$;
grant execute on function cocina_avanzar(uuid, text) to authenticated;

-- ============ COBRAR pedido de MESA (= venta) ============
create or replace function cobrar_pedido(p_pedido_id uuid, p_medio text)
returns jsonb language plpgsql security definer set search_path = public
as $$
declare
  v_rol rol_equipo; v_emp uuid; v_tipo tipo_pedido; v_actual estado_pedido; v_medio medio_pago := p_medio::medio_pago;
begin
  select id, rol into v_emp, v_rol from empleados where auth_user_id = auth.uid() and activo limit 1;
  if v_rol not in ('mesera','admin') then raise exception 'solo mesera o admin'; end if;
  select tipo, estado into v_tipo, v_actual from pedidos where id = p_pedido_id for update;
  if v_actual is null then raise exception 'pedido inexistente'; end if;
  if v_tipo <> 'mesa' then raise exception 'cobrar aplica solo a pedidos de mesa'; end if;
  if v_actual not in ('confirmado','en_proceso','listo') then raise exception 'estado no cobrable: %', v_actual; end if;
  update pedidos set estado='cobrado', medio_pago=v_medio, pagado_at=now(), cerrado_at=now() where id=p_pedido_id;
  insert into pedido_eventos (pedido_id, estado_nuevo, actor_id, actor_rol, meta)
  values (p_pedido_id, 'cobrado', v_emp, v_rol, jsonb_build_object('medio_pago',v_medio));
  return jsonb_build_object('ok',true,'estado','cobrado');
end; $$;
grant execute on function cobrar_pedido(uuid, text) to authenticated;

-- ============ CARNET VIP ============
-- sellar: 1 sello por dia por cliente; tope 30; crea la tarjeta si no existe.
create or replace function sellar_tarjeta(p_cliente_id uuid)
returns jsonb language plpgsql security definer set search_path = public
as $$
declare
  v_rol rol_equipo; v_emp uuid; v_t tarjetas_vip; v_n int;
begin
  select id, rol into v_emp, v_rol from empleados where auth_user_id = auth.uid() and activo limit 1;
  if v_emp is null then raise exception 'solo staff'; end if;
  insert into tarjetas_vip (cliente_id) values (p_cliente_id)
    on conflict (cliente_id) do nothing;
  select * into v_t from tarjetas_vip where cliente_id = p_cliente_id for update;
  if exists (select 1 from sellos_log where cliente_id = p_cliente_id and created_at >= date_trunc('day', now())) then
    raise exception 'ya tiene un sello hoy';
  end if;
  if v_t.sellos >= 30 then raise exception 'la tarjeta ya esta completa (30)'; end if;
  v_n := v_t.sellos + 1;
  update tarjetas_vip set sellos = v_n, updated_at = now() where cliente_id = p_cliente_id;
  insert into sellos_log (tarjeta_id, cliente_id, numero_sello, puesto_por) values (v_t.id, p_cliente_id, v_n, v_emp);
  return jsonb_build_object('ok',true,'sellos',v_n);
end; $$;
grant execute on function sellar_tarjeta(uuid) to authenticated;

-- reclamar premio (15 o 30)
create or replace function reclamar_premio(p_cliente_id uuid, p_cual int)
returns jsonb language plpgsql security definer set search_path = public
as $$
declare v_emp uuid; v_t tarjetas_vip;
begin
  select id into v_emp from empleados where auth_user_id = auth.uid() and activo limit 1;
  if v_emp is null then raise exception 'solo staff'; end if;
  select * into v_t from tarjetas_vip where cliente_id = p_cliente_id for update;
  if v_t is null then raise exception 'sin tarjeta'; end if;
  if p_cual = 15 then
    if v_t.sellos < 15 then raise exception 'aun no llega a 15'; end if;
    if v_t.premio15_reclamado then raise exception 'premio 15 ya reclamado'; end if;
    update tarjetas_vip set premio15_reclamado = true, updated_at = now() where cliente_id = p_cliente_id;
  elsif p_cual = 30 then
    if v_t.sellos < 30 then raise exception 'aun no llega a 30'; end if;
    if v_t.premio30_reclamado then raise exception 'premio 30 ya reclamado'; end if;
    update tarjetas_vip set premio30_reclamado = true, updated_at = now() where cliente_id = p_cliente_id;
  else
    raise exception 'premio invalido';
  end if;
  return jsonb_build_object('ok',true);
end; $$;
grant execute on function reclamar_premio(uuid, int) to authenticated;

-- reiniciar carnet (nuevo ciclo) cuando esta completo
create or replace function reiniciar_carnet(p_cliente_id uuid)
returns jsonb language plpgsql security definer set search_path = public
as $$
declare v_emp uuid; v_t tarjetas_vip;
begin
  select id into v_emp from empleados where auth_user_id = auth.uid() and activo limit 1;
  if v_emp is null then raise exception 'solo staff'; end if;
  select * into v_t from tarjetas_vip where cliente_id = p_cliente_id for update;
  if v_t is null then raise exception 'sin tarjeta'; end if;
  update tarjetas_vip set ciclo = ciclo + 1, sellos = 0, premio15_reclamado = false, premio30_reclamado = false, updated_at = now()
  where cliente_id = p_cliente_id;
  return jsonb_build_object('ok',true,'ciclo',v_t.ciclo + 1);
end; $$;
grant execute on function reiniciar_carnet(uuid) to authenticated;

-- consulta publica del carnet por celular (cliente lo ve con su telefono, sin clave)
create or replace function carnet_por_celular(p_celular text)
returns jsonb language plpgsql security definer set search_path = public stable
as $$
declare v_c clientes; v_t tarjetas_vip;
begin
  select * into v_c from clientes where celular = p_celular limit 1;
  if v_c is null then return jsonb_build_object('existe', false); end if;
  select * into v_t from tarjetas_vip where cliente_id = v_c.id;
  return jsonb_build_object(
    'existe', true,
    'nombre', v_c.nombre,
    'celular', v_c.celular,
    'sellos', coalesce(v_t.sellos, 0),
    'ciclo', coalesce(v_t.ciclo, 1),
    'premio15_reclamado', coalesce(v_t.premio15_reclamado, false),
    'premio30_reclamado', coalesce(v_t.premio30_reclamado, false)
  );
end; $$;
grant execute on function carnet_por_celular(text) to anon, authenticated;
