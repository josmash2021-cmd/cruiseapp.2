import 'package:flutter/material.dart';
import 'legal_document_screen.dart';

/// Full Privacy Policy (docs/privacy_policy.md, final v2 — U.S. only),
/// rendered with the shared neumorphic legal-document widget.
/// English-only legal content.
class PrivacyPolicyScreen extends StatelessWidget {
  const PrivacyPolicyScreen({super.key});

  static const _sections = <LegalSection>[
    LegalSection(
      heading: 'Introduction',
      body: r'''
**Cruiseinride LLC, an Alabama limited liability company, with its principal place of business in Birmingham, Alabama** ("Cruiseinride," "we," "us," or "our") respects your privacy. This Privacy Policy explains what information we collect through the Cruiseinride mobile application and **cruiseinride.com** (the "Service"), how we use it, who we share it with, how we protect it, and the rights you have over your personal information.

The Service is offered in the **United States only** (see Section 11). By using the Service, you acknowledge the practices described in this Policy. If you do not agree, please do not use the Service.''',
    ),
    LegalSection(
      heading: '1. Information We Collect',
      body: r'''
**1.1 Information you provide directly**

- **Account data:** name, email address, phone number, profile photo, password (stored only as an industry-standard hash — never in plain text).
- **Identity verification data:** government-issued ID (driver's license), photos of documents, and liveness selfies, used to verify identity and eligibility.
- **Driver data (drivers only):** vehicle information (make, model, year, color, plate), insurance documents, banking/payout details, and Social Security Number (stored encrypted, used only for background checks and tax reporting).
- **Payment data:** payment method details. Card numbers are processed and stored by **Stripe, Inc.** — Cruiseinride never stores complete card numbers.
- **Location data:** real-time GPS coordinates (with your permission), pickup and dropoff addresses, saved places (home, work, favorites).
- **Communications:** rider-driver chat messages, support conversations, ratings, and feedback.
- **Referral and promotional data:** referral codes, promotional credit balances.

**1.2 Information collected automatically**

- **Trip data:** routes, distance, duration, fares, timestamps.
- **Device data:** model, operating system, app version, device identifiers, IP address, crash logs.
- **Usage data:** features used, screens visited, interaction events (only if you have not opted out — see Section 8).
- **Support interactions:** messages sent to our AI support assistant and human agents.

**1.3 Information from third parties**

- **Background check results** from Checkr, Inc. (drivers only): pass/fail status and report summaries.
- **Authentication data** from Google or Apple sign-in: name, email, and profile identifier.''',
    ),
    LegalSection(
      heading: '2. Biometric Information Policy (Facial Verification)',
      body: r'''
2.1 **What we collect.** During identity verification, the App captures a selfie video or photo sequence to perform **facial liveness detection** — confirming that a live human, matching the submitted ID, is present. Processing is performed **on your device** using Google ML Kit; the liveness analysis does not leave your phone except for the pass/fail result and the verification images described in Section 2.2.

2.2 **What we retain — and what we destroy.** **Raw verification images are destroyed once the verification decision is made.** We retain only: (a) the liveness analysis **result** (pass/fail and quality signals), and (b) **non-biometric audit metadata** (timestamp, decision, and verification status) needed to complete and audit the verification. We do not store facial geometry templates, we do not perform facial recognition searches, and we do not use biometric data to identify you across services or for advertising.

2.3 **Purpose, consent, and legal basis.** Biometric verification prevents identity fraud and protects all users. We collect it **only with your informed written consent, collected in advance**: before any capture occurs, the App presents a **dedicated consent screen** explaining what is captured, why, how it is processed (on-device), and how long it is retained, and requires your **explicit opt-in confirmation** (an affirmative checkbox/accept action) — consistent with the informed-consent standard of the Illinois Biometric Information Privacy Act ("BIPA") and similar laws. **If you decline consent, we cannot complete identity verification**, which means you cannot use the Service as a Driver or as a verified Rider; declining has no other negative consequences.

2.4 **Consent records.** We keep a **record of your consent** — the exact consent text you accepted, the consent version, and the date and time of acceptance — as proof that consent was obtained, for as long as the underlying verification is retained.

2.5 **Retention and destruction of what remains.** The retained verification result and audit metadata described in Section 2.2 are kept only while your verification is valid or as required by law, and are permanently destroyed within **90 days** after your account is deleted or your verification expires, whichever comes first, unless a longer period is required by law. Raw images are already gone by then (Section 2.2).

2.6 **No sale.** We do not sell, lease, trade, or profit from biometric data in any way, and we do not disclose it except to service providers necessary to perform the verification, under confidentiality obligations, or as required by law (including BIPA and similar state laws).

2.7 **Changes.** Any **material change** to how we collect, use, or retain biometric data will require your **new consent**, collected again in advance as described in Section 2.3 — not merely a notice (see Section 14).''',
    ),
    LegalSection(
      heading: '3. Artificial Intelligence and Automated Processing',
      body: r'''
3.1 **How we use AI.** The Service uses artificial intelligence for: (a) **customer support** — an AI assistant (powered by OpenAI) that answers questions and can execute limited account-related actions with your confirmation; (b) **document processing** — OCR and validation of licenses and documents; (c) **matching and dispatch** — algorithmic assignment of riders to nearby available drivers; and (d) **platform integrity** — fraud detection, "ghost driver" detection, document expiration monitoring, and rating moderation.

3.2 **What this means for you.** Conversations with the AI assistant may be processed by OpenAI under its data processing terms, limited to the content you send. Do not share passwords, full card numbers, or sensitive personal data in chat.

3.3 **No solely automated significant decisions.** We do not make decisions with legal or similarly significant effects (account termination, dispute outcomes, background check results) solely by automated means; such decisions include human review. Where applicable law grants it, you have the right to **request human review**, to express your point of view, and to contest an AI-assisted decision via support@cruiseinride.com.

3.4 **Accuracy.** AI outputs may be imperfect and are provided for convenience, not as professional advice of any kind.

3.5 **No AI training on your data.** User content and personal data are used only to operate and improve the Service. **We do not use your content or personal data to train artificial intelligence or machine learning models without your separate, explicit consent**, with one limited exception: **safety and platform-integrity systems** (fraud detection, "ghost driver" detection, rating moderation) may use models trained on **aggregated or de-identified platform data** that cannot reasonably be linked back to you. API calls to OpenAI are made under an API configuration whose inputs are **not used to train OpenAI's models by default**.''',
    ),
    LegalSection(
      heading: '4. How We Use Your Information',
      body: r'''
We use personal information to:

- Provide, operate, and improve the Service (matching, navigation, pricing, payments).
- Verify identity and eligibility, and maintain platform safety.
- Process payments, payouts, refunds, and promotional credits.
- Communicate with you: trip updates, receipts, support, safety alerts, and (with your consent) promotions.
- Comply with legal obligations: tax reporting, background checks, law-enforcement requests.
- Detect, prevent, and investigate fraud, abuse, and security incidents.
- Analyze and improve performance (only with analytics enabled).''',
    ),
    LegalSection(
      heading: '5. How We Share Your Information',
      body: r'''
5.1 **Between users.** Riders and drivers see each other's first name, photo, rating, and (for drivers) vehicle details. During an active trip, live location is shared between the matched rider and driver only, and **riders and drivers may contact each other by phone, in which case the phone number may be visible to the other party**.

5.2 **Service providers (processors).** We share data with vendors who process it on our behalf under contract: **Stripe** (payments), **Checkr** (background checks), **Twilio** (SMS), **Google** (Maps, ML Kit, Firebase hosting, analytics, cloud messaging), **Mapbox** (maps), **OpenAI** (AI support), and cloud hosting providers.

5.3 **Legal and safety.** We may disclose information to comply with law, subpoenas, or government requests; to protect the rights, safety, and property of users, Cruiseinride, or the public; and to enforce our Terms.

5.4 **Business transfers.** In a merger, acquisition, or sale of assets, your information may be transferred, subject to this Policy.

5.5 **Background checks (FCRA).** For Drivers, background checks performed by **Checkr, Inc.** are **"consumer reports" under the Fair Credit Reporting Act ("FCRA")**. We share your identifying information with Checkr only after providing a stand-alone disclosure and obtaining your written authorization in the App. If we consider taking adverse action (including deactivation) based on a report, we follow the FCRA process described in Section 5.5 of our Terms of Service: pre-adverse action notice with a copy of your report and "A Summary of Your Rights Under the FCRA," a reasonable period to dispute, and a final adverse action notice with Checkr's contact information and your rights.

5.6 **We do not sell your personal information** and we do not share it for cross-context behavioral advertising.''',
    ),
    LegalSection(
      heading: '6. Data Retention',
      body: r'''
- **Account data:** kept while your account is active.
- **Trip and transaction records:** retained up to **7 years** for tax, accounting, and legal compliance.
- **Identity verification data:** per Section 2 (raw verification images are destroyed once the verification decision is made; the result and audit metadata are destroyed within 90 days after account deletion or verification expiry).
- **Support conversations:** up to 2 years.
- **TNC records:** driver records and trip records (including unique trip and driver identifiers) are retained for **at least 2 years** as required by the Alabama Transportation Network Company Act (Ala. Code § 32-7C) and APSC rules.
- **Deleted accounts — deletion is partial.** When you delete your account (Settings > Privacy > Delete Account), the account enters a 7-day grace period in case you change your mind, after which personal data is deleted or anonymized, **except** records we must retain by law: trip and driver records are kept for **2 years** under Alabama TNC law, and tax and transaction records for up to **7 years**, plus what is strictly necessary for disputes and fraud prevention.''',
    ),
    LegalSection(
      heading: '7. How We Protect Your Information',
      body: r'''
- **Encryption of sensitive fields at rest and in transit** (for example, SSN is stored encrypted; passwords are stored only as industry-standard hashes).
- Authentication via short-lived access tokens, plus request signing and rate limiting.
- Access controls, role-based permissions, and audit logging of administrative access.
- Secure development practices, including parameterized database access.
- Payments handled by **PCI-compliant payment processors**; background checks handled by accredited providers.

No system is perfectly secure, and we cannot guarantee absolute security. If a breach affects your personal data, we will notify you and the authorities as required by law.''',
    ),
    LegalSection(
      heading: '8. Your Privacy Rights and Choices',
      body: r'''
**8.1 In the app (Settings > Privacy), you can:**

- **Access and export** a summary of your personal data ("Download My Data").
- **Correct** your profile information (Settings > Edit Profile).
- **Delete** your account and personal data ("Delete Account").
- **Clear trip history** stored on your device.
- **Opt out of analytics** (Usage Analytics toggle) and of sharing your live location during rides (Location Sharing toggle).
- **Manage notifications** per category (Settings > Notifications).

8.2 **Universal rights.** Depending on your jurisdiction (including Alabama, California, Virginia, Colorado, Connecticut, Texas, Oregon, and Montana), you may have the right to: know/access your data, correct it, delete it, port it, restrict or object to processing, withdraw consent, and not be discriminated against for exercising these rights. Exercising them is free. Contact privacy@cruiseinride.com and we will respond within the time required by law (generally 30–45 days).

8.3 **Verifying your request and authorized agents.** Before acting on a rights request, we **verify the identity of the requester** by matching the information provided against account data we already hold. You may use an **authorized agent** to submit a request on your behalf; we will require proof of the agent's authorization (and may verify your identity directly) before acting.

8.4 **Appeals.** If we deny your rights request, you may **appeal** by replying to our decision or writing to privacy@cruiseinride.com with "Appeal" in the subject line. We will review the appeal with fresh eyes and respond within the time required by the law of your state (for example, 60 days under Virginia, Colorado, and Connecticut law, and 45 days under Texas and Oregon law).

8.5 **California residents (CCPA/CPRA).** You have the right to know the categories and specific pieces of personal information we collect, use, and disclose; to request deletion and correction; to opt out of sale or sharing (we do not sell or share for advertising); to limit use of sensitive personal information; and to non-discrimination. **Sensitive personal information we collect** is limited to: **Social Security Number** (drivers, for background checks and tax reporting), **precise geolocation** (to provide rides), **biometric data** (liveness verification — Section 2), and **government-issued identification** (identity verification). We use sensitive personal information **only for the purposes permitted by the CPRA** and **do not use it to infer characteristics** about you.

8.6 **Global Privacy Control.** Where required by law, we honor the **Global Privacy Control (GPC)** signal as a valid opt-out request for the device or browser that sends it.

8.7 **Marketing.** You can opt out of promotional emails via the unsubscribe link and of promotional notifications via Settings > Notifications. Transactional messages (receipts, trip status, security) cannot be opted out of while your account is active.''',
    ),
    LegalSection(
      heading: '9. Location Information',
      body: r'''
We collect precise location only with your device's permission. You can revoke it in your phone settings, but the Service cannot provide pickups without it. **Riders:** your live location during a trip is shared with the matched driver, and the **Location Sharing toggle** (Settings > Privacy) limits non-essential ride-time sharing. **Drivers:** because you provide the transportation, you **must keep location sharing active while online** for safety and operations, as stated in Section 5.4 of our Terms of Service; the rider toggle does not apply to driver obligations. Drivers' live location while online is shared with riders they serve and with dispatch.''',
    ),
    LegalSection(
      heading: "10. Children's Privacy",
      body: r'''
The Service is not directed to anyone under 18. We do not knowingly collect personal information from minors. If we learn that we have, we will delete it promptly. Contact privacy@cruiseinride.com if you believe a minor has provided us data.''',
    ),
    LegalSection(
      heading: '11. United States Only',
      body: r'''
The Service is offered **only in the United States**, and your data is **processed in the United States**. The Service is **not directed to residents of the European Economic Area or the United Kingdom**, and we do not knowingly offer the Service to them. If you access the Service from outside the U.S., you understand that your data will be transferred to and processed in the U.S. as described in this Policy.''',
    ),
    LegalSection(
      heading: '12. Cookies and Website Tracking (cruiseinride.com)',
      body: r'''
Our website uses only **essential cookies and storage** required for the site to function (for example, session and security preferences). We **do not use third-party advertising pixels or cross-site tracking cookies**. You can manage or delete cookies at any time through your browser settings; essential features may not work if you block them.''',
    ),
    LegalSection(
      heading: '13. Third-Party Services',
      body: r'''
Third-party providers integrated into the Service (Stripe, Google, Mapbox, Twilio, Checkr, OpenAI) have their own privacy policies governing their handling of your data. We encourage you to review them. We are not responsible for third-party practices.''',
    ),
    LegalSection(
      heading: '14. Changes to This Policy',
      body: r'''
We may update this Policy. Material changes will be announced in the App or by email at least 7 days before taking effect, with the new Effective Date posted. Continued use after that date constitutes acceptance, **except that any material change to the treatment of biometric data requires your new advance consent** (Section 2.7), not merely notice.''',
    ),
    LegalSection(
      heading: '15. Contact Us',
      body: r'''
- **Privacy inquiries:** privacy@cruiseinride.com
- **Support:** support@cruiseinride.com
- **Legal:** legal@cruiseinride.com
- **In-app:** Settings > Support

*This Privacy Policy is designed to comply with applicable U.S. federal and state privacy laws (including CCPA/CPRA, BIPA, and state comprehensive privacy laws), and Apple App Store / Google Play data-safety requirements.*''',
    ),
  ];

  @override
  Widget build(BuildContext context) {
    return const LegalDocumentScreen(
      title: 'Privacy Policy',
      effectiveDate: 'Effective Date: July 26, 2026',
      sections: _sections,
    );
  }
}
