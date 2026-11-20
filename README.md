# DL COMANDA PRO

**Del mesero a la cocina en un toque. Pedido tomado, plato a tiempo.**

Desarrollado y administrado por **DL COMPANY -TECHNOLOGY-**.

## Qué es

App web (instalable en el celular) para restaurantes y bares. El mesero toma el pedido por mesa, la cocina o la caja lo recibe **en vivo**, lo marca **listo** y al mesero le llega el aviso (sonido, vibración y notificación) para recogerlo. Todo sincronizado en tiempo real entre todos los dispositivos.

## Roles

| Rol | Cómo entra | Qué hace |
|---|---|---|
| 👑 Dueño | Correo + contraseña | Todo: mesas, cocina, cuentas, ventas del día, menú, mesas y personal |
| 🧑‍🍳 Mesero | Restaurante + NIT → usuario + PIN | Toma pedidos por mesa, recibe el aviso de "listo", marca recogido |
| 🔥 Cocina / Caja | Restaurante + NIT → usuario + PIN | Tablero en vivo (Nuevos · En preparación · Listos), cobra las cuentas |

## Flujo de un pedido

`nuevo` 🔔 → `preparando` 🔥 → `listo` ✅ (aviso al mesero) → `entregado` 🍽️ → cobrado 💵

## Estructura

```
index.html            App completa (HTML + CSS + JS)
legal.html            Términos, privacidad y reembolsos
config.js             URL y clave pública de Supabase
manifest.json, sw.js  Instalación como app (PWA) y avisos
logo.svg + íconos     Marca DL COMANDA PRO
dl-company.png        Logo de DL COMPANY -TECHNOLOGY-
supabase/schema.sql   Tablas, seguridad (RLS), funciones y tiempo real
supabase/v2-*.sql     Stock y código de barras
supabase/v3-*.sql     Avisos push, cobros (propina/descuento) y cambio de mesa
supabase/v4-*.sql     Estaciones cocina / bar
supabase/functions/   Función que envía los avisos push
supabase/v2-stock-catalogo.sql   Código de barras, stock opcional y catálogo común (v1.2)
```

## Nube (Supabase)

- El esquema ya está aplicado. Para un proyecto nuevo: SQL Editor → pegar `supabase/schema.sql` → Run, y después `supabase/v2-stock-catalogo.sql` → Run.
- **Authentication → Sign In / Providers → Allow anonymous sign-ins: ON** (necesario para el ingreso con PIN).
- **Authentication → URL Configuration → Site URL**: la dirección de GitHub Pages.

## Hoja de ruta

- [x] Pedidos por mesa, cocina en vivo, aviso de listo, cuentas y cobro
- [x] Roles dueño / mesero / cocina-caja con PIN
- [x] Ventas del día, top de productos, tiempos de cocina
- [x] Avisos push con la app cerrada o el celular bloqueado (mesero: listo / cancelado · cocina: pedido nuevo)
- [x] Impresión de comanda, cuenta y recibo (impresora térmica 58/80 mm)
- [x] Cobro con propina voluntaria, descuento, efectivo recibido y vueltas
- [x] Cambiar / juntar mesas
- [x] Ventas con propinas y descuentos; exportar a Excel
- [x] Stock opcional y código de barras
- [x] Estaciones cocina / bar (cada una con su tablero y sus avisos)
- [ ] Pago dividido y cierre de caja
- [ ] Planes de pago
