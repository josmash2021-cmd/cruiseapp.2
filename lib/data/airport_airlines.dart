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

/// IATA code of every airline the app lists. Its real square logo is served
/// from the backend at /static/airlines/{code}.png (owner 2026-11-08: "los
/// íconos de las aerolíneas reales"). Regional brands fly under their
/// parent's mark (American Eagle → AA, Delta Connection → DL, Horizon → AS).
const Map<String, String> kAirlineIata = {
  'ANA': 'NH',
  'Aer Lingus': 'EI',
  'Aeromexico': 'AM',
  'Air Canada': 'AC',
  'Air China': 'CA',
  'Air France': 'AF',
  'Air India': 'AI',
  'Alaska Airlines': 'AS',
  'Allegiant Air': 'G4',
  'American Airlines': 'AA',
  'American Eagle': 'AA',
  'Avianca': 'AV',
  'Bahamasair': 'UP',
  'Breeze Airways': 'MX',
  'British Airways': 'BA',
  'Caribbean Airlines': 'BW',
  'Cathay Pacific': 'CX',
  'China Southern': 'CZ',
  'Condor': 'DE',
  'Copa Airlines': 'CM',
  'Delta Air Lines': 'DL',
  'Delta Connection': 'DL',
  'Delta regional': 'DL',
  'EVA Air': 'BR',
  'Emirates': 'EK',
  'Endeavor Air': '9E',
  'Ethiopian Airlines': 'ET',
  'Etihad Airways': 'EY',
  'Finnair': 'AY',
  'Frontier Airlines': 'F9',
  'Hawaiian Airlines': 'HA',
  'Horizon Air': 'AS',
  'Iberia': 'IB',
  'Icelandair': 'FI',
  'Japan Airlines': 'JL',
  'JetBlue': 'B6',
  'JetBlue Airways': 'B6',
  'KLM': 'KL',
  'Korean Air': 'KE',
  'LATAM Airlines': 'LA',
  'LOT Polish': 'LO',
  'Lufthansa': 'LH',
  'Norse Atlantic': 'N0',
  'Qantas': 'QF',
  'Qatar Airways': 'QR',
  'Royal Air Maroc': 'AT',
  'Royal Jordanian': 'RJ',
  'Silver Airways': '3M',
  'Singapore Airlines': 'SQ',
  'Southwest Airlines': 'WN',
  'Spirit Airlines': 'NK',
  'Sun Country': 'SY',
  'Swiss': 'LX',
  'TAP Air Portugal': 'TP',
  'Turkish Airlines': 'TK',
  'United Airlines': 'UA',
  'United Express': 'UA',
  'Virgin America': 'VX',
  'Virgin Atlantic': 'VS',
  'Viva Aerobus': 'VB',
  'Volaris': 'Y4',
  'WestJet': 'WS',
};

/// "United Airlines (intl)" → "UA"; null for a charter or a name we have no
/// logo for.
String? airlineIataFor(String name) {
  final base = name.replaceAll(RegExp(r'\s*\(.*\)\s*$'), '').trim();
  return kAirlineIata[base];
}
