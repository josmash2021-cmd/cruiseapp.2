"""Firestore Sync — pushes SQLite data to Firestore so dispatch_app sees it in real-time.

Collections synced:
  • clients   — riders created in cruise-app
  • drivers   — drivers created in cruise-app
  • trips     — trips requested / updated in cruise-app

Each document uses the SQLite row ID as the Firestore document ID (prefixed
with "sql_" to avoid collisions with any Firestore-native docs).
"""

import os, logging, asyncio, time
from datetime import datetime, timezone
from typing import Optional

import firebase_admin
from firebase_admin import credentials, firestore, storage

log = logging.getLogger("firestore_sync")

# ── Init ─────────────────────────────────────────────────
_db = None  # Firestore client (lazy)
_fs_db = None  # Alias for _db (used by main.py)
_bucket = None  # Firebase Storage bucket

_KEY_PATH = os.path.join(os.path.dirname(__file__), "serviceAccountKey.json")
_STORAGE_BUCKET = "cruise-af9f1.firebasestorage.app"

def _ensure_init():
    """Initialise Firebase Admin SDK once.
    
    Tries (in order):
    1. serviceAccountKey.json file (local dev)
    2. FIREBASE_SERVICE_ACCOUNT env var (Railway/production) — JSON string
    """
    global _db, _fs_db, _bucket
    if _db is not None:
        return
    try:
        # Already initialized by another module?
        firebase_admin.get_app()
        _db = firestore.client()
        _fs_db = _db
        try:
            _bucket = storage.bucket(_STORAGE_BUCKET)
        except Exception as e:
            log.warning("⚠️  Firebase Storage bucket init failed: %s", e)
        return
    except ValueError:
        # Not yet initialized — continue to the init path below.
        # (ValueError is the specific exception firebase_admin.get_app() raises
        # when there is no default app; we log at DEBUG because this is the
        # expected path on first boot, not an error.)
        log.debug("firebase_admin not yet initialized — proceeding with init")

    cred = None
    # 1. Try local file
    if os.path.exists(_KEY_PATH):
        try:
            cred = credentials.Certificate(_KEY_PATH)
        except Exception as e:
            log.error("❌ Failed to load serviceAccountKey.json: %s", e)

    # 2. Try environment variable (Railway) — supports raw JSON or base64-encoded JSON
    if cred is None:
        sa_raw = os.getenv("FIREBASE_SERVICE_ACCOUNT", "")
        if sa_raw:
            try:
                import json, base64
                # Try base64 decode first, fall back to raw JSON
                try:
                    sa_json = base64.b64decode(sa_raw).decode("utf-8")
                except Exception:
                    sa_json = sa_raw
                sa_dict = json.loads(sa_json)
                cred = credentials.Certificate(sa_dict)
            except Exception as e:
                log.error("❌ Failed to load FIREBASE_SERVICE_ACCOUNT env var: %s", e)

    if cred is None:
        log.warning("⚠️  No Firebase credentials found — Firestore sync disabled")
        return

    try:
        firebase_admin.initialize_app(cred, {'storageBucket': _STORAGE_BUCKET})
        _db = firestore.client()
        _fs_db = _db
        try:
            _bucket = storage.bucket()
            log.info("✅ Firebase Storage initialised (bucket: %s)", _STORAGE_BUCKET)
        except Exception as e:
            log.warning("⚠️  Firebase Storage bucket init failed: %s", e)
        log.info("✅ Firestore sync initialised (project: %s)", cred.project_id)
    except Exception as e:
        log.error("❌ Firestore init failed: %s", e)


def _ts(dt: Optional[datetime] = None):
    """Convert a datetime to Firestore-compatible timestamp or return server timestamp."""
    if dt is None:
        return firestore.SERVER_TIMESTAMP
    return dt


# ═══════════════════════════════════════════════════════════
#  FIREBASE STORAGE (Feature 13.1)
# ═══════════════════════════════════════════════════════════

def upload_to_firebase_storage(data: bytes, path: str, content_type: str = "image/jpeg") -> Optional[str]:
    """Upload bytes to Firebase Storage and return the public download URL.
    
    Args:
        data: File bytes to upload
        path: Storage path (e.g., 'photos/user_123/profile.jpg')
        content_type: MIME type
        
    Returns:
        Public download URL or None if upload fails
    """
    _ensure_init()
    if _bucket is None:
        log.warning("⚠️  Firebase Storage not available — upload skipped")
        return None
    
    try:
        blob = _bucket.blob(path)
        blob.upload_from_string(data, content_type=content_type)
        blob.make_public()
        log.info("✅ Uploaded to Firebase Storage: %s", path)
        return blob.public_url
    except Exception as e:
        log.error("❌ Firebase Storage upload failed: %s", e)
        return None


