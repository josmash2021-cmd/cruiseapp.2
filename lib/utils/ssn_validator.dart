/// Structural validation for a US Social Security Number.
///
/// WHAT THIS DOES AND DOES NOT DO.
///
/// It answers one question: could the Social Security Administration ever
/// have issued this number? That catches every made-up number a person types
/// to get past a form — 000-00-0000, 123-45-6789, 666-12-3456, the one off
/// the sample card in a wallet — because the SSA has publicly committed to
/// never issuing those.
///
/// It does NOT and cannot tell you the number belongs to a real person, or
/// to the person typing it. That takes the SSA's Consent Based SSN
/// Verification or a background-check provider, both server-side. Treat a
/// pass here as "worth sending on", never as "verified".
///
/// The rules come from the SSA's own published guidance on numbers that are
/// never assigned:
///   • the area (first three digits) is never 000, never 666, never 900-999
///   • the group (middle two) is never 00
///   • the serial (last four) is never 0000
///   • 987-65-4320 through 987-65-4329 are reserved for use in advertising
///   • a handful of numbers were printed on sample cards and are permanently
///     retired
library;

/// Why a number cannot be an SSN. `null` from [ssnProblem] means it could be.
enum SsnProblem {
  /// Fewer (or more) than nine digits — they are probably still typing.
  incomplete,

  /// Area 000, 666, or 900-999; group 00; serial 0000.
  neverIssued,

  /// Printed on a sample card, used in an advert, or the placeholder every
  /// form in the world receives: 123-45-6789, 111-11-1111.
  knownFake,
}

/// Numbers the SSA has publicly retired, plus the placeholders people reach
/// for. Digits only, no separators.
const _kRetired = <String>{
  // Printed on a sample card in Woolworth wallets in 1938; tens of thousands
  // of people used it as their own. Retired.
  '078051120',
  // Used in an advert; the SSA voided it.
  '219099999',
  // The placeholder every form receives.
  '123456789',
};

/// Strips separators and returns the nine digits, or null if there are not
/// exactly nine.
String? _digits(String raw) {
  final d = raw.replaceAll(RegExp(r'\D'), '');
  return d.length == 9 ? d : null;
}

/// Returns why [raw] cannot be an SSN, or null if it structurally could be.
SsnProblem? ssnProblem(String raw) {
  final d = _digits(raw);
  if (d == null) return SsnProblem.incomplete;

  final area = d.substring(0, 3);
  final group = d.substring(3, 5);
  final serial = d.substring(5);

  // Never assigned by the SSA.
  if (area == '000' || area == '666' || area[0] == '9') {
    return SsnProblem.neverIssued;
  }
  if (group == '00') return SsnProblem.neverIssued;
  if (serial == '0000') return SsnProblem.neverIssued;

  if (_kRetired.contains(d)) return SsnProblem.knownFake;

  // The SSA also reserves 987-65-4320..4329 for advertising. There is no
  // check for it because there cannot be one that ever runs: area 987 starts
  // with a 9, so the rule above has already rejected it. Noted rather than
  // coded, so nobody adds a branch that can never be reached.

  // Nine of the same digit passes every structural rule above and is never a
  // real number.
  if (d.split('').toSet().length == 1) return SsnProblem.knownFake;

  return null;
}

/// Whether [raw] could be a real SSN. See the library note: a pass is not
/// proof the number belongs to anyone.
bool isPlausibleSsn(String raw) => ssnProblem(raw) == null;
