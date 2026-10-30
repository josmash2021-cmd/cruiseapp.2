import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Guardian for the Android launch window + intro videos (2026-10-29,
/// Android report: black splash, frozen welcome video, buttons "dead").
///
///   1. Every Android theme folder keeps the black launch_background. The
///      theme PARENTS are left as the owner wants them (2026-10-29: "déjalo
///      como está" — the v31 folders stay on their original parents; the
///      bank flow on Android does not use the Stripe sheet).
///   2. Neither the splash nor the welcome video can hold the screen
///      hostage: bounded initialize(), a stall watchdog, and a drop path
///      that frees the decoder and falls back to logo / poster.
///   3. The welcome role buttons never depend on the video being ready.
void main() {
  const res = 'android/app/src/main/res';

  group('Android themes', () {
    for (final dir in const [
      'values',
      'values-night',
      'values-v31',
      'values-night-v31',
    ]) {
      test('$dir: launch_background on both themes', () {
        final xml = File('$res/$dir/styles.xml').readAsStringSync();
        for (final name in const ['LaunchTheme', 'NormalTheme']) {
          final m = RegExp('<style name="$name" parent="([^"]+)">'
                  r'([\s\S]*?)</style>')
              .firstMatch(xml);
          expect(m, isNotNull, reason: '$dir/$name missing');
          expect(
              m!.group(2)!.contains(
                  '<item name="android:windowBackground">@drawable/launch_background</item>'),
              isTrue,
              reason: '$dir/$name must keep the black launch window');
        }
      });
    }

    test('launch_background stays black', () {
      final colors = File('$res/values/colors.xml').readAsStringSync();
      expect(colors.contains('<color name="splash_bg">#FF000000</color>'),
          isTrue);
      for (final d in const ['drawable', 'drawable-v21']) {
        final xml = File('$res/$d/launch_background.xml').readAsStringSync();
        expect(xml.contains('@color/splash_bg'), isTrue);
      }
    });
  });

  group('videos never hold the screen hostage', () {
    for (final entry in const {
      'lib/screens/splash_screen.dart': 'Duration(seconds: 4)',
      'lib/screens/welcome_screen.dart': 'Duration(seconds: 6)',
    }.entries) {
      test(entry.key, () {
        final src = File(entry.key).readAsStringSync();
        expect(src.contains('initialize().timeout(const ${entry.value})'),
            isTrue,
            reason: 'a decoder that never answers must not hang the screen');
        expect(src.contains('_videoStallTimer = Timer(_videoStallTimeout'),
            isTrue,
            reason: 'a clip that never advances must be dropped');
        expect(src.contains('v.value.position > Duration.zero'), isTrue);
        expect(src.contains('c.value.hasError'), isTrue,
            reason: 'a mid-playback decoder error drops the clip too');
        final drop = src.substring(src.indexOf('void _dropVideo('));
        expect(drop.contains('c.dispose()'), isTrue,
            reason: 'free the decoder');
        expect(drop.contains('_videoReady = false'), isTrue,
            reason: 'fall back to the logo / poster');
        expect(src.contains('_videoStallTimer?.cancel();'), isTrue);
      });
    }

    test('splash: a dropped clip releases the navigation wait', () {
      final src =
          File('lib/screens/splash_screen.dart').readAsStringSync();
      final drop = src.substring(src.indexOf('void _dropVideo('));
      expect(
          drop.contains(
              'if (!_firstLoopDone.isCompleted) _firstLoopDone.complete();'),
          isTrue);
    });

    test('welcome: role buttons are never gated on the video', () {
      final src =
          File('lib/screens/welcome_screen.dart').readAsStringSync();
      final buttons = src.substring(src.indexOf('// ── Role buttons'));
      expect(buttons.contains('_videoReady'), isFalse);
      expect(src.contains('IgnorePointer'), isFalse);
      expect(src.contains('AbsorbPointer'), isFalse);
      expect(src.contains('assets/images/welcome_bg_poster.png'), isTrue,
          reason: 'the poster is the fallback background');
    });
  });

  // Android 1.1.7+748: the 747 splash/welcome froze the whole screen on
  // Android only. Impeller stays off there until proven fixed.
  test('Android runs without Impeller', () {
    final m = File('android/app/src/main/AndroidManifest.xml').readAsStringSync();
    expect(
        RegExp(r'android:name="io\.flutter\.embedding\.android\.EnableImpeller"\s*android:value="false"')
            .hasMatch(m),
        isTrue);
  });

  // 2026-10-29: logged-out boot on Android read as black.
  group('logged-out intro', () {
    final splash = File('lib/screens/splash_screen.dart')
        .readAsStringSync()
        .replaceAll('\r\n', '\n');
    final run = splash.substring(splash.indexOf('Future<void> _runSequence()'));
    test('the video starts before the update gate is awaited', () {
      final video = run.indexOf('unawaited(_initVideo());');
      final gate = run.indexOf('final gate = await updateGate;');
      expect(video, isNonNegative);
      expect(video, lessThan(gate));
      expect('unawaited(_initVideo());'.allMatches(splash).length, 1);
    });
    test('permissions are not asked over the logged-out splash', () {
      final perm = run.indexOf('unawaited(_requestFirstRunPermissions());');
      final session = run.indexOf('loggedIn = await UserSession.isLoggedInLocal();');
      expect(perm, greaterThan(session));
      expect(run.substring(session, perm), contains('if (!loggedIn) {'));
      expect(run.substring(session, perm), contains('} else {'),
          reason: 'permissions only in the logged-in branch');
    });
    test('welcome asks them once its clip plays, then resumes it', () {
      final w = File('lib/screens/welcome_screen.dart').readAsStringSync();
      expect(w, contains('unawaited(_askFirstRunPermissions());'));
      expect(w, contains('Permission.locationWhenInUse.request()'));
      expect(w, contains('Permission.notification.request()'));
      expect(w, contains('v.play()'));
    });
  });
}
