# CruiseInRide — Shopify Section

Landing page completa para mostrar la app **CruiseInRide** en tu tienda Shopify.

---

## Archivos generados

```
shopify/
├── sections/
│   └── cruiseinride.liquid   ← Sección principal (HTML + Liquid + JS + Schema)
└── assets/
    └── cruiseinride.css      ← Todos los estilos
```

---

## Cómo instalar en Shopify (paso a paso)

### Paso 1 — Sube el archivo CSS

1. Ve a tu panel de Shopify → **Online Store** → **Themes**
2. Junto a tu tema activo, haz clic en **⋯ → Edit code**
3. En la barra izquierda busca la carpeta **Assets**
4. Haz clic en **Add a new asset** → **Create a blank file**
5. Nómbralo exactamente: `cruiseinride.css`
6. Copia y pega todo el contenido de `shopify/assets/cruiseinride.css`
7. Haz clic en **Save**

### Paso 2 — Sube la sección Liquid

1. En la misma pantalla de edición de código
2. En la barra izquierda busca la carpeta **Sections**
3. Haz clic en **Add a new section** → **Create a blank section**
4. Nómbrala: `cruiseinride`  (Shopify le pondrá la extensión `.liquid`)
5. **Borra** todo el contenido por defecto y pega el contenido de `shopify/sections/cruiseinride.liquid`
6. Haz clic en **Save**

### Paso 3 — Agrega la sección a una página

**Opción A — En el Home (página principal):**
1. Ve a **Online Store → Themes → Customize**
2. Haz clic en **Add section**
3. Busca y selecciona **"CruiseInRide — Landing completa"**
4. Arrastra la sección a la posición que quieras

**Opción B — En una página personalizada:**
1. Ve a **Online Store → Pages** → crea una nueva página (ej. "Descarga la App")
2. Ve a **Themes → Customize** → navega a esa página
3. Agrega la sección igual que en la Opción A

### Paso 4 — Personaliza el contenido

Dentro del editor visual de Shopify podrás editar **sin tocar código**:

| Sección | Qué puedes personalizar |
|---------|------------------------|
| Branding | Logo, nombre de la app, colores |
| Hero | Título, subtítulo, captura de pantalla del teléfono |
| Descarga | URLs de App Store y Google Play |
| App Web | URL del iframe (si tienes Flutter Web hospedado) |
| Cómo funciona | Títulos y descripciones de cada paso (pasajero y conductor) |
| Características | 6 tarjetas de features |
| Vehículos | Nombres, imágenes y capacidades (Sedan, Comfort, SUV) |
| Registro | Tabs de pasajero/conductor, campos del formulario |
| CTA Final | Título y subtítulo del bloque de descarga final |

---

## Secciones incluidas

1. **Hero / Portada** — Título, subtítulo, badges de descarga (App Store / Google Play), mockup del teléfono
2. **Cómo funciona** — Tabs separados para Pasajero y Conductor con 4 pasos cada uno
3. **Características** — 6 tarjetas con las features principales de la app
4. **App Web (iframe)** — Opcional: incrusta la versión Flutter Web de la app
5. **Tipos de vehículo** — Cards para Sedan, Comfort y SUV con imagen y capacidad
6. **Formulario de registro** — Formulario separado para Pasajero y Conductor
7. **CTA Final** — Bloque de descarga al final de la página

---

## Configurar el formulario de registro

Por defecto el formulario muestra un mensaje de éxito en pantalla sin enviar datos.

Para conectarlo a un servicio real:
- **Shopify Contact Form:** pon `/contact` en el campo "URL de envío del formulario"
- **Klaviyo / Mailchimp / Zapier:** usa la URL de su endpoint de integración
- **Tu propio backend:** cualquier URL que acepte POST con los campos `contact[name]`, `contact[email]`, etc.

---

## Colores del tema

Los colores se pueden cambiar desde el editor visual de Shopify.
Si quieres cambiarlos manualmente en el CSS, edita las variables al inicio de `cruiseinride.css`:

```css
--cir-brand:   #1a1a2e;   /* Azul oscuro principal */
--cir-accent:  #e94560;   /* Rojo/rosa de acento */
--cir-mid:     #0f3460;   /* Azul medio */
```

---

## Imágenes sugeridas para subir

Los archivos de imagen de la app están en `assets/images/`:
- `car_sedan.png` → Vehículo 1 (Sedan)
- `car_comfort.png` → Vehículo 2 (Comfort)
- `car_suv.png` → Vehículo 3 (SUV)
- `logoapp.png` → Logo de la app
- `cruise_3.png` / `cruise_6.png` / `cruise_7.png` → Para el Hero o fondo

Súbelas en Shopify → **Content → Files** y cópialas en los campos de imagen del editor.
