import 'dart:async';
import 'dart:developer';
import '../utils/app_platform.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

/// Initializes the background service for keeping the driver online
/// when the app is backgrounded on Android.
///
/// On iOS, background fetch and location updates are handled natively
/// via UIBackgroundModes in Info.plist, so this service is a no-op.
class DriverBackgroundService {
  static final DriverBackgroundService _instance = DriverBackgroundService._internal();
  factory DriverBackgroundService() => _instance;
  DriverBackgroundService._internal();

  bool _initialized = false;

  /// Initialize the background service. Call once at app startup.
  Future<void> initialize() async {
    if (_initialized) return;
    if (!AppPlatform.isAndroid) {
      _initialized = true;
      return; // iOS uses native background modes
    }

    final service = FlutterBackgroundService();

    // flutter_background_service does NOT create a custom notification
    // channel itself — when `notificationChannelId` is set it only uses it.
    // Starting the foreground service with a channel that does not exist is
    // exactly what throws `RemoteServiceException: Bad notification for
    // startForeground` on Android 8+, so the channel must exist before
    // configure()/startService() runs.
    final androidNotifications = FlutterLocalNotificationsPlugin()
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>();
    await androidNotifications?.createNotificationChannel(
      const AndroidNotificationChannel(
        'cruise_driver_bg',
        'Driver Background Service',
        description: 'Keeps you online while the app is in the background',
        importance: Importance.low,
        playSound: false,
        enableVibration: false,
        showBadge: false,
      ),
    );

    await service.configure(
      androidConfiguration: AndroidConfiguration(
        onStart: _onStart,
        autoStart: false,
        isForegroundMode: true,
        notificationChannelId: 'cruise_driver_bg',
        initialNotificationTitle: 'CruiseInRide',
        initialNotificationContent: 'Finding trips nearby...',
        foregroundServiceNotificationId: 888,
      ),
      iosConfiguration: IosConfiguration(
        autoStart: false,
        onForeground: _onStart,
        onBackground: _onIosBackground,
      ),
    );

    _initialized = true;
    log('[DriverBackgroundService] Initialized');
  }

  /// Start the foreground service (shows persistent notification).
  Future<void> start() async {
    if (!_initialized) await initialize();
    if (!AppPlatform.isAndroid) return;

    final service = FlutterBackgroundService();
    final isRunning = await service.isRunning();
    if (!isRunning) {
      await service.startService();
      log('[DriverBackgroundService] Foreground service started');
    }
  }

  /// Stop the foreground service.
  Future<void> stop() async {
    if (!_initialized) return;
    if (!AppPlatform.isAndroid) return;

    final service = FlutterBackgroundService();
    final isRunning = await service.isRunning();
    if (isRunning) {
      service.invoke('stopService');
      log('[DriverBackgroundService] Foreground service stopped');
    }
  }

  /// Update the notification text (e.g., when trip state changes).
  void updateNotification({required String title, required String body}) {
    if (!_initialized || !AppPlatform.isAndroid) return;
    final service = FlutterBackgroundService();
    service.invoke('updateNotification', {
      'title': title,
      'body': body,
    });
  }
}

/// Entry point for the background isolate.
/// Must be a top-level or static function.
@pragma('vm:entry-point')
void _onStart(ServiceInstance service) async {
  // Keep the service alive
  if (service is AndroidServiceInstance) {
    service.on('stopService').listen((event) {
      service.stopSelf();
    });

    service.on('updateNotification').listen((event) {
      final title = event?['title'] as String? ?? 'CruiseInRide';
      final body = event?['body'] as String? ?? 'Finding trips nearby...';
      service.setForegroundNotificationInfo(
        title: title,
        content: body,
      );
    });

    // Set as foreground so Android doesn't kill us
    service.setAsForegroundService();
  }

  // The actual heartbeat logic is handled by the main app's
  // _startBackgroundHeartbeat() Timer. This service just keeps
  // the process alive so that Timer continues to fire.
  // We also listen for a keep-alive ping from the main isolate.
  service.on('heartbeat').listen((event) {
    // Main app is alive — nothing to do
  });
}

/// iOS background fetch handler.
@pragma('vm:entry-point')
Future<bool> _onIosBackground(ServiceInstance service) async {
  // iOS background fetch is handled by the system calling this.
  // We don't need to do anything special here — the existing
  // _startBackgroundHeartbeat() Timer in the main isolate handles
  // location pings when the app is backgrounded.
  return true;
}
