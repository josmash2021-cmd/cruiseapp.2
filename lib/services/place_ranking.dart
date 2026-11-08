import 'places_service.dart' show PlaceSuggestion;

/// What a rider sees when they search a place: one row per real place, the
/// ones in their own state first, the closest first among equals — and
/// another state's look-alike only when they asked for it (owner 2026-11-08:
/// "3659 Lorna Rd" listed the same house in Birmingham, Montgomery TX,
/// Jacksonville FL and Boston).
///
/// Pure functions over the merged provider results, so the rules can be
/// tested with real answers from Google and Mapbox.

const Map<String, String> _kStateNames = {
  'alabama': 'AL',
  'alaska': 'AK',
  'arizona': 'AZ',
  'arkansas': 'AR',
  'california': 'CA',
  'colorado': 'CO',
  'connecticut': 'CT',
  'delaware': 'DE',
  'district of columbia': 'DC',
  'florida': 'FL',
  'georgia': 'GA',
  'hawaii': 'HI',
  'idaho': 'ID',
  'illinois': 'IL',
  'indiana': 'IN',
  'iowa': 'IA',
  'kansas': 'KS',
  'kentucky': 'KY',
  'louisiana': 'LA',
  'maine': 'ME',
  'maryland': 'MD',
  'massachusetts': 'MA',
  'michigan': 'MI',
  'minnesota': 'MN',
  'mississippi': 'MS',
  'missouri': 'MO',
  'montana': 'MT',
  'nebraska': 'NE',
  'nevada': 'NV',
  'new hampshire': 'NH',
  'new jersey': 'NJ',
  'new mexico': 'NM',
  'new york': 'NY',
  'north carolina': 'NC',
  'north dakota': 'ND',
  'ohio': 'OH',
  'oklahoma': 'OK',
  'oregon': 'OR',
  'pennsylvania': 'PA',
  'rhode island': 'RI',
  'south carolina': 'SC',
  'south dakota': 'SD',
  'tennessee': 'TN',
  'texas': 'TX',
  'utah': 'UT',
  'vermont': 'VT',
  'virginia': 'VA',
  'washington': 'WA',
  'west virginia': 'WV',
  'wisconsin': 'WI',
  'wyoming': 'WY',
  'puerto rico': 'PR',
};

final Set<String> _kStateCodes = _kStateNames.values.toSet();

final RegExp _zipTail = RegExp(r'\s*\d{5}(-\d{4})?$');
final RegExp _countryPart = RegExp(
    r'^(usa|us|u\.s\.a\.|united states( of america)?|estados unidos)$',
    caseSensitive: false);

/// The two-letter state a place line ends in ("Homewood, AL, USA",
/// "Hoover, Alabama 35216, United States"), or null when it names none.
String? stateOfPlaceText(String text) {
  final parts =
      text.split(',').map((p) => p.trim()).where((p) => p.isNotEmpty).toList();
  while (parts.isNotEmpty && _countryPart.hasMatch(parts.last)) {
    parts.removeLast();
  }
  // The state is the last or second-to-last part; a street or a business
  // name further up ("Georgia Ave", "Alabama Grill") is not it.
  for (var i = parts.length - 1; i >= 0 && i >= parts.length - 2; i--) {
    final p = parts[i].replaceFirst(_zipTail, '').trim();
    if (p.length == 2 &&
        _kStateCodes.contains(p.toUpperCase()) &&
        p == p.toUpperCase()) {
      return p;
    }
    final code = _kStateNames[p.toLowerCase()];
    if (code != null) return code;
  }
  return null;
}

/// A place line with its country dropped — "Homewood, AL, USA" reads
/// "Homewood, AL" (Lyft and Google both drop it for a US rider).
String withoutCountry(String text) {
  final parts = text.split(',').map((p) => p.trim()).toList();
  while (parts.length > 1 && _countryPart.hasMatch(parts.last)) {
    parts.removeLast();
  }
  return parts.join(', ');
}

const Map<String, String> _kStreetWords = {
  'road': 'rd',
  'drive': 'dr',
  'street': 'st',
  'avenue': 'ave',
  'boulevard': 'blvd',
  'lane': 'ln',
  'court': 'ct',
  'parkway': 'pkwy',
  'highway': 'hwy',
  'place': 'pl',
  'circle': 'cir',
  'terrace': 'ter',
  'trail': 'trl',
  'square': 'sq',
  'north': 'n',
  'south': 's',
  'east': 'e',
  'west': 'w',
  'northeast': 'ne',
  'northwest': 'nw',
  'southeast': 'se',
  'southwest': 'sw',
};

