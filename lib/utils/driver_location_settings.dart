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
///
/// [intervalDuration] matters only on Android, and there it matters a lot:
/// geolocator_android's default is 5000 ms, and the native client applies
/// it as BOTH `setIntervalMillis` and `setMinUpdateIntervalMillis` — the
/// latter is a hard floor, so no fix ever arrives faster than once per 5 s
/// no matter how small [distanceFilter] is. The car then glides for the
/// 3.5 s SmoothMotion dares to extrapolate, stalls, and snaps to the next
/// fix: the "jumps like it loses signal" the driver and the rider both
/// see. 1 s is the cadence Google Maps navigation runs at.
LocationSettings driverLocationSettings({
  LocationAccuracy accuracy = LocationAccuracy.bestForNavigation,
  int distanceFilter = 5,
  // 500 ms: real-time, not near-real-time. The socket cadence below is
  // 250–400 ms, so the fix stream must not be the slowest link.
  Duration intervalDuration = const Duration(milliseconds: 500),
  required String notificationTitle,
  required String notificationText,
  // False for a driver who is OFFLINE (driver spec 2026-08-22): the blue
  // iOS status pill and the Android foreground-service notification are
  // the "this app is tracking you in the background" signals, and they
  // may only exist while the driver is actually working. An offline
  // stream keeps feeding the in-app map dot but stops the moment the
  // app leaves the foreground.
  bool background = true,
}) {
  if (kIsWeb) {
    return LocationSettings(accuracy: accuracy, distanceFilter: distanceFilter);
  }
  if (Platform.isIOS || Platform.isMacOS) {
    return AppleSettings(
      accuracy: accuracy,
      distanceFilter: distanceFilter,
      allowBackgroundLocationUpdates: background,
      pauseLocationUpdatesAutomatically: false,
      // The blue status pill while we track in the background. Not
      // decoration — it is what stops this reading as a location grab, and
      // iOS expects it for a continuously-tracking app. Offline drivers get
      // neither the pill nor the tracking.
      showBackgroundLocationIndicator: background,
      activityType: ActivityType.automotiveNavigation,
    );
  }
  if (Platform.isAndroid) {
    return AndroidSettings(
      accuracy: accuracy,
      distanceFilter: distanceFilter,
      // See the doc comment above: without this the native default floors
      // delivery at one fix per 5 s and the marker steps instead of glides.
      intervalDuration: intervalDuration,
      foregroundNotificationConfig: background
          ? ForegroundNotificationConfig(
              notificationTitle: notificationTitle,
              notificationText: notificationText,
              notificationChannelName: 'Cruise driver location',
              enableWakeLock: true,
              setOngoing: true,
            )
          : null,
    );
  }
  return LocationSettings(accuracy: accuracy, distanceFilter: distanceFilter);
}

/// Location settings for the rider's own dot (home mini map, pickup seeding).
///
/// Same Android cadence trap as the driver stream above, minus the
/// foreground-service machinery — the rider is tracked while the app is
/// open, not on shift. A bare `LocationSettings` on Android floors delivery
/// at one fix per 5 s (geolocator_android's default interval), which is why
/// the home mini-map dot sat still for seconds and then jumped metres at
/// once: SmoothMotion froze its extrapolation long before the next fix.
LocationSettings riderLocationSettings({
  LocationAccuracy accuracy = LocationAccuracy.bestForNavigation,
  int distanceFilter = 0,
  Duration intervalDuration = const Duration(milliseconds: 500),
}) {
  if (kIsWeb) {
    return LocationSettings(accuracy: accuracy, distanceFilter: distanceFilter);
  }
  if (Platform.isIOS || Platform.isMacOS) {
    return AppleSettings(
      accuracy: accuracy,
      distanceFilter: distanceFilter,
      pauseLocationUpdatesAutomatically: false,
      activityType: ActivityType.otherNavigation,
    );
  }
  if (Platform.isAndroid) {
    return AndroidSettings(
      accuracy: accuracy,
      distanceFilter: distanceFilter,
      // See driverLocationSettings: without this the marker steps instead
      // of glides — one fix per 5 s no matter how small distanceFilter is.
      intervalDuration: intervalDuration,
    );
  }
  return LocationSettings(accuracy: accuracy, distanceFilter: distanceFilter);
}
