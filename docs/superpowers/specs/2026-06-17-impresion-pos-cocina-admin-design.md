# Impresión POS + cocina absorbida por el admin — Diseño

Fecha: 2026-06-17
Proyecto: El Fogón de la Pesa (repo `virtanancucuta/fogon`, Supabase `fogon` ref `kxacvooiedcuaohxqrbq`)

## Problema y decisión

La dueña no quiere una pantalla de cocina: las cocineras están acostumbradas a trabajar con la **orden impresa** en impresora térmica POS. Por tanto:

- Se **retira el módulo `/cocina`** del flujo de trabajo.
- El **admin (caja)** absorbe lo que hacía cocina: ve las comandas, **imprime** el ticket para la cocina, y marca los estados **Empezar (en proceso)** y **Entregado**.
- El admin además puede **imprimir la cuenta de cobro** (con precios y total) tanto de **mesa** (la arma la mesera) como de **domicilio**.
- La **mesera se mantiene** igual (toma mesas, agrega rondas, cobra). Solo desaparece la app de cocina.

## Hardware y técnica de impresión

- **Dispositivo:** PC/portátil en caja con la impresora POS instalada como impresora del sistema (USB o red).
- **Ancho de rollo:** **80 mm** (maquetado por CSS; cambiar a 58 mm es ajustar una variable).
- **Técnica:** `window.print()` sobre un **iframe oculto** que contiene únicamente el ticket a imprimir, con `@media print` que oculta todo lo demás. Sin instalar software, sin backend nuevo.
- **Impresión silenciosa (sin diálogo):** Chrome lanzado una sola vez con el flag `--kiosk-printing` (acceso directo en el escritorio de caja). Con eso, imprimir es instantáneo y de un clic. Sin el flag, funciona igual pero aparece el diálogo de impresión.

## Enfoque elegido

`window.print()` + ticket en CSS dentro de iframe oculto (enfoque 1 de los evaluados). Descartados: QZ Tray / servicio ESC/POS local (requiere instalar y mantener software + certificados, innecesario) y generación de PDF (añade una librería sin ventaja para tickets de texto).

## Estación de caja y auto-impresión

- La PC de caja mantiene el **panel admin abierto permanentemente** (actúa como estación de impresión).
- Vía **realtime** (ya existe en `comandas` y `pedidos`), **toda comanda nueva se imprime sola**:
  - **Mesa:** apenas la mesera la manda (queda comanda `pendiente`).
  - **Domicilio:** apenas el admin pulsa **Confirmar y cobrar**.
- **Marca de impreso (anti-duplicado):** cada comanda guarda `impreso_at`. El auto-print solo dispara para comandas con `impreso_at` nulo; al imprimir se sella la marca. Así, **recargar la página no reimprime** lo ya impreso.
- **Reimprimir:** botón siempre disponible en cada comanda; reimprime sin borrar la marca y muestra "Impreso HH:MM".

## Los dos tickets

