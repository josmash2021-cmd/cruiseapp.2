import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../services/haptic_service.dart';
import 'package:share_plus/share_plus.dart';
import 'package:cached_network_image/cached_network_image.dart';

import '../../l10n/app_localizations.dart';
import '../../services/api_service.dart';
import '../../widgets/neu_style.dart';
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

  /// Milestone schedule from the backend (falls back to the flat totals).
  int _m1Rides = 50;
  int _m1Cents = 5000;
  int _m2Rides = 200;
  int _m2Cents = 15000;
  int _refereeBonusCents = 2500;
  int _refereeBonusRides = 2;

  // Redeem-someone-else's-code mini form (driver who skipped it at signup)
  final _redeemCtl = TextEditingController();
  bool _redeeming = false;
  String? _redeemError;
  String? _redeemSuccess;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _redeemCtl.dispose();
    super.dispose();
  }

  Future<void> _redeem() async {
    final s = S.of(context);
    final code = _redeemCtl.text.trim().toUpperCase();
    if (code.isEmpty) return;
    setState(() {
      _redeeming = true;
      _redeemError = null;
      _redeemSuccess = null;
    });
    try {
      final res = await ApiService.redeemDriverReferralCode(code);
      if (!mounted) return;
      _redeemCtl.clear();
      setState(() {
        _redeeming = false;
        _redeemSuccess = (res['referrer_name'] as String?) != null
            ? s.linkedToName(res['referrer_name'] as String)
            : s.codeRedeemed;
      });
      HapticService.mediumImpact();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _redeeming = false;
        _redeemError = e.toString().replaceFirst('ApiException: ', '');
      });
      HapticService.heavyImpact();
    }
  }

  Future<void> _load() async {
    try {
      final data = await ApiService.getMyDriverReferralInfo();
      if (!mounted) return;
      final settings =
          (data['settings'] as Map?)?.cast<String, dynamic>() ?? const {};
      final milestones = (settings['milestones'] as List?) ?? const [];
      setState(() {
        _code = (data['code'] as String?) ?? '';
        _amountCents = (settings['amount_cents'] as int?) ?? 20000;
        _ridesRequired = (settings['rides_required'] as int?) ?? 200;
        _expiryDays = (settings['expiry_days'] as int?) ?? 180;
        if (milestones.length >= 2) {
          final m1 = (milestones[0] as Map).cast<String, dynamic>();
          final m2 = (milestones[1] as Map).cast<String, dynamic>();
          _m1Rides = (m1['rides'] as num?)?.toInt() ?? 50;
          _m1Cents = (m1['amount_cents'] as num?)?.toInt() ?? 5000;
          _m2Rides = (m2['rides'] as num?)?.toInt() ?? 200;
          _m2Cents = (m2['amount_cents'] as num?)?.toInt() ?? 15000;
        }
        _refereeBonusCents =
            (settings['referee_bonus_cents'] as num?)?.toInt() ?? 2500;
        _refereeBonusRides =
            (settings['referee_bonus_rides'] as num?)?.toInt() ?? 2;
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
    final s = S.of(context);
    // The deal, milestone-shaped: the new driver's $25 welcome hook first
    // (that's what makes them use the code), then what the referrer earns.
    final text =
        '${s.driverShareWelcome(_dollars(_refereeBonusCents), _refereeBonusRides)}\n\n'
        '${s.driverShareMilestones(_dollars(_m1Cents), _m1Rides, _dollars(_m2Cents), _m2Rides)}\n\n'
        'Code: $_code\n'
        'https://cruiseinride.com/drive/$_code';
    unawaited(shareText(context, text, subject: s.driverShareSubject));
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    return Scaffold(
      backgroundColor: neuBase,
      body: SafeArea(
        child: _loading
            ? const Center(
                child: CircularProgressIndicator(color: _gold, strokeWidth: 2),
              )
            : Stack(
                children: [
                  RefreshIndicator(
                    color: _gold,
                    onRefresh: _load,
                    child: ListView(
                      physics: const AlwaysScrollableScrollPhysics(
                        parent: BouncingScrollPhysics(),
                      ),
                      padding: const EdgeInsets.fromLTRB(20, 8, 20, 110),
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
                        const SizedBox(height: 22),

                        _buildHeroArtwork(),
                        Transform.translate(
                          offset: const Offset(0, -22),
                          child: _buildRewardsCard(s),
                        ),

                        _buildCodeCard(s),
                        const SizedBox(height: 14),
                        _buildRedeemBlock(s),
                        const SizedBox(height: 14),
                        _buildStats(s),
                        const SizedBox(height: 24),

                        _buildHowItWorksTimeline(s),
                        const SizedBox(height: 16),
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
                            padding:
                                const EdgeInsets.only(left: 4, bottom: 10),
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
                  Positioned(
                    left: 20,
                    right: 20,
                    bottom: 12,
                    child: _buildBottomShareButton(s),
                  ),
                ],
              ),
      ),
    );
  }

  Widget _buildHeroArtwork() {
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(24),
        boxShadow: [
          BoxShadow(
            color: _gold.withValues(alpha: 0.18),
            blurRadius: 26,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(24),
        child: Image.asset(
          'assets/images/referral_hero.png',
          width: double.infinity,
          height: 214,
          fit: BoxFit.cover,
          errorBuilder: (context, error, stackTrace) => const SizedBox.shrink(),
        ),
      ),
    );
  }

  Widget _buildRewardsCard(S s) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 18),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: _gold.withValues(alpha: 0.35)),
        boxShadow: [
          BoxShadow(
            color: _gold.withValues(alpha: 0.22),
            blurRadius: 26,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: IntrinsicHeight(
        child: Row(
          children: [
            Container(
              width: 54,
              height: 54,
              decoration: BoxDecoration(
                color: const Color(0xFF14141A),
                shape: BoxShape.circle,
                border: Border.all(color: _gold, width: 1.5),
              ),
              child: const Icon(Icons.card_giftcard_rounded,
                  color: _gold, size: 28),
            ),
            const SizedBox(width: 14),
            Expanded(
              flex: 47,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    s.driverReferralWinsTitle,
                    style: const TextStyle(
                      color: Colors.black,
                      fontSize: 13,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 0.4,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    _dollars(_refereeBonusCents),
                    style: const TextStyle(
                      color: _gold,
                      fontSize: 33,
                      fontWeight: FontWeight.w900,
                      letterSpacing: -0.8,
                    ),
                  ),
                  Text(
                    s.driverAfterFirstRides(_refereeBonusRides),
                    style: TextStyle(
                      color: Colors.black.withValues(alpha: 0.62),
                      fontSize: 13,
                      height: 1.25,
                    ),
                  ),
                ],
              ),
            ),
            Container(
              width: 1,
              margin: const EdgeInsets.symmetric(horizontal: 12),
              color: Colors.black.withValues(alpha: 0.10),
            ),
            Expanded(
              flex: 53,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    s.driverYouEarnTitle,
                    style: const TextStyle(
                      color: Colors.black,
                      fontSize: 13,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 0.4,
                    ),
                  ),
                  const SizedBox(height: 4),
                  _rewardMilestone(
                      _dollars(_m1Cents), s.driverAtRides(_m1Rides)),
                  const SizedBox(height: 2),
                  _rewardMilestone(
                      _dollars(_m2Cents), s.driverAtRides(_m2Rides)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _rewardMilestone(String amount, String when) {
    return Row(
      children: [
        Text(
          amount,
          style: const TextStyle(
            color: _gold,
            fontSize: 29,
            fontWeight: FontWeight.w900,
            letterSpacing: -0.7,
          ),
        ),
        const SizedBox(width: 5),
        Flexible(
          child: Text(
            when,
            style: TextStyle(
              color: Colors.black.withValues(alpha: 0.78),
              fontSize: 12.5,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildHowItWorksTimeline(S s) {
    final steps = <({IconData icon, String title, String body})>[
      (
        icon: Icons.share_outlined,
        title: s.driverHowShareTitle,
        body: s.driverHowStep1,
      ),
      (
        icon: Icons.person_add_alt_rounded,
        title: s.driverHowSignupTitle,
        body: s.driverHowSignupDesc,
      ),
      (
        icon: Icons.directions_car_rounded,
        title: s.driverHowRidesTitle,
        body: s.driverHowStep2Milestones(
            _dollars(_m1Cents), _m1Rides, _dollars(_m2Cents), _m2Rides),
      ),
      (
        icon: Icons.emoji_events_outlined,
        title: s.driverHowPaidTitle,
        body:
            '${s.driverHowStep3(_dollars(_amountCents))}\n${s.driverHowWelcomeBonus(_dollars(_refereeBonusCents), _refereeBonusRides)}',
      ),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          s.howItWorksTitle,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 28,
            fontWeight: FontWeight.w900,
            letterSpacing: -0.5,
          ),
        ),
        const SizedBox(height: 18),
        for (var i = 0; i < steps.length; i++)
          _buildTimelineRow(
            number: i + 1,
            icon: steps[i].icon,
            title: steps[i].title,
            body: steps[i].body,
            isLast: i == steps.length - 1,
          ),
      ],
    );
  }

  Widget _buildTimelineRow({
    required int number,
    required IconData icon,
    required String title,
    required String body,
    required bool isLast,
  }) {
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 34,
            child: Column(
              children: [
                Container(
                  width: 34,
                  height: 34,
                  decoration: const BoxDecoration(
                    color: _gold,
                    shape: BoxShape.circle,
                  ),
                  child: Center(
                    child: Text(
                      '$number',
                      style: const TextStyle(
                        color: Colors.black,
                        fontSize: 15,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  ),
                ),
                if (!isLast) Expanded(child: _timelineDashedLine()),
              ],
            ),
          ),
          const SizedBox(width: 12),
          Container(
            width: 56,
            height: 56,
            decoration: BoxDecoration(
              color: const Color(0xFF1C1C24),
              shape: BoxShape.circle,
              border: Border.all(
                  color: _gold.withValues(alpha: 0.62), width: 1.3),
            ),
            child: Icon(icon, color: _gold, size: 28),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Padding(
              padding: EdgeInsets.only(bottom: isLast ? 0 : 24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 18,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    body,
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.72),
                      fontSize: 14.5,
                      height: 1.38,
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

  Widget _timelineDashedLine() {
    return LayoutBuilder(
      builder: (context, constraints) {
        final count = (constraints.maxHeight / 9).floor().clamp(0, 20).toInt();
        return Column(
          children: [
            const SizedBox(height: 6),
            for (var i = 0; i < count; i++)
              Container(
                width: 2,
                height: 4,
                margin: const EdgeInsets.only(bottom: 5),
                color: _gold.withValues(alpha: 0.65),
              ),
          ],
        );
      },
    );
  }

  Widget _buildBottomShareButton(S s) {
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(18),
        boxShadow: [
          BoxShadow(
            color: _gold.withValues(alpha: 0.32),
            blurRadius: 24,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: SizedBox(
        width: double.infinity,
        height: 56,
        child: ElevatedButton.icon(
          onPressed: _code.isEmpty ? null : _shareInvite,
          icon: const Icon(Icons.share_rounded, size: 20),
          label: Text(
            s.shareReferralLinkBtn,
            style: const TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w900,
              letterSpacing: 0.2,
            ),
          ),
          style: ElevatedButton.styleFrom(
            backgroundColor: _gold,
            foregroundColor: Colors.black,
            disabledBackgroundColor: _gold.withValues(alpha: 0.35),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(18),
            ),
            elevation: 0,
          ),
        ),
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

  /// For the driver who signed up WITHOUT a code: one redemption is still
  /// allowed here (backend enforces one-per-driver). Same pattern as the
  /// rider screen's redeem block.
  Widget _buildRedeemBlock(S s) {
    final showSuccess = _redeemSuccess != null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
          decoration: BoxDecoration(
            color: _surface,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
          ),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _redeemCtl,
                  textCapitalization: TextCapitalization.characters,
                  enabled: !_redeeming && !showSuccess,
                  cursorColor: _gold,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 1.0,
                  ),
                  decoration: InputDecoration(
                    hintText: s.gotInviteCode,
                    hintStyle: TextStyle(
                      color: Colors.white.withValues(alpha: 0.35),
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                    ),
                    border: InputBorder.none,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              GestureDetector(
                onTap: (_redeeming || showSuccess) ? null : _redeem,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 16, vertical: 10),
                  decoration: BoxDecoration(
                    color: showSuccess ? const Color(0xFF22C55E) : _gold,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: _redeeming
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(
                              strokeWidth: 2.2, color: Colors.black),
                        )
                      : Text(
                          showSuccess ? '✓' : s.redeemLabel,
                          style: const TextStyle(
                            color: Colors.black,
                            fontSize: 12,
                            fontWeight: FontWeight.w900,
                            letterSpacing: 0.6,
                          ),
                        ),
                ),
              ),
            ],
          ),
        ),
        if (_redeemError != null)
          Padding(
            padding: const EdgeInsets.only(top: 6, left: 4),
            child: Text(
              _redeemError!,
              style: const TextStyle(
                color: Color(0xFFEF9A9A),
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        if (_redeemSuccess != null)
          Padding(
            padding: const EdgeInsets.only(top: 6, left: 4),
            child: Text(
              _redeemSuccess!,
              style: const TextStyle(
                color: Color(0xFF22C55E),
                fontSize: 12,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
      ],
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
    // Progress toward the NEXT unpaid milestone, not the far one: a bar
    // crawling toward 200 looks dead for weeks, a bar filling toward 50
    // keeps both sides checking it.
    final int ridesNeeded;
    if (status == 'pending') {
      ridesNeeded = _m1Rides;
    } else {
      ridesNeeded = (r['rides_required'] as int?) ?? _m2Rides;
    }
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
      case 'milestone1':
        statusColor = const Color(0xFF22C55E);
        statusLabel = s.statusMilestone1;
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
