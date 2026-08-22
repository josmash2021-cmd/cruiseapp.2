import '../models/airport_models.dart';
import 'airport_data.dart';

/// Airline lists for the "Select your airline" page (2026-08-22).
///
/// Two tiers: the POPULAR row at the top (curated per airport — what the
/// photo mock shows) and the full list behind "See more airlines". The full
/// list comes from [kCommonAirports] when we have terminal data for the
/// airport; an unknown code gets the generic US majors.

/// Curated front row per airport code. Keep to the four-five names a rider
/// actually looks for first.
const Map<String, List<String>> kPopularAirlinesByAirport = {
  'BHM': [
    'American Airlines',
    'Delta Air Lines',
    'United Airlines',
    'Southwest Airlines',
  ],
};

/// The fallback for any airport without curated or terminal data.
const List<String> kGenericUsAirlines = [
  'American Airlines',
  'Delta Air Lines',
  'United Airlines',
  'Southwest Airlines',
  'JetBlue Airways',
  'Alaska Airlines',
  'Spirit Airlines',
  'Frontier Airlines',
];

AirportInfo? _airportByCode(String code) {
  final c = code.trim().toUpperCase();
  for (final a in kCommonAirports) {
    if (a.code.toUpperCase() == c) return a;
  }
  return null;
}

/// Front row for [code]: the curated list when we have one, else the
/// airport's own airlines, else the generic majors.
List<String> popularAirlinesFor(String code) {
  final curated = kPopularAirlinesByAirport[code.trim().toUpperCase()];
  if (curated != null) return curated;
  final known = _airportByCode(code);
  if (known != null && known.allAirlines.isNotEmpty) {
    return known.allAirlines;
  }
  return kGenericUsAirlines;
}

/// The full searchable list behind "See more airlines".
List<String> allAirlinesFor(String code) {
  final known = _airportByCode(code);
  if (known != null && known.allAirlines.isNotEmpty) {
    return known.allAirlines;
  }
  return kGenericUsAirlines;
}

/// Detect a known airport in a free-form address/label. Matches the IATA
/// code as a whole word (the sheet's own convention) or the airport name.
/// Returns null for non-airport destinations — the airline page stays out
/// of ordinary bookings.
AirportInfo? detectAirportForAddress(String text) {
  final t = text.toLowerCase();
  for (final a in kCommonAirports) {
    if (RegExp('\\b${a.code.toLowerCase()}\\b').hasMatch(t)) return a;
    if (t.contains(a.name.toLowerCase())) return a;
  }
  // No code hit: a generic "…airport" address with no code we know is left
  // to the terminal sheet's own picker, not to a guessed airline list.
  return null;
}
