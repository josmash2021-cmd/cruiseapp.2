import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:permission_handler/permission_handler.dart'
    show openAppSettings;

import '../l10n/app_localizations.dart';
import '../services/notification_service.dart';
import '../widgets/neu_style.dart';

/// Cold-start permissions page for a signed-in rider.
///
/// This is NOT the system dialog — iOS shows that one once per install and
/// then never again. When the rider comes back with a session and location
/// or notifications are still off, this page says so honestly and sends them
/// to Settings. The X dismisses it for the session (the caller holds a
/// per-process latch); it reappears on the next cold start while something
/// is still missing.
class RiderPermissionsScreen extends StatefulWidget {
  const RiderPermissionsScreen({super.key});

  @override
  State<RiderPermissionsScreen> createState() => _RiderPermissionsScreenState();
}

class _RiderPermissionsScreenState extends State<RiderPermissionsScreen>
    with WidgetsBindingObserver {
  static const _gold = Color(0xFFE8C547);

  bool _locationOk = false;
  bool _notifOk = false;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refresh();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Back from Settings — re-read and close if everything is now on.
    if (state == AppLifecycleState.resumed) _refresh();
  }

  Future<void> _refresh() async {
    bool locOk = false;
    bool notifOk = false;
    try {
      final p = await Geolocator.checkPermission();
      locOk = p == LocationPermission.always ||
          p == LocationPermission.whileInUse;
      notifOk = await NotificationService.isPermissionGranted();
    } catch (_) {}
    if (!mounted) return;
    setState(() {
      _locationOk = locOk;
      _notifOk = notifOk;
      _loading = false;
    });
    if (locOk && notifOk) Navigator.of(context).maybePop();
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final top = MediaQuery.of(context).padding.top;
    return Scaffold(
      backgroundColor: neuBase,
      body: Stack(
        children: [
          const Positioned.fill(child: NeuDotsBackdrop()),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(height: top + 8),
                  Row(
                    children: [
                      const Spacer(),
                      // Dismisses for this session only — the per-process
                      // latch lives in home_screen's permission flow.
                      GestureDetector(
                        onTap: () => Navigator.of(context).pop(),
                        child: Container(
                          width: 38,
                          height: 38,
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha: 0.06),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: const Icon(Icons.close_rounded,
                              color: Colors.white70, size: 20),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 18),
                  Text(
                    s.permsTitle,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 26,
                      fontWeight: FontWeight.w800,
                      letterSpacing: -0.5,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    s.permsSubtitle,
                    style: const TextStyle(
                      color: Colors.white54,
                      fontSize: 14,
                      height: 1.4,
                    ),
                  ),
                  const SizedBox(height: 28),
                  _permRow(
                    icon: Icons.location_on_rounded,
                    title: s.permsLocation,
                    desc: s.permsLocationDesc,
                    granted: _locationOk,
                    enabledLabel: s.permsEnabled,
                    missingLabel: s.permsMissing,
                  ),
                  const SizedBox(height: 14),
                  _permRow(
                    icon: Icons.notifications_rounded,
                    title: s.permsNotifications,
                    desc: s.permsNotificationsDesc,
                    granted: _notifOk,
                    enabledLabel: s.permsEnabled,
                    missingLabel: s.permsMissing,
                  ),
                  const Spacer(),
                  SizedBox(
                    width: double.infinity,
                    height: 52,
                    child: ElevatedButton(
                      onPressed: _loading ? null : () => openAppSettings(),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: _gold,
                        foregroundColor: Colors.black,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(16),
                        ),
                        elevation: 0,
                      ),
                      child: Text(
                        s.openSettings,
                        style: const TextStyle(
                            fontSize: 16, fontWeight: FontWeight.w800),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _permRow({
    required IconData icon,
    required String title,
    required String desc,
    required bool granted,
    required String enabledLabel,
    required String missingLabel,
  }) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: neuBox(radius: 18),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: _gold.withValues(alpha: granted ? 0.16 : 0.08),
              borderRadius: BorderRadius.circular(14),
            ),
            child: Icon(icon, color: _gold, size: 22),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        title,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 3),
                      decoration: BoxDecoration(
                        color: granted
                            ? const Color(0xFF4CAF50).withValues(alpha: 0.14)
                            : const Color(0xFFEF4444).withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        granted ? enabledLabel : missingLabel,
                        style: TextStyle(
                          color: granted
                              ? const Color(0xFF4CAF50)
                              : const Color(0xFFEF4444),
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  desc,
                  style: const TextStyle(
                    color: Colors.white54,
                    fontSize: 12.5,
                    height: 1.4,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
