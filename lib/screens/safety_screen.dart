import 'dart:async';
import 'package:flutter/material.dart';
import '../services/haptic_service.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:share_plus/share_plus.dart';
import 'package:geolocator/geolocator.dart';
import '../config/app_theme.dart';
import '../l10n/app_localizations.dart';
import '../services/api_service.dart';
import '../services/local_data_service.dart';
import '../widgets/neu_style.dart';
import '../utils/share_helper.dart';

class SafetyScreen extends StatefulWidget {
  const SafetyScreen({super.key});

  @override
  State<SafetyScreen> createState() => _SafetyScreenState();
}

class _SafetyScreenState extends State<SafetyScreen> {
  static const _gold = Color(0xFFE8C547);

  List<String> _trustedContacts = [];
  bool _isSendingSos = false;

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
      backgroundColor: neuBase,
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
                  decoration: neuBox(radius: 14, pressed: true),
                  child: Icon(
                    Icons.arrow_back_rounded,
                    color: c.textPrimary,
                    size: 22,
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
              _sectionHeader(c, S.of(context).safetyFeatures),

              Container(
                decoration: neuBox(radius: 20),
                child: Column(
                  children: [
                    _featureRow(
                      c,
                      icon: Icons.share_location_rounded,
                      title: S.of(context).shareMyTrip,
                      subtitle: S.of(context).shareMyTripDesc,
                      onTap: () => _shareTrip(context),
                    ),
                    _rowDivider(),
                    _featureRow(
                      c,
                      icon: Icons.verified_user_outlined,
                      title: S.of(context).verifyYourRide,
                      subtitle: S.of(context).verifyYourRideDesc,
                      onTap: () => _showVerifyTip(context, c),
                    ),
                    _rowDivider(),
                    _featureRow(
                      c,
                      icon: Icons.pin_drop_outlined,
                      title: S.of(context).trustedContacts,
                      subtitle: S.of(context).trustedContactsDesc,
                      onTap: () => _showTrustedContacts(context, c),
                    ),
                    _rowDivider(),
                    _featureRow(
                      c,
                      icon: Icons.phone_in_talk_rounded,
                      title: S.of(context).rideCheck,
                      subtitle: S.of(context).rideCheckDesc,
                      onTap: () => _showRideCheck(context, c),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              _policyInfoCard(c),

              const SizedBox(height: 28),

              // ── Safety tips ──
              _sectionHeader(c, S.of(context).safetyTips),
              Container(
                decoration: neuBox(radius: 20),
                child: Column(
                  children: [
                    _tipItem(c, '1', S.of(context).safetyTip1),
                    _rowDivider(indent: 60),
                    _tipItem(c, '2', S.of(context).safetyTip2),
                    _rowDivider(indent: 60),
                    _tipItem(c, '3', S.of(context).safetyTip3),
                    _rowDivider(indent: 60),
                    _tipItem(c, '4', S.of(context).safetyTip4),
                  ],
                ),
              ),

              const SizedBox(height: 32),
            ],
          ),
        ),
      ),
    );
  }

  Widget _sectionHeader(AppColors c, String title) {
    return Padding(
      padding: const EdgeInsets.only(left: 6, bottom: 10),
      child: Text(
        title.toUpperCase(),
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w700,
          letterSpacing: 1.2,
          color: c.textTertiary,
        ),
      ),
    );
  }

  Widget _rowDivider({double indent = 68}) {
    return Divider(
      height: 1,
      indent: indent,
      color: Colors.white.withValues(alpha: 0.05),
    );
  }

  Widget _emergencyCard(AppColors c, BuildContext context) {
    const red = Color(0xFFFF5252);
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: neuBox(radius: 20),
      child: Column(
        children: [
          Row(
            children: [
              Container(
                width: 48,
                height: 48,
                decoration: neuBox(radius: 14, pressed: true),
                child: const Icon(
                  Icons.emergency_rounded,
                  color: red,
                  size: 26,
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      S.of(context).emergency,
                      style: TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w700,
                        color: c.textPrimary,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      S.of(context).call911Assistance,
                      style: TextStyle(
                        fontSize: 13,
                        color: c.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
              GestureDetector(
                onTap: () async {
                  HapticService.heavyImpact();
                  final uri = Uri.parse('tel:911');
                  if (await canLaunchUrl(uri)) await launchUrl(uri);
                },
                child: Semantics(
                  label: S.of(context).call911Emergency,
                  button: true,
                  child: Container(
                    width: 44,
                    height: 44,
                    decoration: neuBox(radius: 14, pressed: true),
                    child: const Icon(
                      Icons.call_rounded,
                      color: red,
                      size: 22,
                    ),
                  ),
                ),
              ),
            ],
          ),
          if (_trustedContacts.isNotEmpty) ...[
            const SizedBox(height: 14),
            GestureDetector(
              onTap: _isSendingSos ? null : _alertAllContacts,
              child: Container(
                width: double.infinity,
                height: 50,
                decoration: neuBox(radius: 16, pressed: true),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    if (_isSendingSos)
                      const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: red,
                        ),
                      )
                    else
                      const Icon(Icons.sms_rounded, size: 18, color: red),
                    const SizedBox(width: 8),
                    Text(
                      _isSendingSos
                          ? 'Sending...'
                          : 'Alert ${_trustedContacts.length} contact${_trustedContacts.length > 1 ? 's' : ''}',
                      style: const TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 13,
                        color: red,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _featureRow(
    AppColors c, {
    required IconData icon,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: Row(
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: neuBox(radius: 14, pressed: true),
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
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                      color: c.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: TextStyle(fontSize: 12, color: c.textTertiary),
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

  Widget _policyInfoCard(AppColors c) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
      decoration: neuBox(radius: 18),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: neuBox(radius: 14, pressed: true),
            child: const Icon(
              Icons.escalator_warning_rounded,
              color: _gold,
              size: 22,
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Text(
              S.of(context).safetyMinorsPolicy,
              style: TextStyle(
                fontSize: 13,
                color: c.textSecondary,
                height: 1.4,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _tipItem(AppColors c, String number, String text) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      child: Row(
        children: [
          Container(
            width: 30,
            height: 30,
            decoration: neuBox(radius: 10, pressed: true),
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

  Future<void> _alertAllContacts() async {
    if (_isSendingSos || _trustedContacts.isEmpty) return;
    setState(() => _isSendingSos = true);
    HapticService.heavyImpact();

    try {
      // Get current location
      Position pos;
      try {
        pos = await Geolocator.getCurrentPosition(
          locationSettings: const LocationSettings(accuracy: LocationAccuracy.high),
        ).timeout(const Duration(seconds: 5));
      } catch (_) {
        pos = await Geolocator.getLastKnownPosition().then(
          (p) => p ?? Position(
            latitude: 0,
            longitude: 0,
            timestamp: DateTime.now(),
            accuracy: 0,
            altitude: 0,
            altitudeAccuracy: 0,
            heading: 0,
            headingAccuracy: 0,
            speed: 0,
            speedAccuracy: 0,
          ),
        );
      }

      final phones = _trustedContacts
          .map((c) => c.split('|').length > 1 ? c.split('|')[1] : '')
          .where((p) => p.isNotEmpty)
          .toList();

      if (phones.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(S.of(context).noPhoneContacts)),
          );
        }
        setState(() => _isSendingSos = false);
        return;
      }

      await ApiService.sendSosAlert(
        lat: pos.latitude,
        lng: pos.longitude,
        tripId: 0,
        contactPhones: phones,
      );

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(S.of(context).emergencyAlertSentTo(phones.length)),
            backgroundColor: const Color(0xFFDC2626),
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to send alert: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _isSendingSos = false);
    }
  }

  void _shareTrip(BuildContext context) {
    HapticService.selectionClick();
    unawaited(shareText(
      context,
      'I\'m riding with Cruise! Track my trip live for safety. '
      'Download Cruise at ${ApiService.publicBaseUrl} 🚗',
    ));
  }

  void _showVerifyTip(BuildContext context, AppColors c) {
    HapticService.selectionClick();
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) => Container(
        padding: const EdgeInsets.all(28),
        decoration: const BoxDecoration(
          color: neuBase,
          borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
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
              decoration: neuBox(radius: 16, pressed: true),
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
              height: 54,
              child: ElevatedButton(
                onPressed: () => Navigator.pop(ctx),
                style: ElevatedButton.styleFrom(
                  backgroundColor: _gold,
                  foregroundColor: Colors.black,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
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
    HapticService.selectionClick();
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
          decoration: const BoxDecoration(
            color: neuBase,
            borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
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
                          backgroundColor: neuSurface,
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
                                S.of(context).cancel,
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
                      decoration: neuBox(radius: 12, pressed: true),
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
                      decoration: neuBox(radius: 14, pressed: true),
                      child: Row(
                        children: [
                          Container(
                            width: 40,
                            height: 40,
                            decoration: neuBox(radius: 20),
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
                            child: const Icon(
                              Icons.remove_circle_outline,
                              color: Color(0xFFFF5252),
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

  void _showRideCheck(BuildContext context, AppColors c) {
    showModalBottomSheet(
      context: context,
      backgroundColor: neuBase,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      builder: (_) => Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: c.textTertiary.withValues(alpha: 0.3),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 20),
            Icon(Icons.phone_in_talk_rounded, size: 48, color: _gold),
            const SizedBox(height: 16),
            Text(
              S.of(context).rideCheck,
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.w700,
                color: c.textPrimary,
              ),
            ),
            const SizedBox(height: 12),
            Text(
              S.of(context).rideCheckFullDesc,
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 14, color: c.textSecondary),
            ),
            const SizedBox(height: 24),
            SizedBox(
              width: double.infinity,
              height: 54,
              child: ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: _gold,
                  foregroundColor: Colors.black,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                  ),
                ),
                onPressed: () {
                  Navigator.pop(context);
                  _shareLocation(context, c);
                },
                child: Text(
                  S.of(context).shareLocationNow,
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
              ),
            ),
            const SizedBox(height: 12),
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(
                S.of(context).close,
                style: TextStyle(color: c.textSecondary),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _shareLocation(BuildContext context, AppColors c) {
    unawaited(shareText(context, S.of(context).rideCheckShareText));
  }
}
