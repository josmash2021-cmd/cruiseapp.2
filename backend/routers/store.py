"""Driver merch store (cruiseinride.com/store) — drivers only.

Sells Cruise-branded merchandise to registered drivers: personalized
business cards, car sign, stickers. The website asks for the catalog and
prices HERE (never trusts client amounts), builds a Stripe Checkout Session
per order, and confirms payment after the redirect back. Merch is paid up
front — no hold, no capture split, nothing touches driver earnings.
"""
import hashlib
import hmac
import json
import logging
from datetime import datetime, timezone

from fastapi import APIRouter, Depends, HTTPException
from fastapi.responses import Response
from pydantic import BaseModel, Field
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from config import _HAS_STRIPE, _stripe_mod, STRIPE_SECRET, PUBLIC_URL
from models.database import StoreOrder, User, get_db
from services.store_card_image import render_card_png
from utils.security import JWT_SECRET, JWT_ALGORITHM
from fastapi import Request
import jwt as _jwt

# ── Web-safe auth ────────────────────────────────────────────────────────
# The store is consumed by cruiseinride.com, which cannot produce the app
# HMAC signature headers — same reason /auth/web/me exists. The driver JWT
# alone authenticates (same trust level as every /auth/web/* endpoint).
async def _get_store_user(
    request: Request,
    db: AsyncSession = Depends(get_db),
) -> User:
    auth = request.headers.get("authorization", "")
    if not auth.startswith("Bearer "):
        raise HTTPException(401, "Not authenticated")
    try:
        payload = _jwt.decode(auth.split(" ", 1)[1], JWT_SECRET,
                              algorithms=[JWT_ALGORITHM])
        user_id = int(payload.get("sub", 0))
    except (_jwt.InvalidTokenError, ValueError):
        raise HTTPException(401, "Invalid or expired token")
    r = await db.execute(select(User).where(User.id == user_id))
    user = r.scalar_one_or_none()
    if not user:
        raise HTTPException(401, "Invalid or expired token")
    return user

router = APIRouter()

# ── Catalog & prices ─────────────────────────────────────────────────────
# Prices in cents — edit HERE to change the store; the site only displays
# what this endpoint returns. The card preview on the site personalizes the
# BACK face (name + phone); the front is the fixed Cruise design.
PRODUCTS = {
    "business_card": {
        "name_es": "Tarjetas de presentación personalizadas (paquete de 50)",
        "name_en": "Personalized business cards (pack of 50)",
        "price_cents": 1000,
        "customizable": True,
    },
    "car_sign": {
        "name_es": "Letrero Cruise para el carro",
        "name_en": "Cruise car sign",
        "price_cents": 4500,
        "customizable": False,
    },
    "sticker_pack": {
        "name_es": "Paquete de stickers Cruise (x5)",
        "name_en": "Cruise sticker pack (x5)",
        "price_cents": 1200,
        "customizable": False,
    },
}

MAX_QTY_PER_ITEM = 20
OWNER_NOTIFY_EMAIL = "support@cruiseinride.com"


def _require_driver(user: User) -> None:
    if (user.role or "") != "driver":
        raise HTTPException(403, "The store is for registered drivers only")


class _ItemIn(BaseModel):
    product_id: str
    qty: int = Field(ge=1, le=MAX_QTY_PER_ITEM)


class CheckoutIn(BaseModel):
    items: list[_ItemIn] = Field(min_length=1, max_length=10)
    custom_name: str | None = Field(default=None, max_length=120)
    custom_phone: str | None = Field(default=None, max_length=40)
    ship_name: str = Field(min_length=2, max_length=160)
    ship_address1: str = Field(min_length=3, max_length=200)
    ship_address2: str | None = Field(default=None, max_length=200)
    ship_city: str = Field(min_length=2, max_length=100)
    ship_state: str = Field(min_length=2, max_length=50)
    ship_zip: str = Field(min_length=3, max_length=20)
    success_url: str = Field(max_length=300)
    cancel_url: str = Field(max_length=300)


class ConfirmIn(BaseModel):
    session_id: str = Field(min_length=5, max_length=120)


# ── Signed card image ────────────────────────────────────────────────────
# The owner notification email links the personalized card image. The link
# must work from a mail client (no JWT), so access is an HMAC signature of
# the order id — unguessable, never expires, and only ever exposes the
# card's back face (name + phone the driver typed).
def _card_sig(order_id: int) -> str:
    return hmac.new(
        JWT_SECRET.encode(), f"store-card:{order_id}".encode(), hashlib.sha256
    ).hexdigest()[:32]


