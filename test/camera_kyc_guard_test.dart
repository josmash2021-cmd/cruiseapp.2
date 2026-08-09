import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Guardian for the camera KYC fixes: face liveness on iOS (rotation and
/// preview sizing), document scanner capture resolution, and the
/// pending-review copy.
///
/// The camera paths need a live device, so what a unit test CAN pin is the
/// wiring, the same way picker_camera_guard_test.dart does: the iOS branch
/// of _rotationDegrees, the displayedFrameSize helper and both call sites,
/// the capture preset of both document scanners, and the review text.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final face =
      File('lib/screens/face_liveness_screen.dart').readAsStringSync();
  final fit = File('lib/utils/face_oval_fit.dart').readAsStringSync();

  group('iOS streams upright — no double rotation', () {
    test('_rotationDegrees returns 0 on iOS', () {
      final fn = RegExp(r'int _rotationDegrees\(\) \{');
      final start = fn.firstMatch(face)!.end;
      final body = face.substring(start, start + 900);
      expect(body.contains('if (!AppPlatform.isAndroid) return 0;'), isTrue,
          reason: 'iOS buffers arrive natively rotated; passing the sensor '
              'angle double-rotates the frame and ML Kit sees the face '
              'sideways — the "Center your face" that never cleared');
      expect(body.contains('sensorOrientation'), isTrue,
          reason: 'the Android branch still needs the sensor angle');
    });
  });

  group('displayedFrameSize is the single frame decision', () {
    test('the helper lives in face_oval_fit.dart', () {
      expect(fit.contains('Size displayedFrameSize({'), isTrue);
    });

    test('_framingFor maps face boxes through it', () {
      final fn =
          RegExp(r'_FaceFeedback _framingFor\(Face face, CameraImage img\) \{');
      final start = fn.firstMatch(face)!.end;
      final body = face.substring(start, start + 1400);
      expect(body.contains('displayedFrameSize('), isTrue,
          reason: 'mapping a stream-space box against the wrong frame is '
              'the ~1.33× "too close" bug');
    });

    test('_buildCameraFill sizes the preview through it', () {
      final fn = RegExp(r'Widget _buildCameraFill\(\) \{');
      final start = fn.firstMatch(face)!.end;
      final body = face.substring(start, start + 1400);
      expect(body.contains('displayedFrameSize('), isTrue,
          reason: 'sizing the FittedBox child from previewSize is the '
              '~1.33× preview zoom on iOS');
      expect(body.contains('_streamFrameSize'), isTrue,
          reason: 'the real texture size comes from the first stream frame');
    });
  });

  group('document scanners capture at full resolution', () {
    for (final path in [
      'lib/screens/identity_verification_screen.dart',
      'lib/screens/driver/license_scanner_screen.dart',
    ]) {
      test('$path uses ResolutionPreset.max, never high', () {
        final src = File(path).readAsStringSync();
        expect(src.contains('ResolutionPreset.high'), isFalse,
            reason: 'high = 720p stills; the document-frame crop lands '
                '~485×306 px and OCR reads nothing');
        expect(
          'ResolutionPreset.max'.allMatches(src).length,
          greaterThanOrEqualTo(2),
          reason: 'both the first attempt and the retry must capture at max',
        );
      });
    }
  });

  group('pending review copy', () {
    test('no "dispatch team" in the rider-facing text', () {
      final src = File('lib/screens/identity_verification_screen.dart')
          .readAsStringSync();
      expect(
        src.contains('Our dispatch team is reviewing your documents.'),
        isFalse,
      );
      expect(src.contains('Our team is reviewing your documents.'), isTrue);
    });
  });
}
