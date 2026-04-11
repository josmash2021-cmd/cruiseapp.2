---
description: Chequeo rápido de salud del backend Cruise en producción
---

Ejecuta un chequeo de salud del sistema Cruise en producción y reporta anomalías.

## Qué revisar (en este orden)

### 1. Estado del último deploy Railway
- Corre `railway logs | tail -50` para ver logs recientes
- Busca indicadores de healthcheck OK vs fallido
- Reporta si el server está respondiendo a `/ping`

### 2. Errores recientes en logs
- Del output de `railway logs | tail -100`, cuenta:
  - Cuántos `500` hay
  - Cuántos `409 Conflict` hay (trip state conflicts)
  - Cuántos `403 Forbidden` hay
  - Cuántos `Traceback` o `ERROR` hay
- Si hay más de 5 de cualquier tipo, es una anomalía
- Muestra hasta 3 ejemplos representativos de cada error

### 3. Patrones críticos a buscar
Grepea los logs buscando estos warnings/errores específicos del sistema Cruise:

- `[GhostDriver]` — ¿está kickeando drivers que no debería?
- `[Guard] Blocked stale cancel` — ¿alguien intentando cancelar trips asignados?
- `[TripStatus] Rejected transition` — ¿hay 409s bloqueando drivers legítimos?
- `[Cascade] Trip.*exhausted` — ¿trips sin drivers disponibles?
- `[FCM].*failed` — ¿push notifications fallando en batch?
- `[Stripe]` con ERROR — ¿pagos fallando?

### 4. Commits recientes que puedan haber causado issues
- Corre `git log --oneline -10`
- Muestra los últimos 10 commits
- Si alguno es un "fix" reciente (< 24h), márcalo como "verificar en producción"

### 5. Estado del working tree
- `git status` — ¿hay cambios sin commitear que debieron haberse deployado?
- Si hay archivos `.py` modificados en `backend/` sin commit, flag como "deploy pendiente"

## Formato del reporte

Usa emojis para semáforo visual:

```
🏥 CRUISE HEALTH REPORT — {timestamp}

🟢/🟡/🔴 Railway Deploy: {estado}
🟢/🟡/🔴 Error rate: {X} 5xx, {Y} 409s, {Z} 403s en últimas 100 líneas
🟢/🟡/🔴 Ghost driver agent: {comportamiento}
🟢/🟡/🔴 Dispatch cascade: {estado}
🟢/🟡/🔴 FCM push: {estado}
🟢/🟡/🔴 Stripe: {estado}

📝 Commits recientes (últimas 24h):
- commit1
- commit2

⚠️ Cambios sin deployar: {lista o "ninguno"}

🔥 Acción recomendada: {próximo paso concreto o "todo OK"}
```

## Notas

- NO modifiques archivos, solo lectura
- NO hagas deploys automáticos aunque detectes problemas
- Si `railway` CLI falla, reporta que el usuario debe correrlo manualmente
- Sé breve — este es un "dashboard", no un análisis completo
