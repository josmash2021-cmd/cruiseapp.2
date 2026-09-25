# FCRA Screening Process — Adverse Action, Disputes, and Driver Rights

**Version 1.0 — PRODUCTION CANDIDATE — Effective Date: August 8, 2026**

> **PRODUCTION CANDIDATE — NOT FOR PUBLICATION until the blockers listed in
> the Appendix are resolved.** This document is separate from the standalone
> `background_check_disclosure_authorization.md`. It describes the screening
> process the Company follows under the Fair Credit Reporting Act ("FCRA"),
> 15 U.S.C. § 1681 et seq., and Fla. Stat. § 627.748(12). It is not part of
> the standalone disclosure and authorization.

## 1. Scope

This process applies to consumer reports obtained by **Cruise in Ride, Inc.**
(the "**Company**") in connection with an application to drive, and continued
engagement as an independent contractor Driver, on the **Cruiseinride**
platform.

The consumer reporting agency used by the Company is:

- **Vendor:** Checkr
- **Consumer reporting agency ("CRA"):** Checkr, Inc.
- **Address:** 1 Montgomery Street, Suite 2400, San Francisco, CA 94104
- **Telephone (toll-free):** (844) 824-3257

## 2. Summary of Rights Process

The CFPB document **"A Summary of Your Rights Under the Fair Credit
Reporting Act"** is delivered to you at **two points** in the process:

1. **At initial electronic consent.** It is presented together with the
   standalone Background Check Disclosure and Authorization when you grant
   consent in the App, before any report is obtained.
2. **With every pre-adverse action notice.** It is attached to each
   pre-adverse action notice described in Section 3, together with a copy of
   your report.

It is also available at any time from the CRA and from the Consumer Financial
Protection Bureau (consumerfinance.gov).

**Every delivery is recorded**: the Company logs the date and time (UTC) of
each delivery, the delivery channel (in-app at consent, or attached to a
pre-adverse action notice), and the version of the document delivered.

> **Operational requirement:** the consent flow must present the current
> CFPB Summary of Rights at initial consent, and the pre-adverse action
> workflow must attach the current CFPB Summary of Rights PDF and a copy of
> the report. Both deliveries must be logged as described above.

## 3. Pre-Adverse Action Notice

If the Company intends to deny your application, suspend, or deactivate your
account based in whole or in part on information in a consumer report, the
Company will, **before** the decision becomes final, send you a pre-adverse
action notice that includes:

1. the **pre-adverse action notice** itself;
2. a **copy of the consumer report**; and
3. the CFPB **"A Summary of Your Rights Under the Fair Credit Reporting
   Act"**.

You will then have a **reasonable opportunity to dispute** the accuracy or
completeness of the report directly with the CRA before any final decision
is made. The Company waits at least five (5) business days after sending
the pre-adverse action notice before any final decision, or longer where
state or local law requires it.

## 4. Adverse Action Notice

If, after the process in Section 3, the Company proceeds with the decision,
the Company will send you a final **adverse action notice** that includes:

1. notice of the adverse action;
2. the name, address, and telephone number of the CRA that provided the
   report — **Checkr, Inc., 1 Montgomery Street, Suite 2400, San Francisco,
   CA 94104, telephone (toll-free): (844) 824-3257**;
3. a statement that **the CRA did not make the decision** and cannot explain
   why it was made;
4. notice of your right to **request a free additional copy of your report
   from the CRA within 60 days** after the adverse action; and
5. notice of your right to **dispute inaccurate or incomplete information
   with the CRA at any time** under the FCRA.

## 5. Disputes

You have the **right to dispute** inaccurate or incomplete information in a
report at any time, directly with the CRA that prepared it, using the contact
information in Section 1. The CRA is required by law to investigate and
correct or delete inaccurate, incomplete, or unverifiable information.

## 6. Questions

Questions about the screening process, requests for a copy of your report,
or questions about a notice you received may be sent to
**support@cruiseinride.com**.

## 7. Refusing or Withdrawing Authorization

Background screening is a **legal eligibility requirement** for Drivers under
Fla. Stat. § 627.748(12): the Company may not authorize any person to drive
on the platform unless the required background screening has been completed.

