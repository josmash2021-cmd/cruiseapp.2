"""
Backfill: repair dispatch-panel fields on backend-synced Firestore trip docs.

Run (dry-run, prints what it would change):
    railway run python backend/scripts/backfill_trip_panel_fields.py
Apply:
    railway run python backend/scripts/backfill_trip_panel_fields.py --apply

Targets only docs with `sqliteId` (synced from this backend — dispatch-native
trips are left alone, they may legitimately be cash / km distances):

  - `distance_miles` missing/<=0  → haversine(pickup, dropoff) estimate
  - `duration` missing/<=0        → 2 min/mi estimate (same heuristic as trips.py)
  - `paymentMethod` 'cash'/absent → 'card' (rider-app trips require a Stripe hold)
  - `vehicleType` non-canonical   → normalize_tier ("VIP"→black, "SUV XL"→premium, ...)
  - legacy plain `distance` (miles written by the old sync_trip_status) is
    moved to `distance_miles` and deleted — the panel reads `distance` as km.

Idempotent: a doc that already matches every rule is skipped.
"""

import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from firebase_admin import firestore as _fs  # noqa: E402

import firestore_sync  # noqa: E402  (handles firebase-admin init)
from utils.helpers import _haversine  # noqa: E402
from services.vehicle_tiers import normalize_tier  # noqa: E402

APPLY = "--apply" in sys.argv

CANONICAL_TIERS = {"standard", "compact", "premium", "black"}


def repair(data: dict) -> dict:
    """Field updates needed for one trip doc, or {} if it is already fine."""
    updates = {}

    # ── distance: legacy plain `distance` holds MILES on backend-synced docs
    legacy_dist = data.get("distance")
    miles = data.get("distance_miles")
    if isinstance(legacy_dist, (int, float)) and legacy_dist > 0:
        if not isinstance(miles, (int, float)) or miles <= 0:
            updates["distance_miles"] = round(float(legacy_dist), 2)
        updates["distance"] = _fs.DELETE_FIELD
        miles = updates.get("distance_miles", miles)

    if (not isinstance(miles, (int, float)) or miles <= 0):
        plat, plng = data.get("pickupLat"), data.get("pickupLng")
        dlat, dlng = data.get("dropoffLat"), data.get("dropoffLng")
        if plat and dlat:
            miles = round(_haversine(plat, plng, dlat, dlng) * 0.621371, 1)
            if miles > 0:
                updates["distance_miles"] = miles

    # ── duration (minutes)
    dur = data.get("duration")
    if not isinstance(dur, (int, float)) or dur <= 0:
        final_miles = updates.get("distance_miles", miles)
        if isinstance(final_miles, (int, float)) and final_miles > 0:
            updates["duration"] = max(1, int(final_miles * 2))

    # ── payment method
    if (data.get("paymentMethod") or "cash") == "cash":
        updates["paymentMethod"] = "card"

    # ── vehicle tier
    vt = (data.get("vehicleType") or "").strip().lower()
    if vt not in CANONICAL_TIERS:
        updates["vehicleType"] = normalize_tier(data.get("vehicleType"))

    return updates


def main():
    firestore_sync._ensure_init()
    db = firestore_sync._db
    if db is None:
        print("[ERROR] Firestore no inicializado (faltan credenciales).")
        sys.exit(1)

    scanned = changed = skipped = 0
    batch = db.batch()
    pending = 0

    for doc in db.collection("trips").stream():
        data = doc.to_dict() or {}
        if "sqliteId" not in data:
            skipped += 1
            continue
        scanned += 1
        updates = repair(data)
        if not updates:
            continue
        changed += 1
        pretty = {k: ("<delete>" if v is _fs.DELETE_FIELD else v)
                  for k, v in updates.items()}
        print(f"{doc.id}: {pretty}")
        if APPLY:
            batch.update(doc.reference, updates)
            pending += 1
            if pending >= 400:
                batch.commit()
                batch = db.batch()
                pending = 0

    if APPLY and pending:
        batch.commit()

    mode = "APLICADO" if APPLY else "DRY-RUN (pasa --apply para escribir)"
    print(f"\n[{mode}] escaneados={scanned} reparados={changed} "
          f"omitidos(no-backend)={skipped}")


if __name__ == "__main__":
    main()
