# El Fogón de la Pesa — Backend, Admin y Fidelización
## Documento de diseño (spec) — Roadmap completo + detalle Fase 0 y Fase 1

**Fecha:** 2026-06-13
**Cliente:** El Fogón de la Pesa (cenadero, El Palustre — Atalaya, Cúcuta).
**Estado actual:** menú estático en GitHub Pages (`virtanancucuta/fogon`, https://virtanancucuta.github.io/fogon/) que arma el pedido y lo envía por WhatsApp al 573222259538. Sin backend.

---

## 1. Objetivo

Convertir la página estática en un sistema con backend que permita:
- Que la **dueña** administre el menú (productos, precios, fotos) sin tocar código.
- Mostrar **"ver producto"** con foto al cliente.
- Un **CRM** de clientes (quién compra, filtrable por mes).
- Un **carnet VIP** de fidelización (15 casillas, almuerzo #15 gratis, #30 premio).
- **Roles** de mesera y cocina con un flujo de pedidos (nuevo → en proceso → entregado = venta).
- Un **panel de ventas** del día (total y por producto).

Sin inventario por ahora.

## 2. ¿Necesita backend? Sí.

Login, persistencia entre dispositivos, multiusuario por rol, CRM, sellos del carnet y ventas no son posibles en una página estática. Se monta sobre **Supabase** (mismo stack que AIMMA): Postgres + Auth + Storage (fotos) + Edge Functions (lógica protegida) + RLS (permisos por rol).

## 3. Decisiones tomadas (bloqueadas)

1. **Backend:** Supabase. El proyecto "fogon" lo crea Claude. Cuenta de Jorge en **Pro** (org `virtana`, id `adkzvjcwyzfbtjqgcylz`). Crear el proyecto = sin costo extra dentro del plan.
2. **Login de clientes (carnet):** solo con número de teléfono, sin clave (frictionless, $0 en SMS). Riesgo bajo: el cliente solo ve su propio carnet. (Se construye en Fase 2/3.)
3. **Primera entrega:** Fase 0 (fundación) + Fase 1 (admin de productos/fotos).
4. **Alcance del admin de productos:** la dueña puede **agregar, editar (nombre/precio/descripción/foto), ocultar/mostrar, eliminar y reordenar** productos. Las **6 categorías son fijas**.
5. **Acceso del staff:**
   - **Dueña/Admin:** usuario (correo) + contraseña. Cuenta raíz.
   - **Mesera y Cocina:** **dispositivo autorizado por la dueña + PIN corto.** Solo el celular habilitado entra a ese rol; otro celular queda fuera aunque tenga la clave; la dueña puede revocar dispositivos. (Se construye en Fase 4; el modelo de roles se deja listo desde Fase 0.)

## 4. Arquitectura general

- **Frontend estático** (HTML/CSS/JS) servido por **GitHub Pages**, hablando con Supabase vía su cliente JS.
  - Menú público: `…/fogon/` (la página actual, ahora dinámica).
  - Admin dueña: `…/fogon/admin/`.
  - Mesera: `…/fogon/mesero/` · Cocina: `…/fogon/cocina/` · Cliente/carnet: `…/fogon/carnet/` (fases futuras).
- **Backend Supabase** (proyecto "fogon", región us-east para cercanía a Colombia):
  - Postgres con RLS.
  - Auth (email/password para staff; identidad por teléfono para clientes en Fase 2/3).
  - Storage: bucket `productos` (lectura pública, escritura solo staff).
  - Edge Functions: se introducen cuando hay escritura pública o lógica sensible (crear pedido del cliente, emparejar dispositivo, sellar carnet). **No se usan en Fase 0/1.**
- **Manejo de llaves:** la *publishable/anon key* va en el cliente (es pública y segura). La *service_role* nunca sale del servidor (Edge Functions), igual que en AIMMA.

## 5. Roadmap por fases

Cada fase se entrega y se prueba antes de seguir. Cada una tendrá su propio ciclo spec → plan → build.

- **Fase 0 — Fundación backend.** Proyecto Supabase, modelo de datos base (categorías, productos, perfiles/roles), seed del menú actual, RLS, bucket de fotos, cuenta de la dueña. Migrar el menú público para que lea de la base.
- **Fase 1 — Admin de la dueña (productos + fotos + precios).** Login, CRUD de productos, subida de fotos, ocultar/mostrar, reordenar. "Ver producto" en el menú público.
- **Fase 2 — CRM de clientes.** Guardar pedidos en la base; tabla de clientes; panel "Clientes" con filtro por mes; login de cliente por teléfono.
- **Fase 3 — Carnet VIP.** Carnet de 15 casillas; la dueña sella por día; #15 gratis, #30 premio; buscar cliente y marcar "reclamó"; el cliente ve su carnet.
- **Fase 4 — POS (mesera/cocina) + ventas.** Emparejamiento de dispositivos + PIN; mesera monta pedidos; cocina cambia estado (nuevo → en proceso → entregado); entregado = venta; panel de ventas del día (total y por producto).

---

## 6. Detalle de la PRIMERA ENTREGA (Fase 0 + Fase 1)

### 6.1 Modelo de datos (lo que se crea ahora)

**`categorias`** — fijas, pre-cargadas.
| campo | tipo | nota |
|---|---|---|
| id | uuid PK | |
| slug | text unique | caldos, medio_caldo, bandeja_250, bandeja_150, especiales, bebidas |
| nombre | text | "Caldos", "Medio caldo", "Bandeja", … |
| subtitulo | text null | "250 gr" / "150 gr" |
| orden | int | |

**`productos`**
| campo | tipo | nota |
|---|---|---|
| id | uuid PK | |
| categoria_id | uuid FK → categorias | |
| nombre | text | |
| descripcion | text null | usada en "ver producto" |
| precio | int | COP. **0 = "Valor en el local"** (bebidas) |
| foto_path | text null | ruta dentro del bucket `productos` |
| visible | bool default true | oculto = no aparece en el menú público |
| orden | int | orden dentro de la categoría |
| created_at / updated_at | timestamptz | |

Seed inicial: los **28 productos actuales** con sus precios.

**`perfiles`** — staff.
| campo | tipo | nota |
|---|---|---|
| id | uuid PK = auth.users.id | |
| rol | text | 'duena' \| 'mesera' \| 'cocina' |
| nombre | text | |
| activo | bool default true | |

En Fase 0 solo se crea **la cuenta de la dueña** (rol `duena`).

> **Tablas futuras (NO se crean ahora, se documentan):** `dispositivos` (Fase 4, device-binding mesera/cocina), `clientes` (Fase 2), `pedidos` + `pedido_items` (Fase 2/4), `carnets` + `sellos` (Fase 3). El modelo es aditivo: se agregan sin romper lo existente.

### 6.2 Seguridad (RLS) — Fase 0/1

- Función helper `es_staff(uid)` que consulta `perfiles.activo` y rol.
- `categorias`: **SELECT público** (anon). Escritura solo staff.
- `productos`:
  - **anon (público):** SELECT solo de `visible = true`.
  - **dueña (autenticada):** SELECT de todos + INSERT/UPDATE/DELETE.
- `perfiles`: cada usuario lee su propio perfil; escritura administrativa controlada.
- **Storage bucket `productos`:** lectura pública; escritura/borrado solo staff autenticado.
- En Fase 0/1 las escrituras de producto las hace la dueña directo por el cliente Supabase (RLS las protege). **No hace falta Edge Function todavía.**

### 6.3 Menú público dinámico + "ver producto"

- La página actual (`index.html`) mantiene **el mismo diseño y el mismo flujo de pedido por WhatsApp**.
- Cambia el origen de datos: en vez de `const MENU` fijo, al cargar **trae de Supabase** las categorías y los productos visibles (con la anon key) y los renderiza en la misma estructura.
- **Resiliencia/velocidad:** se guarda la última respuesta en `localStorage`; al abrir, muestra el caché al instante y refresca en segundo plano. Si Supabase no responde, el cliente ve el último menú conocido.
- Se quita el precio repetido en el encabezado de cada categoría (ahora cada producto trae su propio precio editable).
- **"Ver producto":** si el producto tiene foto, se muestra su miniatura en la fila; al tocar el producto se abre un detalle (foto grande, nombre, descripción, precio y control para agregar al pedido). Si no tiene foto, la fila se comporta como hoy.

### 6.4 Admin de la dueña (`/admin/`)

- Página nueva con el cliente Supabase.
- **Login** con correo (usuario) + contraseña. Si el perfil es `duena`, entra al administrador; si no, acceso denegado.
- **Gestión de productos** agrupados por categoría:
  - Agregar producto nuevo (a una categoría).
  - Editar nombre, descripción, precio.
  - Subir/cambiar foto (se **comprime en el navegador** a ~1200px antes de subir, para no pesar).
  - Ocultar/mostrar.
  - Eliminar.
  - Reordenar dentro de la categoría.
- Cambios se reflejan en el menú público (al recargar / al expirar el caché).
- Sesión persistente para que la dueña no tenga que entrar cada vez.

### 6.5 Hosting / despliegue

- Mismo repo `virtanancucuta/fogon`; el push a `main` publica también `/admin/`.
- La anon key de Supabase queda embebida en el cliente (pública y segura por diseño).
- Sin secretos en el repo.

### 6.6 Qué entrega esta fase (y qué NO)

- **Entrega:** la dueña administrando su menú (productos, precios, fotos) en vivo + el "ver producto" para el cliente, todo respaldado por Supabase.
- **NO todavía:** CRM, carnet VIP, ventas, mesera/cocina, emparejamiento de dispositivos. (Fases 2–4.)

### 6.7 Pruebas (Fase 0/1)

- **Smoke en navegador real (headless):**
  - El menú público renderiza desde una base sembrada (28 productos), arma pedido y abre WhatsApp con el mensaje correcto.
  - "Ver producto" abre el detalle con foto/descripcion/precio.
  - Admin: login de la dueña, agregar/editar/ocultar/eliminar/reordenar producto, subir foto.
- **RLS:**
  - anon NO puede escribir productos.
  - anon NO ve productos `visible=false`.
  - una sesión que no sea staff no puede entrar al admin.

## 7. Puntos abiertos / supuestos

- **Usuario de la dueña:** Supabase Auth usa correo como identificador; "usuario" = un correo (real o uno tipo `duena@fogon…`). Se confirma el correo a usar al crear la cuenta.
- **Idioma de errores y textos** visibles al cliente: español correcto (con ñ).
- El **emparejamiento de dispositivos** (mesera/cocina) y su mecánica fina se detallará en el spec de la Fase 4; aquí solo se reserva el modelo de roles.

---

*Próximo paso tras aprobación: plan de implementación (writing-plans) de la Fase 0 + Fase 1, y como primer paso de ejecución, crear el proyecto Supabase "fogon".*
