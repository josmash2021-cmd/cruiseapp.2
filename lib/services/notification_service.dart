import 'dart:ui' show Color;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timezone/data/latest_all.dart' as tz;
import 'package:timezone/timezone.dart' as tz;

/// Handles local push notifications (scheduled ride reminders, etc.)
/// and syncs with phone notification permissions.
class NotificationService {
  static final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();

  static bool _initialized = false;

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

    _initialized = true;
    debugPrint('[NotificationService] initialized');
  }

  static String _guessTimezone() {
    try {
      final offset = DateTime.now().timeZoneOffset;
      // Map common US offsets
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

  // ── Permission management ──

  /// Check if notification permission is granted on the phone.
  static Future<bool> isPermissionGranted() async {
    final status = await Permission.notification.status;
    return status.isGranted;
  }

  /// Request notification permission from the OS.
  /// Returns true if granted.
  static Future<bool> requestPermission() async {
    final status = await Permission.notification.request();
    return status.isGranted;
  }

  /// Open the phone's app notification settings so the user can toggle.
  static Future<void> openSystemSettings() async {
    await openAppSettings();
  }

  // ── Show immediate notification ──

  /// Show a notification immediately.
  /// [type] can be 'ride', 'promo', 'safety', 'payment', or 'general'.
  /// If the user has disabled that notification type, it won't show.
  static Future<void> show({
    required int id,
    required String title,
    required String body,
    String? payload,
    String type = 'general',
  }) async {
    if (!_initialized) await init();

    final prefs = await SharedPreferences.getInstance();

    // Check if this notification type is enabled
    if (type == 'ride' && !(prefs.getBool('notif_ride') ?? true)) return;
    if (type == 'promo' && !(prefs.getBool('notif_promo') ?? true)) return;
    if (type == 'safety' && !(prefs.getBool('notif_safety') ?? true)) return;
    if (type == 'payment' && !(prefs.getBool('notif_payment') ?? true)) return;

    // Driver sound preferences (from Sounds & Voice settings)
    if (type == 'ride' && !(prefs.getBool('sound_trips') ?? true)) return;
    if (type == 'chat' && !(prefs.getBool('sound_messages') ?? true)) return;

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
          ? const RawResourceAndroidNotificationSound('cruise_notification')
          : null,
      enableVibration: vibrateEnabled,
      vibrationPattern: vibrateEnabled
          ? Int64List.fromList([0, 120, 80, 120])
          : null,
      icon: '@mipmap/ic_launcher',
      color: const Color(0xFFE8C547),
    );

    const iosDetails = DarwinNotificationDetails(
      presentAlert: true,
      presentBadge: true,
      presentSound: true,
    );

    final details = NotificationDetails(
      android: androidDetails,
      iOS: iosDetails,
    );

    await _plugin.show(
      id: id,
      title: title,
      body: body,
      notificationDetails: details,
      payload: payload,
    );

    // Extra haptic feedback when vibration is enabled
    if (vibrateEnabled) {
      HapticFeedback.mediumImpact();
    }
  }

  // ── Schedule notification ──

  /// Schedule a notification at a specific DateTime.
  /// Used for 30-minute ride reminders.
  static Future<void> scheduleAt({
    required int id,
    required String title,
    required String body,
    required DateTime scheduledTime,
    String? payload,
  }) async {
    if (!_initialized) await init();

    // Don't schedule if time is in the past
    if (scheduledTime.isBefore(DateTime.now())) return;

    final prefs = await SharedPreferences.getInstance();
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
          ? const RawResourceAndroidNotificationSound('cruise_notification')
          : null,
      enableVibration: vibrateEnabled,
      vibrationPattern: vibrateEnabled
          ? Int64List.fromList([0, 120, 80, 120])
          : null,
      icon: '@mipmap/ic_launcher',
      color: const Color(0xFFE8C547),
    );

    const iosDetails = DarwinNotificationDetails(
      presentAlert: true,
      presentBadge: true,
      presentSound: true,
    );

    final details = NotificationDetails(
      android: androidDetails,
      iOS: iosDetails,
    );

    final tzTime = tz.TZDateTime.from(scheduledTime, tz.local);

    await _plugin.zonedSchedule(
      id: id,
      scheduledDate: tzTime,
      notificationDetails: details,
      androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
      title: title,
      body: body,
      payload: payload,
    );

    debugPrint(
      '[NotificationService] scheduled #$id at $scheduledTime: $title',
    );
  }

  /// Cancel a specific scheduled notification.
  static Future<void> cancel(int id) async {
    await _plugin.cancel(id: id);
  }

  /// Cancel all scheduled notifications.
  static Future<void> cancelAll() async {
    await _plugin.cancelAll();
  }

  // ── Ride reminder helpers ──

  /// Schedule a 1-hour reminder for a scheduled ride.
  /// Uses trip ID as notification ID for easy cancellation.
  static Future<void> scheduleRideReminder({
    required int tripId,
    required DateTime rideTime,
    required String pickup,
    required String dropoff,
  }) async {
    final reminderTime = rideTime.subtract(const Duration(hours: 1));
    // Only schedule if reminder is still in the future
    if (reminderTime.isBefore(DateTime.now())) return;

    await scheduleAt(
      id: tripId,
      title: '🚗 Your ride is in 1 hour',
      body: 'From $pickup to $dropoff',
      scheduledTime: reminderTime,
      payload: 'ride_reminder:$tripId',
    );
  }

  /// Cancel a ride reminder.
  static Future<void> cancelRideReminder(int tripId) async {
    await cancel(tripId);
  }
}
