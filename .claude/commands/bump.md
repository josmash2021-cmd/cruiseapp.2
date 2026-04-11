---
description: Bump version en pubspec.yaml + commit + push
argument-hint: "[nuevo-build-number, ej: 293]"
---

Sube la versión de la app Cruise en `pubspec.yaml` y prepara para build.

## Pasos

1. **Leer versión actual:**
   - Lee `pubspec.yaml` y encuentra la línea `version: 1.0.2+XXX`
   - Extrae el número de build actual

2. **Determinar nueva versión:**
   - Si $ARGUMENTS tiene un número (ej: `293`), úsalo como nuevo build
   - Si NO hay argumento, incrementa +1 automáticamente (XXX+1)
   - Mantén el prefijo `1.0.2+` (solo bumpeas el build number)

3. **Editar pubspec.yaml:**
   - Usa Edit tool para reemplazar la línea exacta
   - Old: `version: 1.0.2+{actual}`
   - New: `version: 1.0.2+{nuevo}`

4. **Commit:**
   - `git add pubspec.yaml`
   - `git commit -m "chore: bump version to 1.0.2+{nuevo}"` + Co-Authored-By estándar

5. **Push:**
   - `git push`

6. **Reporte final con next steps:**
   ```
   ✅ Version bumpeada a 1.0.2+{nuevo}
   
   Próximos pasos manuales (no ejecutar automático):
   - 📱 Android: lanzar Shorebird patch (o release si hay cambios nativos)
   - 🍎 iOS: lanzar Codemagic build
   ```

## Notas importantes

- **NO lances builds automáticamente** — Shorebird y Codemagic los maneja el usuario
- **NO toques otros archivos** — solo pubspec.yaml
- Si el bump dejaría la versión igual o menor que la actual, reporta error y detente
- El archivo está en la raíz del proyecto: `c:\Users\Puma\cruiseapp.2\pubspec.yaml`
