import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';

import 'api_service.dart';

/// Feature and kill switches for the zone layers and paused payment rails.
/// Missing remote keys = OFF (safe side).
class FeatureFlags {
  FeatureFlags._();

  static bool zonesMapEnabled = false;
  static bool paypalEnabled = false;
  static bool tapToPayEnabled = false;
  static bool _loaded = false;

  static Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final res = await http
          .get(
            Uri.parse('${ApiService.currentBaseUrl}/feature-flags'),
            headers: ApiService.jsonHeaders(),
          )
          .timeout(const Duration(seconds: 4));
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body);
        zonesMapEnabled = data['zones_map_enabled'] == true;
      }
    } catch (e) {
      debugPrint('[Flags] load failed (defaults stay): $e');
    }
  }
}
