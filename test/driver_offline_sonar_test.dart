import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:cruise_app/widgets/driver_sonar_marker.dart';
import 'package:cruise_app/widgets/gold_location_dot.dart';

void main() {
  test('waves expand from the marker and fade to zero', () {
    const size = GoldLocationDot.driverOverlaySize;
    final radii = [0.0, 0.25, 0.5, 0.75, 1.0]
        .map((progress) => DriverSonarMarker.waveRadius(progress, size))
        .toList();
    final opacities =
        [0.0, 0.25, 0.5, 0.75, 1.0].map(DriverSonarMarker.waveOpacity).toList();

    for (var i = 1; i < radii.length; i++) {
      expect(radii[i], greaterThan(radii[i - 1]));
      expect(opacities[i], lessThan(opacities[i - 1]));
    }
    expect(radii.last, closeTo(size * 0.42, 0.000001));
    expect(radii.last * 2, lessThan(size),
        reason: 'the waves stay inside the marker box instead of dominating it');
    expect(DriverSonarMarker.waveOpacity(0), greaterThan(0));
    expect(DriverSonarMarker.waveOpacity(1), 0);
  });

  test('the second wave runs half a cycle behind and wraps', () {
    const size = GoldLocationDot.driverOverlaySize;
    final first = DriverSonarMarker.waveProgress(0.2, 0.0);
    final second = DriverSonarMarker.waveProgress(0.2, 0.5);

    expect(first, closeTo(0.2, 0.000001));
    expect(second, closeTo(0.7, 0.000001));
    expect(
      DriverSonarMarker.waveRadius(second, size),
      greaterThan(DriverSonarMarker.waveRadius(first, size)),
    );
    expect(
      DriverSonarMarker.waveOpacity(second),
      lessThan(DriverSonarMarker.waveOpacity(first)),
    );
    expect(
      DriverSonarMarker.waveProgress(0.75, 0.5),
      closeTo(0.25, 0.000001),
    );
  });

  testWidgets('animation ticks rebuild the waves and request a repaint',
      (tester) async {
    final controller = AnimationController(
      vsync: const TestVSync(),
      value: 0.1,
    );
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: DriverSonarMarker(animation: controller, bearing: 25),
          ),
        ),
      ),
    );

    final marker = tester.widget<GoldLocationDotOverlay>(
      find.byType(GoldLocationDotOverlay),
    );
    expect(marker.bearing, 25);
    expect(marker.size, GoldLocationDot.driverOverlaySize);

    final wavePaint = find
        .descendant(
          of: find.byType(DriverSonarMarker),
          matching: find.byType(CustomPaint),
        )
        .first;
    final before = tester.widget<CustomPaint>(wavePaint).painter!;

    controller.value = 0.45;
    await tester.pump();

    final after = tester.widget<CustomPaint>(wavePaint).painter!;
    expect(after, isNot(same(before)));
    expect(after.shouldRepaint(before), isTrue);
  });

  testWidgets('the marker and its overflowed waves do not block map taps',
      (tester) async {
    var mapTaps = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Stack(
            children: [
              Positioned.fill(
                child: GestureDetector(
                  onTap: () => mapTaps++,
                  child: const ColoredBox(color: Colors.black),
                ),
              ),
              const Center(
                child: DriverSonarMarker(
                  animation: AlwaysStoppedAnimation<double>(0.25),
                  bearing: 40,
                  size: 100,
                ),
              ),
            ],
          ),
        ),
      ),
    );

    final center = tester.getCenter(find.byType(DriverSonarMarker));
    await tester.tapAt(center);
    await tester.tapAt(center + const Offset(60, 0));
    await tester.pump();

    expect(mapTaps, 2);
  });

  group('driver sonar lifecycle', () {
    final controller = File('lib/screens/driver/driver_online_controller.dart')
        .readAsStringSync();
    final widgets = File('lib/screens/driver/driver_online_widgets.dart')
        .readAsStringSync();
    final screen =
        File('lib/screens/driver/driver_online_screen.dart').readAsStringSync();
    final sonar =
        File('lib/widgets/driver_sonar_marker.dart').readAsStringSync();

    test('runs offline AND online, only searching, visible and in foreground',
        () {
      final start = controller.indexOf('bool get _driverSonarActive');
      final gate = controller.substring(start, start + 320);
      for (final needle in [
        '_phase == _Phase.searching',
        '_mapMounted',
        '_mapStyleLoaded',
        '_firstRenderDone',
        '_appInForeground',
      ]) {
        expect(gate, contains(needle));
      }
      expect(gate, isNot(contains('_driverOnline')),
          reason: 'the owner chose the sonar for the WHOLE online shift too');
      expect(controller, contains('_driverSonarCtrl!.stop();'));
      expect(controller, contains('_syncDriverSonar();'));
      expect(screen, contains('_driverSonarCtrl?.dispose();'));
    });

    test('shares the arrow pixel and adds no native work', () {
      expect(widgets,
          contains('_driverSonarActive && _driverSonarCtrl != null'));
      expect(sonar.contains('mapbox'), isFalse);
      expect(sonar.contains('rootBundle'), isFalse);
    });
  });
}
