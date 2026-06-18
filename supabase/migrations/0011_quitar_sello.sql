-- 0011_quitar_sello — corregir un sello puesto por error (resta 1, sin bajar de 0). Solo staff.
create or replace function quitar_sello(p_cliente_id uuid)
returns jsonb language plpgsql security definer set search_path = public
as $$
declare v_emp uuid; v_sellos int;
begin
  select id into v_emp from empleados where auth_user_id = auth.uid() and activo limit 1;
  if v_emp is null then raise exception 'solo staff'; end if;
  update tarjetas_vip set sellos = greatest(0, coalesce(sellos,0) - 1)
    where cliente_id = p_cliente_id
    returning sellos into v_sellos;
  if not found then raise exception 'el cliente no tiene tarjeta'; end if;
  return jsonb_build_object('ok', true, 'sellos', v_sellos);
end; $$;
grant execute on function quitar_sello(uuid) to authenticated;
