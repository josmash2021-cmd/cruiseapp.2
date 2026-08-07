import 'dart:typed_data';
import 'dart:ui' show PlatformDispatcher;
import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:mapbox_maps_flutter/mapbox_maps_flutter.dart';
import 'config/mapbox_config.dart';
import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart' show kDebugMode, kIsWeb, kReleaseMode;
import 'dart:async';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_crashlytics/firebase_crashlytics.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:cloud_firestore/cloud_firestore.dart' as firestore;
import 'package:flutter_stripe/flutter_stripe.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'config/smooth_transitions.dart';
import 'config/page_transitions.dart';
import 'config/api_keys.dart';
import 'config/app_theme.dart';
import 'config/env.dart';
import 'config/theme_notifier.dart';
import 'config/feature_flags.dart';
import 'config/route_observers.dart';
import 'state/accessibility_notifier.dart';
import 'screens/splash_screen.dart';
import 'screens/driver/driver_online_screen.dart';
import 'screens/driver/driver_home_screen.dart';
import 'screens/driver/driver_pending_review_screen.dart';
import 'services/api_service.dart';
import 'services/map_controller_cache.dart';
import 'services/notification_service.dart';
import 'services/security_service.dart';
import 'services/user_session.dart';
import 'services/local_data_service.dart';
import 'services/local_cache.dart';
import 'services/cache_service.dart';
import 'services/map_cache_service.dart';
import 'services/network_service.dart';
import 'services/keep_alive_service.dart';
import 'services/background_service.dart';
import 'services/analytics_service.dart';
import 'services/firebase_auth_recovery.dart';
import 'services/prefs_cache.dart';
import 'services/socket_service.dart';
import 'screens/chat_screen.dart';
import 'screens/ride_request_screen.dart';
import 'screens/home_screen.dart';
import 'screens/rider_tracking_screen.dart';
import 'models/lat_lng.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'firebase_options.dart';
import 'l10n/app_localizations.dart';
import 'utils/responsive.dart';

/// Global theme notifier so any screen can toggle night mode.
final themeNotifier = ThemeNotifier();

/// Global accessibility notifier for app-wide a11y settings.
final accessibilityNotifier = AccessibilityNotifier();

/// M2: Global navigator key for imperative navigation (auto-logout on 401).
final _navigatorKey = GlobalKey<NavigatorState>();

/// Background FCM handler — runs in a separate Dart isolate when the app is
/// killed or backgrounded. Shows a local offer notification with the distinct
/// cruise_offer.wav sound so the driver is alerted even when not in the app.
/// Fallback titles for push notifications when backend sends no title.
String _riderNotifTitle(String type) {
  final isEs = PlatformDispatcher.instance.locale.languageCode == 'es';
  return switch (type) {
    // ── Rider notifications ──
    'driver_assigned'    => isEs ? 'Conductor Asignado' : 'Driver Assigned',
    'driver_arriving'    => isEs ? 'Tu Conductor Está Cerca' : 'Driver Is Almost There',
    'driver_arrived'     => isEs ? 'Tu Conductor Ha Llegado' : 'Driver Has Arrived',
    'driver_found'       => isEs ? 'Conductor Encontrado' : 'Driver Found',
    'arrived_dropoff'    => isEs ? 'Has Llegado' : 'You Have Arrived',
    'fast_ride'          => isEs ? 'Conductores Disponibles Cerca' : 'Drivers Available Nearby',
    'driver_cancelled' || 'ride_reassigned' => isEs ? 'Actualización de Viaje' : 'Ride Update',
    'scheduled_claimed'  => isEs ? 'Conductor Aceptó Tu Viaje' : 'Driver Accepted Your Ride',
    'scheduled_driver_cancelled' => isEs ? 'Conductor Canceló Tu Viaje' : 'Driver Cancelled Your Ride',
    'arrived'            => isEs ? 'Tu Conductor Ha Llegado' : 'Driver Has Arrived',
    'in_trip'            => isEs ? 'Viaje Iniciado' : 'Trip Started',
    'completed'          => isEs ? 'Viaje Completado' : 'Trip Completed',
    'scheduled_reminder' => isEs ? 'Recordatorio de Viaje Próximo' : 'Upcoming Ride Reminder',
    // ── Driver notifications ──
    'trip_offer' || 'new_offer' => isEs ? 'Nueva Oferta de Viaje' : 'New Ride Offer',
    'rider_cancelled'    => isEs ? 'Viaje Cancelado' : 'Ride Cancelled',
    'trip_canceled' || 'trip_cancelled' => isEs ? 'Viaje Cancelado por Dispatch' : 'Trip Cancelled by Dispatch',
    'scheduled_cancelled' => isEs ? 'Viaje Programado Cancelado' : 'Scheduled Ride Cancelled',
    'tip_received'       => isEs ? '¡Recibiste una Propina!' : 'You Got a Tip!',
    'level_up'           => isEs ? '¡Subiste de Nivel!' : 'Level Up!',
    'level_down'         => isEs ? 'Actualización de Nivel' : 'Level Update',
    'instant_cashout'    => isEs ? 'Retiro Instantáneo' : 'Instant Cashout',
    _ => 'Cruise',
  };
}

/// Fallback bodies for push notifications when backend sends no body.
String _riderNotifBody(String type) {
  final isEs = PlatformDispatcher.instance.locale.languageCode == 'es';
  return switch (type) {
    // ── Rider notifications ──
    'driver_assigned'    => isEs ? 'Se ha asignado un conductor a tu viaje.' : 'A driver has been assigned to your ride.',
    'driver_arriving'    => isEs ? 'Tu conductor está casi en el punto de recogida.' : 'Your driver is almost at the pickup location.',
    'driver_arrived'     => isEs ? 'Tu conductor está en el punto de recogida.' : 'Your driver is at the pickup location.',
    'driver_found'       => isEs ? '¡Encontramos un conductor para tu viaje!' : 'We found a driver for your ride!',
    'arrived_dropoff'    => isEs ? 'Has llegado a tu destino. ¡Gracias por viajar con Cruise!' : 'You have arrived at your destination. Thanks for riding with Cruise!',
    'fast_ride'          => isEs ? 'Hay conductores cerca — ¡pide un viaje ahora!' : 'There are drivers near you — request a ride now!',
    'driver_cancelled'   => isEs ? 'Tu conductor canceló. Estamos asignando un nuevo conductor.' : 'Your driver cancelled. We are assigning a new driver.',
    'ride_reassigned'    => isEs ? 'Se está asignando un nuevo conductor a tu viaje.' : 'A new driver is being assigned to your ride.',
    'scheduled_claimed'  => isEs ? 'Un conductor ha aceptado tu viaje programado.' : 'A driver has accepted your scheduled ride.',
    'scheduled_driver_cancelled' => isEs ? 'Tu conductor canceló el viaje reservado. Estamos buscando otro.' : 'Your driver cancelled the scheduled ride. We are looking for another.',
    'arrived'            => isEs ? 'Tu conductor está esperando en el punto de recogida.' : 'Your driver is waiting at the pickup location.',
    'in_trip'            => isEs ? 'Estás en camino a tu destino.' : 'You are on your way to your destination.',
    'completed'          => isEs ? 'Has llegado. ¡Gracias por viajar con Cruise!' : 'You have arrived. Thanks for riding with Cruise!',
    'scheduled_reminder' => isEs ? 'Tu viaje programado está por comenzar.' : 'Your scheduled ride is coming up soon.',
    // ── Driver notifications ──
    'trip_offer' || 'new_offer' => isEs ? 'Un pasajero necesita un viaje — abre Cruise para aceptar.' : 'A rider needs a ride — open Cruise to accept.',
    'rider_cancelled'    => isEs ? 'El pasajero canceló el viaje.' : 'The rider has cancelled the ride.',
    'trip_canceled' || 'trip_cancelled' => isEs ? 'El viaje fue cancelado por dispatch.' : 'The trip has been cancelled by dispatch.',
    'scheduled_cancelled' => isEs ? 'Un viaje programado ha sido cancelado por el pasajero.' : 'A scheduled ride has been cancelled by the rider.',
    'tip_received'       => isEs ? 'Un pasajero te dejó una propina. ¡Sigue así!' : 'A rider left you a tip. Keep up the great work!',
    'level_up'           => isEs ? '¡Felicidades! Subiste de nivel en Cruise.' : 'Congratulations! You leveled up in Cruise.',
    'level_down'         => isEs ? 'Tu nivel de conductor ha cambiado. Revisa la app.' : 'Your driver level has changed. Check the app for details.',
    'instant_cashout'    => isEs ? 'Tu retiro instantáneo se procesó exitosamente.' : 'Your instant cashout has been processed successfully.',
    _ => '',
  };
}

