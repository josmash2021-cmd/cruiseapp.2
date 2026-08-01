import '../../utils/app_platform.dart';
import 'package:flutter/material.dart';
import '../../services/haptic_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../l10n/app_localizations.dart';
import '../../services/notification_service.dart';
import '../../widgets/neu_style.dart';

// ═══════════════════════════════════════════════════════
//  SHARED ROWS
// ═══════════════════════════════════════════════════════
//
// One toggle row, one label, one read-only row, used by every page in
// this file. There were three near-identical private copies before, which
// is how Navigation's rows ended up a different height from
// Communication's on the same screen.

const _gold = Color(0xFFE8C547);

Widget _neuLabel(String text) => Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Text(
        text,
        style: const TextStyle(
          color: Colors.white70,
          fontSize: 13,
          fontWeight: FontWeight.w600,
        ),
      ),
    );

/// Icon in a sunken well, title, optional subtitle, switch on the right.
Widget _neuToggleRow(
  IconData icon,
  String title,
  String? sub,
  bool val,
  ValueChanged<bool> onChanged,
) {
  return Container(
    margin: const EdgeInsets.only(bottom: 12),
    padding: const EdgeInsets.all(14),
    decoration: neuBox(radius: 18),
    child: Row(
      children: [
        Container(
          width: 38,
          height: 38,
          decoration: neuBox(radius: 12, pressed: true),
          child: Icon(icon, color: _gold, size: 19),
        ),
        const SizedBox(width: 13),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                ),
              ),
              if (sub != null) ...[
                const SizedBox(height: 2),
                Text(
                  sub,
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.4),
                    fontSize: 12,
                  ),
                ),
              ],
            ],
          ),
        ),
        Switch.adaptive(
          value: val,
          onChanged: onChanged,
          activeThumbColor: _gold,
          activeTrackColor: _gold.withValues(alpha: 0.3),
          inactiveThumbColor: Colors.white30,
          inactiveTrackColor: Colors.white.withValues(alpha: 0.08),
        ),
      ],
    ),
  );
}

/// A row that states something rather than changing it.
Widget _neuInfoRow(IconData icon, String title, String sub) {
  return Container(
    margin: const EdgeInsets.only(bottom: 12),
    padding: const EdgeInsets.all(14),
    decoration: neuBox(radius: 18),
    child: Row(
      children: [
        Container(
          width: 38,
          height: 38,
          decoration: neuBox(radius: 12, pressed: true),
          child: Icon(icon, color: _gold, size: 19),
        ),
        const SizedBox(width: 13),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                sub,
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.4),
                  fontSize: 12,
                ),
              ),
            ],
          ),
        ),
      ],
    ),
  );
}

// ═══════════════════════════════════════════════════════
//  SIRI SHORTCUTS SCREEN
// ═══════════════════════════════════════════════════════

class DriverSiriShortcutsScreen extends StatelessWidget {
  const DriverSiriShortcutsScreen({super.key});

  static const _gold = Color(0xFFE8C547);
  static const _bg = Color(0xFF0A0A0A);

  @override
  Widget build(BuildContext context) {
    final top = MediaQuery.of(context).padding.top;
    final shortcuts = [
      _ShortcutItem(
        Icons.play_arrow_rounded,
        S.of(context).goOnline,
        S.of(context).siriGoOnlineDesc,
      ),
      _ShortcutItem(
        Icons.stop_rounded,
        S.of(context).goOffline,
        S.of(context).siriGoOfflineDesc,
      ),
      _ShortcutItem(
        Icons.attach_money_rounded,
        S.of(context).checkEarnings,
        S.of(context).siriCheckEarningsDesc,
      ),
      _ShortcutItem(
        Icons.navigation_rounded,
        S.of(context).navigateHome,
        S.of(context).siriNavigateHomeDesc,
      ),
    ];

    return Scaffold(
      backgroundColor: _bg,
      body: Column(
        children: [
          _SettingsTopBar(top: top, title: S.of(context).siriShortcuts),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.all(20),
              children: [
                Text(
                  S.of(context).siriShortcutsInfo,
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.5),
                    fontSize: 14,
                    height: 1.5,
                  ),
                ),
                const SizedBox(height: 24),
                ...shortcuts.map((s) => _shortcutTile(context, s)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _shortcutTile(BuildContext context, _ShortcutItem item) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: _gold.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(item.icon, color: _gold, size: 22),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  item.title,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  item.subtitle,
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.4),
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
          Icon(Icons.add_circle_outline_rounded, color: _gold, size: 24),
        ],
      ),
    );
  }
}

class _ShortcutItem {
  final IconData icon;
  final String title;
  final String subtitle;
  const _ShortcutItem(this.icon, this.title, this.subtitle);
}

