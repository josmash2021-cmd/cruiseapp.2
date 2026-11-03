import 'package:cruise_app/widgets/tracking/rider_trip_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The rider's trip sheet (owner 2026-11-03, drawing J6zTb8hfeKDqfFbzpx5jXb):
/// semi-open at rest, opens by tap or swipe and closes the same way, the map
/// blurred behind when open; the hint once per trip, gone after 5 s or at the
/// first touch.
void main() {
  const hint = 'Desliza hacia arriba para ver los detalles de tu viaje';

  Widget host({
    int? trip = 1,
    String? hintText = hint,
    RiderTripSheetController? controller,
    ValueChanged<double>? onRest,
  }) {
    return MaterialApp(
      home: MediaQuery(
        data: const MediaQueryData(
          size: Size(390, 844),
          padding: EdgeInsets.only(top: 47, bottom: 34),
        ),
        child: Scaffold(
          backgroundColor: const Color(0xFF0B1434),
          body: Stack(
            children: [
              Positioned.fill(
                child: RiderTripSheet(
                  controller: controller,
                  hint: hintText,
                  hintTripId: trip,
                  onRestHeightChanged: onRest,
                  face: const SizedBox(
                    height: 230,
                    child: Center(child: Text('FACE')),
                  ),
                  body: const SizedBox(
                    height: 640,
                    child: Center(child: Text('BODY')),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void phone(WidgetTester t) {
    t.view.physicalSize = const Size(390, 844);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
  }

  double bodyOpacity(WidgetTester t) => t
      .widget<Opacity>(find
          .ancestor(of: find.text('BODY'), matching: find.byType(Opacity))
          .first)
      .opacity;

  testWidgets('rests semi-open and reports its resting height', (t) async {
    phone(t);
    double? rest;
    await t.pumpWidget(host(trip: 101, onRest: (h) => rest = h));
    await t.pump();
    await t.pump(const Duration(milliseconds: 100));
    expect(find.text('FACE'), findsOneWidget);
    expect(bodyOpacity(t), 0);
    expect(rest, closeTo(230 + 24, 0.5), reason: 'face + handle');
    expect(t.getRect(find.byKey(const ValueKey('rider-sheet'))).bottom, 844);
    await t.pump(const Duration(seconds: 6));
  });

  testWidgets('a tap opens it, a tap on the map closes it — smoothly',
      (t) async {
    phone(t);
    await t.pumpWidget(host(trip: 102));
    await t.pump();
    await t.tap(find.text('FACE'));
    await t.pump(const Duration(milliseconds: 60));
    expect(bodyOpacity(t), lessThan(1), reason: 'never in one frame');
    await t.pumpAndSettle();
    expect(bodyOpacity(t), 1);
    expect(find.byKey(const ValueKey('rider-sheet-scrim')), findsOneWidget,
        reason: 'the map behind blurs');
    await t.tapAt(const Offset(195, 60));
    await t.pumpAndSettle();
    expect(bodyOpacity(t), 0);
    expect(find.byKey(const ValueKey('rider-sheet-scrim')), findsNothing);
  });

  testWidgets('a swipe up opens it, a swipe down closes it', (t) async {
    phone(t);
    await t.pumpWidget(host(trip: 103));
    await t.pump();
    await t.drag(find.text('FACE'), const Offset(0, -300));
    await t.pumpAndSettle();
    expect(bodyOpacity(t), 1);
    await t.drag(find.text('BODY'), const Offset(0, 320));
    await t.pumpAndSettle();
    expect(bodyOpacity(t), 0);
  });

  testWidgets('the controller opens and closes it', (t) async {
    phone(t);
    final c = RiderTripSheetController();
    await t.pumpWidget(host(trip: 104, controller: c));
    await t.pump();
    c.open();
    await t.pumpAndSettle();
    expect(c.isOpen, isTrue);
    c.close();
    await t.pumpAndSettle();
    expect(c.isOpen, isFalse);
  });

  testWidgets('the hint: 5 s, the map blurred behind, then gone', (t) async {
    phone(t);
    await t.pumpWidget(host(trip: 105));
    await t.pump();
    await t.pump(const Duration(milliseconds: 500));
    expect(find.text(hint), findsOneWidget);
    expect(find.byKey(const ValueKey('rider-sheet-hint-blur')), findsOneWidget);
    await t.pump(const Duration(seconds: 4));
    expect(find.text(hint), findsOneWidget, reason: 'still up at 4.5 s');
    await t.pump(const Duration(seconds: 1));
    await t.pump(const Duration(milliseconds: 600));
    await t.pump(const Duration(milliseconds: 600));
    expect(find.text(hint), findsNothing);
    expect(find.byKey(const ValueKey('rider-sheet-hint-blur')), findsNothing);
  });

  testWidgets('touching the sheet ends the hint, and it never returns that trip',
      (t) async {
    phone(t);
    await t.pumpWidget(host(trip: 106));
    await t.pump();
    await t.pump(const Duration(milliseconds: 300));
    expect(find.text(hint), findsOneWidget);
    await t.drag(find.text('FACE'), const Offset(0, -300));
    await t.pumpAndSettle();
    expect(find.text(hint), findsNothing);
    // Same trip, the page opened again: no hint.
    await t.pumpWidget(const SizedBox());
    await t.pumpWidget(host(trip: 106));
    await t.pump();
    await t.pump(const Duration(milliseconds: 300));
    expect(find.text(hint), findsNothing);
    // A new trip: once more.
    await t.pumpWidget(const SizedBox());
    await t.pumpWidget(host(trip: 107));
    await t.pump();
    await t.pump(const Duration(milliseconds: 300));
    expect(find.text(hint), findsOneWidget);
    await t.pump(const Duration(seconds: 7));
  });
}
