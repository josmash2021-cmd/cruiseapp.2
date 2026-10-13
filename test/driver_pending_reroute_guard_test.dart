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
/// (2026-10-13: the "review page" these pins route to IS the waitlist
/// screen now — the old pending-review page was retired and the waitlist
/// screen owns pending/waitlist/rejected.)
void main() {
  final lds = File('lib/services/local_data_service.dart').readAsStringSync();
  final todo = File('lib/screens/driver/onboarding/driver_todo_screen.dart')
      .readAsStringSync();
  final splash = File('lib/screens/splash_screen.dart').readAsStringSync();

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

  test('the hub routes a fully-submitted driver to the waitlist page', () {
    expect(todo.contains('Future<void> _maybeRouteToReview()'), isTrue);
    expect(
      todo.contains('_entries.every((e) => e.isCompleted)'),
      isTrue,
      reason: 'everything submitted + waiting on dispatch = the waitlist '
          'page, on every reopen',
    );
    expect(todo.contains('const DriverWaitlistScreen()'), isTrue);
    expect(
      todo.contains("cached == 'rejected'"),
      isTrue,
      reason: 'a rejected account stays on the hub — its next move is '
          'fixing the failed item, not staring at the waitlist page',
    );
  });

  test('the splash keeps its pending/rejected gates', () {
    expect(
      splash.contains('LocalDataService.wasDriverEverApproved()'),
      isTrue,
      reason: 'the ever-approved fast path is the first gate — it must '
          'stay backed by the decontaminated service',
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
}
