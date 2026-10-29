import '../../l10n/app_localizations.dart';
import '../../services/api_service.dart';

/// What to tell the driver when `POST /drivers/vehicles/{id}/use` fails.
///
/// The backend answers 409 `vehicle_switch_blocked_on_trip` while a trip is
/// in progress (the rider's screen re-reads the active car on every poll)
/// and 400 when the car or its documents are not approved yet. Anything
/// else is the network. Shared by the vehicle list, the detail page and the
/// documents page so the three never disagree (owner spec 2026-10-29).
String vehicleSwitchErrorCopy(Object error, S s) {
  if (error is ApiException) {
    if (error.statusCode == 409) return s.vehicleSwitchBlockedOnTrip;
    if (error.statusCode == 400) return s.vehicleNotReadyToUse;
  }
  return s.connectionError;
}
