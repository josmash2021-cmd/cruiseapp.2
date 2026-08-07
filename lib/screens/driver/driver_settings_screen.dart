import '../../utils/app_platform.dart';
import 'package:flutter/material.dart';
import '../../services/haptic_service.dart';
import '../../l10n/app_localizations.dart';
import '../../config/page_transitions.dart';
import '../../config/driver_colors.dart';
import '../../services/user_session.dart';
import '../home_screen.dart';
import '../../main.dart' show accessibilityNotifier;
import '../privacy_screen.dart';
import '../accessibility_screen.dart';
import 'driver_manage_account_screen.dart';
import 'driver_settings_pages.dart';
import '../../widgets/neu_style.dart';

/// Driver settings: Uber Driver–style layout with Account & General sections.
class DriverSettingsScreen extends StatefulWidget {
  const DriverSettingsScreen({super.key});

  @override
  State<DriverSettingsScreen> createState() => _DriverSettingsScreenState();
}

class _DriverSettingsScreenState extends State<DriverSettingsScreen> {
  // ignore: unused_field
  static const _card = Color(0xFF1C1C1E);

  @override
  void initState() {
    super.initState();
    _enforceDriverRole();
  }

  void _enforceDriverRole() {
    UserSession.getMode().then((mode) {
      if (mode != 'driver' && mounted) {
        Navigator.of(context).pushAndRemoveUntil(
          fadeThroughRoute(const HomeScreen()),
          (_) => false,
        );
      }
    });
  }

  /// Whether any accessibility feature is currently enabled.
  /// Used to show the user that a11y settings are active.
  bool get _anyA11yEnabled {
    final n = accessibilityNotifier;
    return n.highContrast ||
        n.reduceMotion ||
        n.screenReaderHints ||
        n.colorBlindMode != 'none' ||
        n.textScale != 1.0;
  }

  @override
  Widget build(BuildContext context) {
    final top = MediaQuery.of(context).padding.top;
    final dc = DriverColors.of(context);
    return Scaffold(
      backgroundColor: neuBase,
      // The same speckled ground the driver menu that opens this carries.
      // On a flat neuBase the neumorphic rows float on nothing; the dots
      // give them a surface to be pressed into, which is the whole point
      // of the style — and arriving here from a dotted menu onto a flat
      // page reads as landing in a different app.
      body: Stack(
        children: [
          const Positioned.fill(child: NeuDotsBackdrop()),
          Column(
        children: [
          // ── Top bar ──
          Container(
            color: neuBase,
            padding: EdgeInsets.only(
              top: top + 8,
              bottom: 12,
              left: 16,
              right: 16,
            ),
            child: Stack(
              alignment: Alignment.center,
              children: [
                Align(
                  alignment: Alignment.centerLeft,
                  child: GestureDetector(
                    onTap: () => Navigator.pop(context),
                    child: Container(
                      width: 40,
                      height: 40,
                      decoration: neuBox(radius: 20),
                      child: Icon(
                        Icons.arrow_back_rounded,
                        color: dc.text,
                        size: 22,
                      ),
                    ),
                  ),
                ),
                Text(
                  S.of(context).settingsTitle,
                  style: TextStyle(
                    color: dc.text,
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

                const SizedBox(height: 28),

                // ═══ GENERAL SECTION ═══
                _sectionHeader(S.of(context).generalLabel),
                _navItem(
                  Icons.accessibility_new_rounded,
                  S.of(context).accessibilityLabel,
                  _anyA11yEnabled
                      ? 'On'
                      : S.of(context).accessibilityFeatures,
                  () => Navigator.push(
                    context,
                    slideFromRightRoute(const AccessibilityScreen()),
                  ),
                ),
                if (AppPlatform.isIOS)
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
              ],
            ),
          ),
        ],
          ),
        ],
      ),
    );
  }

  Widget _sectionHeader(String title) {
    final dc = DriverColors.of(context);
    return Padding(
      padding: const EdgeInsets.only(left: 20, bottom: 10),
      child: Text(
        title,
        style: TextStyle(
          color: dc.textSecondary,
          fontSize: 13,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.5,
        ),
      ),
    );
  }

  Widget _navItem(IconData icon, String title, String sub, VoidCallback onTap) {
    final dc = DriverColors.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 5),
      child: Container(
        decoration: neuBox(radius: 16),
        child: ListTile(
        onTap: () {
          HapticService.selectionClick();
          onTap();
        },
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        leading: Container(
          width: 42,
          height: 42,
          decoration: neuBox(radius: 13, pressed: true),
          child: Icon(icon, color: dc.icon, size: 20),
        ),
        title: Text(
          title,
          style: TextStyle(
            color: dc.text,
            fontSize: 15,
            fontWeight: FontWeight.w700,
          ),
        ),
        subtitle: Text(
          sub,
          style: TextStyle(color: dc.textSecondary, fontSize: 12),
        ),
        trailing: Icon(
          Icons.chevron_right_rounded,
          color: dc.divider,
          size: 20,
        ),
        ),
      ),
    );
  }


}
