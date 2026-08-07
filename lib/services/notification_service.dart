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
///   cruise_online.wav — the offer cue while the app is open, and the
///                       go-online chime it was named for. The chime never
///                       plays from the GO button — that is what froze the
///                       platform thread — only from the online screen once
///                       its map is up. See [playOnlineChime].
class NotificationService {
  static final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();

  static bool _initialized = false;

  // Notification IDs (stable, so a second show() replaces the first)
  static const int _offerBaseId = 9000;
  static const int _driverOnlineId = 8888;

  // Both cues. The go-online chime had a player of its own once, and a
  // second engine cold-starting on the platform thread was part of what made
  // it freeze; it borrows this pre-warmed one now — see [playOnlineChime].
  static final AudioPlayer _offerPlayer = AudioPlayer();

  /// FCM token-refresh subscription (see [ensureTokenRegistered]).
  /// Never cancelled: the service is a process-lifetime static.
  /// The only rotation listener in the app — every screen that used to keep
  /// its own saved without recording the outcome, so a rotation that failed
  /// to reach the backend looked exactly like one that landed.
  static StreamSubscription<String>? _tokenRefreshSub;

  /// The token string the backend last accepted, for this process only.
  ///
  /// Deliberately not persisted. The backend nulls `users.fcm_token` on its
  /// own the first time APNs/FCM answers "Requested entity was not found",
  /// and a memo that outlived the process would keep agreeing with a row
  /// that is already empty. Process-scoped means a cold start always
  /// registers once, and every call after that costs nothing.
  static String? _lastRegisteredToken;

  /// The last save was attempted and did not land — no session JWT yet,
  /// HTTP error, or no network. Whoever can ask again should.
  static bool _lastSaveFailed = false;

  /// One save in flight at a time: screen entry, going online and returning
  /// to the foreground can all ask inside the same second.
  static Future<bool>? _inFlightSave;

  /// Whether the backend is known to hold this device's token.
  static bool get isTokenRegistered => _lastRegisteredToken != null;

  /// Whether it is worth asking again — nothing has registered this process,
  /// or the last attempt failed. The two differ when the phone could not
  /// produce a token at all after an earlier save had already landed.
  static bool get needsTokenRetry =>
      _lastRegisteredToken == null || _lastSaveFailed;

  /// Forget which token the backend holds. Call on logout or any account
  /// switch.
  ///
  /// The FCM token belongs to the DEVICE, not to the account, so after a
  /// switch it is byte-identical — and `_saveCurrentToken` short-circuits on
  /// exactly that comparison. Without this the memo says "already saved" and
  /// the token is never written to the NEW user's row: the second driver to
  /// use a phone silently receives no offers, forever, with nothing in any
  /// log to say why.
  static void forgetRegisteredToken() {
    _lastRegisteredToken = null;
    _lastSaveFailed = false;
  }

  /// Registers the current FCM token with the backend and keeps it updated
  /// on rotation. Safe to call multiple times and before login (fails silently).
  static Future<void> registerTokenWithBackend() =>
      ensureTokenRegistered(reason: 'startup');

  /// Make sure the backend holds this device's token, and say whether it
  /// does. Safe to call multiple times and before login.
  ///
  /// The network call only happens when the token is not the one the backend
  /// already accepted, so the call sites that exist purely as safety nets —
  /// going online, coming back to the foreground — cost one cached
  /// platform-channel read once any of them has worked.
  ///
  /// [reason] names the call site in the log. Which entry point finally
  /// landed the token is the thing worth knowing when a driver reports that
  /// offers never reach the phone.
  /// [force] re-asserts the token even when this process already saw it
  /// saved. That matters because the memo lives in THIS process and the
  /// backend nulls `users.fcm_token` on its own, whenever Apple or Google
  /// answers "Requested entity was not found". After that the row is empty
  /// while the app still believes it is registered, and every later call
  /// short-circuits — which is exactly the trap these extra call sites were
  /// added to escape. Going online is rare, so one unconditional POST there
  /// costs nothing and closes it.
  static Future<bool> ensureTokenRegistered({
    String reason = 'unspecified',
    bool force = false,
  }) {
    if (force) {
      _lastRegisteredToken = null;
      // Do not JOIN a save already travelling — it read the memo before it
      // was cleared, so it can still short-circuit and report success without
      // writing anything. Queue a real one behind it instead. Forcing only
      // happens on go-online, so at most one extra POST is ever chained.
      final travelling = _inFlightSave;
      if (travelling != null) {
        return _inFlightSave = travelling
            .then((_) => _saveCurrentToken(reason))
            .whenComplete(() => _inFlightSave = null);
      }
    }
    return _inFlightSave ??= _saveCurrentToken(reason)
        .whenComplete(() => _inFlightSave = null);
  }