@router.get("/store/card-image/{order_id}.png")
async def store_card_image(order_id: int, sig: str = "",
                           db: AsyncSession = Depends(get_db)):
    if not hmac.compare_digest(sig, _card_sig(order_id)):
        raise HTTPException(403, "Invalid signature")
    r = await db.execute(select(StoreOrder).where(StoreOrder.id == order_id))
    order = r.scalar_one_or_none()
    if not order:
        raise HTTPException(404, "Order not found")
    png = render_card_png(order.custom_name or "", order.custom_phone or "")
    return Response(content=png, media_type="image/png",
                    headers={"Cache-Control": "public, max-age=86400"})


@router.get("/store/products")
async def list_products(user: User = Depends(_get_store_user)):
    """Catalog with server-side prices. Drivers only."""
    _require_driver(user)
    return {
        "products": [
            {"id": pid, "price_cents": p["price_cents"],
             "name_es": p["name_es"], "name_en": p["name_en"],
             "customizable": p["customizable"]}
            for pid, p in PRODUCTS.items()
        ]
    }


@router.post("/store/checkout")
async def store_checkout(
    body: CheckoutIn,
    user: User = Depends(_get_store_user),
    db: AsyncSession = Depends(get_db),
):
    """Create the order (pending) + a Stripe Checkout Session for it."""
    _require_driver(user)
    if not (_HAS_STRIPE and STRIPE_SECRET):
        raise HTTPException(503, "Payments not configured")

    # Price EVERYTHING server-side — the client only sends ids and qtys.
    line_items = []
    total_cents = 0
    items_out = []
    has_card = False
    for it in body.items:
        prod = PRODUCTS.get(it.product_id)
        if not prod:
            raise HTTPException(400, f"Unknown product: {it.product_id}")
        unit = prod["price_cents"]
        total_cents += unit * it.qty
        items_out.append(
            {"product_id": it.product_id, "qty": it.qty, "unit_cents": unit})
        if prod["customizable"]:
            has_card = True
        line_items.append({
            "price_data": {
                "currency": "usd",
                "unit_amount": unit,
                "product_data": {"name": prod["name_en"]},
            },
            "quantity": it.qty,
        })
    if total_cents <= 0 or total_cents > 500_000:
        raise HTTPException(400, "Invalid order total")
    # Personalization is required when the order includes cards.
    if has_card and not ((body.custom_name or "").strip() and (body.custom_phone or "").strip()):
        raise HTTPException(400, "Name and phone are required to personalize the cards")

    order = StoreOrder(
        driver_id=user.id,
        items_json=json.dumps(items_out),
        custom_name=(body.custom_name or "").strip() or None,
        custom_phone=(body.custom_phone or "").strip() or None,
        ship_name=body.ship_name.strip(),
        ship_address1=body.ship_address1.strip(),
        ship_address2=(body.ship_address2 or "").strip() or None,
        ship_city=body.ship_city.strip(),
        ship_state=body.ship_state.strip(),
        ship_zip=body.ship_zip.strip(),
        total_cents=total_cents,
        status="pending",
    )
    db.add(order)
    await db.commit()
    await db.refresh(order)

    try:
        session = _stripe_mod.checkout.Session.create(
            payment_method_types=["card"],
            line_items=line_items,
            mode="payment",
            success_url=body.success_url + ("&" if "?" in body.success_url else "?")
                      + "session_id={CHECKOUT_SESSION_ID}",
            cancel_url=body.cancel_url,
            customer_email=user.email,
            metadata={"store_order_id": str(order.id), "driver_id": str(user.id)},
        )
    except Exception as e:
        logging.error("[Store] checkout session failed: %s", e)
        raise HTTPException(502, "Could not create the payment session")

    order.stripe_session_id = session.id
    await db.commit()
    logging.info("[Store] order %s driver %s $%.2f — session %s",
                 order.id, user.id, total_cents / 100, session.id)
    return {"url": session.url, "order_id": order.id}