@pragma('vm:entry-point')
Future<void> _firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  if (Firebase.apps.isEmpty) {
    await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  }
  final type = message.data['type'] as String? ?? '';

  // The system already drew this one.
  //
  // The backend sends offers with a `notification` block, so FCM renders the
  // alert itself the instant it arrives — guaranteed, even from a cold
  // process, and with the tap wired to onMessageOpenedApp. Drawing a second
  // copy here put TWO alerts on the driver's phone for one offer.
  //
  // Dropping the backend block instead was tried and reverted: without it,
  // onMessageOpenedApp never fires and the notification became untappable.
  // And the reason this copy existed at all — fullScreenIntent — has never
  // worked: USE_FULL_SCREEN_INTENT was missing from the manifest, so Android
  // has silently ignored the flag since API 29. The permission is declared
  // now, but earning a real full-screen takeover also needs the Android 14
  // user grant, so it cannot be the only path an offer arrives by.
  if (type == 'trip_offer' || type == 'new_offer') return;

  final plugin = FlutterLocalNotificationsPlugin();
  const androidSettings = AndroidInitializationSettings('@mipmap/ic_launcher');
  await plugin.initialize(
    settings: const InitializationSettings(android: androidSettings),
  );

  // System push notifications for rider + driver (show even when app is killed)
  const riderTypes = {
    // Rider
    'driver_assigned',
    'driver_arriving',
    'driver_arrived',
    'driver_found',
    'arrived_dropoff',
    'fast_ride',
    'driver_cancelled',
    'ride_reassigned',
    'scheduled_claimed',
    'scheduled_driver_cancelled',
    'arrived',
    'in_trip',
    'completed',
    'scheduled_reminder',
    // Driver
    'rider_cancelled',
    'scheduled_cancelled',
    'tip_received',
    'level_up',
    'level_down',
    'instant_cashout',
  };
  if (riderTypes.contains(type)) {
    final title = message.notification?.title ?? message.data['title'] ?? _riderNotifTitle(type);
    final body = message.notification?.body ?? message.data['body'] ?? _riderNotifBody(type);
    await plugin.show(
      id: DateTime.now().millisecondsSinceEpoch ~/ 1000,
      title: title,
      body: body,
      notificationDetails: NotificationDetails(
        android: AndroidNotificationDetails(
          'cruise_premium',
          'Cruise Notifications',
          channelDescription: 'Ride status updates',
          importance: Importance.high,
          priority: Priority.high,
          playSound: true,
          sound: const RawResourceAndroidNotificationSound('cruise_online'),
          enableVibration: true,
          vibrationPattern: Int64List.fromList([0, 150, 100, 150, 100, 150]),
          color: const Color(0xFFE8C547),
          icon: '@mipmap/ic_launcher',
        ),
        iOS: const DarwinNotificationDetails(
          presentAlert: true,
          presentBadge: true,
          presentSound: true,
          sound: 'cruise_online.wav',
          interruptionLevel: InterruptionLevel.timeSensitive,
        ),
      ),
      payload: type,
    );
  }
}

/// Navigate to DriverOnlineScreen when driver taps a "new_offer" FCM notification.
void _handleDriverRideOffer(RemoteMessage message) {
  if ((message.data['type'] as String? ?? '') != 'new_offer') return;
  _openDriverRideOffer(
    offerId: message.data['offer_id']?.toString() ?? '',
    tripId: message.data['trip_id']?.toString() ?? '',
  );
}

/// Route a tap on a local notification written with [_offerPayload].
///
/// The notification the background isolate puts up is a local one, so nothing
/// about the tap reaches [FirebaseMessaging.onMessageOpenedApp] — the ids come
/// back out of the payload string instead.
void handleOfferNotificationPayload(String? payload) {
  if (payload == null || !payload.startsWith('trip_offer')) return;
  final parts = payload.split(':');
  _openDriverRideOffer(
    offerId: parts.length > 2 ? parts[2] : '',
    tripId: parts.length > 1 ? parts[1] : '',
  );
}

/// How long a tap waits for the offer lookup before the screen is pushed
/// anyway. The tap is the driver's, not the network's: past this the screen
/// goes up and its own poll finds the offer the way it always did.
const Duration _offerLookupBudget = Duration(milliseconds: 1200);

/// What [_fetchPendingOffer] answers: the offer, and whether dispatch was
/// reachable at all.
typedef _PendingOfferLookup = ({bool reachable, Map<String, dynamic>? offer});

