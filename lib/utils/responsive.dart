import 'package:flutter/material.dart';

/// Proportional scaling utility for responsive layout.
/// Base design: iPhone 14 Pro — 390 × 844 logical pixels.
class Responsive {
  static double _width = 390;
  static double _height = 844;
  static double _pixelRatio = 3.0;

  /// Call once from MaterialApp builder (runs on every rebuild / orientation change).
  static void init(BuildContext context) {
    final mq = MediaQuery.of(context);
    _width = mq.size.width;
    _height = mq.size.height;
    _pixelRatio = mq.devicePixelRatio;
  }

  /// Scale a width-axis value proportionally.
  static double w(double px) => px * (_width / 390);

  /// Scale a height-axis value proportionally.
  static double h(double px) => px * (_height / 844);

  /// Scale font size (width-based so text stays readable).
  static double sp(double px) => px * (_width / 390);

  /// Responsive horizontal padding (~5 % of screen width).
  static double get horizontalPad => _width * 0.05;

  /// Screen width.
  static double get screenWidth => _width;

  /// Screen height.
  static double get screenHeight => _height;

  /// Safe area height (account for notches, etc).
  static double safeHeight(BuildContext context) {
    final padding = MediaQuery.of(context).padding;
    return _height - padding.top - padding.bottom;
  }

  // ── Screen-size categories ──
  static bool get isSmall => _width < 360;      // Small phones (iPhone SE, etc)
  static bool get isMedium => _width >= 360 && _width < 414;  // Standard phones
  static bool get isLarge => _width >= 414 && _width < 600;   // Large phones
  static bool get isTablet => _width >= 600;    // Tablets

  /// Card height for vehicle selection grid — scales with screen size.
  static double get vehicleCardHeight => isSmall ? 140 : (isMedium ? 160 : 180);

  /// Car image size in vehicle cards.
  static double get vehicleCarWidth => isSmall ? 100 : (isMedium ? 120 : 140);
  static double get vehicleCarHeight => isSmall ? 70 : (isMedium ? 80 : 90);

  /// Font size for vehicle name.
  static double get vehicleNameSize => isSmall ? 12 : (isMedium ? 13 : 14);

  /// Grid column count for vehicle selection.
  static int get vehicleGridColumns => isSmall ? 2 : 3;

  /// Bottom sheet height ratio.
  static double get bottomSheetRatio => isSmall ? 0.45 : 0.4;
}
