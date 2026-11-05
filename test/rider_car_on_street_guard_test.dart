import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The rider's car (owner 2026-11-05: "ver moverse el carrito fluido sin
/// saltos"). It glides every frame on SmoothMotion from the driver's 1 Hz
/// fixes — and on the route it is DRAWN on the street: fed the same 1 Hz
/// fixes, the glide alone cut a corner by 11 m and, with phone GPS noise,
/// sat 6 m+ off the line one frame in five
/// (the drawing: "Carrito del pasajero").
void main() {
  String read(String p) => File(p).readAsStringSync().replaceAll('\r\n', '\n');
  final ctrl = read('lib/controllers/rider_tracking_controller.dart');
  final view = read('lib/widgets/tracking/tracking_map_view.dart');
  final screen = read('lib/screens/rider_tracking_screen.dart');

  String interp() {
    final i = ctrl.indexOf('void _interpolate(Duration elapsed) {');
    expect(i, isNot(-1));
    return ctrl.substring(i, i + 4200);
  }

  test('every frame the engine glides the car', () {
    final body = interp();
    expect(body, contains('_carMotion.tick(dt);'));
    expect(body, contains('final glide = LatLng(_carMotion.lat!, _carMotion.lng!);'));
  });

  test('on the route the car is drawn on the street, never creeping back', () {
    final body = interp();
    expect(body, contains('_traveledM = _projectOntoRoute(glide).clamp(0.0, _segDist.last);'));
    expect(body, contains('final onRoute = _carSnapActive &&'));
    expect(body, contains('if (prev != null && _traveledM < prev && prev - _traveledM < 25) {'));
    expect(body, contains('_animPos = _posAtDistUltraSmooth(_traveledM).\$1;'));
    // What everything else reads (camera, pins, ETA) is the drawn car.
    expect(body, contains('_driverPos = _animPos;'));
    expect(screen, contains('double? _roadM;'));
  });

  test('a new route starts the drawn progress over', () {
    final i = view.indexOf('void _buildSegDist() {');
    expect(view.substring(i, i + 500), contains('_roadM = null;'));
  });
}
