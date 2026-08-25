import 'package:flutter/material.dart';

/// Shared dark-neumorphism style system for the app.
///
/// Pure black makes neumorphic shadows invisible, so the base is a very
/// dark grey. Every raised/sunken surface should use [neuBox] — no ad-hoc
/// shadows. Constants are top-level (project rule: part files can only
/// reference top-level constants inside const expressions).
const neuBase = Color(0xFF14141A);    // screen/sheet background
const neuSurface = Color(0xFF1C1C24); // raised surface (cards)
const neuPressed = Color(0xFF101014); // sunken surface (pressed wells)

/// Single neumorphic decoration shared across screens.
/// [borderColor]/[borderWidth] override the default faint border (used
/// for selected/error states that need a colored edge).
BoxDecoration neuBox({
  double radius = 24,
  bool pressed = false,
  Color? borderColor,
  double borderWidth = 1,
}) => BoxDecoration(
  color: pressed ? neuPressed : neuSurface,
  borderRadius: BorderRadius.circular(radius),
  // Soft, and pulled back inside the element's own footprint.
  //
  // The dark side used to be black at 55% offset 6 with no spread. Against a
  // #14141A ground that does not read as depth — it reads as a second copy of
  // the card sitting behind it, down and to the right, with a visible edge of
  // its own. On an 87 px tier card a 6 px offset is 7% of its width, so the
  // duplicate is not even subtle.
  //
  // Lower alpha, more blur, and a negative spread so the shadow starts inside
  // the box and bleeds out rather than beginning at the edge already at full
  // strength. That is the difference between a lit surface and a stamp.
  boxShadow: pressed
      ? [BoxShadow(color: Colors.black.withValues(alpha: 0.55), offset: const Offset(3, 3), blurRadius: 8, spreadRadius: -3)]
      : [
          BoxShadow(color: Colors.black.withValues(alpha: 0.32), offset: const Offset(4, 4), blurRadius: 16, spreadRadius: -4),
          BoxShadow(color: Colors.white.withValues(alpha: 0.04), offset: const Offset(-3, -3), blurRadius: 12, spreadRadius: -4),
        ],
  border: Border.all(
    color: borderColor ?? Colors.white.withValues(alpha: 0.04),
    width: borderWidth,
  ),
);

/// Full-page neu backdrop: flat [neuBase]. It used to carry a fine dot
/// grid on top — removed everywhere 2026-08-25 (user spec: no speckled
/// ground on any page). Kept as the shared backdrop so every page keeps
/// the exact same base color.
class NeuDotsBackdrop extends StatelessWidget {
  const NeuDotsBackdrop({super.key});

  @override
  Widget build(BuildContext context) {
    return const ColoredBox(color: neuBase);
  }
}
