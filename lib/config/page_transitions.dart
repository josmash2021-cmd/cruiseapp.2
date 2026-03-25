import 'package:flutter/material.dart';

/// All page transitions use smooth fade in/out only.
/// No slides, no scale, no bounce — pure fade with easeInOut.

const _fadeDuration = Duration(milliseconds: 280);
const _fadeReverse = Duration(milliseconds: 220);
const _fadeCurve = Curves.easeInOut;

Route<T> _fadeRoute<T>(Widget page, {int? durationMs}) {
  final dur = durationMs != null ? Duration(milliseconds: durationMs) : _fadeDuration;
  final rev = durationMs != null ? Duration(milliseconds: (durationMs * 0.78).round()) : _fadeReverse;
  return PageRouteBuilder<T>(
    pageBuilder: (context, animation, secondaryAnimation) => page,
    transitionDuration: dur,
    reverseTransitionDuration: rev,
    transitionsBuilder: (context, animation, secondaryAnimation, child) {
      return FadeTransition(
        opacity: CurvedAnimation(parent: animation, curve: _fadeCurve),
        child: child,
      );
    },
  );
}

Route<T> sharedAxisZRoute<T>(Widget page, {int durationMs = 280, bool opaque = true}) =>
    _fadeRoute<T>(page, durationMs: durationMs);

Route<T> fadeThroughRoute<T>(Widget page, {int durationMs = 280}) =>
    _fadeRoute<T>(page, durationMs: durationMs);

Route<T> slideUpFadeRoute<T>(Widget page, {int durationMs = 280}) =>
    _fadeRoute<T>(page, durationMs: durationMs);

Route<T> scaleExpandRoute<T>(Widget page, {int durationMs = 280}) =>
    _fadeRoute<T>(page, durationMs: durationMs);

Route<T> sharedAxisVerticalRoute<T>(Widget page, {int durationMs = 280}) =>
    _fadeRoute<T>(page, durationMs: durationMs);

Route<T> smoothFadeRoute<T>(Widget page, {int durationMs = 280}) =>
    _fadeRoute<T>(page, durationMs: durationMs);

Route<T> slideFromRightRoute<T>(Widget page, {int durationMs = 280}) =>
    _fadeRoute<T>(page, durationMs: durationMs);