  static Future<bool> _saveCurrentToken(String reason) async {
    try {
      final messaging = FirebaseMessaging.instance;
      // Before the null check below, not after: on iOS a cold start reaches
      // here while APNs is still answering, and the token that never existed
      // for getToken() arrives on this stream a moment later. Attaching only
      // on the success path meant the one device that most needs the listener
      // never got one.
      _listenForRotation(messaging);
      final token = await messaging.getToken();
      if (token == null) {
        // No APNs token on iOS, or the device has not reached FCM yet.
        // Nothing to save and nothing to remember.
        _lastSaveFailed = true;
        debugPrint('[Notifications] getToken() returned null ($reason) — '
            'check APNs setup');
        return false;
      }
      // Already on the backend — this is the happy path, and it makes no
      // request at all. Whatever went wrong last time is over: the phone
      // produced a token and it is the one the backend accepted.
      if (token == _lastRegisteredToken) {
        _lastSaveFailed = false;
        return true;
      }

      final ok = await ApiService.saveFcmToken(token);
      _recordSave(token, ok);
      if (!ok) {
        debugPrint('[Notifications] token not registered ($reason) — likely no '
            'session yet; will retry on rotation, go-online or resume');
      }
      return ok;
    } catch (e) {
      _lastSaveFailed = true;
      debugPrint('[Notifications] token registration failed ($reason): $e');
      return false;
    }
  }

  static void _listenForRotation(FirebaseMessaging messaging) {
    _tokenRefreshSub ??= messaging.onTokenRefresh.listen((t) async {
      debugPrint('[Notifications] token rotated — re-registering');
      _recordSave(t, await ApiService.saveFcmToken(t));
    });
  }

  /// A token counts as registered only when the backend said so. A failed
  /// save clears the memo, so the next caller retries instead of skipping.
  static void _recordSave(String token, bool ok) {
    _lastRegisteredToken = ok ? token : null;
    _lastSaveFailed = !ok;
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

  /// Called when the driver taps a notification THIS app drew (as opposed to
  /// one FCM drew, which arrives through onMessageOpenedApp).
  ///
  /// The body used to be a single debugPrint, so every tap on a local offer
  /// notification did nothing at all — the payload carrying the trip and
  /// offer ids was built, attached, delivered here, and thrown away.
  ///
  /// Set by main() rather than imported: this service is below the app layer
  /// and must not reach up into it.
  static void Function(String? payload)? onOfferTapped;

  static void _onNotificationTapped(NotificationResponse response) {
    final payload = response.payload;
    debugPrint('[Notification] tapped: $payload');
    if (payload != null && payload.startsWith('trip_offer')) {
      onOfferTapped?.call(payload);
    }
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
      // NEEDS A FULL BUILD, NOT A SHOREBIRD PATCH. This flag only does
      // anything with USE_FULL_SCREEN_INTENT in AndroidManifest.xml, and a
      // manifest change is native — `shorebird patch` ships Dart only, so an
      // OTA patch leaves the permission behind and the takeover silently does
      // not happen. On API 34+ it also needs the user to grant it in
      // settings, which is why no delivery path may depend on this working.
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

  /// The go-online confirmation. Called by DriverOnlineScreen once its map
  /// surface is up — never by the GO button, which is what froze; the
  /// screen's `_armOnlineChime` carries that history.
  ///
  /// Borrows the offer player instead of building its own. The chime used to
  /// have a second [AudioPlayer], and a second audio engine cold-starting on
  /// the platform thread was part of the cost; this one is already pre-warmed
  /// by [init], and cruise_online.wav is the clip it was named for.
  ///
  /// One shot and no duck. The offer cue dips the driver's music because it
  /// has to be heard over it for six seconds; this is a beat of confirmation
  /// and mixes at full volume rather than flipping the session category twice
  /// around itself.
  static void playOnlineChime() {
    // The offer cue owns the player while it is running and outranks this:
    // being told a ride is waiting matters more than being told you are
    // online. Checked again inside, after the prefs await.
    if (_offerSoundPlaying) return;
    Future.microtask(() async {
      try {
        final prefs = PrefsCache.instanceSync ?? await PrefsCache.instance;
        final volume = prefs.getDouble('sound_volume') ?? 0.8;
        if (!(prefs.getBool('notif_sounds') ?? true) || volume <= 0) return;
        if (_offerSoundPlaying) return;
        // Free once the session is configured — it hands back the cached
        // future. The case it covers is a chime that beats [init]'s preload,
        // where playing first would activate the session on audioplayers'
        // own category and stop whatever the driver is listening to.
        await ensureNonInterruptingAudio();
        // The preference above was read and then never applied: a driver who
        // pulled the slider down to 0.1 still got the chime at full volume.
        _quietly(_offerPlayer.setVolume(volume), 'chime volume');
        // Fire-and-forget through _quietly for the reason spelled out in
        // playOfferSound: an unawaited platform call that never gets its
        // reply surfaces half a minute later as a bare TimeoutException.
        _quietly(_offerPlayer.seek(Duration.zero), 'chime seek');
        _quietly(_offerPlayer.resume(), 'chime resume');
      } catch (e) {
        debugPrint('[NotificationService] playOnlineChime error: $e');
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
