import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// "Viaje Aceptado". Owner 2026-11-02: no pickup address, the WHOLE trip on
/// the map, top-down. Owner 2026-11-05: the content in the CENTRE over a
/// blurred map ("nublando el contenido detrás de él"), the sheet hidden, the
/// route in the navigation's gold→white design, and the arrow at the
/// driver's real spot — never the centre of the screen.
void main() {
  String read(String p) =>
      File(p).readAsStringSync().replaceAll('\r\n', '\n');

  test('centred content over a blurred, dimmed map; no pickup address', () {
    final overlay = read('lib/screens/driver/trip_accepted_overlay.dart');
    expect(overlay, isNot(contains('// ── Pickup address pill ──')));
    expect(overlay, contains('BackdropFilter('));
    expect(overlay, contains('static const double _kBlur = 8;'));
    expect(overlay, contains('Center('));
    expect(overlay, isNot(contains('stops: const [0.48, 0.64, 1.0],')),
        reason: 'no more darkening only the bottom half');
    // The blur grows in (never under an Opacity, rule 43).
    final i = overlay.indexOf('BackdropFilter(');
    expect(overlay.substring(i - 400, i), contains('TweenAnimationBuilder<double>('));
  });

  test('the whole trip, one gold→white line, framed top-down', () {
    final ctrl = read('lib/screens/driver/driver_online_controller.dart');
    final body = ctrl.substring(
        ctrl.indexOf('Future<void> _paintAcceptedRouteInner('),
        ctrl.indexOf('/// Take the celebration off screen.'));
    expect(body, contains('_fetchRoutePoints(_pickupLL, _dropoffLL,'));
    expect(body, contains('waypoints: _stopLL == null ? null : [_stopLL!]'));
    expect(body, contains('_fitAcceptedRoute(['));
    expect(body, contains('mapbox.CameraOptions(pitch: 0, bearing: 0)'),
        reason: 'top-down, so nothing of the route hides behind a tilt');
    expect(body, contains('await _acceptedRouteLine.set(map, whole);'));
    expect(body, isNot(contains('_drawGoldGlossRoute(')),
        reason: 'the old bright-gold leg is gone');
    expect(body, isNot(contains('zoom: 14.5,')),
        reason: 'the old fixed driver↔pickup zoom cut long trips');
    final hide = ctrl.substring(ctrl.indexOf('void _hideAcceptedOverlay() {'));
    expect(hide.substring(0, 300), contains('_acceptedRouteLine.hide(map)'),
        reason: 'the line leaves with the celebration');
  });

  test('the sheet and side buttons step away; the arrow keeps its spot', () {
    final screen = read('lib/screens/driver/driver_online_screen.dart');
    final widgets = read('lib/screens/driver/driver_online_widgets.dart');
    final map = read('lib/screens/driver/driver_online_map.dart');
    expect(_flat(screen),
        contains('_pendingOffers.isNotEmpty || _resvCardShown || _heatCardShown || _acceptedOverlay != null;'));
    expect(screen, contains('offset: _sheetStepsAway ? const Offset(0, 1) : Offset.zero,'));
    expect(_flat(widgets), contains('_panelFrac > 0.04 || _resvCardShown || _heatCardShown || _acceptedOverlay != null;'));
    expect(map, contains('_previewingOffer != null || _acceptedOverlay != null;'));
    expect(map, contains('if (_cameraFollowing && !_cameraFramesRoute) {'));
  });
}

/// Source with every run of whitespace as one space: a guard survives the
/// formatter wrapping a long condition.
String _flat(String s) => s.replaceAll(RegExp(r'\s+'), ' ');
