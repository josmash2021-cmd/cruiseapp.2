import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Guardian for the pending-driver boot routing (user report 2026-10-11):
/// a driver still waiting for dispatch approval closed the app from the
/// support chat and the next boot landed on the DRIVER HOME as if the
/// account were approved.
///
/// Root cause: store-era builds wrote `driver_onboarding_complete = true`
/// when the driver finished SUBMITTING documents — not when dispatch
/// approved them — and `wasDriverEverApproved()` promoted that flag to
/// 'approved' on the primary cache key, poisoning it permanently.
///
/// (2026-10-13, user report: the hub auto-routed a fully-submitted driver
/// to the WAITLIST page even though dispatch never pressed the waitlist
/// button. That auto-route is dead: docs-complete shows the hub's "In
/// review" card, and the waitlist page opens only when the server says
/// `verification_status == 'waitlist'` — socket, poll, splash, push tap.)
void main() {
  final lds = File('lib/services/local_data_service.dart').readAsStringSync();
  final todo = File('lib/screens/driver/onboarding/driver_todo_screen.dart')
      .readAsStringSync();
  final splash = File('lib/screens/splash_screen.dart').readAsStringSync();
  final welcome = File('lib/screens/driver/driver_welcome_screen.dart')
      .readAsStringSync();

  test('submitting documents is NOT an approval witness', () {
    expect(
      lds.contains("prefs.getBool('driver_onboarding_complete')"),
      isFalse,
      reason: 'that flag meant "documents submitted" in store-era builds — '
          'treating it as approval let unreviewed drivers into the home',
    );
    expect(
      lds.contains("prefs.remove('driver_onboarding_complete')"),
      isTrue,
      reason: 'devices already poisoned must be decontaminated once — the '
          'legacy key (written only after a REAL server approval) is the '
          'witness, and an unvouched approved drops back to pending for a '
          'live re-check',
    );
    expect(
      lds.contains("prefs.getString('driver_status') != 'approved'"),
      isTrue,
    );
  });

  test('the hub NEVER auto-routes on docs-complete (dispatch button only)', () {
    expect(todo.contains('_maybeRouteToReview'), isFalse,
        reason: 'died 2026-10-13 (user report): uploading every document '
            'must NOT open the waitlist page — that state is the hub\'s '
            '"In review" card');
    expect(todo, contains('_allInReviewCard'),
        reason: 'everything submitted + waiting on dispatch = the hub\'s '
            'In review card');
    expect(todo, contains('void _goWaitlisted()'),
        reason: 'the waitlist page opens when the server says waitlist');
    expect(todo, contains("status == 'waitlist'"),
        reason: 'the socket push flips the hub live');
    expect(todo, contains("s == 'waitlist'"),
        reason: 'the 25 s poll is the dead-socket fallback');
    final signup = File('lib/screens/driver/driver_signup_screen.dart')
        .readAsStringSync();
    expect(signup, contains('const DriverTodoScreen()'),
        reason: 'a freshly submitted application lands on the hub');
    expect(signup.contains('const DriverWaitlistScreen()'), isFalse);
  });

  test('the splash keeps its pending/rejected gates', () {
    expect(
      splash.contains('LocalDataService.wasDriverEverApproved()'),
      isTrue,
      reason: 'the ever-approved fast path stays, but only when the primary '
          'cache has no live answer',
    );
    expect(splash.contains('const DriverWaitlistScreen()'), isTrue,
        reason: 'the waitlist gate');
    expect(splash.contains('DriverWaitlistScreen.rejected('), isTrue,
        reason: 'the rejected gate → the rejected variant of the waitlist '
            'page');
    expect(splash.contains('const DriverTodoScreen()'), isTrue,
        reason: 'an unfinished onboarding resumes on the hub, not the '
            'waitlist page and never the home');
  });

  test('a waitlist rollback clears legacy approval and wins every boot', () {
    expect(lds, contains("status != 'approved'"));
    expect(lds, contains("prefs.remove('driver_status')"),
        reason: 'the old driver_status=approved key must not survive waitlist');
    expect(splash, contains("cachedStatus == 'waitlist'"));
    expect(
      splash.indexOf("cachedStatus == 'waitlist'"),
      lessThan(splash.indexOf('wasDriverEverApproved()')),
      reason: 'waitlist is evaluated before the ever-approved latch',
    );
    expect(splash, contains('if (_isWaitlistData(d)) return \'waitlist\';'),
        reason: 'Firestore waitlist wins before any stale isApproved marker');
    expect(welcome, contains("s == 'approved' && isVerified"),
        reason: 'login requires BOTH server markers — never the stale flag');
    expect(welcome, contains("} else if (s == 'waitlist') {"),
        reason: 'login routes waitlist to the waitlist page, not the hub/home');
  });
}
