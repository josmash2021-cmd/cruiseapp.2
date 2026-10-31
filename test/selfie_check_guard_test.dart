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
    expect(screen, isNot(contains('_shotFlash')),
        reason: 'the capture flash died with the license-capture redesign — '
            'the verifying view IS the feedback (owner spec 2026-10-23)');
    expect(screen, contains('_uploadAndVerify(xFile.path)'),
        reason: 'the capture no longer pops — the screen uploads and holds '
            'the verifying loader (owner spec 2026-10-23)');
    expect(screen, contains('Navigator.of(context).pop(null)'),
        reason: 'cancel pops null — the GO call sites read that as no-GO');
  });

  test('step 3 verifying: the page holds until dispatch decides', () {
    // Owner spec 2026-10-23, literal: "no se cerrara y aparecera un loading
    // diciendo estan verificando… y en lo que dispatch apruebe se cerrara ya
    // activando al driver — no 1-3 s en el home y luego se activa".
    expect(screen, contains('backgroundColor: _navy,'),
        reason: 'the camera step is navy like the license page, never '
            'full-bleed black');
    expect(screen, contains('2 => _buildVerifying()'));
    expect(screen, contains('ApiService.submitFaceCheck(photoPath, bytes: bytes)'),
        reason: 'the upload moved INSIDE the screen');
    expect(screen, contains("resp['pending_review'] != true"),
        reason: 'auto-approve pops approved on the spot');
    expect(screen, contains('SocketService.faceCheckReviewStream.listen'),
        reason: 'the live socket answers instantly');
    expect(screen, contains('Timer.periodic(const Duration(seconds: 5)'),
        reason: 'REST poll as the net under a dead socket');
    expect(screen, contains("r['face_check_pending'] == true"),
        reason: 'still pending = still waiting');
    expect(screen, contains('Timer(const Duration(seconds: 90)'),
        reason: 'the 90 s ceiling — nobody is trapped on the loader');
    expect(screen, contains("if (approved == null) 'pending': true else 'approved': approved"),
        reason: 'the three-way result contract');
    // 2026-10-31: during the UPLOAD the X cancels (pop null = no GO);
    // only the real manual-review wait pops pending. Popping pending from
    // the upload parked Fabio on a grey "en revisión" GO nobody reviewed.
    expect(screen,
        contains('onPressed: _uploading ? _cancelUpload : () => _finishReview(null),'),
        reason: 'the escape X: cancel while uploading, pending in review');
    expect(screen, contains('s.faceCheckVerifyingTitle'));
    expect(screen, contains('s.faceCheckVerifyingBody'),
        reason: '"revisando… vestimenta correcta y profesional"');
    for (final g in [
      "String get faceCheckVerifyingTitle =>",
      "String get faceCheckVerifyingBody =>",
      'vestimenta correcta y profesional',
      'professional attire rules',
    ]) {
      expect(l10n, contains(g), reason: 'missing: $g');
    }
  });

  test('the known camera traps are pinned in place', () {
    expect(screen, isNot(contains('ResolutionPreset.max')),
        reason: 'NEVER max — the .max still closes the app on iOS 16+ '
            '(native NSException)');
    expect(screen, contains('AppPlatform.isIOS ? ResolutionPreset.veryHigh : ResolutionPreset.high'),
        reason: 'iOS 1080p since 2026-10-31 (4K made the pure-Dart downscale '
            'crawl on older iPhones — "se queda cargando"); Android high '
            'since 2026-10-29 (a full-sensor max shot blew the 5 MB cap)');
    expect(screen, contains('final c = _ctrl;\n    _ctrl = null;\n    c?.dispose();'),
        reason: 'dispose null-swap — the route exit animation rebuilds '
            'AFTER dispose (Crashlytics 2026-10-17)');
    expect(screen, contains('_initialized && _ctrl != null\n        ? FittedBox('),
        reason: 'build never touches a disposed controller (the preview '
            'ternary gates on it)');
    expect(screen, contains('if (!mounted) return;'),
        reason: 'the init retry checks mounted after the delay');
    expect(screen, isNot(contains('_cornerAnim')),
        reason: 'the corner machinery died with the license-capture redesign '
            '(2026-10-23) — no frame overlay at all');
    expect(screen, contains('faceCheckFrameHint'));
    expect(screen, contains('cameraPermissionPermanentlyDenied'),
        reason: 'the scanner\u2019s permanently-denied dialog, then pop null');
  });

  test('step 2 wears the LICENSE-CAPTURE design (owner spec 2026-10-23)', () {
    // "Así debe ser cuando se van a tomar la foto" — the SAME layout as the
    // registration's license photo page (license_capture_screen.dart): the
    // rounded preview card, X INSIDE the frame, copy below, gold shutter +
    // flash toggle. The scanner frame/corners overlay died here.
    expect(screen, contains('height: size.height * 0.57'),
        reason: 'the rounded preview card takes ~57% of the screen');
    expect(screen, contains('BorderRadius.circular(20)'),
        reason: 'the license page\u2019s card radius');
    expect(screen, contains('top: 12,\n                    left: 12,'),
        reason: 'the X rides inside the preview card');
    expect(screen, contains('s.selfieVerifyTitle'),
        reason: 'the title below the preview');
    expect(screen, contains('s.faceCheckFrameHint'));
    expect(screen, contains('onTap: _toggleFlash'),
        reason: 'the flash toggle is back, in the capture page\u2019s spot');
    expect(screen, contains('Icons.flash_off_rounded'));
    expect(screen, isNot(contains('_FaceCornerPainter')),
        reason: 'no frame corners in this design');
    expect(screen, isNot(contains('const Spacer(),\n                  Text(')),
        reason: 'the scanner top bar died — the title lives below the card');
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

  test('the new l10n strings exist ES/EN', () {
    expect(l10n,
        contains("String get faceCheckTakeSelfie => _es ? 'Tomar selfie' : 'Take a selfie';"));
    expect(l10n, contains('buena iluminación'));
    expect(l10n, contains('clear, centered, and well-lit'));
    // Owner spec 2026-10-23: "todas las páginas de verificación de selfie
    // digan mejor verificación facial".
    expect(l10n, contains("'Verificación facial'"));
    expect(l10n, contains("'Facial Verification'"));
    expect(l10n, isNot(contains("'Verificación de selfie'")),
        reason: 'the old title died on every selfie-verification page');
    expect(l10n, isNot(contains("'Selfie Verification'")));
  });

  test('2026-10-31: no wait in the selfie flow is unbounded', () {
    // "se toman la selfie y se queda cargando" (Fabio, iOS 26.5.2).
    expect(screen,
        contains('takePicture().timeout(const Duration(seconds: 10))'),
        reason: 'a camera that never hands the shot back resets the shutter');
    expect(screen, contains('S.of(context).faceCheckShotFailed'));
    expect(screen, contains('.timeout(const Duration(seconds: 12));'),
        reason: 'past 12 s the downscale is skipped, the shot goes raw');
    expect(screen, contains('void _cancelUpload()'));
    expect(screen, contains("'face_check', '\$outcome"),
        reason: 'every attempt reports its timings to the server log');
    expect(l10n, contains('String get faceCheckShotFailed =>'));
  });
}