/// Lowercase, no accents or punctuation, street words in their short form —
/// so Google's "3659 Lorna Rd" and Mapbox's "3659 Lorna Road" read the same.
String canonPlaceText(String value) {
  final plain = value
      .toLowerCase()
      .replaceAll('á', 'a')
      .replaceAll('é', 'e')
      .replaceAll('í', 'i')
      .replaceAll('ó', 'o')
      .replaceAll('ú', 'u')
      .replaceAll('ü', 'u')
      .replaceAll('ñ', 'n')
      .replaceAll(RegExp(r'[^a-z0-9\s]'), ' ')
      .split(RegExp(r'\s+'))
      .where((w) => w.isNotEmpty)
      .map((w) => _kStreetWords[w] ?? w);
  return plain.join(' ');
}

String _title(PlaceSuggestion s) {
  final main = s.mainText;
  if (main != null && main.trim().isNotEmpty) return main;
  final comma = s.description.indexOf(',');
  return comma > 0 ? s.description.substring(0, comma) : s.description;
}

String _rest(PlaceSuggestion s) {
  final secondary = s.secondaryText;
  if (secondary != null && secondary.trim().isNotEmpty) return secondary;
  final comma = s.description.indexOf(',');
  return comma > 0 ? s.description.substring(comma + 1) : '';
}

bool _fromMapbox(PlaceSuggestion s) =>
    s.placeId.startsWith('mapbox') || s.placeId.startsWith('searchbox');

/// Within this, Google's and Mapbox's rows for one name are one place. Only
/// the distance from the rider is known for Google's, so two different
/// stores can sit at the same distance in different directions — the
/// Walmart Supercenters in Homewood and Hoover are 0.19 mi apart that way;
/// the same house measured by both is 0.02 mi.
const double _kSamePlaceMiles = 0.15;

/// A city line both providers write the same way: no country, no zip, the
/// state as its two letters — Mapbox's "Hoover, Alabama 35244" and Google's
/// "Hoover, AL" are one city.
String _cityKey(String rest) {
  final parts = <String>[];
  for (final raw in withoutCountry(rest).split(',')) {
    final p = raw.replaceFirst(_zipTail, '').trim();
    if (p.isEmpty) continue;
    parts.add(_kStateNames[p.toLowerCase()] ?? p);
  }
  return canonPlaceText(parts.join(' '));
}

bool _isRoad(PlaceSuggestion s) => s.types.contains('route');

/// Two providers naming the same place are one row: same name, same state,
/// and one of
///  • the same city line (zip and "Alabama"/"AL" aside),
///  • Google vs Mapbox at the same distance from the rider,
///  • Google vs Mapbox roads, one with no distance — Google sends a bare
///    road without one ("Galleria Blvd, Birmingham, AL" beside Mapbox's
///    "Galleria Boulevard, Hoover, Alabama 35244", 2.3 mi).
/// One provider's own rows are never merged by distance — it already lists
/// each place once. The first row stays (callers merge Google first, so a
/// business keeps its Google name) unless only the later one knows how far
/// it is.
List<PlaceSuggestion> dedupePlaces(List<PlaceSuggestion> input) {
  final out = <PlaceSuggestion>[];
  final seenExact = <String>{};
  final kept = <({
    String title,
    String? state,
    String city,
    double? mi,
    bool mapbox,
    bool road,
  })>[];
  for (final s in input) {
    final exact = canonPlaceText(withoutCountry(s.description));
    if (exact.isEmpty || seenExact.contains(exact)) continue;
    seenExact.add(exact);
    final row = (
      title: canonPlaceText(_title(s)),
      state: stateOfPlaceText(s.description),
      city: _cityKey(_rest(s)),
      mi: s.distanceMiles,
      mapbox: _fromMapbox(s),
      road: _isRoad(s),
    );
    final at = kept.indexWhere((k) =>
        k.title == row.title &&
        k.state == row.state &&
        ((k.city.isNotEmpty && k.city == row.city) ||
            (k.mapbox != row.mapbox &&
                ((k.mi != null &&
                        row.mi != null &&
                        (k.mi! - row.mi!).abs() < _kSamePlaceMiles) ||
                    (k.road && row.road && (k.mi == null || row.mi == null))))));
    if (at < 0) {
      kept.add(row);
      out.add(s);
    } else if (kept[at].mi == null && row.mi != null) {
      kept[at] = row;
      out[at] = s;
    }
  }
  return out;
}