def delete_from_firebase_storage(path: str) -> bool:
    """Delete a file from Firebase Storage.
    
    Args:
        path: Storage path to delete
        
    Returns:
        True if deleted, False otherwise
    """
    _ensure_init()
    if _bucket is None:
        return False
    
    try:
        blob = _bucket.blob(path)
        blob.delete()
        log.info("✅ Deleted from Firebase Storage: %s", path)
        return True
    except Exception as e:
        log.warning("⚠️  Firebase Storage delete failed: %s", e)
        return False


# ═══════════════════════════════════════════════════════════
#  CLIENT (rider) sync
# ═══════════════════════════════════════════════════════════

def sync_client(user_id: int, first_name: str, last_name: str,
                phone: str = "", email: str = None, photo_url: str = None,
                role: str = "rider", created_at: datetime = None,
                password_hash: str = None,
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
                is_verified: bool = False, id_document_type: str = None,
                id_photo_url: str = None, selfie_url: str = None,
                license_front_url: str = None, license_back_url: str = None,
                insurance_url: str = None, video_url: str = None,
                verification_status: str = "none", verification_reason: str = None,
                status: str = "active",
                cruise_level: str = None, average_rating: float = None):
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
    if cruise_level is not None:
        data["cruiseLevel"] = cruise_level
        data["cruise_level"] = cruise_level
    if average_rating is not None:
        data["averageRating"] = round(float(average_rating), 2)
        data["average_rating"] = round(float(average_rating), 2)
    if license_front_url:
        data["licenseFrontUrl"] = license_front_url
    if license_back_url:
        data["licenseBackUrl"] = license_back_url
    if insurance_url:
        data["insuranceUrl"] = insurance_url
    if video_url:
        data["verificationVideoUrl"] = video_url
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
                       subject: str = "", status: str = "open",
                       needs_escalation: bool = False, bot_phase: str = "welcome"):
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
        "needsEscalation": needs_escalation,
        "botPhase": bot_phase,
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
        # Update parent chat's last message and increment unread counter
        update_data = {
            "lastMessage": message,
            "lastMessageAt": _ts(),
            "lastSenderRole": sender_role,
            "lastUpdated": _ts(),
        }
        # Increment unread count for dispatch when user sends a message
        if sender_role in ("rider", "driver"):
            update_data["hasNewMessage"] = True
        _db.collection("support_chats").document(doc_id).set(update_data, merge=True)
        log.info("🔄 Synced support msg %d in chat %d → Firestore", msg_id, chat_id)
    except Exception as e:
        log.error("❌ Support message sync failed: %s", e)


def sync_dispatch_notification(chat_id: int, user_name: str, notif_type: str, message: str):
    """Write a notification event for the dispatch app to pick up via Firestore listener."""
    _ensure_init()
    if _db is None:
        return
    try:
        _db.collection("dispatch_notifications").add({
            "chatId": chat_id,
            "userName": user_name,
            "type": notif_type,  # "escalation", "new_message"
            "message": message,
            "isRead": False,
            "createdAt": _ts(),
        })
        log.info("🔔 Dispatch notification sent: %s for chat %d", notif_type, chat_id)
    except Exception as e:
        log.error("❌ Dispatch notification failed: %s", e)


# ═══════════════════════════════════════════════════════════
#  DELETE user from Firestore
# ═══════════════════════════════════════════════════════════
#  ACTION REQUESTS — admin approval queue
# ═══════════════════════════════════════════════════════════

def sync_action_request(request_id: int, data: dict):
    """Create or update an action request in Firestore for admin review."""
    _ensure_init()
    if _db is None:
        return
    doc_id = f"req_{request_id}"
    try:
        doc_data = {
            "requestId": request_id,
            "type": data.get("type", "unknown"),
            "chatId": data.get("chat_id"),
            "userId": data.get("user_id"),
            "userName": data.get("user_name", ""),
            "userType": data.get("user_type", "rider"),
            "agentName": data.get("agent_name", ""),
            "details": data.get("details", {}),
            "status": data.get("status", "pending_admin"),
            "reviewedAt": data.get("reviewed_at"),
            "reviewedBy": data.get("reviewed_by"),
            "adminNote": data.get("admin_note"),
            "lastUpdated": _ts(),
        }
        ref = _db.collection("action_requests").document(doc_id)
        existing = ref.get()
        if not existing.exists:
            doc_data["createdAt"] = _ts()
        ref.set(doc_data, merge=True)
        log.info("🔄 Synced action request %d → Firestore", request_id)
    except Exception as e:
        log.error("❌ Action request sync failed for %d: %s", request_id, e)


