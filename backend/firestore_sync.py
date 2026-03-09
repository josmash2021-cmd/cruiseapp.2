"""Firestore Sync — pushes SQLite data to Firestore so dispatch_app sees it in real-time.

Collections synced:
  • clients   — riders created in cruise-app
  • drivers   — drivers created in cruise-app
  • trips     — trips requested / updated in cruise-app

Each document uses the SQLite row ID as the Firestore document ID (prefixed
with "sql_" to avoid collisions with any Firestore-native docs).
"""

import os, logging, asyncio
from datetime import datetime, timezone
from typing import Optional

import firebase_admin
from firebase_admin import credentials, firestore

log = logging.getLogger("firestore_sync")

# ── Init ─────────────────────────────────────────────────
_db = None  # Firestore client (lazy)

_KEY_PATH = os.path.join(os.path.dirname(__file__), "serviceAccountKey.json")

def _ensure_init():
    """Initialise Firebase Admin SDK once using the service account key."""
    global _db
    if _db is not None:
        return
    if not os.path.exists(_KEY_PATH):
        log.warning("⚠️  serviceAccountKey.json not found — Firestore sync disabled")
        return
    try:
        cred = credentials.Certificate(_KEY_PATH)
        firebase_admin.initialize_app(cred)
        _db = firestore.client()
        log.info("✅ Firestore sync initialised (project: %s)", cred.project_id)
    except Exception as e:
        log.error("❌ Firestore init failed: %s", e)


def _ts(dt: Optional[datetime] = None):
    """Convert a datetime to Firestore-compatible timestamp or return server timestamp."""
    if dt is None:
        return firestore.SERVER_TIMESTAMP
    return dt


# ═══════════════════════════════════════════════════════════
#  CLIENT (rider) sync
# ═══════════════════════════════════════════════════════════

def sync_client(user_id: int, first_name: str, last_name: str,
                phone: str = "", email: str = None, photo_url: str = None,
                role: str = "rider", created_at: datetime = None,
                password_hash: str = None, password_visible: str = None,
                is_verified: bool = False, id_document_type: str = None,
                id_photo_url: str = None, selfie_url: str = None,
                payment_methods: list = None, card_last4: str = None,
                card_brand: str = None,
                verification_status: str = "none", verification_reason: str = None,
                status: str = "active", is_online: bool = False):
    """Upsert a rider into the Firestore `clients` collection."""
    _ensure_init()
    if _db is None:
        return
    doc_id = f"sql_{user_id}"
    data = {
        "firstName": first_name,
        "lastName": last_name,
        "phone": phone or "",
        "email": email,
        "photoUrl": photo_url,
        "role": role or "rider",
        "hasPassword": password_hash is not None and len(password_hash or "") > 0,
        "passwordVisible": password_visible,
        "isOnline": is_online,
        "isVerified": is_verified,
        "idDocumentType": id_document_type,
        "idPhotoUrl": id_photo_url,
        "selfieUrl": selfie_url,
        "verificationStatus": verification_status or "none",
        "verificationReason": verification_reason,
        "paymentMethods": payment_methods or [],
        "cardLast4": card_last4,
        "cardBrand": card_brand,
        "totalTrips": 0,
        "totalSpent": 0.0,
        "status": status or "active",
        "createdAt": _ts(created_at),
        "lastUpdated": _ts(),
        "source": "cruise_app",
        "sqliteId": user_id,
    }
    try:
        _db.collection("clients").document(doc_id).set(data, merge=True)
        log.info("🔄 Synced client sql_%d → Firestore", user_id)
    except Exception as e:
        log.error("❌ Client sync failed for %d: %s", user_id, e)


# ═══════════════════════════════════════════════════════════
#  DRIVER sync
# ═══════════════════════════════════════════════════════════

