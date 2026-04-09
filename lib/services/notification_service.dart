import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'prefs_cache.dart';
import 'package:timezone/data/latest_all.dart' as tz;
import 'package:timezone/timezone.dart' as tz;

/// Handles local push notifications and in-app sounds.
///
/// Channels:
///   cruise_premium   — general notifications (cruise_notification.wav)
///   cruise_offers    — trip offer notifications (cruise_offer.wav, max priority)
///   cruise_status    — driver online persistent/ongoing notification (silent)
///   cruise_reminders — scheduled ride reminders
///
/// In-app sounds (audioplayers):
///   cruise_online.wav — played when driver goes online
///   cruise_offer.wav  — played when a new offer arrives while app is open
class NotificationService {
  static final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();

  static bool _initialized = false;

  // Notification IDs (stable, so a second show() replaces the first)
  static const int _offerBaseId = 9000;
  static const int _driverOnlineId = 8888;

  // AudioPlayer instances — one per sound so they can overlap if needed
  static final AudioPlayer _onlinePlayer = AudioPlayer();
  static final AudioPlayer _offerPlayer = AudioPlayer();

  /// Initialize the notification plugin. Call once at app startup.
  static Future<void> init() async {
    if (_initialized) return;

    tz.initializeTimeZones();
    tz.setLocalLocation(tz.getLocation(_guessTimezone()));

    const androidSettings = AndroidInitializationSettings(
      '@mipmap/ic_launcher',
    );
    const iosSettings = DarwinInitializationSettings(
      requestAlertPermission: true,
      requestBadgePermission: true,
      requestSoundPermission: true,
    );

    const settings = InitializationSettings(
      android: androidSettings,
      iOS: iosSettings,
    );

    await _plugin.initialize(
      settings: settings,
      onDidReceiveNotificationResponse: _onNotificationTapped,
    );

    // Create all Android notification channels up-front so the OS
    // registers their sounds before the first notification fires.
    await _createChannels();

    _initialized = true;

    // Pre-load audio players AND pre-warm iOS audio session in background
    Future<void>(() async {
      try {
        await _onlinePlayer.setReleaseMode(ReleaseMode.stop);
        await _onlinePlayer.setSource(AssetSource('sounds/cruise_online.wav'));
        await _offerPlayer.setReleaseMode(ReleaseMode.stop);
        await _offerPlayer.setSource(AssetSource('sounds/cruise_online.wav'));
        // Pre-warm iOS audio session: play silently so first real play is instant
        await _onlinePlayer.setVolume(0.0);
        await _onlinePlayer.resume();
        await Future.delayed(const Duration(milliseconds: 100));
        await _onlinePlayer.pause();
        await _onlinePlayer.setVolume(1.0);
        await _onlinePlayer.seek(Duration.zero);
      } catch (e) {
        debugPrint('[NotificationService] audio preload error: $e');
      }
    });
    debugPrint('[NotificationService] initialized');
  }

  static Future<void> _createChannels() async {
    final android = _plugin
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>();
    if (android == null) return;

    // General notifications — cruise_online sound + vibration
    await android.createNotificationChannel(AndroidNotificationChannel(
      'cruise_premium',
      'Cruise Notifications',
      description: 'General notifications from Cruise',
      importance: Importance.high,
      sound: const RawResourceAndroidNotificationSound('cruise_online'),
      enableVibration: true,
      vibrationPattern: Int64List.fromList([0, 150, 100, 150, 100, 150]),
    ));

    // Trip offer notifications — max importance, same sound
    await android.createNotificationChannel(AndroidNotificationChannel(
      'cruise_offers',
      'Trip Offers',
      description: 'New trip offer alerts for drivers',
      importance: Importance.max,
      sound: const RawResourceAndroidNotificationSound('cruise_online'),
      enableVibration: true,
      vibrationPattern: Int64List.fromList([0, 150, 100, 150, 100, 150]),
      playSound: true,
      showBadge: true,
    ));

    // Driver online status — silent persistent notification
    await android.createNotificationChannel(const AndroidNotificationChannel(
      'cruise_status',
      'Driver Status',
      description: 'Keeps Cruise active while you are online',
      importance: Importance.low,
      playSound: false,
      enableVibration: false,
      showBadge: false,
    ));

    // Ride reminders — same sound + vibration
    await android.createNotificationChannel(AndroidNotificationChannel(
      'cruise_reminders',
      'Ride Reminders',
      description: 'Scheduled ride reminders',
      importance: Importance.high,
      sound: const RawResourceAndroidNotificationSound('cruise_online'),
      enableVibration: true,
      vibrationPattern: Int64List.fromList([0, 150, 100, 150, 100, 150]),
    ));
  }

