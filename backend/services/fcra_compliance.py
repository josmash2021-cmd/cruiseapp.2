"""FCRA compliance helpers.

Centralizes the Fair Credit Reporting Act pieces around driver background
checks (consumer reporting agency: Checkr, Inc.):

- Delivery tracking for the CFPB "A Summary of Your Rights Under the Fair
  Credit Reporting Act" document (initial consent + pre-adverse action).
- Pre-adverse action package builder (FCRA §604(b)(3)).
- Adverse action notice builder with all FCRA §615(a) required elements.
"""

import os
from datetime import datetime, timezone

from sqlalchemy.ext.asyncio import AsyncSession

from models.database import SummaryOfRightsDelivery

# ── Consumer Reporting Agency (background check vendor) ────────────────
CRA_NAME = "Checkr, Inc."
CRA_ADDRESS = "1 Montgomery Street, Suite 2400, San Francisco, CA 94104"
CRA_PHONE = "(844) 824-3257"
CRA_TOLL_FREE_PHONE = "(844) 824-3257"

# ── CFPB "A Summary of Your Rights Under the FCRA" document ────────────
# Current corrected CFPB model form (March 2023 edition; mandatory
# compliance date 2024-03-20). Provenance, official URLs, and SHA-256
# hashes are recorded in backend/static/legal/PROVENANCE.json.
SUMMARY_OF_RIGHTS_VERSION = "2023-03"  # CFPB model form edition (Mar. 2023)
SUMMARY_OF_RIGHTS_URLS = {
    "en": "/static/legal/cfpb_summary_of_rights_en_2023-03.pdf",
    "es": "/static/legal/cfpb_summary_of_rights_es_2023-03.pdf",
}
SUMMARY_OF_RIGHTS_URL = SUMMARY_OF_RIGHTS_URLS["en"]  # backwards-compatible default
SUMMARY_OF_RIGHTS_PATHS = {
    lang: os.path.join(
        os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
        "static", "legal", url.rsplit("/", 1)[-1],
    )
    for lang, url in SUMMARY_OF_RIGHTS_URLS.items()
}
VALID_SUMMARY_LANGUAGES = set(SUMMARY_OF_RIGHTS_URLS)

VALID_DELIVERY_CHANNELS = {"initial_consent", "pre_adverse_action"}


async def record_summary_of_rights_delivery(
    db: AsyncSession, user_id: int, channel: str, language: str = "en",
) -> SummaryOfRightsDelivery:
    """Persist proof that the CFPB Summary of Rights was delivered to a user.

    channel must be "initial_consent" (delivered with the standalone
    disclosure & authorization) or "pre_adverse_action" (delivered with the
    pre-adverse action package). language is the PDF edition delivered
    ("en" or "es"); it is recorded together with the model form version so
    exactly which document each Driver received can be proven later.
    """
    if channel not in VALID_DELIVERY_CHANNELS:
        raise ValueError(
            f"Invalid Summary of Rights delivery channel: {channel!r}. "
            f"Must be one of {sorted(VALID_DELIVERY_CHANNELS)}."
        )
    if language not in VALID_SUMMARY_LANGUAGES:
        raise ValueError(
            f"Invalid Summary of Rights language: {language!r}. "
            f"Must be one of {sorted(VALID_SUMMARY_LANGUAGES)}."
        )
    row = SummaryOfRightsDelivery(
        user_id=user_id,
        channel=channel,
        document_version=SUMMARY_OF_RIGHTS_VERSION,
        language=language,
        delivered_at=datetime.now(timezone.utc),
    )
    db.add(row)
    await db.commit()
    await db.refresh(row)
    return row


def build_pre_adverse_action_package(driver_name: str, report_url_or_ref: str) -> dict:
    """Build the FCRA §604(b)(3) pre-adverse action package.

    Pure function — the caller is responsible for actually sending the
    package and for recording the Summary of Rights delivery via
    record_summary_of_rights_delivery(db, user_id, "pre_adverse_action").
    """
    return {
        "notice": (
            f"Dear {driver_name},\n\n"
            "We are writing to inform you that we may take an adverse action "
            "against your driver account (including denial, suspension, or "
            "deactivation) based in whole or in part on information contained "
            "in a consumer report (background check) we obtained about you. "
            "No final decision has been made at this time.\n\n"
            "Enclosed with this notice you will find: (1) a copy of the "
            "consumer report, and (2) the Consumer Financial Protection "
            "Bureau's document \"A Summary of Your Rights Under the Fair "
            "Credit Reporting Act\". Please review both carefully. You have "
            "the opportunity to dispute the accuracy or completeness of any "
            "information in the report before a final decision is made."
        ),
        "report_copy": report_url_or_ref,
        "summary_of_rights": {
            "urls": dict(SUMMARY_OF_RIGHTS_URLS),
            "url": SUMMARY_OF_RIGHTS_URL,
            "version": SUMMARY_OF_RIGHTS_VERSION,
        },
        "dispute_instructions": (
            f"If you believe any information in your background report is "
            f"inaccurate or incomplete, you may dispute it directly with the "
            f"consumer reporting agency: {CRA_NAME}, {CRA_ADDRESS}, phone "
            f"{CRA_PHONE}. Please also reply to this notice so we know a "
            f"dispute is pending; we will allow a reasonable time for the "
            f"dispute to be resolved before making a final decision."
        ),
    }


def build_adverse_action_notice(driver_name: str, decision_description: str) -> dict:
    """Build the FCRA §615(a) adverse action notice.

    Returns every required element as an explicit key so callers can render
    or send them individually. Pure function (no database access).
    """
    return {
        "adverse_action_notice": (
            f"Dear {driver_name},\n\n"
            f"We have taken adverse action against your driver account: "
            f"{decision_description}. This decision was based in whole or in "
            f"part on information contained in a consumer report (background "
            f"check) prepared by the consumer reporting agency identified "
            f"below."
        ),
        "cra_name": CRA_NAME,
        "cra_address": CRA_ADDRESS,
        "cra_phone": CRA_PHONE,
        "cra_toll_free_phone": CRA_TOLL_FREE_PHONE,
        "cra_did_not_decide_statement": (
            f"{CRA_NAME} supplied the consumer report but did not make the "
            f"decision to take this adverse action and cannot explain why the "
            f"decision was made. The decision was made solely by Royal "
            f"Purple LLC based on our driver eligibility standards."
        ),
        "free_report_within_60_days_notice": (
            f"Under the Fair Credit Reporting Act, you have the right to "
            f"obtain a free copy of your consumer report from {CRA_NAME} "
            f"within 60 days of receiving this notice. Contact them at "
            f"{CRA_ADDRESS}, toll-free {CRA_TOLL_FREE_PHONE}."
        ),
        "dispute_anytime_notice": (
            f"You have the right to dispute, at any time, the accuracy or "
            f"completeness of any information in your consumer report "
            f"directly with {CRA_NAME}."
        ),
    }
