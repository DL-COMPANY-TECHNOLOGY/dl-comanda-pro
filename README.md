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
supabase/v5-*.sql     Pago dividido y mixto
supabase/v6-*.sql     Pedir la cuenta con propina voluntaria preguntada
supabase/v7-*.sql     Caja: apertura, movimientos y cierre
supabase/v8-*.sql     Planes y límites
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
- [x] Pago dividido (partes iguales o por lo que pidió cada uno) y pago con varios medios
- [x] Pedir la cuenta: el mesero pregunta al cliente por la propina voluntaria del 10% y caja recibe el aviso
- [x] Caja: apertura con base, entradas y salidas, cierre con conteo de billetes, faltante/sobrante e historial
- [x] Planes Gratis / Pro / Premium con prueba Premium de 3 días y bono de 7 días de Premium al comprar Pro (activar: `select activar_plan('NIT', 'pro', 1);` en el SQL Editor)
- [x] Precio de lanzamiento -50%: Pro $30.000 y Premium $50.000 al mes (en `config.js`: `LANZAMIENTO: false` para quitarlo)
- [x] Conteo de billetes y monedas al abrir y cerrar la caja; tarjeta y transferencia separadas del efectivo
- [x] Mesa en rojo cada 15 minutos sin cobrar
- [x] Ticket como imagen por WhatsApp (cuenta, recibo y cierre de caja)
- [x] Valores editables al dividir la cuenta
- [x] Excel profesional (.xlsx) con resumen, cobros, pagos, productos y detalle
- [x] Pago anual (14 meses por el precio de 12) y códigos de activación
- [x] Panel DL COMPANY (solo d.l.company.2026@gmail.com): generar y anular códigos, registro de clientes (correo, fecha de creación de la cuenta, último ingreso, plan, fecha en que lo adquirió e historial) con descarga en Excel
- [x] Roles combinables del personal: Mesero, o una o varias funciones de 🍳 Cocina, 🍹 Bar y 💵 Caja (ej. Bar + Caja)
- [x] Guía interactiva con voz para dueño, mesero y cocina, con los planes al final
