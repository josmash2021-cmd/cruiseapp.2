@echo off
chcp 65001 > nul
title 🛑 Cruise - Detener Servicios
color 0C

echo.
echo ╔══════════════════════════════════════════════════════════════╗
echo ║  🛑 CRUISE - DETENER TODOS LOS SERVICIOS                    ║
echo ╚══════════════════════════════════════════════════════════════╝
echo.

echo Deteniendo Backend...
taskkill /F /IM python.exe /FI "WINDOWTITLE eq *main.py*" >nul 2>&1

echo Deteniendo Ngrok...
taskkill /F /IM ngrok.exe >nul 2>&1

echo Deteniendo Protección Automática...
taskkill /F /FI "WINDOWTITLE eq *MANTENER_ACTIVO*" >nul 2>&1

echo.
echo ✅ Todos los servicios detenidos
echo.
timeout /t 3 /nobreak >nul
