---
description: Workflow para bugfix urgente — diagnose, fix, test, deploy
argument-hint: "<descripción del bug>"
---

Ejecuta un workflow de hotfix urgente para Cruise. Usa esto cuando hay un bug activo en producción que afecta usuarios reales.

## Input requerido
El usuario debe describir el bug como argumento: $ARGUMENTS

Si $ARGUMENTS está vacío, pregunta "¿Cuál es el bug?" y detente.

## Workflow

### Fase 1: Diagnóstico (no tocar código aún)

1. **Entender el bug:**
   - Parsea la descripción del usuario
   - Identifica: ¿es backend, frontend, o ambos?
   - Identifica: ¿involucra dinero (Stripe), dispatch, tracking, auth, o FCM?

2. **Buscar el archivo relevante:**
   - Usa Grep/Glob para encontrar el código probablemente afectado
   - Lee el archivo entero (o sección relevante) — NO edites todavía
   - Identifica la función/método del bug

3. **Revisar logs recientes:**
   - Corre `railway logs | tail -50`
   - Busca errores relacionados al área del bug
   - Reporta cualquier pattern que coincida

4. **Reporte de diagnóstico al usuario:**
   ```
   🔍 DIAGNÓSTICO
   Archivo sospechoso: <path:line>
   Causa probable: <explicación 1-2 líneas>
   Logs relacionados: <sí/no + ejemplo>
   Plan de fix propuesto: <qué voy a cambiar>
   
   ¿Continúo con el fix? (responde "sí" o correcciones)
   ```

5. **ESPERAR confirmación del usuario** antes de Fase 2.

### Fase 2: Fix (solo si usuario dice sí)

6. **Aplicar el fix:**
   - Usa Edit tool con cambios mínimos y quirúrgicos
   - NO refactorices código circundante
   - NO agregues features "de paso"
   - Solo arregla el bug descrito

7. **Validación sintáctica:**
   - Si es `.py`: `python -m py_compile <archivo>`
   - Si es `.dart`: nota que no hay compile rápido, confiar en Edit
   - Si falla, reporta el error y espera corrección del usuario

### Fase 3: Deploy

8. **Commit con mensaje descriptivo:**
   - Formato: `fix(<scope>): <descripción>`
   - Scope: `backend`, `tracking`, `dispatch`, `trips`, `drivers`, `payments`, `chat`, etc.
   - Body: explicar QUÉ se arregló y POR QUÉ era un bug
   - Co-Authored-By estándar

9. **Push:**
   - `git push`

10. **Deploy directo si es backend:**
    - Si el fix tocó `backend/`, corre `railway up --detach`
    - Espera ~60s y lee `railway logs | tail -30` para validar

11. **Reporte final:**
    ```
    ✅ HOTFIX DEPLOYED
    Commit: <hash>
    Archivos: <lista>
    Deploy: <estado>
    
    Próximo paso: <verificar en app / bumpear versión / monitorear logs>
    ```

## Reglas estrictas

- **NUNCA** hagas fix sin diagnóstico previo
- **NUNCA** skipees el paso de confirmación del usuario
- **NUNCA** modifiques archivos fuera del scope del bug
- **NUNCA** uses `--no-verify` en commits
- Si el bug requiere cambio en frontend (Flutter), recuerda que necesita build de Shorebird/Codemagic DESPUÉS — no es hotfix instantáneo
- Si el bug es crítico (dinero, auth, crashes) y no puedes diagnosticarlo en 3 intentos, reporta "necesito más contexto" y pregunta

## Ejemplo de uso

```
/hotfix rider tracking se queda pegado cuando trip se cancela desde dispatch
/hotfix payout se duplica cuando un cashout falla y se reintenta
/hotfix driver no recibe push notification de nuevo trip
```
