import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:cruise_app/screens/airport_terminal_sheet.dart';
import 'package:cruise_app/screens/airport_direction_screen.dart';

void main() {
  Future<void> openSheet(WidgetTester tester,
      {AirportDirection? initialDirection}) async {
    await tester.pumpWidget(MaterialApp(
      theme: ThemeData.dark(),
      home: Scaffold(body: Container(color: Colors.green)), // pretend map
    ));
    final ctx = tester.element(find.byType(Scaffold));
    showModalBottomSheet<AirportSelection>(
      context: ctx,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      useSafeArea: true,
      builder: (_) => AirportTerminalSheet(
        isDark: true,
        initialDirection: initialDirection,
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
  }

  testWidgets('sheet over map with notch fills screen; list reaches bottom',
      (tester) async {
    tester.view.physicalSize = const Size(1170, 2532); // iPhone 14 Pro
    tester.view.devicePixelRatio = 3;
    tester.view.padding =
        FakeViewPadding(left: 0, top: 47 * 3, right: 0, bottom: 34 * 3);
    addTearDown(tester.view.reset);

    await openSheet(tester, initialDirection: AirportDirection.toAirport);

    final sheetSize = tester.getSize(find.byType(AirportTerminalSheet));
    final listBottom = tester.getBottomLeft(find.byType(ListView));
    final screen = tester.view.physicalSize / tester.view.devicePixelRatio;
    debugPrint('screen=$screen sheet=$sheetSize listBottom=$listBottom');

    expect(sheetSize.height, greaterThan(screen.height * 0.9));
    // The results list must reach near the bottom of the screen.
    expect(listBottom.dy, greaterThan(screen.height * 0.9));
  });

  testWidgets('step 0 direction picker does not overflow on short screens',
      (tester) async {
    tester.view.physicalSize = const Size(720, 1200); // 360x600 logical
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);

    await openSheet(tester); // no initialDirection -> step 0

    expect(tester.takeException(), isNull);
    expect(find.byType(AirportTerminalSheet), findsOneWidget);
  });

  testWidgets('AirportDirectionScreen does not overflow on short screens',
      (tester) async {
    tester.view.physicalSize = const Size(720, 1200);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(const MaterialApp(
      home: AirportDirectionScreen(),
    ));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));

    expect(tester.takeException(), isNull);
  });
}
