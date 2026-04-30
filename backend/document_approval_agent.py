from utils.ssn_encryption import decrypt_ssn, format_ssn_for_display

"""
Document Auto-Approval Agent — THE FAST-TRACK VERIFIER

Automatically reviews and approves driver vehicle documents,
dramatically reducing wait times from hours to minutes.

═══════════════════════════════════════════════════════════
  PHASE 1 (ACTIVE): Vehicle documents only
  - Vehicle Insurance
  - Vehicle Registration

  PHASE 2 (FUTURE — activate by setting FULL_VERIFICATION=True):
  - License front/back photos
  - Selfie photo
  - SSN validation
  - Profile photo
  - Video verification
  - Email/phone validation
  - Account age anti-bot checks
═══════════════════════════════════════════════════════════

Phase 1 Flow:
1. Driver uploads insurance/registration on Vehicle page
2. Document saved to `documents` table with status="pending"
3. This agent scans every 2 minutes for pending vehicle docs
4. If photo URL exists and is reachable → AUTO-APPROVE
   - Set Document.status = "approved"
   - Set Vehicle.insurance_valid / registration_valid = True
   - Push notification to driver
   - Sync to Firestore
5. If photo URL broken → AUTO-REJECT with reason

Runs every 2 minutes.
"""

import asyncio
import logging
import time
from datetime import datetime, timedelta, timezone
from typing import Dict, List, Optional, Tuple

from sqlalchemy import select, and_, func

logger = logging.getLogger(__name__)

# ══════════════════════════════════════════════════════════════════════
#  MASTER SWITCH — set True to enable full driver verification
# ══════════════════════════════════════════════════════════════════════
FULL_VERIFICATION = False  # Phase 2: flip to True to activate all checks

# ── Configuration ─────────────────────────────────────────────────────
SCAN_INTERVAL_SECONDS = 300     # Check every 5 minutes (was 2m) — reduced for NullPool/PgBouncer efficiency
PHOTO_CHECK_TIMEOUT = 8         # Seconds to wait for photo URL check

# Phase 1: Vehicle document types that get auto-approved
VEHICLE_DOC_TYPES = ["insurance", "registration"]
MIN_FILE_SIZE_BYTES = 10_000      # Minimum 10KB — below this is likely invalid
MAX_FILE_SIZE_BYTES = 20_000_000  # Maximum 20MB
VALID_IMAGE_CONTENT_TYPES = {"image/jpeg", "image/png", "image/jpg", "image/webp", "application/pdf"}

# Phase 2 settings (inactive until FULL_VERIFICATION=True)
MIN_ACCOUNT_AGE_MINUTES = 5     # Anti-bot: account must be 5+ min old
FLAG_ACCOUNT_AGE_HOURS = 24     # Flag for review if account < 24h old
REQUIRED_DRIVER_DOCS = [
    "license_front_url",
    "license_back_url",
    "vehicle_registration_url",
    "insurance_url",
    "registration_photo_url",
    "selfie_url",
]

# Track processed docs to avoid re-processing
_processed: Dict[str, float] = {}  # key: "doc_{id}" or "user_{id}"
_MAX_PROCESSED_CACHE = 10000
_REPROCESS_COOLDOWN = 300  # Don't re-check same doc within 5 min


