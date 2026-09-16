import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Guardian for the rider trip Live Activity widget (user spec 2026-09-17).
///
/// The widget is Swift — it builds only in the Codemagic iOS build — so this
/// pins the source discipline that made the lock-screen card what it is:
///   1. The car is a GLYPH on a gold disc (the top-down PNG read as a pale
///      box at bar size — "en vez de un cuadrado, un carrito").
///   2. The destination end is the dropoff pin glyph, not a ring.
///   3. The bar and the island minutes repaint every 1 s (30 s made the car
///      jump twice a minute — "paso a paso") and the minutes ceil like the
///      in-app ETA.
void main() {
  final swift = File('ios/CruiseLiveActivity/CruiseRideLiveActivityWidget.swift')
      .readAsStringSync();

  test('the bar car is a glyph on a gold disc, never the pale PNG box', () {
    expect(swift.contains('Image(systemName: "car.fill")'), isTrue,
        reason: 'an SF glyph can never fail to render — the asset-catalog '
            'PNG read as a square at bar size');
    expect(swift.contains('Image(state.carImage'), isFalse,
        reason: 'the top-down PNG at 40 px read as a gray square');
  });

  test('the destination end is the dropoff pin glyph, not a ring', () {
    expect(swift.contains('Image(systemName: "mappin.circle.fill")'), isTrue);
    expect(swift.contains('.strokeBorder(rideGold'), isFalse,
        reason: 'the hollow ring is gone');
  });

  test('bar and island minutes repaint every second and ceil honestly', () {
    final ticks = RegExp(r'TimelineView\(\.periodic\(from: \.now, by: 1\)')
        .allMatches(swift)
        .length;
    expect(ticks, greaterThanOrEqualTo(2),
        reason: 'both the route bar and the ETA minutes tick at 1 s — '
            'the car glides, the minutes never sit stale for half a minute');
    expect(swift.contains('by: 30'), isFalse,
        reason: 'the 30 s tick made the car jump twice a minute');
    expect(swift.contains('.rounded(.up)'), isTrue,
        reason: 'ceil like the in-app ETA — flooring read 1.9 min as "1 min"');
  });
}
