# 🚂 Railway Deployment Guide - Cruise App Backend

## Opción 1: Desplegar desde Railway Dashboard (Recomendado)

### Paso 1: Acceder a Railway
1. Ve a https://railway.app/
2. Inicia sesión con tu cuenta
3. Busca tu proyecto "cruise-app" o crea uno nuevo

### Paso 2: Conectar el Repositorio
Si aún no está conectado:
1. Click en "New Project"
2. Selecciona "Deploy from GitHub repo"
3. Autoriza Railway a acceder a tu repositorio
4. Selecciona el repositorio `cruise-app-main`

### Paso 3: Configurar Variables de Entorno
En el dashboard de Railway, ve a "Variables" y agrega:

```
DATABASE_URL=postgresql://...  (Railway te proveerá esto si agregas PostgreSQL)
API_KEY=tu-api-key-segura
JWT_SECRET=tu-jwt-secret-seguro
STRIPE_SECRET_KEY=sk_test_...
STRIPE_PUBLISHABLE_KEY=pk_test_...
PORT=8000
```

### Paso 4: Desplegar
1. Railway detectará automáticamente el `Dockerfile`
2. Click en "Deploy" o haz un push a tu repositorio
3. Railway construirá y desplegará automáticamente

### Paso 5: Obtener la URL
1. En el dashboard, ve a "Settings" → "Domains"
2. Click en "Generate Domain"
3. Copia la URL generada (ej: `cruise-app-production.up.railway.app`)

### Paso 6: Configurar Auto-Deploy
Railway ya tiene auto-deploy configurado por defecto:
- ✅ Se reinicia automáticamente si falla (configurado en `railway.toml`)
- ✅ Se redespliega automáticamente con cada push a GitHub
- ✅ Healthcheck cada 60 segundos en `/health`

---

## Opción 2: Desplegar desde CLI (Requiere Instalación)

### Instalar Railway CLI

**Windows (PowerShell como Administrador):**
```powershell
iwr https://railway.app/install.ps1 | iex
```

**O descarga directamente:**
https://github.com/railwayapp/cli/releases

### Comandos Básicos

```bash
# Login
railway login

# Vincular proyecto existente
railway link

# O crear nuevo proyecto
railway init

# Desplegar
railway up

# Ver logs en tiempo real
railway logs

# Abrir dashboard
railway open

# Ver variables de entorno
railway variables

# Agregar variable
railway variables set API_KEY=tu-valor

# Ver status
railway status
```

---

## Configuración Actual del Proyecto

### `railway.toml`
```toml
[build]
builder = "DOCKERFILE"
dockerfilePath = "Dockerfile"

[deploy]
healthcheckPath = "/health"
healthcheckTimeout = 60
restartPolicyType = "ON_FAILURE"
restartPolicyMaxRetries = 3
```

**Esto significa:**
- ✅ Railway usará el Dockerfile para construir
- ✅ Verificará `/health` cada 60 segundos
- ✅ Se reiniciará automáticamente si falla (hasta 3 intentos)

### `Dockerfile`
```dockerfile
FROM python:3.12-slim
WORKDIR /app
COPY backend/requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY backend/ .
EXPOSE 8000
CMD ["sh", "-c", "uvicorn main:app --host 0.0.0.0 --port ${PORT:-8000} --log-level info"]
```

---

## Actualizar la App Flutter con la URL de Railway

Una vez desplegado, actualiza la URL en tu app:

### Opción A: Usar Firestore (Recomendado)
1. Ve a Firebase Console → Firestore
2. Crea/actualiza el documento `config/server`
3. Agrega el campo `tunnel_url` con tu URL de Railway
4. La app lo detectará automáticamente

### Opción B: Actualizar Código
En `lib/services/api_service.dart`:

```dart
static const String _defaultTunnelUrl = 
    'https://tu-app.up.railway.app';
```

---

## Monitoreo y Logs

### Ver Logs en Tiempo Real
1. Dashboard de Railway → Tu servicio → "Logs"
2. O usa CLI: `railway logs -f`

### Métricas
Railway muestra automáticamente:
- CPU usage
- Memory usage
- Network traffic
- Request count

### Alertas
Configura notificaciones en Settings → Notifications para:
- Deployment failures
- Service crashes
- High resource usage

---

## Troubleshooting

### El servidor no inicia
1. Revisa los logs en Railway dashboard
2. Verifica que todas las variables de entorno estén configuradas
3. Asegúrate que `requirements.txt` tenga todas las dependencias

### Error de conexión a la base de datos
1. Agrega el plugin PostgreSQL en Railway
2. Copia la `DATABASE_URL` a las variables de entorno
3. El código ya maneja la conversión automática de `postgres://` a `postgresql+asyncpg://`

### El healthcheck falla
1. Verifica que el endpoint `/health` responda 200 OK
2. Aumenta el timeout en `railway.toml` si es necesario

### Deployment lento
1. Railway puede tardar 2-5 minutos en el primer deploy
2. Los siguientes deploys son más rápidos (usa cache)

---

## Costos

Railway ofrece:
- **Plan Hobby**: $5/mes + uso
- **Plan Pro**: $20/mes + uso
- Créditos gratis mensuales para empezar

El backend de Cruise debería costar ~$5-10/mes en el plan Hobby.

---

## Ventajas de Railway

✅ **Siempre Activo**: El servidor nunca se apaga (a diferencia de localhost)
✅ **Auto-Restart**: Se reinicia automáticamente si falla
✅ **HTTPS Gratis**: Certificado SSL incluido
✅ **Acceso Global**: Funciona desde cualquier red (WiFi, celular, etc.)
✅ **Auto-Deploy**: Se actualiza automáticamente con cada push a GitHub
✅ **Logs Persistentes**: Guarda logs para debugging
✅ **Escalable**: Puede manejar más usuarios fácilmente

---

## Próximos Pasos

1. ✅ Despliega en Railway usando el dashboard
2. ✅ Obtén la URL de producción
3. ✅ Actualiza Firestore o el código con la nueva URL
4. ✅ Prueba la app desde tu teléfono
5. ✅ Configura notificaciones para estar al tanto de problemas

**¡Tu servidor estará activo 24/7 sin necesidad de mantener tu PC encendida!**
