import 'package:flutter/material.dart';

/// Proportional scaling utility for responsive layout.
/// Base design: iPhone 14 Pro — 390 × 844 logical pixels.
class Responsive {
  static double _width = 390;
  static double _height = 844;

  /// Call once from MaterialApp builder (runs on every rebuild / orientation change).
  static void init(BuildContext context) {
    final size = MediaQuery.of(context).size;
    _width = size.width;
    _height = size.height;
  }

  /// Scale a width-axis value proportionally.
  static double w(double px) => px * (_width / 390);

  /// Scale a height-axis value proportionally.
  static double h(double px) => px * (_height / 844);

  /// Scale font size (width-based so text stays readable).
  static double sp(double px) => px * (_width / 390);

  /// Responsive horizontal padding (~5 % of screen width).
  static double get horizontalPad => _width * 0.05;

  // ── Screen-size categories ──
  static bool get isSmall => _width < 360;
  static bool get isMedium => _width >= 360 && _width < 414;
  static bool get isLarge => _width >= 414;
}
