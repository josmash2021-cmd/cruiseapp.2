import 'package:flutter/material.dart';
import 'package:animations/animations.dart';

/// Collection of premium page transitions for the app.
/// Each transition is a [PageRouteBuilder] factory with unique animations.
/// Tuned for 60fps buttery-smooth feel.

// ─── Shared Axis (Z) (Search bar tap → Search screen) ───
// A profound depth transition used by modern Google/Android apps
Route<T> sharedAxisZRoute<T>(Widget page, {int durationMs = 400}) {
  return PageRouteBuilder<T>(
    pageBuilder: (context, animation, secondaryAnimation) => page,
    transitionDuration: Duration(milliseconds: durationMs),
    reverseTransitionDuration: Duration(milliseconds: (durationMs * 0.8).round()),
    transitionsBuilder: (context, animation, secondaryAnimation, child) {
      return SharedAxisTransition(
        animation: animation,
        secondaryAnimation: secondaryAnimation,
        transitionType: SharedAxisTransitionType.scaled,
        fillColor: Colors.transparent,
        child: child,
      );
    },
  );
}

// ─── Fade Through (Tab switching / Step changes) ───
Route<T> fadeThroughRoute<T>(Widget page, {int durationMs = 350}) {
  return PageRouteBuilder<T>(
    pageBuilder: (context, animation, secondaryAnimation) => page,
    transitionDuration: Duration(milliseconds: durationMs),
    transitionsBuilder: (context, animation, secondaryAnimation, child) {
      return FadeThroughTransition(
        animation: animation,
        secondaryAnimation: secondaryAnimation,
        fillColor: Colors.transparent,
        child: child,
      );
    },
  );
}

// ─── Slide + Fade (Home → Map) ───
// A smooth slide from right with fade and subtle scale
Route<T> slideUpFadeRoute<T>(Widget page, {int durationMs = 450}) {
  return PageRouteBuilder<T>(
    pageBuilder: (context, animation, secondaryAnimation) => page,
    transitionDuration: Duration(milliseconds: durationMs),
    reverseTransitionDuration: Duration(milliseconds: (durationMs * 0.75).round()),
    transitionsBuilder: (context, animation, secondaryAnimation, child) {
      final curved = CurvedAnimation(
        parent: animation,
        curve: Curves.easeOutCubic,
        reverseCurve: Curves.easeInCubic,
      );
      // Outgoing page: scale down + fade
      final secondaryCurved = CurvedAnimation(
        parent: secondaryAnimation,
        curve: Curves.easeOutCubic,
      );
      return ScaleTransition(
        scale: Tween<double>(begin: 1.0, end: 0.92).animate(secondaryCurved),
        child: FadeTransition(
          opacity: Tween<double>(begin: 1.0, end: 0.6).animate(secondaryCurved),
          child: SlideTransition(
            position: Tween<Offset>(
              begin: const Offset(0, 0.06),
              end: Offset.zero,
            ).animate(curved),
            child: FadeTransition(
              opacity: Tween<double>(begin: 0, end: 1).animate(
                CurvedAnimation(parent: animation, curve: const Interval(0, 0.7, curve: Curves.easeOut)),
              ),
              child: child,
            ),
          ),
        ),
      );
    },
  );
}

// ─── Scale + Fade (Search bar tap → Map screen) ───
// Expands from the center like the search bar is growing into the map
Route<T> scaleExpandRoute<T>(Widget page, {int durationMs = 500}) {
  return PageRouteBuilder<T>(
    pageBuilder: (context, animation, secondaryAnimation) => page,
    transitionDuration: Duration(milliseconds: durationMs),
    reverseTransitionDuration: Duration(milliseconds: (durationMs * 0.65).round()),
    transitionsBuilder: (context, animation, secondaryAnimation, child) {
      final curved = CurvedAnimation(
        parent: animation,
        curve: Curves.easeOutExpo,
        reverseCurve: Curves.easeInExpo,
      );
      final secondaryCurved = CurvedAnimation(
        parent: secondaryAnimation,
        curve: Curves.easeOutCubic,
      );
      return ScaleTransition(
        scale: Tween<double>(begin: 1.0, end: 0.92).animate(secondaryCurved),
        child: FadeTransition(
          opacity: Tween<double>(begin: 1.0, end: 0.5).animate(secondaryCurved),
          child: FadeTransition(
            opacity: Tween<double>(begin: 0, end: 1).animate(
              CurvedAnimation(parent: animation, curve: const Interval(0, 0.5, curve: Curves.easeOut)),
            ),
            child: ScaleTransition(
              scale: Tween<double>(begin: 0.94, end: 1.0).animate(curved),
              child: child,
            ),
          ),
        ),
      );
    },
  );
}

