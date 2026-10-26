import 'package:geolocator/geolocator.dart';

class GpsFixPolicy {
  int? _lastTimestampMs;
  int? _lastFutureTimestampMs;

  bool accept(Position pos) {
    final timestamp = pos.timestamp.millisecondsSinceEpoch;
    if (timestamp <= 0) return true;
    final now = DateTime.now().millisecondsSinceEpoch;
    if (timestamp > now + 5000) {
      final previousFuture = _lastFutureTimestampMs;
      if (previousFuture != null && timestamp <= previousFuture) return false;
      _lastFutureTimestampMs = timestamp;
      return true;
    }
    final previous = _lastTimestampMs;
    if (previous != null && timestamp <= previous) return false;
    // A bad future timestamp never replaces the last valid ordering anchor.
    _lastTimestampMs = timestamp;
    return true;
  }

  void reset() {
    _lastTimestampMs = null;
    _lastFutureTimestampMs = null;
  }
}
