import 'package:flutter/material.dart';
import 'legal_document_screen.dart';

/// Rider Terms of Service. Source of truth: docs/rider_terms_of_service.md
/// (Cruise in Ride LLC / Florida, Version 1.0) — keep both in sync.
/// Rendered with the shared neumorphic legal-document widget.
/// English-only legal content; venue is Miami-Dade County, Florida.
class TermsOfServiceScreen extends StatelessWidget {
  const TermsOfServiceScreen({super.key});

  static const _sections = <LegalSection>[
    LegalSection(
      heading: 'Introduction',
      body: r'''
These Rider Terms of Service (the "Rider Terms") are entered into by and between **Cruise in Ride LLC**, a Florida limited liability company ("**Cruise in Ride**" or the "**Company**"), and each individual who requests or takes rides through the Cruiseinride platform (the "**Rider**" or "**you**"). "**Cruiseinride**" means the transportation network company digital platform, mobile application, and brand owned and operated by Cruise in Ride LLC. All operations take place in the State of Florida, and these Rider Terms are governed exclusively by the laws of the State of Florida.''',
    ),
    LegalSection(
      heading: '1. The Platform',
      body: r'''
1.1. Cruiseinride is a technology platform that connects riders with independent drivers. **Cruise in Ride LLC does not provide transportation services.** Transportation is provided by independent contractor drivers.

1.2. The Company operates as a transportation network company under **Fla. Stat. § 627.748**.''',
    ),
    LegalSection(
      heading: '2. Account and Eligibility',
      body: r'''
2.1. You must be at least 18 years old and capable of forming a binding contract to create an account.

2.2. **Minors.** Riders must be at least 18 years old to create an account. Minors may ride only when accompanied by an adult who requested the ride or is otherwise authorized to accompany the minor. Unaccompanied minors are not permitted, and drivers may refuse or cancel a trip involving an unaccompanied minor.

2.3. You agree to provide accurate information, keep your account secure, and notify us of any unauthorized use. Accounts are personal and non-transferable.''',
    ),
    LegalSection(
      heading: '3. Using the Platform',
      body: r'''
3.1. You may request rides for yourself and guests, view the fare or fare estimate before confirming, track your driver, and pay through the app.

3.2. You agree to be ready at the pickup location and to verify the driver, vehicle, and license plate shown in the app before entering the vehicle.''',
    ),
    LegalSection(
      heading: '4. Rider Conduct',
      body: r'''
4.1. You shall treat drivers with respect, comply with law during the trip, and not: damage or soil the vehicle; smoke or vape where prohibited; use drugs or open alcohol containers; carry weapons unlawfully; harass, threaten, or discriminate against the driver or others; or ask the driver to violate traffic laws.

4.2. Violations may result in cancellation of the trip, fees where permitted, and suspension or termination of your account.''',
    ),
    LegalSection(
      heading: '5. Fares, Charges, and Payment',
      body: r'''
5.1. **Fares and fare transparency.** Before you confirm a trip, the app shows you the fare or the method by which the fare is calculated, consistent with **Fla. Stat. § 627.748(4)**. Fares are calculated from a base fare, time, distance, and demand-based pricing where applicable, plus applicable taxes, tolls, and fees. Where an exact fare cannot be quoted in advance, the app shows you an estimated fare (which may be displayed as a range) before you confirm. The final fare is calculated at trip completion and itemized in your electronic receipt under Section 7.

5.2. **Tolls.** Tolls incurred during your trip are passed through to you.

5.3. **Tips.** Tips are optional and go 100% to your driver.

5.4. **Cancellation fees.** You may cancel your trip directly in the app at any time before the trip starts. Cancellation is free of charge at any time before a driver is assigned, and during the first two (2) minutes after driver assignment. After that free window, a cancellation fee of **$5.00** applies if the driver is en route to or has arrived at the pickup location. No cancellation fee applies if the Company cancels your trip or no driver is available.

5.5. **Wait time and no-show fees.** A free waiting period applies at pickup, after which a per-minute wait fee accrues, as displayed live in the app: Standard and Compact — 2 free minutes, then $0.40 per minute; Premium — 3 free minutes, then $0.60 per minute; Black and SUV XL — 5 free minutes, then $1.00 per minute; trips booked through the airport flow (to or from the airport) — 10 free minutes, then $0.40 per minute. Partial minutes round up. Accrued wait fees are added to your trip fare. If you do not appear within the applicable waiting period, the trip may be canceled as a no-show and the wait fees accrued up to cancellation apply.

5.6. **Cleaning and damage fees.** The Company does not currently charge cleaning or damage fees. If such fees are introduced in the future, Riders will receive notice and, where required, an opportunity to accept updated Terms.

5.7. **Payment authorization.** By adding a payment method you authorize the Company to charge it, through its payment processors, for fares, fees, tolls, and adjustments, including placing and later capturing pre-authorization holds. Adjustments (errors, fraud, refunds, chargebacks) are made only as permitted by law and are shown in your receipt.''',
    ),
    LegalSection(
      heading: '6. Trip Identification',
      body: r'''
6.1. Before your driver arrives, the app displays the driver's photograph and first name, and the vehicle's make, model, and license plate number, consistent with **Fla. Stat. § 627.748(5)**. Do not enter a vehicle that does not match the driver and vehicle information shown in the app.''',
    ),
    LegalSection(
      heading: '7. Electronic Receipt',
      body: r'''
7.1. After each trip, an electronic receipt is made available to you in the app (and sent by email for guest web bookings), consistent with **Fla. Stat. § 627.748(6)**. The receipt states: the origin and destination of the trip; the total time and total distance traveled; the total fare paid, with an itemization of applicable charges; and the driver's first name.''',
    ),
    LegalSection(
      heading: '8. Cancellations and Changes',
      body: r'''
8.1. You may cancel your trip directly in the app at any time before the trip starts. Cancellation is free of charge before a driver is assigned and during the free window after assignment; a cancellation fee may apply after that window under Section 5.4. Accrued wait fees may apply under Section 5.5.

8.2. If no driver is available, your trip may be canceled without charge and any hold released.''',
    ),
    LegalSection(
      heading: '9. Safety and Zero Tolerance',
      body: r'''
9.1. The Company maintains a zero-tolerance policy for driver impairment consistent with **Fla. Stat. § 627.748(10)**. If you reasonably believe your driver is impaired, end the trip when safe, call 911 if needed, and report it in the app; the driver will be suspended as soon as practicable while the complaint is investigated, as required by law.

9.2. In an emergency, always call 911 first.''',
    ),
    LegalSection(
      heading: '10. Nondiscrimination, Accessibility, and Service Animals',
      body: r'''
10.1. The Company does not discriminate against riders on the basis of race, color, religion, sex, pregnancy, national origin, age, disability, marital status, or any other legally protected characteristic in providing access to the Platform.

10.2. Drivers are prohibited from discriminating against riders on the basis of any legally protected characteristic, consistent with **Fla. Stat. § 627.748(14)**.

10.3. Drivers must transport service animals and may not charge additional fees for service animals or legally required accommodations. Report any violation in the app and we will review it.''',
    ),
    LegalSection(
      heading: '11. Minors, Child Safety Seats, and Pets',
      body: r'''
11.1. **Unaccompanied minors.** You must be at least 18 years old to hold an account (Section 2.1). Persons under 18 may ride only when accompanied by an adult. Drivers may decline or cancel a trip involving an unaccompanied minor.

11.2. **Child safety seats.** Riders are responsible for providing and installing any child restraint system required by Florida law for children riding with them. Drivers may decline a trip if a required child restraint system is not provided.

11.3. **Pets.** Pets other than service animals may be transported only when you select the pet-friendly ride option, where that option is available in the app.

11.4. **Service animals.** Service animals are always permitted, at no additional charge, under Section 10.3.''',
    ),
    LegalSection(
      heading: '12. Ratings',
      body: r'''
12.1. After each trip you may rate your driver, and drivers may rate you. Your average rider rating may be shown to drivers. Ratings help maintain a safe, respectful community.

12.2. The Company does not currently impose automatic warnings, suspensions, or terminations based solely on a numerical rider-rating threshold. Ratings may be considered together with conduct reports in reviews under Section 13, and any account action is subject to the notice and internal-review process in that Section. If numerical rider-rating thresholds are introduced, these Rider Terms will be updated to state the threshold, notice, suspension, and appeal process before they take effect.''',
    ),
    LegalSection(
      heading: '13. Suspension and Termination',
      body: r'''
13.1. The Company may suspend or terminate your account for: fraud, payment abuse or chargeback abuse, violations of rider conduct rules, safety incidents, unlawful use of the Platform, or as required by law.

13.2. Where practicable, the Company will state the reason. You may request an internal review by contacting **support@cruiseinride.com**.

13.3. You may stop using the Platform and delete your account at any time, subject to legal record-retention obligations.''',
    ),
    LegalSection(
      heading: '14. Lost Items',
      body: r'''
14.1. The Company is not responsible for items left in vehicles, but we will reasonably assist you in contacting the driver so that you and the driver can coordinate the return directly. The Company does not charge a lost-item or return fee, and no fee for the return of an item may be charged through the Platform.''',
    ),
    LegalSection(
      heading: '15. Privacy',
      body: r'''
15.1. Our Privacy Policy governs the collection and use of your personal information, including geolocation, device and log data, and trip records.

15.2. Drivers receive only the information needed to complete your trip and are prohibited from using your personal information for any purpose unrelated to completing the trip.''',
    ),
    LegalSection(
      heading: '16. Disclaimers',
      body: r'''
16.1. THE PLATFORM IS PROVIDED "AS IS" AND "AS AVAILABLE." TO THE MAXIMUM EXTENT PERMITTED BY LAW, THE COMPANY DISCLAIMS ALL WARRANTIES, EXPRESS OR IMPLIED, INCLUDING MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE, AND NON-INFRINGEMENT, AND DOES NOT WARRANT AVAILABILITY, RELIABILITY, OR THAT A DRIVER WILL ALWAYS BE AVAILABLE.

16.2. Transportation is provided by independent drivers. The Company is not responsible for the acts or omissions of drivers, except as provided by non-waivable law and the insurance described in **Fla. Stat. § 627.748(7)–(8)**.''',
    ),
    LegalSection(
      heading: '17. Limitation of Liability',
      body: r'''
17.1. TO THE MAXIMUM EXTENT PERMITTED BY LAW, THE COMPANY SHALL NOT BE LIABLE FOR INDIRECT, INCIDENTAL, SPECIAL, CONSEQUENTIAL, OR PUNITIVE DAMAGES.

17.2. SUBJECT TO SECTION 17.3, THE COMPANY'S AGGREGATE LIABILITY ARISING OUT OF OR RELATING TO THESE RIDER TERMS SHALL NOT EXCEED THE GREATER OF (i) THE AMOUNTS YOU PAID THROUGH THE PLATFORM IN THE THREE MONTHS BEFORE THE EVENT GIVING RISE TO THE CLAIM, OR (ii) ONE HUNDRED DOLLARS ($100).

17.3. EXCLUSIONS. NOTHING IN THIS SECTION EXCLUDES OR LIMITS LIABILITY FOR: (a) DEATH OR PERSONAL INJURY; (b) DAMAGE TO PROPERTY; (c) GROSS NEGLIGENCE OR WILLFUL MISCONDUCT; (d) FRAUD; (e) LIABILITY THAT CANNOT LAWFULLY BE LIMITED OR WAIVED; OR (f) THE COMPANY'S INSURANCE OBLIGATIONS UNDER FLA. STAT. § 627.748.''',
    ),
    LegalSection(
      heading: '18. Indemnification',
      body: r'''
18.1. To the extent permitted by law, you agree to indemnify, defend, and hold harmless the Company from third-party claims, damages, losses, and expenses (including reasonable attorneys' fees) to the extent caused by: (a) your fraud; (b) your violation of applicable law; (c) your negligence or willful misconduct; (d) damage to a vehicle beyond normal wear caused by you or your guests; or (e) use of the Platform through your account by an unauthorized person as a result of your failure to keep your account credentials secure. This Section does not apply to claims arising from the Company's own negligence, willful misconduct, or breach of these Rider Terms.''',
    ),
    LegalSection(
      heading: '19. Dispute Resolution',
      body: r'''
19.1. The parties shall first attempt in good faith to resolve any dispute informally by notice under Section 21.

19.2. **Binding individual arbitration.** Except as provided in Sections 19.5 through 19.8, any dispute, claim, or controversy arising out of or relating to these Rider Terms or the Platform that is not resolved informally shall be resolved by **final and binding individual arbitration** administered by the American Arbitration Association ("**AAA**") under its Consumer Arbitration Rules. The arbitration shall be seated in **Miami-Dade County, Florida**, shall be conducted in English before a single arbitrator, and may be conducted remotely by videoconference where the AAA rules permit. These Rider Terms are governed by the laws of the State of Florida, and the arbitrator shall apply Florida law. Judgment on the award may be entered in any court of competent jurisdiction.

19.3. **CLASS ACTION WAIVER.** YOU AND THE COMPANY AGREE THAT EACH MAY BRING CLAIMS AGAINST THE OTHER **ONLY IN AN INDIVIDUAL CAPACITY** AND NOT AS A PLAINTIFF OR CLASS MEMBER IN ANY PURPORTED CLASS, COLLECTIVE, CONSOLIDATED, OR REPRESENTATIVE ACTION, AND NOT IN ANY PRIVATE ATTORNEY GENERAL ACTION. THE ARBITRATOR MAY NOT CONSOLIDATE THE CLAIMS OF MORE THAN ONE PERSON.

19.4. **JURY TRIAL WAIVER.** TO THE EXTENT ANY CLAIM PROCEEDS IN COURT RATHER THAN ARBITRATION, YOU AND THE COMPANY EACH **WAIVE ANY RIGHT TO A TRIAL BY JURY**.

19.5. **Small-claims carve-out.** Either party may bring an individual claim in the small-claims court of **Miami-Dade County, Florida**, so long as the claim qualifies and remains in that court.

19.6. **30-day opt-out.** You may opt out of this arbitration agreement by emailing **support@cruiseinride.com** within **30 days** of first accepting these Rider Terms, including your name, your account email, and a clear statement that you opt out of arbitration. If you opt out, disputes shall be litigated in the state or federal courts located in **Miami-Dade County, Florida**, still on an individual basis only — the class action waiver in Section 19.3 survives opt-out to the fullest extent permitted by law.

19.7. **Intellectual property.** Either party may seek injunctive or other equitable relief in a court of competent jurisdiction for actual or threatened infringement or misappropriation of intellectual property rights.

19.8. **FCRA exclusion.** This arbitration agreement does not apply to any pre-adverse action or dispute process under the Fair Credit Reporting Act ("**FCRA**"); that administrative process remains unchanged.''',
    ),
    LegalSection(
      heading: '20. Electronic Acceptance and Communications (E-SIGN)',
      body: r'''
20.1. **Consent to electronic records.** By creating an account or tapping acceptance, you consent to enter into these Rider Terms and to receive all related records electronically — including these Rider Terms, updates to them, receipts, notices, disclosures, and other communications — under the federal Electronic Signatures in Global and National Commerce Act (E-SIGN) and the Florida Uniform Electronic Transaction Act.

20.2. **Retaining copies.** You may view these Rider Terms in the app and may download or retain a copy of them and of your electronic receipts. You may also request a paper copy of any electronic record by contacting **support@cruiseinride.com**.

20.3. **Withdrawing consent.** You may withdraw your consent to receive records electronically at any time by contacting **support@cruiseinride.com**. Because the Platform operates through electronic communications, withdrawing consent may require you to close your account and stop using the Platform. Withdrawal does not affect the legal validity of records provided electronically before the withdrawal takes effect.

20.4. **Keeping your contact information current.** You agree to keep the email address and phone number associated with your account current. You may update them in your account profile in the app.

20.5. **Hardware and software requirements.** To receive and retain electronic records you need: a mobile device running a supported version of iOS or Android with internet access, or a current web browser for web bookings; an active email address or phone number; and sufficient storage to save records or the ability to print them.

20.6. **Record of acceptance.** Your acceptance is recorded with the document version, UTC timestamp, IP address, user agent, device information, and your account ID.''',
    ),
    LegalSection(
      heading: '21. Notices',
      body: r'''
21.1. Notices to the Company: by email to **support@cruiseinride.com**. Notices to you: the email address or phone number associated with your account, or through the app.''',
    ),
    LegalSection(
      heading: '22. Updates to These Terms',
      body: r'''
22.1. **Minor changes.** We may make minor or non-material changes (such as clarifications, formatting, or corrections that do not reduce your rights) with notice through the app or by email. Continued use of the Platform after the effective date of a minor change constitutes acceptance.

22.2. **Material changes.** Material changes to these Rider Terms require your affirmative acceptance (for example, tapping to accept in the app) before they apply to you. If you do not accept a material change, you must stop using the Platform and may close your account.

22.3. **No retroactive effect.** No update applies retroactively to trips completed, or to disputes arising, before the effective date of the update.''',
    ),
    LegalSection(
      heading: '23. General',
      body: r'''
23.1. **Entire agreement.** These Rider Terms, together with the Privacy Policy, are the entire agreement between you and the Company regarding use of the Platform as a rider.

23.2. **Severability; waiver.** If any provision is held unenforceable, the remainder stays in effect. No failure to enforce is a waiver.

23.3. **Assignment.** You may not assign these Rider Terms. The Company may assign them to an affiliate or in connection with a merger or sale, with notice.

23.4. **Governing law.** These Rider Terms are governed exclusively by the laws of the **State of Florida**, without regard to conflict-of-laws principles.

23.5. **Survival.** Provisions that by their nature should survive — including payments owed, disclaimers, limitation of liability, indemnification, dispute resolution, and governing law — survive termination.''',
    ),
  ];

  @override
  Widget build(BuildContext context) {
    return const LegalDocumentScreen(
      title: 'Terms of Service',
      effectiveDate: 'Version 1.0 — Effective Date: August 8, 2026',
      sections: _sections,
    );
  }
}
