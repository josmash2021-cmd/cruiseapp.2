import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

/// Share text with the anchor iPadOS requires.
///
/// On iPad the share sheet is a popover, so UIKit needs a non-zero source
/// rect to point it at. `Share.share` without `sharePositionOrigin` throws:
///
///   PlatformException(error, sharePositionOrigin: argument must be set,
///   {{0, 0}, {0, 0}} must be non-zero and within coordinate space of
///   source view: {{0, 0}, {440, 956}})
///
/// which surfaced to riders as "Could not share trip:" followed by that
/// wall of text. Every call site had the same gap, so the rect is computed
/// here once instead of being remembered seven times.
///
/// [context] should be the one belonging to the widget that was tapped —
/// its bounds become the popover's anchor. Falls back to a small rect at
/// the centre of the screen when the box is not laid out, which is still a
/// valid anchor and beats throwing.
Future<void> shareText(
  BuildContext context,
  String text, {
  String? subject,
}) async {
  await Share.share(
    text,
    subject: subject,
    sharePositionOrigin: shareOriginFor(context),
  );
}

/// The anchor rect for a share popover, derived from [context]'s render box.
Rect shareOriginFor(BuildContext context) {
  final box = context.findRenderObject() as RenderBox?;
  if (box != null && box.hasSize && box.size.width > 0 && box.size.height > 0) {
    return box.localToGlobal(Offset.zero) & box.size;
  }
  // No usable box — anchor to the middle of the screen. A zero-sized rect
  // is what throws, so anything non-degenerate is better than passing one.
  final size = MediaQuery.maybeOf(context)?.size ?? const Size(400, 800);
  return Rect.fromCenter(
    center: Offset(size.width / 2, size.height / 2),
    width: 1,
    height: 1,
  );
}