Accordingly:

- if you **decline** to authorize the background screening, your application
  cannot proceed, because the Company cannot establish your legal
  eligibility to drive; and
- if you **withdraw** a previously given authorization, the Company cannot
  perform the screening the law requires, and your account cannot remain
  active as a Driver until a valid authorization and a completed screening
  are again in place.

This is a consequence of a legal eligibility requirement, not a penalty. You
may contact **support@cruiseinride.com** with questions before deciding.

---

## Appendix — Open Blockers (must be resolved before publication)

1. **Vendor confirmation — RESOLVED.** The vendor is confirmed as **Checkr,
   Inc.**, 1 Montgomery Street, Suite 2400, San Francisco, CA 94104, tel.
   (844) 824-3257 (code integration: `backend/services/checkr_service.py`,
   package slug `driver_pro`; vendor data verified against Checkr's official
   legal notices and standard candidate disclosure language). The exact
   screening package contents remain subject to blocker 2.
2. **Screening package confirmation.** Package contents are account-specific
   and must be confirmed via `GET /v1/packages` with the account API key or
   the Checkr Dashboard. Checkr's standard "Driver Pro" package typically
   includes SSN trace, sex offender search, global watchlist search,
   national criminal search, county criminal searches, and a motor vehicle
   report — but the report categories in the standalone document remain
   limited to what is confirmed. Watchlist/sanctions searches are
   **excluded** from the documents until confirmed as actually included in
   the account's package.
3. **Summary of Rights delivery — IMPLEMENTED.** The current corrected CFPB
   model form (**March 2023 edition**, mandatory compliance date 2024-03-20)
   is served in English and Spanish at
   `/static/legal/cfpb_summary_of_rights_en_2023-03.pdf` and
   `/static/legal/cfpb_summary_of_rights_es_2023-03.pdf`; official source
   URLs, publication date, SHA-256 hashes, and download date are recorded in
   `backend/static/legal/PROVENANCE.json`. It is delivered (a)
   at initial electronic consent, from the in-app consent screen, and (b)
   attached to every pre-adverse action package built by
   `backend/services/fcra_compliance.py`. Every delivery is recorded in the
   `summary_rights_deliveries` table with channel, document version, and UTC
   timestamp.
4. **Contact email — RESOLVED.** The background-check contact is
   **support@cruiseinride.com**, the Company's monitored support mailbox
   (`backend/services/email_service.py`).
5. **Separate acceptance flow — IMPLEMENTED.** The in-app consent screen
   (`lib/screens/driver/background_check_consent_screen.dart`) uses a
   dedicated checkbox for the Background Check Disclosure and Authorization
   only, lets the Driver view/download the document and the Summary of
   Rights before accepting, and records acceptance via `POST /auth/consent`
   with `consent_type = background_check_disclosure` (separate from Terms
   and ICA acceptance), document ID, version, content hash, UTC timestamp,
   IP address, user agent, device information, and account ID
   (`ConsentLog`, `backend/models/database.py`). Acceptance history is
   queryable in-app via `GET /auth/consent/history`. **Pending:** run the
   migration `backend/migrations/add_fcra_consent_fields.py` against the
   production database before launch.
6. **Entity and jurisdiction alignment — RESOLVED.** All production-candidate
   legal documents (Rider Terms of Service, Driver Terms of Service,
   Independent Contractor Agreement, Privacy Policy, Insurance Disclosure,
   this document, and the standalone Disclosure and Authorization) identify
   **Cruise in Ride, Inc. (Florida)** under Fla. Stat. § 627.748, and the in-app
   legal screens (Terms of Service, Privacy Policy, Driver Agreement) render
   those same Florida documents. The legacy Alabama document has been
   archived at `docs/archive/terms_of_service_alabama_legacy.md` and is no
   longer in use. The Driver Terms of Service are displayed in-app at
   `lib/screens/driver/driver_terms_screen.dart` (linked from the driver
   menu), with a dedicated acceptance checkbox logged separately as
   `driver_terms_of_service` in `ConsentLog`.
7. **Florida counsel review.** All documents remain PRODUCTION CANDIDATE
   until reviewed and approved by Florida-licensed counsel.
