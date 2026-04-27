import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'api_service.dart';

/// Fetches the complimentary drink chosen by a VIP rider.
/// Data source: CruiseApp backend via /vip/trip/{id}/drink endpoint.
/// Returns the drink name (e.g. "Coca-Cola") or null if not yet chosen.
class ComplimentaryDrinkService {
  static String get _baseUrl => ApiService.publicBaseUrl;

  /// Returns the chosen drink name, or null if the rider hasn't confirmed one yet.
  /// Pass the trip ID to look up the drink selection.
  static Future<String?> fetchForTrip(int tripId) async {
    if (tripId <= 0) return null;

    final url = Uri.parse('$_baseUrl/vip/trip/$tripId/drink');

    try {
      final res = await http
          .get(url)
          .timeout(const Duration(seconds: 6));
      if (res.statusCode != 200) {
        debugPrint('[ComplimentaryDrink] HTTP ${res.statusCode}: ${res.body}');
        return null;
      }
      final data = jsonDecode(res.body) as Map<String, dynamic>;
      final drink = (data['drink_selected'] as String?)?.trim();
      if (drink == null || drink.isEmpty) return null;
      return drink;
    } on TimeoutException {
      debugPrint('[ComplimentaryDrink] timeout');
      return null;
    } catch (e) {
      debugPrint('[ComplimentaryDrink] error: $e');
      return null;
    }
  }

  /// Legacy method — now uses trip ID instead of phone/email.
  /// Kept for backward compatibility but delegates to fetchForTrip.
  @Deprecated('Use fetchForTrip(tripId) instead')
  static Future<String?> fetchForRider({
    String? phone,
    String? email,
  }) async {
    return null;
  }
}
