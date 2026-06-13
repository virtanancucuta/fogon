-- 0003_storage_productos — bucket de fotos de productos (Fase 2B)
-- Lectura pública (la tienda muestra las fotos); escritura/borrado solo admin.

insert into storage.buckets (id, name, public)
values ('productos', 'productos', true)
on conflict (id) do nothing;

-- lectura pública del bucket
create policy "productos_obj_read" on storage.objects
  for select to anon, authenticated
  using (bucket_id = 'productos');

-- escritura solo admin (rol_actual() es SECURITY DEFINER en public)
create policy "productos_obj_insert" on storage.objects
  for insert to authenticated
  with check (bucket_id = 'productos' and public.rol_actual() = 'admin');

create policy "productos_obj_update" on storage.objects
  for update to authenticated
  using (bucket_id = 'productos' and public.rol_actual() = 'admin')
  with check (bucket_id = 'productos' and public.rol_actual() = 'admin');

create policy "productos_obj_delete" on storage.objects
  for delete to authenticated
  using (bucket_id = 'productos' and public.rol_actual() = 'admin');
