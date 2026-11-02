/// A camera bearing that FOLLOWS a target bearing on a critically damped
/// spring, the shortest way round.
///
/// Why the camera needs its own (owner report 2026-11-01, "cuando la cámara
/// gira no gira fluido, gira por pasos"): the arrow's bearing comes from the
/// car's course, which arrives about once a second. [SmoothMotion] glides the
/// arrow between those samples, but only for 0.75 s of extrapolated turn
/// (more overshoots past the end of a real turn), so through a turn the arrow
/// rotates, rests a quarter of a second, and catches up on the next fix. A
/// camera that copies the arrow frame by frame shows that rhythm as a map
/// turning in steps. A critically damped spring on top keeps the map turning
/// through the rests and lands without overshoot; the arrow overlay shows the
/// small difference (arrow bearing − camera bearing) at once.
///
/// Same law as the navigation chase (`_stepCamBearing` in driver_nav_view):
/// `a = ω²·err − 2ω·v`. Pure Dart, no Flutter — the caller owns the frame
/// clock and passes the frame delta in seconds.
class BearingSpring {
  BearingSpring({required this.omega});

  /// Natural frequency (rad/s). Lag on a steady turn is 2/ω seconds; the
  /// residual ripple of a 1 Hz staircase scales with ω²/(ω² + (2π)²).
  final double omega;

  double? _value;
  double _velocity = 0;

  /// Current camera bearing in [0, 360), or null before the first [step] /
  /// after [reset].
  double? get value => _value;

  /// Current turn rate, degrees per second.
  double get velocity => _velocity;

  /// Signed shortest arc from [from] to [to], in (-180, 180].
  static double shortestArc(double from, double to) {
    var d = (to - from) % 360;
    if (d > 180) d -= 360;
    if (d <= -180) d += 360;
    return d;
  }

  /// Forget the state: the next [step] starts wherever it is seeded.
  void reset() {
    _value = null;
    _velocity = 0;
  }

  /// Pin the camera to [bearing] with no motion left.
  void snap(double bearing) {
    if (!bearing.isFinite) return;
    _value = bearing % 360;
    _velocity = 0;
  }

  /// Advances one frame of [dtSec] toward [target] and returns the new
  /// bearing. With no state yet it starts at [seed] (the camera's real
  /// bearing, so engaging the chase never rotates the map in one frame), or
  /// at [target] when there is no seed.
  double step(double target, double dtSec, {double? seed, double? omega}) {
    // [omega] overrides the spring's own frequency for this step only.
    final w = omega ?? this.omega;
    if (!target.isFinite) return _value ?? 0;
    final cur = _value;
    if (cur == null) {
      _value = ((seed != null && seed.isFinite) ? seed : target) % 360;
      _velocity = 0;
      if (seed == null || !seed.isFinite) return _value!;
    }
    if (dtSec <= 0 || !dtSec.isFinite) return _value!;
    // Frame deltas above 50 ms are a hitch, not motion: integrate them as
    // 50 ms so a stalled frame cannot fling the camera.
    final dt = dtSec > 0.05 ? 0.05 : dtSec;
    final err = shortestArc(_value!, target);
    final acc = w * w * err - 2 * w * _velocity;
    _velocity += acc * dt;
    _value = (_value! + _velocity * dt + 360) % 360;
    return _value!;
  }

  /// True when the camera sits on [target] (< 0.1°) and has stopped turning
  /// (< 0.5°/s) — nothing left to animate.
  bool isSettled(double target) {
    final cur = _value;
    if (cur == null) return true;
    return shortestArc(cur, target).abs() < 0.1 && _velocity.abs() < 0.5;
  }
}