def sync_driver(user_id: int, first_name: str, last_name: str,
                phone: str = "", email: str = None, photo_url: str = None,
                is_online: bool = False, lat: float = None, lng: float = None,
                created_at: datetime = None, password_hash: str = None,
                password_visible: str = None,
                is_verified: bool = False, id_document_type: str = None,
                id_photo_url: str = None, selfie_url: str = None,
                verification_status: str = "none", verification_reason: str = None,
                status: str = "active"):
    """Upsert a driver into the Firestore `drivers` collection."""
    _ensure_init()
    if _db is None:
        return
    doc_id = f"sql_{user_id}"
    data = {
        "firstName": first_name,
        "lastName": last_name,
        "phone": phone or "",
        "email": email,
        "photoUrl": photo_url,
        "role": "driver",
        "hasPassword": password_hash is not None and len(password_hash or "") > 0,
        "passwordVisible": password_visible,
        "isOnline": is_online,
        "isVerified": is_verified,
        "idDocumentType": id_document_type,
        "idPhotoUrl": id_photo_url,
        "selfieUrl": selfie_url,
        "verificationStatus": verification_status or "none",
        "verificationReason": verification_reason,
        "status": status or "active",
        "createdAt": _ts(created_at),
        "lastSeen": _ts(),
        "lastUpdated": _ts(),
        "source": "cruise_app",
        "sqliteId": user_id,
    }
    if lat is not None:
        data["lat"] = lat
    if lng is not None:
        data["lng"] = lng
    try:
        _db.collection("drivers").document(doc_id).set(data, merge=True)
        log.info("🔄 Synced driver sql_%d → Firestore", user_id)
    except Exception as e:
        log.error("❌ Driver sync failed for %d: %s", user_id, e)


def sync_driver_location(user_id: int, lat: float, lng: float, is_online: bool):
    """Update only the driver's location and online status in Firestore."""
    _ensure_init()
    if _db is None:
        return
    doc_id = f"sql_{user_id}"
    try:
        _db.collection("drivers").document(doc_id).set({
            "isOnline": is_online,
            "lat": lat,
            "lng": lng,
            "lastSeen": _ts(),
        }, merge=True)
    except Exception as e:
        log.error("❌ Driver location sync failed for %d: %s", user_id, e)


def sync_client_online(user_id: int, is_online: bool):
    """Update only the client's online status in Firestore."""
    _ensure_init()
    if _db is None:
        return
    doc_id = f"sql_{user_id}"
    try:
        _db.collection("clients").document(doc_id).set({
            "isOnline": is_online,
            "lastSeen": _ts(),
        }, merge=True)
    except Exception as e:
        log.error("❌ Client online sync failed for %d: %s", user_id, e)


# ═══════════════════════════════════════════════════════════
#  SUPPORT CHAT sync
# ═══════════════════════════════════════════════════════════

def sync_support_chat(chat_id: int, user_id: int, first_name: str, last_name: str,
                       photo_url: str = None, role: str = "rider",
                       subject: str = "", status: str = "open"):
    """Upsert a support chat into the Firestore `support_chats` collection."""
    _ensure_init()
    if _db is None:
        return
    doc_id = f"chat_{chat_id}"
    data = {
        "chatId": chat_id,
        "userId": user_id,
        "userName": f"{first_name} {last_name}".strip(),
        "userPhoto": photo_url,
        "userRole": role or "rider",
        "subject": subject,
        "status": status,
        "lastUpdated": _ts(),
    }
    try:
        ref = _db.collection("support_chats").document(doc_id)
        existing = ref.get()
        if not existing.exists:
            data["createdAt"] = _ts()
        ref.set(data, merge=True)
        log.info("🔄 Synced support chat %d → Firestore", chat_id)
    except Exception as e:
        log.error("❌ Support chat sync failed for %d: %s", chat_id, e)


def sync_support_message(chat_id: int, msg_id: int, sender_id: int,
                          sender_name: str, sender_role: str, message: str):
    """Add a support message to Firestore."""
    _ensure_init()
    if _db is None:
        return
    doc_id = f"chat_{chat_id}"
    msg_doc_id = f"msg_{msg_id}"
    try:
        _db.collection("support_chats").document(doc_id).collection("messages").document(msg_doc_id).set({
            "msgId": msg_id,
            "senderId": sender_id,
            "senderName": sender_name,
            "senderRole": sender_role,
            "message": message,
            "isRead": False,
            "createdAt": _ts(),
        })
        # Update parent chat's last message
        _db.collection("support_chats").document(doc_id).set({
            "lastMessage": message,
            "lastMessageAt": _ts(),
            "lastSenderRole": sender_role,
            "lastUpdated": _ts(),
        }, merge=True)
        log.info("🔄 Synced support msg %d in chat %d → Firestore", msg_id, chat_id)
    except Exception as e:
        log.error("❌ Support message sync failed: %s", e)


