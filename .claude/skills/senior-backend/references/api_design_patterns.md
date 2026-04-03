# API Design Patterns — CruiseApp

## FastAPI Endpoint Patterns

### Standard CRUD Endpoint
```python
from fastapi import APIRouter, HTTPException, Depends
from pydantic import BaseModel

router = APIRouter(prefix="/api/v1/trips", tags=["trips"])

class TripCreate(BaseModel):
    rider_id: str
    pickup_lat: float
    pickup_lng: float
    dropoff_lat: float
    dropoff_lng: float

class TripResponse(BaseModel):
    id: str
    status: str
    rider_id: str
    driver_id: str | None
    estimated_fare: float

@router.post("/", response_model=TripResponse, status_code=201)
async def create_trip(trip: TripCreate, user=Depends(get_current_user)):
    # Validate user is the rider
    # Create trip in Supabase
    # Return created trip
    pass
```

### Authentication Dependency
```python
async def get_current_user(authorization: str = Header(...)):
    try:
        token = authorization.replace("Bearer ", "")
        user = supabase.auth.get_user(token)
        return user
    except Exception:
        raise HTTPException(status_code=401, detail="Invalid token")
```

### Pagination Pattern
```python
@router.get("/", response_model=list[TripResponse])
async def list_trips(
    limit: int = Query(default=20, le=100),
    offset: int = Query(default=0, ge=0),
    user=Depends(get_current_user)
):
    result = (
        supabase.table("trips")
        .select("*")
        .eq("rider_id", user.id)
        .range(offset, offset + limit - 1)
        .order("created_at", desc=True)
        .execute()
    )
    return result.data
```

## Error Handling Pattern
```python
from fastapi import HTTPException

# Consistent error responses
def not_found(resource: str):
    raise HTTPException(status_code=404, detail=f"{resource} not found")

def forbidden(message: str = "Not authorized"):
    raise HTTPException(status_code=403, detail=message)

def bad_request(message: str):
    raise HTTPException(status_code=400, detail=message)
```

## Supabase Client Pattern
```python
from supabase import create_client
import os

supabase = create_client(
    os.getenv("SUPABASE_URL"),
    os.getenv("SUPABASE_SERVICE_KEY")
)
```

## Ride-Sharing Specific Patterns

### Trip Lifecycle States
```
REQUESTED -> ACCEPTED -> DRIVER_ARRIVED -> IN_PROGRESS -> COMPLETED
                                                       -> CANCELLED
         -> CANCELLED (by rider before acceptance)
```

### Location Update Pattern
- Use Firestore for real-time driver location (low latency)
- Store trip start/end coordinates in Supabase (persistent record)
- Calculate distance/fare on backend, not client

### Fare Calculation
- Always calculate server-side (never trust client-submitted fares)
- Store base rate, per-km rate, per-minute rate in config
- Apply surge pricing as a multiplier
- Round to 2 decimal places
