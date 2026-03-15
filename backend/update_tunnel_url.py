"""
Writes the current Cloudflare tunnel URL to Firestore so the app can
discover it from any network.

Usage:
    python update_tunnel_url.py <tunnel_url>
    python update_tunnel_url.py  # reads from tunnel.log automatically
"""
import sys
import re
import os
import firebase_admin
from firebase_admin import credentials, firestore
from datetime import datetime, timezone

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
SERVICE_KEY = os.path.join(SCRIPT_DIR, "serviceAccountKey.json")
TUNNEL_LOG  = os.path.join(SCRIPT_DIR, "tunnel.log")


def init_firebase():
    if not firebase_admin._apps:
        cred = credentials.Certificate(SERVICE_KEY)
        firebase_admin.initialize_app(cred)
    return firestore.client()


def extract_url_from_log(path: str) -> str | None:
    """Parse the Cloudflare tunnel log to find the latest tunnel URL."""
    if not os.path.exists(path):
        return None
    with open(path, "r", encoding="utf-8", errors="ignore") as f:
        content = f.read()
    # Match trycloudflare.com URLs
    matches = re.findall(r"https://[a-z0-9-]+\.trycloudflare\.com", content)
    return matches[-1] if matches else None


def main():
    # Get tunnel URL from argument or log file
    if len(sys.argv) > 1:
        url = sys.argv[1].strip()
    else:
        url = extract_url_from_log(TUNNEL_LOG)

    if not url or not url.startswith("https://"):
        print("[ERROR] No valid tunnel URL found.")
        print("  Pass it as argument: python update_tunnel_url.py https://xxx.trycloudflare.com")
        sys.exit(1)

    print(f"[INFO] Tunnel URL: {url}")

    db = init_firebase()
    db.collection("config").document("server").set({
        "tunnel_url": url,
        "updated_at": datetime.now(timezone.utc).isoformat(),
    }, merge=True)

    print(f"[OK] Firestore config/server updated with tunnel URL")


if __name__ == "__main__":
    main()
