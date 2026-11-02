import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// "Viaje Aceptado" (owner 2026-11-02): no pickup address at the bottom, and
/// the WHOLE route always on the map above the card — bright gold to the
/// pickup, faded gold through the stop to the destination, framed top-down
/// in the clear strip, darkening only behind the text.
void main() {
  String read(String p) =>
      File(p).readAsStringSync().replaceAll('\r\n', '\n');

  test('no pickup address pill; the top half stays clear', () {
    final overlay = read('lib/screens/driver/trip_accepted_overlay.dart');
    expect(overlay, isNot(contains('// ── Pickup address pill ──')));
    expect(overlay, contains('stops: const [0.48, 0.64, 1.0],'));
  });

  test('the whole trip is drawn and framed above the card', () {
    final ctrl = read('lib/screens/driver/driver_online_controller.dart');
    final body = ctrl.substring(
        ctrl.indexOf('Future<void> _paintAcceptedRouteInner('),
        ctrl.indexOf('/// Take the celebration off screen.'));
    expect(body, contains('_fetchRoutePoints(_pickupLL, _dropoffLL,'));
    expect(body, contains('waypoints: _stopLL == null ? null : [_stopLL!]'));
    expect(body, contains('_fitAcceptedRoute(['));
    expect(body, contains('mapbox.CameraOptions(pitch: 0, bearing: 0)'),
        reason: 'top-down, so nothing of the route hides behind a tilt');
    expect(body, contains('bottom: 360 + mq.padding.bottom,'),
        reason: 'framed in the strip above the celebration card');
    expect(body, isNot(contains('zoom: 14.5,')),
        reason: 'the old fixed driver↔pickup zoom cut long trips');
    final hide = ctrl.substring(ctrl.indexOf('void _hideAcceptedOverlay() {'));
    expect(hide.substring(0, 400), contains('_acceptedTripLine = null;'),
        reason: 'the faded leg leaves with the celebration');
  });
}