class DocumentApprovalAgent:
    """Autonomous agent that auto-approves vehicle documents (Phase 1)
    and full driver verification (Phase 2 — future)."""

    def __init__(self):
        self._db_session_maker = None
        self._running = False
        self._task: Optional[asyncio.Task] = None
        self._stats = {
            "scans": 0,
            "auto_approved": 0,
            "auto_rejected": 0,
            "flagged_for_review": 0,
            "pending_count": 0,
            "last_scan_at": None,
            "last_scan_duration_ms": 0,
            "started_at": None,
            "mode": "vehicle_docs_only" if not FULL_VERIFICATION else "full_verification",
        }

    def set_db_session_maker(self, session_maker):
        self._db_session_maker = session_maker

    async def start(self):
        if self._running:
            return
        self._running = True
        self._stats["started_at"] = datetime.now(timezone.utc).isoformat()
        self._task = asyncio.create_task(self._loop())
        mode = "FULL verification" if FULL_VERIFICATION else "vehicle docs (insurance + registration)"
        logger.info("✅ Document Approval Agent ACTIVE — mode: %s, every %ds", mode, SCAN_INTERVAL_SECONDS)

    async def stop(self):
        self._running = False
        if self._task:
            self._task.cancel()
            try:
                await self._task
            except asyncio.CancelledError:
                pass
        logger.info("✅ Document Approval Agent stopped")

    def get_status(self) -> dict:
        return {
            "agent": "document_approval",
            "running": self._running,
            **self._stats,
            "full_verification_enabled": FULL_VERIFICATION,
            "processed_cache_size": len(_processed),
        }

    async def _loop(self):
        await asyncio.sleep(45)  # Let server warm up
        while self._running:
            try:
                await self._scan()
            except Exception as e:
                logger.error("[DocApproval] Scan error: %s", e, exc_info=True)
            await asyncio.sleep(SCAN_INTERVAL_SECONDS)

    async def _scan(self):
        if not self._db_session_maker:
            return

        t0 = time.time()
        now = datetime.now(timezone.utc)

        # ── PHASE 1: Vehicle document auto-approval ───────────
        await self._scan_vehicle_docs(now)

        # ── PHASE 2: Full driver verification (future) ────────
        if FULL_VERIFICATION:
            await self._scan_full_verification(now)

        # Update stats
        self._stats["scans"] += 1
        self._stats["last_scan_at"] = now.isoformat()
        self._stats["last_scan_duration_ms"] = round((time.time() - t0) * 1000, 1)

        # Cleanup processed cache
        if len(_processed) > _MAX_PROCESSED_CACHE:
            cutoff = time.time() - (_REPROCESS_COOLDOWN * 3)
            stale = [k for k, v in _processed.items() if v < cutoff]
            for k in stale:
                del _processed[k]

    # ══════════════════════════════════════════════════════════════════
    #  PHASE 1 — Vehicle Insurance + Registration auto-approval
    # ══════════════════════════════════════════════════════════════════

    async def _scan_vehicle_docs(self, now: datetime):
        """Scan pending vehicle documents (insurance, registration) and auto-approve."""
        from models.database import Document, Vehicle, User

        async with self._db_session_maker() as db:
            # Find all pending vehicle documents (insurance + registration)
            result = await db.execute(
                select(Document).where(
                    and_(
                        Document.status == "pending",
                        Document.doc_type.in_(VEHICLE_DOC_TYPES),
                    )
                )
            )
            pending_docs = result.scalars().all()
            self._stats["pending_count"] = len(pending_docs)

            approved_count = 0
            rejected_count = 0

            for doc in pending_docs:
                cache_key = f"doc_{doc.id}"
                last_check = _processed.get(cache_key, 0)
                if time.time() - last_check < _REPROCESS_COOLDOWN:
                    continue
                _processed[cache_key] = time.time()

                # Get the driver who owns this document
                driver_result = await db.execute(
                    select(User).where(User.id == doc.user_id)
                )
                driver = driver_result.scalar_one_or_none()
                if not driver:
                    continue

                # ── Validate: photo file exists ───────────────
                if not doc.file_path or len(doc.file_path) < 5:
                    # No file uploaded — reject
                    doc.status = "rejected"
                    doc.rejection_reason = "No se subió archivo. Intenta nuevamente."
                    rejected_count += 1
                    self._stats["auto_rejected"] += 1

                    logger.warning(
                        "[DocApproval] REJECTED %s for driver #%d — no file",
                        doc.doc_type, driver.id,
                    )

                    if driver.fcm_token:
                        self._send_rejection_push(
                            driver, doc.doc_type,
                            "No se detectó archivo. Por favor sube el documento nuevamente."
                        )
                    continue

                # ── Validate: photo URL reachable + smart content check ──
                url_check = await self._smart_url_check(doc.file_path)

                if url_check["status"] == "unreachable":
                    doc.status = "rejected"
                    doc.rejection_reason = "El archivo subido no es accesible. Intenta nuevamente."
                    rejected_count += 1
                    self._stats["auto_rejected"] += 1
                    logger.warning(
                        "[DocApproval] REJECTED %s for driver #%d — URL unreachable: %s",
                        doc.doc_type, driver.id, doc.file_path[:80],
                    )
                    if driver.fcm_token:
                        self._send_rejection_push(
                            driver, doc.doc_type,
                            "Hubo un error con tu archivo. Por favor súbelo nuevamente."
                        )
                    continue

                if url_check["status"] == "invalid_content":
                    # Can't confirm this is a real document — flag for dispatch review
                    logger.warning(
                        "[DocApproval] FLAGGED %s for driver #%d — %s",
                        doc.doc_type, driver.id, url_check.get("reason", "unknown"),
                    )
                    await self._alert_admin(
                        driver, "document_needs_review",
                        f"El agente no pudo verificar automáticamente el documento "
                        f"'{doc.doc_type}' del conductor #{driver.id} "
                        f"({driver.first_name} {driver.last_name}). "
                        f"Razón: {url_check.get('reason', 'Contenido no reconocible')}. "
                        f"URL: {doc.file_path[:120]}",
                        severity="high",
                    )
                    # Leave as pending — dispatch will review manually
                    continue

                # ── ALL CHECKS PASSED — AUTO-APPROVE ──────────
                doc.status = "approved"
                doc.rejection_reason = None
                doc.updated_at = now
                approved_count += 1
                self._stats["auto_approved"] += 1

                # Update Vehicle validity flags
                vehicle_result = await db.execute(
                    select(Vehicle).where(Vehicle.user_id == driver.id)
                )
                vehicle = vehicle_result.scalar_one_or_none()

                if vehicle:
                    if doc.doc_type == "insurance":
                        vehicle.insurance_valid = True
                    elif doc.doc_type == "registration":
                        vehicle.registration_valid = True

                logger.info(
                    "[DocApproval] APPROVED %s for driver #%d (%s %s)",
                    doc.doc_type, driver.id, driver.first_name, driver.last_name,
                )

                # Push notification
                if driver.fcm_token:
                    self._send_approval_push(driver, doc.doc_type)

                # Sync to Firestore
                await self._sync_vehicle_doc_approved(driver, vehicle, doc.doc_type)

                # Check if ALL vehicle docs are now valid → notify driver
                if vehicle and vehicle.insurance_valid and vehicle.registration_valid:
                    if driver.fcm_token:
                        self._send_all_docs_complete_push(driver)
                    await self._alert_admin(
                        driver, "vehicle_docs_complete",
                        f"Driver #{driver.id} ({driver.first_name} {driver.last_name}) "
                        f"tiene todos los documentos de vehículo aprobados. Listo para conducir.",
                        severity="low",
                    )

            if approved_count or rejected_count:
                await db.commit()
                logger.info(
                    "[DocApproval] Vehicle docs scan — %d pending, %d approved, %d rejected",
                    len(pending_docs), approved_count, rejected_count,
                )

    # ══════════════════════════════════════════════════════════════════
    #  PHASE 2 — Full driver verification (FUTURE — activate later)
    # ══════════════════════════════════════════════════════════════════

    async def _scan_full_verification(self, now: datetime):
        """Full driver verification: license, selfie, SSN, vehicle, contact.
        Only runs when FULL_VERIFICATION=True."""
        from models.database import User, Vehicle

        async with self._db_session_maker() as db:
            result = await db.execute(
                select(User).where(
                    and_(
                        User.verification_status == "pending",
                        User.role == "driver",
                    )
                )
            )
            pending_drivers = result.scalars().all()

            for driver in pending_drivers:
                cache_key = f"user_{driver.id}"
                last_check = _processed.get(cache_key, 0)
                if time.time() - last_check < _REPROCESS_COOLDOWN:
                    continue
                _processed[cache_key] = time.time()

                decision, reasons = await self._evaluate_full_verification(
                    db, driver, now
                )

                if decision == "approve":
                    await self._full_approve(db, driver, now)
                elif decision == "reject":
                    await self._full_reject(db, driver, reasons, now)
                elif decision == "flag":
                    await self._flag_for_review(driver, reasons)

            await db.commit()

    async def _evaluate_full_verification(
        self, db, driver, now: datetime
    ) -> Tuple[str, List[str]]:
        """Full verification checklist (Phase 2). Returns (decision, reasons)."""
        from models.database import Vehicle

        reject_reasons = []
        flag_reasons = []

        # CHECK 1: Account age (anti-bot)
        created = driver.created_at
        if created:
            if created.tzinfo is None:
                created = created.replace(tzinfo=timezone.utc)
            account_age_min = (now - created).total_seconds() / 60

            if account_age_min < MIN_ACCOUNT_AGE_MINUTES:
                reject_reasons.append(
                    f"Cuenta creada hace {account_age_min:.0f} min "
                    f"(mínimo: {MIN_ACCOUNT_AGE_MINUTES} min). Posible bot."
                )
            elif account_age_min < FLAG_ACCOUNT_AGE_HOURS * 60:
                flag_reasons.append(
                    f"Cuenta creada hace {account_age_min/60:.1f}h. Cuenta nueva."
                )

        # CHECK 2: Required document photos
        missing_docs = []
        for field in REQUIRED_DRIVER_DOCS:
            url = getattr(driver, field, None)
            if not url or not isinstance(url, str) or len(url) < 10:
                doc_name = field.replace("_url", "").replace("_", " ").title()
                missing_docs.append(doc_name)
        if missing_docs:
            reject_reasons.append(f"Documentos faltantes: {', '.join(missing_docs)}")

        # CHECK 3: Photo URLs reachable
        broken_urls = []
        for field in REQUIRED_DRIVER_DOCS:
            url = getattr(driver, field, None)
            if url and isinstance(url, str) and len(url) > 10:
                if not await self._check_url_reachable(url):
                    doc_name = field.replace("_url", "").replace("_", " ").title()
                    broken_urls.append(doc_name)
        if broken_urls:
            reject_reasons.append(f"Fotos inaccesibles: {', '.join(broken_urls)}")

        # CHECK 4: SSN (decrypt from database for validation)
        ssn_plain = decrypt_ssn(driver.ssn) if driver.ssn else ""
        if not ssn_plain:
            reject_reasons.append("SSN no proporcionado")
        else:
            import re
            ssn_formatted = format_ssn_for_display(ssn_plain)
            if not re.match(r'^\d{3}-\d{2}-\d{4}$', ssn_formatted):
                reject_reasons.append("Formato de SSN inválido")

        # CHECK 5: Vehicle registered
        veh_result = await db.execute(
            select(Vehicle).where(Vehicle.user_id == driver.id)
        )
        vehicle = veh_result.scalar_one_or_none()
        if not vehicle:
            reject_reasons.append("No tiene vehículo registrado")
        else:
            v_missing = []
            if not vehicle.make: v_missing.append("marca")
            if not vehicle.model: v_missing.append("modelo")
            if not vehicle.year: v_missing.append("año")
            if not vehicle.plate: v_missing.append("placa")
            if v_missing:
                reject_reasons.append(f"Vehículo incompleto: {', '.join(v_missing)}")

        # CHECK 6: Contact info
        if not driver.phone or len(driver.phone) < 7:
            reject_reasons.append("Teléfono no válido")
        if not driver.email or "@" not in (driver.email or ""):
            reject_reasons.append("Email no válido")

        # CHECK 7: Profile photo (flag, not reject)
        if not driver.photo_url:
            flag_reasons.append("Sin foto de perfil")

        # CHECK 8: Video verification (flag, not reject)
        if not driver.video_url:
            flag_reasons.append("Sin video de verificación")

        # CHECK 9: Previously rejected
        if driver.verification_reason and "rechazado" in (driver.verification_reason or "").lower():
            flag_reasons.append("Verificación previamente rechazada. Revisión manual.")

        # DECISION
        if reject_reasons:
            return "reject", reject_reasons
        if flag_reasons:
            return "flag", flag_reasons
        return "approve", []

    # ══════════════════════════════════════════════════════════════════
    #  URL VALIDATION
    # ══════════════════════════════════════════════════════════════════

    async def _check_url_reachable(self, url: str) -> bool:
        """Check if a document URL is reachable (HEAD request)."""
        try:
            if "firebasestorage" in url or "localhost" in url or "railway" in url:
                return True  # Trust internal URLs

            import urllib.request
            req = urllib.request.Request(url, method="HEAD")
            req.add_header("User-Agent", "CruiseApp-DocVerifier/1.0")

            loop = asyncio.get_event_loop()
            def _head():
                try:
                    with urllib.request.urlopen(req, timeout=PHOTO_CHECK_TIMEOUT) as resp:
                        return resp.status == 200
                except Exception:
                    return False
            return await loop.run_in_executor(None, _head)
        except Exception:
            return True  # Assume valid on error

    async def _smart_url_check(self, url: str) -> Dict[str, str]:
        """Smart document validation: checks reachability, content-type, and file size.
        Returns dict with 'status' key: 'ok', 'unreachable', or 'invalid_content'."""
        try:
            # Trust internal Firebase Storage URLs
            if "firebasestorage" in url or "localhost" in url or "railway" in url:
                return {"status": "ok"}

            import urllib.request
            req = urllib.request.Request(url, method="HEAD")
            req.add_header("User-Agent", "CruiseApp-DocVerifier/1.0")

            loop = asyncio.get_event_loop()
            def _check():
                try:
                    with urllib.request.urlopen(req, timeout=PHOTO_CHECK_TIMEOUT) as resp:
                        if resp.status != 200:
                            return {"status": "unreachable", "reason": f"HTTP {resp.status}"}
                        content_type = resp.headers.get("Content-Type", "").lower().split(";")[0].strip()
                        content_length = resp.headers.get("Content-Length", "0")
                        try:
                            file_size = int(content_length)
                        except (ValueError, TypeError):
                            file_size = 0

                        # Validate content type
                        if content_type and content_type not in VALID_IMAGE_CONTENT_TYPES:
                            return {
                                "status": "invalid_content",
                                "reason": f"Tipo de archivo no válido: {content_type}. "
                                          f"Se esperaba una imagen o PDF."
                            }

                        # Validate file size
                        if file_size > 0 and file_size < MIN_FILE_SIZE_BYTES:
                            return {
                                "status": "invalid_content",
                                "reason": f"Archivo demasiado pequeño ({file_size} bytes). "
                                          f"Probablemente no es un documento válido."
                            }
                        if file_size > MAX_FILE_SIZE_BYTES:
                            return {
                                "status": "invalid_content",
                                "reason": f"Archivo demasiado grande ({file_size // 1_000_000}MB). Máximo 20MB."
                            }

                        return {"status": "ok"}
                except Exception:
                    return {"status": "unreachable", "reason": "Connection failed"}

            return await loop.run_in_executor(None, _check)
        except Exception as e:
            logger.warning("[DocApproval] Smart URL check error: %s", e)
            return {"status": "ok"}  # Fail open to not block drivers

    # ══════════════════════════════════════════════════════════════════
    #  PUSH NOTIFICATIONS
    # ══════════════════════════════════════════════════════════════════

    def _send_approval_push(self, driver, doc_type: str):
        """Notify driver that a vehicle document was approved."""
        try:
            from services.fcm_service import _send_fcm_push
            doc_names = {
                "insurance": "Seguro del vehículo",
                "registration": "Registro del vehículo",
            }
            doc_name = doc_names.get(doc_type, doc_type)
            _send_fcm_push(
                driver.fcm_token,
                title=f"✅ {doc_name} aprobado",
                body=f"Tu {doc_name.lower()} ha sido verificado y aprobado.",
                data={
                    "type": "vehicle_doc_approved",
                    "doc_type": doc_type,
                    "driver_id": str(driver.id),
                },
            )
        except Exception as e:
            logger.warning("[DocApproval] Approval push failed: %s", e)

    def _send_rejection_push(self, driver, doc_type: str, reason: str):
        """Notify driver that a vehicle document was rejected."""
        try:
            from services.fcm_service import _send_fcm_push
            doc_names = {
                "insurance": "Seguro del vehículo",
                "registration": "Registro del vehículo",
            }
            doc_name = doc_names.get(doc_type, doc_type)
            _send_fcm_push(
                driver.fcm_token,
                title=f"❌ {doc_name} rechazado",
                body=reason,
                data={
                    "type": "vehicle_doc_rejected",
                    "doc_type": doc_type,
                    "reason": reason,
                    "driver_id": str(driver.id),
                },
            )
        except Exception as e:
            logger.warning("[DocApproval] Rejection push failed: %s", e)

    def _send_all_docs_complete_push(self, driver):
        """Notify driver that ALL vehicle documents are approved — ready to drive."""
        try:
            from services.fcm_service import _send_fcm_push
            _send_fcm_push(
                driver.fcm_token,
                title="🚗 ¡Documentos completos!",
                body="Todos tus documentos de vehículo están aprobados. "
                     "Ya puedes conectarte y comenzar a recibir viajes.",
                data={
                    "type": "all_vehicle_docs_approved",
                    "driver_id": str(driver.id),
                },
            )
        except Exception as e:
            logger.warning("[DocApproval] All-docs push failed: %s", e)

    # ══════════════════════════════════════════════════════════════════
    #  PHASE 2 — Full verification approve/reject (future)
    # ══════════════════════════════════════════════════════════════════

    async def _full_approve(self, db, driver, now: datetime):
        """Phase 2: Auto-approve full driver verification."""
        driver.verification_status = "approved"
        driver.is_verified = True
        driver.verified_at = now
        driver.verification_reason = None
        self._stats["auto_approved"] += 1

        logger.info(
            "[DocApproval] FULL APPROVED driver #%d (%s %s)",
            driver.id, driver.first_name, driver.last_name,
        )

        if driver.fcm_token:
            try:
                from services.fcm_service import _send_fcm_push
                _send_fcm_push(
                    driver.fcm_token,
                    title="✅ ¡Cuenta verificada!",
                    body="Tus documentos han sido aprobados. Ya puedes conducir.",
                    data={"type": "verification_approved", "driver_id": str(driver.id)},
                )
            except Exception as e:
                logger.warning("[DocApproval] Full approval push failed: %s", e)

        try:
            from config import _HAS_FIRESTORE, firestore_sync
            if _HAS_FIRESTORE and firestore_sync:
                firestore_sync.write_approval(
                    user_id=driver.id, action="approve", reason=None, role="driver",
                )
        except Exception as e:
            logger.warning("[DocApproval] Firestore sync failed: %s", e)

        await self._alert_admin(
            driver, "auto_approved",
            f"Driver #{driver.id} ({driver.first_name} {driver.last_name}) "
            f"auto-aprobado. Verificación completa.",
            severity="low",
        )

    async def _full_reject(self, db, driver, reasons: List[str], now: datetime):
        """Phase 2: Auto-reject full driver verification."""
        reason_text = " | ".join(reasons)
        driver.verification_status = "rejected"
        driver.is_verified = False
        driver.verification_reason = f"Auto-rechazado: {reason_text}"
        self._stats["auto_rejected"] += 1

        logger.warning(
            "[DocApproval] FULL REJECTED driver #%d — %s",
            driver.id, reason_text,
        )

        if driver.fcm_token:
            try:
                from services.fcm_service import _send_fcm_push
                friendly = reasons[0] if reasons else "Documentación incompleta"
                _send_fcm_push(
                    driver.fcm_token,
                    title="❌ Verificación rechazada",
                    body=f"Motivo: {friendly}. Corrige y envía nuevamente.",
                    data={"type": "verification_rejected", "reason": friendly, "driver_id": str(driver.id)},
                )
            except Exception as e:
                logger.warning("[DocApproval] Full rejection push failed: %s", e)

        try:
            from config import _HAS_FIRESTORE, firestore_sync
            if _HAS_FIRESTORE and firestore_sync:
                firestore_sync.write_approval(
                    user_id=driver.id, action="reject",
                    reason=f"Auto-rechazado: {reason_text}", role="driver",
                )
        except Exception as e:
            logger.warning("[DocApproval] Firestore sync failed: %s", e)

        await self._alert_admin(
            driver, "auto_rejected",
            f"Driver #{driver.id} auto-rechazado: {reason_text}",
            severity="medium",
        )

    async def _flag_for_review(self, driver, reasons: List[str]):
        """Phase 2: Flag for manual admin review."""
        self._stats["flagged_for_review"] += 1
        logger.info("[DocApproval] FLAGGED driver #%d — %s", driver.id, " | ".join(reasons))
        await self._alert_admin(
            driver, "needs_manual_review",
            f"Driver #{driver.id} ({driver.first_name} {driver.last_name}) "
            f"requiere revisión manual: {' | '.join(reasons)}",
            severity="high",
        )

    # ══════════════════════════════════════════════════════════════════
    #  FIRESTORE SYNC & ADMIN ALERTS
    # ══════════════════════════════════════════════════════════════════

    async def _sync_vehicle_doc_approved(self, driver, vehicle, doc_type: str):
        """Sync vehicle document approval to Firestore."""
        try:
            from config import _HAS_FIRESTORE, firestore_sync
            if _HAS_FIRESTORE and firestore_sync:
                update_data = {f"{doc_type}_valid": True}
                if vehicle:
                    if vehicle.insurance_valid and vehicle.registration_valid:
                        update_data["all_docs_valid"] = True
                firestore_sync._db.collection("drivers").document(
                    f"sql_{driver.id}"
                ).update(update_data)
        except Exception as e:
            logger.warning("[DocApproval] Firestore vehicle sync failed: %s", e)

    async def _alert_admin(
        self, driver, alert_type: str, message: str, severity: str = "medium"
    ):
        try:
            from services.admin_alerts import send_alert, CRITICAL, HIGH, MEDIUM, LOW
            severity_map = {"critical": CRITICAL, "high": HIGH, "medium": MEDIUM, "low": LOW}
            await send_alert(
                alert_type=f"doc_approval_{alert_type}",
                title=f"Docs: {alert_type.replace('_', ' ').title()}",
                message=message,
                severity=severity_map.get(severity, MEDIUM),
                data={
                    "driver_id": driver.id,
                    "driver_name": f"{driver.first_name} {driver.last_name}",
                    "email": driver.email or "",
                    "phone": driver.phone or "",
                },
            )
        except Exception as e:
            logger.warning("[DocApproval] Admin alert failed: %s", e)


# Singleton
document_approval_agent = DocumentApprovalAgent()
