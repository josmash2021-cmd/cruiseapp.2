@echo off
chcp 65001 > nul
title CRUISE - Backend + Tunnel
color 0B

echo.
echo ================================================================
echo   CRUISE - INICIO AUTOMATICO (Backend + Tunnel + Firestore)
echo ================================================================
echo.

cd /d "%~dp0"

REM ── 1. Kill previous instances ──
echo [1/5] Deteniendo servicios previos...
taskkill /F /IM cloudflared.exe >nul 2>&1
timeout /t 1 /nobreak >nul

REM ── 2. Check if backend is running ──
echo [2/5] Verificando backend en puerto 8000...
powershell -Command "try { $r = Invoke-WebRequest -Uri 'http://localhost:8000/health' -TimeoutSec 3 -UseBasicParsing; if ($r.StatusCode -eq 200) { Write-Host '    Backend ya esta corriendo.' } } catch { Write-Host '    Iniciando backend...'; Start-Process -FilePath 'py' -ArgumentList 'main.py' -WindowStyle Minimized; Start-Sleep -Seconds 5 }"

REM ── 3. Start Cloudflare tunnel ──
echo [3/5] Iniciando Cloudflare Tunnel...
del /Q tunnel.log >nul 2>&1
start "" /MIN cloudflared.exe tunnel --url http://localhost:8000 --logfile "%~dp0tunnel.log"

REM ── 4. Wait for tunnel URL to appear in log ──
echo [4/5] Esperando URL del tunnel...
:WAIT_LOOP
timeout /t 2 /nobreak >nul
findstr /C:"trycloudflare.com" tunnel.log >nul 2>&1
if %ERRORLEVEL% NEQ 0 goto WAIT_LOOP
echo     Tunnel activo!

REM ── 5. Write tunnel URL to Firestore ──
echo [5/5] Actualizando Firestore con URL del tunnel...
py update_tunnel_url.py
if %ERRORLEVEL% EQU 0 (
    echo.
    echo ================================================================
    echo   TODOS LOS SERVICIOS ACTIVOS
    echo.
    echo   Backend:    http://localhost:8000
    for /f "tokens=*" %%a in ('powershell -Command "[regex]::Match((Get-Content tunnel.log -Raw), 'https://[a-z0-9-]+\.trycloudflare\.com').Value"') do echo   Tunnel:     %%a
    echo   Firestore:  config/server actualizado
    echo.
    echo   La app se conectara automaticamente desde cualquier red.
    echo ================================================================
) else (
    echo [WARN] No se pudo actualizar Firestore, pero el tunnel esta activo.
    echo        Verifica serviceAccountKey.json y firebase_admin instalado.
)
echo.
echo Presiona cualquier tecla para cerrar (los servicios siguen corriendo)...
pause >nul
