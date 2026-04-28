import 'package:flutter/material.dart';

// Smooth, fluid transitions — nothing appears abruptly.
// Every screen enters with a gentle motion + fade, never "de golpe".

const _kFast = Duration(milliseconds: 200);
const _kNormal = Duration(milliseconds: 320);
const _kSlow = Duration(milliseconds: 420);

const _easeOutQuart = Cubic(0.25, 1, 0.5, 1);
const _easeOutExpo = Cubic(0.16, 1, 0.3, 1);
const _easeOutBack = Cubic(0.34, 1.56, 0.64, 1);

/// Slide from right + fade — primary navigation (push)
/// Screen slides in from right while fading in, outgoing screen slides left.
Route<T> slideFromRightRoute<T>(Widget page, {int durationMs = 320}) {
  final dur = Duration(milliseconds: durationMs);
  final rev = Duration(milliseconds: (durationMs * 0.75).round());
  
  return PageRouteBuilder<T>(
    pageBuilder: (context, animation, secondaryAnimation) => page,
    transitionDuration: dur,
    reverseTransitionDuration: rev,
    opaque: true,
    transitionsBuilder: (context, animation, secondaryAnimation, child) {
      // Incoming: slide from right + fade in
      final inSlide = Tween<Offset>(
        begin: const Offset(0.08, 0), // Start 8% from right (subtle)
        end: Offset.zero,
      ).animate(CurvedAnimation(
        parent: animation,
        curve: _easeOutQuart,
        reverseCurve: _easeOutExpo,
      ));
      
      final inFade = Tween<double>(begin: 0.0, end: 1.0).animate(
        CurvedAnimation(
          parent: animation,
          curve: const Interval(0.0, 0.6, curve: Curves.easeOut),
          reverseCurve: Curves.easeIn,
        ),
      );
      
      // Outgoing: slide left + fade out
      final outSlide = Tween<Offset>(
        begin: Offset.zero,
        end: const Offset(-0.05, 0), // Exit 5% to left (very subtle)
      ).animate(CurvedAnimation(
        parent: secondaryAnimation,
        curve: _easeOutQuart,
        reverseCurve: _easeOutExpo,
      ));
      
      final outFade = Tween<double>(begin: 1.0, end: 0.0).animate(
        CurvedAnimation(
          parent: secondaryAnimation,
          curve: const Interval(0.0, 0.5, curve: Curves.easeOut),
        ),
      );
      
      return SlideTransition(
        position: outSlide,
        child: FadeTransition(
          opacity: outFade,
          child: SlideTransition(
            position: inSlide,
            child: FadeTransition(
              opacity: inFade,
              child: child,
            ),
          ),
        ),
      );
    },
  );
}

/// Slide up from bottom + fade — for modals, sheets, overlays
Route<T> slideUpFadeRoute<T>(Widget page, {int durationMs = 350}) {
  final dur = Duration(milliseconds: durationMs);
  final rev = Duration(milliseconds: (durationMs * 0.7).round());
  
  return PageRouteBuilder<T>(
    pageBuilder: (context, animation, secondaryAnimation) => page,
    transitionDuration: dur,
    reverseTransitionDuration: rev,
    opaque: false,
    barrierColor: Colors.black.withValues(alpha: 0.4),
    barrierDismissible: true,
    transitionsBuilder: (context, animation, secondaryAnimation, child) {
      final inSlide = Tween<Offset>(
        begin: const Offset(0, 0.15), // Start 15% from bottom
        end: Offset.zero,
      ).animate(CurvedAnimation(
        parent: animation,
        curve: _easeOutQuart,
        reverseCurve: _easeOutExpo,
      ));
      
      final inFade = Tween<double>(begin: 0.0, end: 1.0).animate(
        CurvedAnimation(
          parent: animation,
          curve: const Interval(0.0, 0.5, curve: Curves.easeOut),
        ),
      );
      
      return SlideTransition(
        position: inSlide,
        child: FadeTransition(
          opacity: inFade,
          child: child,
        ),
      );
    },
  );
}

/// Scale + fade — for dialogs, popups, important actions
Route<T> scaleExpandRoute<T>(Widget page, {int durationMs = 280}) {
  final dur = Duration(milliseconds: durationMs);
  
  return PageRouteBuilder<T>(
    pageBuilder: (context, animation, secondaryAnimation) => page,
    transitionDuration: dur,
    reverseTransitionDuration: dur,
    opaque: false,
    barrierColor: Colors.black.withValues(alpha: 0.5),
    transitionsBuilder: (context, animation, secondaryAnimation, child) {
      final scale = Tween<double>(begin: 0.92, end: 1.0).animate(
        CurvedAnimation(
          parent: animation,
          curve: _easeOutBack,
          reverseCurve: Curves.easeIn,
        ),
      );
      
      final fade = Tween<double>(begin: 0.0, end: 1.0).animate(
        CurvedAnimation(
          parent: animation,
          curve: const Interval(0.0, 0.5, curve: Curves.easeOut),
        ),
      );
      
      return FadeTransition(
        opacity: fade,
        child: ScaleTransition(
          scale: scale,
          child: child,
        ),
      );
    },
  );
}

/// Smooth cross-fade — for same-level navigation (tabs, switches)
Route<T> fadeThroughRoute<T>(Widget page, {int durationMs = 280}) {
  final dur = Duration(milliseconds: durationMs);
  
  return PageRouteBuilder<T>(
    pageBuilder: (context, animation, secondaryAnimation) => page,
    transitionDuration: dur,
    reverseTransitionDuration: dur,
    transitionsBuilder: (context, animation, secondaryAnimation, child) {
      final outFade = Tween<double>(begin: 1.0, end: 0.0).animate(
        CurvedAnimation(
          parent: secondaryAnimation,
          curve: const Interval(0.0, 0.5, curve: Curves.easeOut),
        ),
      );
      
      final inFade = Tween<double>(begin: 0.0, end: 1.0).animate(
        CurvedAnimation(
          parent: animation,
          curve: const Interval(0.2, 1.0, curve: Curves.easeOut),
        ),
      );
      
      return FadeTransition(
        opacity: outFade,
        child: FadeTransition(
          opacity: inFade,
          child: child,
        ),
      );
    },
  );
}

/// Shared axis Z — for sibling screens (settings sub-pages)
Route<T> sharedAxisZRoute<T>(Widget page, {int durationMs = 280}) =>
    slideFromRightRoute<T>(page, durationMs: durationMs);

Route<T> sharedAxisVerticalRoute<T>(Widget page, {int durationMs = 320}) =>
    slideUpFadeRoute<T>(page, durationMs: durationMs);

Route<T> smoothFadeRoute<T>(Widget page, {int durationMs = 280}) =>
    fadeThroughRoute<T>(page, durationMs: durationMs);
