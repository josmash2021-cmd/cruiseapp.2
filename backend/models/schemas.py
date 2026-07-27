"""Cruise App — Pydantic request/response schemas."""

from typing import Optional
from pydantic import BaseModel, field_validator, model_validator


def _sanitize_check(value: str) -> str:
    """Light validation stub — full sanitization happens in security layer."""
    if not value:
        return value
    return value.strip()


# ═══════════════════════════════════════════════════════
#  Auth Schemas
# ═══════════════════════════════════════════════════════

class RegisterIn(BaseModel):
    first_name: str
    last_name: str
    email: Optional[str] = None
    phone: Optional[str] = None
    password: str
    photo_url: Optional[str] = None
    role: str = "rider"

    @field_validator('first_name', 'last_name')
    @classmethod
    def validate_name(cls, v):
        v = v.strip()
        if len(v) > 100:
            raise ValueError('Name too long')
        return v

    @field_validator('email')
    @classmethod
    def validate_email(cls, v):
        if v is None:
            return v
        v = v.strip().lower()
        if len(v) > 255 or '@' not in v:
            raise ValueError('Invalid email')
        return v

    @field_validator('password')
    @classmethod
    def validate_password(cls, v):
        if len(v) < 8 or len(v) > 128:
            raise ValueError('Password must be 8-128 characters')
        import re as _re
        if not _re.search(r'[A-Z]', v):
            raise ValueError('Password must contain at least one uppercase letter')
        if not _re.search(r'[a-z]', v):
            raise ValueError('Password must contain at least one lowercase letter')
        if not _re.search(r'[0-9]', v):
            raise ValueError('Password must contain at least one number')
        if not _re.search(r'[!@#$%^&*(),.?":{}|<>]', v):
            raise ValueError('Password must contain at least one special character')
        return v


class CheckExistsIn(BaseModel):
    identifier: str
    role: Optional[str] = None


class LoginIn(BaseModel):
    identifier: str
    password: str
    role: Optional[str] = None


class CompleteLoginIn(BaseModel):
    login_token: str


class SocialAuthIn(BaseModel):
    provider: str
    id_token: str
    first_name: Optional[str] = None
    last_name: Optional[str] = None
    photo_url: Optional[str] = None
    role: str = "rider"
    login_only: bool = False


class SendOtpIn(BaseModel):
    phone: Optional[str] = None
    email: Optional[str] = None

    @model_validator(mode='after')
    def validate_contact(self):
        if not self.phone and not self.email:
            raise ValueError('Either phone or email is required')
        return self


class VerifyOtpIn(BaseModel):
    phone: Optional[str] = None
    email: Optional[str] = None
    code: str

    @model_validator(mode='after')
    def validate_contact(self):
        if not self.phone and not self.email:
            raise ValueError('Either phone or email is required')
        return self


class OwnerLogin(BaseModel):
    email: str
    password: str


class ApplyReferralIn(BaseModel):
    code: str


# ═══════════════════════════════════════════════════════
#  Trip Schemas
# ═══════════════════════════════════════════════════════

class CreateTripIn(BaseModel):
    rider_id: int
    pickup_address: str
    dropoff_address: str
    pickup_lat: float
    pickup_lng: float
    dropoff_lat: float
    dropoff_lng: float
    fare: Optional[float] = None
    vehicle_type: Optional[str] = None
    scheduled_at: Optional[str] = None
    is_airport: bool = False
    airport_code: Optional[str] = None
    terminal: Optional[str] = None
    pickup_zone: Optional[str] = None
    notes: Optional[str] = None
    stripe_payment_intent_id: Optional[str] = None


class AcceptTripIn(BaseModel):
    driver_id: int


# ═══════════════════════════════════════════════════════
#  Driver Schemas
# ═══════════════════════════════════════════════════════

class DriverLocationIn(BaseModel):
    lat: float
    lng: float
    is_online: bool = True


class CashoutIn(BaseModel):
    amount: float
    # "standard" (free, 1-2 days, default) or "instant" (1.5% fee, minutes).
    method: str = "standard"


# ═══════════════════════════════════════════════════════
#  Payment Schemas
# ═══════════════════════════════════════════════════════

class PayoutMethodIn(BaseModel):
    method_type: str
    display_name: str
    set_default: bool = False


class RiderPaymentMethodIn(BaseModel):
    method_type: str
    display_name: str
    stripe_pm_id: Optional[str] = None
    # NOTE: Raw bank account numbers are NOT accepted. Use stripe_pm_id
    # for cards or plaid_token for Plaid-linked bank accounts.
    account_type: Optional[str] = None  # 'checking' or 'savings'
    bank_name: Optional[str] = None
    plaid_token: Optional[str] = None  # Plaid verification token (optional)
    set_default: bool = False


class BankAccountAttachIn(BaseModel):
    # Financial Connections account id (fca_...) collected client-side by the
    # native Stripe SDK. Raw account/routing numbers are never accepted.
    account_id: str


class WalletTopUpIn(BaseModel):
    amount: float
    payment_method_id: Optional[str] = None


class WalletWithdrawIn(BaseModel):
    amount: float
    payout_method_id: int


class PaymentIntentIn(BaseModel):
    amount: int
    currency: str = "usd"
    payment_method_id: Optional[str] = None
    trip_id: Optional[int] = None
    hold_only: bool = False


class PayPalOrderIn(BaseModel):
    amount: str = "1.00"
    currency: str = "USD"
    description: str = "Cruise ride payment"


class PayPalCaptureIn(BaseModel):
    order_id: str


# ═══════════════════════════════════════════════════════
#  Dispatch Schemas
# ═══════════════════════════════════════════════════════

class DispatchRequestIn(BaseModel):
    rider_id: int
    pickup_address: str
    dropoff_address: str
    pickup_lat: float
    pickup_lng: float
    dropoff_lat: float
    dropoff_lng: float
    fare: Optional[float] = None
    vehicle_type: Optional[str] = None
    is_airport: bool = False
    airport_code: Optional[str] = None
    terminal: Optional[str] = None
    pickup_zone: Optional[str] = None
    notes: Optional[str] = None
    scheduled_at: Optional[str] = None
    meet_inside: bool = False
    stripe_payment_intent_id: Optional[str] = None


# ═══════════════════════════════════════════════════════
#  Admin Schemas
# ═══════════════════════════════════════════════════════

class AdminStatsResponse(BaseModel):
    total_trips_today: int
    active_trips: int
    pending_trips: int
    active_drivers: int
    total_revenue_today: float
    avg_trip_time: float
    completion_rate: float


class AdminUpdateTripIn(BaseModel):
    status: Optional[str] = None
    driver_id: Optional[int] = None
    fare: Optional[float] = None
    vehicle_type: Optional[str] = None
    notes: Optional[str] = None
    cancel_reason: Optional[str] = None


class AdminCancelTripIn(BaseModel):
    reason: Optional[str] = None


class VehicleIn(BaseModel):
    make: Optional[str] = None
    model: Optional[str] = None
    year: Optional[int] = None
    color: Optional[str] = None
    plate: Optional[str] = None
    vin: Optional[str] = None
