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

/// Slide from right — forward push navigation (e.g. Home → RideRequest → Tracking)
Route<T> slideFromRightRoute<T>(Widget page, {int durationMs = 280}) {
  return PageRouteBuilder<T>(
    pageBuilder: (context, animation, secondaryAnimation) => page,
    transitionDuration: Duration(milliseconds: durationMs),
    reverseTransitionDuration: Duration(milliseconds: (durationMs * 0.78).round()),
    transitionsBuilder: (context, animation, secondaryAnimation, child) {
      final slide = Tween<Offset>(
        begin: const Offset(1.0, 0),
        end: Offset.zero,
      ).animate(CurvedAnimation(parent: animation, curve: _easeOutQuart));
      final fade = CurvedAnimation(
        parent: animation,
        curve: const Interval(0.0, 0.5, curve: Curves.easeIn),
      );
      return FadeTransition(
        opacity: fade,
        child: SlideTransition(position: slide, child: child),
      );
    },
  );
}

/// Slide up from bottom — bottom sheets and modal overlays
Route<T> slideUpFadeRoute<T>(Widget page, {int durationMs = 350}) {
  return PageRouteBuilder<T>(
    pageBuilder: (context, animation, secondaryAnimation) => page,
    transitionDuration: Duration(milliseconds: durationMs),
    reverseTransitionDuration: Duration(milliseconds: (durationMs * 0.78).round()),
    transitionsBuilder: (context, animation, secondaryAnimation, child) {
      final slide = Tween<Offset>(
        begin: const Offset(0, 0.08),
        end: Offset.zero,
      ).animate(CurvedAnimation(parent: animation, curve: _easeOutExpo));
      final fade = CurvedAnimation(
        parent: animation,
        curve: const Interval(0.0, 0.6, curve: Curves.easeIn),
      );
      return FadeTransition(
        opacity: fade,
        child: SlideTransition(position: slide, child: child),
      );
    },
  );
}

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
