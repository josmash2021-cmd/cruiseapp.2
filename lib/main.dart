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
import 'config/smooth_transitions.dart';
import 'config/page_transitions.dart';
import 'config/api_keys.dart';
import 'config/app_theme.dart';
import 'config/env.dart';
import 'config/theme_notifier.dart';
import 'config/feature_flags.dart';
import 'state/accessibility_notifier.dart';
import 'screens/splash_screen.dart';
import 'screens/driver/driver_online_screen.dart';
import 'services/api_service.dart';
import 'services/notification_service.dart';
import 'services/security_service.dart';
import 'services/user_session.dart';
import 'services/local_data_service.dart';
import 'services/local_cache.dart';
import 'services/cache_service.dart';
import 'services/map_cache_service.dart';
import 'services/network_service.dart';
import 'services/keep_alive_service.dart';
import 'services/analytics_service.dart';
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
  final plugin = FlutterLocalNotificationsPlugin();
  const androidSettings = AndroidInitializationSettings('@mipmap/ic_launcher');
  await plugin.initialize(
    settings: const InitializationSettings(android: androidSettings),
  );

  if (type == 'trip_offer' || type == 'new_offer') {
    // Always show clean title/body — never expose price or address to driver
    const title = 'New Ride Offer';
    const body = 'A rider needs a ride \u2014 open Cruise to accept.';
    await plugin.show(
      id: 9001,
      title: title,
      body: body,
      notificationDetails: NotificationDetails(
        android: AndroidNotificationDetails(
          'cruise_offers',
          'Trip Offers',
          channelDescription: 'New trip offer alerts for drivers',
          importance: Importance.max,
          priority: Priority.max,
          playSound: true,
          sound: const RawResourceAndroidNotificationSound('cruise_online'),
          enableVibration: true,
          vibrationPattern: Int64List.fromList([0, 150, 100, 150, 100, 150]),
          fullScreenIntent: true,
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
      payload: 'trip_offer',
    );
  }

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
  UserSession.getMode().then((mode) {
    if (mode != 'driver') return;
    final nav = _navigatorKey.currentState;
    if (nav == null) return;
    nav.push(PageRouteBuilder(
      opaque: false,
      pageBuilder: (_, __, ___) => const DriverOnlineScreen(),
      transitionDuration: const Duration(milliseconds: 280),
      reverseTransitionDuration: const Duration(milliseconds: 220),
      transitionsBuilder: (_, anim, __, child) => FadeTransition(
        opacity: CurvedAnimation(parent: anim, curve: Curves.easeInOut),
        child: child,
      ),
    ));
  });
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

void main() async {
  // Performance profiling: track cold start
  final perfStopwatch = Stopwatch()..start();

  // Catch all unhandled async Dart errors
  await runZonedGuarded(
    () async {
      WidgetsFlutterBinding.ensureInitialized();
      debugPrint('[Perf] Flutter binding: ${perfStopwatch.elapsedMilliseconds}ms');

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

      // M1: Friendly error widget in release mode — no red/grey screen of death
      if (kReleaseMode) {
        ErrorWidget.builder = (FlutterErrorDetails _) {
          return const Material(
            color: Colors.black,
            child: Center(
              child: Text(
                'Algo salió mal.\nCierra y reinicia la app.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.white70, fontSize: 15),
              ),
            ),
          );
        };
      }

      // Guard: fail loudly in release mode if dev placeholder credentials slipped through.
      // This catches a failed Codemagic env injection before the app reaches users.
      if (kReleaseMode) {
        assert(
          Env.apiKey != 'dev-api-key-change-in-production',
          'FATAL: dev API key in production build. Check Codemagic generate_env step.',
        );
        assert(
          Env.hmacSecret != 'dev-hmac-secret-change-in-production',
          'FATAL: dev HMAC secret in production build. Check Codemagic generate_env step.',
        );
      }

      // ── Parallel startup: independent inits run concurrently ──
      // Group 1: no dependencies between these
      await Future.wait([
        PrefsCache.init(),           // cache SharedPreferences singleton early
        SecurityService.init(),
        CacheService.initialize(),
        LocalDataService.init(),
        LocalCache.init(),
        _initFirebase(),
        ApiService.preResolveDns(), // warm DNS cache early — eliminates first-request latency
      ]);
      debugPrint('[Perf] Group 1 init: ${perfStopwatch.elapsedMilliseconds}ms');

      // Group 2: depend on Firebase being ready
      await Future.wait([
        ApiService.init(),
        AnalyticsService.instance.init(),
        SocketService.init(),
        FeatureFlags.initRemoteConfig(),
      ]);
      debugPrint('[Perf] Group 2 init: ${perfStopwatch.elapsedMilliseconds}ms');

      // Limit in-memory image cache to prevent OOM on long sessions
      PaintingBinding.instance.imageCache.maximumSizeBytes = 50 * 1024 * 1024; // 50 MB — prevents OOM on low-end devices
      PaintingBinding.instance.imageCache.maximumSize = 500;

      MapboxOptions.setAccessToken(MapboxConfig.accessToken);
      SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
      SystemChrome.setSystemUIOverlayStyle(
        const SystemUiOverlayStyle(statusBarColor: Colors.transparent),
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

/// Firebase init extracted so it can run in Future.wait with other services.
Future<void> _initFirebase() async {
  try {
    await Firebase.initializeApp(
      options: DefaultFirebaseOptions.currentPlatform,
    );
    firestore.FirebaseFirestore.instance.settings = const firestore.Settings(
      persistenceEnabled: true,
      cacheSizeBytes: 100 * 1024 * 1024, // 100 MB cap — prevents OOM on low-end devices
    );
    // Enable RTDB disk persistence so messages survive restarts & work offline
    FirebaseDatabase.instance.setPersistenceEnabled(true);
    // Ensure Firebase Auth so RTDB/Firestore rules (auth != null) pass
    if (FirebaseAuth.instance.currentUser == null) {
      try {
        await FirebaseAuth.instance.signInAnonymously();
      } catch (authErr) {
        debugPrint('[Firebase] anonymous auth failed: $authErr — retrying...');
        // Retry once after a short delay
        await Future.delayed(const Duration(milliseconds: 500));
        try {
          await FirebaseAuth.instance.signInAnonymously();
        } catch (retryErr) {
          debugPrint('[Firebase] anonymous auth retry failed: $retryErr');
        }
      }
    }
    // Auto-reauthenticate if anonymous session expires mid-use
    FirebaseAuth.instance.authStateChanges().listen((user) async {
      if (user == null) {
        debugPrint('[Firebase] auth lost — re-signing in anonymously…');
        try {
          await FirebaseAuth.instance.signInAnonymously();
        } catch (e) {
          debugPrint('[Firebase] re-auth failed: $e');
        }
      }
    });
  } catch (e) {
    debugPrint('[Firebase] early init error: $e');
  }
}

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
    // Initialize Mapbox offline tile cache
    MapCacheService().init(),

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
    () async {
      try {
        if (Firebase.apps.isEmpty) {
          await Firebase.initializeApp(
            options: DefaultFirebaseOptions.currentPlatform,
          );
        }
        try {
          await FirebaseCrashlytics.instance.setCrashlyticsCollectionEnabled(kReleaseMode);

          // Register background handler BEFORE any other messaging setup
          FirebaseMessaging.onBackgroundMessage(_firebaseMessagingBackgroundHandler);

          final messaging = FirebaseMessaging.instance;
          await messaging.requestPermission(alert: true, badge: true, sound: true);
          final fcmToken = await messaging.getToken();
          if (kDebugMode) debugPrint('[FCM] token: $fcmToken');

          FirebaseMessaging.onMessage.listen((RemoteMessage message) {
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
            };
            const driverInAppTypes = {
              'trip_offer', 'new_offer',
              'rider_cancelled', 'scheduled_cancelled', 'scheduled_available',
              // Driver verification decision from dispatch.
              'driver_approved', 'driver_rejected',
            };

            // Chat messages: show in-app only for drivers, suppress for riders (badge shows)
            if (type == 'chat_message') {
              final tripId = int.tryParse(message.data['trip_id']?.toString() ?? '');
              // Always suppress if user is in that chat screen
              if (tripId != null && ChatScreen.activeTripId == tripId) {
                debugPrint('[FCM] suppressed chat notification — user is in chat');
                return;
              }
              // For drivers: show the notification overlay in-app
              UserSession.getMode().then((mode) {
                if (mode == 'driver') {
                  NotificationService.show(
                    id: DateTime.now().millisecondsSinceEpoch ~/ 1000,
                    title: title,
                    body: body,
                    type: type,
                  );
                }
                // Always save to notification history
                LocalDataService.addNotification(
                  title: title,
                  message: body,
                  type: type,
                );
              });
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

            NotificationService.show(
              id: DateTime.now().millisecondsSinceEpoch ~/ 1000,
              title: title,
              body: body,
              type: type,
            );
            LocalDataService.addNotification(
              title: title,
              message: body,
              type: type,
            );

            // Play offer sound for trip offers
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
          });
          // Handle notification tap when app is backgrounded
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
        await NotificationService.init();
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
            navigatorObservers: [AnalyticsService.instance.observer],
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
