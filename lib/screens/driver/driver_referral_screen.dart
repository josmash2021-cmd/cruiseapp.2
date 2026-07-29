import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../services/haptic_service.dart';
import 'package:share_plus/share_plus.dart';
import 'package:cached_network_image/cached_network_image.dart';

import '../../l10n/app_localizations.dart';
import '../../services/api_service.dart';
import '../../utils/share_helper.dart';

/// Refer Friends — DRIVER program.
///
/// Distinct from the rider Cruise Cash referrals (lib/screens/referral_screen.dart).
/// Drivers share their unique code; when another person signs up as a
/// driver using that code AND completes N rides as a driver within the
/// expiry window (default 50 rides / 60 days), the referrer earns a
/// flat cash bonus (default $200) credited to their pending_balance and
/// cashable in the next payout.
///
/// All numbers come from the backend (configurable via AppConfig).
class DriverReferralScreen extends StatefulWidget {
  const DriverReferralScreen({super.key});

  @override
  State<DriverReferralScreen> createState() => _DriverReferralScreenState();
}

class _DriverReferralScreenState extends State<DriverReferralScreen> {
  static const _gold = Color(0xFFE8C547);
  static const _surface = Color(0xFF1A1A1F);
  static const _surfaceLight = Color(0xFF222226);

  bool _loading = true;
  String _code = '';
  int _amountCents = 20000;
  int _ridesRequired = 50;
  int _expiryDays = 60;
  int _totalEarnedCents = 0;
  int _pendingCents = 0;
  List<Map<String, dynamic>> _referees = const [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final data = await ApiService.getMyDriverReferralInfo();
      if (!mounted) return;
      final settings =
          (data['settings'] as Map?)?.cast<String, dynamic>() ?? const {};
      setState(() {
        _code = (data['code'] as String?) ?? '';
        _amountCents = (settings['amount_cents'] as int?) ?? 20000;
        _ridesRequired = (settings['rides_required'] as int?) ?? 50;
        _expiryDays = (settings['expiry_days'] as int?) ?? 60;
        _totalEarnedCents = (data['total_earned_cents'] as int?) ?? 0;
        _pendingCents = (data['pending_cents'] as int?) ?? 0;
        _referees = ((data['referees'] as List?) ?? const [])
            .cast<Map<String, dynamic>>();
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _loading = false);
    }
  }

  String _dollars(int cents) => '\$${(cents / 100).toStringAsFixed(0)}';

