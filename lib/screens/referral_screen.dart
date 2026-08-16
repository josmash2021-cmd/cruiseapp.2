import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../services/haptic_service.dart';
import 'package:share_plus/share_plus.dart';

import '../services/api_service.dart';
import '../l10n/app_localizations.dart';
import '../config/app_theme.dart';
import '../widgets/neu_style.dart';
import 'transfer_cruise_cash_screen.dart';

/// Invite Friends screen — Cruise Cash referral system.
///
/// Layout (top to bottom):
///   1. Back button + title
///   2. Hero card — "GIVE $15, GET $15" with the deal spelled out
///   3. Pending-bonus banner (only when THIS rider redeemed a code and
///      hasn't qualified yet — their welcome bonus waiting)
///   4. Referral code chip (tap to copy) + big Share button
///   5. Cruise Cash balance card + Transfer
///   6. "How it works" 3-step explainer
///   7. Redeem-someone-else's-code mini form
///   8. List of referees with per-row progress bar
///   9. Recent Cruise Cash transactions
///
/// The deal itself (amounts, qualifying fare) comes from the backend's
/// policy payload — change it once in referrals.py and every screen,
/// message and test follows.
///
/// Style: shared dark-neumorphism system (`neu_style.dart`) — `neuBase`
/// background, raised `neuBox` cards, sunken `neuBox(pressed: true)` wells,
/// gold 0xFFE8C547 accents, text colors from `AppColors.of(context)`.
class ReferralScreen extends StatefulWidget {
  const ReferralScreen({super.key});

  @override
  State<ReferralScreen> createState() => _ReferralScreenState();
}

