import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Guardian (owner report 2026-11-04, with photos): on opening the nav the
/// line was not under the arrow; "Ruta completa" left the start of the
/// route — where the car is — under the turn box and showed no arrow; the
/// way back froze the overview behind an arrow pinned mid-screen.
void main() {
  final nav = File('lib/screens/driver/driver_nav_view.dart')
      .readAsStringSync()
      .replaceAll('\r\n', '\n');

  String bodyOf(String signature, {int maxLen = 1600}) {
    final start = nav.indexOf(signature);
    expect(start, isNonNegative, reason: '$signature not found');
    return nav.substring(start, start + maxLen);
  }

  test('the overview frames the car with the line', () {
    final pts = bodyOf('List<LatLng> get _overviewPoints {', maxLen: 800);
    expect(pts, contains('_renderPos?.latitude ?? _dot.lat'));
    expect(pts, contains('LatLng(lat!, lng!)'));
    expect(pts, contains('DestBuilding.slice(_routePts, _trimS, _drawEndS)'),
        reason: 'only what is left: the driven stretch shrank the road ahead');
  });

  test('the overview frames below the turn box and above the panel', () {
    final insets = bodyOf('_overviewInsets(MediaQueryData media) {',
        maxLen: 600);
    expect(insets, contains('_topBarKey.currentContext'));
    expect(insets, contains('_panelRestH'));
    expect(nav, contains('key: _topBarKey,'));
    for (final sig in const [
      'Future<void> _glideToOverview() async {',
      'Future<void> _fitRouteOnce() async {',
    ]) {
      final body = bodyOf(sig, maxLen: 1500);
      expect(body, contains('_overviewInsets(media)'), reason: sig);
      expect(body, contains('_overviewPoints'), reason: sig);
      expect(body, isNot(contains('media.padding.top + 120,')), reason: sig);
    }
  });

  test('a loaded line always gets the arrow on it', () {
    final place = bodyOf('void _placeArrowOnRoute() {', maxLen: 700);
    expect(place, contains('_dot.setTarget('),
        reason: 'indoors every fix is > 30 m: without a seed the dot stays '
            'empty and nothing follows, recenters or draws the arrow');
    expect(place, contains('_renderPos = '));
    final fetch = bodyOf('Future<void> _fetchRoute({', maxLen: 6000);
    expect(fetch, contains('_placeArrowOnRoute();'),
        reason: 'a route that was not prefetched arrives after _startGps');
    expect(bodyOf('void _startGps() {', maxLen: 1500),
        contains('_placeArrowOnRoute();'));
  });
}
