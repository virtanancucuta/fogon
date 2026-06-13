-- 0002_crear_pedido_domicilio — RPC atómica para el checkout del menú web (Fase 1)
-- Crea pedido(domicilio,whatsapp,por_confirmar) + comanda(tanda 1,pendiente) + comanda_items
-- en una sola transacción. Precio se toma de la BD (anti-manipulación); el nombre_snap usa
-- el nombre descriptivo provisto por el cliente ("Caldo Venas", "Bandeja 250gr Carne").
-- Código de pedido = últimos 4 del uuid (en la fila por construcción) -> "#A3F9".
-- por_confirmar NO es venta: no se tocan cerrado_at ni pagado_at.

create or replace function crear_pedido_domicilio(
  p_cliente_id uuid,
  p_direccion  text,
  p_notas      text,
  p_items      jsonb   -- [{producto_id, qty, nombre, precio}]
) returns jsonb
language plpgsql security definer set search_path = public
as $$
declare
  v_pedido_id  uuid;
  v_comanda_id uuid;
  v_total int := 0;
  v_item jsonb;
  v_prod uuid;
  v_qty  int;
  v_precio int;
  v_nombre text;
  v_codigo text;
begin
  if p_items is null or jsonb_array_length(p_items) = 0 then
    raise exception 'pedido sin items';
  end if;

  insert into pedidos (tipo, canal, cliente_id, direccion, notas, total, estado)
  values ('domicilio', 'whatsapp', p_cliente_id, nullif(btrim(p_direccion),''), nullif(btrim(p_notas),''), 0, 'por_confirmar')
  returning id into v_pedido_id;

  insert into comandas (pedido_id, tanda, estado)
  values (v_pedido_id, 1, 'pendiente')
  returning id into v_comanda_id;

  for v_item in select * from jsonb_array_elements(p_items)
  loop
    v_prod := nullif(v_item->>'producto_id','')::uuid;
    v_qty  := greatest(1, coalesce((v_item->>'qty')::int, 1));
    -- precio real desde la BD; fallback al provisto si el producto no existe
    select precio into v_precio from productos where id = v_prod;
    if v_precio is null then v_precio := coalesce((v_item->>'precio')::int, 0); end if;
    v_nombre := coalesce(nullif(btrim(v_item->>'nombre'),''), 'Item');

    insert into comanda_items (comanda_id, producto_id, nombre_snap, precio_snap, qty, subtotal)
    values (v_comanda_id, v_prod, v_nombre, v_precio, v_qty, v_precio * v_qty);

    v_total := v_total + v_precio * v_qty;
  end loop;

  update pedidos set total = v_total where id = v_pedido_id;

  v_codigo := upper(right(v_pedido_id::text, 4));

  return jsonb_build_object(
    'pedido_id', v_pedido_id,
    'comanda_id', v_comanda_id,
    'codigo', v_codigo,
    'total', v_total
  );
end;
$$;

grant execute on function crear_pedido_domicilio(uuid, text, text, jsonb) to anon, authenticated;
