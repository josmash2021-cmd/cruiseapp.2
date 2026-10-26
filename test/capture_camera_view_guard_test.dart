import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Guardian for the shared capture camera (owner spec 2026-10-23: "así como
/// es esa cámara, así quiero que estén las demás — seguro, registración y
/// foto de perfil"): ONE design source (`CaptureCameraView`, the
/// license-capture layout) and every camera path routes through it — the
/// native camera app (ImageSource.camera) is gone from the driver docs
/// flows.
void main() {
  final view = File('lib/widgets/capture_camera_view.dart')
      .readAsStringSync()
      .replaceAll('\r\n', '\n');
  final docCapture =
      File('lib/screens/driver/onboarding/doc_capture_screen.dart')
          .readAsStringSync()
          .replaceAll('\r\n', '\n');
  final signup = File('lib/screens/driver/driver_signup_screen.dart')
      .readAsStringSync()
      .replaceAll('\r\n', '\n');
  final profile =
      File('lib/screens/driver/onboarding/profile_photo_capture_screen.dart')
          .readAsStringSync()
          .replaceAll('\r\n', '\n');
  final l10n = File('lib/l10n/app_localizations.dart')
      .readAsStringSync()
      .replaceAll('\r\n', '\n');

  test('the shared view IS the license-capture design', () {
    expect(view, contains('class CaptureCameraView'),
        reason: 'one design source for every capture camera');
    expect(view, contains('height: size.height * 0.57'),
        reason: 'the rounded preview card (~57% of the screen)');
    expect(view, contains('BorderRadius.circular(20)'));
    expect(view, contains('onTap: widget.onCancel'),
        reason: 'the X rides inside the frame');
    expect(view, contains('onTap: _toggleFlash'),
        reason: 'the flash toggle in the capture page spot');
    expect(view, contains('frontCamera'),
        reason: 'front for face photos, rear (default) for documents');
    expect(
        view,
        contains('static ResolutionPreset get _capturePreset =>'),
        reason: 'the app-wide preset rule lives here too');
    expect(view, contains('ResolutionPreset.ultraHigh'),
        reason: 'iOS ultraHigh, NEVER max (the .max crash on iOS 16+)');
    expect(view, contains('cameraPermissionPermanentlyDenied'),
        reason: 'the permanently-denied dialog, shared');
    expect(view, contains('NEVER copy this layout into another screen'),
        reason: 'the one-design-source rule stays written on it');
  });

  test('insurance/registration/inspection open the shared camera', () {
    expect(docCapture, contains('CaptureCameraView('),
        reason: 'DocCaptureScreen "Take photo" routes to the in-app camera');
    expect(docCapture, contains('_openInAppCamera'));
    expect(docCapture, isNot(contains('ImageSource.camera')),
        reason: 'the native camera app is gone from the docs hub');
    expect(signup, contains('CaptureCameraView('),
        reason: 'the legacy signup camera too');
    expect(signup, contains('_pickCamera(title)'),
        reason: 'the sheet title reaches the camera page');
    expect(signup, isNot(contains('source: ImageSource.camera')),
        reason: 'no native camera in signup either');
    expect(signup, contains('decoded.width < 640'),
        reason: 'the quality gate survives the switch');
  });

  test('the profile photo capture embeds the shared view (front lens)', () {
    expect(profile, contains('CaptureCameraView('));
    expect(profile, contains('frontCamera: true'));
    expect(profile, contains('s.captureProfilePhotoTitle'));
    expect(profile, contains('s.obPhotoGuide'));
    expect(profile, isNot(contains('CameraController(')),
        reason: 'the camera lifecycle lives inside the shared view now');
    expect(profile, isNot(contains('_permissionDenied')),
        reason: 'the shared view owns the denial path — no duplicate page');
  });

  test('the new l10n strings exist ES/EN', () {
    for (final g in [
      'String get captureDocHint =>',
      'String get captureProfilePhotoTitle =>',
      'completo, claro y con buena iluminación',
      'clear, well-lit, and easy to read',
      "'Toma tu foto de perfil'",
      "'Take your profile photo'",
    ]) {
      expect(l10n, contains(g), reason: 'missing: $g');
    }
  });
}
