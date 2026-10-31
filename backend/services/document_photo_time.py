"""A document's date follows its PHOTO (owner spec 2026-10-31: "cada foto
quiero que tenga fecha y hora para todos los drivers").

The dispatch panel prints each card's ``created_at`` as the photo's date and
time. But a re-upload replaces the file IN PLACE on the same row (driver
re-sends a license, dispatch's "Actualizar", the signup flow…) — six code
paths assign ``Document.file_path`` — so the date stayed on the FIRST photo
forever. This listener renews ``created_at`` whenever the file actually
changes, in one place, for every path present and future. ``created_at`` is
only ever used to order documents newest-first, which stays correct.

Imported once from main.py; importing registers the listener.
"""

from datetime import datetime, timezone

from sqlalchemy import event
from sqlalchemy.orm import attributes

from models.database import Document

_UNSET = (attributes.NO_VALUE, attributes.NEVER_SET, None)


@event.listens_for(Document.file_path, "set")
def _photo_replaced(target, value, oldvalue, initiator):
    # First photo: the row's own default stamps it. A value loaded from the
    # database never fires "set", so only real replacements land here.
    if oldvalue in _UNSET or not value or value == oldvalue:
        return
    target.created_at = datetime.now(timezone.utc)
