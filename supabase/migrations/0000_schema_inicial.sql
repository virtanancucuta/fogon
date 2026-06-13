-- 0000_schema_inicial — El Fogón de la Pesa
-- Fase 0: cimientos del backend (enums, tablas, índices, helpers, RLS, realtime).
-- gen_random_uuid() es nativo en Postgres 17 (no requiere extensión).

-- ============================ ENUMS ============================
create type rol_equipo     as enum ('admin','cocina','mesera','domiciliario');
create type tipo_pedido     as enum ('domicilio','mesa');
create type canal_pedido    as enum ('whatsapp','mesera','qr','mostrador');
create type medio_pago      as enum ('efectivo','nequi','daviplata','datafono');
create type estado_pedido   as enum ('por_confirmar','confirmado','en_proceso','listo','enviado','cobrado','cancelado');
create type estado_comanda  as enum ('pendiente','en_proceso','entregado');

-- ============================ TABLAS ============================
create table categorias (
  id        uuid primary key default gen_random_uuid(),
  nombre    text not null,
  sub       text,
  orden     int  not null default 0,
  visible   bool not null default true,
  created_at timestamptz not null default now()
);

create table productos (
  id           uuid primary key default gen_random_uuid(),
  categoria_id uuid not null references categorias(id) on delete cascade,
  nombre       text not null,
  descripcion  text,
  precio       int  not null default 0,
  img_url      text,
  visible      bool not null default true,
  orden        int  not null default 0,
  created_at   timestamptz not null default now()
);

create table clientes (
  id        uuid primary key default gen_random_uuid(),
  celular   text unique not null,
  nombre    text,
  created_at timestamptz not null default now()
);

create table empleados (
  id           uuid primary key default gen_random_uuid(),
  auth_user_id uuid unique,
  nombre       text not null,
  rol          rol_equipo not null,
  telefono     text,
  activo       bool not null default true,
  created_at   timestamptz not null default now()
);

create table pedidos (
  id            uuid primary key default gen_random_uuid(),
  tipo          tipo_pedido,
  canal         canal_pedido,
  cliente_id    uuid references clientes(id),
  mesa_numero   text,
  estado        estado_pedido not null default 'por_confirmar',
  direccion     text,
  notas         text,
  total         int not null default 0,
  medio_pago    medio_pago,
  repartidor_id uuid references empleados(id),
  mesera_id     uuid references empleados(id),
  pagado_at     timestamptz,
  cerrado_at    timestamptz,
  enviado_at    timestamptz,
  created_at    timestamptz not null default now()
);

create table comandas (
  id            uuid primary key default gen_random_uuid(),
  pedido_id     uuid not null references pedidos(id) on delete cascade,
  tanda         int not null default 1,
  estado        estado_comanda not null default 'pendiente',
  enviada_at    timestamptz,
  en_proceso_at timestamptz,
  entregada_at  timestamptz,
  created_at    timestamptz not null default now()
);

create table comanda_items (
  id          uuid primary key default gen_random_uuid(),
  comanda_id  uuid not null references comandas(id) on delete cascade,
  producto_id uuid references productos(id),
  nombre_snap text not null,
  precio_snap int not null default 0,
  qty         int not null default 1,
  subtotal    int not null default 0,
  created_at  timestamptz not null default now()
);

create table pedido_eventos (
  id           uuid primary key default gen_random_uuid(),
  pedido_id    uuid not null references pedidos(id) on delete cascade,
  estado_nuevo estado_pedido,
  actor_id     uuid,
  actor_rol    rol_equipo,
  meta         jsonb,
  created_at   timestamptz not null default now()
);

create table tarjetas_vip (
  id                 uuid primary key default gen_random_uuid(),
  cliente_id         uuid unique not null references clientes(id) on delete cascade,
  ciclo              int  not null default 1,
  sellos             int  not null default 0,
  premio15_reclamado bool not null default false,
  premio30_reclamado bool not null default false,
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now()
);

create table sellos_log (
  id          uuid primary key default gen_random_uuid(),
  tarjeta_id  uuid not null references tarjetas_vip(id) on delete cascade,
  cliente_id  uuid not null references clientes(id) on delete cascade,
  numero_sello int not null,
  puesto_por  uuid,
  created_at  timestamptz not null default now()
);

-- ============================ ÍNDICES ============================
create index idx_pedidos_estado        on pedidos(estado);
create index idx_pedidos_cerrado_at    on pedidos(cerrado_at);
create index idx_pedidos_tipo_cerrado  on pedidos(tipo, cerrado_at);
create index idx_comandas_pedido_estado on comandas(pedido_id, estado);
create index idx_productos_cat_visible on productos(categoria_id, visible);
create index idx_clientes_celular      on clientes(celular);

-- ============================ HELPERS (SECURITY DEFINER) ============================
create or replace function es_staff()
returns boolean
language sql security definer set search_path = public stable
as $$
  select exists (
    select 1 from empleados e
    where e.auth_user_id = auth.uid() and e.activo = true
  );
$$;

