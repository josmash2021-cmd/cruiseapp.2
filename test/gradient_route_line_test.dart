import 'dart:convert';
import 'dart:io';

import 'package:cruise_app/map/gradient_route_line.dart';
import 'package:cruise_app/models/lat_lng.dart';
import 'package:flutter_test/flutter_test.dart';

/// Owner 2026-11-04: the route on the map is the card rail's line — gold
/// where it starts, white where it ends — on the reservations map and in
/// the navigation.
void main() {
  test('gold at the start, white at the end, along the line', () {
    expect(GradientRouteLine.gradient[2], ['line-progress']);
    expect(GradientRouteLine.gradient[3], 0);
    expect(GradientRouteLine.gradient[4], 'rgba(232, 197, 71, 1)');
    expect(GradientRouteLine.gradient[5], 1);
    expect(GradientRouteLine.gradient[6], 'rgba(255, 255, 255, 1)');
  });

  test('the GeoJSON is [lng, lat] and skips broken points', () {
    final j = jsonDecode(GradientRouteLine.geoJson(const [
      LatLng(33.5, -86.8),
      LatLng(double.nan, -86.7),
      LatLng(33.4, -86.7),
    ])) as Map<String, dynamic>;
    final coords = (j['geometry'] as Map)['coordinates'] as List;
    expect(coords, [
      [-86.8, 33.5],
      [-86.7, 33.4],
    ]);
  });

  test('the navigation and the reservations map both draw it', () {
    final nav = File('lib/screens/driver/driver_nav_view.dart')
        .readAsStringSync()
        .replaceAll('\r\n', '\n');
    expect(nav, contains('final GradientRouteLine _routeLine = GradientRouteLine('));
    expect(nav, isNot(contains('PolylineAnnotation? _routeAnnot')),
        reason: 'an annotation cannot carry the gradient');
    expect(nav, contains('if (!_routeLine.isShown) await _drawRoute();'),
        reason: 'a draw before the style loaded must be redone');
    expect(nav, contains('_routeLine.forget();'),
        reason: 'a lost surface took its style with it');
  });
}
