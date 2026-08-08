import 'dart:ui';

import 'package:cruise_app/utils/face_oval_fit.dart';
import 'package:flutter_test/flutter_test.dart';

/// Guardian for the stream-vs-preview frame bug in face liveness.
///
/// ML Kit reports the face box in the STREAM frame (typically 640×480),
/// but the preview the person sees is drawn from `previewSize` (typically
/// 1280×720) with BoxFit.cover. The fix scales the box into the preview
/// frame BEFORE mapping it to the screen; the old code mapped it straight
/// from the stream frame, inflating it ~1.33× and pinning the feedback at
/// "too close" forever.
void main() {
  // Portrait screen and oval geometry mirroring face_liveness_screen.
  const screen = Size(360, 720);
  final oval = Rect.fromCenter(
    center: const Offset(180, 300),
    width: 260,
    height: 340,
  );

  // Stream: 640×480 landscape, rotated 90° to portrait → 480×640 upright.
  const streamUpright = Size(480, 640);
  // Preview: 1280×720 landscape → drawn as 720×1280 upright (FittedBox).
  const displayed = Size(720, 1280);

  // A face that honestly fills ~0.90 of the oval width, dead centred, in
  // the PREVIEW frame (what the person is actually doing on screen).
  // Cover scale for the preview frame: max(360/720, 720/1280) = 0.5625,
  // with dx = -22.5, dy = 0.
  const coverScale = 0.5625;
  final facePreview = Rect.fromCenter(
    center: const Offset(360, 300 / coverScale),
    width: 0.90 * oval.width / coverScale,
    height: 0.90 * oval.height / coverScale,
  );

  // The same face as ML Kit would report it in the stream frame.
  final faceStream =
      scaleBoxBetweenFrames(facePreview, displayed, streamUpright);

  test('box scaled stream→preview keeps the ratio inside the gate', () {
    final onScreen = mapImageRectToScreen(
      scaleBoxBetweenFrames(faceStream, streamUpright, displayed),
      displayed,
      screen,
    )!;
    final ratio = onScreen.width / oval.width;
    expect(ratio, closeTo(0.90, 0.02));
    expect(ratio, greaterThan(0.42));
    expect(ratio, lessThan(1.15));
    expect(faceFitsOval(onScreen, oval), isTrue);
  });

  test('old direct-from-stream mapping inflates past the gate', () {
    final onScreen =
        mapImageRectToScreen(faceStream, streamUpright, screen)!;
    final ratio = onScreen.width / oval.width;
    expect(ratio, greaterThan(1.15));
    expect(faceFitsOval(onScreen, oval), isFalse);
  });

  test('scaleBoxBetweenFrames roundtrips', () {
    final back = scaleBoxBetweenFrames(faceStream, streamUpright, displayed);
    expect(back.left, closeTo(facePreview.left, 1e-6));
    expect(back.top, closeTo(facePreview.top, 1e-6));
    expect(back.width, closeTo(facePreview.width, 1e-6));
    expect(back.height, closeTo(facePreview.height, 1e-6));
  });
}
