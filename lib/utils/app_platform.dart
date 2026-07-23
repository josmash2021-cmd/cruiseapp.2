import 'dart:io' show Platform;
import 'package:flutter/foundation.dart' show kIsWeb;

/// Web-safe platform checks. On web, every dart:io Platform.* getter throws
/// UnsupportedError, so guard with kIsWeb (const → short-circuits at compile
/// time). Web reports false for all native platforms.
class AppPlatform {
  AppPlatform._();
  static bool get isIOS => !kIsWeb && Platform.isIOS;
  static bool get isAndroid => !kIsWeb && Platform.isAndroid;
  static bool get isMacOS => !kIsWeb && Platform.isMacOS;
  static bool get isWindows => !kIsWeb && Platform.isWindows;
  static bool get isLinux => !kIsWeb && Platform.isLinux;
  static String get operatingSystem => kIsWeb ? 'web' : Platform.operatingSystem;
}
