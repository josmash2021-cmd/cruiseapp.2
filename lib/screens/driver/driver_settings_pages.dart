import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../l10n/app_localizations.dart';

// ═══════════════════════════════════════════════════════
//  EDIT ADDRESS SCREEN
// ═══════════════════════════════════════════════════════

class DriverEditAddressScreen extends StatefulWidget {
  const DriverEditAddressScreen({super.key});
  @override
  State<DriverEditAddressScreen> createState() =>
      _DriverEditAddressScreenState();
}

class _DriverEditAddressScreenState extends State<DriverEditAddressScreen> {
  static const _gold = Color(0xFFE8C547);
  static const _bg = Color(0xFF0A0A0A);
  static const _surface = Color(0xFF111111);

  final _homeCtrl = TextEditingController();
  final _workCtrl = TextEditingController();
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _homeCtrl.dispose();
    _workCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    _homeCtrl.text = prefs.getString('driver_home_address') ?? '';
    _workCtrl.text = prefs.getString('driver_work_address') ?? '';
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('driver_home_address', _homeCtrl.text.trim());
    await prefs.setString('driver_work_address', _workCtrl.text.trim());
    if (!mounted) return;
    setState(() => _saving = false);
    _snack(S.of(context).addressSaved);
  }

  @override
  Widget build(BuildContext context) {
    final top = MediaQuery.of(context).padding.top;
    return Scaffold(
      backgroundColor: _bg,
      body: Column(
        children: [
          _topBar(top, S.of(context).editAddress),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.all(20),
              children: [
                _label(S.of(context).homeAddress),
                const SizedBox(height: 8),
                _field(
                  _homeCtrl,
                  Icons.home_rounded,
                  S.of(context).enterHomeAddress,
                ),
                const SizedBox(height: 24),
                _label(S.of(context).workAddress),
                const SizedBox(height: 8),
                _field(
                  _workCtrl,
                  Icons.work_rounded,
                  S.of(context).enterWorkAddress,
                ),
                const SizedBox(height: 32),
                SizedBox(
                  width: double.infinity,
                  height: 52,
                  child: ElevatedButton(
                    onPressed: _saving ? null : _save,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: _gold,
                      foregroundColor: Colors.black,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16),
                      ),
                    ),
                    child: _saving
                        ? const SizedBox(
                            width: 22,
                            height: 22,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.black,
                            ),
                          )
                        : Text(
                            S.of(context).saveChanges,
                            style: const TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _topBar(double top, String title) =>
      _SettingsTopBar(top: top, title: title);
  Widget _label(String t) => Text(
    t,
    style: const TextStyle(
      color: Colors.white70,
      fontSize: 13,
      fontWeight: FontWeight.w600,
    ),
  );

  Widget _field(TextEditingController ctrl, IconData icon, String hint) {
    return TextField(
      controller: ctrl,
      style: const TextStyle(color: Colors.white, fontSize: 15),
      cursorColor: _gold,
      decoration: InputDecoration(
        hintText: hint,
        hintStyle: TextStyle(color: Colors.white.withValues(alpha: 0.25)),
        prefixIcon: Icon(icon, color: _gold, size: 20),
        filled: true,
        fillColor: Colors.white.withValues(alpha: 0.06),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: Colors.white.withValues(alpha: 0.08)),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: _gold, width: 1.2),
        ),
        contentPadding: const EdgeInsets.symmetric(vertical: 14),
      ),
    );
  }

  void _snack(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          msg,
          style: const TextStyle(
            color: Colors.black,
            fontWeight: FontWeight.w700,
          ),
        ),
        backgroundColor: _gold,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    );
  }
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
  static const _gold = Color(0xFFE8C547);
  static const _bg = Color(0xFF0A0A0A);

  bool _pushNotifications = true;
  bool _emailNotifications = true;
  bool _smsNotifications = false;
  bool _promotions = false;

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
      backgroundColor: _bg,
      body: Column(
        children: [
          _SettingsTopBar(top: top, title: S.of(context).communicationLabel),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.all(20),
              children: [
                _toggleRow(
                  Icons.notifications_active_rounded,
                  S.of(context).pushNotifications,
                  S.of(context).pushNotificationsDesc,
                  _pushNotifications,
                  (v) {
                    setState(() => _pushNotifications = v);
                    _set('comm_push', v);
                  },
                ),
                _toggleRow(
                  Icons.email_rounded,
                  S.of(context).emailNotifications,
                  S.of(context).emailNotificationsDesc,
                  _emailNotifications,
                  (v) {
                    setState(() => _emailNotifications = v);
                    _set('comm_email', v);
                  },
                ),
                _toggleRow(
                  Icons.sms_rounded,
                  S.of(context).smsNotifications,
                  S.of(context).smsNotificationsDesc,
                  _smsNotifications,
                  (v) {
                    setState(() => _smsNotifications = v);
                    _set('comm_sms', v);
                  },
                ),
                _toggleRow(
                  Icons.local_offer_rounded,
                  S.of(context).promotions,
                  S.of(context).promotionsDesc,
                  _promotions,
                  (v) {
                    setState(() => _promotions = v);
                    _set('comm_promos', v);
                  },
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _toggleRow(
    IconData icon,
    String title,
    String sub,
    bool val,
    ValueChanged<bool> onChanged,
  ) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        children: [
          Icon(icon, color: _gold, size: 22),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                  ),
                ),
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
  static const _gold = Color(0xFFE8C547);
  static const _bg = Color(0xFF0A0A0A);

  String _defaultMap = 'cruise';
  bool _avoidTolls = false;
  bool _avoidHighways = false;

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
      backgroundColor: _bg,
      body: Column(
        children: [
          _SettingsTopBar(top: top, title: S.of(context).navigationLabel),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.all(20),
              children: [
                Text(
                  S.of(context).defaultMapApp,
                  style: const TextStyle(
                    color: Colors.white70,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 12),
                _mapOption('cruise', 'Cruise Maps', Icons.map_rounded),
                _mapOption(
                  'google',
                  'Google Maps',
                  Icons.travel_explore_rounded,
                ),
                _mapOption('apple', 'Apple Maps', Icons.explore_rounded),
                _mapOption('waze', 'Waze', Icons.directions_car_rounded),
                const SizedBox(height: 24),
                Text(
                  S.of(context).routePreferences,
                  style: const TextStyle(
                    color: Colors.white70,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 12),
                _toggleTile(
                  Icons.toll_rounded,
                  S.of(context).avoidTolls,
                  _avoidTolls,
                  (v) async {
                    setState(() => _avoidTolls = v);
                    (await SharedPreferences.getInstance()).setBool(
                      'nav_avoid_tolls',
                      v,
                    );
                  },
                ),
                _toggleTile(
                  Icons.alt_route_rounded,
                  S.of(context).avoidHighways,
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
        HapticFeedback.selectionClick();
        setState(() => _defaultMap = key);
        (await SharedPreferences.getInstance()).setString(
          'nav_default_map',
          key,
        );
      },
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          color: sel
              ? _gold.withValues(alpha: 0.1)
              : Colors.white.withValues(alpha: 0.05),
          borderRadius: BorderRadius.circular(14),
          border: sel ? Border.all(color: _gold, width: 1.2) : null,
        ),
        child: Row(
          children: [
            Icon(icon, color: sel ? _gold : Colors.white54, size: 22),
            const SizedBox(width: 14),
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

  Widget _toggleTile(
    IconData icon,
    String title,
    bool val,
    ValueChanged<bool> onChanged,
  ) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          Icon(icon, color: _gold, size: 22),
          const SizedBox(width: 14),
          Expanded(
            child: Text(
              title,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 15,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          Switch.adaptive(
            value: val,
            onChanged: onChanged,
            activeThumbColor: _gold,
            activeTrackColor: _gold.withValues(alpha: 0.3),
          ),
        ],
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════
//  SOUNDS & VOICE SCREEN
// ═══════════════════════════════════════════════════════

class DriverSoundsVoiceScreen extends StatefulWidget {
  const DriverSoundsVoiceScreen({super.key});
  @override
  State<DriverSoundsVoiceScreen> createState() =>
      _DriverSoundsVoiceScreenState();
}

class _DriverSoundsVoiceScreenState extends State<DriverSoundsVoiceScreen> {
  static const _gold = Color(0xFFE8C547);
  static const _bg = Color(0xFF0A0A0A);

  bool _tripSounds = true;
  bool _navigationVoice = true;
  bool _messageSounds = true;
  double _volume = 0.8;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      _tripSounds = prefs.getBool('sound_trips') ?? true;
      _navigationVoice = prefs.getBool('sound_nav_voice') ?? true;
      _messageSounds = prefs.getBool('sound_messages') ?? true;
      _volume = prefs.getDouble('sound_volume') ?? 0.8;
    });
  }

  @override
  Widget build(BuildContext context) {
    final top = MediaQuery.of(context).padding.top;
    return Scaffold(
      backgroundColor: _bg,
      body: Column(
        children: [
          _SettingsTopBar(top: top, title: S.of(context).soundsAndVoice),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.all(20),
              children: [
                Text(
                  S.of(context).volumeLevel,
                  style: const TextStyle(
                    color: Colors.white70,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 8,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.05),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Row(
                    children: [
                      const Icon(
                        Icons.volume_down_rounded,
                        color: Colors.white38,
                        size: 22,
                      ),
                      Expanded(
                        child: Slider(
                          value: _volume,
                          min: 0,
                          max: 1,
                          activeColor: _gold,
                          inactiveColor: Colors.white12,
                          onChanged: (v) async {
                            setState(() => _volume = v);
                            (await SharedPreferences.getInstance()).setDouble(
                              'sound_volume',
                              v,
                            );
                          },
                        ),
                      ),
                      const Icon(
                        Icons.volume_up_rounded,
                        color: _gold,
                        size: 22,
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 24),
                _toggleTile(
                  Icons.local_taxi_rounded,
                  S.of(context).tripRequestSounds,
                  S.of(context).tripRequestSoundsDesc,
                  _tripSounds,
                  (v) async {
                    setState(() => _tripSounds = v);
                    (await SharedPreferences.getInstance()).setBool(
                      'sound_trips',
                      v,
                    );
                  },
                ),
                _toggleTile(
                  Icons.record_voice_over_rounded,
                  S.of(context).navigationVoice,
                  S.of(context).navigationVoiceDesc,
                  _navigationVoice,
                  (v) async {
                    setState(() => _navigationVoice = v);
                    (await SharedPreferences.getInstance()).setBool(
                      'sound_nav_voice',
                      v,
                    );
                  },
                ),
                _toggleTile(
                  Icons.message_rounded,
                  S.of(context).messageSounds,
                  S.of(context).messageSoundsDesc,
                  _messageSounds,
                  (v) async {
                    setState(() => _messageSounds = v);
                    (await SharedPreferences.getInstance()).setBool(
                      'sound_messages',
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

  Widget _toggleTile(
    IconData icon,
    String title,
    String sub,
    bool val,
    ValueChanged<bool> onChanged,
  ) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        children: [
          Icon(icon, color: _gold, size: 22),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                  ),
                ),
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
          Switch.adaptive(
            value: val,
            onChanged: onChanged,
            activeThumbColor: _gold,
            activeTrackColor: _gold.withValues(alpha: 0.3),
          ),
        ],
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
      color: const Color(0xFF111111),
      padding: EdgeInsets.only(top: top + 8, bottom: 12, left: 16, right: 16),
      child: Row(
        children: [
          GestureDetector(
            onTap: () => Navigator.pop(context),
            child: Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.06),
                shape: BoxShape.circle,
              ),
              child: const Icon(
                Icons.arrow_back_rounded,
                color: Colors.white,
                size: 22,
              ),
            ),
          ),
          const SizedBox(width: 14),
          Text(
            title,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 20,
              fontWeight: FontWeight.w900,
            ),
          ),
        ],
      ),
    );
  }
}