/// Beyond this a place in another state is a look-alike, not a neighbour
/// across the line (a rider in Phenix City, AL rides to Columbus, GA).
const double kOtherStateNearbyMiles = 60;

/// Orders [list] for the rider and drops another state's look-alikes.
///
/// Rank: how well the text matches what they typed (same house number
/// first), then their own state, then the closest. A place in another
/// state more than [kOtherStateNearbyMiles] away (or at an unknown
/// distance) stays only when it matches better than anything in their
/// state — typing "3659 Lorna Rd Boston" or "atl airport" still finds it.
List<PlaceSuggestion> rankPlacesForRider(
  String input,
  List<PlaceSuggestion> list, {
  String? riderState,
}) {
  final query = canonPlaceText(input);
  if (list.isEmpty) return list;
  final tokens = query.split(' ').where((t) => t.isNotEmpty).toList();
  final number = RegExp(r'^\d+').firstMatch(query)?.group(0);

  double score(PlaceSuggestion s) {
    final text = canonPlaceText('${s.mainText ?? ''} ${s.description}');
    if (text.isEmpty) return 0;
    var pts = 0.0;
    if (number != null && RegExp('(^| )$number ').hasMatch('$text ')) {
      pts += 100; // same house number → almost certainly the address
    }
    for (final t in tokens) {
      if (RegExp(r'^\d+$').hasMatch(t)) continue; // number already scored
      if (text.contains(t)) pts += 10;
    }
    return pts;
  }

  final scores = [for (final s in list) score(s)];
  final states = [for (final s in list) stateOfPlaceText(s.description)];
  bool home(int i) => riderState != null && states[i] == riderState;
  bool road(int i) => list[i].types.contains('route');

  var keep = List<int>.generate(list.length, (i) => i);
  // Mapbox searches fuzzily and fills up with nearby names that share none
  // of the words ("galleria" → "Crowne Reserve"). When something does
  // match, those go. Google's stay: its 0-word rows are typo corrections
  // ("walmrt" → Walmart).
  if (scores.any((p) => p > 0)) {
    keep = keep
        .where((i) => scores[i] > 0 || !_fromMapbox(list[i]))
        .toList();
  }
  if (riderState != null) {
    final inState = keep.where(home).toList();
    if (inState.isNotEmpty) {
      final best =
          inState.map((i) => scores[i]).reduce((a, b) => a > b ? a : b);
      keep = keep.where((i) {
        if (home(i) || scores[i] > best) return true;
        final mi = list[i].distanceMiles;
        return mi != null && mi <= kOtherStateNearbyMiles;
      }).toList();
    }
  }

  keep.sort((a, b) {
    final byScore = scores[b].compareTo(scores[a]);
    if (byScore != 0) return byScore;
    final byHome = (home(b) ? 1 : 0) - (home(a) ? 1 : 0);
    if (byHome != 0) return byHome;
    // A named place over a bare road that matches as well: "airport"
    // is the airport before Airport Rd, even when the road is closer.
    final byRoad = (road(a) ? 1 : 0) - (road(b) ? 1 : 0);
    if (byRoad != 0) return byRoad;
    final da = list[a].distanceMiles;
    final db = list[b].distanceMiles;
    if (da != null && db != null && (da - db).abs() > 0.05) {
      return da.compareTo(db);
    }
    if (da != null && db == null) return -1;
    if (da == null && db != null) return 1;
    return a.compareTo(b);
  });
  return [for (final i in keep) list[i]];
}

/// The number in "2.9 mi" / "14 mi" / "0.1 mi" (S.placeDistanceMi adds the
/// unit) — one decimal under ten miles.
String placeDistanceText(double miles) {
  if (miles < 0.1) return '0.1';
  if (miles < 10) return miles.toStringAsFixed(1);
  return miles.round().toString();
}
