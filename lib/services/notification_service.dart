import 'dart:async';
import '../utils/app_platform.dart';
import 'package:audioplayers/audioplayers.dart';

import 'audio_session_config.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' show Color;
import 'haptic_service.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:permission_handler/permission_handler.dart';
import 'api_service.dart';
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
///   cruise_online.wav — played when a new offer arrives while the app is open.
///                       Despite the filename this is the OFFER cue; the
///                       go-online chime it was named for was removed for
///                       freezing the platform thread during the transition.
class NotificationService {
  static final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();

  static bool _initialized = false;

  // Notification IDs (stable, so a second show() replaces the first)
  static const int _offerBaseId = 9000;
  static const int _driverOnlineId = 8888;

  // Offers only. There was a second player for the go-online chime; that
  // chime is gone — see the comment where _goOnline used to call it.
  static final AudioPlayer _offerPlayer = AudioPlayer();

  /// FCM token-refresh subscription (see [registerTokenWithBackend]).
  /// Never cancelled: the service is a process-lifetime static.
  static StreamSubscription<String>? _tokenRefreshSub;

  /// Registers the current FCM token with the backend and keeps it updated
  /// on rotation. Safe to call multiple times and before login (fails silently).
  static Future<void> registerTokenWithBackend() async {
    try {
      final messaging = FirebaseMessaging.instance;
      final token = await messaging.getToken();
      if (token == null) {
        debugPrint('[Notifications] getToken() returned null — check APNs setup');
      } else {
        final ok = await ApiService.saveFcmToken(token);
        if (!ok) {
          debugPrint('[Notifications] token not registered (likely no session '
              'yet) — will retry on the next rotation or screen entry');
        }
      }
      _tokenRefreshSub ??= messaging.onTokenRefresh.listen((t) {
        unawaited(ApiService.saveFcmToken(t));
      });
    } catch (e) {
      debugPrint('[Notifications] token registration failed: $e');
    }
  }

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
        // Before the pre-warm below activates the session — that silent
        // play at launch is what used to stop the user's music.
        await ensureNonInterruptingAudio();
        await _offerPlayer.setReleaseMode(ReleaseMode.stop);
        await _offerPlayer.setSource(AssetSource('sounds/cruise_online.wav'));
        // Explicitly release player state when the clip ends so the
        // MediaPlayer / AVAudioPlayer instance does not keep the audio
        // session held.
        _offerPlayer.onPlayerComplete.listen((_) {
          // `unawaited` marks a future as intentionally not awaited. It
          // does not handle its errors.
          _quietly(_offerPlayer.stop(), 'stop');
        });
        // Pre-warm the iOS audio session: play silently so the first real
        // offer sound is instant. This used to run on the go-online player;
        // that one is gone, so it moved here rather than being dropped —
        // offers are the sound that actually has to be heard.
        await _offerPlayer.setVolume(0.0);
        await _offerPlayer.resume();
        await Future.delayed(const Duration(milliseconds: 100));
        await _offerPlayer.pause();
        await _offerPlayer.setVolume(1.0);
        await _offerPlayer.seek(Duration.zero);
      } catch (e) {
        debugPrint('[NotificationService] audio preload error: $e');
      }
    });
    debugPrint('[NotificationService] initialized');
  }

  /// Web-only partial init. flutter_local_notifications has no web
  /// implementation, so [init] must not run there — but the offer sound
  /// uses audioplayers, which does work on web. This configures only the
  /// offer AudioPlayer so incoming offers are not silent in the browser.
  /// (No silent pre-warm: browsers block audio before the first user
  /// gesture; the first [playOfferSound] after any tap will succeed.)
  static Future<void> initWebAudio() async {
    if (_initialized) return;
    _initialized = true;
    try {
      await _offerPlayer.setReleaseMode(ReleaseMode.stop);
      await _offerPlayer.setSource(AssetSource('sounds/cruise_online.wav'));
      _offerPlayer.onPlayerComplete.listen((_) {
        _quietly(_offerPlayer.stop(), 'stop');
      });
    } catch (e) {
      debugPrint('[NotificationService] web audio init error: $e');
    }
    debugPrint('[NotificationService] web audio initialized');
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

    // Master gate — when notifications are disabled app-wide, nothing shows.
    if (!(prefs.getBool('notif_master') ?? true)) return;

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

    if (vibrateEnabled) HapticService.mediumImpact();
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

    if (vibrateEnabled) HapticService.heavyImpact();
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
  ///
  /// On iOS this is a NO-OP because:
  /// 1. iOS does not require a foreground-service notification
  /// 2. The notification would show in the iOS notification center
  ///    and annoy the driver while they are actively using the app.
  static Future<void> showDriverOnlineNotification() async {
    if (!_initialized) await init();

    // iOS: skip entirely — no foreground-service requirement and the
    // notification would appear in the system tray while the driver
    // is actively looking at the online screen.
    if (AppPlatform.isIOS) {
      debugPrint('[NotificationService] driver online notification skipped on iOS');
      return;
    }

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

    await _plugin.show(
      id: _driverOnlineId,
      title: 'Cruise — You\'re Online',
      body: 'You are online and receiving trip offers.',
      notificationDetails: const NotificationDetails(android: androidDetails),
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

  static bool _offerSoundPlaying = false;

  /// Reset sound guards when app resumes from background.
  /// Prevents stuck flags from blocking sounds on next offer.
  static void resetSoundGuards() {
    _offerSoundPlaying = false;
  }

  /// Play the trip offer sound inside the app (when app is in foreground).
  /// Plays 3 times with 2-second intervals to grab driver's attention.
  /// Let a deliberately-unawaited platform call fail without taking the
  /// app with it. Nothing here is worth a crash — it is a notification
  /// sound.
  static void _quietly(Future<void> f, String what) {
    f.catchError((Object e) {
      debugPrint('[NotificationService] $what failed: $e');
    });
  }

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
        // Dip the driver's music/video ONLY while the cue sounds — the
        // resting session mixes at full volume (user spec 2026-08-04).
        _quietly(duckForOfferCue(), 'duck');
        // Fire-and-forget seek+resume — never await platform channel calls
        // to avoid blocking the UI thread / causing 1-second freezes.
        //
        // Fire-and-forget is not the same as error-free. These two were
        // bare, and the `catch` below never saw them: an unawaited future
        // reports to the zone, not to the enclosing try. When the audio
        // session wedges, seek() never gets its reply and throws
        // "TimeoutException after 0:00:30 — Future not completed" half a
        // minute later, with no context left. Crashlytics has 15 of them,
        // new in 1.0.9.
        for (int i = 0; i < 3; i++) {
          _quietly(_offerPlayer.seek(Duration.zero), 'seek');
          _quietly(_offerPlayer.resume(), 'resume');
          if (i < 2) await Future.delayed(const Duration(seconds: 2));
        }
        // Reset guard + lift the duck after the last repeat finishes (~2s)
        Future.delayed(const Duration(seconds: 2), () {
          _offerSoundPlaying = false;
          _quietly(restoreAfterOfferCue(), 'unduck');
        });
      } catch (e) {
        _offerSoundPlaying = false;
        _quietly(restoreAfterOfferCue(), 'unduck');
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