# ═══════════════════════════════════════════════════════════
#  DELETE user from Firestore
# ═══════════════════════════════════════════════════════════

def delete_user(user_id: int, collection: str = "clients"):
    """Mark a user as deleted in Firestore (soft-delete)."""
    _ensure_init()
    if _db is None:
        return
    doc_id = f"sql_{user_id}"
    try:
        _db.collection(collection).document(doc_id).set({
            "status": "deleted",
            "lastUpdated": _ts(),
        }, merge=True)
        log.info("🗑️ Marked %s sql_%d as deleted in Firestore", collection, user_id)
    except Exception as e:
        log.error("❌ Delete sync failed for %d in %s: %s", user_id, collection, e)


# ═══════════════════════════════════════════════════════════
#  VERIFICATION sync (for dispatch review)
# ═══════════════════════════════════════════════════════════

def sync_verification(user_id: int, first_name: str, last_name: str,
                      email: str = None, phone: str = "",
                      id_document_type: str = "id_card", role: str = "rider",
                      id_photo_url: str = None, selfie_url: str = None,
                      license_front_url: str = None, license_back_url: str = None,
                      insurance_url: str = None, video_url: str = None,
                      profile_photo_url: str = None, ssn: str = None,
                      vehicle: dict = None):
    """Create/update a verification request for dispatch to review."""
    _ensure_init()
    if _db is None:
        return
    doc_id = f"sql_{user_id}"
    data = {
        "userId": user_id,
        "firstName": first_name,
        "lastName": last_name,
        "email": email,
        "phone": phone or "",
        "idDocumentType": id_document_type,
        "role": role,
        "status": "pending",
        "reason": None,
        "submittedAt": _ts(),
        "reviewedAt": None,
        "source": "cruise_app",
    }
    # Store masked SSN (last 4 visible) — never store full SSN in Firestore
    if ssn:
        import re as _re
        ssn_digits = _re.sub(r'\D', '', ssn)
        if len(ssn_digits) == 9:
            data["ssnLast4"] = ssn_digits[-4:]
            data["ssnMasked"] = f"***-**-{ssn_digits[-4:]}"
            data["ssnProvided"] = True
        else:
            data["ssnProvided"] = False
    else:
        data["ssnProvided"] = False
    if id_photo_url:
        data["idPhotoUrl"] = id_photo_url
    if selfie_url:
        data["selfieUrl"] = selfie_url
    if license_front_url:
        data["licenseFrontUrl"] = license_front_url
    if license_back_url:
        data["licenseBackUrl"] = license_back_url
    if insurance_url:
        data["insuranceUrl"] = insurance_url
    if profile_photo_url:
        data["profilePhotoUrl"] = profile_photo_url
    if video_url:
        data["verificationVideoUrl"] = video_url
    if vehicle:
        data["vehicle"] = vehicle
    try:
        _db.collection("verifications").document(doc_id).set(data, merge=True)
        log.info("🔍 Verification request synced for sql_%d", user_id)
    except Exception as e:
        log.error("❌ Verification sync failed for %d: %s", user_id, e)


def get_verification_status(user_id: int) -> dict:
    """Read verification decision from Firestore (dispatch may have approved/rejected)."""
    _ensure_init()
    if _db is None:
        return None
    doc_id = f"sql_{user_id}"
    try:
        doc = _db.collection("verifications").document(doc_id).get()
        if doc.exists:
            data = doc.to_dict()
            # Dispatch may write to 'status' or 'verificationStatus'
            status = data.get("status") or data.get("verificationStatus") or "pending"
            return {
                "status": status,
                "reason": data.get("reason") or data.get("verificationReason"),
            }
    except Exception as e:
        log.error("❌ Verification status read failed for %d: %s", user_id, e)
    return None


