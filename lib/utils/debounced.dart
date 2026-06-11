import 'dart:async';

/// Creates a debounced version of [action] that ignores subsequent
/// calls for [duration].
VoidCallback debounce(VoidCallback action, {Duration duration = const Duration(milliseconds: 500)}) {
  Timer? timer;
  return () {
    if (timer?.isActive ?? false) return;
    timer = Timer(duration, () {});
    action();
  };
}

typedef VoidCallback = void Function();