class _ReferralScreenState extends State<ReferralScreen>
    with TickerProviderStateMixin {
  static const _gold = Color(0xFFE8C547);
  static const _goldLight = Color(0xFFFBE47A);
  static const _green = Color(0xFF22C55E);

  bool _loading = true;
  String _code = '';
  String _shareMessage = '';
  int _balanceCents = 0;
  int _lifetimeEarnedCents = 0;
  List<Map<String, dynamic>> _referees = [];
  List<Map<String, dynamic>> _transactions = [];

  /// The deal, as the backend currently offers it (policy payload).
  double _bonusDollars = 15;
  double _minFareDollars = 25;
  Map<String, dynamic>? _myPendingBonus;

  // Redeem-someone-else's-code mini form
  final _redeemCtl = TextEditingController();
  bool _redeeming = false;
  String? _redeemError;
  String? _redeemSuccess;

  late final AnimationController _entryCtl;

  @override
  void initState() {
    super.initState();
    _entryCtl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
    );
    _load();
  }

  @override
  void dispose() {
    _entryCtl.dispose();
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
      final res = await ApiService.redeemReferralCode(code);
      if (!mounted) return;
      _redeemCtl.clear();
      setState(() {
        _redeeming = false;
        _redeemSuccess = (res['inviter_first_name'] as String?) != null
            ? s.linkedToName(res['inviter_first_name'] as String)
            : s.codeRedeemed;
      });
      HapticService.mediumImpact();
      // The pending-bonus banner applies to this rider now — reload so it
      // shows without leaving and re-entering the screen.
      _load();
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
    setState(() => _loading = true);
    try {
      final results = await Future.wait([
        ApiService.getMyReferralInfo(),
        ApiService.getCruiseCashHistory(limit: 20),
      ]);
      if (!mounted) return;
      final info = results[0];
      final hist = results[1];
      final policy = (info['policy'] as Map?) ?? const {};
      setState(() {
        _code = (info['referral_code'] as String?) ?? '';
        _shareMessage = (info['share_message'] as String?) ?? '';
        _balanceCents = (info['balance_cents'] as num?)?.toInt() ?? 0;
        _lifetimeEarnedCents =
            (info['lifetime_earned_cents'] as num?)?.toInt() ?? 0;
        _referees = ((info['referees'] as List?) ?? const [])
            .map((e) => Map<String, dynamic>.from(e as Map))
            .toList();
        _transactions = ((hist['transactions'] as List?) ?? const [])
            .map((e) => Map<String, dynamic>.from(e as Map))
            .toList();
        _bonusDollars =
            (policy['referrer_bonus'] as num?)?.toDouble() ?? 15.0;
        _minFareDollars =
            (policy['qualifying_min_fare'] as num?)?.toDouble() ?? 25.0;
        _myPendingBonus = (info['my_pending_bonus'] as Map?)
            ?.map((k, v) => MapEntry(k.toString(), v));
        _loading = false;
      });
      _entryCtl.forward(from: 0);
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  String _fmt(int cents) {
    final dollars = cents / 100.0;
    return '\$${dollars.toStringAsFixed(2)}';
  }

  /// "$15", not "$15.00" — the deal reads cleaner in whole dollars.
  String _deal(double dollars) => dollars == dollars.roundToDouble()
      ? dollars.toStringAsFixed(0)
      : dollars.toStringAsFixed(2);

  Future<void> _copyCode() async {
    if (_code.isEmpty) return;
    HapticService.selectionClick();
    await Clipboard.setData(ClipboardData(text: _code));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(S.of(context).codeCopied),
        backgroundColor: _green,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  Future<void> _share() async {
    HapticService.lightImpact();
    final s = S.of(context);
    final msg = _shareMessage.isNotEmpty
        ? _shareMessage
        : 'Use my Cruise code $_code!';
    try {
      final box = context.findRenderObject() as RenderBox?;
      final origin = box != null
          ? box.localToGlobal(Offset.zero) & box.size
          : Rect.zero;
      await Share.share(
        msg,
        subject: 'Cruise Cash',
        sharePositionOrigin: origin,
      );
    } catch (e) {
      debugPrint('[ReferralScreen] Share failed: $e');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(s.shareSheetFailed),
          backgroundColor: _gold,
          behavior: SnackBarBehavior.floating,
          shape: const RoundedRectangleBorder(
              borderRadius: BorderRadius.all(Radius.circular(12))),
          duration: const Duration(seconds: 2),
        ),
      );
    }
  }

  Future<void> _openTransfer() async {
    HapticService.selectionClick();
    final result = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => TransferCruiseCashScreen(balanceCents: _balanceCents),
      ),
    );
    if (result == true) _load();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: neuBase,
      body: SafeArea(
        child: _loading
            ? const Center(child: CircularProgressIndicator(color: _gold))
            : RefreshIndicator(
                color: _gold,
                backgroundColor: neuSurface,
                onRefresh: _load,
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
                  physics: const AlwaysScrollableScrollPhysics(
                      parent: BouncingScrollPhysics()),
                  children: [
                    _buildHeader(),
                    const SizedBox(height: 20),
                    _entryItem(0, _buildHeroCard()),
                    if (_myPendingBonus != null) ...[
                      const SizedBox(height: 16),
                      _entryItem(1, _buildPendingBonusBanner()),
                    ],
                    const SizedBox(height: 16),
                    _entryItem(2, _buildCodeCard()),
                    const SizedBox(height: 16),
                    _entryItem(3, _buildBalanceCard()),
                    const SizedBox(height: 28),
                    _entryItem(4, _buildHowItWorks()),
                    const SizedBox(height: 24),
                    _entryItem(5, _buildRedeemBlock()),
                    const SizedBox(height: 28),
                    _entryItem(6, _buildRefereesSection()),
                    const SizedBox(height: 24),
                    _entryItem(7, _buildTransactionsSection()),
                  ],
                ),
              ),
      ),
    );
  }

  Widget _entryItem(int index, Widget child) {
    final start = (index * 0.08).clamp(0.0, 0.8);
    final anim = CurvedAnimation(
      parent: _entryCtl,
      curve: Interval(start, (start + 0.5).clamp(0.0, 1.0),
          curve: const Cubic(0.22, 1, 0.36, 1)),
    );
    return AnimatedBuilder(
      animation: anim,
      builder: (_, c) => Opacity(
        opacity: anim.value,
        child: Transform.translate(
          offset: Offset(0, 14 * (1 - anim.value)),
          child: c,
        ),
      ),
      child: child,
    );
  }

  Widget _buildHeader() {
    final c = AppColors.of(context);
    return Row(
      children: [
        GestureDetector(
          onTap: () => Navigator.of(context).maybePop(),
          child: Container(
            width: 40,
            height: 40,
            decoration: neuBox(radius: 14, pressed: true),
            alignment: Alignment.center,
            child: Icon(Icons.arrow_back_rounded,
                color: c.textPrimary, size: 22),
          ),
        ),
        const SizedBox(width: 14),
        Text(
          S.of(context).inviteFriendsTitle,
          style: TextStyle(
            fontFamily: 'Poppins',
            fontSize: 28,
            fontWeight: FontWeight.w800,
            color: c.textPrimary,
            letterSpacing: -0.5,
          ),
        ),
      ],
    );
  }

  Widget _sectionHeader(String title, {Widget? trailing}) {
    final c = AppColors.of(context);
    return Padding(
      padding: const EdgeInsets.only(left: 6, bottom: 10),
      child: Row(
        children: [
          Text(
            title.toUpperCase(),
            style: TextStyle(
              fontFamily: 'Poppins',
              color: c.textTertiary,
              fontSize: 12,
              fontWeight: FontWeight.w700,
              letterSpacing: 1.2,
            ),
          ),
          const Spacer(),
          if (trailing != null) trailing,
        ],
      ),
    );
  }

  /// The deal, front and centre. Gold on dark: the one card on this screen
  /// that is allowed to shout.
  Widget _buildHeroCard() {
    final s = S.of(context);
    final amount = _deal(_bonusDollars);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(22, 24, 22, 22),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [_gold, _goldLight],
        ),
        borderRadius: BorderRadius.circular(24),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 46,
            height: 46,
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(14),
            ),
            alignment: Alignment.center,
            child: const Icon(Icons.card_giftcard_rounded,
                color: Colors.black, size: 26),
          ),
          const SizedBox(height: 16),
          Text(
            s.referHeroTitle(amount),
            style: const TextStyle(
              fontFamily: 'Poppins',
              color: Colors.black,
              fontSize: 26,
              fontWeight: FontWeight.w900,
              letterSpacing: -0.5,
              height: 1.1,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            s.referHeroSub(amount, _deal(_minFareDollars)),
            style: TextStyle(
              fontFamily: 'Poppins',
              color: Colors.black.withValues(alpha: 0.65),
              fontSize: 13.5,
              fontWeight: FontWeight.w600,
              height: 1.35,
            ),
          ),
        ],
      ),
    );
  }

  /// Shown only to a rider who redeemed someone's code and hasn't taken
  /// their qualifying ride yet — the welcome bonus they already have
  /// waiting, so the promise is visible from day one.
  Widget _buildPendingBonusBanner() {
    final s = S.of(context);
    final b = _myPendingBonus!;
    final bonusCents = (b['bonus_cents'] as num?)?.toInt() ?? 0;
    final minFare = (b['qualifying_min_fare'] as num?)?.toDouble() ?? 25.0;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
      decoration: BoxDecoration(
        color: _green.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: _green.withValues(alpha: 0.45)),
      ),
      child: Row(
        children: [
          const Icon(Icons.savings_rounded, color: _green, size: 26),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  s.referPendingBonusTitle(
                      _deal(bonusCents / 100.0)),
                  style: const TextStyle(
                    fontFamily: 'Poppins',
                    color: _green,
                    fontSize: 14.5,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  s.referPendingBonusSub(_deal(minFare)),
                  style: TextStyle(
                    fontFamily: 'Poppins',
                    color: Colors.white.withValues(alpha: 0.6),
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// The code is the product of this screen — biggest type after the hero,
  /// tap anywhere to copy, and the share button glued underneath.
  Widget _buildCodeCard() {
    final c = AppColors.of(context);
    final s = S.of(context);
    return Container(
      decoration: neuBox(radius: 20),
      child: Column(
        children: [
          GestureDetector(
            onTap: _copyCode,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 18, 20, 16),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          s.yourCode,
                          style: TextStyle(
                            fontFamily: 'Poppins',
                            color: c.textTertiary,
                            fontSize: 10,
                            fontWeight: FontWeight.w700,
                            letterSpacing: 1.2,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          _code.isEmpty ? '--' : _code,
                          style: TextStyle(
                            fontFamily: 'Poppins',
                            color: c.textPrimary,
                            fontSize: 26,
                            fontWeight: FontWeight.w900,
                            letterSpacing: 1.4,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 14, vertical: 8),
                    decoration: neuBox(radius: 12, pressed: true),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.copy_rounded, color: _gold, size: 14),
                        const SizedBox(width: 6),
                        Text(
                          s.copyLabel,
                          style: const TextStyle(
                            fontFamily: 'Poppins',
                            color: _gold,
                            fontSize: 11,
                            fontWeight: FontWeight.w800,
                            letterSpacing: 0.8,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          Divider(height: 1, color: Colors.white.withValues(alpha: 0.06)),
          Padding(
            padding: const EdgeInsets.all(12),
            child: GestureDetector(
              onTap: _share,
              child: Container(
                height: 52,
                decoration: BoxDecoration(
                  color: _gold,
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Icon(Icons.share_rounded,
                        color: Colors.black, size: 18),
                    const SizedBox(width: 10),
                    Text(
                      s.shareInviteLabel,
                      style: const TextStyle(
                        fontFamily: 'Poppins',
                        color: Colors.black,
                        fontSize: 15,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 0.2,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBalanceCard() {
    final c = AppColors.of(context);
    final s = S.of(context);
    return Container(
      padding: const EdgeInsets.fromLTRB(22, 20, 22, 20),
      decoration: neuBox(radius: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.account_balance_wallet_rounded,
                  color: _gold, size: 20),
              const SizedBox(width: 8),
              Text(
                s.cruiseCashLabel,
                style: TextStyle(
                  fontFamily: 'Poppins',
                  color: c.textSecondary,
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.3,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    AnimatedSwitcher(
                      duration: const Duration(milliseconds: 350),
                      child: Text(
                        _fmt(_balanceCents),
                        key: ValueKey(_balanceCents),
                        style: const TextStyle(
                          fontFamily: 'Poppins',
                          color: _gold,
                          fontSize: 36,
                          fontWeight: FontWeight.w900,
                          letterSpacing: -1.0,
                        ),
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      s.lifetimeEarned(_fmt(_lifetimeEarnedCents)),
                      style: TextStyle(
                        fontFamily: 'Poppins',
                        color: c.textTertiary,
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ),
              ),
              GestureDetector(
                onTap: _balanceCents > 0 ? _openTransfer : null,
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 160),
                  padding: const EdgeInsets.symmetric(
                      horizontal: 18, vertical: 12),
                  decoration: _balanceCents > 0
                      ? BoxDecoration(
                          color: _gold,
                          borderRadius: BorderRadius.circular(14),
                        )
                      : neuBox(radius: 14, pressed: true),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.send_rounded,
                          color: _balanceCents > 0
                              ? Colors.black
                              : c.textTertiary,
                          size: 15),
                      const SizedBox(width: 8),
                      Text(
                        s.transferLabel,
                        style: TextStyle(
                          fontFamily: 'Poppins',
                          color: _balanceCents > 0
                              ? Colors.black
                              : c.textTertiary,
                          fontSize: 13,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 0.2,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildHowItWorks() {
    final s = S.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionHeader(s.howItWorksTitle),
        _step(1, Icons.share_rounded, s.referStep1Title, s.referStep1Body),
        _step(2, Icons.directions_car_rounded, s.referStep2Title,
            s.referStep2Body(_deal(_minFareDollars))),
        _step(3, Icons.savings_rounded, s.referStep3Title(_deal(_bonusDollars)),
            s.referStep3Body),
      ],
    );
  }

  Widget _step(int index, IconData icon, String title, String body) {
    final c = AppColors.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: neuBox(radius: 16),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: neuBox(radius: 14, pressed: true),
              alignment: Alignment.center,
              child: Icon(icon, color: _gold, size: 22),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: _gold,
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          '$index',
                          style: const TextStyle(
                            fontFamily: 'Poppins',
                            color: Colors.black,
                            fontSize: 10,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          title,
                          style: TextStyle(
                            fontFamily: 'Poppins',
                            color: c.textPrimary,
                            fontSize: 14,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    body,
                    style: TextStyle(
                      fontFamily: 'Poppins',
                      color: c.textSecondary,
                      fontSize: 12.5,
                      height: 1.35,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildRedeemBlock() {
    final c = AppColors.of(context);
    final s = S.of(context);
    final showSuccess = _redeemSuccess != null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionHeader(s.gotInviteCode),
        Container(
          padding: const EdgeInsets.all(12),
          decoration: neuBox(radius: 16, pressed: true),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _redeemCtl,
                  textCapitalization: TextCapitalization.characters,
                  enabled: !_redeeming && !showSuccess,
                  cursorColor: _gold,
                  style: TextStyle(
                    fontFamily: 'Poppins',
                    color: c.textPrimary,
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 1.2,
                  ),
                  decoration: InputDecoration(
                    hintText: 'XXXX-XXXX',
                    hintStyle: TextStyle(
                      fontFamily: 'Poppins',
                      color: c.textTertiary,
                      fontSize: 15,
                      fontWeight: FontWeight.w500,
                      letterSpacing: 1.2,
                    ),
                    border: InputBorder.none,
                    contentPadding: const EdgeInsets.symmetric(
                        horizontal: 6, vertical: 14),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              GestureDetector(
                onTap: (_redeeming || showSuccess) ? null : _redeem,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 18, vertical: 12),
                  decoration: BoxDecoration(
                    color: showSuccess ? _green : _gold,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: _redeeming
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                              strokeWidth: 2.2, color: Colors.black),
                        )
                      : Text(
                          showSuccess ? '✓' : s.redeemLabel,
                          style: const TextStyle(
                            fontFamily: 'Poppins',
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
            padding: const EdgeInsets.only(top: 8, left: 4),
            child: Text(
              _redeemError!,
              style: const TextStyle(
                fontFamily: 'Poppins',
                color: Color(0xFFEF9A9A),
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        if (_redeemSuccess != null)
          Padding(
            padding: const EdgeInsets.only(top: 8, left: 4),
            child: Text(
              _redeemSuccess!,
              style: const TextStyle(
                fontFamily: 'Poppins',
                color: _green,
                fontSize: 12,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildRefereesSection() {
    final c = AppColors.of(context);
    final s = S.of(context);
    final qualified = _referees.where((r) => r['status'] == 'qualified').length;
    final total = _referees.length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionHeader(
          s.yourReferrals,
          trailing: total > 0
              ? Text(
                  s.qualifiedOfTotal(qualified, total),
                  style: TextStyle(
                    fontFamily: 'Poppins',
                    color: c.textTertiary,
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                  ),
                )
              : null,
        ),
        if (_referees.isEmpty)
          Container(
            padding: const EdgeInsets.symmetric(vertical: 28),
            decoration: neuBox(radius: 16),
            alignment: Alignment.center,
            child: Column(
              children: [
                Icon(Icons.group_add_outlined,
                    color: c.textTertiary, size: 28),
                const SizedBox(height: 10),
                Text(
                  s.noReferralsYet,
                  style: TextStyle(
                    fontFamily: 'Poppins',
                    color: c.textSecondary,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          )
        else
          ..._referees.map(_refereeRow),
      ],
    );
  }

  Widget _refereeRow(Map<String, dynamic> r) {
    final c = AppColors.of(context);
    final s = S.of(context);
    final first = (r['first_name'] ?? '') as String;
    final last = (r['last_name'] ?? '') as String;
    final count = (r['qualified_trips_count'] as num?)?.toInt() ?? 0;
    final required = (r['qualified_trips_required'] as num?)?.toInt() ?? 1;
    final progress = required == 0 ? 1.0 : (count / required).clamp(0.0, 1.0);
    final isComplete = r['status'] == 'qualified';
    final initials = (first.isNotEmpty ? first[0] : '?').toUpperCase();
    final displayName = '$first ${last.isNotEmpty ? '$last.' : ''}'.trim();
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: neuBox(radius: 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 40,
                  height: 40,
                  decoration: isComplete
                      ? const BoxDecoration(
                          color: _gold,
                          shape: BoxShape.circle,
                        )
                      : neuBox(radius: 20, pressed: true),
                  alignment: Alignment.center,
                  child: Text(
                    initials,
                    style: TextStyle(
                      fontFamily: 'Poppins',
                      color: isComplete ? Colors.black : c.textPrimary,
                      fontSize: 15,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    displayName.isEmpty ? 'Friend' : displayName,
                    style: TextStyle(
                      fontFamily: 'Poppins',
                      color: c.textPrimary,
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                if (isComplete)
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: _gold,
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.check_rounded,
                            color: Colors.black, size: 12),
                        const SizedBox(width: 3),
                        Text(
                          s.earnedBadge,
                          style: const TextStyle(
                            fontFamily: 'Poppins',
                            color: Colors.black,
                            fontSize: 9,
                            fontWeight: FontWeight.w900,
                            letterSpacing: 0.6,
                          ),
                        ),
                      ],
                    ),
                  )
                else
                  Text(
                    '$count/$required',
                    style: TextStyle(
                      fontFamily: 'Poppins',
                      color: c.textSecondary,
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            ClipRRect(
              borderRadius: BorderRadius.circular(50),
              child: Stack(
                children: [
                  Container(
                    height: 6,
                    color: neuPressed,
                  ),
                  TweenAnimationBuilder<double>(
                    tween: Tween(begin: 0.0, end: progress),
                    duration: const Duration(milliseconds: 800),
                    curve: const Cubic(0.22, 1, 0.36, 1),
                    builder: (_, val, __) => FractionallySizedBox(
                      widthFactor: val,
                      child: Container(
                        height: 6,
                        decoration: const BoxDecoration(
                          gradient: LinearGradient(
                            colors: [_gold, _goldLight],
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTransactionsSection() {
    final s = S.of(context);
    if (_transactions.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionHeader(s.recentActivityLabel),
        Container(
          decoration: neuBox(radius: 20),
          child: Column(
            children: [
              for (int i = 0; i < _transactions.length; i++) ...[
                if (i > 0)
                  Divider(
                    height: 1,
                    indent: 68,
                    color: Colors.white.withValues(alpha: 0.05),
                  ),
                _txRow(_transactions[i]),
              ],
            ],
          ),
        ),
      ],
    );
  }

  Widget _txRow(Map<String, dynamic> tx) {
    final c = AppColors.of(context);
    final s = S.of(context);
    final kind = (tx['kind'] ?? '') as String;
    final cents = (tx['amount_cents'] as num?)?.toInt() ?? 0;
    final note = (tx['note'] ?? '') as String;
    final positive = cents > 0;
    final IconData icon;
    final String label;
    switch (kind) {
      case 'earned_referral':
        icon = Icons.card_giftcard_rounded;
        label = note.isNotEmpty ? note : s.txReferralBonus;
        break;
      case 'spent_ride':
        icon = Icons.directions_car_rounded;
        label = note.isNotEmpty ? note : s.txAppliedToRide;
        break;
      case 'transferred_in':
        icon = Icons.south_west_rounded;
        label = note.isNotEmpty ? note : s.txTransferReceived;
        break;
      case 'transferred_out':
        icon = Icons.north_east_rounded;
        label = note.isNotEmpty ? note : s.txTransferSent;
        break;
      default:
        icon = Icons.swap_horiz_rounded;
        label = note.isNotEmpty ? note : s.txAdjustment;
    }
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: neuBox(radius: 14, pressed: true),
            alignment: Alignment.center,
            child: Icon(icon,
                color: positive ? _gold : c.textSecondary, size: 22),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontFamily: 'Poppins',
                color: c.textPrimary,
                fontSize: 13.5,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          Text(
            '${positive ? '+' : '−'}${_fmt(cents.abs())}',
            style: TextStyle(
              fontFamily: 'Poppins',
              color: positive ? _gold : c.textPrimary,
              fontSize: 14,
              fontWeight: FontWeight.w800,
            ),
          ),
        ],
      ),
    );
  }
}
