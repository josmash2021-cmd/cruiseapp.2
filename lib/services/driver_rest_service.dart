import 'package:flutter/foundation.dart';

import 'api_service.dart';
import 'prefs_cache.dart';

class DriverRestService {
  static final restUntil = ValueNotifier<DateTime?>(null);

  static Duration get remaining {
    final until = restUntil.value;
    if (until == null) return Duration.zero;
    final left = until.difference(DateTime.now());
    return left > Duration.zero ? left : Duration.zero;
  }

  static bool get isResting => remaining > Duration.zero;

  static String format(Duration duration) {
    final h = duration.inHours.toString().padLeft(2, '0');
    final m = (duration.inMinutes % 60).toString().padLeft(2, '0');
    final s = (duration.inSeconds % 60).toString().padLeft(2, '0');
    return '$h:$m:$s';
  }

  static Future<void> set(DateTime? when) async {
    final active = when != null && when.isAfter(DateTime.now()) ? when : null;
    if (restUntil.value != active) restUntil.value = active;
    final prefs = await PrefsCache.instance;
    await prefs.setInt(
        'driver_rest_until', active?.millisecondsSinceEpoch ?? 0);
  }

  static Future<void> restore() async {
    final prefs = await PrefsCache.instance;
    final ms = prefs.getInt('driver_rest_until') ?? 0;
    if (ms > 0) await set(DateTime.fromMillisecondsSinceEpoch(ms));
  }

  static Future<void> syncFromServer(Map<String, dynamic> result) async {
    if (!result.containsKey('rest_until')) return;
    final raw = result['rest_until']?.toString();
    await set(raw == null || raw.isEmpty ? null : DateTime.tryParse(raw));
  }

  static Future<void> refresh() async {
    try {
      await syncFromServer(await ApiService.canGoOnline());
    } catch (e) {
      debugPrint('[DriverRest] refresh failed: $e');
    }
  }
}
