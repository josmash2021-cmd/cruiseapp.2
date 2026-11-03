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

/// Words that open a compound surname: "Juan De La Cruz" is "Juan D.".
const Set<String> _kSurnameParticles = {
  'de', 'del', 'la', 'las', 'los', 'y', 'da', 'das', 'do', 'dos', 'van', 'von', 'di',
};

/// First name + last-name initial: "Lisbeth Tosta" → "Lisbeth T.".
///
/// For the rider on a ride OFFER (owner spec 2026-11-01): until the driver
/// accepts, the card does not show the rider's surname. Once the ride is
/// theirs the pickup screens keep [displayName] — the full name, so the
/// driver can confirm who is getting in (owner decision 2026-04-19).
///
/// The backend sends `first_name + " " + last_name` as one string, so the
/// surname has to be guessed from the words:
/// - two or three words: the LAST word's initial — a compound first name
///   ("Maria Jose Tosta" → "Maria T.") or a middle name;
/// - four or more: the SECOND-TO-LAST, the first of two surnames, the
///   Hispanic "Nombre Nombre Paterno Materno" ("Eduardo Jonas Ramirez
///   Bocanegra" → "Eduardo R.", owner 2026-11-03, the rider's driver card);
/// - a surname opened by a particle takes the particle's ("Juan De La
///   Cruz" → "Juan D.").
/// A single word is returned as is, and an already-short name ("Lisbeth
/// T.") comes back unchanged.
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
  var i = parts.length >= 4 ? parts.length - 2 : parts.length - 1;
  while (i > 1 && _kSurnameParticles.contains(parts[i - 1].toLowerCase())) {
    i--;
  }
  final initial = String.fromCharCodes([parts[i].runes.first]).toUpperCase();
  return '${parts.first} $initial.';
}
