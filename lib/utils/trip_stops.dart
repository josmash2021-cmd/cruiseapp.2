import 'dart:convert';

import '../models/lat_lng.dart';

/// The booking-time/mid-trip stop parsed off any trip-or-offer payload's
/// `stops` field — a JSON string from the server, or an already-decoded
/// list. Null when there is none. One parser for every surface (offer
/// preview map, offer card, chained card, trip screen): the shape is
/// written by booking_stops_json (backend) and /trips/{id}/stops.
({LatLng point, String label})? parseTripStop(Map<String, dynamic> payload) {
  try {
    final raw = payload['stops'];
    final list = raw is String ? jsonDecode(raw) : (raw is List ? raw : null);
    if (list is! List || list.isEmpty) return null;
    final s = list.first;
    if (s is! Map) return null;
    final lat = (s['lat'] as num?)?.toDouble();
    final lng = (s['lng'] as num?)?.toDouble();
    if (lat == null || lng == null) return null;
    if (!lat.isFinite || !lng.isFinite) return null;
    if (lat.abs() > 90 || lng.abs() > 180) return null;
    return (point: LatLng(lat, lng), label: (s['label'] ?? '').toString());
  } catch (_) {
    return null;
  }
}
