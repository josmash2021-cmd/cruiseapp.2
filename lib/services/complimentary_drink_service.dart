import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

/// Fetches the complimentary drink chosen by a VIP rider.
/// Data source: Supabase `reservations` table populated by the VIP drink menu web page.
/// Matches by phone OR email, returns the drink name (e.g. "Coca-Cola") or null if not yet chosen.
class ComplimentaryDrinkService {
  static const String _supabaseUrl = 'https://elvszwazwvpgqvnzxwnq.supabase.co';
  // Anon key is safe to expose — Supabase RLS policies restrict anon to select/update only
  static const String _anonKey =
      'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImVsdnN6d2F6d3ZwZ3F2bnp4d25xIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzUxOTEzMzMsImV4cCI6MjA5MDc2NzMzM30.EhrXsgSF7nK2jvebOgO4mvzJSqGXJ0Je6j2vi9ZvMX4';

  static Map<String, String> get _headers => {
        'apikey': _anonKey,
        'Authorization': 'Bearer $_anonKey',
      };

  /// Returns the chosen drink name, or null if the rider hasn't confirmed one yet.
  /// Pass phone and/or email — at least one must be non-empty.
  static Future<String?> fetchForRider({
    String? phone,
    String? email,
  }) async {
    final cleanPhone = (phone ?? '').trim();
    final cleanEmail = (email ?? '').trim().toLowerCase();
    if (cleanPhone.isEmpty && cleanEmail.isEmpty) return null;

    // Build OR filter — supabase PostgREST supports or=(phone.eq.X,email.eq.Y)
    final orClauses = <String>[];
    if (cleanPhone.isNotEmpty) {
      orClauses.add('phone.eq.${Uri.encodeComponent(cleanPhone)}');
    }
    if (cleanEmail.isNotEmpty) {
      orClauses.add('email.eq.${Uri.encodeComponent(cleanEmail)}');
    }
    final orFilter = 'or=(${orClauses.join(',')})';

    final url = Uri.parse(
      '$_supabaseUrl/rest/v1/reservations?select=drink_name,status,used_at&$orFilter&order=used_at.desc.nullslast&limit=1',
    );

    try {
      final res = await http
          .get(url, headers: _headers)
          .timeout(const Duration(seconds: 6));
      if (res.statusCode != 200) {
        debugPrint('[ComplimentaryDrink] HTTP ${res.statusCode}: ${res.body}');
        return null;
      }
      final list = jsonDecode(res.body) as List<dynamic>;
      if (list.isEmpty) return null;
      final row = list.first as Map<String, dynamic>;
      final drink = (row['drink_name'] as String?)?.trim();
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
}