def notify_admin_action_request(request_id: int, action_type: str,
                                 user_name: str, agent_name: str,
                                 details: dict):
    """Send push notification to admin about a pending action request."""
    _ensure_init()
    if _db is None:
        return
    try:
        amount = details.get("amount", "")
        reason = details.get("reason", "")
        amount_str = f" de ${amount}" if amount else ""
        msg = f"{agent_name} solicita {action_type}{amount_str} para {user_name}"
        if reason:
            msg += f" — {reason}"
        _db.collection("dispatch_notifications").add({
            "type": "action_request",
            "requestId": request_id,
            "actionType": action_type,
            "userName": user_name,
            "agentName": agent_name,
            "amount": details.get("amount"),
            "reason": reason,
            "chatId": details.get("chat_id"),
            "message": f"🔔 Solicitud de soporte: {msg}",
            "isRead": False,
            "createdAt": _ts(),
        })
        log.info("🔔 Admin notified: action request %d (%s)", request_id, action_type)
    except Exception as e:
        log.error("❌ Admin notification failed for action request %d: %s", request_id, e)


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
                      insurance_url: str = None, registration_photo_url: str = None,
                      video_url: str = None,
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
    if registration_photo_url:
        data["registrationPhotoUrl"] = registration_photo_url
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
        log.warning("⚠️  get_verification_status skipped — _db is None (no Firebase credentials)")
        return None
    doc_id = f"sql_{user_id}"
    try:
        doc = _db.collection("verifications").document(doc_id).get()
        if doc.exists:
            data = doc.to_dict()
            # Dispatch may write to 'status' or 'verificationStatus'
            status = data.get("status") or data.get("verificationStatus") or "pending"
            log.info("📖 Verification status for %s: %s (raw keys: %s)", doc_id, status, list(data.keys()))
            return {
                "status": status,
                "reason": data.get("reason") or data.get("verificationReason"),
            }
        else:
            log.info("📖 Verification doc %s does not exist in Firestore", doc_id)
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


def write_approval(user_id: int, action: str, reason: str = None,
                   role: str = "driver"):
    """Atomic batch write of approval/rejection to ALL 3 Firestore collections.

    Writes to: verifications, drivers (or clients), and users.
    Uses a Firestore batch so either ALL writes succeed or NONE do.
    """
    _ensure_init()
    if _db is None:
        log.warning("⚠️  write_approval skipped — _db is None")
        return False
    doc_id = f"sql_{user_id}"
    is_approved = action == "approve"
    status_str = "approved" if is_approved else "rejected"
    ts = _ts()
    payload = {
        "status": status_str,
        "driver_status": status_str,
        "approvalStatus": status_str,
        "verificationStatus": status_str,
        "isVerified": is_approved,
        "isApproved": is_approved,
        "reason": reason,
        "verificationReason": reason,
        "reviewedAt": ts,
        "updated_at": ts,
        "lastUpdated": ts,
    }
    user_col = "drivers" if role == "driver" else "clients"
    try:
        batch = _db.batch()
        batch.set(_db.collection("verifications").document(doc_id), payload, merge=True)
        batch.set(_db.collection(user_col).document(doc_id), payload, merge=True)
        batch.set(_db.collection("users").document(doc_id), payload, merge=True)
        batch.commit()
        log.info("✅ write_approval OK: %s/%s (action=%s)", user_col, doc_id, action)
        return True
    except Exception as e:
        log.error("❌ write_approval FAILED for %s: %s", doc_id, e)
        return False


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


# ── Retry helper for critical Firestore writes ────────────

def _retry_sync(fn, max_retries=2):
    """Call *fn* up to *max_retries+1* times with back-off.

    Uses synchronous sleep because the Firebase Admin SDK calls here are
    synchronous (they block on gRPC internally).
    """
    for attempt in range(max_retries + 1):
        try:
            fn()
            return
        except Exception as e:
            if attempt == max_retries:
                log.error("Firestore sync failed after %d attempts: %s", max_retries + 1, e)
                raise
            else:
                time.sleep(0.5 * (attempt + 1))


# ═══════════════════════════════════════════════════════════
#  TRIP sync
# ═══════════════════════════════════════════════════════════

