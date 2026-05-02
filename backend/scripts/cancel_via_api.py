import hmac
import hashlib
import time
import uuid
import requests
import json

# Config
DISPATCH_API_KEY = "8ni63svMNeTUuQ4ZTTmtuEQkPvor0EvhmVy54Supnvg"
HMAC_SECRET = "8kQ3Ouh1wwnF398fP3GtY6JW7rYhTMbo7A3CXCUVg4s="
BASE_URL = "https://cruiseapp2-production.up.railway.app"

def generate_headers():
    timestamp = str(int(time.time()))
    nonce = str(uuid.uuid4())
    msg = f"{DISPATCH_API_KEY}:{timestamp}:{nonce}"
    signature = hmac.new(HMAC_SECRET.encode(), msg.encode(), hashlib.sha256).hexdigest()
    return {
        "X-Api-Key": DISPATCH_API_KEY,
        "X-Timestamp": timestamp,
        "X-Nonce": nonce,
        "X-Signature": signature,
        "Content-Type": "application/json",
    }

def list_active_trips():
    headers = generate_headers()
    url = f"{BASE_URL}/admin/trips?status=requested,accepted,driver_en_route,arrived,in_trip"
    resp = requests.get(url, headers=headers, timeout=30)
    print(f"List trips status: {resp.status_code}")
    if resp.status_code == 200:
        trips = resp.json()
        print(f"Found {len(trips)} active trips")
        for t in trips[:5]:
            print(f"  ID: {t.get('id')}, Status: {t.get('status')}, Rider: {t.get('rider_id')}, Driver: {t.get('driver_id')}")
            print(f"    From: {t.get('pickup_address')}")
            print(f"    To: {t.get('dropoff_address')}")
        return trips
    else:
        print(f"Error: {resp.text}")
        return []

def list_all_recent_trips(limit=20):
    headers = generate_headers()
    url = f"{BASE_URL}/admin/trips?limit={limit}"
    resp = requests.get(url, headers=headers, timeout=30)
    print(f"List all trips status: {resp.status_code}")
    if resp.status_code == 200:
        trips = resp.json()
        print(f"Found {len(trips)} total trips (showing last {limit})")
        for t in trips[:limit]:
            print(f"  ID: {t.get('id')}, Status: {t.get('status')}, Rider: {t.get('rider_id')}, Driver: {t.get('driver_id')}")
            print(f"    From: {t.get('pickup_address')}")
            print(f"    To: {t.get('dropoff_address')}")
            print(f"    Created: {t.get('created_at')}")
        return trips
    else:
        print(f"Error: {resp.text}")
        return []

def cancel_trip(trip_id):
    headers = generate_headers()
    url = f"{BASE_URL}/admin/trips/{trip_id}/cancel"
    body = {"reason": "Cancelled by admin via script"}
    resp = requests.post(url, headers=headers, json=body, timeout=30)
    print(f"Cancel trip {trip_id} status: {resp.status_code}")
    if resp.status_code == 200:
        print(f"Success: {resp.json()}")
    else:
        print(f"Error: {resp.text}")
    return resp.status_code == 200

if __name__ == "__main__":
    print("=== Buscando viajes activos ===")
    trips = list_active_trips()
    
    if trips:
        trip_id = trips[0]["id"]
        print(f"\n=== Cancelando viaje {trip_id} ===")
        cancel_trip(trip_id)
    else:
        print("No hay viajes activos. Mostrando todos los viajes recientes...")
        all_trips = list_all_recent_trips(20)
        
        # Cancelar el trip in_trip (ID 375)
        for t in all_trips:
            if t.get('status') == 'in_trip':
                print(f"\n=== Cancelando viaje en progreso {t['id']} ===")
                cancel_trip(t['id'])
                break
