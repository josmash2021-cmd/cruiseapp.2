/// Returns the display name for a driver/rider.
///
/// * VIP rides → full name.
/// * All other ride types → first name only.
///
/// [fullName] — the complete first+last name string.
/// [rideType] — the ride/vehicle type label (e.g. 'VIP', 'Sedan', 'Comfort').
///              Pass `null` or empty for non-VIP default.
String displayName(String fullName, [String? rideType]) {
  if (fullName.isEmpty) return fullName;

  // VIP shows full name
  if (rideType != null && rideType.toUpperCase() == 'VIP') {
    return fullName;
  }

  // All other types → first name only
  final parts = fullName.trim().split(' ');
  return parts.isNotEmpty ? parts.first : fullName;
}
