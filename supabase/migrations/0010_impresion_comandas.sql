-- 0010_impresion_comandas — marca anti-duplicado para la impresion de comandas de cocina.
-- La comanda de cocina se auto-imprime cuando su pedido entra a cocina (confirmado/en_proceso/listo)
-- y aun no fue impresa. impreso_at sella el momento; recargar el panel no reimprime.

alter table comandas add column if not exists impreso_at timestamptz;

-- Sellar el historico existente para que el primer admin que entre NO reimprima pedidos viejos.
update comandas set impreso_at = now() where impreso_at is null;

-- Marca una comanda como impresa (idempotente: conserva el primer timestamp). Cualquier staff activo.
create or replace function marcar_comanda_impresa(p_comanda_id uuid)
returns jsonb language plpgsql security definer set search_path = public
as $$
declare v_rol rol_equipo; v_imp timestamptz;
begin
  select rol into v_rol from empleados where auth_user_id = auth.uid() and activo limit 1;
  if v_rol is null then raise exception 'solo personal autorizado'; end if;
  update comandas set impreso_at = coalesce(impreso_at, now())
    where id = p_comanda_id
    returning impreso_at into v_imp;
  if not found then raise exception 'comanda inexistente'; end if;
  return jsonb_build_object('ok', true, 'impreso_at', v_imp);
end; $$;
grant execute on function marcar_comanda_impresa(uuid) to authenticated;
