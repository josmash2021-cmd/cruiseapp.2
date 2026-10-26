import 'dart:ui' show Offset;

class MapGestureGuard {
  static const double dragThreshold = 6.0;

  Offset? _down;
  bool _active = false;

  bool get isActive => _active;

  bool pointerDown(Offset position, int pointerCount) {
    if (pointerCount >= 2) return _activate();
    _down = position;
    return false;
  }

  bool pointerMove(Offset position, int pointerCount) {
    if (_active) return false;
    if (pointerCount >= 2) return _activate();
    final down = _down;
    if (down == null) return false;
    if ((position - down).distance < dragThreshold) return false;
    return _activate();
  }

  void pointerUp(int pointerCount) {
    if (pointerCount <= 0) reset();
  }

  void reset() {
    _down = null;
    _active = false;
  }

  bool _activate() {
    if (_active) return false;
    _active = true;
    return true;
  }
}