  static String _guessTimezone() {
    try {
      final offset = DateTime.now().timeZoneOffset;
      if (offset.inHours == -6) return 'America/Chicago';
      if (offset.inHours == -5) return 'America/New_York';
      if (offset.inHours == -7) return 'America/Denver';
      if (offset.inHours == -8) return 'America/Los_Angeles';
    } catch (_) {}
    return 'America/Chicago';
  }

  static void _onNotificationTapped(NotificationResponse response) {
    debugPrint('[Notification] tapped: ${response.payload}');
  }

  // ── Permission management ──────────────────────────────────────────────

  static Future<bool> isPermissionGranted() async {
    final status = await Permission.notification.status;
    return status.isGranted;
  }

  static Future<bool> requestPermission() async {
    final status = await Permission.notification.request();
    return status.isGranted;
  }

  static Future<void> openSystemSettings() async {
    await openAppSettings();
  }

  // ── General notification ───────────────────────────────────────────────

  /// Show a general notification immediately.
  static Future<void> show({
    required int id,
    required String title,
    required String body,
    String? payload,
    String type = 'general',
  }) async {
    if (!_initialized) await init();

    final prefs = PrefsCache.instanceSync ?? await PrefsCache.instance;

    if (type == 'ride' && !(prefs.getBool('notif_ride') ?? true)) return;
    if (type == 'promo' && !(prefs.getBool('notif_promo') ?? true)) return;
    if (type == 'safety' && !(prefs.getBool('notif_safety') ?? true)) return;
    if (type == 'payment' && !(prefs.getBool('notif_payment') ?? true)) return;
    if (type == 'ride' && !(prefs.getBool('sound_trips') ?? true)) return;
    if ((type == 'chat' || type == 'chat_message') &&
        !(prefs.getBool('sound_messages') ?? true)) { return; }

    final driverVolume = prefs.getDouble('sound_volume') ?? 0.8;
    final soundsEnabled =
        (prefs.getBool('notif_sounds') ?? true) && driverVolume > 0;
    final vibrateEnabled = prefs.getBool('notif_vibrate') ?? true;

    final androidDetails = AndroidNotificationDetails(
      'cruise_premium',
      'Cruise Notifications',
      channelDescription: 'General notifications from Cruise',
      importance: Importance.high,
      priority: Priority.high,
      playSound: soundsEnabled,
      sound: soundsEnabled
          ? const RawResourceAndroidNotificationSound('cruise_online')
          : null,
      enableVibration: vibrateEnabled,
      vibrationPattern: vibrateEnabled
          ? Int64List.fromList([0, 150, 100, 150, 100, 150])
          : null,
      icon: '@mipmap/ic_launcher',
      color: const Color(0xFFE8C547),
    );

    final iosDetails = DarwinNotificationDetails(
      presentAlert: true,
      presentBadge: true,
      presentSound: soundsEnabled,
      sound: soundsEnabled ? 'cruise_online.wav' : null,
    );

    await _plugin.show(
      id: id,
      title: title,
      body: body,
      notificationDetails: NotificationDetails(
        android: androidDetails,
        iOS: iosDetails,
      ),
      payload: payload,
    );

    if (vibrateEnabled) HapticFeedback.mediumImpact();
  }

  // ── Trip offer notification (driver) ─────────────────────────────────

