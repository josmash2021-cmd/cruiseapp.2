import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui';

import 'package:image/image.dart' as img;

/// Geometry for the document scanner's capture window.
///
/// These two functions decide which pixels of a driver's licence actually get
/// uploaded, so they live apart from the screen and are covered by tests. A
/// silent error here does not crash anything — it just uploads a photo of the
/// desk, and nobody finds out until a verification is rejected.

/// The scan window, in screen coordinates.
///
/// One definition, used by the overlay that draws the brackets, the blur that
/// softens everything around them, and the crop that cuts the photo. If these
/// ever disagreed, the driver would line the document up inside the brackets
/// and get a picture of something else.
Rect docScanFrame(Size screen) {
  final w = screen.width * 0.82;
  final h = w * 0.63;
  return Rect.fromLTWH(
    (screen.width - w) / 2,
    (screen.height - h) / 2 - 30,
    w,
    h,
  );
}

/// Maps a rectangle of screen onto the pixels of the captured photo.
///
/// The preview is laid out with `BoxFit.cover`: the picture is scaled up
/// until it covers the screen and the overflow is centred and cut off. The
/// still comes through the same lens, so running that mapping backwards turns
/// a rectangle of screen into a rectangle of pixels.
///
/// The mapping is derived from the STILL's own dimensions rather than the
/// preview's. Some Android sensors report a different aspect ratio for the
/// two, and using the preview's numbers on the still's pixels would slide the
/// crop off the document.
///
/// Returns null when the result should not be trusted — a degenerate size, a
/// non-finite rect, or a crop so small that the mapping clearly went wrong
/// rather than the driver having framed a sliver. Callers upload the whole
/// photo in that case; a full-frame photo still gets reviewed by a human, an
/// error message does not.
Rect? mapFrameToImage(Rect frame, Size screen, Size image) {
  if (!screen.isFinite || !image.isFinite || !_rectIsFinite(frame)) return null;
  if (screen.width < 2 || screen.height < 2) return null;
  if (image.width < 2 || image.height < 2) return null;

  // A portrait screen holding a landscape still means the decoder did not
  // apply the sensor's EXIF rotation. The cover mapping would then be
  // computed against an image lying on its side and would quietly cut a band
  // out of the middle of it — a crop that looks deliberate and is wrong.
  // Better to hand back the whole photo.
  if ((screen.width > screen.height) != (image.width > image.height)) {
    return null;
  }

  final scale = math.max(screen.width / image.width, screen.height / image.height);
  if (!scale.isFinite || scale <= 0) return null;

  final dx = (screen.width - image.width * scale) / 2;
  final dy = (screen.height - image.height * scale) / 2;

  final src = Rect.fromLTRB(
    (frame.left - dx) / scale,
    (frame.top - dy) / scale,
    (frame.right - dx) / scale,
    (frame.bottom - dy) / scale,
  ).intersect(Rect.fromLTWH(0, 0, image.width, image.height));

  if (!_rectIsFinite(src)) return null;
  if (src.width < image.width * 0.15 || src.height < image.height * 0.10) {
    return null;
  }
  return src;
}

bool _rectIsFinite(Rect r) =>
    r.left.isFinite && r.top.isFinite && r.right.isFinite && r.bottom.isFinite;

/// Re-encodes raw RGBA pixels as JPEG.
///
/// `dart:ui` decodes every format the phone can produce and honours the
/// sensor's EXIF rotation, but it can only write PNG — and a PNG of a
/// photograph runs several times the size of the JPEG it came from. These
/// bytes are base64'd into a verification payload alongside a second document
/// side and a selfie, so that difference is the difference between an upload
/// that completes on a weak connection and one that does not.
///
/// Returns null rather than throwing: the caller falls back to the original
/// photo, which is worse framed but perfectly reviewable.
Uint8List? jpegFromRgba(
  ByteData rgba,
  int width,
  int height, {
  int quality = 90,
}) {
  try {
    if (width < 1 || height < 1) return null;
    final expected = width * height * 4;
    // A short buffer would be read past the end inside the encoder.
    if (rgba.lengthInBytes < expected) return null;

    final frame = img.Image.fromBytes(
      width: width,
      height: height,
      bytes: rgba.buffer,
      bytesOffset: rgba.offsetInBytes,
      numChannels: 4,
      order: img.ChannelOrder.rgba,
    );
    return img.encodeJpg(frame, quality: quality);
  } catch (_) {
    return null;
  }
}
