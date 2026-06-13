-- 0006_hardening — correcciones de la auditoría (agentes caza-bugs)
-- Cierra: insert directo anon (manipulacion de total), escalada de privilegios en empleados,
-- impersonacion via cliente_id, upsert que pisa nombres, comanda huerfana al cobrar,
-- sello 1-por-dia en zona Bogota, guards de carnet.

-- 1) Quitar INSERT directo de anon: toda creacion va por RPC SECURITY DEFINER (que toma precio de BD)
drop policy if exists clientes_ins_anon on clientes;
drop policy if exists pedidos_ins on pedidos;
drop policy if exists comandas_ins on comandas;
drop policy if exists comanda_items_ins on comanda_items;

-- 2) empleados: lectura para staff, ESCRITURA solo admin (evita que mesera/cocina se auto-asciendan)
drop policy if exists empleados_all_staff on empleados;
create policy empleados_sel_staff on empleados for select to authenticated using (es_staff());
create policy empleados_ins_admin on empleados for insert to authenticated with check (rol_actual() = 'admin');
create policy empleados_upd_admin on empleados for update to authenticated using (rol_actual() = 'admin') with check (rol_actual() = 'admin');
create policy empleados_del_admin on empleados for delete to authenticated using (rol_actual() = 'admin');

-- 3) cliente_upsert: no pisar el nombre de un cliente existente (preserva el que ya hay)
create or replace function cliente_upsert(p_celular text, p_nombre text default null)
returns clientes
language plpgsql security definer set search_path = public
as $$
declare c clientes;
begin
  insert into clientes (celular, nombre) values (p_celular, p_nombre)
  on conflict (celular) do update set nombre = coalesce(clientes.nombre, excluded.nombre)
  returning * into c;
  return c;
end;
$$;
grant execute on function cliente_upsert(text, text) to anon, authenticated;

-- 4) crear_pedido_domicilio: recibe celular (no cliente_id arbitrario); resuelve el cliente adentro
drop function if exists crear_pedido_domicilio(uuid, text, text, jsonb);
create or replace function crear_pedido_domicilio(
  p_celular   text,
  p_nombre    text,
  p_direccion text,
  p_notas     text,
  p_items     jsonb
) returns jsonb
language plpgsql security definer set search_path = public
as $$
declare
  v_cliente uuid; v_pedido uuid; v_comanda uuid; v_total int := 0;
  v_item jsonb; v_prod uuid; v_qty int; v_precio int; v_nombre text;
begin
  if p_items is null or jsonb_array_length(p_items) = 0 then raise exception 'pedido sin items'; end if;
  if coalesce(btrim(p_celular),'') = '' then raise exception 'falta celular'; end if;

  insert into clientes (celular, nombre) values (p_celular, p_nombre)
  on conflict (celular) do update set nombre = coalesce(clientes.nombre, excluded.nombre)
  returning id into v_cliente;

  insert into pedidos (tipo, canal, cliente_id, direccion, notas, total, estado)
  values ('domicilio','whatsapp', v_cliente, nullif(btrim(p_direccion),''), nullif(btrim(p_notas),''), 0, 'por_confirmar')
  returning id into v_pedido;

  insert into comandas (pedido_id, tanda, estado) values (v_pedido, 1, 'pendiente') returning id into v_comanda;

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

  update pedidos set total = v_total where id = v_pedido;
  return jsonb_build_object('ok', true, 'pedido_id', v_pedido, 'codigo', upper(right(v_pedido::text,4)),
    'total', v_total, 'cliente_id', v_cliente);
end;
$$;
grant execute on function crear_pedido_domicilio(text, text, text, text, jsonb) to anon, authenticated;

-- 5) cobrar_pedido: marcar tambien la comanda como entregada (no dejarla huerfana)
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
  update comandas set estado='entregado', entregada_at=coalesce(entregada_at, now()) where pedido_id=p_pedido_id;
  insert into pedido_eventos (pedido_id, estado_nuevo, actor_id, actor_rol, meta)
  values (p_pedido_id, 'cobrado', v_emp, v_rol, jsonb_build_object('medio_pago',v_medio));
  return jsonb_build_object('ok',true,'estado','cobrado');
end; $$;
grant execute on function cobrar_pedido(uuid, text) to authenticated;

-- 6) sellar_tarjeta: 1-por-dia en zona horaria de Colombia (no medianoche UTC)
create or replace function sellar_tarjeta(p_cliente_id uuid)
returns jsonb language plpgsql security definer set search_path = public
as $$
declare
  v_rol rol_equipo; v_emp uuid; v_t tarjetas_vip; v_n int;
begin
  select id, rol into v_emp, v_rol from empleados where auth_user_id = auth.uid() and activo limit 1;
  if v_emp is null then raise exception 'solo staff'; end if;
  insert into tarjetas_vip (cliente_id) values (p_cliente_id) on conflict (cliente_id) do nothing;
  select * into v_t from tarjetas_vip where cliente_id = p_cliente_id for update;
  if exists (select 1 from sellos_log where cliente_id = p_cliente_id
             and (created_at at time zone 'America/Bogota')::date = (now() at time zone 'America/Bogota')::date) then
    raise exception 'ya tiene un sello hoy';
  end if;
  if v_t.sellos >= 30 then raise exception 'la tarjeta ya esta completa (30)'; end if;
  v_n := v_t.sellos + 1;
  update tarjetas_vip set sellos = v_n, updated_at = now() where cliente_id = p_cliente_id;
  insert into sellos_log (tarjeta_id, cliente_id, numero_sello, puesto_por) values (v_t.id, p_cliente_id, v_n, v_emp);
  return jsonb_build_object('ok',true,'sellos',v_n);
end; $$;
grant execute on function sellar_tarjeta(uuid) to authenticated;

-- 7) reclamar_premio / reiniciar_carnet: guard robusto (if not found) + reinicio solo si esta completo
create or replace function reclamar_premio(p_cliente_id uuid, p_cual int)
returns jsonb language plpgsql security definer set search_path = public
as $$
declare v_emp uuid; v_t tarjetas_vip;
begin
  select id into v_emp from empleados where auth_user_id = auth.uid() and activo limit 1;
  if v_emp is null then raise exception 'solo staff'; end if;
  select * into v_t from tarjetas_vip where cliente_id = p_cliente_id for update;
  if not found then raise exception 'sin tarjeta'; end if;
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

create or replace function reiniciar_carnet(p_cliente_id uuid)
returns jsonb language plpgsql security definer set search_path = public
as $$
declare v_emp uuid; v_t tarjetas_vip;
begin
  select id into v_emp from empleados where auth_user_id = auth.uid() and activo limit 1;
  if v_emp is null then raise exception 'solo staff'; end if;
  select * into v_t from tarjetas_vip where cliente_id = p_cliente_id for update;
  if not found then raise exception 'sin tarjeta'; end if;
  if v_t.sellos < 30 then raise exception 'el carnet aun no esta completo'; end if;
  update tarjetas_vip set ciclo = ciclo + 1, sellos = 0, premio15_reclamado = false, premio30_reclamado = false, updated_at = now()
  where cliente_id = p_cliente_id;
  return jsonb_build_object('ok',true,'ciclo', v_t.ciclo + 1);
end; $$;
grant execute on function reiniciar_carnet(uuid) to authenticated;
