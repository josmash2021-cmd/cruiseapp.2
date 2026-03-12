@echo off
chcp 65001 > nul
title 🔒 Cruise Backend + Ngrok - Protección Automática
color 0A

echo.
echo ╔══════════════════════════════════════════════════════════════╗
echo ║  🔒 CRUISE BACKEND + NGROK - PROTECCIÓN AUTOMÁTICA          ║
echo ║  Mantiene ambos servicios activos 24/7                      ║
echo ╚══════════════════════════════════════════════════════════════╝
echo.

cd /d "%~dp0"

:LOOP
echo [%date% %time%] Verificando servicios...

REM ═══════════════════════════════════════════════════════════════
REM  1. VERIFICAR Y REINICIAR BACKEND SI ESTÁ CAÍDO
REM ═══════════════════════════════════════════════════════════════
tasklist /FI "IMAGENAME eq python.exe" /FI "WINDOWTITLE eq *main.py*" 2>nul | find /I "python.exe" >nul
if errorlevel 1 (
    echo [%date% %time%] ⚠️  Backend caído - Reiniciando...
    start "Cruise Backend" /MIN py main.py
    timeout /t 5 /nobreak >nul
) else (
    echo [%date% %time%] ✅ Backend activo
)

REM ═══════════════════════════════════════════════════════════════
REM  2. VERIFICAR Y REINICIAR NGROK SI ESTÁ CAÍDO
REM ═══════════════════════════════════════════════════════════════
tasklist /FI "IMAGENAME eq ngrok.exe" 2>nul | find /I "ngrok.exe" >nul
if errorlevel 1 (
    echo [%date% %time%] ⚠️  Ngrok caído - Reiniciando...
    start "Ngrok Tunnel" /MIN "%LOCALAPPDATA%\ngrok.exe" http 8000
    timeout /t 5 /nobreak >nul
) else (
    echo [%date% %time%] ✅ Ngrok activo
)

REM ═══════════════════════════════════════════════════════════════
REM  3. VERIFICAR CONECTIVIDAD DEL BACKEND
REM ═══════════════════════════════════════════════════════════════
powershell -Command "try { $r = Invoke-WebRequest -Uri 'http://localhost:8000/health' -UseBasicParsing -TimeoutSec 3; exit 0 } catch { exit 1 }" >nul 2>&1
if errorlevel 1 (
    echo [%date% %time%] ❌ Backend no responde - Forzando reinicio...
    taskkill /F /IM python.exe /FI "WINDOWTITLE eq *main.py*" >nul 2>&1
    timeout /t 2 /nobreak >nul
    start "Cruise Backend" /MIN py main.py
    timeout /t 5 /nobreak >nul
) else (
    echo [%date% %time%] ✅ Backend respondiendo correctamente
)

echo [%date% %time%] 💤 Esperando 30 segundos antes de próxima verificación...
echo.
timeout /t 30 /nobreak >nul
goto LOOP
