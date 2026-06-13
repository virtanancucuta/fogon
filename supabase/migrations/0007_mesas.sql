-- 0007_mesas — mesas configurables (mapa del salón). La dueña define la lista;
-- la mesera elige de ahí (fin del texto libre). Lectura: staff; escritura: solo admin.

create table mesas (
  id        uuid primary key default gen_random_uuid(),
  nombre    text not null,
  orden     int  not null default 0,
  activa    bool not null default true,
  created_at timestamptz not null default now()
);

alter table mesas enable row level security;
create policy mesas_sel_staff on mesas for select to authenticated using (es_staff());
create policy mesas_ins_admin on mesas for insert to authenticated with check (rol_actual() = 'admin');
create policy mesas_upd_admin on mesas for update to authenticated using (rol_actual() = 'admin') with check (rol_actual() = 'admin');
create policy mesas_del_admin on mesas for delete to authenticated using (rol_actual() = 'admin');

insert into mesas (nombre, orden) values
  ('Mesa 1',1),('Mesa 2',2),('Mesa 3',3),('Mesa 4',4),('Mesa 5',5),('Mesa 6',6);
