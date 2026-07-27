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
BoxDecoration neuBox({double radius = 24, bool pressed = false}) => BoxDecoration(
  color: pressed ? neuPressed : neuSurface,
  borderRadius: BorderRadius.circular(radius),
  boxShadow: pressed
      ? [BoxShadow(color: Colors.black.withValues(alpha: 0.7), offset: const Offset(3, 3), blurRadius: 6, spreadRadius: -2)]
      : [
          BoxShadow(color: Colors.black.withValues(alpha: 0.55), offset: const Offset(6, 6), blurRadius: 14),
          BoxShadow(color: Colors.white.withValues(alpha: 0.045), offset: const Offset(-4, -4), blurRadius: 10),
        ],
  border: Border.all(color: Colors.white.withValues(alpha: 0.04), width: 1),
);
