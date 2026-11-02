// Arriving and leaving a point in navigation (owner design 2026-11-02,
// drawings 7, 10 and 11): ~200 m out the camera straightens to look straight
// down; leaving, it tilts back, the new line draws itself out from the car
// (never a blank map) and the next stretch shows in faded gold.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final nav = File('lib/screens/driver/driver_nav_view.dart').readAsStringSync();

  test('top-down at the pickup and the stop, a timed glide both ways', () {
    expect(nav.contains('case NavPanelStage.waitingStop:\n        return 0.0;'),
        isTrue);
    expect(nav.contains('static const _pitchGlideMs = 1400;'), isTrue);
    expect(nav.contains('Curves.easeInOutCubic.transform(t)'), isTrue);
    expect(nav.contains('(_camBearingSettled && !_pitchGliding)'), isTrue,
        reason: 'a parked car still glides: the settle ticker drives it');
    expect(nav.contains('..rotateX(_pitch * math.pi / 180)'), isTrue,
        reason: 'the overlay arrow lies at the live tilt');
  });

  test('the new leg is seeded from the fetched next leg and draws itself on',
      () {
    expect(nav.contains('_routePts = List.of(next);'), isTrue);
    expect(nav.contains('await _drawOnRoute(mgr);'), isTrue);
    expect(nav.contains('if (drawOn != null && now.isBefore(drawOn)) return;'),
        isTrue,
        reason: 'the erase waits for the line to finish drawing');
    expect(nav.contains('unawaited(_drawRoute());\n        return;'), isTrue,
        reason: 'the full line is written once more at the end');
  });

  test('the next stretch in faded gold, its handle dropped with the surface',
      () {
    expect(nav.contains('lineColor: _gold.withAlpha(_nextLegAlpha).toARGB32(),'),
        isTrue);
    expect(nav.contains('_nextLegAnnot = null;\n        _drawOnTimer?.cancel();'),
        isTrue);
    expect(nav.contains('_drawOnTimer?.cancel();\n    _arrowWatchdog?.cancel();'),
        isTrue);
  });
}
