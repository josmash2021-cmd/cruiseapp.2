import 'dart:async';

import 'package:flutter/foundation.dart';

/// Ultra-fast debouncer for batching UI updates.
/// Eliminates redundant rebuilds by batching rapid-fire notifications.
class FastDebouncer {
  Timer? _timer;
  final Duration delay;
  VoidCallback? _pending;

  FastDebouncer({this.delay = const Duration(milliseconds: 16)}); // 1 frame @ 60fps

  void call(VoidCallback action) {
    _pending = action;
    _timer?.cancel();
    _timer = Timer(delay, () {
      _pending?.call();
      _pending = null;
    });
  }

  void dispose() {
    _timer?.cancel();
    _pending = null;
  }
}

/// Throttler that ensures a minimum interval between calls.
/// Perfect for GPS updates, scroll events, etc.
class FastThrottler {
  DateTime? _lastCall;
  final Duration interval;

  FastThrottler({this.interval = const Duration(milliseconds: 100)});

  bool call(VoidCallback action) {
    final now = DateTime.now();
    if (_lastCall == null || now.difference(_lastCall!) >= interval) {
      _lastCall = now;
      action();
      return true;
    }
    return false;
  }
}
