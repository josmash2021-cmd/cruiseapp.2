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