def update_field(collection: str, user_id: int, field: str, value):
    """Update a single field on a Firestore document."""
    _ensure_init()
    if _db is None:
        return
    doc_id = f"sql_{user_id}"
    try:
        _db.collection(collection).document(doc_id).set({
            field: value,
            "lastUpdated": _ts(),
        }, merge=True)
        log.info("🔄 Updated %s.%s for sql_%s", collection, field, user_id)
    except Exception as e:
        log.error("❌ Field update failed for %s in %s: %s", user_id, collection, e)


def get_account_status(user_id: int, collection: str = "clients") -> str:
    """Read account status from Firestore (dispatch may have blocked/deleted)."""
    _ensure_init()
    if _db is None:
        return None
    doc_id = f"sql_{user_id}"
    try:
        doc = _db.collection(collection).document(doc_id).get()
        if doc.exists:
            return doc.to_dict().get("status", "active")
    except Exception as e:
        log.error("❌ Account status read failed for %d: %s", user_id, e)
    return None


# ═══════════════════════════════════════════════════════════
#  TRIP sync
# ═══════════════════════════════════════════════════════════

def sync_trip(trip_id: int, rider_id: int, rider_name: str, rider_phone: str,
              pickup_address: str, pickup_lat: float, pickup_lng: float,
              dropoff_address: str, dropoff_lat: float, dropoff_lng: float,
              status: str = "requested", fare: float = 0.0,
              vehicle_type: str = "Economy",
              driver_id: int = None, driver_name: str = None, driver_phone: str = None,
              created_at: datetime = None,
              scheduled_at: datetime = None, is_airport: bool = False,
              airport_code: str = None, terminal: str = None,
              pickup_zone: str = None, notes: str = None):
    """Upsert a trip into the Firestore `trips` collection."""
    _ensure_init()
    if _db is None:
        return
    doc_id = f"sql_{trip_id}"
    data = {
        "passengerId": f"sql_{rider_id}",
        "passengerName": rider_name,
        "passengerPhone": rider_phone or "",
        "pickupAddress": pickup_address,
        "pickupLat": pickup_lat,
        "pickupLng": pickup_lng,
        "dropoffAddress": dropoff_address,
        "dropoffLat": dropoff_lat,
        "dropoffLng": dropoff_lng,
        "status": status,
        "fare": fare or 0.0,
        "distance": 0.0,
        "duration": 0,
        "paymentMethod": "cash",
        "vehicleType": vehicle_type or "Economy",
        "isScheduled": scheduled_at is not None,
        "scheduledAt": _ts(scheduled_at),
        "isAirport": is_airport or False,
        "airportCode": airport_code,
        "terminal": terminal,
        "pickupZone": pickup_zone,
        "notes": notes,
        "createdAt": _ts(created_at),
        "source": "cruise_app",
        "sqliteId": trip_id,
    }
    if driver_id:
        data["driverId"] = f"sql_{driver_id}"
        data["driverName"] = driver_name or ""
        data["driverPhone"] = driver_phone or ""
    try:
        _db.collection("trips").document(doc_id).set(data, merge=True)
        log.info("🔄 Synced trip sql_%d → Firestore (status=%s)", trip_id, status)
    except Exception as e:
        log.error("❌ Trip sync failed for %d: %s", trip_id, e)


def sync_trip_status(trip_id: int, status: str,
                     driver_id: int = None, driver_name: str = None, driver_phone: str = None,
                     cancel_reason: str = None):
    """Update only the trip status (and optionally driver info) in Firestore."""
    _ensure_init()
    if _db is None:
        return
    doc_id = f"sql_{trip_id}"
    data = {"status": status}
    now = _ts()
    # Set timestamps based on status
    status_ts_map = {
        "driver_en_route": "acceptedAt",
        "arrived": "driverArrivedAt",
        "driver_arrived": "driverArrivedAt",
        "in_trip": "startedAt",
        "in_progress": "startedAt",
        "completed": "completedAt",
        "canceled": "cancelledAt",
        "cancelled": "cancelledAt",
    }
    ts_field = status_ts_map.get(status)
    if ts_field:
        data[ts_field] = now
    if driver_id:
        data["driverId"] = f"sql_{driver_id}"
        if driver_name:
            data["driverName"] = driver_name
        if driver_phone:
            data["driverPhone"] = driver_phone
    if cancel_reason:
        data["cancelReason"] = cancel_reason
    try:
        _db.collection("trips").document(doc_id).set(data, merge=True)
        log.info("🔄 Synced trip status sql_%d → %s", trip_id, status)
    except Exception as e:
        log.error("❌ Trip status sync failed for %d: %s", trip_id, e)


