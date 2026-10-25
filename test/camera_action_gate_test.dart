import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:cruise_app/map/camera_action_gate.dart';

void main() {
  test('only the newest camera action can complete', () {
    final gate = CameraActionGate();
    final fit = gate.begin();
    final recenter = gate.begin();
    final gesture = gate.begin();

    expect(gate.isCurrent(fit), isFalse);
    expect(gate.isCurrent(recenter), isFalse);
    expect(gate.isCurrent(gesture), isTrue);
  });

  test('repeated gestures do not resurrect an older action', () {
    final gate = CameraActionGate();
    final oldFit = gate.begin();
    gate.begin();
    final latest = gate.begin();

    expect(gate.isCurrent(oldFit), isFalse);
    expect(gate.isCurrent(latest), isTrue);
  });

  group('driver camera invariants', () {
    final map =
        File('lib/screens/driver/driver_online_map.dart').readAsStringSync();
    final ctrl = File('lib/screens/driver/driver_online_controller.dart')
        .readAsStringSync();
    final nav =
        File('lib/screens/driver/driver_nav_view.dart').readAsStringSync();

    test('gestures and recenter invalidate older camera actions', () {
      expect(map, contains('_cameraActionGate.begin();'));
      expect(map, contains('_mapPointers < 2'));
      expect(nav, contains('_cameraActionGate.isCurrent(seq)'));
      expect(ctrl, contains('_cameraActionGate.begin();'));
    });

    test('the overlay waits until the native marker is hidden', () {
      expect(
        map,
        contains('if (_goldDotAnnot != null && !_goldDotHidden) return false;'),
      );
      expect(map, contains('iconOpacity: _overlayWantsMarker ? 0.0 : 1.0'));
      expect(map, contains('_goldDotHidden = overlayWanted;'));
    });

    test('native writes stay bounded and belong to the current surface', () {
      expect(ctrl, contains('identical(map, _map)'));
      expect(nav, contains('identical(map, _map)'));
      expect(map, contains('_zoneWaveWriteBusy'));
      expect(map, contains('_zoneWavePendingPhase'));
    });
  });
}