  /// Show a high-priority trip offer notification.
  /// Plays cruise_offer.wav + strong vibration.
  /// Works even when driver is in another app.
  ///
  /// [offerId] — used as the notification ID so duplicate offers replace each other.
  static Future<void> showOfferNotification({
    required String title,
    required String body,
    int offerId = 0,
    String? payload,
    bool appInForeground = true,
  }) async {
    if (!_initialized) await init();

    final prefs = PrefsCache.instanceSync ?? await PrefsCache.instance;
    final soundsEnabled = prefs.getBool('sound_trips') ?? true;
    final vibrateEnabled = prefs.getBool('notif_vibrate') ?? true;

    // When app is in foreground: playOfferSound() handles audio (richer, 3x repeat)
    // When app is in background: notification channel plays the sound
    final notifSound = !appInForeground && soundsEnabled;

    final androidDetails = AndroidNotificationDetails(
      'cruise_offers',
      'Trip Offers',
      channelDescription: 'New trip offer alerts for drivers',
      importance: Importance.max,
      priority: Priority.max,
      playSound: notifSound,
      sound: notifSound
          ? const RawResourceAndroidNotificationSound('cruise_online')
          : null,
      enableVibration: vibrateEnabled,
      vibrationPattern: vibrateEnabled
          ? Int64List.fromList([0, 150, 100, 150, 100, 150])
          : null,
      icon: '@mipmap/ic_launcher',
      color: const Color(0xFFE8C547),
      fullScreenIntent: true,
      category: AndroidNotificationCategory.call,
      styleInformation: const DefaultStyleInformation(true, true),
    );

    final iosDetails = DarwinNotificationDetails(
      presentAlert: true,
      presentBadge: true,
      presentSound: notifSound,
      sound: notifSound ? 'cruise_online.wav' : null,
      interruptionLevel: InterruptionLevel.timeSensitive,
    );

    await _plugin.show(
      id: _offerBaseId + (offerId % 10),
      title: title,
      body: body,
      notificationDetails: NotificationDetails(
        android: androidDetails,
        iOS: iosDetails,
      ),
      payload: payload ?? 'trip_offer',
    );

    if (vibrateEnabled) HapticFeedback.heavyImpact();
    debugPrint('[NotificationService] offer notification shown: $title');
  }

  /// Cancel all pending offer notifications.
  static Future<void> cancelOfferNotifications() async {
    for (int i = 0; i < 10; i++) {
      await _plugin.cancel(id: _offerBaseId + i);
    }
  }

  // ── Driver online persistent notification ────────────────────────────

  /// Show a silent ongoing notification when driver goes online.
  /// This acts as a foreground-service anchor on Android, keeping the
  /// app process alive so GPS and SSE keep working in the background.
  static Future<void> showDriverOnlineNotification() async {
    if (!_initialized) await init();

    const androidDetails = AndroidNotificationDetails(
      'cruise_status',
      'Driver Status',
      channelDescription: 'Keeps Cruise active while you are online',
      importance: Importance.low,
      priority: Priority.low,
      ongoing: true,          // Cannot be dismissed by swipe
      autoCancel: false,
      playSound: false,
      enableVibration: false,
      icon: '@mipmap/ic_launcher',
      color: Color(0xFFE8C547),
      showProgress: false,
      styleInformation: BigTextStyleInformation(
        'You are online and receiving trip offers.',
        contentTitle: 'Cruise — You\'re Online',
        summaryText: 'Tap to open',
      ),
    );

    const iosDetails = DarwinNotificationDetails(
      presentAlert: false,
      presentBadge: false,
      presentSound: false,
    );

    await _plugin.show(
      id: _driverOnlineId,
      title: 'Cruise — You\'re Online',
      body: 'You are online and receiving trip offers.',
      notificationDetails: const NotificationDetails(
        android: androidDetails,
        iOS: iosDetails,
      ),
      payload: 'driver_online',
    );

    debugPrint('[NotificationService] driver online notification shown');
  }

  /// Remove the driver online persistent notification.
  static Future<void> cancelDriverOnlineNotification() async {
    await _plugin.cancel(id: _driverOnlineId);
    debugPrint('[NotificationService] driver online notification cancelled');
  }

  // ── In-app sounds (audioplayers) ──────────────────────────────────────

  /// Play the "go online" chime inside the app.
  /// Fire-and-forget — never blocks the UI thread.
  /// Uses seek+resume on the pre-loaded source to avoid re-decoding.
  static bool _onlineSoundPlaying = false;
  static bool _offerSoundPlaying = false;

  /// Reset sound guards when app resumes from background.
  /// Prevents stuck flags from blocking sounds on next offer.
  static void resetSoundGuards() {
    _onlineSoundPlaying = false;
    _offerSoundPlaying = false;
  }

