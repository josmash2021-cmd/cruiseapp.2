import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Guardian for the 2026-10-29 session fixes (driver reports on Android:
/// "me pide la selfie en cada GO", "error al iniciar sesión", "cerrar y
/// abrir la app me saca y queda negro").
///
/// The access token expires after 24 h; the first call of the day answers
/// 401 and the app refreshes. The refresh used to be a bool — a timeout, a
/// 429 from the per-IP auth bucket or a 5xx all read as "refresh token
/// REJECTED", which cleared the token (isTokenValid → false → background
/// logout) or fired onUnauthorized whose "already on auth" test was
/// `route.isFirst` — true for Home after the splash's pushReplacement — so
/// nobody navigated and the driver sat on Home firing 401s at every poll.
/// The daily selfie, shot at ResolutionPreset.max on Android, blew the
/// backend's 5 MB body cap (413) and the GO fell open silently with no
/// stamp, so it came back on every connect.
void main() {
  final api = File('lib/services/api_service.dart').readAsStringSync();
  final socket = File('lib/services/socket_service.dart').readAsStringSync();
  final mainDart = File('lib/main.dart').readAsStringSync();
  final splash = File('lib/screens/splash_screen.dart').readAsStringSync();
  final selfie =
      File('lib/screens/driver/selfie_check_screen.dart').readAsStringSync();
  final offline = File('lib/screens/driver/driver_online_offline.dart')
      .readAsStringSync();
  final l10n = File('lib/l10n/app_localizations.dart').readAsStringSync();

  // Plain throws (not expect): some slices are cut at group level, where
  // expect() is not allowed.
  String between(String src, String start, String end) {
    final a = src.indexOf(start);
    if (a < 0) throw StateError('missing "$start"');
    final b = src.indexOf(end, a + start.length);
    if (b < 0) throw StateError('missing "$end" after "$start"');
    return src.substring(a, b);
  }

  group('refreshAccessToken is tri-state', () {
    final body = between(api, 'static Future<bool?> refreshAccessToken()',
        'static Future<void> clearToken()');

    test('the completer carries bool? and only 401/403 answer false', () {
      expect(api, contains('static Completer<bool?>? _refreshCompleter;'));
      expect(body, contains('if (res.statusCode == 401 || res.statusCode == 403)'));
      final rejected = between(body,
          'if (res.statusCode == 401 || res.statusCode == 403)', 'inconclusive (HTTP');
      expect(rejected, contains('_refreshCompleter!.complete(false);'));
      expect(rejected, contains('return false;'));
    });

    test('429 / 5xx / any other status is inconclusive (null)', () {
      final other = between(body, 'inconclusive (HTTP', '} catch (e) {');
      expect(other, contains('_refreshCompleter!.complete(null);'));
      expect(other, contains('return null;'));
      expect(other, isNot(contains('complete(false)')));
    });

    test('timeout / network error is inconclusive (null), with the reason logged', () {
      final caught = between(body, '} catch (e) {', '} finally {');
      expect(caught, contains("debugPrint('[Api] refresh inconclusive"));
      expect(caught, contains('_refreshCompleter!.complete(null);'));
      expect(caught, contains('return null;'));
      expect(caught, isNot(contains('complete(false)')),
          reason: 'a dropped connection is not a verdict on the session');
    });

    test('every bool? consumer compares against true explicitly', () {
      // getMe / account-status auto-refresh + both socket paths.
      expect(RegExp(r'if \(refreshed\) \{').allMatches(api), isEmpty,
          reason: 'a bare `if (refreshed)` no longer compiles against bool?');
      expect(RegExp(r'if \(refreshed\) \{').allMatches(socket), isEmpty);
      expect('if (refreshed == true) {'.allMatches(socket).length, 2);
    });
  });

  group('a 401 only ends the session on a definitive refresh rejection', () {
    test('isTokenValid returns null when the refresh is inconclusive', () {
      final body = between(api, 'static Future<bool?> isTokenValid()',
          'Get dashboard data');
      expect(body, contains('if (refreshed == null) return null;'));
      expect(body, contains('if (!refreshed) return false;'));
      expect(body.indexOf('if (refreshed == null) return null;'),
          lessThan(body.indexOf('if (!refreshed) return false;')));
    });

    test('_handleUnauthorized clears the token only on `false`', () {
      final body = between(api, 'static Future<void> _handleUnauthorized()',
          'static Future<bool?> refreshAccessToken()');
      expect(body, contains('if (refreshed == false) {'));
      expect(body, isNot(contains('if (!refreshed)')));
      final clearing = between(body, 'if (refreshed == false) {', '} else if');
      expect(clearing, contains('await clearToken();'));
      expect(clearing, contains('onUnauthorized?.call();'));
      expect(body, contains('else if (refreshed == null)'));
    });
  });

  group('onUnauthorized decides "already on auth" by route NAME, not isFirst', () {
    final body = between(mainDart, 'ApiService.onUnauthorized = () async {',
        'ApiService.onTokenSaved = () {');

    test('route.isFirst is gone from the guard', () {
      expect(body, isNot(contains('route.isFirst')),
          reason: 'Home is the first route after the splash pushReplacement');
      expect(body, contains('isAuthRouteName(route.settings.name)'));
    });

    test('the splash/welcome/login names are the recognised auth routes', () {
      final helper = between(splash, 'bool isAuthRouteName(String? name)', '}');
      expect(helper, contains("name == '/'"));
      expect(helper, contains('name == splashRouteName'));
      expect(helper, contains('name == welcomeRouteName'));
      expect(helper, contains("name.startsWith('/login')"));
      expect(splash, contains("const String splashRouteName = '/splash';"));
      expect(splash, contains("const String welcomeRouteName = '/welcome';"));
    });

    test('every Splash push in main.dart is named', () {
      final pushes = 'pageBuilder: (_, __, ___) => const SplashScreen(),'
          .allMatches(mainDart)
          .length;
      expect(pushes, 3);
      expect('settings: const RouteSettings(name: splashRouteName),'
              .allMatches(mainDart).length,
          pushes,
          reason: 'an unnamed Splash route would fail the auth test again');
    });

    test('the splash names its own hand-over (welcome vs home)', () {
      expect(
          'name: destination is WelcomeScreen'.allMatches(splash).length, 2);
    });
  });

  group('session-replaced dialog opens once and never pops the Splash', () {
    final body = between(mainDart, 'ApiService.onSessionExpiredNewDevice = () {',
        'ApiService.onAccountTerminated = () {');

    test('a guard flag admits one dialog at a time', () {
      expect(mainDart, contains('bool _sessionExpiredDialogOpen = false;'));
      expect(body, contains('if (_sessionExpiredDialogOpen) return;'));
      expect(body, contains('_sessionExpiredDialogOpen = true;'));
      expect(body, contains('.whenComplete(() => _sessionExpiredDialogOpen = false);'));
    });

    test('the dialog closes through its own context, never a blind overlay pop', () {
      expect(body, contains('builder: (dialogContext) => AlertDialog('));
      expect(body, contains('Navigator.of(dialogContext).pop();'));
      expect(body, isNot(contains('Navigator.of(nav.overlay!.context).pop()')));
      expect(body, isNot(contains('nav.overlay!')),
          reason: 'overlay is read with ?. and bails when absent');
    });
  });

  group('the daily selfie lands under the 5 MB body cap', () {
    test('Android captures at high, iOS keeps ultraHigh (never max)', () {
      expect(selfie,
          contains('AppPlatform.isIOS ? ResolutionPreset.ultraHigh : ResolutionPreset.high;'));
      expect(selfie, isNot(contains('ResolutionPreset.max')));
    });

    test('the shot is downscaled off the UI thread before the base64', () {
      expect(selfie, contains('const int kSelfieUploadMaxSide = 1280;'));
      expect(selfie, contains('const int kSelfieUploadJpegQuality = 85;'));
      expect(selfie, contains('await compute(_shrinkSelfieForUpload, photoPath)'));
      // '\n}' = the first top-level closing brace after the signature
      // (CRLF-safe: "\r\n}" still contains "\n}").
      final shrink = between(selfie, 'Uint8List _shrinkSelfieForUpload(String path)', '\n}');
      expect(shrink, contains('img.bakeOrientation(decoded)'));
      expect(shrink, contains('img.copyResize('));
      expect(shrink, contains('img.encodeJpg(resized, quality: kSelfieUploadJpegQuality)'));
      expect(selfie, contains('ApiService.submitFaceCheck(photoPath, bytes: bytes)'));
    });

    test('the upload waits 60 s and reports status/detail instead of a bare null', () {
      final body = between(api, 'static Future<Map<String, dynamic>?> submitFaceCheck(',
          'Check if driver can go online');
      expect(body, contains('.timeout(const Duration(seconds: 60))'));
      expect(body, isNot(contains('if (res.statusCode != 200) return null;')));
      expect(body, contains("return {'ok': false, 'status': res.statusCode, 'detail': detail};"));
      expect(body, contains("return {'ok': false, 'status': 0, 'detail': '\${e.runtimeType}: \$e'};"));
    });

    test('a failed upload is logged and told to the driver, GO still fail-open', () {
      expect(selfie, contains("if (resp == null || resp['ok'] == false) {"));
      expect(selfie, contains("Navigator.of(context).pop({'photo': photoPath, 'error': reason});"));
      final go = between(offline, "if (res['approved'] == true) {", 'The flip itself');
      expect(go, contains("[DriverOnline] face-check upload failed"));
      expect(go, contains('ScaffoldMessenger.maybeOf(context)?.showSnackBar('),
          reason: 'maybeOf outside build (CLAUDE.md #26)');
      expect(go, contains('S.of(context).faceCheckUploadFailed'));
      expect(l10n, contains('String get faceCheckUploadFailed'));
      expect(l10n, contains("'No se pudo verificar la selfie, se volverá a pedir'"));
      expect(l10n, contains("'The selfie could not be verified, it will be asked again'"));
    });
  });

  group('Android activity theme is what flutter_stripe requires', () {
    for (final path in [
      'android/app/src/main/res/values/styles.xml',
      'android/app/src/main/res/values-night/styles.xml',
    ]) {
      test(path, () {
        final xml = File(path).readAsStringSync();
        expect('parent="Theme.MaterialComponents.DayNight.NoActionBar"'
                .allMatches(xml).length,
            2,
            reason: 'LaunchTheme and NormalTheme both need a MaterialComponents parent');
        expect(xml, isNot(contains('@android:style/Theme.')));
        expect('@drawable/launch_background'.allMatches(xml).length, 2,
            reason: 'the launch drawable entries survive the parent change');
      });
    }
  });
}
