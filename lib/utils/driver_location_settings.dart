import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:geolocator/geolocator.dart';

/// Location settings for a driver who is working.
///
/// Every driver GPS stream in the app used to be created with a bare
/// `LocationSettings`, and a bare LocationSettings is a foreground-only
/// stream on both platforms:
///
///  * **iOS** stops delivering the moment the app leaves the foreground
///    unless the location manager itself sets
///    `allowsBackgroundLocationUpdates`. `UIBackgroundModes: location` in
///    Info.plist is necessary but on its own does nothing — the runtime
///    opt-in is what turns it on, and geolocator only sends it when you
///    hand it an [AppleSettings].
///  * **Android** throttles a backgrounded app's location to a few fixes an
///    hour unless the stream runs behind a foreground service, which
///    geolocator only starts when you give it a
///    [ForegroundNotificationConfig].
///
/// The platform side was already fully configured for this — the iOS
/// background mode, and on Android `FOREGROUND_SERVICE_LOCATION`,
/// `ACCESS_BACKGROUND_LOCATION` and a `foregroundServiceType="location"`
/// service in the manifest. Only the Dart call was missing, so none of it
/// was ever reached.
///
/// What that cost: the driver taps "open in Google Maps" to navigate, or
/// just locks the phone, and their app stops publishing position. On the
/// passenger's screen the car freezes mid-street — and the chase camera,
/// which has nothing to do but follow that car, freezes with it. On the
/// server the driver goes quiet long enough for the ghost agent to log them
/// inactive and force them offline in the middle of a fare.
///
/// [pauseLocationUpdatesAutomatically] is off deliberately: iOS pauses
/// updates when it decides the device has stopped moving, and a car at a
/// long red light reads exactly like a device that has stopped moving.
LocationSettings driverLocationSettings({
  LocationAccuracy accuracy = LocationAccuracy.bestForNavigation,
  int distanceFilter = 5,
  required String notificationTitle,
  required String notificationText,
}) {
  if (kIsWeb) {
    return LocationSettings(accuracy: accuracy, distanceFilter: distanceFilter);
  }
  if (Platform.isIOS || Platform.isMacOS) {
    return AppleSettings(
      accuracy: accuracy,
      distanceFilter: distanceFilter,
      allowBackgroundLocationUpdates: true,
      pauseLocationUpdatesAutomatically: false,
      // The blue status pill while we track in the background. Not
      // decoration — it is what stops this reading as a location grab, and
      // iOS expects it for a continuously-tracking app.
      showBackgroundLocationIndicator: true,
      activityType: ActivityType.automotiveNavigation,
    );
  }
  if (Platform.isAndroid) {
    return AndroidSettings(
      accuracy: accuracy,
      distanceFilter: distanceFilter,
      foregroundNotificationConfig: ForegroundNotificationConfig(
        notificationTitle: notificationTitle,
        notificationText: notificationText,
        notificationChannelName: 'Cruise driver location',
        enableWakeLock: true,
        setOngoing: true,
      ),
    );
  }
  return LocationSettings(accuracy: accuracy, distanceFilter: distanceFilter);
}