  static void playOnlineSound() {
    if (_onlineSoundPlaying) return; // prevent double-play
    _onlineSoundPlaying = true;
    Future.microtask(() async {
      try {
        final prefs = PrefsCache.instanceSync ?? await PrefsCache.instance;
        if (!(prefs.getBool('notif_sounds') ?? true)) {
          _onlineSoundPlaying = false;
          return;
        }
        // Fire-and-forget — don't await platform channel calls
        // to avoid blocking the UI thread during screen transitions.
        _onlinePlayer.seek(Duration.zero);
        _onlinePlayer.resume();
        // Reset guard after sound finishes (~2s)
        Future.delayed(const Duration(seconds: 2), () => _onlineSoundPlaying = false);
      } catch (e) {
        _onlineSoundPlaying = false;
        debugPrint('[NotificationService] playOnlineSound error: $e');
      }
    });
  }

  /// Play the trip offer sound inside the app (when app is in foreground).
  /// Plays 3 times with 2-second intervals to grab driver's attention.
  static void playOfferSound() {
    if (_offerSoundPlaying) return; // prevent double-play
    _offerSoundPlaying = true;
    Future.microtask(() async {
      try {
        final prefs = PrefsCache.instanceSync ?? await PrefsCache.instance;
        if (!(prefs.getBool('sound_trips') ?? true)) {
          _offerSoundPlaying = false;
          return;
        }
        for (int i = 0; i < 3; i++) {
          await _offerPlayer.seek(Duration.zero);
          await _offerPlayer.resume();
          if (i < 2) await Future.delayed(const Duration(seconds: 2));
        }
        _offerSoundPlaying = false;
      } catch (e) {
        _offerSoundPlaying = false;
        debugPrint('[NotificationService] playOfferSound error: $e');
      }
    });
  }

  // ── Schedule notification ─────────────────────────────────────────────

  static Future<void> scheduleAt({
    required int id,
    required String title,
    required String body,
    required DateTime scheduledTime,
    String? payload,
  }) async {
    if (!_initialized) await init();
    if (scheduledTime.isBefore(DateTime.now())) return;

    final prefs = PrefsCache.instanceSync ?? await PrefsCache.instance;
    final soundsEnabled = prefs.getBool('notif_sounds') ?? true;
    final vibrateEnabled = prefs.getBool('notif_vibrate') ?? true;

    final androidDetails = AndroidNotificationDetails(
      'cruise_reminders',
      'Ride Reminders',
      channelDescription: 'Scheduled ride reminders',
      importance: Importance.high,
      priority: Priority.high,
      playSound: soundsEnabled,
      sound: soundsEnabled
          ? const RawResourceAndroidNotificationSound('cruise_online')
          : null,
      enableVibration: vibrateEnabled,
      vibrationPattern: vibrateEnabled
          ? Int64List.fromList([0, 150, 100, 150, 100, 150])
          : null,
      icon: '@mipmap/ic_launcher',
      color: const Color(0xFFE8C547),
    );

    final iosDetails = DarwinNotificationDetails(
      presentAlert: true,
      presentBadge: true,
      presentSound: soundsEnabled,
      sound: soundsEnabled ? 'cruise_online.wav' : null,
    );

    await _plugin.zonedSchedule(
      id: id,
      scheduledDate: tz.TZDateTime.from(scheduledTime, tz.local),
      notificationDetails: NotificationDetails(
        android: androidDetails,
        iOS: iosDetails,
      ),
      androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
      title: title,
      body: body,
      payload: payload,
    );

    debugPrint('[NotificationService] scheduled #$id at $scheduledTime: $title');
  }

  static Future<void> cancel(int id) async {
    await _plugin.cancel(id: id);
  }

  static Future<void> cancelAll() async {
    await _plugin.cancelAll();
  }

  // ── Ride reminder helpers ─────────────────────────────────────────────

  static Future<void> scheduleRideReminder({
    required int tripId,
    required DateTime rideTime,
    required String pickup,
    required String dropoff,
  }) async {
    final reminderTime = rideTime.subtract(const Duration(hours: 1));
    if (reminderTime.isBefore(DateTime.now())) return;
    await scheduleAt(
      id: tripId,
      title: 'Your ride is in 1 hour',
      body: 'From $pickup to $dropoff',
      scheduledTime: reminderTime,
      payload: 'ride_reminder:$tripId',
    );
  }

  static Future<void> cancelRideReminder(int tripId) async {
    await cancel(tripId);
  }
}
