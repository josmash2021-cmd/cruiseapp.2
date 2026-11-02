import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Owner report 2026-11-02, "no se ve la ruta completa": with a stop on the
/// ride, the offer route ran down under the offer card. The reservation left
/// out the Accept pill (and the card was never measured), and the native
/// fit framed it lower still. The math of the fit is pinned in
/// flat_map_projection_test.dart; this pins how the screen uses it.
void main() {
  final map = File('lib/screens/driver/driver_online_map.dart')
      .readAsStringSync()
      .replaceAll('\r\n', '\n');
  final screen = File('lib/screens/driver/driver_online_screen.dart')
      .readAsStringSync()
      .replaceAll('\r\n', '\n');
  final fit = map.substring(map.indexOf('Future<void> _fitBoundsMulti('),
      map.indexOf('/// Keep the offer preview honest'));

  test('the reservation is the measured offer block', () {
    expect(screen, contains('key: _offerBlockKey,'));
    expect(fit, contains('_offerBlockKey.currentContext?.findRenderObject()'));
    expect(fit, contains('blockH + blockLift + 16.0'));
    // The fallback counts the Accept pill row (4 + 54 + 8).
    expect(fit, contains('66.0 +'));
  });

  test('the camera is our own flat fit, flown with zero padding', () {
    expect(fit, contains('FlatMapProjection.fitFlat('));
    expect(fit, contains('padding: _kZeroCamPadding,'));
    expect(fit, isNot(contains('.cameraForCoordinatesPadding(')));
    expect(fit, contains('maxZoom: 15.5,'));
  });

  test('a quarter of the screen is kept for the route, not a third', () {
    expect(fit, contains('screenH * 0.75'));
  });
}
