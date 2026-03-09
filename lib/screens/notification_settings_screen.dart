import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:permission_handler/permission_handler.dart';
import '../config/app_theme.dart';
import '../l10n/app_localizations.dart';
import '../services/notification_service.dart';

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
  bool _rideUpdates = true;
  bool _promotions = true;
  bool _safety = true;
  bool _payment = true;
  bool _sounds = true;
  bool _vibrate = true;

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
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      _rideUpdates = prefs.getBool('notif_ride') ?? true;
      _promotions = prefs.getBool('notif_promo') ?? true;
      _safety = prefs.getBool('notif_safety') ?? true;
      _payment = prefs.getBool('notif_payment') ?? true;
      _sounds = prefs.getBool('notif_sounds') ?? true;
      _vibrate = prefs.getBool('notif_vibrate') ?? true;
    });
  }

  Future<void> _toggle(String key, bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(key, value);
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

                    _toggleItem(
                      c,
                      S.of(context).rideUpdates,
                      S.of(context).rideUpdatesDesc,
                      _rideUpdates,
                      (v) {
                        setState(() => _rideUpdates = v);
                        _toggle('notif_ride', v);
                      },
                    ),
                    const SizedBox(height: 10),
                    _toggleItem(
                      c,
                      S.of(context).promotionsOffers,
                      S.of(context).promotionsDesc,
                      _promotions,
                      (v) {
                        setState(() => _promotions = v);
                        _toggle('notif_promo', v);
                      },
                    ),
                    const SizedBox(height: 10),
                    _toggleItem(
                      c,
                      S.of(context).safetyAlerts,
                      S.of(context).safetyAlertsDesc,
                      _safety,
                      (v) {
                        setState(() => _safety = v);
                        _toggle('notif_safety', v);
                      },
                    ),
                    const SizedBox(height: 10),
                    _toggleItem(
                      c,
                      S.of(context).paymentNotif,
                      S.of(context).paymentNotifDesc,
                      _payment,
                      (v) {
                        setState(() => _payment = v);
                        _toggle('notif_payment', v);
                      },
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
                        _toggle('notif_sounds', v);
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
                        _toggle('notif_vibrate', v);
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
