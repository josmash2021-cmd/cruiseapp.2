import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

class AccessibilityNotifier extends ChangeNotifier {
  static const _kTextScale = 'a11y_text_scale';
  static const _kHighContrast = 'a11y_high_contrast';
  static const _kReduceMotion = 'a11y_reduce_motion';
  static const _kScreenReaderHints = 'a11y_screen_reader_hints';
  static const _kColorBlindMode = 'a11y_color_blind_mode';
  static const _kHapticFeedback = 'a11y_haptic_feedback';

  double _textScale = 1.0;
  bool _highContrast = false;
  bool _reduceMotion = false;
  bool _screenReaderHints = false;
  String _colorBlindMode = 'none'; // none, protanopia, deuteranopia, tritanopia
  bool _hapticFeedback = true;

  double get textScale => _textScale;
  bool get highContrast => _highContrast;
  bool get reduceMotion => _reduceMotion;
  bool get screenReaderHints => _screenReaderHints;
  String get colorBlindMode => _colorBlindMode;
  bool get hapticFeedback => _hapticFeedback;

  AccessibilityNotifier() {
    _load();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    _textScale = prefs.getDouble(_kTextScale) ?? 1.0;
    _highContrast = prefs.getBool(_kHighContrast) ?? false;
    _reduceMotion = prefs.getBool(_kReduceMotion) ?? false;
    _screenReaderHints = prefs.getBool(_kScreenReaderHints) ?? false;
    _colorBlindMode = prefs.getString(_kColorBlindMode) ?? 'none';
    _hapticFeedback = prefs.getBool(_kHapticFeedback) ?? true;
    notifyListeners();
  }

  Future<void> setTextScale(double v) async {
    _textScale = v;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_kTextScale, v);
  }

  Future<void> setHighContrast(bool v) async {
    _highContrast = v;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kHighContrast, v);
  }

  Future<void> setReduceMotion(bool v) async {
    _reduceMotion = v;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kReduceMotion, v);
  }

  Future<void> setScreenReaderHints(bool v) async {
    _screenReaderHints = v;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kScreenReaderHints, v);
  }

  Future<void> setColorBlindMode(String v) async {
    _colorBlindMode = v;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kColorBlindMode, v);
  }

  Future<void> setHapticFeedback(bool v) async {
    _hapticFeedback = v;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kHapticFeedback, v);
  }
}
