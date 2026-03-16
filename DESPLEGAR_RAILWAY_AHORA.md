# 🚂 Desplegar en Railway - Guía Paso a Paso

## ✅ Lo Que Ya Tienes Listo

- ✅ Cuenta de Railway
- ✅ Backend FastAPI funcionando
- ✅ `Dockerfile` configurado
- ✅ `railway.toml` configurado
- ✅ `requirements.txt` con todas las dependencias

**Todo está listo para desplegar. Solo toma 10-15 minutos.**

---

## 🚀 PASO 1: Acceder a Railway

1. Abre tu navegador
2. Ve a: **https://railway.app/**
3. Click en **"Login"**
4. Inicia sesión con tu cuenta (GitHub, Google, o email)

---

## 🚀 PASO 2: Crear Nuevo Proyecto

1. En el dashboard de Railway, click en **"New Project"**

2. Selecciona **"Deploy from GitHub repo"**

3. Si es la primera vez:
   - Railway te pedirá autorización para acceder a GitHub
   - Click **"Authorize Railway"**
   - Selecciona los repositorios que Railway puede ver

4. Busca y selecciona tu repositorio: **`cruise-app-main`**

---

## 🚀 PASO 3: Railway Detecta Automáticamente

Railway detectará:
- ✅ Tu `Dockerfile`
- ✅ Tu `railway.toml`
- ✅ Empezará a construir automáticamente

Verás:
```
Building...
[1/5] Pulling base image
[2/5] Installing dependencies
[3/5] Copying files
[4/5] Building application
[5/5] Starting server
```

**Esto tarda 2-5 minutos la primera vez.**

---

## 🚀 PASO 4: Configurar Variables de Entorno

Mientras se construye, configura las variables:

1. Click en tu servicio (aparecerá como "cruise-app-main")

2. Click en la pestaña **"Variables"**

3. Agrega estas variables (click "+ New Variable" para cada una):

```
API_KEY=cruise-api-key-production-2026
JWT_SECRET=cruise-jwt-secret-super-seguro-cambiar-esto
STRIPE_SECRET_KEY=sk_test_51... (tu key de Stripe)
STRIPE_PUBLISHABLE_KEY=pk_test_51... (tu key de Stripe)
```

**Importante:** Cambia `API_KEY` y `JWT_SECRET` por valores únicos y seguros.

4. Click **"Save"** o las variables se guardan automáticamente

---

## 🚀 PASO 5: Generar Dominio Público

1. Click en la pestaña **"Settings"**

2. Scroll hasta la sección **"Domains"**

3. Click en **"Generate Domain"**

4. Railway generará una URL como:
   ```
   https://cruise-app-production.up.railway.app
   ```

5. **COPIA ESTA URL** - la necesitarás

---

## 🚀 PASO 6: Verificar que Funciona

1. Abre una nueva pestaña del navegador

2. Ve a tu URL + `/health`:
   ```
   https://tu-app.up.railway.app/health
   ```

3. Deberías ver:
   ```json
   {"status": "ok"}
   ```

4. También puedes ver la documentación de la API:
   ```
   https://tu-app.up.railway.app/docs
   ```

---

## 🚀 PASO 7: Actualizar App Flutter (Opcional)

Tu app ya está configurada para detectar Railway automáticamente, pero si quieres forzar la URL:

1. Abre: `lib/services/api_service.dart`

2. Actualiza la línea 27:
   ```dart
   static const String _productionUrl = 'https://TU-URL-DE-RAILWAY.up.railway.app';
   ```

3. Guarda el archivo

4. Reinicia la app Flutter (presiona 'R')

---

## 🎯 PASO 8: Probar desde tu Teléfono

1. Abre la app en tu teléfono (con datos móviles)

2. La app debería conectarse automáticamente a Railway

3. Prueba:
   - Registro de usuario
   - Login
   - Solicitar viaje

**¡Debería funcionar desde cualquier lugar!**

---

## 📊 Monitorear tu Deployment

### Ver Logs en Tiempo Real

1. En Railway, click en tu servicio
2. Tab **"Deployments"**
3. Click en el deployment activo
4. Verás logs en tiempo real:
   ```
   INFO:     Started server process
   INFO:     Waiting for application startup
   INFO:     Application startup complete
   INFO:     Uvicorn running on http://0.0.0.0:8000
   ```

### Ver Métricas

1. Tab **"Metrics"**
2. Verás:
   - CPU usage
   - Memory usage
   - Network traffic
   - Request count

---

## 🔧 Troubleshooting

### El deployment falla

**Revisa los logs:**
1. Tab "Deployments"
2. Click en el deployment fallido
3. Lee el error

**Errores comunes:**

**Error: "Port already in use"**
- Solución: Railway maneja esto automáticamente, solo redeploy

**Error: "Module not found"**
- Solución: Verifica que `requirements.txt` tenga todas las dependencias
- Redeploy

**Error: "Database connection failed"**
- Solución: Agrega PostgreSQL plugin (ver abajo)

### Agregar PostgreSQL (Opcional)

Si quieres migrar de SQLite a PostgreSQL:

1. En tu proyecto de Railway, click **"+ New"**
2. Selecciona **"Database"** → **"PostgreSQL"**
3. Railway creará la base de datos automáticamente
4. Copia la `DATABASE_URL` a las variables de entorno
5. Tu código ya soporta PostgreSQL automáticamente

---

## 💰 Costos

Railway cobra por:
- **Tiempo de CPU:** ~$0.000463/min
- **Memoria:** ~$0.000231/GB/min
- **Network:** Gratis hasta 100GB/mes

**Estimación para tu app:**
- Backend pequeño: **$5-10/mes**
- Con PostgreSQL: **$5-15/mes**

**Plan Hobby:** $5/mes + uso
**Plan Pro:** $20/mes + uso

---

## 🎉 ¡Listo!

Una vez desplegado:

✅ Tu servidor está activo 24/7
✅ Accesible desde cualquier lugar
✅ Funciona con datos móviles
✅ HTTPS automático
✅ Auto-reinicio si falla
✅ Auto-deploy con cada push a GitHub

---

## 🔄 Actualizar el Deployment

Cada vez que hagas cambios:

1. Commit y push a GitHub:
   ```bash
   git add .
   git commit -m "Update backend"
   git push
   ```

2. Railway detecta el push automáticamente
3. Redeploy automático
4. Listo en 2-3 minutos

---

## 📞 Soporte

Si tienes problemas:

1. **Revisa logs** en Railway dashboard
2. **Verifica variables** de entorno
3. **Prueba el endpoint** `/health`
4. **Pregúntame** y te ayudo

---

## 🎯 Próximos Pasos Después del Deploy

1. ✅ Verificar que `/health` responde
2. ✅ Probar desde tu teléfono con datos móviles
3. ✅ Configurar dominio personalizado (opcional)
4. ✅ Agregar PostgreSQL (opcional)
5. ✅ Configurar notificaciones de Railway

---

**¿Listo para empezar? Sigue los pasos y avísame si necesitas ayuda en algún paso.**