def sync_trip(trip_id: int, rider_id: int, rider_name: str, rider_phone: str,
              pickup_address: str, pickup_lat: float, pickup_lng: float,
              dropoff_address: str, dropoff_lat: float, dropoff_lng: float,
              status: str = "requested", fare: float = 0.0,
              vehicle_type: str = "Economy",
              driver_id: int = None, driver_name: str = None, driver_phone: str = None,
              rider_photo_url: str = None,
              driver_photo_url: str = None,
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
        data["driverId"] = str(driver_id)
        data["driverName"] = driver_name or ""
        data["driverPhone"] = driver_phone or ""
    if rider_photo_url:
        data["riderPhotoUrl"] = rider_photo_url
    if driver_photo_url:
        data["driverPhotoUrl"] = driver_photo_url
    try:
        _retry_sync(lambda: _db.collection("trips").document(doc_id).set(data, merge=True))
        log.info("🔄 Synced trip sql_%d → Firestore (status=%s)", trip_id, status)
    except Exception as e:
        log.error("❌ Trip sync failed for %d: %s", trip_id, e)


def sync_scheduled_ride(trip_id: int, rider_id: int, rider_name: str = "",
                        rider_phone: str = "", scheduled_at=None, status: str = "scheduled",
                        ride_type: str = "scheduled", vehicle_type: str = "",
                        pickup_address: str = "", dropoff_address: str = "",
                        pickup_lat: float = 0, pickup_lng: float = 0,
                        dropoff_lat: float = 0, dropoff_lng: float = 0,
                        fare: float = 0, notes: str = "",
                        is_airport: bool = False, airport_code: str = "",
                        terminal: str = "", airline: str = "", flight_number: str = "",
                        meet_inside: bool = False,
                        driver_id: int = None, driver_name: str = None,
                        driver_phone: str = None):
    """Sync a scheduled ride to Firestore scheduled_rides collection for dispatch app."""
    _ensure_init()
    if _db is None:
        return
    doc_id = f"sql_{trip_id}"
    data = {
        "id": trip_id,
        "rider_id": rider_id,
        "riderName": rider_name,
        "riderPhone": rider_phone,
        "scheduledAt": _ts(scheduled_at) if scheduled_at else None,
        "status": status,
        "type": "airport" if is_airport else "scheduled",
        "vehicle_type": vehicle_type or "",
        "pickup_address": pickup_address or "",
        "dropoff_address": dropoff_address or "",
        "pickup_lat": pickup_lat,
        "pickup_lng": pickup_lng,
        "dropoff_lat": dropoff_lat,
        "dropoff_lng": dropoff_lng,
        "fare": fare or 0,
        "notes": notes or "",
        "airline": airline or "",
        "flight_number": flight_number or "",
        "airport_code": airport_code or "",
        "terminal": terminal or "",
        "meet_inside": meet_inside,
        "createdAt": _ts(),
    }
    if driver_id:
        data["driverId"] = driver_id
        data["driverName"] = driver_name or ""
        data["driverPhone"] = driver_phone or ""
        data["assignedAt"] = _ts()
    try:
        _db.collection("scheduled_rides").document(doc_id).set(data, merge=True)
        log.info("Synced scheduled ride sql_%d to Firestore", trip_id)
    except Exception as e:
        log.error("Scheduled ride sync failed for %d: %s", trip_id, e)


def sync_trip_status(trip_id: int, status: str,
                     driver_id: int = None, driver_name: str = None, driver_phone: str = None,
                     driver_photo_url: str = None,
                     vehicle_make: str = None, vehicle_model: str = None,
                     vehicle_color: str = None, vehicle_plate: str = None,
                     vehicle_year: str = None,
                     cancel_reason: str = None,
                     cancellation_fee: float = None,
                     cancelled_by: str = None,
                     distance: float = None,
                     duration: int = None,
                     payment_status: str = None):
    """Update only the trip status (and optionally driver info) in Firestore."""
    _ensure_init()
    if _db is None:
        return
    doc_id = f"sql_{trip_id}"
    data = {"status": status}
    now = _ts()
    # Normalise incoming status to canonical values before writing to Firestore.
    # This ensures the Flutter listener only ever sees one spelling per state.
    _canonical = {
        "driver_arrived": "arrived",
        "arrived_pickup": "arrived",
        "arrived_at_pickup": "arrived",
        "in_progress": "in_trip",
        "rider_onboard": "in_trip",
        "on_trip": "in_trip",
        "trip_started": "in_trip",
        "canceled": "cancelled",
    }
    status = _canonical.get(status, status)
    data["status"] = status

    # Set timestamps based on canonical status
    status_ts_map = {
        "driver_en_route": "acceptedAt",
        "arrived": "driverArrivedAt",
        "in_trip": "startedAt",
        "completed": "completedAt",
        "cancelled": "cancelledAt",
    }
    ts_field = status_ts_map.get(status)
    if ts_field:
        data[ts_field] = now
    if driver_id:
        data["driverId"] = str(driver_id)
        data["driver_id"] = driver_id  # snake_case for Flutter compatibility
        if driver_name:
            data["driverName"] = driver_name
            data["driver_name"] = driver_name
        if driver_phone:
            data["driverPhone"] = driver_phone
            data["driver_phone"] = driver_phone
        if driver_photo_url:
            data["driverPhotoUrl"] = driver_photo_url
            data["driver_photo_url"] = driver_photo_url
        if vehicle_make:
            data["vehicle_make"] = vehicle_make
        if vehicle_model:
            data["vehicle_model"] = vehicle_model
        if vehicle_color:
            data["vehicle_color"] = vehicle_color
        if vehicle_plate:
            data["vehicle_plate"] = vehicle_plate
        if vehicle_year:
            data["vehicle_year"] = str(vehicle_year)
    if cancel_reason:
        data["cancelReason"] = cancel_reason
    if cancellation_fee is not None and cancellation_fee > 0:
        data["cancellationFee"] = cancellation_fee
    if cancelled_by:
        data["cancelledBy"] = cancelled_by
    if distance is not None:
        data["distance"] = distance
    if duration is not None:
        data["duration"] = duration
    if payment_status is not None:
        data["payment_status"] = payment_status
    try:
        _retry_sync(lambda: _db.collection("trips").document(doc_id).set(data, merge=True))
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
                is_verified=d.is_verified or False,
                id_document_type=d.id_document_type,
                id_photo_url=d.id_photo_url,
                selfie_url=d.selfie_url,
                license_front_url=d.license_front_url,
                license_back_url=d.license_back_url,
                insurance_url=d.insurance_url,
                video_url=d.video_url,
                verification_status=d.verification_status or "none",
                verification_reason=d.verification_reason,
                status=d.status or "active",
            )

        # Sync all trips
        result = await db.execute(select(Trip))
        trips = result.scalars().all()
        for t in trips:
            # Look up rider info (with guest-booking fallback)
            rider = None
            if t.rider_id:
                r_result = await db.execute(select(User).where(User.id == t.rider_id))
                rider = r_result.scalar_one_or_none()
            if rider:
                rider_name = f"{rider.first_name} {rider.last_name}"
                rider_phone = rider.phone or ""
            else:
                _gf = (getattr(t, "guest_first_name", None) or "").strip()
                _gl = (getattr(t, "guest_last_name", None) or "").strip()
                rider_name = f"{_gf} {_gl}".strip() or "Unknown"
                rider_phone = (getattr(t, "guest_phone", None) or "").strip()

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


