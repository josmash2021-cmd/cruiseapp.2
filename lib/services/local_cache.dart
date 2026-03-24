import 'package:hive_flutter/hive_flutter.dart';

/// Fast key-value cache backed by Hive — synchronous reads, async writes.
/// Screens load instantly from cache while network refreshes in background.
class LocalCache {
  static late Box _box;
  static bool _initialized = false;

  static Future<void> init() async {
    if (_initialized) return;
    await Hive.initFlutter();
    _box = await Hive.openBox('cruiseCache');
    _initialized = true;
  }

  /// Synchronous read — no await, instant.
  static T? get<T>(String key) {
    if (!_initialized) return null;
    return _box.get(key) as T?;
  }

  /// Async write.
  static Future<void> set(String key, dynamic value) async {
    if (!_initialized) return;
    await _box.put(key, value);
  }

  /// Delete a key.
  static Future<void> delete(String key) async {
    if (!_initialized) return;
    await _box.delete(key);
  }

  /// Cache with automatic expiry.
  static Future<void> setWithExpiry(
    String key,
    dynamic value,
    Duration expiry,
  ) async {
    if (!_initialized) return;
    await _box.put(key, {
      'v': value,
      'exp': DateTime.now().add(expiry).millisecondsSinceEpoch,
    });
  }

  /// Read with expiry check — returns null if expired.
  static T? getWithExpiry<T>(String key) {
    if (!_initialized) return null;
    final data = _box.get(key);
    if (data == null || data is! Map) return null;
    final exp = data['exp'] as int?;
    if (exp == null || DateTime.now().millisecondsSinceEpoch > exp) {
      _box.delete(key);
      return null;
    }
    return data['v'] as T?;
  }

  /// Check if a key exists and is not expired.
  static bool has(String key) => _initialized && _box.containsKey(key);
}
