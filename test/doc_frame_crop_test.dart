import 'dart:typed_data';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import 'package:cruise_app/utils/doc_frame_crop.dart';

/// The document scanner's crop, pinned.
///
/// These numbers decide which pixels of a driver's licence reach a reviewer.
/// Getting them wrong does not throw and does not crash — it uploads a photo
/// of the desk, and nobody finds out until the verification comes back
/// rejected. So the mapping is checked against real device numbers rather
/// than trusted.
void main() {
  // iPhone 14: 390x844 logical, 4:3 sensor held portrait.
  const iphone = Size(390, 844);
  const still43 = Size(3024, 4032);

  group('docScanFrame', () {
    test('is 82% of the width at a 0.63 aspect, sitting above centre', () {
      final f = docScanFrame(iphone);
      expect(f.width, closeTo(390 * 0.82, 0.001));
      expect(f.height, closeTo(390 * 0.82 * 0.63, 0.001));
      expect(f.center.dx, closeTo(195, 0.001));
      // 30 logical px above the vertical centre — where the brackets are
      // drawn, so where the crop has to be.
      expect(f.center.dy, closeTo(844 / 2 - 30, 0.001));
    });

    test('never leaves the screen on the phones we ship to', () {
      for (final s in const [
        Size(320, 568), // iPhone SE 1st gen, the smallest still supported
        Size(360, 640), // common cheap Android
        Size(390, 844),
        Size(430, 932), // Pro Max
        Size(412, 915),
      ]) {
        final f = docScanFrame(s);
        expect(f.left, greaterThanOrEqualTo(0), reason: '$s');
        expect(f.top, greaterThanOrEqualTo(0), reason: '$s');
        expect(f.right, lessThanOrEqualTo(s.width + 0.001), reason: '$s');
        expect(f.bottom, lessThanOrEqualTo(s.height + 0.001), reason: '$s');
      }
    });
  });

  group('mapFrameToImage on a 4:3 still', () {
    test('takes the fraction of the image the frame really covers', () {
      final src = mapFrameToImage(docScanFrame(iphone), iphone, still43)!;

      // The still is taller than 390:844, so cover scales it to match the
      // HEIGHT and spills sideways. Vertically that makes screen fraction
      // and image fraction identical.
      expect(src.height / still43.height, closeTo(0.2387, 0.002));

      // Horizontally the picture is 633 logical px wide behind a 390 px
      // screen, so the 319.8 px frame covers barely half of it — not 82%.
      final displayedW = still43.width * (iphone.height / still43.height);
      expect(src.width / still43.width,
          closeTo(390 * 0.82 / displayedW, 0.002));
      expect(src.width / still43.width, lessThan(0.82));
    });

    test('stays centred horizontally, because the frame is', () {
      final src = mapFrameToImage(docScanFrame(iphone), iphone, still43)!;
      expect(src.center.dx, closeTo(still43.width / 2, 1.0));
    });

    test('sits above the middle of the image, as drawn', () {
      final src = mapFrameToImage(docScanFrame(iphone), iphone, still43)!;
      expect(src.center.dy, lessThan(still43.height / 2));
    });

    test('never escapes the image', () {
      for (final s in const [
        Size(320, 568),
        Size(390, 844),
        Size(430, 932),
      ]) {
        for (final img in const [
          Size(3024, 4032),
          Size(1080, 1920),
          Size(2160, 3840),
          Size(1200, 1600),
        ]) {
          final src = mapFrameToImage(docScanFrame(s), s, img);
          if (src == null) continue;
          expect(src.left, greaterThanOrEqualTo(-0.001), reason: '$s $img');
          expect(src.top, greaterThanOrEqualTo(-0.001), reason: '$s $img');
          expect(src.right, lessThanOrEqualTo(img.width + 0.001),
              reason: '$s $img');
          expect(src.bottom, lessThanOrEqualTo(img.height + 0.001),
              reason: '$s $img');
          expect(src.width, greaterThan(0), reason: '$s $img');
          expect(src.height, greaterThan(0), reason: '$s $img');
        }
      }
    });

    test('a 16:9 still crops the same fraction vertically as a 4:3 one', () {
      // Both are portrait and both are covered to the screen height, so the
      // vertical slice is a property of the frame, not of the sensor.
      final a = mapFrameToImage(docScanFrame(iphone), iphone, still43)!;
      final b = mapFrameToImage(
          docScanFrame(iphone), iphone, const Size(1080, 1920))!;
      expect(a.height / still43.height, closeTo(b.height / 1920, 0.002));
    });
  });

  group('refuses to guess', () {
    test('when the still came back sideways', () {
      // Portrait screen, landscape image: the EXIF rotation was not applied.
      // Cropping here would cut a band out of a photo lying on its side.
      expect(mapFrameToImage(docScanFrame(iphone), iphone, const Size(4032, 3024)),
          isNull);
    });

    test('when either size is degenerate', () {
      final f = docScanFrame(iphone);
      expect(mapFrameToImage(f, Size.zero, still43), isNull);
      expect(mapFrameToImage(f, iphone, Size.zero), isNull);
      expect(mapFrameToImage(f, iphone, const Size(1, 1)), isNull);
      expect(mapFrameToImage(f, const Size(1, 1), still43), isNull);
    });

    test('when a size is not finite', () {
      final f = docScanFrame(iphone);
      expect(mapFrameToImage(f, const Size(double.infinity, 844), still43),
          isNull);
      expect(mapFrameToImage(f, iphone, const Size(3024, double.nan)), isNull);
    });

    test('when the frame itself is not finite', () {
      expect(
        mapFrameToImage(
            const Rect.fromLTRB(0, 0, double.nan, 100), iphone, still43),
        isNull,
      );
    });

    test('when the frame lands off the image entirely', () {
      expect(
        mapFrameToImage(
            const Rect.fromLTWH(-9000, -9000, 100, 100), iphone, still43),
        isNull,
      );
    });
  });

  group('jpegFromRgba', () {
    /// Photo-like noise. A flat gradient compresses to nothing in either
    /// format and would make the size comparison below meaningless.
    ByteData noise(int w, int h) {
      final bytes = Uint8List(w * h * 4);
      var seed = 12345;
      for (var i = 0; i < w * h; i++) {
        seed = (seed * 1103515245 + 12345) & 0x7FFFFFFF;
        bytes[i * 4] = (seed >> 16) & 0xFF;
        bytes[i * 4 + 1] = (seed >> 8) & 0xFF;
        bytes[i * 4 + 2] = seed & 0xFF;
        bytes[i * 4 + 3] = 255;
      }
      return ByteData.view(bytes.buffer);
    }

    test('writes a real JPEG of the right size', () {
      final out = jpegFromRgba(noise(160, 120), 160, 120);
      expect(out, isNotNull);
      // SOI marker.
      expect(out!.sublist(0, 3), [0xFF, 0xD8, 0xFF]);

      final back = img.decodeJpg(out);
      expect(back, isNotNull);
      expect(back!.width, 160);
      expect(back.height, 120);
    });

    test('is far smaller than the PNG dart:ui would have written', () {
      // The whole reason the image package is a dependency at all.
      const w = 400, h = 300;
      final rgba = noise(w, h);
      final jpeg = jpegFromRgba(rgba, w, h)!;
      final png = img.encodePng(img.Image.fromBytes(
        width: w,
        height: h,
        bytes: rgba.buffer,
        numChannels: 4,
        order: img.ChannelOrder.rgba,
      ));
      expect(jpeg.length, lessThan(png.length));
    });

    test('refuses a buffer too short for the dimensions', () {
      // Would be read past the end inside the encoder.
      expect(jpegFromRgba(noise(10, 10), 200, 200), isNull);
    });

    test('refuses degenerate dimensions', () {
      expect(jpegFromRgba(noise(10, 10), 0, 10), isNull);
      expect(jpegFromRgba(noise(10, 10), 10, -1), isNull);
    });
  });

  test('a square screen and a square image still map', () {
    const s = Size(500, 500);
    const img = Size(2000, 2000);
    final src = mapFrameToImage(docScanFrame(s), s, img);
    expect(src, isNotNull);
    expect(src!.width, greaterThan(0));
    expect(src.height, greaterThan(0));
  });
}
