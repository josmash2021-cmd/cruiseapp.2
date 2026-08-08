import 'package:flutter/material.dart';
import 'legal_document_screen.dart';

/// Privacy Policy. Source of truth: docs/privacy_policy.md
/// (Royal Purple LLC / Florida, Version 2.0) — keep both in sync.
/// Rendered with the shared neumorphic legal-document widget.
/// English-only legal content; bracketed placeholders are kept verbatim.
class PrivacyPolicyScreen extends StatelessWidget {
  const PrivacyPolicyScreen({super.key});

  static const _sections = <LegalSection>[
    LegalSection(
      heading: 'Introduction',
      body: r'''
This Privacy Policy (the "Policy") explains how **Royal Purple LLC**, a Florida limited liability company, with its principal place of business at **[COMPANY ADDRESS]** ("**Royal Purple**", "**we**", "**us**", or the "**Company**"), collects, uses, shares, and protects personal information in connection with the **Cruiseinride** platform, application, and brand that the Company owns and operates (the "Platform").

The Company operates as a transportation network company under Florida TNC law (**Fla. Stat. § 627.748**). Prearranged rides offered through the Platform are provided only in the State of Florida. Personal information may be processed and stored in the United States by the Company and by the service providers identified in this Policy.

This Policy applies to riders, drivers, and visitors of the Platform (together, "Users" or "you").''',
    ),
    LegalSection(
      heading: '1. Information We Collect',
      body: r'''
**1.1. Information you provide**

- **Account information:** name, phone number, email address, password, and profile photo.
- **Driver documents:** driver's license, vehicle registration, proof of insurance, vehicle inspection records, and vehicle details (make, model, year, color, plate).
- **Identity verification:** government ID images, selfies, and liveness verification results (for drivers, also a short verification video), as described in Section 10.
- **Tax information:** IRS Form W-9 data (including Social Security number or other taxpayer identification number) required to pay drivers and to meet tax reporting obligations.
- **Payment information:** payment method tokens and identifiers (for riders) and payout account identifiers (for drivers). Card numbers and bank account details are collected and held by our payment processor; we do not store full card numbers or full bank account numbers — only the bank name and last four digits, for display.
- **Communications:** messages you send through the Platform (including in-app chat), calls and messages with support, and feedback or ratings you submit.

**1.2. Information collected automatically**

- **Geolocation:** precise (GPS) location, as described in Section 3.
- **Device and log data:** IP address, user agent, device model and identifiers, operating system, app version, language, crash logs, and usage events (screens, taps, errors).
- **Trip data:** pickup and dropoff locations, route, times, fare, payment status, ratings, and trip communications.

**1.3. Information from third parties**

- **Background check results** from our background check vendor, **Checkr, Inc.**, including criminal history and driving records, as described in the Background Check Disclosure and Authorization.
- **Payment and payout confirmations** from our payment processor(s).
- **Insurance and accident information** from insurers and claims processes.''',
    ),
    LegalSection(
      heading: '2. How We Use Information',
      body: r'''
We use personal information, including the information from third parties described in Section 1.3, to:

- operate the Platform (matching, routing, pricing, dispatch, receipts);
- verify identity and eligibility, and run background checks;
- process payments, ACH payouts, and instant payouts;
- administer insurance coverage and handle accident and claims processes;
- ensure safety, prevent fraud, and enforce our terms;
- provide support and communicate with you;
- comply with legal and regulatory obligations, including the record-keeping required by Florida TNC law (**Fla. Stat. § 627.748(15)**); and
- improve and debug the Platform (in aggregated or de-identified form where practicable).''',
    ),
    LegalSection(
      heading: '3. Geolocation',
      body: r'''
The Platform collects **precise (GPS) location**, not approximate location.

**Foreground and background collection.** Location collection works differently for drivers and riders:

- **Drivers:** Driver location is collected while the Driver is online and during trips — including, on Android, when the app is in the background or the screen is off — so the Platform can dispatch trips, show trip progress to riders, and support safety features. Background collection runs only while the Driver remains online; it stops when the Driver goes offline in the app. On iOS, Driver location is currently collected while the app is in use.
- **Riders:** Rider location is collected while the app is in use (foreground) to suggest pickups, match the rider with drivers, and — during a trip — share trip progress with the driver and support safety features. We do not collect Rider location in the background when the app is not in use.

**Your controls.** You can disable or limit location permission at any time in your device settings (on iOS you can choose "While Using the App"; on Android, "Allow only while using the app"). If you disable location, the Platform cannot provide trips: Drivers cannot go online, and Riders cannot be matched or tracked during a trip.''',
    ),
    LegalSection(
      heading: '4. Communications',
      body: r'''
We send different categories of messages:

- **Service messages:** trip updates (driver assigned, driver on the way, driver arrived, trip started, trip completed, trip canceled) by push notification, SMS, or email.
- **Verification codes:** one-time passcodes for login and account verification, by SMS or email.
- **Receipts:** an electronic receipt after each trip, as required by **Fla. Stat. § 627.748(6)**.
- **Safety alerts:** notifications about safety features, incidents, or account security.
- **Marketing:** product news and promotional messages, only where permitted.

**Opt-out.** You may opt out of promotional SMS and email at any time through the app settings, the unsubscribe link in the message, or by replying STOP where supported. Opting out of marketing does not affect operational messages (service messages, verification codes, receipts, and safety alerts), which we send as needed to provide the Platform. Message and data rates from your mobile carrier may apply to SMS.''',
    ),
    LegalSection(
      heading: '5. Calls and Messages',
      body: r'''
- **Rider–Driver phone calls** are placed through your device's native dialer, so your phone number may be visible to the other party. We do not monitor or record these calls.
- **Support phone line.** Our support phone line is answered by an automated voice system. Calls are not recorded; spoken responses may be transcribed so we can operate the support service, and transcripts may be logged.
- **In-app messages** between riders and drivers, and with support, are retained in our systems and may be reviewed and used for safety, customer support, fraud prevention, and the resolution of disputes, as permitted by law.''',
    ),
    LegalSection(
      heading: '6. How We Share Information',
      body: r'''
We share personal information only as follows:

- **Between riders and drivers:** first name, photo, vehicle details, and trip-relevant contact and location information, limited to what is needed to complete the trip. Phone numbers may be visible when you call each other through your device's native dialer (see Section 5).
- **Payment processors:** **Stripe** (card payments, ACH bank payments, and driver payouts, including instant payouts) and **PayPal**, to process charges and payouts.
- **Background check vendor:** **Checkr, Inc.**, to perform the screening described in the Background Check Disclosure and Authorization.
- **Insurers and claims administrators:** to administer coverage and handle accidents and claims.
- **Service providers** that process personal information on our behalf, under contractual obligations, by category:
  - cloud hosting and database: **Railway** and **Supabase**;
  - mapping and location services: **Mapbox** and **Google Maps Platform**;
  - push notifications: **Firebase Cloud Messaging (Google)**;
  - analytics: **Firebase Analytics (Google)**;
  - crash reporting: **Firebase Crashlytics (Google)**;
  - file and document storage: **Google Firebase / Google Cloud**;
  - SMS delivery: **Twilio** (including masked/proxied calls and messages);
  - email delivery: **EmailJS**, with direct SMTP as a fallback;
  - automated customer support processing: **OpenAI** — support chat content and related trip context are processed through OpenAI's API to generate support responses; under OpenAI's API data usage terms, API inputs are not used to train its models.
- **Authorities:** when required by law, regulation, subpoena, court order, or to protect rights, safety, and property, including disclosures to regulators under Florida TNC law.
- **Corporate transactions:** in connection with a merger, reorganization, or sale of substantially all assets, with notice where required.

We do not sell personal information. We do not share personal information with third parties for their own targeted advertising.''',
    ),
    LegalSection(
      heading: '7. Cookies and Similar Technologies',
      body: r'''
Our web booking pages and app use cookies, SDK identifiers, and similar technologies for authentication, analytics (Firebase Analytics), and crash reporting (Crashlytics). We do not use advertising cookies or sell data collected through them. You can control cookies through your browser settings; disabling them may prevent web bookings.''',
    ),
    LegalSection(
      heading: '8. Driver Obligations Regarding Rider Data',
      body: r'''
Drivers may access and use rider personal information solely to complete the trip and as otherwise permitted by law, and may not retain, sell, disclose, or use rider personal information for any purpose unrelated to completing the trip.''',
    ),
    LegalSection(
      heading: '9. Sensitive Information',
      body: r'''
Certain information we collect is sensitive, including:

- Social Security number or other taxpayer ID (Form W-9 data);
- driver's license and other government ID images;
- bank account details (collected and held by our payment processor);
- background check results; and
- precise geolocation.

We use this information only for the purposes that require it: processing payments and payouts, tax reporting, identity and eligibility verification, safety and fraud prevention, and compliance with law. We do not use sensitive information for marketing.''',
    ),
    LegalSection(
      heading: '10. Identity Verification',
      body: r'''
To keep the Platform safe, we verify the identity of Users:

- **What we collect:** images of your government ID (for example, a driver's license, state ID, or passport), a selfie, and a liveness check; drivers also record a short verification video.
- **Liveness verification** runs on your device (using on-device face detection) and asks you to perform simple movements to confirm that a live person — not a photo or recording — is completing the check.
- **No facial recognition.** We do not perform face matching or facial recognition, and we do not create or store biometric templates or face prints. The images and video you provide are stored as verification documents and reviewed to confirm your identity and eligibility.
- **Who performs verification:** identity verification is performed in-house; we do not use a third-party identity verification vendor.
- **Use, retention, and deletion:** verification materials are used only to verify identity and eligibility, prevent fraud, and comply with law. They are retained for the periods described in Section 11 and deleted when no longer needed, subject to legal retention obligations; you may request deletion as described in Section 13.''',
    ),
    LegalSection(
      heading: '11. Retention',
      body: r'''
- **Trip records:** we retain individual ride (trip) records for at least one year after each ride is provided, as required by **Fla. Stat. § 627.748(15)(a)**.
- **Driver records:** we retain individual driver records for at least one year after the driver's relationship with the Company ends, as required by **Fla. Stat. § 627.748(15)(b)**.
- **Chat and support transcripts:** in-app trip chat messages and customer support transcripts (including AI support conversations) are retained for up to two (2) years and then deleted or anonymized, unless a longer period is required by a legal hold, an open safety investigation or dispute, or tax, accounting, or legal compliance obligations.
- **Identity verification materials:** government ID images, selfies, and verification videos are retained while the account is active and deleted within 90 days after account closure or a failed verification, unless a longer period is required by law, an open investigation, or a dispute.
- **Other information** may be retained for longer periods where needed for tax, accounting, insurance, safety, fraud prevention, dispute resolution, or legal compliance.

These statutory minimums are a floor, not our full retention schedule. Beyond them, we retain personal information only for the periods needed for the purposes described in this Policy. We do not automatically delete all personal information on any fixed anniversary; deletion requests are honored subject to the retention obligations described in this Section.''',
    ),
    LegalSection(
      heading: '12. Security',
      body: r'''
We use administrative, technical, and physical safeguards designed to protect personal information, including: encryption in transit (TLS); application-layer encryption of Social Security numbers and taxpayer IDs at rest; password hashing; one-time passcode verification at login; role-based access controls; security audit logging; and rate limiting against abusive traffic.

No system is perfectly secure. If we become aware of a breach affecting your personal information, we will notify you and the authorities as required by law.''',
    ),
    LegalSection(
      heading: '13. Your Rights and Choices',
      body: r'''
Subject to applicable law, you may:

- access and correct your account information in the app;
- request a copy of your personal information;
- request deletion of your account and personal information, subject to the retention obligations described in Section 11;
- control push, SMS, and email preferences in the app settings; and
- control location and other device permissions in your device settings.

To exercise these rights, contact **[PRIVACY EMAIL]**. To protect your account, we may need to verify your identity (for example, through the contact information registered to your account) before fulfilling a request. We respond to requests within the time required by applicable law.''',
    ),
    LegalSection(
      heading: '14. Children',
      body: r'''
The Platform is not directed to children under 18. Riders must be at least 18 years old to create an account. Minors may ride only when accompanied by an adult who requested the ride or is otherwise authorized to accompany the minor; unaccompanied minors are not permitted (see the Rider Terms of Service). We do not knowingly collect personal information directly from minors; trip information about an accompanied minor is collected only as part of the accompanying adult's trip record. If we become aware that a person under 18 has provided us personal information outside these circumstances, we will delete it.''',
    ),
    LegalSection(
      heading: '15. Changes to This Policy',
      body: r'''
We may update this Policy. Minor changes take effect when the updated version is posted in the app with a new effective date. For material changes, we will provide prominent advance notice in the app or by email and, where required by law, obtain your consent. Changes apply going forward; we will not apply changes retroactively except as permitted by law.''',
    ),
    LegalSection(
      heading: '16. Contact',
      body: r'''
Privacy questions and requests: **[PRIVACY EMAIL]** or **[COMPANY ADDRESS]**.''',
    ),
  ];

  @override
  Widget build(BuildContext context) {
    return const LegalDocumentScreen(
      title: 'Privacy Policy',
      effectiveDate: 'Version 2.0 — Effective Date: [EFFECTIVE DATE]',
      sections: _sections,
    );
  }
}