// ═══════════════════════════════════════════════════════
//  COMMUNICATION SCREEN
// ═══════════════════════════════════════════════════════

class DriverCommunicationScreen extends StatefulWidget {
  const DriverCommunicationScreen({super.key});
  @override
  State<DriverCommunicationScreen> createState() =>
      _DriverCommunicationScreenState();
}

class _DriverCommunicationScreenState extends State<DriverCommunicationScreen> {
  bool _pushNotifications = true;
  bool _emailNotifications = true;
  bool _smsNotifications = false;
  bool _promotions = false;
  // Moved here from the Sounds & Voice page, which no longer exists. The
  // keys are unchanged, so a driver who had already turned one off keeps
  // it off.
  bool _tripSounds = true;
  bool _messageSounds = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      _pushNotifications = prefs.getBool('comm_push') ?? true;
      _emailNotifications = prefs.getBool('comm_email') ?? true;
      _smsNotifications = prefs.getBool('comm_sms') ?? false;
      _promotions = prefs.getBool('comm_promos') ?? false;
      _tripSounds = prefs.getBool('sound_trips') ?? true;
      _messageSounds = prefs.getBool('sound_messages') ?? true;
    });
  }

  Future<void> _set(String key, bool val) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(key, val);
  }

  @override
  Widget build(BuildContext context) {
    final top = MediaQuery.of(context).padding.top;
    return Scaffold(
      backgroundColor: neuBase,
      body: Column(
        children: [
          _SettingsTopBar(top: top, title: S.of(context).communicationLabel),
          Expanded(
            child: ListView(
              physics: const BouncingScrollPhysics(),
              padding: const EdgeInsets.all(20),
              children: [
                _neuLabel(S.of(context).messagePreferences),
                _neuToggleRow(
                  Icons.notifications_active_rounded,
                  S.of(context).pushNotifications,
                  S.of(context).pushNotificationsDesc,
                  _pushNotifications,
                  (v) async {
                    if (v) {
                      // Request system notification permission when enabling
                      final granted =
                          await NotificationService.requestPermission();
                      if (!granted) {
                        // Open system settings if denied
                        NotificationService.openSystemSettings();
                        return;
                      }
                    }
                    setState(() => _pushNotifications = v);
                    _set('comm_push', v);
                  },
                ),
                _neuToggleRow(
                  Icons.email_rounded,
                  S.of(context).emailNotifications,
                  S.of(context).emailNotificationsDesc,
                  _emailNotifications,
                  (v) {
                    setState(() => _emailNotifications = v);
                    _set('comm_email', v);
                  },
                ),
                _neuToggleRow(
                  Icons.sms_rounded,
                  S.of(context).smsNotifications,
                  S.of(context).smsNotificationsDesc,
                  _smsNotifications,
                  (v) {
                    setState(() => _smsNotifications = v);
                    _set('comm_sms', v);
                  },
                ),
                _neuToggleRow(
                  Icons.local_offer_rounded,
                  S.of(context).promotions,
                  S.of(context).promotionsDesc,
                  _promotions,
                  (v) {
                    setState(() => _promotions = v);
                    _set('comm_promos', v);
                  },
                ),
                const SizedBox(height: 14),
                _neuLabel(S.of(context).soundsAndVoice),
                _neuInfoRow(
                  Icons.volume_up_rounded,
                  S.of(context).syncedWithDeviceVolume,
                  S.of(context).adjustWithPhoneVolumeButtons,
                ),
                _neuToggleRow(
                  Icons.local_taxi_rounded,
                  S.of(context).tripRequestSounds,
                  S.of(context).tripRequestSoundsDesc,
                  _tripSounds,
                  (v) {
                    setState(() => _tripSounds = v);
                    _set('sound_trips', v);
                  },
                ),
                _neuToggleRow(
                  Icons.message_rounded,
                  S.of(context).messageSounds,
                  S.of(context).messageSoundsDesc,
                  _messageSounds,
                  (v) {
                    setState(() => _messageSounds = v);
                    _set('sound_messages', v);
                  },
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════
//  NAVIGATION PREFERENCES SCREEN
// ═══════════════════════════════════════════════════════

class DriverNavigationScreen extends StatefulWidget {
  const DriverNavigationScreen({super.key});
  @override
  State<DriverNavigationScreen> createState() => _DriverNavigationScreenState();
}

class _DriverNavigationScreenState extends State<DriverNavigationScreen> {
  String _defaultMap = 'cruise';
  bool _avoidTolls = false;
  bool _avoidHighways = false;

  // Map app deep-link scheme used to test if installed
  static const _mapSchemes = {
    'google': 'comgooglemaps://',
    'apple': 'maps://',
    'waze': 'waze://',
  };

  // Store URLs if app is not installed
  static final _storeUrls = {
    'google': AppPlatform.isIOS
        ? 'https://apps.apple.com/app/google-maps/id585027354'
        : 'https://play.google.com/store/apps/details?id=com.google.android.apps.maps',
    'apple': 'https://apps.apple.com/app/apple-maps/id915056765',
    'waze': AppPlatform.isIOS
        ? 'https://apps.apple.com/app/waze-navigation-live-traffic/id323229106'
        : 'https://play.google.com/store/apps/details?id=com.waze',
  };

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      _defaultMap = prefs.getString('nav_default_map') ?? 'cruise';
      _avoidTolls = prefs.getBool('nav_avoid_tolls') ?? false;
      _avoidHighways = prefs.getBool('nav_avoid_highways') ?? false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final top = MediaQuery.of(context).padding.top;
    return Scaffold(
      backgroundColor: neuBase,
      body: Column(
        children: [
          _SettingsTopBar(top: top, title: S.of(context).navigationLabel),
          Expanded(
            child: ListView(
              physics: const BouncingScrollPhysics(),
              padding: const EdgeInsets.all(20),
              children: [
                _neuLabel(S.of(context).defaultMapApp),
                _mapOption('cruise', 'Cruise Maps', Icons.map_rounded),
                _mapOption(
                  'google',
                  'Google Maps',
                  Icons.travel_explore_rounded,
                ),
                _mapOption('apple', 'Apple Maps', Icons.explore_rounded),
                _mapOption('waze', 'Waze', Icons.directions_car_rounded),
                const SizedBox(height: 14),
                _neuLabel(S.of(context).routePreferences),
                _neuToggleRow(
                  Icons.toll_rounded,
                  S.of(context).avoidTolls,
                  null,
                  _avoidTolls,
                  (v) async {
                    setState(() => _avoidTolls = v);
                    (await SharedPreferences.getInstance()).setBool(
                      'nav_avoid_tolls',
                      v,
                    );
                  },
                ),
                _neuToggleRow(
                  Icons.alt_route_rounded,
                  S.of(context).avoidHighways,
                  null,
                  _avoidHighways,
                  (v) async {
                    setState(() => _avoidHighways = v);
                    (await SharedPreferences.getInstance()).setBool(
                      'nav_avoid_highways',
                      v,
                    );
                  },
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _mapOption(String key, String label, IconData icon) {
    final sel = _defaultMap == key;
    return GestureDetector(
      onTap: () async {
        HapticService.selectionClick();
        // For third-party apps, check if installed first
        final scheme = _mapSchemes[key];
        if (scheme != null) {
          final uri = Uri.parse(scheme);
          final available = await canLaunchUrl(uri);
          if (!available) {
            // App not installed — redirect to store
            final storeUrl = _storeUrls[key];
            if (storeUrl != null) {
              final storeUri = Uri.parse(storeUrl);
              if (await canLaunchUrl(storeUri)) {
                await launchUrl(storeUri, mode: LaunchMode.externalApplication);
              }
            }
            return;
          }
        }
        setState(() => _defaultMap = key);
        (await SharedPreferences.getInstance()).setString(
          'nav_default_map',
          key,
        );
      },
      child: Container(
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.all(14),
        decoration: neuBox(
          radius: 18,
          borderColor: sel ? _gold.withValues(alpha: 0.55) : null,
          borderWidth: sel ? 1.2 : 1,
        ),
        child: Row(
          children: [
            Container(
              width: 38,
              height: 38,
              decoration: neuBox(radius: 12, pressed: true),
              child: Icon(icon, color: sel ? _gold : Colors.white54, size: 19),
            ),
            const SizedBox(width: 13),
            Expanded(
              child: Text(
                label,
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 15,
                  fontWeight: sel ? FontWeight.w700 : FontWeight.w500,
                ),
              ),
            ),
            if (sel) const Icon(Icons.check_rounded, color: _gold, size: 20),
          ],
        ),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════
//  SHARED TOP BAR
// ═══════════════════════════════════════════════════════

class _SettingsTopBar extends StatelessWidget {
  final double top;
  final String title;
  const _SettingsTopBar({required this.top, required this.title});

  @override
  Widget build(BuildContext context) {
    return Container(
      color: neuBase,
      padding: EdgeInsets.only(top: top + 8, bottom: 12, left: 16, right: 16),
      child: Row(
        children: [
          GestureDetector(
            onTap: () => Navigator.pop(context),
            child: Container(
              width: 40,
              height: 40,
              decoration: neuBox(radius: 20),
              child: const Icon(
                Icons.arrow_back_rounded,
                color: Colors.white,
                size: 20,
              ),
            ),
          ),
          const SizedBox(width: 14),
          Text(
            title,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 20,
              fontWeight: FontWeight.w800,
            ),
          ),
        ],
      ),
    );
  }
}
