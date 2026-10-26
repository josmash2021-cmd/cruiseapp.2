import 'package:flutter_test/flutter_test.dart';

import 'package:cruise_app/map/camera_action_gate.dart';
import 'package:cruise_app/map/recenter_landing_guard.dart';
import 'package:cruise_app/models/lat_lng.dart';

void main() {
  final target = LatLng(25.8, -80.1);

  test('follow resumes only when the actual camera reaches the driver', () {
    final gate = CameraActionGate();
    final sequence = gate.begin();
    final guard = RecenterLandingGuard(sequence, target);

    expect(guard.isLanding(gate, LatLng(25.7, -80.2)), isFalse);
    expect(guard.isLanding(gate, target), isTrue);
  });

  test('a newer gesture or camera action cannot complete an old recenter', () {
    final gate = CameraActionGate();
    final guard = RecenterLandingGuard(gate.begin(), target);
    gate.begin();

    expect(guard.isLanding(gate, target), isFalse);
  });

  test('a point outside the tolerance never triggers a handoff', () {
    final gate = CameraActionGate();
    final guard = RecenterLandingGuard(gate.begin(), target);

    expect(
      guard.isLanding(gate, LatLng(target.latitude + 0.001, target.longitude)),
      isFalse,
    );
  });
}
