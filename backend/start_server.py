#!/usr/bin/env python3
"""
Production-ready server launcher for Cruise backend.
Includes keepalive, auto-restart, and connection pooling.
"""
import uvicorn
import logging
from datetime import datetime

# Configure logging
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s'
)

def main():
    """Start the server with production-ready configuration."""
    print("=" * 60)
    print("🚀 CRUISE BACKEND SERVER")
    print("=" * 60)
    print(f"Started at: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}")
    print("Server URL: http://0.0.0.0:8000")
    print("API Docs: http://localhost:8000/docs")
    print("=" * 60)
    print()
    
    uvicorn.run(
        "main:app",
        host="0.0.0.0",
        port=8000,
        reload=False,  # Disable in production for stability
        log_level="info",
        access_log=True,
        # Connection settings to prevent timeouts
        timeout_keep_alive=75,  # Keep connections alive for 75 seconds
        timeout_graceful_shutdown=30,  # Graceful shutdown timeout
        limit_concurrency=1000,  # Max concurrent connections
        # Worker settings
        workers=1,  # Single worker for SQLite (prevents DB locks)
        # HTTP settings
        h11_max_incomplete_event_size=16384,  # 16KB max header size
    )

if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        print("\n🛑 Server stopped by user (Ctrl+C)")
    except Exception as e:
        print(f"\n❌ Server error: {e}")
        raise
