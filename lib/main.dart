import 'package:flutter/material.dart';
import 'package:mapbox_maps_flutter/mapbox_maps_flutter.dart';
import 'config/mapbox_config.dart';
import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart' show kDebugMode, kIsWeb, kReleaseMode;
import 'dart:async';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_crashlytics/firebase_crashlytics.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:cloud_firestore/cloud_firestore.dart' as firestore;
import 'package:flutter_stripe/flutter_stripe.dart';
import 'config/smooth_transitions.dart';
import 'config/page_transitions.dart';
import 'config/api_keys.dart';
import 'config/app_theme.dart';
import 'config/theme_notifier.dart';
import 'screens/splash_screen.dart';
import 'services/api_service.dart';
import 'services/notification_service.dart';
import 'services/security_service.dart';
import 'services/user_session.dart';
import 'services/local_data_service.dart';
import 'services/local_cache.dart';
import 'services/map_cache_service.dart';
import 'services/network_service.dart';
import 'services/keep_alive_service.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'firebase_options.dart';
import 'l10n/app_localizations.dart';

/// Global theme notifier so any screen can toggle night mode.
final themeNotifier = ThemeNotifier();

/// M2: Global navigator key for imperative navigation (auto-logout on 401).
final _navigatorKey = GlobalKey<NavigatorState>();

void main() async {
  // Catch all unhandled async Dart errors
  await runZonedGuarded(
    () async {
      WidgetsFlutterBinding.ensureInitialized();

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

      // Only minimal sync work before runApp — everything else moves to
      // SplashScreen so the first frame paints instantly (no white flash).
      await SecurityService.init();
      // Firebase MUST be initialized before ApiService.init() so the
      // Firestore dynamic tunnel URL read works on any network.
      try {
        await Firebase.initializeApp(
          options: DefaultFirebaseOptions.currentPlatform,
        );
        // Firestore persistence: unlimited cache for instant offline reads
        firestore.FirebaseFirestore.instance.settings = const firestore.Settings(
          persistenceEnabled: true,
          cacheSizeBytes: firestore.Settings.CACHE_SIZE_UNLIMITED,
        );
      } catch (e) {
        debugPrint('[Firebase] early init error: $e');
      }
      await ApiService.init();

      // Init local Hive cache (fast, sync reads after this)
      await LocalCache.init();

      // Limit in-memory image cache to prevent OOM on long sessions
      PaintingBinding.instance.imageCache.maximumSizeBytes = 200 * 1024 * 1024; // 200 MB
      PaintingBinding.instance.imageCache.maximumSize = 1000;

      MapboxOptions.setAccessToken(MapboxConfig.accessToken);
      SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
      SystemChrome.setSystemUIOverlayStyle(
        const SystemUiOverlayStyle(statusBarColor: Colors.transparent),
      );
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

/// Heavy async init that runs while the splash animation plays.
/// Called from SplashScreen.initState().
Future<void> heavyInit() async {
  // Probe + warm up the server BEFORE the user reaches the login screen.
  // 10 s total covers cellular DNS/TLS overhead AND Railway cold-starts.
  await ApiService.probeAndSetBestUrl(
    timeout: const Duration(seconds: 8),
  ).timeout(
    const Duration(seconds: 10),
    onTimeout: () {
      debugPrint('[heavyInit] probe timed out — using production URL');
      return null;
    },
  );

  // Start keep-alive pings to prevent server sleep
  KeepAliveService.instance.start();

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
      if (!kIsWeb && !ApiKeys.stripePublishableKey.contains('REPLACE')) {
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

          final messaging = FirebaseMessaging.instance;
          await messaging.requestPermission(alert: true, badge: true, sound: true);
          final fcmToken = await messaging.getToken();
          if (kDebugMode) debugPrint('[FCM] token: $fcmToken');

          FirebaseMessaging.onMessage.listen((RemoteMessage message) {
            final title = message.notification?.title ?? 'Cruise';
            final body = message.notification?.body ?? '';
            final type = message.data['type'] as String? ?? 'general';
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
      ApiService.goOffline();
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
      animation: themeNotifier,
      builder: (context, _) {
        return AnimatedTheme(
          data: themeNotifier.isNightMode ? darkTheme : lightTheme,
          duration: const Duration(milliseconds: 400),
          curve: Curves.easeInOut,
          child: MaterialApp(
            navigatorKey: _navigatorKey,
            debugShowCheckedModeBanner: false,
            themeMode: themeNotifier.mode,
            theme: lightTheme,
            darkTheme: darkTheme,
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
            home: const SplashScreen(),
            builder: (context, child) {
              // Apply smooth scroll behavior globally
              return ScrollConfiguration(
                behavior: const SmoothScrollBehavior(),
                child: child!,
              );
            },
          ),
        );
      },
    );
  }
}

/// Route generator for smooth transitions
Widget _getPageForRoute(RouteSettings settings) {
  // Add your route cases here
  switch (settings.name) {
    default:
      return const SplashScreen();
  }
}