@router.post("/store/confirm")
async def store_confirm(
    body: ConfirmIn,
    user: User = Depends(_get_store_user),
    db: AsyncSession = Depends(get_db),
):
    """Confirm payment after the Stripe redirect and mark the order paid.

    Idempotent: the unique stripe_session_id + status='paid' make a second
    call a no-op that just returns the order.
    """
    _require_driver(user)
    if not (_HAS_STRIPE and STRIPE_SECRET):
        raise HTTPException(503, "Payments not configured")

    r = await db.execute(
        select(StoreOrder).where(StoreOrder.stripe_session_id == body.session_id))
    order = r.scalar_one_or_none()
    if not order or order.driver_id != user.id:
        raise HTTPException(404, "Order not found")
    if order.status == "paid":
        return {"status": "paid", "order_id": order.id}

    try:
        session = _stripe_mod.checkout.Session.retrieve(body.session_id)
    except Exception as e:
        logging.error("[Store] session retrieve failed: %s", e)
        raise HTTPException(502, "Could not verify the payment")

    if getattr(session, "payment_status", "") != "paid":
        return {"status": getattr(session, "payment_status", "unpaid"),
                "order_id": order.id}

    order.status = "paid"
    order.paid_at = datetime.now(timezone.utc)
    await db.commit()

    # Notify the owner (production/fulfillment) + confirm to the driver.
    # Both best effort: the order is already paid and must not 500 on a
    # mail provider hiccup.
    items = json.loads(order.items_json)
    items_txt = ", ".join(
        f"{PRODUCTS.get(i['product_id'], {}).get('name_en', i['product_id'])} x{i['qty']}"
        for i in items)
    ship_txt = (f"{order.ship_name}, {order.ship_address1} "
                f"{order.ship_address2 or ''}, {order.ship_city}, "
                f"{order.ship_state} {order.ship_zip}")
    try:
        from services.email_sms_service import _send_email
        card_img = (
            f"{PUBLIC_URL}/store/card-image/{order.id}.png?sig={_card_sig(order.id)}"
        )
        _send_email(
            OWNER_NOTIFY_EMAIL,
            f"New store order #{order.id} — ${order.total_cents / 100:.2f}",
            f"<h3>Order #{order.id} (PAID)</h3>"
            f"<p><b>Driver:</b> {user.first_name} {user.last_name} "
            f"(id {user.id}, {user.email}, {user.phone or '-'})</p>"
            f"<p><b>Items:</b> {items_txt}</p>"
            f"<p><b>Card personalization:</b> {order.custom_name or '-'} · "
            f"{order.custom_phone or '-'}</p>"
            f"<p><b>Ship to:</b> {ship_txt}</p>"
            f"<p><b>Total paid:</b> ${order.total_cents / 100:.2f} "
            f"(Stripe session {order.stripe_session_id})</p>"
            f"<p><b>Card back (print):</b></p>"
            f"<p><img src=\"{card_img}\" alt=\"business card\" "
            f"style=\"max-width:520px;border-radius:10px\"></p>",
            skip_emailjs=True,
        )
    except Exception as e:
        logging.warning("[Store] owner notify failed for order %s: %s", order.id, e)

    try:
        from services.email_sms_service import _send_email
        _send_email(
            user.email,
            f"¡Felicidades por tu nuevo pedido! — Orden #{order.id}",
            f"<div style=\"font-family:Arial,sans-serif\">"
            f"<h2>¡Felicidades por tu nuevo pedido, {user.first_name}!</h2>"
            f"<p>Tu pago se procesó correctamente y tu pedido ya está en "
            f"producción.</p>"
            f"<p><b>Orden:</b> #{order.id}<br>"
            f"<b>Productos:</b> {items_txt}<br>"
            f"<b>Personalización:</b> {order.custom_name or '-'} · "
            f"{order.custom_phone or '-'}<br>"
            f"<b>Envío a:</b> {ship_txt}<br>"
            f"<b>Total:</b> ${order.total_cents / 100:.2f}</p>"
            f"<p><b>Tiempo estimado de entrega: 3 a 5 días hábiles.</b></p>"
            f"<p>Gracias por rodar con Cruise.<br>— Equipo Cruise in Ride</p>"
            f"</div>",
            skip_emailjs=True,
        )
    except Exception as e:
        logging.warning("[Store] driver confirm email failed for order %s: %s", order.id, e)

    logging.info("[Store] order %s PAID (driver %s)", order.id, user.id)
    return {"status": "paid", "order_id": order.id}
