import 'package:shared_preferences/shared_preferences.dart';

/// Cached SharedPreferences singleton — avoids redundant getInstance() calls.
/// Call [init] once at startup; after that use [instance] synchronously.
class PrefsCache {
  static SharedPreferences? _prefs;

  /// Initialize eagerly at app startup.
  static Future<SharedPreferences> init() async {
    _prefs ??= await SharedPreferences.getInstance();
    return _prefs!;
  }

  /// Returns the cached instance, or fetches it if not yet initialized.
  static Future<SharedPreferences> get instance async {
    return _prefs ?? await init();
  }

  /// Synchronous access — only use after [init] has completed.
  /// Returns null if not yet initialized.
  static SharedPreferences? get instanceSync => _prefs;
}