/// Open the driver's online screen ON the offer the notification was about.
///
/// The push names its offer (`offer_id` / `trip_id`, see
/// backend/routers/dispatch.py) and the cascade hands that same offer to the
/// next driver OFFER_TIMEOUT_SECONDS later. Both ids used to be dropped here:
/// the screen went up bare and started looking for whatever dispatch still had
/// for this driver, so a tap late in the window either found the card after a
/// round trip of its own, or sat on the "Finding trips" bar without ever
/// saying the ride had already moved on.
///
/// Now the offer is looked up by id first and handed to the screen whole, and
/// a lookup that comes back without it means the cascade reassigned it — which
/// is said out loud instead of being left to the driver to work out.
void _openDriverRideOffer({required String offerId, required String tripId}) {
  UserSession.getMode().then((mode) async {
    if (mode != 'driver') return;

    final Future<_PendingOfferLookup?>? lookup =
        offerId.isEmpty && tripId.isEmpty
            ? null
            : _fetchPendingOffer(offerId, tripId);
    _PendingOfferLookup? found;
    if (lookup != null) {
      found = await lookup.timeout(_offerLookupBudget, onTimeout: () => null);
    }

    final nav = _navigatorKey.currentState;
    if (nav == null) return;
    // The screen that DREW this notification is still up.
    //
    // A warm-app tap can only come from the local notification, and the only
    // thing that posts it is DriverOnlineScreen's own background branch — so
    // that screen is on the stack by construction. Pushing a second copy
    // buries the live one, SSE, poll and map included, and makes the new one
    // rebuild all of it while the offer's 45 seconds run down. Returning to
    // the driver is the whole job; its own stream already has the offer.
    if (DriverOnlineScreen.mountedCount > 0) {
      debugPrint('[FCM] offer tap — driver screen already up, not stacking');
      return;
    }
    nav.push(PageRouteBuilder(
      opaque: false,
      pageBuilder: (_, __, ___) =>
          DriverOnlineScreen(
            deepLinkOffer: found?.offer,
            // Dispatch only offers rides to drivers who are ALREADY online,
            // so arriving here from a notification is a resume by
            // definition. Left at the default `false` the screen replayed
            // the entire go-online handshake — with an offer waiting and 45
            // seconds on the clock.
            resuming: true,
          ),
      transitionDuration: const Duration(milliseconds: 280),
      reverseTransitionDuration: const Duration(milliseconds: 220),
      transitionsBuilder: (_, anim, __, child) => FadeTransition(
        opacity: CurvedAnimation(parent: anim, curve: Curves.easeInOut),
        child: child,
      ),
    ));
    debugPrint('[FCM] offer tap → DriverOnlineScreen '
        'offer=$offerId trip=$tripId card=${found?.offer != null}');

    if (lookup == null || found?.offer != null) return;
    // Either the lookup outran the budget above or it answered while the
    // route was going up; this is the settled answer either way.
    lookup.then((result) {
      if (result == null || result.offer != null || !result.reachable) return;
      _showOfferGoneNotice();
    });
  });
}

/// The still-pending offer with this id, straight from dispatch.
///
/// `reachable` is false when the question could not be asked — no session, no
/// network — so a dead connection is never reported to the driver as a ride
/// somebody else took.
Future<_PendingOfferLookup> _fetchPendingOffer(
  String offerId,
  String tripId,
) async {
  try {
    final driverId = await ApiService.getCurrentUserId();
    if (driverId == null) return (reachable: false, offer: null);
    final pending = await ApiService.getDriverPendingOffers(driverId);
    for (final o in pending) {
      // In a pending row `offer_id` is the offer and `id` is the trip it was
      // cut from — the row is the offer merged with _trip_dict, see
      // backend/routers/dispatch.py. The push carries both ids, and either
      // one names the ride the driver just tapped.
      final matchesOffer =
          offerId.isNotEmpty && o['offer_id']?.toString() == offerId;
      final matchesTrip = tripId.isNotEmpty &&
          (o['trip_id'] ?? o['id'])?.toString() == tripId;
      if (matchesOffer || matchesTrip) return (reachable: true, offer: o);
    }
    return (reachable: true, offer: null);
  } catch (e) {
    debugPrint('[FCM] offer $offerId lookup failed: $e');
    return (reachable: false, offer: null);
  }
}

/// Say the offer is gone. The driver opened the app from a notification about
/// one specific ride, and landing on the searching bar with nothing said reads
/// as the app having lost it.
void _showOfferGoneNotice() {
  final ctx = _navigatorKey.currentContext;
  if (ctx == null) return;
  // maybeOf: this lands a frame or more after the route was pushed, off any
  // build of ours, and the lookup can settle while the tree is rebuilding.
  final messenger = ScaffoldMessenger.maybeOf(ctx);
  if (messenger == null) return;
  messenger.showSnackBar(SnackBar(
    content: Text(
      S.of(ctx).tripNoLongerAvailable,
      style: const TextStyle(color: Colors.black, fontWeight: FontWeight.w700),
    ),
    backgroundColor: const Color(0xFFD4A843),
    behavior: SnackBarBehavior.floating,
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    duration: const Duration(seconds: 4),
  ));
}

/// Unified notification tap handler — routes to correct screen by FCM type.
void _handleNotificationTap(RemoteMessage message) {
  final type = message.data['type'] as String? ?? '';

  // Driver: ride offer → DriverOnlineScreen
  if (type == 'new_offer') {
    _handleDriverRideOffer(message);
    return;
  }

  // Rider: scheduled ride starting → fetch trip and open tracking
  if (type == 'scheduled_trip_starting' || type == 'scheduled_claimed') {
    final tripId = int.tryParse(message.data['trip_id'] ?? '');
    if (tripId != null) {
      _navigateToScheduledTracking(tripId);
    }
    return;
  }

  // Rider: driver cancelled scheduled → refresh home card
  if (type == 'scheduled_driver_cancelled') {
    HomeScreen.scheduledRideRefresh.value++;
    return;
  }

  // ── Chat message tap ──
  if (type == 'chat_message') {
    final tripId = int.tryParse(message.data['trip_id'] ?? '');
    if (tripId != null) {
      _navigateToChat(tripId);
    }
    return;
  }

  // ── Trip cancelled by dispatch ──
  // Backend sends 'trip_canceled' (1 l) when dispatch cancels a trip.
  // The Firestore watcher on each screen handles the actual UI update,
  // but the notification tap should refresh the home screen so the user
  // sees the trip is gone if they open the app from the notification.
  if (type == 'trip_canceled' || type == 'trip_cancelled') {
    HomeScreen.scheduledRideRefresh.value++;
    return;
  }

  // ── Account approval / rejection taps ──
  if (type == 'driver_approved' || type == 'rider_approved') {
    _handleAccountApproved(type == 'driver_approved');
    return;
  }
  if (type == 'driver_rejected' || type == 'rider_rejected') {
    _handleAccountRejected(type == 'driver_rejected');
    return;
  }
}

