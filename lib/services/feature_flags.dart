import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';

import 'api_service.dart';

/// Tiny remote kill switches (2026-10-11, born for the zone layers): the
/// driver map's zone drawing can be switched off from the server while a
/// live issue is diagnosed — no build, no patch. Missing key = OFF (safe
/// side: a flag that never shipped reads as off).
class FeatureFlags {
  FeatureFlags._();

  static bool zonesMapEnabled = false;
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
