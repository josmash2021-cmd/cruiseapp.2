import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:share_plus/share_plus.dart';
import '../config/app_theme.dart';
import '../l10n/app_localizations.dart';
import '../services/local_data_service.dart';

class SafetyScreen extends StatefulWidget {
  const SafetyScreen({super.key});

  @override
  State<SafetyScreen> createState() => _SafetyScreenState();
}

class _SafetyScreenState extends State<SafetyScreen> {
  static const _gold = Color(0xFFE8C547);

  List<String> _trustedContacts = [];

  @override
  void initState() {
    super.initState();
    _loadContacts();
  }

  Future<void> _loadContacts() async {
    final saved = await LocalDataService.getStringList('trusted_contacts');
    if (mounted) setState(() => _trustedContacts = saved ?? []);
  }

  Future<void> _saveContacts() async {
    await LocalDataService.saveStringList('trusted_contacts', _trustedContacts);
  }

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);

    return Scaffold(
      backgroundColor: c.bg,
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SizedBox(height: 8),

              // ── Back button ──
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
              const SizedBox(height: 28),

              Text(
                S.of(context).safetyTitle,
                style: TextStyle(
                  fontSize: 28,
                  fontWeight: FontWeight.w800,
                  color: c.textPrimary,
                  letterSpacing: -0.5,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                S.of(context).safetySubtitle,
                style: TextStyle(fontSize: 15, color: c.textSecondary),
              ),
              const SizedBox(height: 28),

              // ── Emergency ──
              _emergencyCard(c, context),
              const SizedBox(height: 24),

              // ── Safety features ──
              Text(
                S.of(context).safetyFeatures,
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                  color: c.textPrimary,
                ),
              ),
              const SizedBox(height: 12),

              _featureCard(
                c,
                icon: Icons.share_location_rounded,
                title: S.of(context).shareMyTrip,
                subtitle: S.of(context).shareMyTripDesc,
                onTap: () => _shareTrip(context),
              ),
              const SizedBox(height: 10),
              _featureCard(
                c,
                icon: Icons.verified_user_outlined,
                title: S.of(context).verifyYourRide,
                subtitle: S.of(context).verifyYourRideDesc,
                onTap: () => _showVerifyTip(context, c),
              ),
              const SizedBox(height: 10),
              _featureCard(
                c,
                icon: Icons.pin_drop_outlined,
                title: S.of(context).trustedContacts,
                subtitle: S.of(context).trustedContactsDesc,
                onTap: () => _showTrustedContacts(context, c),
              ),
              const SizedBox(height: 10),
              _featureCard(
                c,
                icon: Icons.phone_in_talk_rounded,
                title: S.of(context).rideCheck,
                subtitle: S.of(context).rideCheckDesc,
                onTap: () => _showComingSoon(context, c),
              ),
              const SizedBox(height: 10),
              _featureCard(
                c,
                icon: Icons.record_voice_over_outlined,
                title: S.of(context).audioRecording,
                subtitle: S.of(context).audioRecordingDesc,
                onTap: () => _showComingSoon(context, c),
              ),

              const SizedBox(height: 28),

              // ── Safety tips ──
              Text(
                S.of(context).safetyTips,
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                  color: c.textPrimary,
                ),
              ),
              const SizedBox(height: 12),
              _tipItem(c, '1', S.of(context).safetyTip1),
              const SizedBox(height: 8),
              _tipItem(c, '2', S.of(context).safetyTip2),
              const SizedBox(height: 8),
              _tipItem(c, '3', S.of(context).safetyTip3),
              const SizedBox(height: 8),
              _tipItem(c, '4', S.of(context).safetyTip4),

              const SizedBox(height: 32),
            ],
          ),
        ),
      ),
    );
  }

  Widget _emergencyCard(AppColors c, BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white.withValues(alpha: 0.3)),
      ),
      child: Row(
        children: [
          Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(14),
            ),
            child: const Icon(
              Icons.emergency_rounded,
              color: Colors.white,
              size: 26,
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Emergency',
                  style: TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w700,
                    color: c.textPrimary,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  'Call 911 for immediate assistance',
                  style: TextStyle(fontSize: 13, color: c.textSecondary),
                ),
              ],
            ),
          ),
          GestureDetector(
            onTap: () async {
              final uri = Uri.parse('tel:911');
              if (await canLaunchUrl(uri)) await launchUrl(uri);
            },
            child: Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(12),
              ),
              child: const Icon(
                Icons.call_rounded,
                color: Colors.black,
                size: 22,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _featureCard(
    AppColors c, {
    required IconData icon,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
        decoration: BoxDecoration(
          color: c.surface,
          borderRadius: BorderRadius.circular(14),
          border: c.isDark
              ? null
              : Border.all(color: Colors.black.withValues(alpha: 0.06)),
        ),
        child: Row(
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: _gold.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(icon, color: _gold, size: 22),
            ),
            const SizedBox(width: 14),
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
            Icon(Icons.chevron_right_rounded, color: c.textTertiary, size: 20),
          ],
        ),
      ),
    );
  }

  Widget _tipItem(AppColors c, String number, String text) {
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
          Container(
            width: 30,
            height: 30,
            decoration: BoxDecoration(
              color: _gold.withValues(alpha: 0.12),
              shape: BoxShape.circle,
            ),
            child: Center(
              child: Text(
                number,
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                  color: _gold,
                ),
              ),
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Text(
              text,
              style: TextStyle(fontSize: 14, color: c.textPrimary, height: 1.3),
            ),
          ),
        ],
      ),
    );
  }

  void _shareTrip(BuildContext context) {
    HapticFeedback.selectionClick();
    Share.share('I\'m riding with Cruise! Track my trip live for safety. 🚗');
  }

  void _showVerifyTip(BuildContext context, AppColors c) {
    HapticFeedback.selectionClick();
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) => Container(
        padding: const EdgeInsets.all(28),
        decoration: BoxDecoration(
          color: c.surface,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: Colors.white12,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 24),
            Container(
              width: 56,
              height: 56,
              decoration: BoxDecoration(
                color: _gold.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(16),
              ),
              child: const Icon(
                Icons.verified_user_rounded,
                color: _gold,
                size: 28,
              ),
            ),
            const SizedBox(height: 16),
            Text(
              'How to verify your ride',
              style: TextStyle(
                color: c.textPrimary,
                fontSize: 20,
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 12),
            Text(
              'Before entering the vehicle:\n\n'
              '1. Check the license plate matches your app\n'
              '2. Ask the driver "Who are you here for?"\n'
              '3. Verify the driver\'s name and photo\n'
              '4. Check the vehicle make and color',
              style: TextStyle(
                color: c.textSecondary,
                fontSize: 15,
                height: 1.5,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            SizedBox(
              width: double.infinity,
              height: 50,
              child: ElevatedButton(
                onPressed: () => Navigator.pop(ctx),
                style: ElevatedButton.styleFrom(
                  backgroundColor: _gold,
                  foregroundColor: Colors.black,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                ),
                child: const Text(
                  'Got it',
                  style: TextStyle(fontWeight: FontWeight.w700),
                ),
              ),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  void _showTrustedContacts(BuildContext context, AppColors c) {
    HapticFeedback.selectionClick();
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheetState) => Container(
          padding: const EdgeInsets.all(28),
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(ctx).size.height * 0.7,
          ),
          decoration: BoxDecoration(
            color: c.surface,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.white12,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(height: 20),
              Row(
                children: [
                  Text(
                    'Trusted Contacts',
                    style: TextStyle(
                      color: c.textPrimary,
                      fontSize: 20,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const Spacer(),
                  GestureDetector(
                    onTap: () {
                      final nameCtrl = TextEditingController();
                      final phoneCtrl = TextEditingController();
                      showDialog(
                        context: ctx,
                        builder: (dCtx) => AlertDialog(
                          backgroundColor: c.surface,
                          title: Text(
                            'Add contact',
                            style: TextStyle(color: c.textPrimary),
                          ),
                          content: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              TextField(
                                controller: nameCtrl,
                                style: TextStyle(color: c.textPrimary),
                                decoration: InputDecoration(
                                  hintText: 'Name',
                                  hintStyle: TextStyle(color: c.textTertiary),
                                ),
                              ),
                              const SizedBox(height: 8),
                              TextField(
                                controller: phoneCtrl,
                                keyboardType: TextInputType.phone,
                                style: TextStyle(color: c.textPrimary),
                                decoration: InputDecoration(
                                  hintText: 'Phone number',
                                  hintStyle: TextStyle(color: c.textTertiary),
                                ),
                              ),
                            ],
                          ),
                          actions: [
                            TextButton(
                              onPressed: () => Navigator.pop(dCtx),
                              child: Text(
                                'Cancel',
                                style: TextStyle(color: c.textSecondary),
                              ),
                            ),
                            TextButton(
                              onPressed: () {
                                final name = nameCtrl.text.trim();
                                final phone = phoneCtrl.text.trim();
                                if (name.isNotEmpty && phone.isNotEmpty) {
                                  setState(() {
                                    _trustedContacts.add('$name|$phone');
                                  });
                                  setSheetState(() {});
                                  _saveContacts();
                                  Navigator.pop(dCtx);
                                }
                              },
                              child: const Text(
                                'Add',
                                style: TextStyle(color: _gold),
                              ),
                            ),
                          ],
                        ),
                      );
                    },
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 6,
                      ),
                      decoration: BoxDecoration(
                        color: _gold.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: const Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.add_rounded, color: _gold, size: 16),
                          SizedBox(width: 4),
                          Text(
                            'Add',
                            style: TextStyle(
                              color: _gold,
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              if (_trustedContacts.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 32),
                  child: Column(
                    children: [
                      Icon(
                        Icons.people_outline_rounded,
                        color: c.textTertiary,
                        size: 48,
                      ),
                      const SizedBox(height: 12),
                      Text(
                        'No trusted contacts yet',
                        style: TextStyle(color: c.textSecondary, fontSize: 15),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'Add contacts who can follow your trips',
                        style: TextStyle(color: c.textTertiary, fontSize: 13),
                      ),
                    ],
                  ),
                )
              else
                ...List.generate(_trustedContacts.length, (i) {
                  final parts = _trustedContacts[i].split('|');
                  final name = parts.isNotEmpty ? parts[0] : 'Unknown';
                  final phone = parts.length > 1 ? parts[1] : '';
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Container(
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: c.bg,
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: Row(
                        children: [
                          Container(
                            width: 40,
                            height: 40,
                            decoration: BoxDecoration(
                              color: _gold.withValues(alpha: 0.12),
                              shape: BoxShape.circle,
                            ),
                            child: Center(
                              child: Text(
                                name.isNotEmpty ? name[0].toUpperCase() : '?',
                                style: const TextStyle(
                                  color: _gold,
                                  fontWeight: FontWeight.w700,
                                  fontSize: 16,
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  name,
                                  style: TextStyle(
                                    color: c.textPrimary,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                if (phone.isNotEmpty)
                                  Text(
                                    phone,
                                    style: TextStyle(
                                      color: c.textSecondary,
                                      fontSize: 13,
                                    ),
                                  ),
                              ],
                            ),
                          ),
                          GestureDetector(
                            onTap: () {
                              setState(() {
                                _trustedContacts.removeAt(i);
                              });
                              setSheetState(() {});
                              _saveContacts();
                            },
                            child: Icon(
                              Icons.remove_circle_outline,
                              color: Colors.redAccent.withValues(alpha: 0.6),
                              size: 22,
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                }),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
  }

  void _showComingSoon(BuildContext context, AppColors c) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: const Text('Coming soon'),
        backgroundColor: c.isDark ? c.surface : Colors.black87,
        duration: const Duration(seconds: 1),
      ),
    );
  }
}
