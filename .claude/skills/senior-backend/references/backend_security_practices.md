# Backend Security Practices — CruiseApp

## Authentication & Authorization

### Supabase Auth
- Use Supabase Auth for user management (not custom auth)
- OTP email codes for verification
- JWT tokens for session management
- Validate tokens on every protected endpoint

### Endpoint Protection
```python
# Every protected endpoint must use Depends
@router.get("/profile")
async def get_profile(user=Depends(get_current_user)):
    # user is guaranteed to be authenticated
    pass

# Role-based access
async def require_driver(user=Depends(get_current_user)):
    if user.role != "driver":
        raise HTTPException(status_code=403, detail="Drivers only")
    return user
```

### Token Handling
- Never log tokens or include in error messages
- Validate token expiration server-side
- Use short-lived access tokens with refresh tokens
- Store service key only in environment variables

## Input Validation

### Pydantic Models
```python
from pydantic import BaseModel, Field, validator

class DriverDocument(BaseModel):
    document_type: str = Field(..., pattern="^(license|insurance|registration)$")
    document_url: str = Field(..., min_length=10)
    expiry_date: str

    @validator("expiry_date")
    def validate_expiry(cls, v):
        # Ensure document is not expired
        pass
```

### SQL Injection Prevention
- NEVER use f-strings or string concatenation for queries
- Always use Supabase client methods (`.eq()`, `.in_()`, etc.)
- If raw SQL is needed, use parameterized queries

### File Upload Validation
- Validate file type (MIME type check)
- Limit file size (e.g., 5MB for documents, 2MB for photos)
- Store in Supabase Storage with proper bucket policies
- Never serve user-uploaded files directly

## Data Protection

### PII Handling
- Phone numbers: display masked (***-***-1234)
- Email: never expose other users' emails
- Driver documents: accessible only to driver and admin
- Payment info: never store full card numbers

### API Response Filtering
```python
# Don't return sensitive fields
class PublicDriverProfile(BaseModel):
    id: str
    first_name: str
    rating: float
    vehicle_model: str
    # Exclude: email, phone, ssn, bank_info
```

## Rate Limiting

### Critical Endpoints
- OTP request: max 3 per minute per email
- Login attempts: max 5 per minute per IP
- Trip creation: max 10 per minute per user
- Payment processing: max 5 per minute per user

## Environment Security

### Secret Management
- All secrets in `.env` (never committed to git)
- Use `SUPABASE_URL`, `SUPABASE_SERVICE_KEY`, etc.
- Different keys for dev/staging/production
- Rotate keys periodically

### CORS Configuration
```python
from fastapi.middleware.cors import CORSMiddleware

app.add_middleware(
    CORSMiddleware,
    allow_origins=["https://yourdomain.com"],  # Not "*" in production
    allow_methods=["GET", "POST", "PUT", "DELETE"],
    allow_headers=["Authorization", "Content-Type"],
)
```
