import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

/// A pin bitmap with a small dark bubble ABOVE it — the "Reservado" tag on a
/// reservation's pickup (owner 2026-11-03, Lyft's "Scheduled"). One image,
/// the pin's tip still at the bottom centre, so the caller keeps
/// `IconAnchor.BOTTOM` and nothing else moves.
Future<Uint8List> pinWithTopLabel(Uint8List pinPng, String label) async {
  final codec = await ui.instantiateImageCodec(pinPng);
  final pin = (await codec.getNextFrame()).image;
  final pinW = pin.width.toDouble();
  final pinH = pin.height.toDouble();

  // Sized from the pin, so it reads the same at whatever size the pin is
  // drawn (the nav shows it at iconSize 0.62).
  final fontSize = pinW * 0.30;
  final text = TextPainter(
    text: TextSpan(
      text: label,
      style: TextStyle(
        fontSize: fontSize,
        fontWeight: FontWeight.w600,
        color: Colors.white.withValues(alpha: 0.88),
      ),
    ),
    textDirection: TextDirection.ltr,
    maxLines: 1,
  )..layout(maxWidth: pinW * 6);

  final hPad = fontSize * 0.75;
  final vPad = fontSize * 0.42;
  final bubbleW = text.width + hPad * 2;
  final bubbleH = text.height + vPad * 2;
  final tail = fontSize * 0.40;
  final gap = fontSize * 0.25;
  final w = math.max(pinW, bubbleW) + 4;
  final h = bubbleH + tail + gap + pinH;

  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder, Rect.fromLTWH(0, 0, w, h));
  final cx = w / 2;

  final bubble = RRect.fromRectAndRadius(
    Rect.fromLTWH(cx - bubbleW / 2, 0, bubbleW, bubbleH),
    Radius.circular(bubbleH * 0.36),
  );
  final fill = Paint()..color = const Color(0xEB16161C);
  canvas.drawRRect(bubble, fill);
  canvas.drawPath(
    Path()
      ..moveTo(cx - tail, bubbleH - 0.5)
      ..lineTo(cx + tail, bubbleH - 0.5)
      ..lineTo(cx, bubbleH + tail)
      ..close(),
    fill,
  );
  canvas.drawRRect(
    bubble,
    Paint()
      ..color = Colors.white.withValues(alpha: 0.12)
      ..style = PaintingStyle.stroke
      ..strokeWidth = math.max(1.0, fontSize * 0.06),
  );
  text.paint(canvas, Offset(cx - text.width / 2, vPad));
  canvas.drawImage(pin, Offset(cx - pinW / 2, h - pinH), Paint());

  final img = await recorder.endRecording().toImage(w.ceil(), h.ceil());
  final data = await img.toByteData(format: ui.ImageByteFormat.png);
  // A lost raster context hands back null on iOS (rule 26): keep the pin.
  return data == null ? pinPng : data.buffer.asUint8List();
}
