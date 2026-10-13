import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Guardian for the driver waitlist page (user spec 2026-10-13): when
/// dispatch moves a driver to the waitlist (backend
/// `verification_status == 'waitlist'`), the app shows the "Navy and Gold
/// Waitlist Verification Screen" mock — gold hourglass + ID card over a
/// dark-blue cloud. The same screen ALSO owns the rejected state: the old
/// pending-review page was retired the same day ("esa página de under
/// review elimínala ya que es vieja") and every route to it now lands
/// here.
///
/// Pins: widget-only mock art (OTA patches carry no new assets — the
/// maintenance_hero lesson), the exact hero intervals of the
/// update-required page, support top-LEFT / exit X top-RIGHT, the rejected
/// variant (soft red, dispatch reason, support as primary action), the
/// verbatim mock copy ES/EN, the retired file DELETED with zero references
/// left in lib/, and the 10 s auto-exit poll cancelled in dispose.
void main() {
  final screen =
      File('lib/screens/driver/driver_waitlist_screen.dart').readAsStringSync();
  final splash =
      File('lib/screens/splash_screen.dart').readAsStringSync();
  final mainDart = File('lib/main.dart').readAsStringSync();
  final l10n = File('lib/l10n/app_localizations.dart').readAsStringSync();

  group('mock art — widgets only, cloud + hourglass + ID card', () {
    test('no image assets or network art (OTA-safe)', () {
      expect(screen.contains('Image.asset'), isFalse,
          reason: 'Shorebird OTA patches do not carry new assets');
      expect(screen.contains('Image.network'), isFalse);
    });

    test('gold hourglass + ID card with person glyph over a composed cloud',
        () {
      expect(screen, contains('Icons.hourglass_top_rounded'),
          reason: 'the gold hourglass of the mock');
      expect(screen, contains('Icons.person_outline_rounded'),
          reason: 'the ID card carries a person glyph');
      expect(screen, contains('_cloudPuff'),
          reason: 'the dark-blue cloud is an organic blob composed from '
              'overlapping circles');
      expect(screen.contains('Icons.cloud'), isFalse,
          reason: 'the mock cloud is composed, never the cloud glyph');
      expect(screen, contains('0xFFE8C547'), reason: 'house gold');
    });

    test('hero entrance mirrors update-required EXACTLY', () {
      expect(screen,
          contains('const Interval(0, 0.55, curve: Curves.easeOutBack)'),
          reason: 'scale interval of update_required_screen.dart');
      expect(screen, contains('const Interval(0, 0.4)'),
          reason: 'fade interval of update_required_screen.dart');
    });
  });

  group('corner buttons + not a prison', () {
    test('support top-LEFT, exit X top-RIGHT', () {
      expect(screen, contains('left: 8,'),
          reason: 'support button Positioned top-left');
      expect(screen, contains('right: 8,'),
          reason: 'exit X Positioned top-right');
      expect(screen, contains('Icons.close_rounded'));
      expect(screen, contains('HelpScreen'),
          reason: 'support opens the existing dispatch support chat');
      expect(screen, contains('UserSession.logout()'),
          reason: 'X mirrors the retired page\'s explicit exit (logout → '
              'welcome) — a bare pop is unsafe: the splash can make this '
              'page the root route');
      expect(screen, contains('WelcomeScreen'));
    });

    test('NOT a prison — back stays enabled', () {
      expect(screen.contains('canPop: false'), isFalse,
          reason: 'same rule as the retired pending review (2026-08-24)');
    });
  });

  group('rejected variant', () {
    test('constructor + soft-red accent + dispatch reason', () {
      expect(screen, contains('DriverWaitlistScreen.rejected'));
      expect(screen, contains('startsRejected'));
      expect(screen, contains('0xFFE57373'),
          reason: 'soft red accent replaces the gold when rejected');
      expect(screen, contains('waitlistRejectedTitle'));
      expect(screen, contains("result['rejection_reason']"),
          reason: 'the poll refreshes the dispatch note from the API');
    });

    test('support is the primary action of the rejected variant', () {
      expect(screen, contains('ElevatedButton.icon'),
          reason: 'full-width support CTA');
      expect(screen, contains('_rejected'),
          reason: 'the CTA and accents are gated on the variant');
    });

    test('the 10 s poll flips variants in place and keeps the approved chain',
        () {
      expect(screen, contains('_rejected = true'),
          reason: 'waitlist → rejected when the poll sees a rejection');
      expect(screen, contains('_rejected = false'),
          reason: 'rejected → waitlist when the status leaves rejection '
              'without an approval');
      expect(screen, contains('DriverApprovedCelebrationScreen'),
          reason: 'approved → the same celebration the retired page landed '
              'on (pending→approved chain intact)');
      expect(screen, contains('if (!mounted'),
          reason: 'mounted guard before navigating after the async gap');
    });

    test('poll cancelled in dispose', () {
      final dispose = screen.substring(screen.indexOf('void dispose()'));
      expect(dispose, contains('_poll?.cancel();'));
    });
  });

  group('routing — every old pending-review route lands here', () {
    test('splash: rejected branches → rejected variant, waitlist → waitlist',
        () {
      expect(
          'DriverWaitlistScreen.rejected('.allMatches(splash).length >= 2,
          isTrue,
          reason: 'the live-status branch (with the API reason) and the '
              'Firestore branch');
      expect(splash, contains('const DriverWaitlistScreen()'));
      expect(splash, contains("setDriverApprovalStatus('waitlist')"));
    });

    test('main.dart: rejection push + driver_waitlisted push', () {
      expect(mainDart, contains('const DriverWaitlistScreen.rejected()'),
          reason: '_handleAccountRejected lands on the rejected variant');
      expect(mainDart, contains("type == 'driver_waitlisted'"));
      expect(mainDart, contains('_handleDriverWaitlisted'));
      expect(
          mainDart, contains("import 'screens/driver/driver_waitlist_screen.dart'"));
    });

    test('signup / welcome / to-do hub route here', () {
      final signup = File('lib/screens/driver/driver_signup_screen.dart')
          .readAsStringSync();
      final welcome = File('lib/screens/driver/driver_welcome_screen.dart')
          .readAsStringSync();
      final todo = File('lib/screens/driver/onboarding/driver_todo_screen.dart')
          .readAsStringSync();
      expect(signup, contains('const DriverWaitlistScreen()'),
          reason: 'freshly submitted application = under review = waitlist');
      expect(welcome, contains('const DriverWaitlistScreen.rejected()'));
      expect(todo, contains('const DriverWaitlistScreen()'),
          reason: '_maybeRouteToReview lands on the waitlist page');
    });
  });

  group('the old pending-review page is gone', () {
    test('file deleted, zero references left in lib/', () {
      expect(
          File('lib/screens/driver/driver_pending_review_screen.dart')
              .existsSync(),
          isFalse,
          reason: 'retired 2026-10-13 — "esa página de under review '
              'elimínala ya que es vieja"');
      final leftovers = <String>[];
      for (final entity in Directory('lib').listSync(recursive: true)) {
        if (entity is! File || !entity.path.endsWith('.dart')) continue;
        final src = entity.readAsStringSync();
        if (src.contains('DriverPendingReviewScreen') ||
            src.contains('driver_pending_review_screen')) {
          leftovers.add(entity.path);
        }
      }
      expect(leftovers, isEmpty,
          reason: 'references to the retired screen left behind');
    });
  });

  group('strings — verbatim mock copy ES + EN', () {
    test('waitlistTitle', () {
      expect(l10n, contains('Estás en lista de espera'));
      expect(l10n, contains("You're on the waitlist!"));
    });

    test('waitlistBody — verbatim, blank line included', () {
      expect(
          l10n,
          contains(
              'Tu cuenta está actualmente en revisión. Nuestro equipo está trabajando para completar tu verificación.\\n\\nTe notificaremos en cuanto tu cuenta sea aprobada.'));
      expect(
          l10n,
          contains(
              "Your account is currently under review. Our team is working to complete your verification.\\n\\nWe'll notify you as soon as your account is approved."));
    });

    test('waitlistRejectedTitle + waitlistSupport + waitlistExitHint', () {
      expect(l10n,
          contains("waitlistRejectedTitle =>\n      _es ? 'Solicitud no aprobada' : 'Application not approved'"));
      expect(l10n, contains("waitlistSupport => _es ? 'Soporte' : 'Support'"));
      expect(l10n, contains("waitlistExitHint => _es ? 'Salir' : 'Exit'"));
    });
  });
}
