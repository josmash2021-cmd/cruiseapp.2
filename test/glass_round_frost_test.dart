import 'dart:io';
import 'dart:math' as math;

import 'package:cruise_app/widgets/glass_style.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Owner 2026-11-04 (photo of the nav panel): "semi transparente borroso
/// pero sin esquinas". On iOS a blur over the native map is framed to its
/// rectangle (Flutter 3.38), so the frost is built from rectangles that
/// stay inside the rounded shape.
void main() {
  const panel = Size(374, 104);
  final round = BorderRadius.circular(30);

  RRect shape(Size s, BorderRadius r) =>
      r.toRRect(Offset.zero & s);

  test('no frost outside the rounded corners', () {
    final rr = shape(panel, round);
    for (final r in frostStairRects(panel, round)) {
      final inner = r.deflate(0.01);
      for (final p in [
        inner.topLeft,
        inner.topRight,
        inner.bottomLeft,
        inner.bottomRight,
      ]) {
        expect(rr.contains(p), isTrue, reason: '$r leaks at $p');
      }
    }
  });

  test('inside the shape, only thin slivers along the arcs miss the frost',
      () {
    final rects = frostStairRects(panel, round);
    var deepest = 0.0;
    for (var x = 0.0; x <= 30; x += 0.25) {
      for (var y = 0.0; y <= 30; y += 0.25) {
        final d = math.sqrt(math.pow(30 - x, 2) + math.pow(30 - y, 2));
        if (d > 30) continue; // outside the corner
        final p = Offset(x, y);
        if (rects.any((r) => r.contains(p))) continue;
        deepest = math.max(deepest, 30 - d);
      }
    }
    expect(deepest, lessThanOrEqualTo(4.2));
    // And the whole middle is frosted.
    for (final p in const [
      Offset(187, 52),
      Offset(1, 52),
      Offset(187, 1),
      Offset(373, 103 - 40),
    ]) {
      expect(rects.any((r) => r.contains(p)), isTrue, reason: '$p');
    }
  });

  test('a square corner beside round ones is frosted to its tip', () {
    final r = BorderRadius.only(
      topLeft: const Radius.circular(14),
      topRight: const Radius.circular(14),
      bottomRight: const Radius.circular(14),
    );
    final rects = frostStairRects(const Size(360, 90), r);
    expect(rects.any((x) => x.contains(const Offset(0.5, 89.5))), isTrue);
    expect(rects.any((x) => x.contains(const Offset(0.5, 0.5))), isFalse);
  });

  test('the open panel (square bottom) needs no extra quadrant', () {
    final open = BorderRadius.only(
      topLeft: const Radius.circular(30),
      topRight: const Radius.circular(30),
    );
    final rects = frostStairRects(const Size(390, 600), open);
    expect(rects, hasLength(7));
    expect(rects.any((x) => x.contains(const Offset(0.5, 599.5))), isTrue);
  });

  test('all square is one rectangle; no size, no frost', () {
    expect(frostStairRects(panel, BorderRadius.zero), [Offset.zero & panel]);
    expect(frostStairRects(Size.zero, round), isEmpty);
  });

  test('the nav panel and the turn box use it; the open scrim hides', () {
    final panelSrc = File('lib/screens/driver/nav_trip_panel.dart')
        .readAsStringSync()
        .replaceAll('\r\n', '\n');
    expect(panelSrc,
        contains('tint: Color.lerp(glassNavRestTint, glassSheetOpenTint, t)!,'));
    expect(panelSrc, contains('roundFrostOnIOS: true,'));
    final blur = RegExp(r'const double _kScrimBlur = (\d+);')
        .firstMatch(panelSrc)!;
    final dim = RegExp(r'const double _kScrimDim = ([\d.]+);')
        .firstMatch(panelSrc)!;
    expect(double.parse(blur.group(1)!), greaterThanOrEqualTo(30),
        reason: 'at 14 the turn box read through it');
    expect(double.parse(dim.group(1)!), greaterThanOrEqualTo(0.5));
    final nav = File('lib/screens/driver/driver_nav_view.dart')
        .readAsStringSync()
        .replaceAll('\r\n', '\n');
    expect(nav, contains('roundFrostOnIOS: true,'));
    expect(glassNavRestTint.a, lessThan(glassSheetOpenTint.a));
  });
}
