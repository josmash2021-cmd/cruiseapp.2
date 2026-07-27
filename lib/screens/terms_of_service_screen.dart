import 'package:flutter/material.dart';
import 'legal_document_screen.dart';

/// Full Terms of Service (docs/terms_of_service.md), rendered with the
/// shared neumorphic legal-document widget. English-only legal content.
class TermsOfServiceScreen extends StatelessWidget {
  const TermsOfServiceScreen({super.key});

  static const _sections = <LegalSection>[
    LegalSection(
      heading: 'Introduction',
      body: r'''
Welcome to Cruiseinride. These Terms of Service (the "Terms" or the "Agreement") constitute a legally binding agreement between you ("you," "user," "Rider," or "Driver") and **Cruiseinride LLC, an Alabama limited liability company, with its principal place of business in Birmingham, Alabama** ("Cruiseinride," "Company," "we," "us," or "our"), operator of the Cruiseinride mobile application (the "App") and the website **cruiseinride.com** (collectively, the "Service").

**Brand note.** "Cruiseinride" is our legal and commercial brand and is used throughout this document. "Cruise" may be used informally as a short name for the App only; the standalone mark "Cruise" belongs to General Motors and is not our brand. All official correspondence uses addresses at **@cruiseinride.com**.

**PLEASE READ THESE TERMS CAREFULLY. THEY CONTAIN A BINDING ARBITRATION CLAUSE, A CLASS ACTION WAIVER, AND A JURY TRIAL WAIVER (SECTION 18) THAT AFFECT YOUR LEGAL RIGHTS.**

By downloading, accessing, registering for, or using the Service, you acknowledge that you have read, understood, and agree to be bound by these Terms and by our Privacy Policy, which is incorporated by reference. If you do not agree, do not access or use the Service.''',
    ),
    LegalSection(
      heading: '1. Nature of the Service — Marketplace, Not a Carrier',
      body: r'''
1.1 **Cruiseinride is a technology platform, not a transportation company.** The Service provides a marketplace that connects independent riders seeking transportation with independent third-party drivers. Cruiseinride does not provide transportation, logistics, taxi, limousine, or common carrier services, and does not employ any drivers.

1.2 **Pure marketplace — no company fleet.** Cruiseinride does not own, lease, or operate any vehicles. **Every ride on the platform is performed by an independent Driver using the Driver's own personal vehicle**, consistent with the definition of a "prearranged ride" under the Alabama Transportation Network Company Act (Act 2018-127, Ala. Code § 32-7C). Cruiseinride does not direct or control drivers' work, routes, schedules, or conduct. Any arrangement for a ride is solely between the Rider and the Driver.

1.3 **Independent contractors.** All drivers who use the Service are independent contractors and not employees, agents, joint venturers, franchisees, or representatives of Cruiseinride.

1.4 **APSC authorization.** Cruiseinride operates as a Transportation Network Company with a permit issued by the **Alabama Public Service Commission ("APSC")** pursuant to Act 2018-127 (Ala. Code § 32-7C) and the APSC rules at 770-X-12, and maintains compliance with that Act as described in Section 6.

1.5 **No guarantee of service.** Cruiseinride does not guarantee the availability of drivers, wait times, the condition or suitability of any vehicle, the identity or conduct of any user, or that the Service will be uninterrupted, timely, secure, or error-free.''',
    ),
    LegalSection(
      heading: '2. Eligibility',
      body: r'''
2.1 **Age.** You must be at least **18 years old** and capable of forming a binding contract to use the Service. Persons under 18 may not register for or use the Service. A minor may ride **only when accompanied by an adult**, and the accompanying adult is solely responsible for the minor's conduct and safety during the ride.

2.2 **Child restraints.** When Alabama's child restraint law (Ala. Code § 32-5-222) requires a child safety seat or booster, **the Rider is responsible for providing and installing it**. Drivers are not obligated to supply child restraint systems and may decline a ride when a required restraint is not provided.

2.3 **Drivers must:** (a) meet the minimum age required by applicable law; (b) hold a valid driver's license for the jurisdiction in which they operate; (c) maintain current vehicle registration and the minimum automobile liability insurance required by applicable law; (d) pass a background check administered by our third-party provider (Checkr, Inc.), as described in Section 5.5; and (e) complete identity verification, including document validation and facial liveness verification.

2.4 Users whose accounts have been suspended or terminated may not re-register or use the Service through another account.''',
    ),
    LegalSection(
      heading: '3. Accounts and Security',
      body: r'''
3.1 You agree to provide accurate, current, and complete information and to keep it updated. You are responsible for all activity that occurs under your account and for maintaining the confidentiality of your credentials.

3.2 You must notify us immediately at **support@cruiseinride.com** of any unauthorized use of your account or any other security breach. Cruiseinride is not liable for losses caused by unauthorized use of your credentials, except where required by law.

3.3 Accounts are personal and non-transferable. You may not sell, lend, or share your account.''',
    ),
    LegalSection(
      heading: "4. Riders' Terms",
      body: r'''
4.1 **Ride requests and fares.** Riders request rides through the App. Quoted fares are estimates and may vary based on route, traffic, demand (including dynamic or "surge" pricing, which will be disclosed before confirmation), tolls, wait time, and applicable taxes and fees. **Alabama local assessment:** fares for trips originating in Alabama may include the one percent (1%) assessment on the gross trip fare imposed by Ala. Code § 32-7C, which Cruiseinride reports and remits quarterly to the APSC (see Section 6.6).

4.2 **Cancellations.** Rides canceled within 2 minutes of driver assignment are free. After 2 minutes, or in case of a no-show, a cancellation fee may apply as displayed in the App. **Cancellation fees are paid to the Driver** (less applicable payment-processing costs) to compensate time and fuel, and are generally non-refundable, except where required by law.

4.3 **Scheduled rides.** Rides scheduled in advance are subject to driver availability. A scheduled ride that cannot be matched will be canceled without charge.

4.4 **Pre-ride disclosures.** Before you enter the vehicle, the App displays the **Driver's photo and first name, and the vehicle's make, model, and license plate**, as required by Ala. Code § 32-7C. Always verify the driver and vehicle match the App before boarding.

4.5 **Electronic receipts.** Within **two (2) hours** after trip completion, the App issues an electronic receipt showing the **origin, destination, total time, total distance, total fare paid, and the Driver's first name**, as required by Ala. Code § 32-7C.

4.6 **Payment.** You authorize Cruiseinride and its payment processor (Stripe, Inc.) to charge your designated payment method for fares, fees, tolls, cancellation charges, cleaning fees (in case of documented damage or excessive mess), and applicable taxes. Payment is processed automatically at trip completion. You are responsible for maintaining a valid payment method.

4.7 **Conduct.** Riders agree to treat drivers and vehicles with respect. Smoking, illegal substances, weapons, and abusive or discriminatory behavior are prohibited. Riders are liable for damage they cause to a vehicle.

4.8 **Lost and found.** If you leave an item in a vehicle, contact Support (Settings > Support) and we will help coordinate with the Driver. Drivers are independent contractors and are not required to return items, but most will; a **reasonable return fee** may apply to compensate the Driver's time, payable as displayed in the App. Cruiseinride is not responsible for lost items.

4.9 **Airport trips.** Trips to or from **Birmingham–Shuttlesworth International Airport (BHM)** are subject to the airport's rules for transportation network companies, including use of designated pickup and drop-off zones, airport permit requirements, and **airport fees or surcharges that may be passed through to the Rider** as displayed in the App.

4.10 **Dashcams and recording.** Drivers may use in-vehicle dashboard cameras ("dashcams") in accordance with applicable law. Alabama is a **one-party consent state for audio recording**, and drivers may therefore lawfully record audio and video inside their own vehicles. **By taking a ride, you acknowledge and consent that the ride may be recorded by the Driver's dashcam.** Dashcam footage belongs to the Driver and must be handled by the Driver in compliance with applicable law.''',
    ),
    LegalSection(
      heading: "5. Drivers' Terms",
      body: r'''
5.1 **Independent contractor relationship.** Nothing in these Terms creates an employment, agency, partnership, or joint venture relationship between you and Cruiseinride. You are not entitled to wages, benefits, workers' compensation, unemployment insurance, expense reimbursement, or any employment protections from Cruiseinride. You are solely responsible for your taxes, including self-employment taxes.

5.2 **Earnings.** Drivers earn a percentage of each fare according to their vehicle tier (Comfort: 60%, Premium: 65%, VIP: 70% of the fare), as displayed in the App. Tips are 100% for the driver. Cancellation fees collected from Riders are paid to the Driver, less applicable payment-processing costs. Rider refunds may reduce corresponding driver earnings.

5.3 **Changes to platform commission.** Cruiseinride may adjust its platform fee or commission structure with **at least fourteen (14) days' prior notice through the App**. Your continued use of the Service after that notice period constitutes acceptance of the new rates.

5.4 **Obligations.** Drivers agree to: (a) maintain a safe, clean, legally compliant, and insured vehicle; (b) comply with all traffic laws and local licensing requirements; (c) not discriminate against any rider (Section 10); (d) comply with the Zero-Tolerance Drug and Alcohol Policy (Section 9); (e) maintain the confidentiality of rider information; (f) not solicit rides or payments outside the platform for trips originated through it; (g) maintain accurate location sharing while online; and (h) display the Cruiseinride trade dress as required by Section 6.3.

5.5 **Background checks — annual screening and FCRA.** Continued access to the platform is conditioned on passing an **initial background check and a re-screening at least once every year**, administered by Checkr, Inc. Background checks are **"consumer reports" under the Fair Credit Reporting Act ("FCRA")**. In accordance with the FCRA: (a) we provide a **stand-alone disclosure** and obtain your **written authorization** in the App (via the background check consent screen) **before** ordering any report; (b) before taking any adverse action (including deactivation) based in whole or in part on a report, we will provide you a **pre-adverse action notice** with a copy of the report and the document **"A Summary of Your Rights Under the FCRA,"** and a **reasonable period to dispute** inaccurate or incomplete information with Checkr; and (c) if we proceed, we will send a final **adverse action notice** with the information required by the FCRA, including Checkr's contact details and your right to a free report and to dispute.

5.6 **Deactivation and appeal.** Cruiseinride may deactivate a Driver account based on background check results, safety reports, ratings below the platform threshold, document expiration, or fraud indicators. **Deactivations triggered by document expiration or fraud indicators include human review before they take effect.** A Driver may **appeal a deactivation** by contacting support@cruiseinride.com; appeals receive **human review and a response within fourteen (14) days**.''',
    ),
    LegalSection(
      heading: '6. Alabama TNC Compliance (Act 2018-127 / APSC Rules 770-X-12)',
      body: r'''
6.1 **Vehicle inspection.** Each Driver vehicle must pass a safety inspection performed by an **AATI- or ASE-certified mechanic** covering the safety points required by the APSC rules, **before the vehicle's first ride** on the platform and **at least once every year** thereafter. **No vehicle more than fifteen (15) model years old** may be used on the platform.

6.2 **Insurance.** Drivers and Cruiseinride maintain the coverages described in Section 8, as required by Ala. Code § 32-7C.

6.3 **Trade dress.** While online and available for rides, Drivers must display the **Cruiseinride emblem/logo** on their vehicle, **legible from fifty (50) feet during daylight and reflective or illuminated at night**, consistent with the trade dress design on file with the APSC.

6.4 **Pre-ride disclosures and receipts.** The Service provides the rider-facing disclosures (Section 4.4) and electronic receipts (Section 4.5) required by Ala. Code § 32-7C.

6.5 **Records and identifiers.** Cruiseinride retains **driver records and trip records for at least two (2) years**, as required by the APSC rules. Each trip is assigned a **unique trip identifier with its date**, and each Driver is assigned a **unique driver identifier**.

6.6 **Local assessment.** Cruiseinride assesses, collects, reports, and remits to the APSC, **on a quarterly basis**, the **one percent (1%) assessment on the gross trip fare** of all trips originating in Alabama, as required by Ala. Code § 32-7C. This assessment may be included in the fare displayed to the Rider (Section 4.1).

6.7 **Agent for service of process.** Cruiseinride maintains an **agent for service of legal process in the State of Alabama**, as required by Ala. Code § 32-7C.''',
    ),
    LegalSection(
      heading: '7. Payments, Credits, and Refunds',
      body: r'''
7.1 **Processor.** All payment processing is performed by Stripe, Inc. Cruiseinride does not store complete card numbers. Your use of payment services is also subject to Stripe's terms.

7.2 **Refunds.** Refund requests are evaluated case-by-case through in-app Support. Approved refunds are issued to the original payment method. Charges for completed trips, cancellation fees, and cleaning fees are otherwise final.

7.3 **Promotional credits ("Cruise Cash").** Promotional or referral credits: (a) have no cash value; (b) are non-transferable and non-refundable; (c) may expire as indicated in the App; (d) may be revoked in cases of fraud, abuse, or error; and (e) cannot be redeemed except as ride fare credit.

7.4 **Chargebacks.** If you dispute a valid charge with your bank or card issuer, Cruiseinride may suspend your account pending resolution and charge any costs incurred as permitted by law.''',
    ),
    LegalSection(
      heading: '8. Insurance',
      body: r'''
8.1 **Driver online, no prearranged ride (Period 1).** While a Driver is logged into the App and available to receive requests but has not yet accepted a prearranged ride, Cruiseinride maintains automobile liability coverage that is **primary** as required by Ala. Code § 32-7C, in amounts of at least **$50,000 per person for death and bodily injury, $100,000 per incident for death and bodily injury, and $25,000 for property damage**.

8.2 **Prearranged ride in progress (Periods 2 and 3).** From the moment a Driver accepts a prearranged ride until the ride ends, Cruiseinride maintains **primary automobile liability coverage of at least $1,000,000** for death, bodily injury, and property damage, as required by Ala. Code § 32-7C.

8.3 **First-dollar protection.** If a Driver's personal automobile policy does not apply, has lapsed, or denies coverage for an incident occurring during the periods described above, **Cruiseinride's coverage responds from the first dollar**, up to the limits stated in this Section and as required by law.

8.4 **Driver responsibilities.** Drivers remain responsible for maintaining at least the minimum personal automobile insurance required in their jurisdiction at all times, for vehicle maintenance and safe operation, and for any accident caused by their conduct outside the coverage described in this Section.

8.5 This Section describes the coverages Cruiseinride maintains to comply with applicable TNC law; it is a summary, not an insurance policy. Coverage is subject to the terms, conditions, and exclusions of the applicable policies.''',
    ),
    LegalSection(
      heading: '9. Zero-Tolerance Drug and Alcohol Policy',
      body: r'''
9.1 **Policy.** Cruiseinride maintains a **zero-tolerance policy** for drug and alcohol use by Drivers while using the Service, in accordance with Ala. Code § 32-7C and APSC rules. A Driver may not provide rides while impaired by alcohol, illegal drugs, or impairing medication.

9.2 **Reporting mechanism.** Riders and other users may report a suspected impaired Driver at any time through **Settings > Support** in the App or at support@cruiseinride.com. This complaint mechanism is published in the App as required by Ala. Code § 32-7C.

9.3 **Immediate suspension and investigation.** Upon receiving a complaint of drug or alcohol impairment, Cruiseinride will **immediately suspend the Driver's access to the platform** while the complaint is investigated. The investigation includes human review, a request for the Driver's response, and review of available trip, rating, and report data.

9.4 **Corrective action.** If the investigation substantiates the complaint, the Driver's account is **permanently deactivated**. If it does not, access is restored promptly and the complaint is documented in the Driver's record. Drivers may use the appeal process in Section 5.6.''',
    ),
    LegalSection(
      heading: '10. Non-Discrimination and Accessibility',
      body: r'''
10.1 **No discrimination.** In accordance with the Civil Rights Act of 1964, the Americans with Disabilities Act ("ADA"), and Ala. Code § 32-7C, users and Drivers may not discriminate on the basis of race, color, religion, national origin, sex, sexual orientation, gender identity, disability, age, or any other status protected by law, in the provision or use of the Service.

10.2 **No accessibility surcharges.** **Drivers may not charge or impose any additional fee, surcharge, or condition on Riders with disabilities**, including for the transport of mobility devices (wheelchairs, walkers, scooters), as required by the ADA and Ala. Code § 32-7C.

10.3 **Service animals.** Drivers **must accept service animals** accompanying Riders, without exception, surcharge, or cleaning fee, as required by the ADA and Ala. Code § 32-7C. **A Driver who refuses a service animal is subject to immediate suspension and, upon review, permanent deactivation.** Allergies or personal preference are not valid grounds for refusal.

10.4 Riders with disabilities may request accommodation or report discrimination through Settings > Support. Reports receive human review.''',
    ),
    LegalSection(
      heading: '11. Artificial Intelligence and Automated Features',
      body: r'''
11.1 **Disclosure.** The Service uses artificial intelligence and machine learning technologies ("AI Features"), including: (a) **identity verification** — facial liveness detection and document scanning (OCR) processed on-device via Google ML Kit; (b) **customer support chatbot** — automated responses generated by large language models (including OpenAI); (c) **automated matching and dispatch** — algorithmic rider-driver assignment based on location, availability, and other factors; (d) **safety and integrity systems** — fraud detection, "ghost driver" detection, document expiration monitoring, and rating moderation.

11.2 **Consent.** By using the Service, you consent to automated processing of your data for these purposes, as detailed in our Privacy Policy.

11.3 **No solely automated significant decisions.** Cruiseinride does not make decisions that produce legal effects or similarly significant effects on you (including account termination, payment disputes, or background check outcomes) **solely** through automated means. **Deactivations triggered by document expiration or fraud indicators also include human review before execution.** You may request human review of any AI-assisted decision by contacting support@cruiseinride.com.

11.4 **Limitations of AI.** AI-generated content (including support chat responses) may be inaccurate, incomplete, or outdated. It is provided for convenience only and does not constitute legal, financial, medical, or professional advice. Cruiseinride is not liable for actions taken in reliance on AI-generated content, except where prohibited by law.

11.5 **Biometric verification.** Facial liveness verification is used solely to confirm that the person registering or operating an account is a live human matching the submitted identification documents, as described in our Biometric Information Policy within the Privacy Policy.

11.6 **No AI training on your content.** User content and personal data are used **only to operate and improve the Service**. **We do not use user content or personal data to train artificial intelligence or machine learning models without your separate, explicit consent.**''',
    ),
    LegalSection(
      heading: '12. Safety and Prohibited Conduct',
      body: r'''
12.1 You agree NOT to: (a) use the Service for any unlawful purpose; (b) harass, threaten, discriminate against, or harm any user; (c) provide false information or impersonate any person; (d) manipulate GPS or use location-spoofing tools; (e) reverse engineer, scrape, or interfere with the Service; (f) use the Service to transport goods or persons in violation of law; (g) carry weapons (except as lawful and disclosed where required), illegal drugs, or hazardous materials; (h) create multiple accounts; or (i) attempt to defraud the fare, referral, or promotional systems.

12.2 Drivers additionally agree to comply with the Zero-Tolerance Policy (Section 9) and to honor the dashcam recording rules applicable to them (Section 4.10).

12.3 Violation of this section may result in immediate account termination and, where appropriate, referral to law enforcement.''',
    ),
    LegalSection(
      heading: '13. Intellectual Property',
      body: r'''
13.1 The Service, including the App, design, logos, trademarks, text, and software, is owned by or licensed to Cruiseinride and protected by intellectual property laws. We grant you a limited, non-exclusive, non-transferable, revocable license to use the App for its intended personal (Rider) or commercial driving (Driver) purposes.

13.2 You may not copy, modify, distribute, sell, or lease any part of the Service, nor use Cruiseinride trademarks without prior written consent.

13.3 **User content license.** By submitting content (photos, documents, ratings, messages), you grant Cruiseinride a worldwide, non-exclusive, royalty-free license to host, process, and display that content **solely to operate and improve the Service**. **We do not use your content to train artificial intelligence models without your separate, explicit consent** (Section 11.6).

13.4 **DMCA.** Copyright infringement claims under the Digital Millennium Copyright Act should be sent to our designated DMCA agent at **legal@cruiseinride.com**, including the information required by 17 U.S.C. § 512(c)(3).''',
    ),
    LegalSection(
      heading: '14. Third-Party Services',
      body: r'''
The Service integrates third-party providers, including Stripe (payments), Checkr (background checks), Twilio (SMS), Mapbox (maps), Google (Maps, ML Kit, Firebase), and OpenAI (AI support). Your use of those features may be subject to the providers' own terms and privacy policies. Cruiseinride is not responsible for third-party services, their availability, or their acts or omissions.''',
    ),
    LegalSection(
      heading: '15. Disclaimers',
      body: r'''
15.1 THE SERVICE IS PROVIDED "AS IS" AND "AS AVAILABLE," WITH ALL FAULTS AND WITHOUT WARRANTY OF ANY KIND. TO THE MAXIMUM EXTENT PERMITTED BY LAW, CRUISEINRIDE DISCLAIMS ALL WARRANTIES, EXPRESS OR IMPLIED, INCLUDING MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE, NON-INFRINGEMENT, AND ANY WARRANTY ARISING FROM COURSE OF DEALING OR USAGE OF TRADE.

15.2 WITHOUT LIMITING THE FOREGOING, CRUISEINRIDE MAKES NO WARRANTY REGARDING: (a) THE CONDUCT, IDENTITY, DRIVING, OR VEHICLES OF DRIVERS OR RIDERS; (b) THE AVAILABILITY OR RELIABILITY OF THE SERVICE; OR (c) THE ACCURACY OF ESTIMATED ARRIVAL TIMES, FARES, OR ROUTES.''',
    ),
    LegalSection(
      heading: '16. Limitation of Liability',
      body: r'''
16.1 TO THE MAXIMUM EXTENT PERMITTED BY APPLICABLE LAW, IN NO EVENT SHALL CRUISEINRIDE, ITS DIRECTORS, OFFICERS, EMPLOYEES, OR AFFILIATES BE LIABLE FOR ANY INDIRECT, INCIDENTAL, SPECIAL, CONSEQUENTIAL, EXEMPLARY, OR PUNITIVE DAMAGES, INCLUDING LOST PROFITS, LOST DATA, OR LOSS OF GOODWILL, ARISING OUT OF OR RELATED TO: (a) YOUR USE OF OR INABILITY TO USE THE SERVICE; (b) THE CONDUCT OF ANY DRIVER, RIDER, OR THIRD PARTY; (c) ANY RIDE OBTAINED THROUGH THE SERVICE; OR (d) UNAUTHORIZED ACCESS TO YOUR ACCOUNT OR DATA.

16.2 TO THE MAXIMUM EXTENT PERMITTED BY LAW, CRUISEINRIDE'S TOTAL AGGREGATE LIABILITY TO YOU FOR ALL CLAIMS ARISING FROM OR RELATED TO THE SERVICE SHALL NOT EXCEED THE GREATER OF: (a) THE TOTAL AMOUNTS PAID BY YOU TO CRUISEINRIDE (NET OF DRIVER EARNINGS) IN THE SIX (6) MONTHS PRECEDING THE EVENT GIVING RISE TO THE CLAIM, OR (b) ONE HUNDRED U.S. DOLLARS (US $100).

16.3 **Express exception.** THE LIMITATIONS AND CAPS IN THIS SECTION **DO NOT APPLY TO PERSONAL INJURY OR DEATH, TO CRUISEINRIDE'S GROSS NEGLIGENCE OR WILLFUL MISCONDUCT, OR WHERE APPLICABLE LAW PROHIBITS SUCH LIMITATIONS** (including liability that cannot be limited by law, such as certain statutory TNC insurance obligations).

16.4 SOME JURISDICTIONS DO NOT ALLOW CERTAIN LIMITATIONS, SO PARTS OF THIS SECTION MAY NOT APPLY TO YOU. IN SUCH CASES, LIABILITY IS LIMITED TO THE FULLEST EXTENT PERMITTED BY LAW.''',
    ),
    LegalSection(
      heading: '17. Indemnification',
      body: r'''
You agree to indemnify, defend, and hold harmless Cruiseinride, its affiliates, and their respective officers, directors, employees, and agents from and against any claims, demands, losses, damages, liabilities, costs, and expenses (including reasonable attorneys' fees) arising out of or related to: (a) your violation of these Terms; (b) your violation of any law or the rights of any third party; (c) your use or misuse of the Service; (d) content you submit; or (e) for Drivers, the operation, condition, or insurance status of your vehicle and any accident or incident occurring during a ride you provide.''',
    ),
    LegalSection(
      heading: '18. Dispute Resolution — Arbitration and Class Action Waiver',
      body: r'''
18.1 **Informal resolution first.** Before filing any claim, you agree to contact us at support@cruiseinride.com and attempt to resolve the dispute informally for at least 30 days.

18.2 **Binding arbitration.** Except as provided in Section 18.6, any dispute, claim, or controversy arising out of or relating to these Terms or the Service shall be resolved by **final and binding arbitration** administered by the American Arbitration Association ("AAA") under its Consumer Arbitration Rules. The arbitration shall be conducted in English, by a single arbitrator, in Birmingham, Alabama, or remotely by videoconference at your election. Judgment on the award may be entered in any court of competent jurisdiction.

18.3 **CLASS ACTION WAIVER.** YOU AND CRUISEINRIDE AGREE THAT EACH MAY BRING CLAIMS AGAINST THE OTHER **ONLY IN AN INDIVIDUAL CAPACITY** AND NOT AS A PLAINTIFF OR CLASS MEMBER IN ANY PURPORTED CLASS, COLLECTIVE, CONSOLIDATED, OR REPRESENTATIVE ACTION. THE ARBITRATOR MAY NOT CONSOLIDATE CLAIMS OF MORE THAN ONE PERSON.

18.4 **JURY TRIAL WAIVER.** TO THE EXTENT ANY CLAIM PROCEEDS IN COURT RATHER THAN ARBITRATION, YOU AND CRUISEINRIDE EACH **WAIVE ANY RIGHT TO A TRIAL BY JURY**.

18.5 **Mass-claim batching.** If **twenty-five (25) or more** similar claims are filed against Cruiseinride by or through the same or coordinated counsel, the parties agree to process them in **batches**, with **bellwether (test) cases arbitrated first** while the remaining claims are stayed; statutes of limitation and filing deadlines are **tolled** during the batching process; AAA filing and administrative fees are **prorated and allocated** as provided by the AAA's mass-arbitration procedures; and the parties will confer in good faith on an efficient schedule before any batch proceeds.

18.6 **Exceptions.** Either party may: (a) bring an individual action in small claims court within the court's jurisdictional limits; or (b) seek injunctive or equitable relief in court for intellectual property infringement or misuse of the Service.

18.7 **Drivers — FAA § 1 carve-out.** You and Cruiseinride acknowledge that Section 1 of the Federal Arbitration Act may exempt Drivers, as "transportation workers" engaged in interstate commerce, from the FAA's coverage. To the extent the FAA does not apply to a Driver claim, **the arbitration agreement between Cruiseinride and Drivers is governed by a separate driver arbitration agreement and, as a fallback, by the arbitration law of the applicable state** (including the Alabama Uniform Arbitration Act), and this Section applies to the fullest extent permitted by that law.

18.8 **Opt-out.** You may opt out of this arbitration agreement by sending written notice to **legal@cruiseinride.com** within **30 days** of first accepting these Terms, including your name, account email, and a clear statement that you opt out of arbitration.

18.9 **Time limit for claims.** Any claim arising from the Service must be filed within **one (1) year** after the claim arises, or it is permanently barred, to the extent permitted by law.''',
    ),
    LegalSection(
      heading: '19. Termination',
      body: r'''
19.1 You may delete your account at any time through Settings > Privacy > Delete Account. Account deletion follows the process described in our Privacy Policy.

19.2 Cruiseinride may suspend or terminate your access immediately, without prior notice, for violation of these Terms, fraud, safety concerns, illegal activity, or as required by law. **Suspensions and terminations based on document expiration or fraud indicators include human review before execution**, and Drivers may appeal under Section 5.6.

19.3 Upon termination, your license to use the Service ends. Sections that by their nature should survive (including Sections 1, 5.1, 8, 13, 15, 16, 17, 18, and 22) survive termination.''',
    ),
    LegalSection(
      heading: '20. Apple App Store and Google Play Terms',
      body: r'''
20.1 These Terms are between you and Cruiseinride only, not with Apple Inc. or Google LLC. Apple and Google are not responsible for the Service or its content. Your use of the App is also subject to the **App Store Usage Rules** (and, for Android, the Google Play Terms of Service).

20.2 Apple and Google have no obligation to provide maintenance or support for the App, are not responsible for addressing any claims (including product liability, legal compliance, or consumer protection claims), and are not responsible for third-party infringement claims. **Cruiseinride, not Apple, is solely responsible for the App and for any warranty not effectively disclaimed** under Section 15, including any express or implied warranty that the App fails to conform to.

20.3 Apple, and Apple's subsidiaries, are third-party beneficiaries of these Terms and may enforce them against you.

20.4 You represent that you are not located in a country subject to a U.S. government embargo and are not on any U.S. government restricted-party list.''',
    ),
    LegalSection(
      heading: '21. Communications and SMS Consent (TCPA)',
      body: r'''
21.1 **Transactional SMS.** By registering for the Service and providing your phone number, you **expressly consent to receive transactional text messages** from Cruiseinride and its providers (including Twilio), such as verification codes, trip status, driver arrival notices, receipts, and security alerts, at the number you provided, including messages sent by automated means.

21.2 **Promotional SMS (separate opt-in).** We send promotional or marketing text messages **only if you separately opt in**, as offered in the App. Consent to promotional messages is **not required** to use the Service.

21.3 **Opt-out and help.** You may revoke consent at any time: reply **STOP** to any message to cancel, or **HELP** for help. Message and data rates from your carrier may apply. Message frequency varies. Opting out of transactional SMS may prevent use of phone-based verification features.

21.4 Consent records are kept as required by the Telephone Consumer Protection Act ("TCPA") and related rules.''',
    ),
    LegalSection(
      heading: '22. Governing Law and Venue',
      body: r'''
These Terms are governed by the laws of the **State of Alabama** and applicable federal law of the United States, without regard to conflict-of-law principles. Subject to Section 18 (arbitration), the state and federal courts located in **Jefferson County, Alabama** shall have exclusive jurisdiction over any dispute that proceeds in court, and you consent to their venue and jurisdiction.''',
    ),
    LegalSection(
      heading: '23. Changes to These Terms',
      body: r'''
We may modify these Terms at any time. Material changes will be notified through the App, by email, or by posting an updated version with a new Effective Date at least 7 days before they take effect. Your continued use of the Service after the effective date constitutes acceptance. If you do not agree, you must stop using the Service and delete your account.''',
    ),
    LegalSection(
      heading: '24. Miscellaneous',
      body: r'''
24.1 **Entire agreement.** These Terms, together with the Privacy Policy, are the entire agreement between you and Cruiseinride regarding the Service.

24.2 **Severability.** If any provision is held invalid or unenforceable, it will be enforced to the maximum extent permissible and the remainder will continue in full force.

24.3 **No waiver.** Failure to enforce any provision is not a waiver of that or any other provision.

24.4 **Assignment.** You may not assign these Terms without our consent. Cruiseinride may assign them freely, including in connection with a merger, acquisition, or sale of assets.

24.5 **Force majeure.** Cruiseinride is not liable for failures caused by events beyond its reasonable control, including natural disasters, wars, strikes, pandemics, utility or network failures, or acts of government.

24.6 **Notices.** We may notify you via the App, email, or SMS. Legal notices to Cruiseinride must be sent to **legal@cruiseinride.com**.''',
    ),
    LegalSection(
      heading: '25. Contact',
      body: r'''
- **Support:** support@cruiseinride.com
- **Legal:** legal@cruiseinride.com
- **Privacy:** privacy@cruiseinride.com
- **Data protection:** dpo@cruiseinride.com
- **In-app:** Settings > Support

*By using Cruiseinride, you acknowledge that you have read and understood these Terms of Service and agree to be bound by them.*''',
    ),
  ];

  @override
  Widget build(BuildContext context) {
    return const LegalDocumentScreen(
      title: 'Terms of Service',
      effectiveDate: 'Effective Date: July 26, 2026',
      sections: _sections,
    );
  }
}
