import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

/// The two markers that sit at the ends of an offer's route preview.
///
/// They match the offer card exactly: a gold disc where the card shows its
/// gold dot, a white disc where the card shows its white one. A map that
/// labels the pickup with a different shape than the card beside it makes
/// the driver work out which is which twice. (The dropoff used to be a
/// square; a circle reads calmer next to the gold disc and the driver
/// asked for it.)
///
/// Both are drawn centre-anchored, so the marker sits *on* the coordinate
/// rather than pointing down at it from above — these are positions, not
/// teardrop pins.

const _gold = Color(0xFFE8C547);

/// A filled gold disc with a dark rim and a soft halo. 30, down from 44 —
/// at 44 the two endpoints competed with the route line itself.
Future<Uint8List> renderPickupDotBytes({double size = 30}) =>
    _render(size, fill: _gold);

/// A white disc, same size and treatment as the pickup one.
Future<Uint8List> renderDropoffCircleBytes({double size = 30}) =>
    _render(size, fill: Colors.white);

Future<Uint8List> _render(
  double size, {
  required Color fill,
}) async {
  // The canvas is bigger than the marker so the halo has room; without it
  // the glow is clipped square at the bitmap's edge.
  final canvasSize = size * 1.9;
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  final centre = Offset(canvasSize / 2, canvasSize / 2);
  final r = size / 2;

  // Halo — the marker has to stay legible on a pale road as well as on the
  // dark map style, and a flat shape on light grey disappears.
  canvas.drawCircle(
    centre,
    r * 1.55,
    Paint()
      ..color = fill.withValues(alpha: 0.20)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 7),
  );

  // A dark rim under the fill, so the marker reads as raised and keeps its
  // edge against whatever is behind it.
  canvas.drawCircle(centre, r + 2.5, Paint()..color = const Color(0xFF0B0B0F));
  canvas.drawCircle(centre, r, Paint()..color = fill);

  final img = await recorder.endRecording().toImage(
        canvasSize.ceil(),
        canvasSize.ceil(),
      );
  final data = await img.toByteData(format: ui.ImageByteFormat.png);
  img.dispose();
  return data!.buffer.asUint8List();
}
