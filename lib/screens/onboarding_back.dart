import 'package:flutter/material.dart';

import '../config/page_transitions.dart';
import 'welcome_screen.dart';

/// Back arrow of an onboarding step (name / email, rider and driver).
///
/// During a signup these steps sit on top of the code screen, but the
/// splash also boots straight INTO them to resume an abandoned signup — as
/// the ONLY route on the stack. A blind `Navigator.pop()` there removed the
/// last route and left a black screen (Android 747 report 2026-10-29: "le
/// dan para atrás y les queda pantalla negra"). With nothing underneath,
/// back goes to the role picker instead; the session is kept, so the next
/// launch resumes the same step.
void onboardingBack(BuildContext context) {
  final nav = Navigator.maybeOf(context);
  if (nav == null) return;
  if (nav.canPop()) {
    nav.pop();
    return;
  }
  nav.pushAndRemoveUntil(
    smoothFadeRoute(const WelcomeScreen()),
    (_) => false,
  );
}
