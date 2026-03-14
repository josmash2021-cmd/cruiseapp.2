import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'dart:async';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_stripe/flutter_stripe.dart';
import 'firebase_options.dart';
import 'config/api_keys.dart';
import 'config/app_theme.dart';
import 'config/theme_notifier.dart';
import 'screens/splash_screen.dart';
import 'services/api_service.dart';
import 'services/notification_service.dart';
import 'services/security_service.dart';
import 'services/user_session.dart';
import 'services/local_data_service.dart';
import 'services/keep_alive_service.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'l10n/app_localizations.dart';

/// Global theme notifier so any screen can toggle night mode.
final themeNotifier = ThemeNotifier();

void main() async {
  // Catch all unhandled async Dart errors
  await runZonedGuarded(
    () async {
      WidgetsFlutterBinding.ensureInitialized();

      // Catch any Flutter framework errors and log them instead of crashing
      FlutterError.onError = (FlutterErrorDetails details) {
        FlutterError.presentError(details);
        debugPrint('[FlutterError] ${details.exception}\n${details.stack}');
      };

      // Only minimal sync work before runApp — everything else moves to
      // SplashScreen so the first frame paints instantly (no white flash).
      await SecurityService.init();
      await ApiService.init();

      SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
      SystemChrome.setSystemUIOverlayStyle(
        const SystemUiOverlayStyle(statusBarColor: Colors.transparent),
      );
      runApp(const UberCloneApp());
    },
    (error, stack) {
      debugPrint('[ZoneError] $error\n$stack');
    },
  );
}

/// Heavy async init that runs while the splash animation plays.
/// Called from SplashScreen.initState().
Future<void> heavyInit() async {
  // Auto-detect best reachable server
  await ApiService.probeAndSetBestUrl(
    timeout: const Duration(seconds: 3),
  ).timeout(
    const Duration(seconds: 8),
    onTimeout: () {
      debugPrint('[ApiService] probe timed out — using saved/default URL');
      return null;
    },
  );

  // Start keep-alive pings to prevent server sleep
  KeepAliveService.instance.start();

  // Initialize profile photo notifier
  await UserSession.initPhotoNotifier();

  // ── Stripe ──
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

  // ── Firebase ──
  try {
    await Firebase.initializeApp(
      options: DefaultFirebaseOptions.currentPlatform,
    );
    try {
      final messaging = FirebaseMessaging.instance;
      await messaging.requestPermission(alert: true, badge: true, sound: true);
      final fcmToken = await messaging.getToken();
      debugPrint('[FCM] token: $fcmToken');

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

  // ── Local Notifications ──
  try {
    await NotificationService.init();
  } catch (e) {
    debugPrint('[NotificationService] init error: $e');
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
            debugShowCheckedModeBanner: false,
            themeMode: themeNotifier.mode,
            theme: lightTheme,
            darkTheme: darkTheme,
            scrollBehavior: const SmoothScrollBehavior(),
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
          ),
        );
      },
    );
  }
}
