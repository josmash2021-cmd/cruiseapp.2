import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Guard for the 2026-10-22 driver-referral invite link + "My Referrals"
/// swipe page:
///  * the shared link lives on the BACKEND host (the one serving
///    apple-app-site-association / assetlinks.json) at /drive/{code};
///  * Android keeps the code across a fresh install via the Play install
///    referrer, iOS via Universal Links delivered to the SceneDelegate;
///  * Dart persists the code until signup redeems it, and the signup form
///    confirms "referral invitation applied" under the DOB tile;
///  * page 2 shows private names ("Luis R."), joined/expiry dates, smooth
///    animated bars, green at 100%, and a Pending/Paid Earned card.
void main() {
  final screen = File('lib/screens/driver/driver_referral_screen.dart')
      .readAsStringSync();
  final signup = File('lib/screens/driver/driver_signup_screen.dart')
      .readAsStringSync();
  final service =
      File('lib/services/referral_link_service.dart').readAsStringSync();
  final main = File('lib/main.dart').readAsStringSync();
  final api = File('lib/services/api_service.dart').readAsStringSync();
  final l10n = File('lib/l10n/app_localizations.dart').readAsStringSync();
  final manifest = File('android/app/src/main/AndroidManifest.xml')
      .readAsStringSync();
  final mainActivity =
      File('android/app/src/main/kotlin/com/cruiseinride/app/MainActivity.kt')
          .readAsStringSync();
  final gradle =
      File('android/app/build.gradle.kts').readAsStringSync();
  final appDelegate =
      File('ios/Runner/AppDelegate.swift').readAsStringSync();
  final sceneDelegate =
      File('ios/Runner/SceneDelegate.swift').readAsStringSync();
  final authRouter =
      File('backend/routers/auth.py').readAsStringSync();

  group('share link targets the backend host', () {
    test('the shared URL is /drive/{code} on the API host', () {
      expect(screen, contains('/drive/\$_code'));
      expect(screen, contains('ApiService.currentBaseUrl'));
      expect(screen.contains('cruiseinride.com/drive'), isFalse,
          reason: 'the marketing domain serves no AASA/assetlinks — the OS '
              'could never open an installed app from it');
    });
  });

  group('native link capture', () {
    test('Android manifest matches /drive on the backend host', () {
      expect(
        manifest,
        contains('android:host="cruiseapp2-production.up.railway.app" '
            'android:pathPrefix="/drive"'),
      );
    });

    test('MainActivity reads intents AND the Play install referrer', () {
      expect(mainActivity, contains('"cruise/referral_link"'));
      expect(mainActivity, contains('getPendingDriverCode'));
      expect(mainActivity, contains('driverReferralLink'));
      expect(mainActivity, contains('InstallReferrerClient'));
      expect(mainActivity, contains('getQueryParameter("driver_code")'));
      expect(mainActivity, contains('catch (e: Exception)'),
          reason: 'installReferrer can throw — an uncaught throw inside '
              'onInstallReferrerSetupFinished kills the connection silently');
    });

    test('the install referrer dependency is declared', () {
      expect(gradle,
          contains('com.android.installreferrer:installreferrer:2.2'));
    });

    test('iOS caches the code and answers getPendingDriverCode', () {
      expect(appDelegate, contains('"cruise/referral_link"'));
      expect(appDelegate, contains('latestDriverCode'));
      expect(appDelegate, contains('handleDriverReferralUrl'));
      expect(appDelegate, contains('getPendingDriverCode'));
    });

    test('the SceneDelegate — not the AppDelegate — receives the link', () {
      // UIScene lifecycle: NSUserActivity never reaches
      // application(_:continue:); it lands on scene(_:continue:) and on
      // willConnectTo's connectionOptions for cold starts.
      expect(sceneDelegate, contains('scene(_:continue'));
      expect(sceneDelegate, contains('willConnectTo'));
      expect(sceneDelegate, contains('AppDelegate.handleDriverReferralUrl'));
    });

    test('the backend serves the /drive landing + AASA path', () {
      expect(authRouter, contains('@router.get("/drive/{code}")'));
      expect(authRouter, contains('"/drive/*"'));
      expect(authRouter, contains('driver_code='));
    });
  });

  group('Dart side of the channel', () {
    test('ReferralLinkService persists the pending code', () {
      expect(service, contains("MethodChannel('cruise/referral_link')"));
      expect(service, contains('pending_driver_referral_code'));
      expect(service, contains('pendingDriverCode'));
      expect(service, contains('clearPendingDriverCode'));
      expect(service, contains('getPendingDriverCode'));
    });

    test('boot absorbs any code that arrived before Dart was up', () {
      expect(main, contains('ReferralLinkService.init()'));
    });

    test('ApiService exposes the public validate call', () {
      expect(api, contains('validateDriverReferralCode'));
      expect(api, contains('/driver-referrals/validate?code='));
    });
  });

  group('signup applies the invited code', () {
    test('the pending code prefills and validates', () {
      expect(signup, contains('ReferralLinkService.pendingDriverCode()'));
      expect(signup, contains('ApiService.validateDriverReferralCode(code)'));
      expect(signup, contains('_linkReferralApplied'));
    });

    test('the confirmation line sits under the DOB tile', () {
      final dob = signup.indexOf('_buildDobPicker(),');
      final line = signup.indexOf('referralInvitationApplied');
      expect(dob, greaterThan(-1));
      expect(line, greaterThan(dob),
          reason: 'the applied line must render right after the DOB tile');
    });

    test('a successful redeem clears the pending code', () {
      expect(signup, contains('ReferralLinkService.clearPendingDriverCode()'));
    });

    test('the string is localized ES/EN', () {
      expect(l10n, contains('Invitación de referido aplicada exitosamente'));
      expect(l10n, contains('Referral invitation applied successfully'));
    });
  });

  group('My Referrals swipe page', () {
    test('two pages in a PageView with dots', () {
      expect(screen, contains('PageView('));
      expect(screen, contains('_buildMainReferralPage'));
      expect(screen, contains('_buildMyReferralsPage'));
      expect(screen, contains('_pageCtrl'));
      expect(screen, contains('_buildPageDots'));
    });

    test('page 1 keeps Share fixed; page 2 hides it', () {
      expect(screen, contains('_buildBottomShareButton'));
      expect(screen, contains('ignoring: _pageIndex != 0'));
    });

    test('rows are privacy-safe and dated', () {
      expect(screen, contains("r['display_name']"));
      expect(screen, contains('referralJoined'));
      expect(screen, contains('referralExpires'));
      expect(screen, contains('_fmtDate'));
      expect(screen.contains('CachedNetworkImageProvider'), isFalse,
          reason: 'page 2 shows name + last initial only — no photos');
    });

    test('bars and the Earned total animate smoothly', () {
      expect(screen, contains('TweenAnimationBuilder<double>'));
      expect(screen, contains('_buildEarnedCard'));
      expect(screen, contains('Curves.easeOutCubic'));
    });

    test('paid turns green; pending stays gold', () {
      expect(screen, contains('_green'));
      expect(screen, contains('s.paidLabel'));
      expect(screen, contains('s.pendingLabel'));
      expect(screen, contains('payment_status'));
    });

    test('the steering-wheel glyph is painted, not an asset', () {
      expect(screen, contains('_SteeringWheelPainter'));
    });
  });
}