### 1) Comanda de cocina (SIN precios)
Lo que usa la cocina para preparar. Contenido:
- Encabezado: tipo (**MESA N°** o **DOMICILIO #XXXX**) + **Ronda N** si la tanda > 1.
- Hora.
- Lista de **producto + cantidad** (de `comanda_items`: `nombre_snap`, `qty`).
- Notas del pedido si existen.
- Letra grande y legible; sin valores monetarios.

### 2) Cuenta de cobro (CON precios)
Para el cliente, al momento de cobrar/cerrar. Contenido:
- Encabezado del negocio: **El Fogón de la Pesa**, dirección (Estación de servicio Terpel El Palustre, Atalaya, Cúcuta), teléfono/WhatsApp **3222259538**.
- Identificador: **MESA N°** o **DOMICILIO #XXXX**.
- Productos con cantidad, precio unitario y subtotal (todas las rondas).
- **TOTAL**.
- Medio de pago cuando aplique.
- Fecha y hora (zona America/Bogotá).
- Botón **Imprimir cuenta** en el momento de cobrar (mesa) o cerrar/enviar (domicilio). También reimprimible.

## Flujo y roles resultantes

- **Mesera:** toma mesas, agrega rondas, cobra mesas (igual que hoy).
- **Admin (caja):**
  - Recibe e **imprime automáticamente** las comandas (mesa y domicilio).
  - Marca **Empezar** (`cocina_comanda` → en proceso) y **Entregado** (`cocina_comanda` → entregado) en cada comanda. El estado del pedido se **deriva** vía `recalc_estado_pedido`.
  - Domicilios: **Confirmar y cobrar** → (Empezar/Entregado por comanda) → **Enviar** (cerrado = venta). Imprime cuenta de cobro.
  - Mesas: ve la comanda, imprime, marca estados; el **cobro de mesa** lo puede hacer mesera o admin. Imprime cuenta al cobrar.
- **Cocina:** ya no usa app; trabaja con el papel. El usuario `cocina@` se **desactiva** tras terminar la auditoría (no se borra, por si se quiere revertir).

### Reconciliación de estados de domicilio
Hoy la bandeja de domicilio tiene botón "En proceso" (`transicion_pedido` confirmado→en_proceso). Con el modelo derivado de comandas, los estados intermedios (**en_proceso**, **listo**) los produce `cocina_comanda` (Empezar/Entregado). Para no tener dos caminos:
- La **vista de comandas del admin** (Empezar/Entregado) es la única fuente de los estados intermedios.
- La **bandeja de domicilio** conserva solo **Confirmar y cobrar** (por_confirmar→confirmado) y **Enviar** (listo→enviado). Se elimina de ahí el botón "En proceso" manual.

## Cambios técnicos

### Base de datos (migración 0010)
- `alter table comandas add column impreso_at timestamptz;`
- RPC `marcar_comanda_impresa(p_comanda_id uuid)` — guard staff (admin/cocina/mesera), sella `impreso_at = now()` solo si estaba nulo (idempotente). Devuelve estado.
- (Sin cambios de RLS; reusa `cocina_comanda`, `cobrar_pedido`, `transicion_pedido` ya existentes.)

### Front `/admin`
- **Nueva sección "Cocina" / comandas:** lista de comandas `pendiente` y `en_proceso` (join pedido para mesa/tipo/#código), con botones **Empezar**/**Entregado**, badge **Impreso HH:MM** y botón **Reimprimir**. Realtime sobre `comandas`.
- **Auto-print por realtime:** al detectar comanda nueva o no impresa, renderiza el ticket de cocina en iframe oculto, imprime y llama `marcar_comanda_impresa`.
- **Render de tickets:** dos plantillas (comanda de cocina / cuenta de cobro) en CSS 80 mm dentro de iframe oculto + `@media print`.
- **Cuenta de cobro:** botón "Imprimir cuenta" en el detalle de mesa (al cobrar) y de domicilio (al cerrar/enviar).
- **Bandeja domicilio:** quitar botón "En proceso" manual (queda derivado por comanda).

### Retiro de `/cocina`
- Se deja de enlazar y se desactiva el usuario `cocina@` al cerrar la auditoría. El código de la carpeta puede quedar o eliminarse (decisión menor, sin impacto en el resto).

## Criterios de éxito (verificación)

1. La mesera manda un pedido de mesa → en caja **sale solo** el ticket de cocina (sin precios), marcado "Impreso".
2. Recargar el panel admin **no reimprime** la comanda ya impresa.
3. Reimprimir produce una copia idéntica y mantiene la marca.
4. Admin marca **Empezar** y **Entregado** → el pedido avanza (en_proceso → listo) sin pasar por /cocina.
5. Al cobrar una mesa, el admin imprime la **cuenta de cobro** con encabezado del negocio, productos, precios y TOTAL correctos.
6. Domicilio: Confirmar y cobrar (imprime comanda) → Empezar/Entregado → Enviar (cierra venta) → cuenta de cobro imprimible.
7. El ancho de 80 mm se ve bien en la térmica real (validación física de Jorge).

## Fuera de alcance (YAGNI)
- Corte automático de papel (ESC/POS).
- Impresión desde celular/tablet/iOS.
- Cajón monedero, apertura por comando.
- Reportes impresos / cierre de caja en papel (futuro si se pide).
