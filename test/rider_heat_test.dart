import 'dart:io';

import 'package:cruise_app/map/rider_heat.dart';
import 'package:flutter_test/flutter_test.dart';

/// Heat zones (owner 2026-11-05): clouds of riders building a trip, faded
/// in smooth, one flame per cloud, on the map floor.
void main() {
  group('HeatCell.listFrom', () {
    test('keeps good cells, drops the rest one by one', () {
      final cells = HeatCell.listFrom([
        {'lat': 33.4, 'lng': -86.8, 'w': 0.55},
        {'lat': 'x', 'lng': -86.8, 'w': 1},
        {'lat': 33.4, 'lng': -86.8, 'w': 0},
        {'lat': 95, 'lng': -86.8, 'w': 1},
        'nope',
      ]);
      expect(cells.length, 1);
      expect(cells.single.w, 0.55);
      expect(HeatCell.listFrom(null), isEmpty);
    });
  });

  group('heatZonesFrom', () {
    var k = 0;
    int next() => ++k;

    test('neighbouring cells are one cloud, far ones another', () {
      final zones = heatZonesFrom([
        const HeatCell(33.400, -86.800, 1.0),
        const HeatCell(33.4036, -86.800, 0.8), // ~400 m north
        const HeatCell(33.500, -86.800, 0.55), // ~11 km away
      ], nextKey: next);
      expect(zones.length, 2);
      expect(zones.first.weight, closeTo(1.8, 1e-9)); // heaviest first
      expect(zones.first.center.latitude, greaterThan(33.400));
      expect(zones.first.center.latitude, lessThan(33.4036));
    });

    test('a cloud that grows keeps its key (its flame does not re-fade)', () {
      final a = heatZonesFrom([const HeatCell(33.4, -86.8, 0.55)],
          nextKey: next);
      final b = heatZonesFrom([
        const HeatCell(33.4, -86.8, 0.55),
        const HeatCell(33.4036, -86.8, 1.0),
      ], previous: a, nextKey: next);
      expect(b.single.key, a.single.key);
      final far = heatZonesFrom([const HeatCell(33.6, -86.8, 1)],
          previous: a, nextKey: next);
      expect(far.single.key, isNot(a.single.key));
    });
  });

  group('HeatFader', () {
    test('a new cell grows smooth from nothing over 1.2 s', () {
      final f = HeatFader();
      f.setTarget([const HeatCell(33.4, -86.8, 1)], 0);
      expect(f.at(0), isEmpty);
      final mid = f.at(kHeatFadeMs ~/ 2).single.w;
      expect(mid, closeTo(0.5, 0.01));
      expect(f.at(kHeatFadeMs).single.w, 1);
      expect(f.animating(kHeatFadeMs ~/ 2), isTrue);
      expect(f.animating(kHeatFadeMs + 1), isFalse);
    });

    test('a change eases from where it is, a gone cell fades out and goes', () {
      final f = HeatFader();
      f.setTarget([const HeatCell(33.4, -86.8, 1)], 0);
      f.setTarget([const HeatCell(33.4, -86.8, 0.5)], kHeatFadeMs);
      expect(f.at(kHeatFadeMs).single.w, 1);
      expect(f.at(kHeatFadeMs * 2).single.w, 0.5);
      f.setTarget(const [], kHeatFadeMs * 2);
      expect(f.at(kHeatFadeMs * 2 + kHeatFadeMs ~/ 2).single.w,
          closeTo(0.25, 0.01));
      expect(f.at(kHeatFadeMs * 3), isEmpty);
      expect(f.isEmpty, isTrue);
    });
  });

  test('the glow keeps its size on the ground: radius doubles per zoom', () {
    final e = heatRadiusExpression(33.4);
    final r8 = e[4] as double, r16 = e[6] as double;
    expect(r16 / r8, closeTo(256, 1e-6));
    // ~2 km on the ground at zoom 12 near Birmingham ≈ 127 px.
    expect(r8 * 16, closeTo(127, 2));
  });

  test('GeoJSON carries the weight per point', () {
    final j = heatGeoJson([const HeatCell(33.4, -86.8, 0.55)]);
    expect(j, contains('"w":0.550'));
    expect(j, contains('[-86.800000,33.400000]'));
  });

  group('wiring (source guards)', () {
    final heat =
        File('lib/screens/driver/driver_online_heat.dart').readAsStringSync();
    final screen =
        File('lib/screens/driver/driver_online_screen.dart').readAsStringSync();
    final widgets = File('lib/screens/driver/driver_online_widgets.dart')
        .readAsStringSync();
    final layer = File('lib/map/rider_heat_layer.dart').readAsStringSync();

    test('the clouds go UNDER the roads, as a native heatmap layer', () {
      expect(layer, contains('mapbox.HeatmapLayer('));
      expect(layer, contains('LayerPosition(below: belowLayerId)'));
      expect(heat, contains('_zoneRoadAnchor(map)'));
    });

    test('flames and card online AND offline, never over an offer', () {
      final wanted = heat.substring(heat.indexOf('bool get _heatWanted'),
          heat.indexOf('bool get _heatCardShown'));
      expect(wanted, isNot(contains('_driverOnline')));
      expect(wanted, contains('_pendingOffers.isEmpty'));
      expect(wanted, contains('_acceptedOverlay == null'));
    });

    test('a new flame eases the follow camera out to show it', () {
      expect(heat, contains('_heatRevealNew('));
      expect(heat, contains('boardRevealZoom('));
      expect(heat, contains('_easeSearchFollowZoom(z, ms: 1400)'));
    });

    test('the card takes the sheet\'s place and navigates in the app', () {
      expect(screen, contains('_heatCardShown ||'));
      expect(screen, contains('_heatCardLayer(),'));
      expect(widgets, contains('_heatCardShown ||'));
      expect(widgets, contains('_heatFlameOverlay()'));
      expect(heat, contains('ZoneNavScreen.route('));
      expect(heat, contains('Navigator.maybeOf(context)'));
    });

    test('the destination is a street address, never a highway', () {
      expect(heat, contains('types=address'));
    });
  });
}