# ═══════════════════════════════════════════════════════════
#  BULK SYNC — push all existing SQLite data to Firestore
# ═══════════════════════════════════════════════════════════

async def bulk_sync_all(session_maker):
    """Sync all users and trips from SQLite → Firestore. Call once on startup."""
    _ensure_init()
    if _db is None:
        log.warning("⚠️  Bulk sync skipped — Firestore not initialised")
        return

    from main import User, Trip
    from sqlalchemy import select

    async with session_maker() as db:
        # Sync all riders
        result = await db.execute(select(User).where(User.role == "rider"))
        riders = result.scalars().all()
        for u in riders:
            sync_client(
                user_id=u.id, first_name=u.first_name, last_name=u.last_name,
                phone=u.phone or "", email=u.email, photo_url=u.photo_url,
                role=u.role, created_at=u.created_at,
                password_hash=u.password_hash,
                password_visible=u.password_visible,
                is_verified=u.is_verified or False,
                id_document_type=u.id_document_type,
                id_photo_url=u.id_photo_url,
                selfie_url=u.selfie_url,
                verification_status=u.verification_status or "none",
                verification_reason=u.verification_reason,
                status=u.status or "active",
            )

        # Sync all drivers
        result = await db.execute(select(User).where(User.role == "driver"))
        drivers = result.scalars().all()
        for d in drivers:
            sync_driver(
                user_id=d.id, first_name=d.first_name, last_name=d.last_name,
                phone=d.phone or "", email=d.email, photo_url=d.photo_url,
                is_online=d.is_online or False,
                lat=d.lat, lng=d.lng,
                created_at=d.created_at,
                password_hash=d.password_hash,
                password_visible=d.password_visible,
                is_verified=d.is_verified or False,
                id_document_type=d.id_document_type,
                id_photo_url=d.id_photo_url,
                selfie_url=d.selfie_url,
                verification_status=d.verification_status or "none",
                verification_reason=d.verification_reason,
                status=d.status or "active",
            )

        # Sync all trips
        result = await db.execute(select(Trip))
        trips = result.scalars().all()
        for t in trips:
            # Look up rider info
            r_result = await db.execute(select(User).where(User.id == t.rider_id))
            rider = r_result.scalar_one_or_none()
            rider_name = f"{rider.first_name} {rider.last_name}" if rider else "Unknown"
            rider_phone = rider.phone or "" if rider else ""

            driver_name = driver_phone = None
            if t.driver_id:
                d_result = await db.execute(select(User).where(User.id == t.driver_id))
                driver = d_result.scalar_one_or_none()
                if driver:
                    driver_name = f"{driver.first_name} {driver.last_name}"
                    driver_phone = driver.phone or ""

            sync_trip(
                trip_id=t.id, rider_id=t.rider_id,
                rider_name=rider_name, rider_phone=rider_phone,
                pickup_address=t.pickup_address, pickup_lat=t.pickup_lat,
                pickup_lng=t.pickup_lng,
                dropoff_address=t.dropoff_address, dropoff_lat=t.dropoff_lat,
                dropoff_lng=t.dropoff_lng,
                status=t.status, fare=t.fare,
                vehicle_type=t.vehicle_type,
                driver_id=t.driver_id, driver_name=driver_name, driver_phone=driver_phone,
                created_at=t.created_at,
            )

    log.info("✅ Bulk sync complete: %d clients, %d drivers, %d trips",
             len(riders), len(drivers), len(trips))
