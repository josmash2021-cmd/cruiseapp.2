import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';

import 'package:cruise_app/utils/face_oval_fit.dart';

/// The "is the face actually in the oval" check, pinned.
///
/// Before this existed the liveness screen only knew whether a face was
/// somewhere in frame, so a face twice the size of the oval and half off the
/// side of it still read as framed. The numbers below are the ones that stop
/// that, and they have to stay generous enough not to fail an honest driver.
void main() {
  // The oval as the screen draws it: 270x330 centred at 42% of the height.
  const screen = Size(390, 844);
  final oval = Rect.fromCenter(
    center: Offset(screen.width / 2, screen.height * 0.42),
    width: 270,
    height: 330,
  );

  Rect faceAt(Offset center, double width) => Rect.fromCenter(
        center: center,
        width: width,
        height: width * 1.25,
      );

  group('uprightFrameSize', () {
    test('swaps at a quarter turn, which is how a phone is held', () {
      expect(uprightFrameSize(const Size(640, 480), 90), const Size(480, 640));
      expect(uprightFrameSize(const Size(640, 480), 270), const Size(480, 640));
    });

    test('leaves it alone at 0 and 180', () {
      expect(uprightFrameSize(const Size(640, 480), 0), const Size(640, 480));
      expect(uprightFrameSize(const Size(640, 480), 180), const Size(640, 480));
    });

    test('normalises a degree count that wrapped or went negative', () {
      expect(uprightFrameSize(const Size(640, 480), 450), const Size(480, 640));
      expect(uprightFrameSize(const Size(640, 480), -90), const Size(480, 640));
    });
  });

  group('mapImageRectToScreen', () {
    // 480x640 upright frame covering a 390x844 screen: cover matches the
    // height, so the frame is scaled 844/640 and spills sideways.
    const upright = Size(480, 640);

    test('a box at the frame centre lands at the screen centre', () {
      final box = Rect.fromCenter(
        center: const Offset(240, 320),
        width: 100,
        height: 120,
      );
      final out = mapImageRectToScreen(box, upright, screen)!;
      expect(out.center.dx, closeTo(195, 0.01));
      expect(out.center.dy, closeTo(422, 0.01));
    });

    test('scales by the cover factor', () {
      final box = Rect.fromLTWH(0, 0, 100, 100);
      final out = mapImageRectToScreen(box, upright, screen)!;
      final expected = 844 / 640;
      expect(out.width, closeTo(100 * expected, 0.01));
      expect(out.height, closeTo(100 * expected, 0.01));
    });

    test('refuses degenerate and non-finite input instead of making NaN', () {
      final box = Rect.fromLTWH(0, 0, 10, 10);
      expect(mapImageRectToScreen(box, Size.zero, screen), isNull);
      expect(mapImageRectToScreen(box, upright, Size.zero), isNull);
      expect(
        mapImageRectToScreen(box, const Size(480, double.nan), screen),
        isNull,
      );
      expect(
        mapImageRectToScreen(
            const Rect.fromLTRB(0, 0, double.infinity, 10), upright, screen),
        isNull,
      );
    });
  });

  group('faceFitsOval accepts a properly framed face', () {
    test('dead centre, oval-sized', () {
      expect(faceFitsOval(faceAt(oval.center, 200), oval), isTrue);
    });

    test('a little off centre', () {
      expect(
        faceFitsOval(faceAt(oval.center.translate(40, -50), 200), oval),
        isTrue,
      );
    });

    test('across the whole range of reasonable sizes', () {
      for (final w in const [120.0, 160.0, 200.0, 240.0, 300.0]) {
        expect(faceFitsOval(faceAt(oval.center, w), oval), isTrue,
            reason: 'width $w');
      }
    });
  });

  group('faceFitsOval rejects what the old check let through', () {
    test('a face pressed against the lens', () {
      // The screenshot that started this: a face far wider than the oval,
      // which the old code called "Face detected".
      expect(faceFitsOval(faceAt(oval.center, 380), oval), isFalse);
    });

    test('a face too far away', () {
      expect(faceFitsOval(faceAt(oval.center, 90), oval), isFalse);
    });

    test('a face off to the side', () {
      expect(
        faceFitsOval(faceAt(oval.center.translate(120, 0), 200), oval),
        isFalse,
      );
    });

    test('a face above or below the oval', () {
      expect(
        faceFitsOval(faceAt(oval.center.translate(0, 130), 200), oval),
        isFalse,
      );
      expect(
        faceFitsOval(faceAt(oval.center.translate(0, -130), 200), oval),
        isFalse,
      );
    });

    test('an empty or nonsense box', () {
      expect(faceFitsOval(Rect.zero, oval), isFalse);
      expect(faceFitsOval(faceAt(oval.center, 200), Rect.zero), isFalse);
      expect(
        faceFitsOval(
            const Rect.fromLTRB(0, 0, double.nan, double.nan), oval),
        isFalse,
      );
    });
  });

  test('mirroring the front camera does not change the answer', () {
    // The preview is mirrored for a front camera and the oval is centred on
    // the screen, so containment is symmetric about the centre line. This is
    // why the screen never has to work out whether it is looking at a
    // mirrored frame — worth pinning, because it is load-bearing.
    for (final dx in const [-90.0, -40.0, 0.0, 40.0, 90.0, 160.0]) {
      final f = faceAt(oval.center.translate(dx, 0), 200);
      final mirrored = Rect.fromCenter(
        center: Offset(screen.width - f.center.dx, f.center.dy),
        width: f.width,
        height: f.height,
      );
      expect(faceFitsOval(f, oval), faceFitsOval(mirrored, oval),
          reason: 'dx $dx');
    }
  });

  group('displayedFrameSize', () {
    // iOS rotates the buffers natively, so the stream and the preview
    // texture are the same upright frame: the displayed frame IS the
    // stream frame, and previewSize must not enter into it.
    test('iOS shows the upright stream frame', () {
      expect(
        displayedFrameSize(
          streamed: const Size(480, 640),
          rotationDegrees: 0,
          preview: const Size(1920, 1080),
          isAndroid: false,
        ),
        const Size(480, 640),
      );
    });

    // Android draws the previewSize surface on its side; the stream is a
    // separate buffer and does not set what the person sees.
    test('Android shows the preview surface turned upright', () {
      expect(
        displayedFrameSize(
          streamed: const Size(640, 480),
          rotationDegrees: 90,
          preview: const Size(1280, 720),
          isAndroid: true,
        ),
        const Size(720, 1280),
      );
    });
  });
}
