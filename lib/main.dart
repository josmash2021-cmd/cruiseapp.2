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
import 'screens/splash_screen.dart';
import 'services/api_service.dart';
import 'services/notification_service.dart';
import 'services/security_service.dart';
import 'services/user_session.dart';
import 'services/local_data_service.dart';

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
      // ── Initialize Security Service (10-layer defense) ──
      await SecurityService.init();
      // ── Load persisted server URL (must run before any ApiService call) ──
      await ApiService.init();
      // Auto-detect best reachable server — non-blocking with 8s overall timeout
      // so the app doesn't freeze for 42s if all URLs are unreachable.
      await ApiService.probeAndSetBestUrl(
        timeout: const Duration(seconds: 3),
      ).timeout(
        const Duration(seconds: 8),
        onTimeout: () {
          debugPrint('[ApiService] probe timed out — using saved/default URL');
          return null;
        },
      );
      // Initialize profile photo notifier for real-time sync
      await UserSession.initPhotoNotifier();

      // ── Stripe — skip if key is still a placeholder ──
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

      try {
        await Firebase.initializeApp(
          options: DefaultFirebaseOptions.currentPlatform,
        );

        // ── Firebase Cloud Messaging ──
        try {
          final messaging = FirebaseMessaging.instance;
          await messaging.requestPermission(
            alert: true,
            badge: true,
            sound: true,
          );
          final fcmToken = await messaging.getToken();
          debugPrint('[FCM] token: $fcmToken');

          // Handle foreground messages
          FirebaseMessaging.onMessage.listen((RemoteMessage message) {
            final title = message.notification?.title ?? 'Cruise';
            final body = message.notification?.body ?? '';
            NotificationService.show(
              id: DateTime.now().millisecondsSinceEpoch ~/ 1000,
              title: title,
              body: body,
            );
            // Also save to local inbox
            LocalDataService.addNotification(
              title: title,
              message: body,
              type: 'push',
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

class UberCloneApp extends StatelessWidget {
  const UberCloneApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      themeMode: ThemeMode.system,
      theme: lightTheme,
      darkTheme: darkTheme,
      scrollBehavior: const SmoothScrollBehavior(),
      home: const SplashScreen(),
    );
  }
}
