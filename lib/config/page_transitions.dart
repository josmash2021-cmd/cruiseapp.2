import 'package:flutter/material.dart';

const _fadeDuration = Duration(milliseconds: 280);
const _fadeReverse = Duration(milliseconds: 220);
const _easeOutQuart = Cubic(0.25, 1, 0.5, 1);
const _easeOutExpo = Cubic(0.16, 1, 0.3, 1);

Route<T> _fadeRoute<T>(Widget page, {int? durationMs}) {
  final dur = durationMs != null ? Duration(milliseconds: durationMs) : _fadeDuration;
  final rev = durationMs != null ? Duration(milliseconds: (durationMs * 0.78).round()) : _fadeReverse;
  return PageRouteBuilder<T>(
    pageBuilder: (context, animation, secondaryAnimation) => page,
    transitionDuration: dur,
    reverseTransitionDuration: rev,
    transitionsBuilder: (context, animation, secondaryAnimation, child) {
      return FadeTransition(
        opacity: CurvedAnimation(parent: animation, curve: Curves.easeInOut),
        child: child,
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