/// Fetch scheduled trip from backend and navigate to RiderTrackingScreen.
void _navigateToScheduledTracking(int tripId) {
  ApiService.getTrip(tripId).then((fresh) {
    final status = (fresh['status'] ?? '').toString().toLowerCase();
    const activeStatuses = {
      'scheduled_accepted', 'scheduled_active', 'driver_assigned',
      'accepted', 'en_route', 'en_route_to_pickup', 'driver_en_route',
      'arriving', 'arrived', 'driver_arrived', 'in_trip', 'in_progress',
    };
    if (!activeStatuses.contains(status) || fresh['driver_id'] == null) return;

    final pickupLat = (fresh['pickup_lat'] as num?)?.toDouble();
    final pickupLng = (fresh['pickup_lng'] as num?)?.toDouble();
    final dropoffLat = (fresh['dropoff_lat'] as num?)?.toDouble();
    final dropoffLng = (fresh['dropoff_lng'] as num?)?.toDouble();
    if (pickupLat == null || pickupLng == null ||
        dropoffLat == null || dropoffLng == null) {
      return;
    }

    final nav = _navigatorKey.currentState;
    if (nav == null) return;
    nav.push(MaterialPageRoute(
      builder: (_) => RiderTrackingScreen(
        pickupLatLng: LatLng(pickupLat, pickupLng),
        dropoffLatLng: LatLng(dropoffLat, dropoffLng),
        driverName: (fresh['driver_name'] ?? 'Driver').toString(),
        driverPhone: (fresh['driver_phone'] ?? '').toString().isNotEmpty
            ? fresh['driver_phone'].toString()
            : null,
        driverRating: (fresh['driver_rating'] as num?)?.toDouble() ?? 4.9,
        vehicleMake: (fresh['vehicle_make'] ?? '').toString(),
        vehicleModel: (fresh['vehicle_model'] ?? '').toString(),
        vehicleColor: (fresh['vehicle_color'] ?? '').toString(),
        vehiclePlate: (fresh['vehicle_plate'] ?? '').toString(),
        vehicleYear: (fresh['vehicle_year'] ?? '').toString(),
        rideName: (fresh['vehicle_type'] ?? 'Ride').toString(),
        price: (fresh['fare'] as num?)?.toDouble() ?? 0,
        pickupLabel: (fresh['pickup_address'] ?? '').toString(),
        dropoffLabel: (fresh['dropoff_address'] ?? '').toString(),
        tripId: tripId,
        firestoreTripId: 'sql_$tripId',
        driverPhotoUrl: (fresh['driver_photo_url'] ?? '').toString(),
        driverId: (fresh['driver_id'] ?? '').toString(),
        initialStatus: status,
      ),
    ));
  }).catchError((e) {
    debugPrint('[FCM] Failed to fetch scheduled trip $tripId: $e');
  });
}

/// Navigate to ChatScreen from FCM tap.
void _navigateToChat(int tripId) {
  final nav = _navigatorKey.currentState;
  if (nav == null) return;

  ApiService.getTrip(tripId).then((trip) {
    final driverName = (trip['driver_name'] ?? 'Driver').toString();
    final driverPhoto = trip['driver_photo_url']?.toString();

    nav.push(MaterialPageRoute(
      builder: (_) => ChatScreen(
        recipientName: driverName,
        tripId: tripId,
        avatarInitial: driverName.isNotEmpty ? driverName[0] : 'D',
      ),
    ));
    debugPrint('[FCM] Navigated to ChatScreen for trip $tripId');
  }).catchError((e) {
    debugPrint('[FCM] Failed to fetch trip $tripId for chat navigation: $e');
  });
}

/// Navigate to the correct home screen after account approval.
void _handleAccountApproved(bool isDriver) {
  final nav = _navigatorKey.currentState;
  if (nav == null) return;

  // Remove any pending-review screen from the stack and push the home screen
  final route = isDriver
      ? MaterialPageRoute(builder: (_) => const DriverHomeScreen())
      : MaterialPageRoute(builder: (_) => const HomeScreen());

  nav.pushAndRemoveUntil(route, (r) => false);
  debugPrint('[FCM] Navigated to ${isDriver ? "DriverHomeScreen" : "HomeScreen"} after approval');
}

/// Navigate to pending-review screen after account rejection.
void _handleAccountRejected(bool isDriver) {
  if (!isDriver) return; // riders don't have a pending-review screen

  final nav = _navigatorKey.currentState;
  if (nav == null) return;

  nav.pushAndRemoveUntil(
    MaterialPageRoute(builder: (_) => const DriverPendingReviewScreen()),
    (r) => false,
  );
  debugPrint('[FCM] Navigated to DriverPendingReviewScreen after rejection');
}

