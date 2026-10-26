import 'package:geolocator/geolocator.dart';

import '../models/lat_lng.dart';
import 'camera_action_gate.dart';

class RecenterLandingGuard {
  const RecenterLandingGuard(
    this.sequence,
    this.target, {
    this.toleranceMeters = 4.0,
  });

  final int sequence;
  final LatLng target;
  final double toleranceMeters;

  bool isLanding(CameraActionGate gate, LatLng cameraCenter) {
    if (!gate.isCurrent(sequence)) return false;
    final meters = Geolocator.distanceBetween(
      target.latitude,
      target.longitude,
      cameraCenter.latitude,
      cameraCenter.longitude,
    );
    return meters <= toleranceMeters;
  }
}
