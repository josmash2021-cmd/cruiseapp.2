import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

/// The two markers that sit at the ends of an offer's route preview.
///
/// They match the offer card exactly: a gold disc where the card shows its
/// gold dot, a white square where the card shows its white square. A map
/// that labels the pickup with a different shape than the card beside it
/// makes the driver work out which is which twice.
///
/// Both are drawn centre-anchored, so the marker sits *on* the coordinate
/// rather than pointing down at it from above — these are positions, not
/// teardrop pins.

const _gold = Color(0xFFE8C547);

/// A filled gold disc with a dark rim and a soft halo.
Future<Uint8List> renderPickupDotBytes({double size = 44}) =>
    _render(size, isSquare: false, fill: _gold);

/// A white rounded square, same size and treatment as the pickup disc.
Future<Uint8List> renderDropoffSquareBytes({double size = 44}) =>
    _render(size, isSquare: true, fill: Colors.white);

Future<Uint8List> _render(
  double size, {
  required bool isSquare,
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
  final rimPaint = Paint()..color = const Color(0xFF0B0B0F);
  final fillPaint = Paint()..color = fill;

  if (isSquare) {
    final rim = RRect.fromRectAndRadius(
      Rect.fromCenter(center: centre, width: size + 5, height: size + 5),
      Radius.circular(r * 0.34),
    );
    final body = RRect.fromRectAndRadius(
      Rect.fromCenter(center: centre, width: size, height: size),
      Radius.circular(r * 0.30),
    );
    canvas.drawRRect(rim, rimPaint);
    canvas.drawRRect(body, fillPaint);
  } else {
    canvas.drawCircle(centre, r + 2.5, rimPaint);
    canvas.drawCircle(centre, r, fillPaint);
  }

  final img = await recorder.endRecording().toImage(
        canvasSize.ceil(),
        canvasSize.ceil(),
      );
  final data = await img.toByteData(format: ui.ImageByteFormat.png);
  img.dispose();
  return data!.buffer.asUint8List();
}