void main() async {
  // Performance profiling: track cold start
  final perfStopwatch = Stopwatch()..start();

  // Catch all unhandled async Dart errors
  await runZonedGuarded(
    () async {
      WidgetsFlutterBinding.ensureInitialized();
      debugPrint('[Perf] Flutter binding: ${perfStopwatch.elapsedMilliseconds}ms');

      // CRASH FIX: Clear potentially corrupted SharedPreferences on first run
      // after app update. This prevents crashes caused by schema changes
      // between versions (e.g., cached data from v470 incompatible with v471).
      try {
        final prefs = await SharedPreferences.getInstance().timeout(const Duration(seconds: 2));
        final lastVersion = prefs.getString('app_last_version');
        // FIX: Use PackageInfo to get the real build number instead of a
        // hardcoded string that gets forgotten on every version bump. This
        // was causing crashes because builds 478-479 never triggered cache
        // cleanup — stale data from previous builds accumulated and corrupted
        // the app state on launch.
        final packageInfo = await PackageInfo.fromPlatform().timeout(const Duration(seconds: 2));
        final currentVersion = '${packageInfo.version}+${packageInfo.buildNumber}';
        if (lastVersion != currentVersion) {
          debugPrint('[Startup] Version changed from $lastVersion to $currentVersion — clearing potentially stale caches');
          // Only clear caches that might be schema-incompatible, NOT user data
          await prefs.remove('cache_active_trip_v1');
          await prefs.remove('cache_active_trip_id_v1');
          await prefs.remove('sched_avail_cache');
          await prefs.remove('sched_mine_cache');
          await prefs.remove('pending_offers_cache');
          await prefs.remove('cache_user_v1');
          await prefs.remove('cache_driver_v1');
          await prefs.remove('cache_route_coords_v1');
          await prefs.remove('cache_last_driver_pos_v1');
          await prefs.remove('cache_last_eta_v1');
          await prefs.setString('app_last_version', currentVersion);
        }
      } catch (e) {
        debugPrint('[Startup] Version check failed: $e');
      }

      // Clear any stale MapControllerCache from previous session.
      // A cached controller from a crashed session can cause native
      // PlatformView errors on next launch.
      MapControllerCache.instance.dispose();
      debugPrint('[Startup] MapControllerCache cleared');

      // M1: Catch platform-level errors (native threads, plugin exceptions)
      WidgetsBinding.instance.platformDispatcher.onError = (error, stack) {
        debugPrint('[PlatformError] $error\n$stack');
        if (kReleaseMode) {
          FirebaseCrashlytics.instance.recordError(error, stack, fatal: true);
        }
        return true; // mark as handled — prevents default crash dialog
      };

      // Catch any Flutter framework errors and log them instead of crashing
      FlutterError.onError = (FlutterErrorDetails details) {
        FlutterError.presentError(details);
        debugPrint('[FlutterError] ${details.exception}\n${details.stack}');
        if (kReleaseMode) {
          FirebaseCrashlytics.instance.recordFlutterFatalError(details);
        }
      };

      // M1: Graceful error widget in release mode — NON-BLOCKING.
      // Widget build errors are almost always transient (null during async
      // load, NaN from backend, brief memory pressure). Showing a full-screen
      // modal blocks the user from interacting with the UI and prevents the
      // widget from self-healing on the next rebuild.
      //
      // Strategy:
      //   - First 5 errors in 10s → return SizedBox.shrink() so the tree
      //     rebuilds cleanly on the next frame. Log to Crashlytics.
      //   - >5 errors in 10s → something is genuinely broken (infinite loop,
      //     memory exhaustion). Show the blocking modal as last resort.
      // Not on web. The modal covers the whole screen after five failed
      // builds, and on web a single unsupported plugin widget reaches five in
      // one frame — so the one thing the browser build exists to show would be
      // hidden behind "Something went wrong".
      if (kReleaseMode && !kIsWeb) {
        final errorTimes = <DateTime>[];
        ErrorWidget.builder = (FlutterErrorDetails details) {
          final now = DateTime.now();
          errorTimes.removeWhere((t) => now.difference(t).inSeconds > 10);
          errorTimes.add(now);

          // Always log the error
          FirebaseCrashlytics.instance.recordError(
            details.exception,
            details.stack,
            fatal: false,
            reason: 'Build error: ${details.exception.toString().substring(0, details.exception.toString().length.clamp(0, 200))}',
          );

          // Fatal threshold: >5 build errors in 10 seconds
          if (errorTimes.length > 5) {
            return Material(
              color: Colors.black.withValues(alpha: 0.92),
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.all(32),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.error_outline, color: Colors.white38, size: 40),
                      const SizedBox(height: 16),
                      const Text(
                        'Something went wrong',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: Colors.white70, fontSize: 17, fontWeight: FontWeight.w700),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'Please restart the app.',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: Colors.white.withValues(alpha: 0.5), fontSize: 14),
                      ),
                    ],
                  ),
                ),
              ),
            );
          }

          // Non-fatal: invisible placeholder. The framework will rebuild
          // this subtree on the next frame. If the error was transient
          // (e.g., null during offer card render), the user sees nothing.
          return const SizedBox.shrink();
        };
      }

      // Guard: fail loudly in release mode if secrets were not injected at build time.
      // This catches a failed CI/CD env injection before the app reaches users.
      if (kReleaseMode) {
        assert(
          Env.apiKey.isNotEmpty,
          'FATAL: CRUISE_API_KEY not injected at build time. '
          'Pass --dart-define=CRUISE_API_KEY=... to flutter build.',
        );
        assert(
          Env.hmacSecret.isNotEmpty,
          'FATAL: CRUISE_HMAC_SECRET not injected at build time. '
          'Pass --dart-define=CRUISE_HMAC_SECRET=... to flutter build.',
        );
      }

      // ── Parallel startup: independent inits run concurrently ──
      // FIX: Each init has its own try/catch so one failure doesn't crash the app
      // Group 1: no dependencies between these
      debugPrint('[Perf] Starting Group 1 inits...');
      final group1Results = await Future.wait([
        _safeInit('PrefsCache', PrefsCache.init().timeout(const Duration(seconds: 3))),
        _safeInit('SecurityService', SecurityService.init().timeout(const Duration(seconds: 3))),
        _safeInit('CacheService', CacheService.initialize().timeout(const Duration(seconds: 3))),
        _safeInit('LocalDataService', LocalDataService.init().timeout(const Duration(seconds: 3))),
        _safeInit('LocalCache', LocalCache.init().timeout(const Duration(seconds: 3))),
        _safeInitBool('Firebase', _initFirebase().timeout(const Duration(seconds: 8))),
        _safeInit('DNS', ApiService.preResolveDns().timeout(const Duration(seconds: 3))),
      ]);
      debugPrint('[Perf] Group 1 init: ${perfStopwatch.elapsedMilliseconds}ms (results: $group1Results)');

      // Group 2: depend on Firebase being ready
      // If Firebase auth failed, skip Firebase-dependent services but still launch the app
      final firebaseOk = group1Results.length > 5 && (group1Results[5] == true);
      if (!firebaseOk) {
        debugPrint('[Firebase] WARNING: Firebase auth failed — Firestore/FCM/Analytics will be unavailable');
      }
      debugPrint('[Perf] Starting Group 2 inits...');
      final group2Results = await Future.wait([
        _safeInit('ApiService', ApiService.init().timeout(const Duration(seconds: 5))),
        if (firebaseOk) _safeInit('Analytics', AnalyticsService.instance.init().timeout(const Duration(seconds: 3))) else Future.value(true),
        _safeInit('Socket', SocketService.init().timeout(const Duration(seconds: 5))),
        if (firebaseOk) _safeInit('FeatureFlags', FeatureFlags.initRemoteConfig().timeout(const Duration(seconds: 5))) else Future.value(true),
        _safeInit('BackgroundService', DriverBackgroundService().initialize().timeout(const Duration(seconds: 3))),
      ]);
      debugPrint('[Perf] Group 2 init: ${perfStopwatch.elapsedMilliseconds}ms (results: $group2Results)');

      // Limit in-memory image cache to prevent OOM on long sessions
      PaintingBinding.instance.imageCache.maximumSizeBytes = 50 * 1024 * 1024; // 50 MB — prevents OOM on low-end devices
      PaintingBinding.instance.imageCache.maximumSize = 500;

      // Mapbox init with error handling — prevents crash on invalid token.
      // Native only: setAccessToken drops the Pigeon future, so on web the
      // MissingPluginException escapes this try and lands in runZonedGuarded.
      if (kIsWeb) {
        debugPrint('[MapboxInit] web build — using Mapbox GL JS, no native token');
      } else if (MapboxConfig.accessToken.isEmpty) {
        debugPrint('[MapboxInit] CRITICAL: MAPBOX_TOKEN is empty — map will be black');
      } else {
        try {
          MapboxOptions.setAccessToken(MapboxConfig.accessToken);
          debugPrint('[MapboxInit] Token set successfully (length=${MapboxConfig.accessToken.length})');
        } catch (e) {
          debugPrint('[MapboxInit] Failed to set token: $e');
        }
      }
      
      SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
      SystemChrome.setSystemUIOverlayStyle(
        const SystemUiOverlayStyle(),
      );
      debugPrint('[Perf] runApp: ${perfStopwatch.elapsedMilliseconds}ms');
      runApp(const UberCloneApp());
    },
    (error, stack) {
      debugPrint('[ZoneError] $error\n$stack');
      if (kReleaseMode) {
        FirebaseCrashlytics.instance.recordError(error, stack, fatal: true);
      }
    },
  );
}

/// Wraps an async init with try/catch so one failure doesn't crash the app.
/// Returns true if init succeeded, false if it failed (but app continues).
Future<bool> _safeInit(String name, Future<void> future) async {
  try {
    await future;
    debugPrint('[InitOK] $name initialized');
    return true;
  } on TimeoutException {
    debugPrint('[InitError] $name timed out — continuing without it');
    return false;
  } catch (e, stack) {
    debugPrint('[InitError] $name failed: $e');
    debugPrint(stack.toString());
    return false;
  }
}

/// Same as _safeInit but for bool-returning futures (e.g. _initFirebase).
Future<bool> _safeInitBool(String name, Future<bool> future) async {
  try {
    final result = await future;
    debugPrint('[InitOK] $name initialized (result=$result)');
    return result;
  } on TimeoutException {
    debugPrint('[InitError] $name timed out — continuing without it');
    return false;
  } catch (e, stack) {
    debugPrint('[InitError] $name failed: $e');
    debugPrint(stack.toString());
    return false;
  }
}

