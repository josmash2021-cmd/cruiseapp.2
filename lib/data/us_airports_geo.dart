/// Major US commercial airports with coordinates — the data behind the
/// gold airport pills on the driver's map (2026-10-22, owner spec: "solo
/// los grandes", visual only, both online and offline searching views).
///
/// Distinct from `airport_data.dart` (the rider door-picker: terminals and
/// airlines, no coordinates). Only the state's principal commercial
/// airports — no private strips, no regionals.
library;

class UsAirportGeo {
  final String code; // IATA
  final String name;
  final String state; // 'AL' | 'FL'
  final double lat;
  final double lng;

  const UsAirportGeo({
    required this.code,
    required this.name,
    required this.state,
    required this.lat,
    required this.lng,
  });
}

const List<UsAirportGeo> kUsAirportsGeo = [
  // ── Alabama ──
  UsAirportGeo(
      code: 'BHM',
      name: 'Birmingham-Shuttlesworth Intl',
      state: 'AL',
      lat: 33.5629,
      lng: -86.7536),
  UsAirportGeo(
      code: 'HSV',
      name: 'Huntsville Intl',
      state: 'AL',
      lat: 34.6372,
      lng: -86.7751),
  UsAirportGeo(
      code: 'MOB',
      name: 'Mobile Regional',
      state: 'AL',
      lat: 30.6912,
      lng: -88.2428),
  UsAirportGeo(
      code: 'MGM',
      name: 'Montgomery Regional',
      state: 'AL',
      lat: 32.3006,
      lng: -86.3940),
  // ── Florida ──
  UsAirportGeo(
      code: 'MIA',
      name: 'Miami Intl',
      state: 'FL',
      lat: 25.7959,
      lng: -80.2870),
  UsAirportGeo(
      code: 'FLL',
      name: 'Fort Lauderdale-Hollywood Intl',
      state: 'FL',
      lat: 26.0742,
      lng: -80.1506),
  UsAirportGeo(
      code: 'MCO',
      name: 'Orlando Intl',
      state: 'FL',
      lat: 28.4312,
      lng: -81.3081),
  UsAirportGeo(
      code: 'TPA',
      name: 'Tampa Intl',
      state: 'FL',
      lat: 27.9755,
      lng: -82.5332),
  UsAirportGeo(
      code: 'JAX',
      name: 'Jacksonville Intl',
      state: 'FL',
      lat: 30.4941,
      lng: -81.6879),
  UsAirportGeo(
      code: 'RSW',
      name: 'Southwest Florida Intl',
      state: 'FL',
      lat: 26.5362,
      lng: -81.7552),
  UsAirportGeo(
      code: 'PBI',
      name: 'Palm Beach Intl',
      state: 'FL',
      lat: 26.6832,
      lng: -80.0956),
  UsAirportGeo(
      code: 'PNS',
      name: 'Pensacola Intl',
      state: 'FL',
      lat: 30.4734,
      lng: -87.1866),
];

/// Airports of one working state ('AL' / 'FL'); anything else → none.
List<UsAirportGeo> airportsForState(String? stateCode) {
  final st = (stateCode ?? '').trim().toUpperCase();
  if (st.isEmpty) return const [];
  return kUsAirportsGeo.where((a) => a.state == st).toList();
}
