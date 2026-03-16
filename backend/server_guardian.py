"""
Server Guardian - Mantiene el servidor backend siempre activo
Reinicia automáticamente si el servidor falla o se detiene
"""
import subprocess
import time
import sys
import os
from datetime import datetime
import signal

class ServerGuardian:
    def __init__(self):
        self.process = None
        self.restart_count = 0
        self.start_time = None
        self.running = True
        
    def log(self, message):
        """Log con timestamp"""
        timestamp = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
        print(f"[{timestamp}] {message}")
        sys.stdout.flush()
    
    def start_server(self):
        """Inicia el servidor backend"""
        try:
            self.log("🚀 Iniciando servidor backend...")
            
            # Cambiar al directorio backend
            backend_dir = os.path.dirname(os.path.abspath(__file__))
            
            # Comando para iniciar el servidor
            cmd = [sys.executable, "main.py"]
            
            # Iniciar proceso
            self.process = subprocess.Popen(
                cmd,
                cwd=backend_dir,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                universal_newlines=True,
                bufsize=1
            )
            
            self.start_time = datetime.now()
            self.restart_count += 1
            
            self.log(f"✅ Servidor iniciado (PID: {self.process.pid}, Intento #{self.restart_count})")
            
            return True
            
        except Exception as e:
            self.log(f"❌ Error al iniciar servidor: {e}")
            return False
    
    def is_server_running(self):
        """Verifica si el servidor está corriendo"""
        if self.process is None:
            return False
        
        # Verificar si el proceso sigue vivo
        poll = self.process.poll()
        return poll is None
    
    def stop_server(self):
        """Detiene el servidor de forma segura"""
        if self.process:
            self.log("🛑 Deteniendo servidor...")
            try:
                self.process.terminate()
                self.process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.log("⚠️ Forzando cierre del servidor...")
                self.process.kill()
            self.process = None
    
    def monitor_output(self):
        """Lee y muestra la salida del servidor"""
        if self.process and self.process.stdout:
            try:
                line = self.process.stdout.readline()
                if line:
                    print(line.rstrip())
                    sys.stdout.flush()
            except:
                pass
    
    def run(self):
        """Loop principal del guardian"""
        self.log("=" * 70)
        self.log("🛡️  SERVER GUARDIAN ACTIVADO")
        self.log("=" * 70)
        self.log("El servidor se reiniciará automáticamente si falla")
        self.log("Presiona Ctrl+C para detener")
        self.log("=" * 70)
        
        # Configurar manejador de señales para cierre limpio
        def signal_handler(sig, frame):
            self.log("\n🛑 Señal de cierre recibida...")
            self.running = False
            self.stop_server()
            sys.exit(0)
        
        signal.signal(signal.SIGINT, signal_handler)
        signal.signal(signal.SIGTERM, signal_handler)
        
        # Iniciar servidor por primera vez
        self.start_server()
        
        # Loop de monitoreo
        last_check = time.time()
        check_interval = 5  # Verificar cada 5 segundos
        
        while self.running:
            try:
                # Leer salida del servidor
                self.monitor_output()
                
                # Verificar estado cada intervalo
                current_time = time.time()
                if current_time - last_check >= check_interval:
                    last_check = current_time
                    
                    if not self.is_server_running():
                        uptime = (datetime.now() - self.start_time).total_seconds() if self.start_time else 0
                        
                        self.log("=" * 70)
                        self.log(f"⚠️  SERVIDOR CAÍDO (estuvo activo {uptime:.0f}s)")
                        self.log("=" * 70)
                        
                        # Esperar un poco antes de reiniciar
                        self.log("⏳ Esperando 3 segundos antes de reiniciar...")
                        time.sleep(3)
                        
                        # Reiniciar
                        self.start_server()
                
                # Pequeña pausa para no consumir CPU
                time.sleep(0.1)
                
            except KeyboardInterrupt:
                break
            except Exception as e:
                self.log(f"❌ Error en loop de monitoreo: {e}")
                time.sleep(1)
        
        # Cleanup
        self.stop_server()
        self.log("👋 Guardian detenido")

if __name__ == "__main__":
    guardian = ServerGuardian()
    guardian.run()