/// Firebase init extracted so it can run in Future.wait with other services.
/// CRITICAL: This must complete with auth established before ANY Firestore call.
Future<bool> _initFirebase() async {
  try {
    await Firebase.initializeApp(
      options: DefaultFirebaseOptions.currentPlatform,
    );
    firestore.FirebaseFirestore.instance.settings = const firestore.Settings(
      persistenceEnabled: true,
      cacheSizeBytes: 100 * 1024 * 1024, // 100 MB cap — prevents OOM on low-end devices
    );
    // Enable RTDB disk persistence so messages survive restarts & work offline.
    // Web throws UnsupportedError here, synchronously — which used to abort the
    // rest of this method, including the anonymous sign-in right below. Every
    // rule that reads `auth != null` then rejected the whole session.
    if (!kIsWeb) FirebaseDatabase.instance.setPersistenceEnabled(true);

    // ── Ensure Firebase Auth so RTDB/Firestore rules (auth != null) pass ──
    // Anonymous auth is DISABLED in the console (admin-restricted-operation):
    // the old 3-attempt signInAnonymously loop here failed on every boot,
    // left every client without a session, and turned all Firestore/RTDB
    // access into the permission-denied crash groups on Crashlytics. The
    // working path is the backend-minted custom token — and it needs the
    // app JWT, which a signed-out user does not have yet. That is fine:
    // ensureSignedIn() is retried after login and by every recovery path.
    final ok = await FirebaseAuthRecovery.ensureSignedIn();
    if (!ok) {
      debugPrint('[Firebase] no session yet (signed out or mint '
          'unavailable) — realtime mirrors stay off, fallbacks carry');
      return false;
    }

    // Re-establish the session if it expires mid-use.
    unawaited(_fbAuthStateSub?.cancel());
    _fbAuthStateSub = FirebaseAuth.instance.authStateChanges().listen((user) async {
      if (user == null) {
        debugPrint('[Firebase] auth lost — re-establishing via custom token…');
        await FirebaseAuthRecovery.ensureSignedIn();
      }
    });
    return true;
  } catch (e) {
    debugPrint('[Firebase] early init error: $e');
    return false;
  }
}

/// The long-lived stream listeners [heavyInit] and the early Firebase init
/// attach.
///
/// Held so they can be cancelled before being re-attached. Neither function
/// runs only once: SplashScreen is pushed again on every logout (see
/// account_screen, driver_menu_screen, privacy_screen), and each pass used
/// to add another listener to the same stream. After three logout/login
/// cycles in one process a single ride offer produced three notifications
/// and three screen pushes.
StreamSubscription<RemoteMessage>? _fcmOnMessageSub;
StreamSubscription<RemoteMessage>? _fcmOpenedAppSub;
StreamSubscription<User?>? _fbAuthStateSub;

