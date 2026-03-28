import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import '../config/app_theme.dart';
import '../l10n/app_localizations.dart';
import '../services/notification_service.dart';
import '../services/user_session.dart';

class NotificationSettingsScreen extends StatefulWidget {
  const NotificationSettingsScreen({super.key});

  @override
  State<NotificationSettingsScreen> createState() =>
      _NotificationSettingsScreenState();
}

class _NotificationSettingsScreenState extends State<NotificationSettingsScreen>
    with WidgetsBindingObserver {
  static const _gold = Color(0xFFE8C547);

  bool _systemEnabled = true; // phone-level permission
  bool _masterEnabled = true; // app-level master toggle
  bool _rideUpdates = true;
  bool _promotions = true;
  bool _safety = true;
  bool _payment = true;
  bool _sounds = true;
  bool _vibrate = true;

  String get _uid => UserSession.currentUid;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _load();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// Re-check system permission when user returns from settings app
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _checkSystemPermission();
    }
  }

  Future<void> _checkSystemPermission() async {
    final granted = await NotificationService.isPermissionGranted();
    if (!mounted) return;
    setState(() => _systemEnabled = granted);
  }

  Future<void> _load() async {
    await _checkSystemPermission();
    // Load from local cache instantly (uid-keyed)
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      _masterEnabled = prefs.getBool('notif_${_uid}_master') ?? true;
      _rideUpdates = prefs.getBool('notif_${_uid}_rideUpdates') ?? true;
      _promotions = prefs.getBool('notif_${_uid}_promotions') ?? true;
      _safety = prefs.getBool('notif_${_uid}_safetyAlerts') ?? true;
      _payment = prefs.getBool('notif_${_uid}_payment') ?? true;
      _sounds = prefs.getBool('notif_${_uid}_sounds') ?? true;
      _vibrate = prefs.getBool('notif_${_uid}_vibration') ?? true;
    });

    // Then sync from Firestore
    _loadFirestorePrefs();
  }

  Future<void> _loadFirestorePrefs() async {
    if (_uid.isEmpty) return;
    try {
      final doc = await FirebaseFirestore.instance
          .collection('users')
          .doc('sql_$_uid')
          .get();
      if (!mounted) return;
      final data = doc.data()?['notificationPrefs'] as Map<String, dynamic>? ?? {};
      setState(() {
        _masterEnabled = data['master'] as bool? ?? _masterEnabled;
        _rideUpdates = data['rideUpdates'] as bool? ?? _rideUpdates;
        _promotions = data['promotions'] as bool? ?? _promotions;
        _safety = data['safetyAlerts'] as bool? ?? _safety;
        _payment = data['payment'] as bool? ?? _payment;
        _sounds = data['sounds'] as bool? ?? _sounds;
        _vibrate = data['vibration'] as bool? ?? _vibrate;
      });
    } catch (e) {
      debugPrint('[NotifSettings] Firestore load error: $e');
    }
  }

  Future<void> _savePreference(String key, bool value) async {
    // Save to uid-keyed SharedPreferences
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('notif_${_uid}_$key', value);

    // Save to Firestore
    if (_uid.isNotEmpty) {
      try {
        await FirebaseFirestore.instance
            .collection('users')
            .doc('sql_$_uid')
            .set({
          'notificationPrefs': {key: value},
        }, SetOptions(merge: true));
      } catch (e) {
        debugPrint('[NotifSettings] Firestore save error: $e');
      }
    }
  }

  Future<void> _applyFCMPreference(String topic, bool enabled) async {
    try {
      final fullTopic = '${_uid}_$topic';
      if (enabled && _masterEnabled) {
        await FirebaseMessaging.instance.subscribeToTopic(fullTopic);
      } else {
        await FirebaseMessaging.instance.unsubscribeFromTopic(fullTopic);
      }
    } catch (e) {
      debugPrint('[NotifSettings] FCM topic error: $e');
    }
  }

  Future<void> _togglePreference(String key, String fcmTopic, bool value, void Function(bool) setLocal) async {
    setState(() => setLocal(value));
    await _savePreference(key, value);
    await _applyFCMPreference(fcmTopic, value);
  }

  Future<void> _handleMasterToggle(bool value) async {
    setState(() => _masterEnabled = value);
    await _savePreference('master', value);

    // Subscribe/unsubscribe all FCM topics
    final topics = {
      'ride_updates': _rideUpdates,
      'promotions': _promotions,
      'safety': _safety,
      'payment': _payment,
    };
    for (final entry in topics.entries) {
      await _applyFCMPreference(entry.key, value && entry.value);
    }
  }

  Future<void> _handleSystemToggle(bool value) async {
    if (value) {
      // Request permission
      final granted = await NotificationService.requestPermission();
      if (!granted) {
        // Permission denied — open system settings
        await NotificationService.openSystemSettings();
        return;
      }
      if (!mounted) return;
      setState(() => _systemEnabled = true);
    } else {
      // Can't revoke permission programmatically — open system settings
      await NotificationService.openSystemSettings();
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);

    return Scaffold(
      backgroundColor: c.bg,
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(height: 8),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Row(
                children: [
                  GestureDetector(
                    onTap: () => Navigator.of(context).pop(),
                    child: Container(
                      width: 40,
                      height: 40,
                      decoration: BoxDecoration(
                        color: c.surface,
                        borderRadius: BorderRadius.circular(12),
                        border: c.isDark
                            ? null
                            : Border.all(
                                color: Colors.black.withValues(alpha: 0.06),
                              ),
                      ),
                      child: Icon(
                        Icons.arrow_back_ios_new_rounded,
                        color: c.textPrimary,
                        size: 18,
                      ),
                    ),
                  ),
                  const SizedBox(width: 16),
                  Text(
                    'Notifications',
                    style: TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w700,
                      color: c.textPrimary,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 28),

            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // ── System permission status ──
                    Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: _systemEnabled
                            ? _gold.withValues(alpha: 0.08)
                            : const Color(0xFFFF5252).withValues(alpha: 0.08),
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(
                          color: _systemEnabled
                              ? _gold.withValues(alpha: 0.2)
                              : const Color(0xFFFF5252).withValues(alpha: 0.2),
                        ),
                      ),
                      child: Row(
                        children: [
                          Icon(
                            _systemEnabled
                                ? Icons.notifications_active_rounded
                                : Icons.notifications_off_rounded,
                            color: _systemEnabled
                                ? _gold
                                : const Color(0xFFFF5252),
                            size: 22,
                          ),
                          const SizedBox(width: 14),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  _systemEnabled
                                      ? S.of(context).notificationsEnabled
                                      : S.of(context).notificationsDisabled,
                                  style: TextStyle(
                                    fontSize: 15,
                                    fontWeight: FontWeight.w700,
                                    color: _systemEnabled
                                        ? _gold
                                        : const Color(0xFFFF5252),
                                  ),
                                ),
                                const SizedBox(height: 3),
                                Text(
                                  _systemEnabled
                                      ? S.of(context).syncedWithPhone
                                      : S.of(context).enableInSettings,
                                  style: TextStyle(
                                    fontSize: 13,
                                    color: c.textSecondary,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          Switch.adaptive(
                            value: _systemEnabled,
                            onChanged: _handleSystemToggle,
                            activeThumbColor: _gold,
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 16),

                    // ── Master app-level toggle ──
                    _toggleItem(
                      c,
                      S.of(context).notificationsEnabled,
                      _masterEnabled
                          ? S.of(context).allNotificationsOn
                          : S.of(context).allNotificationsOff,
                      _masterEnabled,
                      _handleMasterToggle,
                    ),
                    const SizedBox(height: 24),

                    Text(
                      S.of(context).pushNotifications,
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                        color: c.textPrimary,
                      ),
                    ),
                    const SizedBox(height: 14),

                    Opacity(
                      opacity: _masterEnabled ? 1.0 : 0.4,
                      child: IgnorePointer(
                        ignoring: !_masterEnabled,
                        child: Column(
                          children: [
                            _toggleItem(
                              c,
                              S.of(context).rideUpdates,
                              S.of(context).rideUpdatesDesc,
                              _rideUpdates,
                              (v) => _togglePreference('rideUpdates', 'ride_updates', v, (val) => _rideUpdates = val),
                            ),
                            const SizedBox(height: 10),
                            _toggleItem(
                              c,
                              S.of(context).promotionsOffers,
                              S.of(context).promotionsDesc,
                              _promotions,
                              (v) => _togglePreference('promotions', 'promotions', v, (val) => _promotions = val),
                            ),
                            const SizedBox(height: 10),
                            _toggleItem(
                              c,
                              S.of(context).safetyAlerts,
                              S.of(context).safetyAlertsDesc,
                              _safety,
                              (v) => _togglePreference('safetyAlerts', 'safety', v, (val) => _safety = val),
                            ),
                            const SizedBox(height: 10),
                            _toggleItem(
                              c,
                              S.of(context).paymentNotif,
                              S.of(context).paymentNotifDesc,
                              _payment,
                              (v) => _togglePreference('payment', 'payment', v, (val) => _payment = val),
                            ),
                          ],
                        ),
                      ),
                    ),

                    const SizedBox(height: 28),
                    Text(
                      S.of(context).soundAndVibration,
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                        color: c.textPrimary,
                      ),
                    ),
                    const SizedBox(height: 14),

                    _toggleItem(
                      c,
                      S.of(context).sounds,
                      S.of(context).soundsDesc,
                      _sounds,
                      (v) {
                        setState(() => _sounds = v);
                        _savePreference('sounds', v);
                      },
                    ),
                    const SizedBox(height: 10),
                    _toggleItem(
                      c,
                      S.of(context).vibration,
                      S.of(context).vibrationDesc,
                      _vibrate,
                      (v) {
                        setState(() => _vibrate = v);
                        _savePreference('vibration', v);
                      },
                    ),
                    const SizedBox(height: 32),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _toggleItem(
    AppColors c,
    String title,
    String subtitle,
    bool value,
    ValueChanged<bool> onChanged,
  ) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(14),
        border: c.isDark
            ? null
            : Border.all(color: Colors.black.withValues(alpha: 0.06)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: c.textPrimary,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  subtitle,
                  style: TextStyle(fontSize: 13, color: c.textSecondary),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          Switch.adaptive(
            value: value,
            onChanged: onChanged,
            activeThumbColor: _gold,
            activeTrackColor: _gold.withValues(alpha: 0.3),
          ),
        ],
      ),
    );
  }
}
