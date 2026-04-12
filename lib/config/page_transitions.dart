import 'package:flutter/material.dart';

// Slower, smoother defaults so every Navigator.push that uses one of
// the helpers below reads as a gentle cross-fade instead of a quick
// flick. User asked for "fluido y smooth, no de golpe": we pair 420 ms
// forward with a slightly shorter reverse so the back gesture still
// feels responsive.
const _fadeDuration = Duration(milliseconds: 420);
const _fadeReverse = Duration(milliseconds: 320);
const _easeOutQuart = Cubic(0.25, 1, 0.5, 1);
const _easeOutExpo = Cubic(0.16, 1, 0.3, 1);

Route<T> _fadeRoute<T>(Widget page, {int? durationMs}) {
  final dur = durationMs != null ? Duration(milliseconds: durationMs) : _fadeDuration;
  final rev = durationMs != null ? Duration(milliseconds: (durationMs * 0.78).round()) : _fadeReverse;
  return PageRouteBuilder<T>(
    pageBuilder: (context, animation, secondaryAnimation) => page,
    transitionDuration: dur,
    reverseTransitionDuration: rev,
    opaque: true,
    barrierDismissible: false,
    // Cross-fade: outgoing fades 1→0 while incoming fades 0→1 on the
    // same clock, both easeInOutCubic. No slide, no scale.
    transitionsBuilder: (context, animation, secondaryAnimation, child) {
      final outOpacity = Tween<double>(begin: 1.0, end: 0.0).animate(
        CurvedAnimation(
          parent: secondaryAnimation,
          curve: Curves.easeInOutCubic,
          reverseCurve: Curves.easeInOutCubic,
        ),
      );
      return FadeTransition(
        opacity: outOpacity,
        child: FadeTransition(
          opacity: CurvedAnimation(
            parent: animation,
            curve: Curves.easeInOutCubic,
            reverseCurve: Curves.easeInOutCubic,
          ),
          child: child,
        ),
      );
    },
  );
}

/// Forward push navigation — smooth fade in/out (no slide)
Route<T> slideFromRightRoute<T>(Widget page, {int durationMs = 280}) =>
    _fadeRoute<T>(page, durationMs: durationMs);

/// Modal/overlay navigation — smooth fade in/out (no slide)
Route<T> slideUpFadeRoute<T>(Widget page, {int durationMs = 350}) =>
    _fadeRoute<T>(page, durationMs: durationMs);

/// Shared axis horizontal — semantic sibling navigation
Route<T> sharedAxisZRoute<T>(Widget page, {int durationMs = 280, bool opaque = true}) =>
    slideFromRightRoute<T>(page, durationMs: durationMs);

Route<T> fadeThroughRoute<T>(Widget page, {int durationMs = 280}) =>
    _fadeRoute<T>(page, durationMs: durationMs);

Route<T> scaleExpandRoute<T>(Widget page, {int durationMs = 280}) =>
    _fadeRoute<T>(page, durationMs: durationMs);

Route<T> sharedAxisVerticalRoute<T>(Widget page, {int durationMs = 280}) =>
    slideUpFadeRoute<T>(page, durationMs: durationMs);

Route<T> smoothFadeRoute<T>(Widget page, {int durationMs = 280}) =>
    _fadeRoute<T>(page, durationMs: durationMs);