/// Heavy async init that runs while the splash animation plays.
/// Called from SplashScreen.initState().
Future<void> heavyInit() async {
  // Probe + warm up the server in the background — NEVER block splash on this.
  unawaited(ApiService.probeAndSetBestUrl(
    timeout: const Duration(seconds: 2),
  ).timeout(
    const Duration(seconds: 3),
    onTimeout: () {
      debugPrint('[heavyInit] probe timed out — using production URL');
      return null;
    },
  ));

  // Start keep-alive pings to prevent server sleep
  KeepAliveService.instance.start();

  // Pre-resolve DNS for all API domains (non-blocking)
  unawaited(ApiService.preResolveDns());

  // Run remaining init tasks in parallel — none depend on each other
  // Initialize network connectivity listener (sync — no Future)
  NetworkService().init();

  await Future.wait([
    // Initialize Mapbox offline tile cache (native only — TileStore has no web side)
    if (kIsWeb) Future<void>.value() else MapCacheService().init(),

    // Initialize profile photo notifier
    UserSession.initPhotoNotifier(),

    // ── Stripe ──
    () async {
      if (!kIsWeb && ApiKeys.stripePublishableKey.isNotEmpty && !ApiKeys.stripePublishableKey.contains('REPLACE')) {
        try {
          Stripe.publishableKey = ApiKeys.stripePublishableKey;
          Stripe.merchantIdentifier = ApiKeys.stripeMerchantId;
          await Stripe.instance.applySettings();
        } catch (e) {
          debugPrint('[Stripe] init failed: $e');
        }
      } else {
        debugPrint('[Stripe] skipped — placeholder key detected');
      }
    }(),

    // ── Firebase + Messaging ──
    // NOTE: Firebase.initializeApp() and anonymous auth are already done
    // in main() Group 1. We only set up FCM handlers here.
    () async {
      if (kIsWeb) return; // no Crashlytics, no service worker, no FCM
      try {
        try {
          await FirebaseCrashlytics.instance.setCrashlyticsCollectionEnabled(kReleaseMode);

          // Register background handler BEFORE any other messaging setup
          FirebaseMessaging.onBackgroundMessage(_firebaseMessagingBackgroundHandler);

          final messaging = FirebaseMessaging.instance;
          await messaging.requestPermission(alert: true, badge: true, sound: true);

          // iOS: suppress all FCM banner notifications while the app is in
          // the foreground. The foreground handler below already updates the
          // UI silently and plays in-app sounds; showing the system banner
          // on top of the active screen is redundant and annoying.
          await messaging.setForegroundNotificationPresentationOptions(
            alert: false,
            badge: false,
            sound: false,
          );

          final fcmToken = await messaging.getToken();
          if (kDebugMode) debugPrint('[FCM] token: $fcmToken');

          // Register the token with the backend + keep it updated on
          // rotation (covers restarts with an active session).
          unawaited(NotificationService.registerTokenWithBackend());

          unawaited(_fcmOnMessageSub?.cancel());
          _fcmOnMessageSub = FirebaseMessaging.onMessage.listen((RemoteMessage message) {
            final type = message.data['type'] as String? ?? 'general';
            // For driver ride offers: always use clean title/body — never show price or address
            final bool isOffer = type == 'trip_offer' || type == 'new_offer';
            final title = isOffer
                ? 'New Ride Offer'
                : (message.notification?.title ??
                    message.data['title'] ??
                    _riderNotifTitle(type));
            final body = isOffer
                ? 'A rider needs a ride \u2014 open Cruise to accept.'
                : (message.notification?.body ??
                    message.data['body'] ??
                    _riderNotifBody(type));

            // ── In-app notification policy ──
            // By default ALL foreground notifications are suppressed.
            // Only specific types are allowed through:
            //
            // RIDER (show in-app):
            //   driver_arriving, driver_arrived, arrived, completed, arrived_dropoff
            //
            // DRIVER (show in-app):
            //   chat_message (from rider), trip_offer, new_offer,
            //   rider_cancelled, scheduled_cancelled, scheduled_available

            const riderInAppTypes = {
              'driver_arriving', 'driver_arrived', 'arrived',
              'completed', 'arrived_dropoff',
              'scheduled_claimed', 'scheduled_driver_cancelled',
              // Verification decision — rider must see their account was
              // approved/rejected the second dispatch acts on it.
              'rider_approved', 'rider_rejected',
              // FIX: dispatch cancellation uses 'trip_canceled' (1 l)
              'trip_canceled', 'trip_cancelled',
            };
            const driverInAppTypes = {
              'trip_offer', 'new_offer',
              'rider_cancelled', 'scheduled_cancelled', 'scheduled_available',
              // Driver verification decision from dispatch.
              'driver_approved', 'driver_rejected',
              // FIX: dispatch cancellation uses 'trip_canceled' (1 l)
              'trip_canceled', 'trip_cancelled',
            };

            // Chat messages: suppress in-app notification — the OS already shows
            // the FCM push when the app is backgrounded. When foreground, the user
            // is already in the app and doesn't need an intrusive overlay.
            if (type == 'chat_message') {
              final tripId = int.tryParse(message.data['trip_id']?.toString() ?? '');
              // Always suppress if user is in that chat screen
              if (tripId != null && ChatScreen.activeTripId == tripId) {
                debugPrint('[FCM] suppressed chat notification — user is in chat');
                return;
              }
              // Save to notification history only (no local OS notification)
              LocalDataService.addNotification(
                title: title,
                message: body,
                type: type,
              );
              return;
            }

            // Check if this notification type is allowed in-app
            final isAllowedInApp = riderInAppTypes.contains(type) ||
                driverInAppTypes.contains(type);

            if (!isAllowedInApp) {
              // Suppress — only save to notification history
              debugPrint('[FCM] suppressed foreground notification type=$type');
              LocalDataService.addNotification(
                title: title,
                message: body,
                type: type,
              );
              return;
            }

            // Save to notification history only — the OS already shows FCM push
            // notifications when the app is backgrounded. When foreground, we
            // update the UI silently without an intrusive local notification overlay.
            LocalDataService.addNotification(
              title: title,
              message: body,
              type: type,
            );

            // Play offer sound for trip offers (foreground only — background
            // offers already play sound via the FCM notification channel)
            if (type == 'trip_offer' || type == 'new_offer') {
              NotificationService.playOfferSound();
            }

            // Scheduled ride reminder — navigate to ride request if 15-min alert
            if (type == 'scheduled_reminder' || type == 'scheduled_trip_starting') {
              // 15-min rider reminder — fetch trip and navigate to tracking
              if (type == 'scheduled_trip_starting') {
                final tripId = int.tryParse(message.data['trip_id'] ?? '');
                if (tripId != null) {
                  _navigateToScheduledTracking(tripId);
                }
              }
            }

            // Scheduled ride status changed — refresh home screen card
            if (type == 'scheduled_claimed' || type == 'scheduled_driver_cancelled') {
              HomeScreen.scheduledRideRefresh.value++;
            }

            // ── Account approval / rejection (driver + rider) ──
            // When dispatch approves or rejects, navigate the user instantly
            // so they don't stay stuck on "Application Under Review".
            if (type == 'driver_approved' || type == 'rider_approved') {
              LocalDataService.setDriverApprovalStatus('approved').then((_) {
                _handleAccountApproved(type == 'driver_approved');
              });
            }
            if (type == 'driver_rejected' || type == 'rider_rejected') {
              LocalDataService.setDriverApprovalStatus('rejected').then((_) {
                _handleAccountRejected(type == 'driver_rejected');
              });
            }
          });
          // Handle notification tap when app is backgrounded
          unawaited(_fcmOpenedAppSub?.cancel());
          _fcmOpenedAppSub =
              FirebaseMessaging.onMessageOpenedApp.listen(_handleNotificationTap);
          // Handle notification tap when app was fully terminated
          FirebaseMessaging.instance.getInitialMessage().then((msg) {
            if (msg != null) {
              // Use post-frame callback instead of artificial delay
              WidgetsBinding.instance.addPostFrameCallback((_) {
                _handleNotificationTap(msg);
              });
            }
          });
        } catch (e) {
          debugPrint('[FCM] init error: $e');
        }
      } catch (e) {
        debugPrint('[Firebase] init error: $e');
      }
    }(),

    // ── Local Notifications ──
    () async {
      try {
        if (kIsWeb) {
          // flutter_local_notifications has no web package — only arm the
          // offer AudioPlayer (audioplayers works on web) so offers are
          // not silent in the browser.
          await NotificationService.initWebAudio();
          return;
        }
        await NotificationService.init();
        // The third way into the offer: a tap on the notification the
        // background isolate showed, when that tap is what started the app.
        // FCM's own getInitialMessage knows only about the push it received,
        // never about a local notification, so without this the ids of the
        // offer the driver tapped are gone by the time the app is up.
        // Cold launch covers the app that was not running; this covers the
        // one that was — a tap on a local notification with the app warm
        // reaches _onNotificationTapped and nowhere else.
        NotificationService.onOfferTapped = handleOfferNotificationPayload;

        final launch = await FlutterLocalNotificationsPlugin()
            .getNotificationAppLaunchDetails();
        if (launch?.didNotificationLaunchApp ?? false) {
          final payload = launch?.notificationResponse?.payload;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            handleOfferNotificationPayload(payload);
          });
        }
      } catch (e) {
        debugPrint('[NotificationService] init error: $e');
      }
    }(),
  ]);

  // Deferred cache cleanup — runs 10s after startup, non-blocking
  Future.delayed(const Duration(seconds: 10), () {
    MapCacheService().cleanIfNeeded();
  });

  // Pre-cache map tiles around last known driver location (if available)
  final lastLat = LocalCache.get<double>('last_driver_lat');
  final lastLng = LocalCache.get<double>('last_driver_lng');
  if (lastLat != null && lastLng != null) {
    MapCacheService().precacheArea(
      regionId: 'startup_area',
      lat: lastLat,
      lng: lastLng,
      minZoom: 12,
      maxZoom: 15,
      radiusKm: 3.0,
    );
  }
}

/// Smooth 60 fps scroll everywhere — iOS-style bouncing on all platforms.
class SmoothScrollBehavior extends ScrollBehavior {
  const SmoothScrollBehavior();

  @override
  ScrollPhysics getScrollPhysics(BuildContext context) =>
      const BouncingScrollPhysics(parent: AlwaysScrollableScrollPhysics());

  @override
  Widget buildOverscrollIndicator(
    BuildContext context,
    Widget child,
    ScrollableDetails details,
  ) {
    // Remove the Android glow — we already have bounce
    return child;
  }
}

class UberCloneApp extends StatefulWidget {
  const UberCloneApp({super.key});

  @override
  State<UberCloneApp> createState() => _UberCloneAppState();
}

