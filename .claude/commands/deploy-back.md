---
description: Deploy backend a Railway con validaciones previas
argument-hint: "[mensaje-commit-opcional]"
---

Ejecuta el flujo completo de deploy del backend Cruise a Railway.

## Pasos a seguir

1. **Verificar estado git:**
   - Corre `git status` para ver qué hay staged/unstaged
   - Si NO hay cambios, reporta "nada que deployar" y para aquí
   - Si hay cambios en `backend/` sin commit, continúa

2. **Sintaxis check rápido:**
   - Identifica todos los `.py` modificados en `backend/`
   - Corre `python -m py_compile <archivo>` en cada uno
   - Si alguno falla, reporta el error y DETENTE — no deploys código roto

3. **Commit si hay cambios:**
   - Si el usuario pasó un mensaje como argumento ($ARGUMENTS), úsalo
   - Si no, analiza el diff con `git diff --staged backend/` y genera un mensaje tipo:
     `fix(backend): descripción corta del cambio principal`
     o `feat(backend): ...` según el tipo de cambio
   - Solo agrega archivos dentro de `backend/` al commit (nunca `git add -A`)
   - Commit con Co-Authored-By estándar

4. **Push al remote:**
   - `git push`
   - Si falla (conflicto, auth), reporta y detente

5. **Deploy directo a Railway (bypass GitHub CI):**
   - `railway up --detach`
   - Captura el build URL del output

6. **Esperar y verificar:**
   - Espera ~60 segundos
   - Lee últimas 20 líneas de `railway logs`
   - Busca patrones de error: `ERROR`, `SyntaxError`, `Traceback`, `healthcheck fail`
   - Si encuentras errores, reporta y sugiere rollback con el commit anterior

7. **Reporte final:**
   - ✅ Deploy exitoso → muestra el build URL
   - ❌ Deploy fallido → muestra el error + comando para revertir

## Notas

- **NUNCA** uses `git add -A` o `git add .` — solo archivos específicos de backend/
- **NUNCA** hagas deploy si hay errores de sintaxis Python
- **NUNCA** uses `--no-verify` aunque un hook pre-commit falle — investiga la causa
- Si Railway CLI no está disponible, reporta que el usuario debe correr `railway up --detach` manualmente

Argumento opcional: mensaje de commit custom. Si no se pasa, se genera automáticamente del diff.
