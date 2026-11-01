/// Returns the display name for a driver/rider.
///
/// Always returns the full name (first + last) so drivers can identify
/// the rider clearly when picking up.
///
/// [fullName] — the complete first+last name string.
/// [rideType] — kept for signature compatibility; no longer alters the output.
String displayName(String fullName, [String? rideType]) {
  return fullName.trim();
}

/// Generic names the backend sends when it has no real one. Abbreviating
/// them would print "Guest R.", so they pass through untouched.
const Set<String> _kPlaceholderNames = {'guest rider', 'web booking'};

/// Trailing words that are not a surname: "John Smith Jr." is "John S.".
const Set<String> _kNameSuffixes = {'jr', 'sr', 'ii', 'iii', 'iv'};

/// First name + last-name initial: "Lisbeth Tosta" → "Lisbeth T.".
///
/// For the rider on a ride OFFER (owner spec 2026-11-01): until the driver
/// accepts, the card does not show the rider's surname. Once the ride is
/// theirs the pickup screens keep [displayName] — the full name, so the
/// driver can confirm who is getting in (owner decision 2026-04-19).
///
/// The backend sends `first_name + " " + last_name` as one string, so the
/// initial is the LAST word's: it covers a compound first name ("Maria Jose
/// Tosta" → "Maria T.") and a middle name. A single word is returned as is,
/// and an already-short name ("Lisbeth T.") comes back unchanged.
String shortName(String fullName) {
  final parts = fullName
      .trim()
      .split(RegExp(r'\s+'))
      .where((p) => p.isNotEmpty)
      .toList();
  if (parts.isEmpty) return '';
  if (_kPlaceholderNames.contains(parts.join(' ').toLowerCase())) {
    return parts.join(' ');
  }
  while (parts.length > 2 &&
      _kNameSuffixes.contains(parts.last.replaceAll('.', '').toLowerCase())) {
    parts.removeLast();
  }
  if (parts.length < 2) return parts.first;
  final initial = String.fromCharCodes([parts.last.runes.first]).toUpperCase();
  return '${parts.first} $initial.';
}