// ─── Shared axis vertical (Trip receipt) ───
// Slides up from below with fade — used for detail/receipt screens
Route<T> sharedAxisVerticalRoute<T>(Widget page, {int durationMs = 450}) {
  return PageRouteBuilder<T>(
    pageBuilder: (context, animation, secondaryAnimation) => page,
    transitionDuration: Duration(milliseconds: durationMs),
    reverseTransitionDuration: Duration(milliseconds: (durationMs * 0.7).round()),
    transitionsBuilder: (context, animation, secondaryAnimation, child) {
      final fadeIn = CurvedAnimation(
        parent: animation,
        curve: const Interval(0, 0.6, curve: Curves.easeOut),
      );
      final slideIn = CurvedAnimation(
        parent: animation,
        curve: Curves.easeOutCubic,
      );
      return FadeTransition(
        opacity: fadeIn,
        child: SlideTransition(
          position: Tween<Offset>(
            begin: const Offset(0, 0.12),
            end: Offset.zero,
          ).animate(slideIn),
          child: child,
        ),
      );
    },
  );
}

// ─── Smooth fade (Splash → Home) ───
// A smooth crossfade with a slight zoom
Route<T> smoothFadeRoute<T>(Widget page, {int durationMs = 700}) {
  return PageRouteBuilder<T>(
    pageBuilder: (context, animation, secondaryAnimation) => page,
    transitionDuration: Duration(milliseconds: durationMs),
    reverseTransitionDuration: Duration(milliseconds: (durationMs * 0.6).round()),
    transitionsBuilder: (context, animation, secondaryAnimation, child) {
      final curved = CurvedAnimation(
        parent: animation,
        curve: Curves.easeOutQuart,
      );
      return FadeTransition(
        opacity: curved,
        child: ScaleTransition(
          scale: Tween<double>(begin: 1.03, end: 1.0).animate(curved),
          child: child,
        ),
      );
    },
  );
}

// ─── Slide from right (for general navigations) ───
Route<T> slideFromRightRoute<T>(Widget page, {int durationMs = 400}) {
  return PageRouteBuilder<T>(
    pageBuilder: (context, animation, secondaryAnimation) => page,
    transitionDuration: Duration(milliseconds: durationMs),
    reverseTransitionDuration: Duration(milliseconds: (durationMs * 0.7).round()),
    transitionsBuilder: (context, animation, secondaryAnimation, child) {
      final curved = CurvedAnimation(
        parent: animation,
        curve: Curves.easeOutCubic,
        reverseCurve: Curves.easeInCubic,
      );
      // Outgoing page slides left slightly + fades
      final secondaryCurved = CurvedAnimation(
        parent: secondaryAnimation,
        curve: Curves.easeOutCubic,
      );
      return SlideTransition(
        position: Tween<Offset>(
          begin: Offset.zero,
          end: const Offset(-0.08, 0),
        ).animate(secondaryCurved),
        child: FadeTransition(
          opacity: Tween<double>(begin: 1.0, end: 0.7).animate(secondaryCurved),
          child: SlideTransition(
            position: Tween<Offset>(
              begin: const Offset(0.20, 0),
              end: Offset.zero,
            ).animate(curved),
            child: FadeTransition(
              opacity: Tween<double>(begin: 0.3, end: 1).animate(
                CurvedAnimation(parent: animation, curve: const Interval(0, 0.6, curve: Curves.easeOut)),
              ),
              child: child,
            ),
          ),
        ),
      );
    },
  );
}
