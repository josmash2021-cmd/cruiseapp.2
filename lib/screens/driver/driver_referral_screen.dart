import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import '../../services/haptic_service.dart';

import '../../l10n/app_localizations.dart';
import '../../services/api_service.dart';
import '../../widgets/neu_style.dart';
import '../../widgets/onboarding_image.dart';
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
  static const _green = Color(0xFF22C55E);
  static const _surface = Color(0xFF1A1A1F);

  bool _loading = true;
  String _code = '';
  int _amountCents = 20000;
  int _totalEarnedCents = 0;
  int _pendingCents = 0;
  List<Map<String, dynamic>> _referees = const [];

  // Two-page layout: page 0 is the invite/how-it-works pitch, page 1 is
  // "My Referrals" with per-driver progress. Swipe sideways to switch.
  final PageController _pageCtrl = PageController();
  int _pageIndex = 0;

  /// Milestone schedule from the backend (falls back to the flat totals).
  int _m1Rides = 50;
  int _m1Cents = 5000;
  int _m2Rides = 200;
  int _m2Cents = 15000;
  int _refereeBonusCents = 2500;
  int _refereeBonusRides = 2;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _pageCtrl.dispose();
    super.dispose();
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

  Future<List<int>> _inviteImageBytes() async {
    try {
      final data = await rootBundle.load('assets/images/referral_invite.png');
      return data.buffer
          .asUint8List(data.offsetInBytes, data.lengthInBytes);
    } catch (e) {
      debugPrint('[Referral] bundled image unavailable, downloading: $e');
    }
    final url =
        '${ApiService.publicBaseUrl}/static/media/referral_invite.png';
    final response = await http
        .get(Uri.parse(url))
        .timeout(const Duration(seconds: 12));
    if (response.statusCode != 200 || response.bodyBytes.length < 10000) {
      throw Exception('invite image HTTP ${response.statusCode}');
    }
    return response.bodyBytes;
  }

  Future<void> _shareInvite() async {
    if (_code.isEmpty) return;
    HapticService.mediumImpact();
    final s = S.of(context);
    // Invitee-centered: the message sells ONLY what the invited driver gets
    // ($25 after 2 rides). What the referrer earns is never the invitee's
    // business — the old "I earn $50 when you…" line died 2026-10-22.
    //
    // HOST: the brand domain (owner spec 2026-10-23). Its hosting (GitHub
    // Pages, repo cruisewebsite branch gh-pages) serves
    // /.well-known/apple-app-site-association + assetlinks.json (the OS
    // opens an installed app directly) and its 404.html handles /drive/*:
    // Android without the app bounces to the backend (which 302s to Play
    // with the code in the install referrer), iOS/desktop see the branded
    // invite card with the copyable code without leaving the domain.
    const shareHost = 'https://cruiseinride.com';
    final link = '$shareHost/drive/$_code';
    final text =
        '${s.driverShareWelcome(_dollars(_refereeBonusCents), _refereeBonusRides)}\n\n'
        '${s.driverShareCodeLine(_code)}\n'
        '$link';
    // The invite goes out as an IMAGE + the code + the link (owner spec
    // 2026-10-27): not a bare text message. The asset is written to a temp
    // file because shareXFiles needs a real filesystem path on device.
    try {
      final dir = await getTemporaryDirectory();
      final f = File('${dir.path}/cruise_referral_invite.png');
      final bytes = await _inviteImageBytes();
      await f.writeAsBytes(bytes, flush: true);
      if (!mounted) return;
      await Share.shareXFiles(
        [XFile(f.path)],
        text: text,
        subject: s.driverShareSubject,
      );
    } catch (e) {
      debugPrint('[Referral] image share failed, falling back to text: $e');
      if (!mounted) return;
      unawaited(shareText(context, text, subject: s.driverShareSubject));
    }
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
            : Column(
                children: [
                  Expanded(
                    child: PageView(
                      controller: _pageCtrl,
                      onPageChanged: (i) =>
                          setState(() => _pageIndex = i),
                      children: [
                        _buildMainReferralPage(s),
                        _buildMyReferralsPage(s),
                      ],
                    ),
                  ),
                  _buildPageDots(),
                ],
              ),
      ),
    );
  }

  Widget _buildPageDots() {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          for (var i = 0; i < 2; i++)
            AnimatedContainer(
              duration: const Duration(milliseconds: 250),
              margin: const EdgeInsets.symmetric(horizontal: 4),
              width: _pageIndex == i ? 18 : 7,
              height: 7,
              decoration: BoxDecoration(
                color: _pageIndex == i
                    ? _gold
                    : Colors.white.withValues(alpha: 0.25),
                borderRadius: BorderRadius.circular(4),
              ),
            ),
        ],
      ),
    );
  }

  /// Page 1 — NO scrollable of any kind (owner spec 2026-10-23: "la primera
  /// pagina completa, sin scroll"). Same LayoutBuilder gapScale idiom as the
  /// rider referral screen: gaps and the hero scale down on short phones,
  /// fonts never do. On VERY short screens the hero artwork bows out — the
  /// rewards numbers matter, the artwork is decoration. The Share button
  /// lives IN the column (a Spacer pins it to the bottom) — the old floating
  /// overlay + 110 bottom padding died with the scroll.
  Widget _buildMainReferralPage(S s) {
    return LayoutBuilder(
      builder: (context, box) {
        final gapScale = (box.maxHeight / 700).clamp(0.55, 1.0);
        double gap(double v) => v * gapScale;
        final heroHeight = box.maxHeight < 600 ? 0.0 : 150.0 * gapScale;
        return Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 10),
          child: Column(
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
                  Expanded(
                    child: Text(
                      s.referFriends,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 22,
                        fontWeight: FontWeight.w800,
                        letterSpacing: -0.4,
                      ),
                    ),
                  ),
                ],
              ),
              SizedBox(height: gap(14)),
              if (heroHeight > 0) ...[
                _buildHeroArtwork(heroHeight),
                Transform.translate(
                  offset: const Offset(0, -16),
                  child: _buildRewardsCard(s),
                ),
              ] else
                _buildRewardsCard(s),
              SizedBox(height: gap(12)),
              _buildHowItWorksTimeline(s, gapScale),

              // Hint toward page 2 — the referrals tracker lives one swipe
              // away.
              if (_referees.isNotEmpty) ...[
                SizedBox(height: gap(10)),
                Center(
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        s.swipeToSeeReferrals,
                        style: const TextStyle(
                          color: Color(0xFFB0B0B6),
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(width: 6),
                      const Icon(Icons.arrow_forward_rounded,
                          color: _gold, size: 16),
                    ],
                  ),
                ),
              ],
              const Spacer(),
              _buildBottomShareButton(s),
            ],
          ),
        );
      },
    );
  }

  Widget _buildHeroArtwork(double height) {
    return Container(
      height: height,
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
        child: OnboardingImage(
          filename: 'referral_hero.png',
          localPath: 'assets/images/referral_hero.png',
          remoteUrl:
              '${ApiService.publicBaseUrl}/static/media/referral_hero.png',
          width: double.infinity,
          height: height,
          fit: BoxFit.cover,
          fallbackIcon: Icons.card_giftcard_rounded,
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

  Widget _buildHowItWorksTimeline(S s, double gapScale) {
    final steps = <({IconData icon, String title, String body})>[
      (
        // Icon glyphs must ALSO exist as plain const references elsewhere in
        // the app: the release build's icon tree-shaker misses glyphs that
        // appear ONLY inside this record literal and the circle then renders
        // a "?" box (prod screenshots, 2026-10-22).
        icon: Icons.share_rounded,
        title: s.driverHowShareTitle,
        body: s.driverHowStep1,
      ),
      (
        icon: Icons.person_add_rounded,
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
        icon: Icons.emoji_events_rounded,
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
            fontSize: 22,
            fontWeight: FontWeight.w900,
            letterSpacing: -0.5,
          ),
        ),
        SizedBox(height: 12 * gapScale),
        for (var i = 0; i < steps.length; i++)
          _buildTimelineRow(
            number: i + 1,
            icon: steps[i].icon,
            title: steps[i].title,
            body: steps[i].body,
            isLast: i == steps.length - 1,
            gapScale: gapScale,
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
    required double gapScale,
  }) {
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 30,
            child: Column(
              children: [
                Container(
                  width: 30,
                  height: 30,
                  decoration: const BoxDecoration(
                    color: _gold,
                    shape: BoxShape.circle,
                  ),
                  child: Center(
                    child: Text(
                      '$number',
                      style: const TextStyle(
                        color: Colors.black,
                        fontSize: 14,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  ),
                ),
                if (!isLast) Expanded(child: _timelineDashedLine()),
              ],
            ),
          ),
          const SizedBox(width: 10),
          Container(
            width: 42,
            height: 42,
            decoration: BoxDecoration(
              color: const Color(0xFF1C1C24),
              shape: BoxShape.circle,
              border: Border.all(
                  color: _gold.withValues(alpha: 0.62), width: 1.3),
            ),
            child: Icon(icon, color: _gold, size: 21),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Padding(
              padding: EdgeInsets.only(bottom: isLast ? 0 : 12 * gapScale),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    body,
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.72),
                      fontSize: 13,
                      height: 1.32,
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


  // ── Page 2: My Referrals ──────────────────────────────────────────────────

  Widget _buildMyReferralsPage(S s) {
    return RefreshIndicator(
      color: _gold,
      onRefresh: _load,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(
          parent: BouncingScrollPhysics(),
        ),
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
        children: [
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
              Expanded(
                child: Text(
                  s.referFriends,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 22,
                    fontWeight: FontWeight.w800,
                    letterSpacing: -0.4,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 22),
          _buildEarnedCard(s),
          const SizedBox(height: 26),
          Row(
            children: [
              Expanded(
                child: Text(
                  s.myReferralsTitle,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 24,
                    fontWeight: FontWeight.w900,
                    letterSpacing: -0.5,
                  ),
                ),
              ),
              Text(
                s.driversJoinedCount(_referees.length),
                style: const TextStyle(
                  color: Color(0xFFB0B0B6),
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          if (_referees.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 36),
              child: Center(
                child: Text(
                  s.noReferralsYet,
                  style: const TextStyle(
                    color: Color(0xFFB0B0B6),
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            )
          else
            ..._referees.map((r) => _buildReferralTrackRow(r, s)),
        ],
      ),
    );
  }

  /// Gold summary card: steering-wheel badge, animated Earned total, and a
  /// Pending/Paid chip — pending while any bonus is still on its way, paid
  /// (green) once everything earned has been credited.
  Widget _buildEarnedCard(S s) {
    final fullyPaid = _pendingCents <= 0 && _totalEarnedCents > 0;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 22),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [Color(0xFFF2D267), Color(0xFFD4AF37)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(22),
        boxShadow: [
          BoxShadow(
            color: _gold.withValues(alpha: 0.35),
            blurRadius: 26,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: Row(
        children: [
          Container(
            width: 62,
            height: 62,
            decoration: const BoxDecoration(
              color: Color(0xFF14141A),
              shape: BoxShape.circle,
            ),
            child: Center(
              child: CustomPaint(
                size: const Size(34, 34),
                painter: _SteeringWheelPainter(color: _gold),
              ),
            ),
          ),
          const SizedBox(width: 14),
          Container(
            width: 1.5,
            height: 56,
            color: Colors.black.withValues(alpha: 0.22),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  s.earnedLabel,
                  style: TextStyle(
                    color: Colors.black.withValues(alpha: 0.75),
                    fontSize: 15,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                TweenAnimationBuilder<double>(
                  tween: Tween(begin: 0, end: _totalEarnedCents / 100),
                  duration: const Duration(milliseconds: 900),
                  curve: Curves.easeOutCubic,
                  builder: (context, value, _) => Text(
                    '\$${value.toStringAsFixed(0)}',
                    style: const TextStyle(
                      color: Colors.black,
                      fontSize: 44,
                      fontWeight: FontWeight.w900,
                      letterSpacing: -1.2,
                      height: 1.05,
                    ),
                  ),
                ),
              ],
            ),
          ),
          if (_totalEarnedCents > 0 || _pendingCents > 0)
            Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.85),
                borderRadius: BorderRadius.circular(20),
              ),
              child: Text(
                fullyPaid ? s.paidLabel : s.pendingLabel,
                style: TextStyle(
                  color: fullyPaid ? _green : _gold,
                  fontSize: 12,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 0.4,
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// One referred driver: name + joined/expiry dates, an animated progress
  /// bar toward the next milestone, and what their rides have earned the
  /// referrer ($50 after 50 rides, $200 once they reach 200 — the amount
  /// turns green when the goal is fully paid).
  Widget _buildReferralTrackRow(Map<String, dynamic> r, S s) {
    final name = (r['display_name'] as String?)?.trim().isNotEmpty == true
        ? (r['display_name'] as String).trim()
        : 'Driver';
    final ridesDone = (r['rides_completed'] as num?)?.toInt() ?? 0;
    final nextRides = (r['next_milestone_rides'] as num?)?.toInt() ?? _m1Rides;
    final earned = (r['earned_cents'] as num?)?.toInt() ?? 0;
    final nextAmount =
        (r['next_milestone_amount_cents'] as num?)?.toInt() ?? 0;
    final status = (r['status'] as String?) ?? 'pending';
    // The backend's payment_status is the authority: expired / paid / pending.
    final paymentStatus = (r['payment_status'] as String?) ?? 'pending';
    final expired = paymentStatus == 'expired';
    final fullyPaid = paymentStatus == 'paid' &&
        (r['paid_at'] != null || status == 'qualified');
    final m1Paid = paymentStatus == 'paid' && !fullyPaid;
    final progress =
        nextRides > 0 ? (ridesDone / nextRides).clamp(0.0, 1.0) : 0.0;
    final pct = (progress * 100).round();

    final amountCents = (fullyPaid || m1Paid) ? earned : nextAmount;
    final barColor = expired
        ? Colors.white.withValues(alpha: 0.25)
        : (fullyPaid ? _green : _gold);
    final statusLabel = expired
        ? s.statusExpired
        : (fullyPaid || m1Paid ? s.paidLabel : s.pendingLabel);
    final statusColor = expired
        ? const Color(0xFFEF4444)
        : (fullyPaid || m1Paid ? _green : _gold);
    final amountColor = expired
        ? Colors.white38
        : (fullyPaid ? _green : _gold);

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          name,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 15,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          '${s.referralJoined(_fmtDate(r['joined_at'] as String?, s.isSpanish))}'
                          ' · '
                          '${s.referralExpires(_fmtDate(r['expires_at'] as String?, s.isSpanish))}',
                          style: const TextStyle(
                            color: Color(0xFFB0B0B6),
                            fontSize: 11.5,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 10),
                  CustomPaint(
                    size: const Size(20, 20),
                    painter: _SteeringWheelPainter(
                        color: expired ? Colors.white38 : _gold),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    _dollars(amountCents),
                    style: TextStyle(
                      color: amountColor,
                      fontSize: 18,
                      fontWeight: FontWeight.w900,
                      letterSpacing: -0.4,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 9, vertical: 4),
                    decoration: BoxDecoration(
                      color: statusColor.withValues(alpha: 0.14),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(
                          color: statusColor.withValues(alpha: 0.4)),
                    ),
                    child: Text(
                      statusLabel,
                      style: TextStyle(
                        color: statusColor,
                        fontSize: 10.5,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 0.3,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Text(
                    '$ridesDone / $nextRides ${s.ridesLabel}',
                    style: const TextStyle(
                      color: Color(0xFFB0B0B6),
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const Spacer(),
                  Text(
                    '$pct%',
                    style: const TextStyle(
                      color: Color(0xFFB0B0B6),
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              TweenAnimationBuilder<double>(
                tween: Tween(begin: 0, end: progress),
                duration: const Duration(milliseconds: 800),
                curve: Curves.easeOutCubic,
                builder: (context, value, _) => ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(
                    value: value,
                    minHeight: 6,
                    backgroundColor: Colors.white.withValues(alpha: 0.08),
                    valueColor: AlwaysStoppedAnimation<Color>(barColor),
                  ),
                ),
              ),
            ],
          ),
        ),
        Divider(
          height: 1,
          thickness: 1,
          color: Colors.white.withValues(alpha: 0.07),
        ),
      ],
    );
  }

  /// "Oct 10, 2026" / "10 oct 2026" — formatted by hand because intl's
  /// DateFormat with an 'es' locale throws unless initializeDateFormatting
  /// ran, and nothing in the app initializes it.
  String _fmtDate(String? iso, bool es) {
    final dt = DateTime.tryParse(iso ?? '')?.toLocal();
    if (dt == null) return '—';
    const monthsEn = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
    ];
    const monthsEs = [
      'ene', 'feb', 'mar', 'abr', 'may', 'jun',
      'jul', 'ago', 'sep', 'oct', 'nov', 'dic',
    ];
    final month = (es ? monthsEs : monthsEn)[dt.month - 1];
    return es
        ? '${dt.day} $month ${dt.year}'
        : '$month ${dt.day}, ${dt.year}';
  }
}

/// Minimal steering-wheel glyph for the referral earnings card and rows —
/// Material has no steering-wheel icon, and this avoids shipping an asset.
class _SteeringWheelPainter extends CustomPainter {
  const _SteeringWheelPainter({required this.color});

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final stroke = size.width * 0.10;
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round;
    final center = size.center(Offset.zero);
    final rimRadius = size.width * 0.42;
    canvas.drawCircle(center, rimRadius, paint);
    canvas.drawCircle(center, size.width * 0.13, paint);
    final spoke = Paint()
      ..color = color
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(
      Offset(center.dx - rimRadius * 0.9, center.dy - rimRadius * 0.12),
      Offset(center.dx - size.width * 0.13, center.dy),
      spoke,
    );
    canvas.drawLine(
      Offset(center.dx + rimRadius * 0.9, center.dy - rimRadius * 0.12),
      Offset(center.dx + size.width * 0.13, center.dy),
      spoke,
    );
    canvas.drawLine(
      Offset(center.dx, center.dy + size.width * 0.13),
      Offset(center.dx, center.dy + rimRadius * 0.92),
      spoke,
    );
  }

  @override
  bool shouldRepaint(_SteeringWheelPainter oldDelegate) =>
      oldDelegate.color != color;
}
