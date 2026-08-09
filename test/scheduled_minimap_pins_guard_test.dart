import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Guardian for the scheduled-rides mini map pins (2026-08-08).
///
/// The mini map created its custom pins right after onMapCreated, BEFORE
/// the style finished loading — and Mapbox renders annotations whose image
/// attaches pre-style as its DEFAULT BLUE MARKER. Every other screen places
/// pins after onStyleLoaded; this one now does too, gated by `_styleReady`.
void main() {
  final src = File('lib/screens/scheduled_rides_screen.dart').readAsStringSync();

  test('onMapCreated only starts route+pins when the style is ready', () {
    expect(
      src.contains('if (_hasCoords && mounted && _styleReady) _loadRouteAndAnimate();'),
      isTrue,
      reason: 'starting pins/route on map creation without the style-ready '
          'gate brings back the default blue markers',
    );
  });

  test('onStyleLoaded flips _styleReady and kicks the held-back load', () {
    final listener = RegExp(r'onStyleLoadedListener:\s*\(_\)\s*async\s*\{');
    final start = listener.firstMatch(src)!.end;
    final block = src.substring(start, start + 700);
    expect(block.contains('_styleReady = true'), isTrue);
    expect(block.contains('_loadRouteAndAnimate()'), isTrue,
        reason: 'the cold-start path must resume once the style is up');
  });

  test('_styleReady is declared', () {
    expect(src.contains('bool _styleReady = false;'), isTrue);
  });
}
