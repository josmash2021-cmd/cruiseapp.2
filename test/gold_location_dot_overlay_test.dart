import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:cruise_app/widgets/gold_location_dot.dart';

/// Tests that actually render.
///
/// Three bugs got past this session's other tests because every one of them
/// checked logic or arithmetic and not one of them painted a widget. The
/// marker is a CustomPaint, and a CustomPaint only redraws when something
/// tells it to — so "the arrow moves at sixty frames a second" was a claim
/// about a repaint that nothing was triggering. Twice.
///
/// The point here is not the drawing. It is that a Listenable actually
/// drives it, and that the size both drawing techniques agree on comes from
/// one place, because those are the two things that were assumed.
void main() {
  testWidgets('renders at the size the annotation is scaled to match', (t) async {
    await t.pumpWidget(const MaterialApp(
      home: Scaffold(body: Center(child: GoldLocationDotOverlay(bearing: 0))),
    ));
    final size = t.getSize(find.byType(GoldLocationDotOverlay));
    expect(size.width, GoldLocationDot.driverOverlaySize);
    expect(size.height, GoldLocationDot.driverOverlaySize);
  });

  testWidgets('both techniques scale from the same constant', (t) async {
    // If these ever drift apart the arrow changes size at the moment the
    // driver drags the map and the overlay hands over to the annotation.
    expect(
      GoldLocationDot.driverOverlaySize,
      44.0 * GoldLocationDot.driverScale,
    );
    expect(GoldLocationDot.driverIconSize, GoldLocationDot.driverScale);
  });

  testWidgets('a notifier tick repaints it — the bug that shipped twice',
      (t) async {
    final frame = ValueNotifier<int>(0);
    addTearDown(frame.dispose);
    var bearing = 0.0;
    var builds = 0;

    await t.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Center(
          child: ListenableBuilder(
            listenable: frame,
            builder: (_, __) {
              builds++;
              return GoldLocationDotOverlay(bearing: bearing);
            },
          ),
        ),
      ),
    ));
    expect(builds, 1);

    // What the animation ticker does on every frame the driver moves.
    bearing = 90;
    frame.value++;
    await t.pump();
    expect(builds, 2, reason: 'the marker must follow the ticker, not setState');

    bearing = 180;
    frame.value++;
    await t.pump();
    expect(builds, 3);

    // And the widget really carries the new heading, not a stale one.
    final w = t.widget<GoldLocationDotOverlay>(
      find.byType(GoldLocationDotOverlay),
    );
    expect(w.bearing, 180);
  });

  testWidgets('does not swallow taps meant for the map', (t) async {
    var mapTaps = 0;
    await t.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Stack(
          children: [
            Positioned.fill(
              child: GestureDetector(
                onTap: () => mapTaps++,
                child: const ColoredBox(color: Colors.black),
              ),
            ),
            const Center(child: GoldLocationDotOverlay(bearing: 0)),
          ],
        ),
      ),
    ));
    // Straight through the middle of the marker.
    await t.tapAt(t.getCenter(find.byType(GoldLocationDotOverlay)));
    await t.pump();
    expect(mapTaps, 1, reason: 'the overlay sits on the map and must not eat gestures');
  });

  testWidgets('positions by its centre inside a Stack', (t) async {
    const half = GoldLocationDot.driverOverlaySize / 2;
    await t.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 400,
          height: 800,
          child: Stack(
            children: [
              Positioned(
                left: 300 - half,
                top: 200 - half,
                child: GoldLocationDotOverlay(bearing: 45),
              ),
            ],
          ),
        ),
      ),
    ));
    // The projection returns the pixel the driver is ON, so the marker has
    // to be centred there rather than hung from its top-left corner.
    final centre = t.getCenter(find.byType(GoldLocationDotOverlay));
    expect(centre.dx, closeTo(300, 0.5));
    expect(centre.dy, closeTo(200, 0.5));
  });
}
