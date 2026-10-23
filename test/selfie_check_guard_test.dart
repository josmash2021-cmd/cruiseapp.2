import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Guardian for the 24 h GO selfie check (owner spec 2026-10-23): NOT the
/// 4-step biometric liveness page — step 1 is the guide's instruction card
/// (shared SelfieVerifyCard), step 2 a FRONT-camera manual still with the
/// license scanner's frame design. Output contract: `{'photo': path}` on
/// success, null on cancel.
void main() {
  final screen = File('lib/screens/driver/selfie_check_screen.dart')
      .readAsStringSync()
      .replaceAll('\r\n', '\n');
  final card = File('lib/widgets/selfie_verify_card.dart')
      .readAsStringSync()
      .replaceAll('\r\n', '\n');
  final guide =
      File('lib/screens/driver/onboarding/first_trip_guide_screen.dart')
          .readAsStringSync()
          .replaceAll('\r\n', '\n');
  final offline = File('lib/screens/driver/driver_online_offline.dart')
      .readAsStringSync()
      .replaceAll('\r\n', '\n');
  final driverScreen = File('lib/screens/driver/driver_online_screen.dart')
      .readAsStringSync()
      .replaceAll('\r\n', '\n');
  final l10n = File('lib/l10n/app_localizations.dart')
      .readAsStringSync()
      .replaceAll('\r\n', '\n');

  test('step 1 is the shared instruction card, BEFORE any camera', () {
    expect(screen, contains("int _step = 0;"),
        reason: 'the instructions come first');
    expect(screen, contains('SelfieVerifyCard('),
        reason: 'the SAME card as guide page 6 — one design source');
    expect(screen, contains('flash: false'),
        reason: 'the shutter flash stays guide-only');
    expect(screen, contains('s.selfieVerifyTitle'));
    expect(screen, isNot(contains('s.selfieVerifyEvery24h')),
        reason: 'owner spec 2026-10-23: the "Every 24 hours" subtitle died '
            'on the selfie-check screen (the guide page 6 keeps it)');
    expect(screen, contains('_vip ? s.selfieBodyVip : s.selfieBodyStd'));
    expect(screen, contains('s.faceCheckTakeSelfie'),
        reason: 'the gold full-width button opens step 2');
    // The camera wakes ONLY when step 2 opens.
    final openFn = screen.indexOf('void _openCamera()');
    final initFn = screen.indexOf('Future<void> _initCamera()');
    expect(screen.indexOf('_initCamera()', openFn), greaterThan(openFn));
    expect(screen.substring(0, openFn).contains('Permission.camera.request()'),
        isFalse,
        reason: 'no camera permission prompt on the instructions card');
    expect(initFn, greaterThan(-1));
  });

  test('the shared card is used by BOTH the guide and the check', () {
    expect(guide, contains('SelfieVerifyCard('));
    expect(guide, contains('flash: true'),
        reason: 'the guide keeps the flash through the card flag');
    expect(card, contains('guide_selfie_\${widget.variant}.png'));
    expect(card, contains('s.selfieChipFaceVisible'));
    expect(card, contains('s.selfieChipNoGlasses'),
        reason: 'the 4 chips with caption under the icon');
    expect(card, contains('Widget icon'),
        reason: 'icons arrive as full const Icon widgets at the call sites '
            '(loose IconData tree-shakes to "?" in release — cured on '
            'device 2026-10-23, never reintroduce)');
    expect(card, isNot(contains('IconData icon')));
  });

  test('the variant resolves through the one shared helper', () {
    expect(screen, contains('resolveSelfieVariant()'));
    expect(guide, contains('resolveSelfieVariant()'));
    final util = File('lib/utils/selfie_variant.dart')
        .readAsStringSync()
        .replaceAll('\r\n', '\n');
    expect(util, contains("u?['gender'] == 'female'"));
    expect(util, contains("tier == 'vip' || tier == 'black'"));
    expect(util, contains("'\${vip ? 'vip' : 'std'}_\${female ? 'f' : 'm'}'"),
        reason: 'fail-soft std_m');
  });

  test('step 2: front camera, manual capture, no ML Kit / OCR / stream', () {
    expect(screen, contains('CameraLensDirection.front'));
    expect(screen, contains('firstWhere('),
        reason: 'front first, orElse the first camera');
    expect(screen, isNot(contains('google_mlkit')),
        reason: 'no ML Kit import in this screen');
    expect(screen, isNot(contains('TextRecognizer')));
    expect(screen, isNot(contains('startImageStream')),
        reason: 'no image stream, no auto-capture');
    expect(screen, contains('takePicture()'),
        reason: 'manual capture on the gold shutter tap');
    expect(screen, contains('HapticService.mediumImpact();'));
    expect(screen, contains('_shotFlash.forward(from: 0)'),
        reason: 'brief white flash as capture feedback');
    expect(screen, contains("Navigator.of(context).pop({'photo': xFile.path})"),
        reason: 'the output contract is identical to the old flow');
    expect(screen, contains('Navigator.of(context).pop(null)'),
        reason: 'cancel pops null — the GO call sites read that as no-GO');
  });

  test('the known camera traps are pinned in place', () {
    expect(screen, contains('ResolutionPreset.ultraHigh'),
        reason: 'iOS ultraHigh, NEVER max — the .max still closes the app '
            'on iOS 16+ (native NSException)');
    expect(screen, contains('AppPlatform.isIOS ? ResolutionPreset.ultraHigh : ResolutionPreset.max'),
        reason: 'Android keeps max; the doc-comment says why');
    expect(screen, contains('final c = _ctrl;\n    _ctrl = null;\n    c?.dispose();'),
        reason: 'dispose null-swap — the route exit animation rebuilds '
            'AFTER dispose (Crashlytics 2026-10-17)');
    expect(screen, contains('if (_initialized && _ctrl != null)'),
        reason: 'build never touches a disposed controller');
    expect(screen, contains('if (!mounted) return;'),
        reason: 'the init retry checks mounted after the delay');
    expect(screen, contains('_cornerAnim'),
        reason: 'the scanner\u2019s animated gold corners (1400 ms '
            'repeat-reverse)');
    expect(screen, contains('duration: const Duration(milliseconds: 1400)'));
    expect(screen, contains('faceCheckFrameHint'));
    expect(screen, contains('cameraPermissionPermanentlyDenied'),
        reason: 'the scanner\u2019s permanently-denied dialog, then pop null');
  });

  test('the GO call sites swapped to SelfieCheckScreen', () {
    expect(offline.split('const SelfieCheckScreen()').length, 3,
        reason: 'the daily gate AND _onFaceVerifyTap');
    expect(offline, isNot(contains('FaceLivenessScreen')));
    expect(driverScreen, contains("import 'selfie_check_screen.dart';"));
    expect(driverScreen,
        isNot(contains("import '../face_liveness_screen.dart';")),
        reason: 'face_liveness_screen.dart stays alive for the signup — '
            'only this import died');
  });

  test('the two new l10n strings exist ES/EN', () {
    expect(l10n,
        contains("String get faceCheckTakeSelfie => _es ? 'Tomar selfie' : 'Take a selfie';"));
    expect(l10n, contains('Centra tu rostro dentro del marco'));
    expect(l10n, contains('Center your face inside the frame'));
  });
}
