import 'dart:io';

import 'package:cruise_app/screens/driver/driver_welcome_screen.dart';
import 'package:cruise_app/services/api_service.dart';
import 'package:flutter_test/flutter_test.dart';

/// Guardian for the 2026-10-29 Android 747 reports:
///  A) registered drivers "les pedía todo nuevamente como si no estuvieran
///     registrados" and back left a black screen;
///  B) drivers looped on 401 for an hour with ZERO calls to /auth/refresh,
///     and an IP-ban 403 right after phone-login must not end the session;
///  C) "si le doy rechazar a un driver no le aparece la página de rechazado".
void main() {
  String read(String p) => File(p).readAsStringSync().replaceAll('\r\n', '\n');
  final api = read('lib/services/api_service.dart');
  final mainDart = read('lib/main.dart');
  final splash = read('lib/screens/splash_screen.dart');
  final welcome = read('lib/screens/driver/driver_welcome_screen.dart');
  final todo = read('lib/screens/driver/onboarding/driver_todo_screen.dart');
  final waitlist = read('lib/screens/driver/driver_waitlist_screen.dart');

  String between(String src, String start, String end) {
    final a = src.indexOf(start);
    if (a < 0) throw StateError('missing "$start"');
    final b = src.indexOf(end, a + start.length);
    if (b < 0) throw StateError('missing "$end" after "$start"');
    return src.substring(a, b);
  }

  group('A — onboarding steps never pop the last route', () {
    for (final p in const [
      'lib/screens/driver/driver_name_screen.dart',
      'lib/screens/driver/driver_email_screen.dart',
      'lib/screens/rider_name_screen.dart',
      'lib/screens/rider_email_screen.dart',
    ]) {
      test('$p back arrow is root-safe', () {
        final src = read(p);
        expect(src, contains('onTap: () => onboardingBack(context),'));
        expect(src, isNot(contains('onTap: () => Navigator.of(context).pop(),')),
            reason: 'the splash boots INTO this step as the only route — a '
                'blind pop() leaves a black screen');
      });
    }

    test('onboardingBack falls back to the role picker', () {
      final src = read('lib/screens/onboarding_back.dart');
      expect(src, contains('Navigator.maybeOf(context)'));
      expect(src, contains('nav.canPop()'));
      expect(src, contains('const WelcomeScreen()'));
    });
  });

  group('A — reviewed / decided drivers skip the signup rungs', () {
    test('isPastSignupMap', () {
      for (final s in ['approved', 'pending', 'rejected', 'waitlist', 'PENDING ']) {
        expect(
          DriverWelcomeScreen.isPastSignupMap(
              {'verification_status': s, 'email': ''}),
          isTrue,
          reason: s,
        );
      }
      expect(DriverWelcomeScreen.isPastSignupMap({'is_verified': true}), isTrue);
      expect(DriverWelcomeScreen.isPastSignupMap({'verification_status': 'none'}),
          isFalse);
      expect(DriverWelcomeScreen.isPastSignupMap(const {}), isFalse);
    });

    test('phone-login routes a reviewed account before the email rung', () {
      final body = between(welcome, 'Future<void> _onLoggedIn() async {',
          'Widget build(BuildContext context)');
      final past = body.indexOf('DriverWelcomeScreen.isPastSignupMap(user)');
      final emailRung = body.indexOf('DriverEmailScreen(');
      expect(past, greaterThan(0));
      expect(past, lessThan(emailRung));
      expect(body.indexOf('if (isNewUser)'), lessThan(past),
          reason: 'a blank-name account still goes to the name page first');
    });

    test('splash resumes signup only for accounts never reviewed', () {
      final body = between(splash, "if (mode == 'driver') {",
          '// ── No cached status');
      expect(body, contains('DriverWelcomeScreen.pastSignupStatuses.contains(cachedStatus)'));
      // The ever-approved latch stays AFTER the waitlist branch
      // (driver_pending_reroute_guard_test) — not consulted here.
      expect(body.indexOf('final pastSignup'),
          lessThan(body.indexOf('_driverResumeScreen(')));
      expect(body, contains('if (!pastSignup) {'));
    });
  });

  group('B — 401s reach the refresh, request-level refusals do not end it', () {
    test('isSessionVerdict', () {
      // Token / account verdicts.
      expect(ApiService.isSessionVerdict(401, '{"detail":"Invalid token"}'), isTrue);
      expect(ApiService.isSessionVerdict(401, '{"detail":"Invalid or expired refresh token"}'),
          isTrue);
      expect(ApiService.isSessionVerdict(401, 'not json'), isTrue);
      expect(ApiService.isSessionVerdict(403, '{"detail":"Account blocked"}'), isTrue);
      expect(ApiService.isSessionVerdict(403, '{"detail":"account_revoked"}'), isTrue);
      // Request-level refusals: IP ban, signed-request gate.
      expect(ApiService.isSessionVerdict(403, '{"detail":"Access denied"}'), isFalse);
      expect(ApiService.isSessionVerdict(403, '{"error":"Access denied"}'), isFalse);
      expect(ApiService.isSessionVerdict(401, '{"detail":"Timestamp expired"}'), isFalse);
      expect(ApiService.isSessionVerdict(401, '{"detail":"Replay detected"}'), isFalse);
      expect(ApiService.isSessionVerdict(401, '{"detail":"Invalid signature"}'), isFalse);
      expect(ApiService.isSessionVerdict(500, '{}'), isFalse);
    });

    test('refresh, isTokenValid and getAccountStatus use the verdict', () {
      final refresh = between(api, 'static Future<bool?> refreshAccessToken()',
          'static Future<void> clearToken()');
      expect(refresh, contains('isSessionVerdict(res.statusCode, res.body)'));
      final valid = between(api, 'static Future<bool?> isTokenValid()',
          'static Map<String, dynamic>? _dashboardCache');
      expect(valid, contains('if (!isSessionVerdict(res.statusCode, res.body)) return null;'));
      final status = between(api, 'static Future<String> getAccountStatus()',
          'PHOTO  ENDPOINTS');
      expect(status, contains('if (refreshed == false) {'));
      expect(status, contains('await _endSession();'));
    });

    test('the silent pollers signal their 401', () {
      for (final anchor in const [
        "'\$_baseUrl/auth/dashboard'",
        "'\$_baseUrl/dispatch/available?driver_id=\$driverId'",
        "'\$_baseUrl/scheduled-trips/available?\$qs'",
        "Uri.parse('\$_baseUrl/notifications'),",
      ]) {
        final a = api.indexOf(anchor);
        expect(a, greaterThan(0), reason: anchor);
        final slice = api.substring(a, a + 700);
        expect(slice, contains('_signal401(res);'), reason: anchor);
      }
      final sig = between(api, 'static void _signal401(http.Response res) {',
          '/// Attempt to refresh');
      expect(sig, contains("headers['Authorization']"));
      expect(sig, contains('_handleUnauthorized().ignore();'));
      expect(sig, contains("'Timestamp expired'"));
    });

    test('register() stores the refresh token the backend returns', () {
      final reg = between(api, 'static Future<Map<String, dynamic>> register(',
          'static Future<Map<String, dynamic>> sendOtp(');
      expect(reg, contains("await _saveRefreshToken(data['refresh_token'] as String);"));
    });
  });

  group('C — account rejection opens the rejected page live', () {
    test('to-do hub: socket + poll route a rejection to the rejected page', () {
      final push = between(todo, 'void _onStatusPush(', 'Future<void> _checkApproval()');
      expect(push, contains('_goRejected(reason:'));
      expect(push, contains("data['item']"),
          reason: 'a one-document rejection still only re-lists the cards');
      final poll = between(todo, 'Future<void> _checkApproval()', 'bool _navigatedToApproved');
      expect(poll, contains("} else if (s == 'rejected') {\n        // Same rule"));
      expect(poll, contains('_goRejected();'));
      final go = between(todo, 'void _goRejected(', 'Future<void> _load()');
      expect(go, contains('DriverWaitlistScreen.rejected('));
      expect(go, contains('Navigator.maybeOf(context)'));
      expect(go, contains("setDriverApprovalStatus('rejected')"));
    });

    test('main.dart: no duplicate page, waits for the splash on cold start', () {
      final h = between(mainDart, 'void _handleAccountRejected(', 'void main()');
      expect(h, contains('DriverWaitlistScreen.liveRejected > 0'));
      expect(h, contains('_isSplashOnTop(nav)'));
      expect(waitlist, contains('static int liveRejected = 0;'));
      expect(waitlist, contains('if (widget.startsRejected) DriverWaitlistScreen.liveRejected++;'));
      expect(waitlist, contains('if (widget.startsRejected) DriverWaitlistScreen.liveRejected--;'));
    });
  });
}
