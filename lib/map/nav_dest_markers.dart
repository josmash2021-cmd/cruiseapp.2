import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

/// The navigation's destination marks, Lyft's way in Cruise gold (owner
/// 2026-11-04, with Lyft photos): an ordinary pickup or dropoff is the gold
/// pin standing on a small ring at the exact spot — the pickup inside a
/// soft gold halo; a reservation's pickup is the ring alone under a dark
/// "Reservado" pill, no pin.
///
/// Both images are drawn around the spot, so the caller anchors them at
/// `IconAnchor.CENTER`.
const _gold = Color(0xFFE8C547);
const _pillFill = Color(0xEB16161C);

/// The ring on the ground, centred on [c]; [r] is its outer radius.
void _paintGroundRing(Canvas canvas, Offset c, double r) {
  canvas.drawCircle(
      c, r * 1.9, Paint()..color = _gold.withValues(alpha: 0.18));
  canvas.drawCircle(c, r, Paint()..color = _gold);
  canvas.drawCircle(c, r * 0.55, Paint()..color = Colors.white);
  canvas.drawCircle(
    c,
    r,
    Paint()
      ..color = Colors.black.withValues(alpha: 0.35)
      ..style = PaintingStyle.stroke
      ..strokeWidth = math.max(1.0, r * 0.12),
  );
}

Future<Uint8List> _toPng(
    ui.PictureRecorder recorder, double w, double h, Uint8List fallback) async {
  final img = await recorder.endRecording().toImage(w.ceil(), h.ceil());
  final data = await img.toByteData(format: ui.ImageByteFormat.png);
  // A lost raster context hands back null on iOS (rule 26): keep the pin.
  return data == null ? fallback : data.buffer.asUint8List();
}

/// [pinPng] (tip at its bottom centre) standing on the ground ring, with
/// the gold halo around the spot when [halo].
Future<Uint8List> pinOnGround(Uint8List pinPng, {bool halo = false}) async {
  final pin = (await (await ui.instantiateImageCodec(pinPng)).getNextFrame())
      .image;
  final pinW = pin.width.toDouble();
  final pinH = pin.height.toDouble();
  final ringR = pinW * 0.11;
  final haloR = halo ? pinW * 1.1 : 0.0;
  // The pin's tip sits on the top of the ring.
  final lift = ringR * 0.45;
  final half = math.max(pinH + lift, math.max(haloR, ringR * 1.9)) + 2;
  final w = math.max(pinW, haloR * 2) + 4;
  final h = half * 2;
  final c = Offset(w / 2, half);

  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder, Rect.fromLTWH(0, 0, w, h));
  if (halo) {
    canvas.drawCircle(c, haloR, Paint()..color = _gold.withValues(alpha: 0.16));
    canvas.drawCircle(
      c,
      haloR,
      Paint()
        ..color = _gold.withValues(alpha: 0.38)
        ..style = PaintingStyle.stroke
        ..strokeWidth = math.max(1.0, pinW * 0.018),
    );
  }
  _paintGroundRing(canvas, c, ringR);
  canvas.drawImage(pin, Offset(c.dx - pinW / 2, c.dy - lift - pinH), Paint());
  return _toPng(recorder, w, h, pinPng);
}

/// A reservation's pickup: the ground ring under a dark pill with [label]
/// ("Reservado"). [unit] is the width of the pin it replaces, so it reads
/// at the same scale as the other marks.
Future<Uint8List> scheduledPickupMarker(
    String label, double unit, Uint8List fallback) async {
  final ringR = unit * 0.17;
  final fontSize = unit * 0.38;
  final text = TextPainter(
    text: TextSpan(
      text: label,
      style: TextStyle(
        fontSize: fontSize,
        fontWeight: FontWeight.w600,
        color: Colors.white.withValues(alpha: 0.92),
      ),
    ),
    textDirection: TextDirection.ltr,
    maxLines: 1,
  )..layout(maxWidth: unit * 6);
  final hPad = fontSize * 0.8;
  final vPad = fontSize * 0.45;
  final pillW = text.width + hPad * 2;
  final pillH = text.height + vPad * 2;
  final gap = ringR * 1.1;
  final half = pillH + gap + ringR * 1.9 + 2;
  final w = math.max(pillW, ringR * 3.8) + 4;
  final h = half * 2;
  final c = Offset(w / 2, half);

  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder, Rect.fromLTWH(0, 0, w, h));
  final pill = RRect.fromRectAndRadius(
    Rect.fromLTWH(c.dx - pillW / 2, c.dy - ringR - gap - pillH, pillW, pillH),
    Radius.circular(pillH / 2),
  );
  canvas.drawRRect(pill, Paint()..color = _pillFill);
  canvas.drawRRect(
    pill,
    Paint()
      ..color = Colors.white.withValues(alpha: 0.12)
      ..style = PaintingStyle.stroke
      ..strokeWidth = math.max(1.0, fontSize * 0.06),
  );
  text.paint(canvas, Offset(c.dx - text.width / 2, pill.top + vPad));
  _paintGroundRing(canvas, c, ringR);
  return _toPng(recorder, w, h, fallback);
}
