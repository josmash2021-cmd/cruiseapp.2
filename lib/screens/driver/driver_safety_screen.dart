import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:share_plus/share_plus.dart';
import '../../l10n/app_localizations.dart';
import '../../services/api_service.dart';

// ═══════════════════════════════════════════════════════════════════════════
//  DRIVER SAFETY SCREEN — In-navigation safety actions
//  Accessible via shield button during active navigation
// ═══════════════════════════════════════════════════════════════════════════

class DriverSafetyScreen extends StatelessWidget {
  const DriverSafetyScreen({
    super.key,
    required this.tripId,
    required this.riderName,
    this.riderPhone = '',
    this.pickupAddress = '',
    this.dropoffAddress = '',
  });

  final int tripId;
  final String riderName;
  final String riderPhone;
  final String pickupAddress;
  final String dropoffAddress;

  static const _gold = Color(0xFFD4A843);
  static const _bg = Color(0xFF0A0E18);
  static const _card = Color(0xFF141824);

  @override
  Widget build(BuildContext context) {
    final top = MediaQuery.of(context).padding.top;

    return Scaffold(
      backgroundColor: _bg,
      body: SafeArea(
        top: false,
        child: Column(
          children: [
            SizedBox(height: top),
            // ── Header ──
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: Row(
                children: [
                  GestureDetector(
                    onTap: () => Navigator.of(context).pop(),
                    child: Container(
                      width: 40, height: 40,
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.08),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: const Icon(Icons.arrow_back_ios_new_rounded,
                          color: Colors.white, size: 18),
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Text(S.of(context).safetySection,
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 22,
                        fontWeight: FontWeight.w800)),
                  ),
                  const Icon(Icons.shield_rounded, color: _gold, size: 26),
                ],
              ),
            ),
            const SizedBox(height: 24),

            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // ── Emergency card ──
                    _emergencyCard(context),
                    const SizedBox(height: 16),

                    // ── Quick actions ──
                    Text(S.of(context).quickActions,
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.6),
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.8)),
                    const SizedBox(height: 10),

                    _actionCard(
                      icon: Icons.share_location_rounded,
                      title: 'Share Trip Status',
                      subtitle: 'Send your real-time location to a contact',
                      onTap: () async {
                        HapticFeedback.lightImpact();
                        try {
                          final result = await ApiService.shareTrip(tripId);
                          final shareUrl = result['share_url'] as String?;
                          if (shareUrl != null) {
                            final fullUrl = '${ApiService.publicBaseUrl}$shareUrl';
                            await Share.share(
                              'Track my Cruise trip live: $fullUrl',
                              subject: 'Cruise - Live Trip Tracking',
                            );
                          }
                        } catch (_) {
                          if (context.mounted) _showToast(context, 'Could not share trip');
                        }
                      },
                    ),
                    const SizedBox(height: 8),
                    _actionCard(
                      icon: Icons.report_problem_rounded,
                      title: 'Report Unsafe Rider',
                      subtitle: 'Flag unsafe behavior for review',
                      color: Colors.orange,
                      onTap: () {
                        HapticFeedback.mediumImpact();
                        _showReportSheet(context);
                      },
                    ),
                    const SizedBox(height: 8),
                    _actionCard(
                      icon: Icons.record_voice_over_rounded,
                      title: 'Record Audio',
                      subtitle: 'Start recording for your safety',
                      onTap: () {
                        HapticFeedback.lightImpact();
                        _showToast(context, 'Audio recording started');
                      },
                    ),

                    const SizedBox(height: 24),

                    // ── Trip info ──
                    Text(S.of(context).currentTrip,
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.6),
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.8)),
                    const SizedBox(height: 10),
                    _tripInfoCard(),

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

  Widget _emergencyCard(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            const Color(0xFFB71C1C).withValues(alpha: 0.3),
            const Color(0xFFB71C1C).withValues(alpha: 0.1),
          ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
            color: const Color(0xFFB71C1C).withValues(alpha: 0.4)),
      ),
      child: Row(
        children: [
          Container(
            width: 52, height: 52,
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(14),
            ),
            child: const Icon(Icons.emergency_rounded,
                color: Colors.white, size: 28),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(S.of(context).emergency,
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.w800)),
                const SizedBox(height: 3),
                Text(S.of(context).call911Help,
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.7),
                    fontSize: 13)),
              ],
            ),
          ),
          GestureDetector(
            onTap: () async {
              HapticFeedback.heavyImpact();
              final uri = Uri.parse('tel:911');
              if (await canLaunchUrl(uri)) await launchUrl(uri);
            },
            child: Container(
              width: 48, height: 48,
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(14),
              ),
              child: const Icon(Icons.call_rounded,
                  color: Color(0xFFB71C1C), size: 24),
            ),
          ),
        ],
      ),
    );
  }

  Widget _actionCard({
    required IconData icon,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
    Color color = _gold,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: _card,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
              color: Colors.white.withValues(alpha: 0.06)),
        ),
        child: Row(
          children: [
            Container(
              width: 42, height: 42,
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(icon, color: color, size: 22),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 15,
                      fontWeight: FontWeight.w700)),
                  const SizedBox(height: 2),
                  Text(subtitle,
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.5),
                      fontSize: 12)),
                ],
              ),
            ),
            Icon(Icons.chevron_right_rounded,
                color: Colors.white.withValues(alpha: 0.3), size: 20),
          ],
        ),
      ),
    );
  }

  Widget _tripInfoCard() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: _card,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
            color: Colors.white.withValues(alpha: 0.06)),
      ),
      child: Column(
        children: [
          _infoRow('Trip ID', '#$tripId'),
          const SizedBox(height: 10),
          _infoRow('Rider', riderName),
          if (pickupAddress.isNotEmpty) ...[
            const SizedBox(height: 10),
            _infoRow('Pickup', pickupAddress),
          ],
          if (dropoffAddress.isNotEmpty) ...[
            const SizedBox(height: 10),
            _infoRow('Dropoff', dropoffAddress),
          ],
        ],
      ),
    );
  }

  Widget _infoRow(String label, String value) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 72,
          child: Text(label,
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.45),
              fontSize: 12,
              fontWeight: FontWeight.w600)),
        ),
        Expanded(
          child: Text(value,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 13,
              fontWeight: FontWeight.w600),
            maxLines: 2,
            overflow: TextOverflow.ellipsis),
        ),
      ],
    );
  }

  void _showReportSheet(BuildContext context) {
    showModalBottomSheet(
      context: context,
      backgroundColor: _card,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                margin: const EdgeInsets.only(bottom: 16),
                width: 40, height: 4,
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.24),
                  borderRadius: BorderRadius.circular(2)),
              ),
              Text(S.of(context).reportIssue,
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 18,
                  fontWeight: FontWeight.w800)),
              const SizedBox(height: 16),
              _reportOption(ctx, 'Unsafe behavior'),
              _reportOption(ctx, 'Verbal harassment'),
              _reportOption(ctx, 'Intoxicated rider'),
              _reportOption(ctx, 'Suspicious activity'),
              _reportOption(ctx, 'Other concern'),
            ],
          ),
        ),
      ),
    );
  }

  Widget _reportOption(BuildContext ctx, String label) {
    return GestureDetector(
      onTap: () {
        Navigator.pop(ctx);
        _showToast(ctx, 'Report submitted: $label');
      },
      child: Container(
        width: double.infinity,
        margin: const EdgeInsets.only(bottom: 6),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.05),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Text(label,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 15,
            fontWeight: FontWeight.w600)),
      ),
    );
  }

  void _showToast(BuildContext context, String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Row(
          children: [
            const Icon(Icons.check_circle_rounded,
                color: _gold, size: 18),
            const SizedBox(width: 10),
            Expanded(
              child: Text(msg,
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w600,
                  fontSize: 13)),
            ),
          ],
        ),
        backgroundColor: const Color(0xFF1A1E2E),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12)),
        duration: const Duration(seconds: 3),
      ),
    );
  }
}