# ═══════════════════════════════════════════════════════════
#  MESSAGING — Admin to Driver real-time messages
# ═══════════════════════════════════════════════════════════

def send_driver_message(driver_id: int, message: str, sender: str = "admin"):
    """Send a message from admin to driver via Firestore (real-time)."""
    _ensure_init()
    if _db is None:
        return
    
    doc_id = f"sql_{driver_id}"
    message_data = {
        "type": "admin_message",
        "message": message,
        "sender": sender,
        "timestamp": _ts(),
        "read": False,
        "driverId": driver_id,
    }
    
    try:
        # Store in driver's messages subcollection
        _db.collection("drivers").document(doc_id).collection("messages").add(message_data)
        # Also store in a global messages collection for admin tracking
        _db.collection("admin_messages").add({
            **message_data,
            "driverDocId": doc_id,
        })
        log.info("✅ Message sent to driver %d", driver_id)
    except Exception as e:
        log.error("❌ Failed to send message to driver %d: %s", driver_id, e)


def sync_driver_rejection_reason(trip_id: int, driver_id: int, reason: str):
    """Store driver rejection reason in Firestore for analytics."""
    _ensure_init()
    if _db is None:
        return
    
    rejection_data = {
        "tripId": trip_id,
        "driverId": driver_id,
        "reason": reason,
        "timestamp": _ts(),
        "type": "rejection",
    }
    
    try:
        _db.collection("rejections").add(rejection_data)
        log.info("✅ Rejection reason stored for trip %d by driver %d", trip_id, driver_id)
    except Exception as e:
        log.error("❌ Failed to store rejection reason: %s", e)