create or replace function rol_actual()
returns rol_equipo
language sql security definer set search_path = public stable
as $$
  select e.rol from empleados e
  where e.auth_user_id = auth.uid() and e.activo = true
  limit 1;
$$;

-- ============================ RLS: ENABLE ============================
alter table categorias     enable row level security;
alter table productos      enable row level security;
alter table clientes       enable row level security;
alter table empleados      enable row level security;
alter table pedidos        enable row level security;
alter table comandas       enable row level security;
alter table comanda_items  enable row level security;
alter table pedido_eventos enable row level security;
alter table tarjetas_vip   enable row level security;
alter table sellos_log     enable row level security;

-- ---- categorias: SELECT público (visible) + staff ve todo; escritura solo admin ----
create policy categorias_sel_public on categorias for select to anon, authenticated using (visible = true);
create policy categorias_sel_staff  on categorias for select to authenticated using (es_staff());
create policy categorias_ins_admin  on categorias for insert to authenticated with check (rol_actual() = 'admin');
create policy categorias_upd_admin  on categorias for update to authenticated using (rol_actual() = 'admin') with check (rol_actual() = 'admin');
create policy categorias_del_admin  on categorias for delete to authenticated using (rol_actual() = 'admin');

-- ---- productos: igual que categorias ----
create policy productos_sel_public on productos for select to anon, authenticated using (visible = true);
create policy productos_sel_staff  on productos for select to authenticated using (es_staff());
create policy productos_ins_admin  on productos for insert to authenticated with check (rol_actual() = 'admin');
create policy productos_upd_admin  on productos for update to authenticated using (rol_actual() = 'admin') with check (rol_actual() = 'admin');
create policy productos_del_admin  on productos for delete to authenticated using (rol_actual() = 'admin');

-- ---- clientes: anon INSERT; lectura/edición solo staff (acceso del cliente por celular vía RPC SECURITY DEFINER) ----
create policy clientes_ins_anon on clientes for insert to anon, authenticated with check (true);
create policy clientes_all_staff on clientes for all to authenticated using (es_staff()) with check (es_staff());

-- ---- empleados: solo staff ----
create policy empleados_all_staff on empleados for all to authenticated using (es_staff()) with check (es_staff());

-- ---- pedidos: anon INSERT; SELECT/UPDATE solo staff ----
create policy pedidos_ins        on pedidos for insert to anon, authenticated with check (true);
create policy pedidos_sel_staff  on pedidos for select to authenticated using (es_staff());
create policy pedidos_upd_staff  on pedidos for update to authenticated using (es_staff()) with check (es_staff());

-- ---- comandas: anon INSERT; SELECT/UPDATE solo staff ----
create policy comandas_ins       on comandas for insert to anon, authenticated with check (true);
create policy comandas_sel_staff on comandas for select to authenticated using (es_staff());
create policy comandas_upd_staff on comandas for update to authenticated using (es_staff()) with check (es_staff());

-- ---- comanda_items: anon INSERT; SELECT/UPDATE solo staff ----
create policy comanda_items_ins       on comanda_items for insert to anon, authenticated with check (true);
create policy comanda_items_sel_staff on comanda_items for select to authenticated using (es_staff());
create policy comanda_items_upd_staff on comanda_items for update to authenticated using (es_staff()) with check (es_staff());

-- ---- pedido_eventos: solo staff ----
create policy pedido_eventos_all_staff on pedido_eventos for all to authenticated using (es_staff()) with check (es_staff());

-- ---- tarjetas_vip: staff total; el cliente ve su fila vía RPC SECURITY DEFINER ----
create policy tarjetas_all_staff on tarjetas_vip for all to authenticated using (es_staff()) with check (es_staff());

-- ---- sellos_log: solo staff ----
create policy sellos_all_staff on sellos_log for all to authenticated using (es_staff()) with check (es_staff());

-- ============================ RPCs cliente por celular (sin auth fuerte, sin exponer la tabla) ============================
create or replace function cliente_get(p_celular text)
returns clientes
language sql security definer set search_path = public stable
as $$
  select * from clientes where celular = p_celular limit 1;
$$;

create or replace function cliente_upsert(p_celular text, p_nombre text default null)
returns clientes
language plpgsql security definer set search_path = public
as $$
declare c clientes;
begin
  insert into clientes (celular, nombre) values (p_celular, p_nombre)
  on conflict (celular) do update set nombre = coalesce(excluded.nombre, clientes.nombre)
  returning * into c;
  return c;
end;
$$;

create or replace function tarjeta_get(p_celular text)
returns tarjetas_vip
language sql security definer set search_path = public stable
as $$
  select t.* from tarjetas_vip t
  join clientes c on c.id = t.cliente_id
  where c.celular = p_celular limit 1;
$$;

grant execute on function cliente_get(text)            to anon, authenticated;
grant execute on function cliente_upsert(text, text)   to anon, authenticated;
grant execute on function tarjeta_get(text)            to anon, authenticated;

-- ============================ REALTIME ============================
alter table pedidos  replica identity full;
alter table comandas replica identity full;
alter publication supabase_realtime add table pedidos;
alter publication supabase_realtime add table comandas;
