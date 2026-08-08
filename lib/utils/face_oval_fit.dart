import 'dart:math' as math;
import 'dart:ui';

/// Deciding whether the face the detector found is actually inside the oval
/// the person is being shown.
///
/// ML Kit hands back a bounding box in the coordinates of the image it was
/// given. The person is looking at that image scaled up with `BoxFit.cover`
/// and cropped to the screen. Without putting the box through that same
/// mapping, "a face was found" is all you can honestly say — which is how a
/// liveness check ends up passing someone whose face fills the whole frame
/// and never enters the oval at all.

/// The upright size of the frame ML Kit measured.
///
/// The camera streams landscape whatever way the phone is held; ML Kit is
/// told to rotate by [rotationDegrees] and reports boxes in the ROTATED
/// frame. At 90 or 270 that frame is the stream turned on its side, so the
/// dimensions swap.
Size uprightFrameSize(Size streamed, int rotationDegrees) {
  final r = ((rotationDegrees % 360) + 360) % 360;
  return (r == 90 || r == 270)
      ? Size(streamed.height, streamed.width)
      : streamed;
}

/// Maps a rectangle of the upright camera frame onto the screen it is being
/// displayed on with `BoxFit.cover`.
///
/// Returns null for degenerate or non-finite inputs rather than emitting a
/// rectangle full of NaN — a NaN that reaches a Canvas call crosses into
/// native code and takes the app down where no Dart catch can reach it.
Rect? mapImageRectToScreen(Rect box, Size upright, Size screen) {
  if (!upright.isFinite || !screen.isFinite) return null;
  if (upright.width < 1 || upright.height < 1) return null;
  if (screen.width < 1 || screen.height < 1) return null;
  if (!box.left.isFinite ||
      !box.top.isFinite ||
      !box.right.isFinite ||
      !box.bottom.isFinite) {
    return null;
  }

  final scale = math.max(
    screen.width / upright.width,
    screen.height / upright.height,
  );
  if (!scale.isFinite || scale <= 0) return null;

  final dx = (screen.width - upright.width * scale) / 2;
  final dy = (screen.height - upright.height * scale) / 2;

  return Rect.fromLTRB(
    box.left * scale + dx,
    box.top * scale + dy,
    box.right * scale + dx,
    box.bottom * scale + dy,
  );
}

/// Rescales [box] from one upright frame ([from]) into another ([to]) of
/// possibly different resolution or aspect.
///
/// Needed because the ML Kit stream frame and the preview frame the
/// FittedBox draws are NOT the same surface: the stream typically runs at
/// 640×480 (4:3) while the preview negotiates something like 1280×720
/// (16:9). Mapping a stream-space box against preview-space dimensions
/// inflates it by the resolution ratio (~1.33× in that pairing) and the
/// face reads as permanently "too close".
Rect scaleBoxBetweenFrames(Rect box, Size from, Size to) {
  final sx = to.width / from.width;
  final sy = to.height / from.height;
  return Rect.fromLTRB(
    box.left * sx,
    box.top * sy,
    box.right * sx,
    box.bottom * sy,
  );
}

/// Whether [face] (in screen coordinates) sits inside [oval] well enough to
/// call it framed.
///
/// Two things have to be true, and the second is the one that matters: the
/// face has to be roughly CENTRED on the oval, and roughly the SIZE of it.
/// A face twice the width of the oval is a person holding the phone too
/// close, and passing them is exactly the hole this closes.
///
/// The tolerances are deliberately generous. A liveness check that keeps
/// telling an honest driver "not quite" is worse than one that occasionally
/// accepts a slightly off-centre face, because the next stage is a human
/// reviewing the recording anyway.
bool faceFitsOval(Rect face, Rect oval) {
  if (face.isEmpty || oval.isEmpty) return false;
  if (!face.width.isFinite || !face.height.isFinite) return false;

  // Centred: within about a quarter of the oval of dead centre.
  final offX = (face.center.dx - oval.center.dx).abs();
  final offY = (face.center.dy - oval.center.dy).abs();
  if (offX > oval.width * 0.26) return false;
  if (offY > oval.height * 0.26) return false;

  // Sized: not a distant speck, not a face pressed against the lens.
  final ratio = face.width / oval.width;
  if (ratio < 0.42 || ratio > 1.15) return false;

  return true;
}
