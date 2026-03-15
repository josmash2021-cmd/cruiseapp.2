import 'package:flutter/material.dart';

/// Theme-aware colors for all driver screens.
/// Dark mode keeps the current dark palette; light mode switches to a clean
/// light palette while preserving the gold brand color.
class DriverColors {
  DriverColors._(this._dark);

  factory DriverColors.of(BuildContext context) =>
      DriverColors._(Theme.of(context).brightness == Brightness.dark);

  final bool _dark;

  static const gold = Color(0xFFE8C547);

  Color get bg => _dark ? const Color(0xFF0A0A0A) : const Color(0xFFF2F2F7);
  Color get surface =>
      _dark ? const Color(0xFF141414) : const Color(0xFFE8E8ED);
  Color get card => _dark ? const Color(0xFF1C1C1E) : Colors.white;
  Color get text => _dark ? Colors.white : const Color(0xFF1C1C1E);
  Color get textSecondary => _dark ? Colors.white60 : const Color(0xFF6E6E73);
  Color get icon => _dark ? Colors.white70 : const Color(0xFF3A3A3C);
  Color get divider => _dark
      ? Colors.white.withValues(alpha: 0.06)
      : Colors.black.withValues(alpha: 0.08);
  Color get glassBg => _dark
      ? const Color(0xFF2C2C2E)
      : const Color(0xFFE5E5EA);
}
