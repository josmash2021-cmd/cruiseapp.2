"""
Railway deployment helper - Add this to main.py imports section
This adds better error handling and logging for Railway
"""
import logging
import traceback
from fastapi import Request
from fastapi.responses import JSONResponse

# Configure detailed logging for Railway
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s'
)
logger = logging.getLogger(__name__)

# Add this after creating the FastAPI app:
# @app.exception_handler(Exception)
# async def global_exception_handler(request: Request, exc: Exception):
#     logger.error(f"Global error: {str(exc)}")
#     logger.error(traceback.format_exc())
#     return JSONResponse(
#         status_code=500,
#         content={"detail": f"Internal error: {str(exc)}"}
#     )

# Enhanced health check endpoint:
# @app.get("/health")
# async def health_check():
#     try:
#         # Test database connection
#         async with SessionLocal() as session:
#             result = await session.execute(text("SELECT 1"))
#             db_status = "connected" if result.scalar() == 1 else "error"
#         
#         return {
#             "status": "healthy",
#             "database": db_status,
#             "timestamp": datetime.now(timezone.utc).isoformat()
#         }
#     except Exception as e:
#         logger.error(f"Health check failed: {e}")
#         return JSONResponse(
#             status_code=500,
#             content={"status": "unhealthy", "error": str(e)}
#         )
