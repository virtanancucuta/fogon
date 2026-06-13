-- 0001_seed_menu — siembra categorías + productos desde el const MENU del index.html
-- Fuente de verdad: index.html (28 productos). Bebidas precio 0 = "valor en el local", visible=true.

insert into categorias (nombre, sub, orden) values
  ('Caldos',       null,     1),
  ('Medio caldo',  null,     2),
  ('Bandeja',      '250 gr', 3),
  ('Bandeja',      '150 gr', 4),
  ('Especiales',   null,     5),
  ('Bebidas',      null,     6);

-- Caldos
insert into productos (categoria_id, nombre, descripcion, precio, orden) values
  ((select id from categorias where nombre='Caldos' and sub is null), 'Venas',    null, 15000, 1),
  ((select id from categorias where nombre='Caldos' and sub is null), 'Pichón',   null, 15000, 2),
  ((select id from categorias where nombre='Caldos' and sub is null), 'Vigoroso', null, 15000, 3),
  ((select id from categorias where nombre='Caldos' and sub is null), 'Costilla', null, 15000, 4),
  ((select id from categorias where nombre='Caldos' and sub is null), 'Lagarto',  null, 15000, 5);

-- Medio caldo
insert into productos (categoria_id, nombre, descripcion, precio, orden) values
  ((select id from categorias where nombre='Medio caldo' and sub is null), 'Venas',    null, 10000, 1),
  ((select id from categorias where nombre='Medio caldo' and sub is null), 'Pichón',   null, 10000, 2),
  ((select id from categorias where nombre='Medio caldo' and sub is null), 'Vigoroso', null, 10000, 3),
  ((select id from categorias where nombre='Medio caldo' and sub is null), 'Lagarto',  null, 10000, 4);

-- Bandeja 250 gr
insert into productos (categoria_id, nombre, descripcion, precio, orden) values
  ((select id from categorias where nombre='Bandeja' and sub='250 gr'), 'Carne',            null, 34000, 1),
  ((select id from categorias where nombre='Bandeja' and sub='250 gr'), 'Pechuga',          null, 32000, 2),
  ((select id from categorias where nombre='Bandeja' and sub='250 gr'), 'Lomo',             null, 32000, 3),
  ((select id from categorias where nombre='Bandeja' and sub='250 gr'), 'Lengua',           null, 32000, 4),
  ((select id from categorias where nombre='Bandeja' and sub='250 gr'), 'Chunchullo',       null, 32000, 5),
  ((select id from categorias where nombre='Bandeja' and sub='250 gr'), 'Sobre barriga',    null, 32000, 6),
  ((select id from categorias where nombre='Bandeja' and sub='250 gr'), 'Mixta 2 carnes',   null, 35000, 7),
  ((select id from categorias where nombre='Bandeja' and sub='250 gr'), 'Bandeja 3 carnes', null, 38000, 8);

-- Bandeja 150 gr
insert into productos (categoria_id, nombre, descripcion, precio, orden) values
  ((select id from categorias where nombre='Bandeja' and sub='150 gr'), 'Carne',          null, 22000, 1),
  ((select id from categorias where nombre='Bandeja' and sub='150 gr'), 'Pechuga',        null, 22000, 2),
  ((select id from categorias where nombre='Bandeja' and sub='150 gr'), 'Lomo',           null, 22000, 3),
  ((select id from categorias where nombre='Bandeja' and sub='150 gr'), 'Chunchullo',     null, 22000, 4),
  ((select id from categorias where nombre='Bandeja' and sub='150 gr'), 'Lengua',         null, 22000, 5),
  ((select id from categorias where nombre='Bandeja' and sub='150 gr'), 'Sobre barriga',  null, 22000, 6),
  ((select id from categorias where nombre='Bandeja' and sub='150 gr'), 'Mixta 2 carnes', null, 24000, 7);

-- Especiales
insert into productos (categoria_id, nombre, descripcion, precio, orden) values
  ((select id from categorias where nombre='Especiales' and sub is null), 'Picada', 'Ideal para 3 a 4 personas', 44000, 1);

-- Bebidas (precio 0 = valor en el local)
insert into productos (categoria_id, nombre, descripcion, precio, orden) values
  ((select id from categorias where nombre='Bebidas' and sub is null), 'Gaseosa',  null, 0, 1),
  ((select id from categorias where nombre='Bebidas' and sub is null), 'Agua',     null, 0, 2),
  ((select id from categorias where nombre='Bebidas' and sub is null), 'Limonada', null, 0, 3);
