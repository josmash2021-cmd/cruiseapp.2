"""
n8n Workflow Trigger Utility

This module provides fire-and-forget webhook triggers to n8n workflows.
All triggers are non-blocking and log errors without breaking the main app flow.
"""

import os
import httpx
import logging
from typing import Dict, Any, Optional
import asyncio

logger = logging.getLogger(__name__)

# Configuration from environment variables
N8N_BASE_URL = os.getenv("N8N_BASE_URL", "http://localhost:5678")
N8N_WEBHOOK_SECRET = os.getenv("N8N_WEBHOOK_SECRET", "")
N8N_ENABLED = os.getenv("N8N_ENABLED", "true").lower() == "true"
N8N_TIMEOUT = int(os.getenv("N8N_TIMEOUT", "5"))  # seconds


async def trigger_workflow(
    webhook_name: str,
    payload: Dict[str, Any],
    timeout: Optional[int] = None
) -> bool:
    """
    Trigger an n8n workflow via webhook (fire-and-forget).
    
    Args:
        webhook_name: The webhook path/name (e.g., 'new-user', 'payment-failed')
        payload: Dictionary containing the data to send to the workflow
        timeout: Optional timeout in seconds (defaults to N8N_TIMEOUT)
    
    Returns:
        bool: True if trigger was sent successfully, False otherwise
        
    Note:
        This is a fire-and-forget operation. Even if it fails, it won't
        raise exceptions or block the main application flow.
    """
    if not N8N_ENABLED:
        logger.debug(f"n8n is disabled. Skipping workflow trigger: {webhook_name}")
        return False
    
    if not N8N_BASE_URL:
        logger.warning("N8N_BASE_URL not configured. Cannot trigger workflow.")
        return False
    
    # Construct webhook URL
    webhook_url = f"{N8N_BASE_URL}/webhook/{webhook_name}"
    
    # Add secret to payload if configured
    if N8N_WEBHOOK_SECRET:
        payload["_webhook_secret"] = N8N_WEBHOOK_SECRET
    
    try:
        logger.info(f"Triggering n8n workflow: {webhook_name}")
        logger.debug(f"Webhook URL: {webhook_url}")
        logger.debug(f"Payload keys: {list(payload.keys())}")
        
        # Use httpx for async HTTP requests
        async with httpx.AsyncClient(timeout=timeout or N8N_TIMEOUT) as client:
            response = await client.post(
                webhook_url,
                json=payload,
                headers={"Content-Type": "application/json"}
            )
            
            # Log response
            if response.status_code in [200, 201, 202]:
                logger.info(
                    f"Successfully triggered n8n workflow '{webhook_name}' "
                    f"(status: {response.status_code})"
                )
                return True
            else:
                logger.warning(
                    f"n8n workflow '{webhook_name}' returned status {response.status_code}: "
                    f"{response.text[:200]}"
                )
                return False
                
    except httpx.TimeoutException:
        logger.error(
            f"Timeout triggering n8n workflow '{webhook_name}' after {timeout or N8N_TIMEOUT}s"
        )
        return False
        
    except httpx.ConnectError:
        logger.error(
            f"Cannot connect to n8n at {N8N_BASE_URL}. Is n8n running?"
        )
        return False
        
    except Exception as e:
        logger.error(
            f"Error triggering n8n workflow '{webhook_name}': {type(e).__name__}: {str(e)}",
            exc_info=True
        )
        return False


def trigger_workflow_background(
    webhook_name: str,
    payload: Dict[str, Any]
) -> None:
    """
    Trigger an n8n workflow in the background without awaiting.
    
    This is useful for synchronous contexts where you want to trigger
    a workflow but don't want to block or await the result.
    
    Args:
        webhook_name: The webhook path/name
        payload: Dictionary containing the data to send
    """
    if not N8N_ENABLED:
        return
    
    # Create a task that runs in the background
    try:
        loop = asyncio.get_event_loop()
        if loop.is_running():
            # If there's already an event loop running, create a task
            loop.create_task(trigger_workflow(webhook_name, payload))
        else:
            # Otherwise run it synchronously (shouldn't happen in FastAPI)
            asyncio.run(trigger_workflow(webhook_name, payload))
    except Exception as e:
        logger.error(
            f"Error creating background task for n8n workflow '{webhook_name}': {e}"
        )


# Convenience functions for specific workflows

async def trigger_welcome_email(name: str, email: str, verification_link: str) -> bool:
    """Trigger the welcome email workflow for new users."""
    return await trigger_workflow("new-user", {
        "name": name,
        "email": email,
        "verification_link": verification_link
    })


async def trigger_driver_onboarding(name: str, email: str, driver_id: str) -> bool:
    """Trigger the driver onboarding workflow for new drivers."""
    return await trigger_workflow("new-driver", {
        "name": name,
        "email": email,
        "driver_id": driver_id
    })


async def trigger_payment_failed(
    user_name: str,
    user_email: str,
    user_phone: Optional[str],
    trip_id: str,
    amount: float
) -> bool:
    """Trigger the payment failed recovery workflow."""
    return await trigger_workflow("payment-failed", {
        "user_name": user_name,
        "user_email": user_email,
        "user_phone": user_phone,
        "trip_id": trip_id,
        "amount": amount
    })


async def trigger_new_ride_notification(
    rider_id: str,
    pickup_address: str,
    dropoff_address: str,
    pickup_lat: float,
    pickup_lng: float,
    dropoff_lat: float,
    dropoff_lng: float,
    fare: float,
    vehicle_type: str = "comfort"
) -> bool:
    """Trigger new ride notification to available drivers."""
    return await trigger_workflow("new-ride", {
        "rider_id": rider_id,
        "pickup_address": pickup_address,
        "dropoff_address": dropoff_address,
        "pickup_lat": pickup_lat,
        "pickup_lng": pickup_lng,
        "dropoff_lat": dropoff_lat,
        "dropoff_lng": dropoff_lng,
        "fare": fare,
        "vehicle_type": vehicle_type
    })


# Example usage logging on module load
if __name__ == "__main__":
    logging.basicConfig(level=logging.INFO)
    logger.info(f"n8n Trigger Utility - Base URL: {N8N_BASE_URL}")
    logger.info(f"n8n Enabled: {N8N_ENABLED}")
    logger.info(f"n8n Webhook Secret Configured: {'Yes' if N8N_WEBHOOK_SECRET else 'No'}")
