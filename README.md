# El Fogón de la Pesa — Menú digital

Página de pedidos para clientes del cenadero **El Fogón de la Pesa** (El Palustre, Atalaya — tradición desde 1960).

El cliente abre el menú desde el celular, arma su pedido tocando **+** y lo envía por **WhatsApp** al negocio. Sin backend: es una página estática (un solo archivo `index.html`).

## Características
- Menú por categorías (Caldos, Medio caldo, Bandeja 250gr / 150gr, Especiales, Bebidas).
- Navegación rápida por categorías (chips fijos arriba).
- Carrito con resumen del pedido y total en tiempo real.
- Envío directo a WhatsApp con nombre, tipo de pedido y dirección/mesa.
- Botones de Llamar y Cómo llegar (Google Maps).
- Diseño mobile-first, accesible, con la identidad del negocio.

## Cómo se publica
Hospedado en **GitHub Pages**. Cualquier cambio en `index.html` se publica al hacer push a `main`.

## Próximo (fase 2)
Agregar fotos de los productos para "ver producto". La estructura de datos en `index.html` (`const MENU`) ya soporta los campos `img` y `desc` por ítem: al agregarlos, la miniatura y la descripción aparecen solas.

---
Contacto domicilios: **322 225 9538**
