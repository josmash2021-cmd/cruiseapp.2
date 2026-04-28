#!/usr/bin/env python3
"""
Script para obtener logs de Railway y guardarlos en un archivo.

Uso:
    python scripts/get_railway_logs.py

Requiere:
    - Railway CLI instalado: npm install -g @railway/cli
    - Estar logueado: railway login
"""

import subprocess
import sys
from datetime import datetime

def get_logs():
    """Obtiene logs de Railway y los guarda en un archivo."""
    timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
    output_file = f"railway_logs_{timestamp}.txt"
    
    print("Obteniendo logs de Railway...")
    print("   Esto puede tardar unos segundos...")
    
    try:
        # Obtener logs (ultimas 200 lineas)
        result = subprocess.run(
            ["railway", "logs", "--project", "cruiseapp2", "--tail", "200"],
            capture_output=True,
            text=True,
            timeout=30
        )
        
        if result.returncode != 0:
            print(f"Error: {result.stderr}")
            return None
            
        logs = result.stdout
        
        # Guardar en archivo
        with open(output_file, "w", encoding="utf-8") as f:
            f.write(f"=== Railway Logs - {datetime.now()} ===\n\n")
            f.write(logs)
        
        print(f"Logs guardados en: {output_file}")
        print(f"   Total de lineas: {len(logs.splitlines())}")
        
        # Mostrar ultimas 50 lineas
        lines = logs.splitlines()
        print(f"\nUltimas 50 lineas:\n")
        for line in lines[-50:]:
            print(line)
            
        return output_file
        
    except subprocess.TimeoutExpired:
        print("Timeout - Railway no respondio a tiempo")
        return None
    except FileNotFoundError:
        print("Railway CLI no encontrado")
        print("   Instala con: npm install -g @railway/cli")
        return None
    except Exception as e:
        print(f"Error inesperado: {e}")
        return None

def analyze_logs(log_file):
    """Analiza los logs buscando errores comunes."""
    if not log_file:
        return
        
    with open(log_file, "r", encoding="utf-8") as f:
        logs = f.read()
    
    lines = logs.splitlines()
    
    # Buscar patrones de error
    errors = []
    warnings = []
    socket_io_logs = []
    trip_logs = []
    
    for line in lines:
        lower = line.lower()
        
        if any(x in lower for x in ["error", "exception", "traceback", "failed", "crash"]):
            errors.append(line)
        elif any(x in lower for x in ["warning", "warn"]):
            warnings.append(line)
        elif "socket.io" in lower or "socketio" in lower:
            socket_io_logs.append(line)
        elif any(x in lower for x in ["trip", "driver", "ride", "dispatch"]):
            trip_logs.append(line)
    
    print(f"\nAnalisis de logs:\n")
    print(f"   Errores encontrados: {len(errors)}")
    print(f"   Warnings: {len(warnings)}")
    print(f"   Logs de Socket.io: {len(socket_io_logs)}")
    print(f"   Logs de trips/drivers: {len(trip_logs)}")
    
    if errors:
        print(f"\nERRORES ({len(errors)}):\n")
        for err in errors[-10:]:  # Ultimos 10 errores
            print(f"   {err}")
    
    if socket_io_logs:
        print(f"\nSOCKET.IO ({len(socket_io_logs)}):\n")
        for log in socket_io_logs[-10:]:
            print(f"   {log}")
    
    if trip_logs:
        print(f"\nTRIPS/DRIVERS ({len(trip_logs)}):\n")
        for log in trip_logs[-10:]:
            print(f"   {log}")

if __name__ == "__main__":
    print("=" * 60)
    print("  Railway Logs Fetcher")
    print("=" * 60)
    
    log_file = get_logs()
    
    if log_file:
        analyze_logs(log_file)
        print(f"\nPara ver el archivo completo:")
        print(f"   type {log_file}")
    else:
        print("\nNo se pudieron obtener los logs")
        print("\nAlternativas:")
        print("   1. Ve a https://railway.app/dashboard")
        print("   2. Selecciona tu proyecto")
        print("   3. Copia los logs manualmente")
