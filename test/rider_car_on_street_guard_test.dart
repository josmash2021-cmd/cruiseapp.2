import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The rider's car (owner 2026-11-05: "ver moverse el carrito fluido sin
/// saltos", then "avanzando al mismo tiempo que el conductor… cuando gire
/// gire igual… que no se salga del carril"). Along the route the
/// RouteFollower draws it (its own behaviour: test/route_follower_test.dart);
/// off the route the free glide (SmoothMotion) does.
void main() {
  String read(String p) => File(p).readAsStringSync().replaceAll('\r\n', '\n');
  final ctrl = read('lib/controllers/rider_tracking_controller.dart');
  final view = read('lib/widgets/tracking/tracking_map_view.dart');
  final screen = read('lib/screens/rider_tracking_screen.dart');

  String interp() {
    final i = ctrl.indexOf('void _interpolate(Duration elapsed) {');
    expect(i, isNot(-1));
    return ctrl.substring(i, i + 3600);
  }

  test('every frame both movers tick; on the route the follower draws', () {
    final body = interp();
    expect(body, contains('_carMotion.tick(dt);'));
    expect(body, contains('_follower.tick(dt);'));
    expect(body, contains('final onRoad = _follower.active ? _follower.position : null;'));
    expect(body, contains('_animBearing = _follower.bearing;'));
    // Off the route, the free glide.
    expect(body, contains('drawn = LatLng(_carMotion.lat!, _carMotion.lng!);'));
    // What everything else reads (camera, pins, ETA, the erase) is the
    // drawn car.
    expect(body, contains('_driverPos = drawn;'));
    expect(body, contains('_traveledM = _projectOntoRoute(drawn)'));
  });

  test('every fix feeds the follower with its speed, its capture time and '
      'where the car is drawn', () {
    expect(ctrl, contains('_follower.onFix(ll.latitude, ll.longitude,'));
    expect(ctrl, contains('timestampMs: timestampMs,'));
    expect(ctrl, contains('drawnNow: _carMotion.hasPosition ? _animPos : null);'));
    expect(ctrl, contains('_follower.leaveRoute();'));
    expect(screen, contains('final RouteFollower _follower = RouteFollower();'));
  });

  test('a new route goes to the follower', () {
    final i = view.indexOf('void _buildSegDist() {');
    expect(view.substring(i, i + 500), contains('_follower.setRoute(_routePts);'));
  });
}
