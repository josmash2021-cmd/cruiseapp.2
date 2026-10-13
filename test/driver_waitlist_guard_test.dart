import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Guardian for the driver waitlist page (user spec 2026-10-13): when
/// dispatch moves a driver to the waitlist (backend
/// `verification_status == 'waitlist'`), the app shows a navy/gold
/// "You're on the waitlist!" page instead of dropping them into the
/// generic to-do hub.
///
/// Pins: widget-only art (OTA patches carry no new assets — the
/// maintenance_hero lesson), support top-LEFT / exit X top-RIGHT, splash
/// routing on BOTH the Firestore and API branches, the pending-review
/// handoff, the `driver_waitlisted` push route, ES+EN strings, and the
/// 10 s auto-exit poll cancelled in dispose.
void main() {
  final screen =
      File('lib/screens/driver/driver_waitlist_screen.dart').readAsStringSync();
  final splash =
      File('lib/screens/splash_screen.dart').readAsStringSync();
  final pending = File('lib/screens/driver/driver_pending_review_screen.dart')
      .readAsStringSync();
  final mainDart = File('lib/main.dart').readAsStringSync();
  final l10n = File('lib/l10n/app_localizations.dart').readAsStringSync();

  group('waitlist screen — widget-only art + corner buttons', () {
    test('no image assets or network art (OTA-safe)', () {
      expect(screen.contains('Image.asset'), isFalse,
          reason: 'Shorebird OTA patches do not carry new assets');
      expect(screen.contains('Image.network'), isFalse);
      expect(screen, contains('Icons.hourglass_top_rounded'),
          reason: 'the gold hourglass of the mock, composed from widgets');
      expect(screen, contains('Icons.badge_outlined'));
      expect(screen, contains('0xFFE8C547'), reason: 'house gold');
    });

    test('support top-LEFT, exit X top-RIGHT', () {
      expect(screen, contains('left: 8,'),
          reason: 'support button Positioned top-left');
      expect(screen, contains('right: 8,'),
          reason: 'exit X Positioned top-right');
      expect(screen, contains('Icons.close_rounded'));
      expect(screen, contains('HelpScreen'),
          reason: 'support opens the existing dispatch support chat');
      expect(screen, contains('UserSession.logout()'),
          reason: 'X mirrors pending review\'s explicit exit (logout → '
              'welcome) — a bare pop is unsafe: the splash can make this '
              'page the root route');
      expect(screen, contains('WelcomeScreen'));
    });

    test('NOT a prison — back stays enabled', () {
      expect(screen.contains('canPop: false'), isFalse,
          reason: 'same rule as pending review (2026-08-24)');
    });
  });

  group('waitlist screen — auto-exit poll', () {
    test('polls approval status and navigates on change', () {
      expect(screen, contains('ApiService.getDriverApprovalStatus()'));
      expect(screen, contains('Duration(seconds: 10)'));
      expect(screen, contains('DriverApprovedCelebrationScreen'),
          reason: 'approved → the same celebration pending review lands on');
      expect(screen, contains('DriverPendingReviewScreen'),
          reason: 'rejected/back-to-pending → the live status screen');
      expect(screen, contains('if (!mounted'),
          reason: 'mounted guard before navigating after the async gap');
    });

    test('poll cancelled in dispose', () {
      final dispose = screen.substring(screen.indexOf('void dispose()'));
      expect(dispose, contains('_poll?.cancel();'));
    });
  });

  group('splash routing — waitlist lands on the waitlist page', () {
    test('Firestore branch routes fsStatus waitlist', () {
      expect(splash, contains("if (fsStatus == 'waitlist')"));
      expect(splash, contains('_isWaitlistData'),
          reason: 'the quick Firestore check must be able to RETURN '
              'waitlist for fsStatus to ever carry it');
    });

    test('API branch routes status waitlist (no more to-do hub fallthrough)',
        () {
      expect(splash, contains("} else if (status == 'waitlist') {"));
    });

    test('cached-status live re-check routes liveStatus waitlist', () {
      expect(splash, contains("} else if (liveStatus == 'waitlist') {"));
    });

    test('status cached like the other routings + screen imported', () {
      expect(splash, contains("setDriverApprovalStatus('waitlist')"));
      expect(
          'return const DriverWaitlistScreen();'.allMatches(splash).length >=
              3,
          isTrue,
          reason: 'fs branch + API branch + cached live re-check');
      expect(splash, contains("import 'driver/driver_waitlist_screen.dart'"));
    });
  });

  group('pending review — waitlist handoff', () {
    test('Firestore data branch detects waitlist', () {
      expect(pending, contains('isWaitlisted'));
      expect(pending, contains('_handleWaitlisted'));
    });

    test('API branches (primary + fallback) detect waitlist', () {
      expect(pending, contains("} else if (status == 'waitlist') {"));
      expect(pending, contains("} else if (status2 == 'waitlist') {"));
    });

    test('handoff is pushReplacement to DriverWaitlistScreen', () {
      expect(pending, contains('pushReplacement('));
      expect(pending, contains('const DriverWaitlistScreen()'));
      expect(
          pending, contains("import 'driver_waitlist_screen.dart'"));
    });
  });

  group('push routing — driver_waitlisted', () {
    test('main.dart routes the tap, role-gated driver', () {
      expect(mainDart, contains("type == 'driver_waitlisted'"));
      expect(mainDart, contains('_handleDriverWaitlisted'));
      expect(mainDart, contains('const DriverWaitlistScreen()'));
      expect(
          mainDart, contains("import 'screens/driver/driver_waitlist_screen.dart'"));
    });
  });

  group('strings — ES + EN', () {
    test('waitlistTitle', () {
      expect(l10n, contains('Estás en lista de espera'));
      expect(l10n, contains("You're on the waitlist!"));
    });

    test('waitlistBody', () {
      expect(l10n, contains('Tu cuenta está actualmente en revisión.'));
      expect(l10n, contains('Your account is currently under review.'));
    });

    test('waitlistSupport + waitlistExitHint', () {
      expect(l10n, contains("waitlistSupport => _es ? 'Soporte' : 'Support'"));
      expect(l10n, contains("waitlistExitHint => _es ? 'Salir' : 'Exit'"));
    });
  });
}
