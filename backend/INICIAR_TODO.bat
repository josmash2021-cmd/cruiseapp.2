@echo off
chcp 65001 > nul
title 🚀 Cruise - Inicio Completo
color 0B

echo.
echo ╔══════════════════════════════════════════════════════════════╗
echo ║  🚀 CRUISE - INICIO COMPLETO DE SERVICIOS                   ║
echo ╚══════════════════════════════════════════════════════════════╝
echo.

cd /d "%~dp0"

REM Detener procesos previos
echo [1/4] 🛑 Deteniendo servicios previos...
taskkill /F /IM python.exe /FI "WINDOWTITLE eq *main.py*" >nul 2>&1
taskkill /F /IM ngrok.exe >nul 2>&1
timeout /t 2 /nobreak >nul

REM Iniciar Backend
echo [2/4] 🔧 Iniciando Backend en puerto 8000...
start "Cruise Backend" /MIN py main.py
timeout /t 5 /nobreak >nul

REM Iniciar Ngrok
echo [3/4] 🌐 Iniciando Ngrok Tunnel...
start "Ngrok Tunnel" /MIN "%LOCALAPPDATA%\ngrok.exe" http 8000
timeout /t 5 /nobreak >nul

REM Iniciar Protección Automática
echo [4/4] 🔒 Iniciando Protección Automática...
start "Protección Automática" /MIN "%~dp0MANTENER_ACTIVO.bat"

echo.
echo ╔══════════════════════════════════════════════════════════════╗
echo ║  ✅ TODOS LOS SERVICIOS INICIADOS                           ║
echo ║                                                              ║
echo ║  Backend:    http://localhost:8000                          ║
echo ║  Ngrok:      https://jaida-intervarsity-tashina...          ║
echo ║  Protección: Activa (monitoreo cada 30s)                    ║
echo ╚══════════════════════════════════════════════════════════════╝
echo.
echo Presiona cualquier tecla para cerrar esta ventana...
pause >nul
