"""Local ephemeral storage service for CRUISEAPP2.

Uses the Railway Volume mounted at VOLUME_PATH for temporary file operations.
NEVER stores permanent user data here — all persistent files go to S3.

Typical use cases:
- Temporary processing of uploaded files before S3 transfer
- Caching large payloads during batch operations
- Staging area for document OCR / image resizing pipelines
"""

import os
import logging
import uuid
from pathlib import Path
from typing import Optional
from datetime import datetime, timezone

logger = logging.getLogger(__name__)

# ── Environment ──
VOLUME_PATH = os.getenv("VOLUME_PATH", "")

# Fallback: if no volume is mounted, use a temp dir inside the project
# (this works for local dev but NOT for production persistence)
if not VOLUME_PATH:
    VOLUME_PATH = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "data")
    logger.warning(
        "[LocalStorage] VOLUME_PATH not set — falling back to %s (ephemeral on Railway!)",
        VOLUME_PATH,
    )

# Subdirectories
_TEMP_DIR = os.path.join(VOLUME_PATH, "temp")
_CACHE_DIR = os.path.join(VOLUME_PATH, "cache")

# Ensure directories exist
os.makedirs(_TEMP_DIR, exist_ok=True)
os.makedirs(_CACHE_DIR, exist_ok=True)

# Max temp file age before auto-cleanup (seconds)
_MAX_TEMP_AGE_SECONDS = 3600  # 1 hour


def _ensure_dir(path: str) -> Path:
    """Ensure a directory exists and return its Path."""
    p = Path(path)
    p.mkdir(parents=True, exist_ok=True)
    return p


def save_temp_file(data: bytes, prefix: str = "tmp", suffix: str = "") -> str:
    """Save data to a temporary file on the volume.

    Args:
        data: Raw bytes to write.
        prefix: Optional prefix for the filename (e.g. "upload", "ocr").
        suffix: Optional file extension (e.g. ".jpg", ".pdf").

    Returns:
        Absolute filepath of the saved temp file.
    """
    _ensure_dir(_TEMP_DIR)

    filename = f"{prefix}_{uuid.uuid4().hex}{suffix}"
    filepath = os.path.join(_TEMP_DIR, filename)

    with open(filepath, "wb") as f:
        f.write(data)

    logger.info("[LocalStorage] Saved temp file: %s (%d bytes)", filepath, len(data))
    return filepath


def cleanup_temp_file(filepath: str) -> bool:
    """Delete a temporary file.

    Args:
        filepath: Absolute path to the file.

    Returns:
        True if deleted (or didn't exist), False on error.
    """
    try:
        if os.path.exists(filepath):
            os.remove(filepath)
            logger.info("[LocalStorage] Deleted temp file: %s", filepath)
        return True
    except OSError as e:
        logger.error("[LocalStorage] Failed to delete %s: %s", filepath, e)
        return False


def save_cache_file(key: str, data: bytes, suffix: str = ".bin") -> str:
    """Save data to the cache directory with a deterministic key.

    Args:
        key: Deterministic cache key (will be sanitized).
        data: Raw bytes to write.
        suffix: File extension.

    Returns:
        Absolute filepath of the cached file.
    """
    _ensure_dir(_CACHE_DIR)

    # Sanitize key to prevent path traversal
    safe_key = Path(key).name.replace("..", "").replace("/", "_").replace("\\", "_")
    filename = f"{safe_key}{suffix}"
    filepath = os.path.join(_CACHE_DIR, filename)

    with open(filepath, "wb") as f:
        f.write(data)

    logger.info("[LocalStorage] Saved cache file: %s (%d bytes)", filepath, len(data))
    return filepath


def read_cache_file(key: str, suffix: str = ".bin") -> Optional[bytes]:
    """Read data from the cache directory.

    Args:
        key: Cache key.
        suffix: File extension.

    Returns:
        File bytes or None if not found.
    """
    safe_key = Path(key).name.replace("..", "").replace("/", "_").replace("\\", "_")
    filename = f"{safe_key}{suffix}"
    filepath = os.path.join(_CACHE_DIR, filename)

    if not os.path.exists(filepath):
        return None

    with open(filepath, "rb") as f:
        return f.read()


def cleanup_cache_file(key: str, suffix: str = ".bin") -> bool:
    """Delete a cached file.

    Args:
        key: Cache key.
        suffix: File extension.

    Returns:
        True if deleted (or didn't exist).
    """
    safe_key = Path(key).name.replace("..", "").replace("/", "_").replace("\\", "_")
    filename = f"{safe_key}{suffix}"
    filepath = os.path.join(_CACHE_DIR, filename)
    return cleanup_temp_file(filepath)


def cleanup_stale_temp_files(max_age_seconds: int = _MAX_TEMP_AGE_SECONDS) -> int:
    """Remove temp files older than max_age_seconds.

    Args:
        max_age_seconds: Age threshold in seconds.

    Returns:
        Number of files deleted.
    """
    if not os.path.exists(_TEMP_DIR):
        return 0

    now = datetime.now(timezone.utc).timestamp()
    deleted = 0

    for filename in os.listdir(_TEMP_DIR):
        filepath = os.path.join(_TEMP_DIR, filename)
        if not os.path.isfile(filepath):
            continue
        try:
            mtime = os.path.getmtime(filepath)
            if now - mtime > max_age_seconds:
                os.remove(filepath)
                deleted += 1
        except OSError:
            continue

    if deleted > 0:
        logger.info("[LocalStorage] Cleaned up %d stale temp files", deleted)
    return deleted


def get_volume_stats() -> dict:
    """Return volume usage statistics.

    Returns:
        {"total_mb": float, "used_mb": float, "free_mb": float,
         "temp_files": int, "cache_files": int}
    """
    try:
        import shutil
        stat = shutil.disk_usage(VOLUME_PATH)
        total_mb = stat.total / (1024 * 1024)
        used_mb = stat.used / (1024 * 1024)
        free_mb = stat.free / (1024 * 1024)
    except Exception as e:
        logger.warning("[LocalStorage] Could not get disk stats: %s", e)
        total_mb = used_mb = free_mb = 0.0

    temp_files = len([f for f in os.listdir(_TEMP_DIR) if os.path.isfile(os.path.join(_TEMP_DIR, f))]) if os.path.exists(_TEMP_DIR) else 0
    cache_files = len([f for f in os.listdir(_CACHE_DIR) if os.path.isfile(os.path.join(_CACHE_DIR, f))]) if os.path.exists(_CACHE_DIR) else 0

    return {
        "total_mb": round(total_mb, 2),
        "used_mb": round(used_mb, 2),
        "free_mb": round(free_mb, 2),
        "temp_files": temp_files,
        "cache_files": cache_files,
        "volume_path": VOLUME_PATH,
    }
