import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../l10n/app_localizations.dart';
import '../../config/page_transitions.dart';
import '../../main.dart' show themeNotifier;
import '../privacy_screen.dart';
import 'driver_manage_account_screen.dart';
import 'driver_settings_pages.dart';

/// Driver settings: Uber Driver–style layout with Account & General sections.
class DriverSettingsScreen extends StatefulWidget {
  const DriverSettingsScreen({super.key});

  @override
  State<DriverSettingsScreen> createState() => _DriverSettingsScreenState();
}

class _DriverSettingsScreenState extends State<DriverSettingsScreen> {
  static const _gold = Color(0xFFE8C547);
  static const _bg = Color(0xFF0A0A0A);
  static const _surface = Color(0xFF111111);
  // ignore: unused_field
  static const _card = Color(0xFF1C1C1E);

  // Toggles
  bool _nightMode = true;
  bool _accessibility = false;

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      _nightMode = prefs.getBool('driver_night_mode') ?? true;
      _accessibility = prefs.getBool('driver_accessibility') ?? false;
    });
  }

  Future<void> _setNightMode(bool v) async {
    setState(() => _nightMode = v);
    themeNotifier.setNightMode(v);
  }

  Future<void> _setAccessibility(bool v) async {
    setState(() => _accessibility = v);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('driver_accessibility', v);
  }

  @override
  Widget build(BuildContext context) {
    final top = MediaQuery.of(context).padding.top;
    return Scaffold(
      backgroundColor: _bg,
      body: Column(
        children: [
          // ── Top bar ──
          Container(
            color: _surface,
            padding: EdgeInsets.only(
              top: top + 8,
              bottom: 12,
              left: 16,
              right: 16,
            ),
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
                  S.of(context).settingsTitle,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 20,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ],
            ),
          ),

          // ── Content ──
          Expanded(
            child: ListView(
              physics: const BouncingScrollPhysics(),
              padding: const EdgeInsets.only(top: 20, bottom: 40),
              children: [
                _sectionHeader(S.of(context).accountLabel),
                _navItem(
                  Icons.person_outline_rounded,
                  S.of(context).manageAccount,
                  S.of(context).editAccountDetails,
                  () => Navigator.push(
                    context,
                    slideFromRightRoute(const DriverManageAccountScreen()),
                  ),
                ),
                _navItem(
                  Icons.lock_outline_rounded,
                  S.of(context).privacy,
                  S.of(context).dataPrivacySettings,
                  () => Navigator.push(
                    context,
                    slideFromRightRoute(const PrivacyScreen()),
                  ),
                ),
                _navItem(
                  Icons.edit_location_alt_outlined,
                  S.of(context).editAddress,
                  S.of(context).homeWorkAddresses,
                  () => Navigator.push(
                    context,
                    slideFromRightRoute(const DriverEditAddressScreen()),
                  ),
                ),

                const SizedBox(height: 28),

                // ═══ GENERAL SECTION ═══
                _sectionHeader(S.of(context).generalLabel),
                _toggleItem(
                  Icons.accessibility_new_rounded,
                  S.of(context).accessibilityLabel,
                  S.of(context).accessibilityFeatures,
                  _accessibility,
                  _setAccessibility,
                ),
                _toggleItem(
                  Icons.dark_mode_rounded,
                  S.of(context).nightMode,
                  S.of(context).appAppearance,
                  _nightMode,
                  _setNightMode,
                ),
                _navItem(
                  Icons.record_voice_over_rounded,
                  S.of(context).siriShortcuts,
                  S.of(context).voiceCommands,
                  () => Navigator.push(
                    context,
                    slideFromRightRoute(const DriverSiriShortcutsScreen()),
                  ),
                ),
                _navItem(
                  Icons.chat_bubble_outline_rounded,
                  S.of(context).communicationLabel,
                  S.of(context).messagePreferences,
                  () => Navigator.push(
                    context,
                    slideFromRightRoute(const DriverCommunicationScreen()),
                  ),
                ),
                _navItem(
                  Icons.navigation_rounded,
                  S.of(context).navigationLabel,
                  S.of(context).mapsRoutingPrefs,
                  () => Navigator.push(
                    context,
                    slideFromRightRoute(const DriverNavigationScreen()),
                  ),
                ),
                _navItem(
                  Icons.volume_up_rounded,
                  S.of(context).soundsAndVoice,
                  S.of(context).audioVoiceSettings,
                  () => Navigator.push(
                    context,
                    slideFromRightRoute(const DriverSoundsVoiceScreen()),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _sectionHeader(String title) {
    return Padding(
      padding: const EdgeInsets.only(left: 20, bottom: 10),
      child: Text(
        title,
        style: TextStyle(
          color: Colors.white.withValues(alpha: 0.4),
          fontSize: 13,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.5,
        ),
      ),
    );
  }

  Widget _navItem(IconData icon, String title, String sub, VoidCallback onTap) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
      child: ListTile(
        onTap: () {
          HapticFeedback.selectionClick();
          onTap();
        },
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        leading: Container(
          width: 42,
          height: 42,
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.05),
            borderRadius: BorderRadius.circular(13),
          ),
          child: Icon(
            icon,
            color: Colors.white.withValues(alpha: 0.6),
            size: 20,
          ),
        ),
        title: Text(
          title,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 15,
            fontWeight: FontWeight.w700,
          ),
        ),
        subtitle: Text(
          sub,
          style: TextStyle(
            color: Colors.white.withValues(alpha: 0.3),
            fontSize: 12,
          ),
        ),
        trailing: Icon(
          Icons.chevron_right_rounded,
          color: Colors.white.withValues(alpha: 0.1),
          size: 20,
        ),
      ),
    );
  }

  Widget _toggleItem(
    IconData icon,
    String title,
    String sub,
    bool value,
    ValueChanged<bool> onChanged,
  ) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
      child: ListTile(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        leading: Container(
          width: 42,
          height: 42,
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.05),
            borderRadius: BorderRadius.circular(13),
          ),
          child: Icon(
            icon,
            color: Colors.white.withValues(alpha: 0.6),
            size: 20,
          ),
        ),
        title: Text(
          title,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 15,
            fontWeight: FontWeight.w700,
          ),
        ),
        subtitle: Text(
          sub,
          style: TextStyle(
            color: Colors.white.withValues(alpha: 0.3),
            fontSize: 12,
          ),
        ),
        trailing: Switch.adaptive(
          value: value,
          onChanged: (v) {
            HapticFeedback.selectionClick();
            onChanged(v);
          },
          activeThumbColor: _gold,
          activeTrackColor: _gold.withValues(alpha: 0.3),
          inactiveThumbColor: Colors.white30,
          inactiveTrackColor: Colors.white.withValues(alpha: 0.08),
        ),
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
        duration: const Duration(seconds: 2),
      ),
    );
  }
}
