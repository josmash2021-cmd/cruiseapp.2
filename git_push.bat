@echo off
echo ============================================
echo SUBIENDO CAMBIOS A GITHUB
echo ============================================
echo.

cd /d C:\Users\Puma\CascadeProjects\cruise-app-main

echo [1/4] Verificando estado de Git...
git status
echo.

echo [2/4] Agregando todos los archivos modificados...
git add .
echo.

echo [3/4] Creando commit...
git commit -m "Fix iOS map dark mode (mutedStandard) and driver profile photo live updates

DRIVER HOME SCREEN:
- Fix iOS map to use AppleMap instead of GoogleMap
- Apply mutedStandard map style for dark appearance on iOS
- Add UserSession.photoNotifier listener for live profile photo updates
- Profile photo now updates immediately when driver changes it

iOS MAP STYLING:
- mutedStandard provides dark/neutral appearance matching Android dark theme
- Platform-specific map rendering (AppleMap iOS, GoogleMap Android)"
echo.

echo [4/4] Subiendo a GitHub...
git push origin main
echo.

echo ============================================
echo COMPLETADO
echo ============================================
pause