class _UberCloneAppState extends State<UberCloneApp>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // M2: auto-logout when JWT is expired and refresh also fails.
    // Guard against re-entry: if already on auth screens, skip.
    ApiService.onUnauthorized = () async {
      // Prevent double-fire or firing during login
      final nav = _navigatorKey.currentState;
      if (nav == null) return;
      // Check if we're already showing an auth/splash screen
      bool alreadyOnAuth = false;
      nav.popUntil((route) {
        final name = route.settings.name;
        if (name == '/' || route.isFirst) alreadyOnAuth = true;
        return true; // don't actually pop — just inspect
      });
      await ApiService.clearToken();
      if (!alreadyOnAuth) {
        nav.pushAndRemoveUntil(
          PageRouteBuilder(
            pageBuilder: (_, __, ___) => const SplashScreen(),
            transitionDuration: const Duration(milliseconds: 280),
            reverseTransitionDuration: const Duration(milliseconds: 220),
            transitionsBuilder: (_, anim, __, child) => FadeTransition(
              opacity: CurvedAnimation(parent: anim, curve: Curves.easeInOut),
              child: child,
            ),
          ),
          (_) => false,
        );
      }
    };

    // Driver session replaced on another device — show dialog then force logout
    ApiService.onSessionExpiredNewDevice = () {
      final nav = _navigatorKey.currentState;
      if (nav == null) return;
      showDialog(
        context: nav.overlay!.context,
        barrierDismissible: false,
        builder: (_) => AlertDialog(
          title: const Text('Sesion cerrada'),
          content: const Text(
            'Tu cuenta se abrio en otro dispositivo. Solo puedes tener una sesion activa.',
          ),
          actions: [
            TextButton(
              onPressed: () {
                Navigator.of(nav.overlay!.context).pop();
                nav.pushAndRemoveUntil(
                  PageRouteBuilder(
                    pageBuilder: (_, __, ___) => const SplashScreen(),
                    transitionDuration: const Duration(milliseconds: 280),
                    reverseTransitionDuration: const Duration(milliseconds: 220),
                    transitionsBuilder: (_, anim, __, child) => FadeTransition(
                      opacity: CurvedAnimation(parent: anim, curve: Curves.easeInOut),
                      child: child,
                    ),
                  ),
                  (_) => false,
                );
              },
              child: const Text('Aceptar'),
            ),
          ],
        ),
      );
    };
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      // Only mark riders offline on pause — drivers control their
      // online state via the explicit toggle; pausing the app briefly
      // (phone lock, switching apps) must NOT set is_online=false.
      UserSession.getMode().then((mode) {
        if (mode != 'driver') ApiService.goOffline();
      });
      KeepAliveService.instance.stop();
    } else if (state == AppLifecycleState.resumed) {
      // getMe marks user as online on the backend
      ApiService.getMe();
      KeepAliveService.instance.start();
    }
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Listenable.merge([themeNotifier, accessibilityNotifier]),
      builder: (context, _) {
        final a11y = accessibilityNotifier;

        // High contrast theme overrides
        final ThemeData effectiveDark = a11y.highContrast
            ? darkTheme.copyWith(
                colorScheme: darkTheme.colorScheme.copyWith(
                  primary: Colors.white,
                  secondary: const Color(0xFFFFD700),
                  surface: Colors.black,
                ),
                scaffoldBackgroundColor: Colors.black,
              )
            : darkTheme;
        final ThemeData effectiveLight = a11y.highContrast
            ? lightTheme.copyWith(
                colorScheme: lightTheme.colorScheme.copyWith(
                  primary: Colors.black,
                  secondary: const Color(0xFFFFD700),
                  surface: Colors.white,
                ),
              )
            : lightTheme;

        final selectedTheme = themeNotifier.isNightMode ? effectiveDark : effectiveLight;

        Widget app = AnimatedTheme(
          data: selectedTheme,
          duration: const Duration(milliseconds: 400),
          curve: Curves.easeInOut,
          child: MaterialApp(
            navigatorKey: _navigatorKey,
            debugShowCheckedModeBanner: false,
            themeMode: themeNotifier.mode,
            theme: effectiveLight,
            darkTheme: effectiveDark,
            scrollBehavior: const SmoothScrollBehavior(),
            // Smooth page transitions for all routes
            onGenerateRoute: (settings) {
              return SmoothTransitions.fadeSlide(
                page: _getPageForRoute(settings),
                fromRight: true,
              );
            },
            localizationsDelegates: const [
              S.delegate,
              GlobalMaterialLocalizations.delegate,
              GlobalWidgetsLocalizations.delegate,
              GlobalCupertinoLocalizations.delegate,
            ],
            supportedLocales: const [Locale('en'), Locale('es')],
            localeResolutionCallback: (deviceLocale, supported) {
              // Match any Spanish variant (es_MX, es_US, etc.) to 'es'
              if (deviceLocale?.languageCode == 'es') {
                return const Locale('es');
              }
              return const Locale('en');
            },
            navigatorObservers: [
              AnalyticsService.instance.observer,
              // Lets a screen underneath the stack drop its native Mapbox
              // surface while something else is on top — see
              // lib/config/route_observers.dart.
              mapRouteObserver,
            ],
            home: const SplashScreen(),
            builder: (context, child) {
              Responsive.init(context);
              final scale = a11y.textScale;
              return MediaQuery(
                data: MediaQuery.of(context).copyWith(
                  textScaler: TextScaler.linear(scale),
                ),
                child: ScrollConfiguration(
                  behavior: const SmoothScrollBehavior(),
                  child: child!,
                ),
              );
            },
          ),
        );

        // Color blind filter wrapping
        if (a11y.colorBlindMode != 'none') {
          app = ColorFiltered(
            colorFilter: _colorBlindFilter(a11y.colorBlindMode),
            child: app,
          );
        }

        return app;
      },
    );
  }
}

/// Route generator for smooth transitions
Widget _getPageForRoute(RouteSettings settings) {
  // Deep link handling: store deep link data in UserSession for later processing
  // Format examples:
  // - cruiseapp://trips/{trip_id}/split/{split_id} (fare-split accept)
  // - cruiseapp://promo?code=SUMMER20 (promo code)
  // - cruiseapp://referral?ref={code} (referral)
  if (settings.name != null && settings.name!.isNotEmpty) {
    try {
      final uri = Uri.parse(settings.name ?? '');
      // Store deep link for splash screen to process
      UserSession.currentDeepLink = uri;
    } catch (e) {
      debugPrint('[DeepLink] Parse error: $e');
    }
  }
  // Always go through splash - it will check and process deep links
  return const SplashScreen();
}

/// Color blind simulation filter matrices.
ColorFilter _colorBlindFilter(String mode) {
  switch (mode) {
    case 'protanopia':
      return const ColorFilter.matrix(<double>[
        0.567, 0.433, 0, 0, 0,
        0.558, 0.442, 0, 0, 0,
        0, 0.242, 0.758, 0, 0,
        0, 0, 0, 1, 0,
      ]);
    case 'deuteranopia':
      return const ColorFilter.matrix(<double>[
        0.625, 0.375, 0, 0, 0,
        0.7, 0.3, 0, 0, 0,
        0, 0.3, 0.7, 0, 0,
        0, 0, 0, 1, 0,
      ]);
    case 'tritanopia':
      return const ColorFilter.matrix(<double>[
        0.95, 0.05, 0, 0, 0,
        0, 0.433, 0.567, 0, 0,
        0, 0.475, 0.525, 0, 0,
        0, 0, 0, 1, 0,
      ]);
    default:
      return const ColorFilter.matrix(<double>[
        1, 0, 0, 0, 0,
        0, 1, 0, 0, 0,
        0, 0, 1, 0, 0,
        0, 0, 0, 1, 0,
      ]);
  }
}