  void _copyCode() {
    if (_code.isEmpty) return;
    HapticService.lightImpact();
    Clipboard.setData(ClipboardData(text: _code));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(S.of(context).codeCopied),
        backgroundColor: _gold,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    );
  }

  void _shareInvite() {
    if (_code.isEmpty) return;
    HapticService.mediumImpact();
    final amount = _dollars(_amountCents);
    final rides = _ridesRequired;
    final s = S.of(context);
    final text =
        '${s.driverShareIntro(amount)}\n\n'
        '${s.driverShareSteps(rides)}\n\n'
        'Code: $_code\n'
        'https://cruiseinride.com/drive/$_code';
    unawaited(shareText(context, text, subject: s.driverShareSubject));
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: _loading
            ? const Center(
                child: CircularProgressIndicator(color: _gold, strokeWidth: 2),
              )
            : RefreshIndicator(
                color: _gold,
                onRefresh: _load,
                child: ListView(
                  physics: const AlwaysScrollableScrollPhysics(
                    parent: BouncingScrollPhysics(),
                  ),
                  padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
                  children: [
                    // ── Top bar ──
                    Row(
                      children: [
                        GestureDetector(
                          onTap: () => Navigator.of(context).pop(),
                          child: Container(
                            width: 40,
                            height: 40,
                            decoration: BoxDecoration(
                              color: _surface,
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: const Icon(
                              Icons.arrow_back_ios_new_rounded,
                              color: Colors.white,
                              size: 18,
                            ),
                          ),
                        ),
                        const SizedBox(width: 16),
                        Text(
                          s.referFriends,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 22,
                            fontWeight: FontWeight.w800,
                            letterSpacing: -0.4,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 24),

                    // ── Hero card: amount + share ──
                    _buildHeroCard(s),
                    const SizedBox(height: 14),

                    // ── Code chip ──
                    _buildCodeCard(s),
                    const SizedBox(height: 14),

                    // ── Aggregate stats (earned / pending / referrals) ──
                    _buildStats(s),
                    const SizedBox(height: 14),

                    // ── How it works ──
                    _buildInfoCard(
                      title: s.howItWorksTitle,
                      icon: Icons.info_outline_rounded,
                      iconColor: _gold,
                      lines: [
                        s.driverHowStep1,
                        s.driverHowStep2(_ridesRequired, _expiryDays),
                        s.driverHowStep3(_dollars(_amountCents)),
                      ],
                    ),
                    const SizedBox(height: 12),

                    _buildInfoCard(
                      title: s.noLimitTitle,
                      icon: Icons.all_inclusive_rounded,
                      iconColor: _gold,
                      lines: [s.noLimitDesc],
                    ),

                    // ── Referees list ──
                    if (_referees.isNotEmpty) ...[
                      const SizedBox(height: 24),
                      Padding(
                        padding: const EdgeInsets.only(left: 4, bottom: 10),
                        child: Text(
                          s.yourReferrals,
                          style: const TextStyle(
                            color: Color(0xFFB0B0B6),
                            fontSize: 12,
                            fontWeight: FontWeight.w800,
                            letterSpacing: 1.2,
                          ),
                        ),
                      ),
                      ..._referees.map((r) => Padding(
                            padding: const EdgeInsets.only(bottom: 10),
                            child: _buildRefereeRow(r, s),
                          )),
                    ],
                  ],
                ),
              ),
      ),
    );
  }

  Widget _buildHeroCard(S s) {
    return Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: _surface,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: _gold.withValues(alpha: 0.18)),
        boxShadow: [
          BoxShadow(
            color: _gold.withValues(alpha: 0.06),
            blurRadius: 22,
            spreadRadius: 1,
          ),
        ],
      ),
      child: Column(
        children: [
          Text(
            s.driverEarnHero(_dollars(_amountCents)),
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: _gold,
              fontSize: 36,
              fontWeight: FontWeight.w900,
              letterSpacing: -0.5,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            s.driverEarnSub(_ridesRequired, _expiryDays),
            textAlign: TextAlign.center,
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.65),
              fontSize: 13.5,
              height: 1.45,
            ),
          ),
          const SizedBox(height: 22),
          SizedBox(
            width: double.infinity,
            height: 52,
            child: ElevatedButton.icon(
              onPressed: _code.isEmpty ? null : _shareInvite,
              icon: const Icon(Icons.share_rounded, size: 18),
              label: Text(
                s.shareInviteLinkBtn,
                style: const TextStyle(
                  fontSize: 15.5,
                  fontWeight: FontWeight.w800,
                ),
              ),
              style: ElevatedButton.styleFrom(
                backgroundColor: _gold,
                foregroundColor: Colors.black,
                disabledBackgroundColor:
                    _gold.withValues(alpha: 0.35),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                ),
                elevation: 0,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCodeCard(S s) {
    return GestureDetector(
      onTap: _copyCode,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
        decoration: BoxDecoration(
          color: _surface,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
        ),
        child: Row(
          children: [
            const Icon(Icons.qr_code_rounded, color: _gold, size: 22),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    s.yourCode,
                    style: const TextStyle(
                      color: Color(0xFFB0B0B6),
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 1,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    _code.isEmpty ? '— — —' : _code,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 17,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 0.4,
                    ),
                  ),
                ],
              ),
            ),
            const Icon(Icons.copy_rounded,
                color: Color(0xFFB0B0B6), size: 18),
          ],
        ),
      ),
    );
  }

  Widget _buildStats(S s) {
    return Row(
      children: [
        Expanded(child: _statCard(s.earnedLabel, _dollars(_totalEarnedCents))),
        const SizedBox(width: 10),
        Expanded(child: _statCard(s.pendingLabel, _dollars(_pendingCents))),
        const SizedBox(width: 10),
        Expanded(
            child:
                _statCard(s.referralsLabel, _referees.length.toString())),
      ],
    );
  }

  Widget _statCard(String label, String value) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 10),
      decoration: BoxDecoration(
        color: _surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
      ),
      child: Column(
        children: [
          Text(
            value,
            style: const TextStyle(
              color: _gold,
              fontSize: 19,
              fontWeight: FontWeight.w900,
              letterSpacing: -0.3,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            label,
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: Color(0xFFB0B0B6),
              fontSize: 11,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildInfoCard({
    required String title,
    required IconData icon,
    required Color iconColor,
    required List<String> lines,
  }) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: _surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: iconColor, size: 20),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 14,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 6),
                ...lines.map((line) => Padding(
                      padding: const EdgeInsets.only(bottom: 4),
                      child: Text(
                        line,
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.65),
                          fontSize: 13,
                          height: 1.45,
                        ),
                      ),
                    )),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildRefereeRow(Map<String, dynamic> r, S s) {
    final name = (r['name'] as String?)?.trim().isNotEmpty == true
        ? r['name'] as String
        : 'Driver';
    final photoUrl = r['photo_url'] as String?;
    final status = (r['status'] as String?) ?? 'pending';
    final ridesDone = (r['rides_completed'] as int?) ?? 0;
    final ridesNeeded = (r['rides_required'] as int?) ?? _ridesRequired;
    final progress = ridesNeeded > 0
        ? (ridesDone / ridesNeeded).clamp(0.0, 1.0)
        : 0.0;

    final Color statusColor;
    final String statusLabel;
    switch (status) {
      case 'qualified':
        statusColor = const Color(0xFF22C55E);
        statusLabel = s.statusPaid;
        break;
      case 'expired':
        statusColor = const Color(0xFFEF4444);
        statusLabel = s.statusExpired;
        break;
      default:
        statusColor = _gold;
        statusLabel = s.statusInProgress;
    }

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: _surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
      ),
      child: Column(
        children: [
          Row(
            children: [
              CircleAvatar(
                radius: 18,
                backgroundColor: _surfaceLight,
                backgroundImage: (photoUrl != null && photoUrl.isNotEmpty)
                    ? CachedNetworkImageProvider(photoUrl)
                    : null,
                child: (photoUrl == null || photoUrl.isEmpty)
                    ? Text(
                        name.isNotEmpty ? name[0].toUpperCase() : 'D',
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w700,
                        ),
                      )
                    : null,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      name,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    Text(
                      '$ridesDone / $ridesNeeded ${s.ridesLabel}',
                      style: const TextStyle(
                        color: Color(0xFFB0B0B6),
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: statusColor.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(10),
                  border:
                      Border.all(color: statusColor.withValues(alpha: 0.4)),
                ),
                child: Text(
                  statusLabel,
                  style: TextStyle(
                    color: statusColor,
                    fontSize: 11,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 0.3,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: progress,
              minHeight: 5,
              backgroundColor: Colors.white.withValues(alpha: 0.08),
              valueColor: AlwaysStoppedAnimation<Color>(statusColor),
            ),
          ),
        ],
      ),
    );
  }
}
