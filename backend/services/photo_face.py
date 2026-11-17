"""Where the face is in a profile photo, so the panel's round avatars show
the face (owner 2026-11-16: "que la foto de perfil se vean bien en cada
círculo"). Drivers' selfies are taken in the car: the face is small and low,
and a plain centred crop shows the headliner.

Found once per photo with OpenCV's YuNet face detector (the 230 KB model
in services/models, from opencv_zoo, MIT) — offline and free, no API call
per photo. The old Haar cascade missed a face turned a little and marked a
temple instead; YuNet finds selfies at three-quarter view. The answer is cached in one
AppConfig row per person (`photo_face:{user_id}`) together with a hash of
the photo URL, so a new photo is looked at again. No face found = null, and
the panel keeps the centred crop.

Only photos on our own storage are downloaded (Firebase / Google storage,
Google profile photos, the Tigris bucket), over https and without following
redirects: one auth route lets the app save any https URL as its photo, and
the server must not fetch arbitrary addresses for it.
"""
from __future__ import annotations

import asyncio
import hashlib
import json
import logging
import threading
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Optional
from urllib.parse import urlparse

from sqlalchemy import select

logger = logging.getLogger(__name__)

_KEY = "photo_face:{}"
_MAX_BYTES = 6 * 1024 * 1024
_MAX_SIDE = 640
_PER_CALL = 8
_RETRY_AFTER_S = 600
_ALLOWED_HOSTS = (
    "firebasestorage.googleapis.com",
    "storage.googleapis.com",
    "googleusercontent.com",
    "firebasestorage.app",
    "storageapi.dev",
)

_sem = asyncio.Semaphore(2)
_pending: set[int] = set()
_tasks: set = set()  # strong refs: a bare create_task can be collected mid-run
_failed_at: dict[int, float] = {}
_MODEL = Path(__file__).resolve().parent / "models" / "face_detection_yunet_2023mar.onnx"
_MIN_SCORE = 0.8
_detector = None
_detector_lock = threading.Lock()


def url_ok(url: Optional[str]) -> bool:
    try:
        u = urlparse(url or "")
    except ValueError:
        return False
    host = (u.hostname or "").lower()
    return u.scheme == "https" and any(host == h or host.endswith("." + h) for h in _ALLOWED_HOSTS)


def _hash(url: str) -> str:
    return hashlib.sha1(url.encode("utf-8")).hexdigest()[:16]


def detect(data: bytes) -> Optional[dict]:
    """The largest face, as fractions of the image: centre (cx, cy), width
    (s), and the image's height/width (ar). None when there is none."""
    global _detector
    import cv2  # lazy: the app runs without it, the feature just stays off
    import numpy as np

    img = cv2.imdecode(np.frombuffer(data, np.uint8), cv2.IMREAD_COLOR)
    if img is None:
        return None
    h, w = img.shape[:2]
    if not h or not w:
        return None
    scale = min(1.0, _MAX_SIDE / max(h, w))
    if scale < 1.0:
        img = cv2.resize(img, (max(1, int(w * scale)), max(1, int(h * scale))), interpolation=cv2.INTER_AREA)
    sh, sw = img.shape[:2]
    with _detector_lock:  # one detector, not thread-safe
        if _detector is None:
            _detector = cv2.FaceDetectorYN.create(str(_MODEL), "", (sw, sh), _MIN_SCORE, 0.3, 20)
        _detector.setInputSize((sw, sh))
        _, faces = _detector.detect(img)
    if faces is None or len(faces) == 0:
        return None
    x, y, fw, fh = (float(v) for v in max(faces, key=lambda f: f[2] * f[3])[:4])
    return {
        "cx": round(min(1.0, max(0.0, (x + fw / 2) / sw)), 4),
        "cy": round(min(1.0, max(0.0, (y + fh / 2) / sh)), 4),
        "s": round(min(1.0, fw / sw), 4),
        "ar": round(sh / sw, 4),
    }


async def _download(url: str) -> Optional[bytes]:
    import httpx

    async with httpx.AsyncClient(timeout=8.0, follow_redirects=False) as client:
        async with client.stream("GET", url) as r:
            if r.status_code != 200:
                return None
            chunks, size = [], 0
            async for chunk in r.aiter_bytes():
                size += len(chunk)
                if size > _MAX_BYTES:
                    return None
                chunks.append(chunk)
    return b"".join(chunks)


async def _store(user_id: int, url: str, face: Optional[dict]) -> None:
    from models.database import AppConfig, SessionLocal

    value = json.dumps({"url": _hash(url), "face": face,
                        "at": datetime.now(timezone.utc).isoformat()})
    async with SessionLocal() as db:
        key = _KEY.format(user_id)
        row = (await db.execute(select(AppConfig).where(AppConfig.key == key))).scalar_one_or_none()
        if row is None:
            db.add(AppConfig(key=key, value=value, description="Dónde está la cara en la foto de perfil (panel)"))
        else:
            row.value = value
        await db.commit()


async def _compute(user_id: int, url: str) -> None:
    try:
        async with _sem:
            data = await _download(url)
            if data is None:
                _failed_at[user_id] = time.monotonic()
                return
            face = await asyncio.to_thread(detect, data)
            await _store(user_id, url, face)
    except Exception as e:  # never breaks a page: the avatar stays centred
        _failed_at[user_id] = time.monotonic()
        logger.warning("[PhotoFace] user %s: %s", user_id, e)
    finally:
        _pending.discard(user_id)


def _schedule(user_id: int, url: str) -> None:
    if user_id in _pending:
        return
    failed = _failed_at.get(user_id)
    if failed is not None and time.monotonic() - failed < _RETRY_AFTER_S:
        return
    _pending.add(user_id)
    task = asyncio.get_running_loop().create_task(_compute(user_id, url))
    _tasks.add(task)
    task.add_done_callback(_tasks.discard)


async def faces_for(db, photos: dict[int, Optional[str]]) -> dict[int, Optional[dict]]:
    """The known face of each person's CURRENT photo. Photos not looked at
    yet are queued in the background (a few per call) and show up on a
    later call."""
    from models.database import AppConfig

    wanted = {uid: url for uid, url in photos.items() if uid and url_ok(url)}
    if not wanted:
        return {}
    rows = (await db.execute(
        select(AppConfig).where(AppConfig.key.in_([_KEY.format(uid) for uid in wanted]))
    )).scalars().all()
    cached: dict[int, dict] = {}
    for row in rows:
        try:
            cached[int(row.key.split(":", 1)[1])] = json.loads(row.value or "{}")
        except (ValueError, TypeError):
            continue
    out: dict[int, Optional[dict]] = {}
    queued = 0
    for uid, url in wanted.items():
        c = cached.get(uid)
        if c is not None and c.get("url") == _hash(url):
            out[uid] = c.get("face")
        elif queued < _PER_CALL:
            queued += 1
            _schedule(uid, url)
    return out
