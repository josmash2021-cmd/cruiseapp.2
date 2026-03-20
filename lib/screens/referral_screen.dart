import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';
import '../services/api_service.dart';

class ReferralScreen extends StatefulWidget {
  const ReferralScreen({super.key});

  @override
  State<ReferralScreen> createState() => _ReferralScreenState();
}

class _ReferralScreenState extends State<ReferralScreen> {
  static const _gold = Color(0xFFE8C547);
  static const _card = Color(0xFF1C1C1E);
  static const _surface = Color(0xFF141414);

  bool _loading = true;
  String _code = '';
  int _referralCount = 0;
  double _totalBonus = 0.0;
  List<Map<String, dynamic>> _referrals = [];

  final _codeController = TextEditingController();
  bool _applying = false;
  String? _applyError;
  bool _alreadyReferred = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _codeController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final results = await Future.wait([
        ApiService.getReferralCode(),
        ApiService.getMyReferrals(),
      ]);
      if (!mounted) return;
      final info = results[0];
      final hist = results[1];
      setState(() {
        _code = info['referral_code'] as String? ?? '';
        _referralCount = (info['referral_count'] as num?)?.toInt() ?? 0;
        _totalBonus = (info['total_bonus_earned'] as num?)?.toDouble() ?? 0.0;
        _referrals = (hist['referrals'] as List<dynamic>?)
                ?.map((e) => Map<String, dynamic>.from(e as Map))
                .toList() ??
            [];
        _loading = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _applyCode() async {
    final code = _codeController.text.trim();
    if (code.isEmpty) return;
    setState(() {
      _applying = true;
      _applyError = null;
    });
    try {
      await ApiService.applyReferralCode(code);
      if (!mounted) return;
      _codeController.clear();
      setState(() {
        _alreadyReferred = true;
        _applying = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('🎉 Code applied! \$10 credit added to your account.'),
          backgroundColor: const Color(0xFF34A853),
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _applyError = e.toString().replaceFirst('ApiException: ', '');
        _applying = false;
      });
    }
  }

  void _share() {
    Share.share(
      'Join me on Cruise! Use my referral code $_code when you sign up and get \$10 off your first ride. Download the app now! 🚗✨',
      subject: 'Join Cruise — get \$10 off!',
    );
  }

  void _copyCode() {
    Clipboard.setData(ClipboardData(text: _code));
    HapticFeedback.lightImpact();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: const Text('Code copied to clipboard!'),
        backgroundColor: _card,
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 2),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: CustomScrollView(
        physics: const BouncingScrollPhysics(),
        slivers: [
          SliverAppBar(
            backgroundColor: _surface,
            pinned: true,
            expandedHeight: 100,
            leading: IconButton(
              icon: Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.06),
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.arrow_back_rounded,
                    color: Colors.white, size: 20),
              ),
              onPressed: () => Navigator.pop(context),
            ),
            flexibleSpace: const FlexibleSpaceBar(
              titlePadding: EdgeInsets.only(left: 56, bottom: 16),
              title: Text(
                'Invite Friends',
                style: TextStyle(
                    color: Colors.white,
                    fontSize: 20,
                    fontWeight: FontWeight.w900),
              ),
            ),
          ),
          if (_loading)
            const SliverFillRemaining(
              child: Center(
                  child: CircularProgressIndicator(color: _gold, strokeWidth: 2)),
            )
          else
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // ── Hero banner ──
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(24),
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          colors: [
                            _gold.withValues(alpha: 0.18),
                            _gold.withValues(alpha: 0.05),
                          ],
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                        ),
                        borderRadius: BorderRadius.circular(24),
                        border: Border.all(color: _gold.withValues(alpha: 0.3)),
                      ),
                      child: Column(
                        children: [
                          const Icon(Icons.card_giftcard_rounded,
                              color: _gold, size: 40),
                          const SizedBox(height: 12),
                          const Text(
                            'Give \$10, Get \$10',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 26,
                              fontWeight: FontWeight.w900,
                              letterSpacing: -0.5,
                            ),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            'Share your code with friends. When they join,\nyou both earn \$10.',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color: Colors.white.withValues(alpha: 0.6),
                              fontSize: 14,
                              height: 1.5,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 20),

                    // ── Stats row ──
                    Row(
                      children: [
                        _statCard('$_referralCount', 'Friends Joined'),
                        const SizedBox(width: 12),
                        _statCard('\$${_totalBonus.toStringAsFixed(0)}', 'Bonus Earned'),
                      ],
                    ),
                    const SizedBox(height: 20),

                    // ── Your code ──
                    Container(
                      padding: const EdgeInsets.all(20),
                      decoration: BoxDecoration(
                        color: _card,
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Your Referral Code',
                            style: TextStyle(
                              color: Colors.white.withValues(alpha: 0.5),
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const SizedBox(height: 12),
                          GestureDetector(
                            onTap: _copyCode,
                            child: Container(
                              width: double.infinity,
                              padding: const EdgeInsets.symmetric(
                                  vertical: 16, horizontal: 20),
                              decoration: BoxDecoration(
                                color: Colors.black,
                                borderRadius: BorderRadius.circular(14),
                                border: Border.all(
                                    color: _gold.withValues(alpha: 0.4)),
                              ),
                              child: Row(
                                mainAxisAlignment:
                                    MainAxisAlignment.spaceBetween,
                                children: [
                                  Text(
                                    _code,
                                    style: const TextStyle(
                                      color: _gold,
                                      fontSize: 26,
                                      fontWeight: FontWeight.w900,
                                      letterSpacing: 4,
                                    ),
                                  ),
                                  Icon(Icons.copy_rounded,
                                      color: Colors.white.withValues(alpha: 0.4),
                                      size: 20),
                                ],
                              ),
                            ),
                          ),
                          const SizedBox(height: 14),
                          SizedBox(
                            width: double.infinity,
                            height: 50,
                            child: ElevatedButton.icon(
                              onPressed: _share,
                              icon: const Icon(Icons.share_rounded, size: 18),
                              label: const Text('Share with Friends',
                                  style: TextStyle(
                                      fontSize: 15,
                                      fontWeight: FontWeight.w700)),
                              style: ElevatedButton.styleFrom(
                                backgroundColor: _gold,
                                foregroundColor: Colors.black,
                                shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(14)),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 20),

                    // ── Apply a code ──
                    if (!_alreadyReferred)
                      Container(
                        padding: const EdgeInsets.all(20),
                        decoration: BoxDecoration(
                          color: _card,
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Have a Friend\'s Code?',
                              style: TextStyle(
                                color: Colors.white.withValues(alpha: 0.5),
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            const SizedBox(height: 12),
                            Row(
                              children: [
                                Expanded(
                                  child: TextField(
                                    controller: _codeController,
                                    textCapitalization:
                                        TextCapitalization.characters,
                                    style: const TextStyle(
                                        color: Colors.white,
                                        fontSize: 16,
                                        fontWeight: FontWeight.w700,
                                        letterSpacing: 2),
                                    decoration: InputDecoration(
                                      hintText: 'ENTER CODE',
                                      hintStyle: TextStyle(
                                          color:
                                              Colors.white.withValues(alpha: 0.25),
                                          letterSpacing: 2),
                                      filled: true,
                                      fillColor: Colors.black,
                                      contentPadding:
                                          const EdgeInsets.symmetric(
                                              horizontal: 16, vertical: 14),
                                      border: OutlineInputBorder(
                                        borderRadius: BorderRadius.circular(12),
                                        borderSide: BorderSide(
                                            color: Colors.white
                                                .withValues(alpha: 0.1)),
                                      ),
                                      enabledBorder: OutlineInputBorder(
                                        borderRadius: BorderRadius.circular(12),
                                        borderSide: BorderSide(
                                            color: Colors.white
                                                .withValues(alpha: 0.1)),
                                      ),
                                      focusedBorder: OutlineInputBorder(
                                        borderRadius: BorderRadius.circular(12),
                                        borderSide: const BorderSide(
                                            color: _gold, width: 1.5),
                                      ),
                                      errorText: _applyError,
                                      errorStyle: const TextStyle(
                                          color: Colors.redAccent, fontSize: 12),
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 10),
                                SizedBox(
                                  height: 50,
                                  child: ElevatedButton(
                                    onPressed: _applying ? null : _applyCode,
                                    style: ElevatedButton.styleFrom(
                                      backgroundColor: _gold,
                                      foregroundColor: Colors.black,
                                      shape: RoundedRectangleBorder(
                                          borderRadius:
                                              BorderRadius.circular(12)),
                                      padding: const EdgeInsets.symmetric(
                                          horizontal: 18),
                                    ),
                                    child: _applying
                                        ? const SizedBox(
                                            width: 18,
                                            height: 18,
                                            child: CircularProgressIndicator(
                                                strokeWidth: 2,
                                                color: Colors.black))
                                        : const Text('Apply',
                                            style: TextStyle(
                                                fontWeight: FontWeight.w800,
                                                fontSize: 15)),
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    if (!_alreadyReferred) const SizedBox(height: 20),

                    // ── Referrals list ──
                    if (_referrals.isNotEmpty) ...[
                      const Text(
                        'Friends You\'ve Invited',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 18,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      const SizedBox(height: 14),
                      ..._referrals.map((r) {
                        final name = r['referee_name'] as String? ?? '—';
                        final bonus =
                            (r['bonus'] as num?)?.toDouble() ?? 0.0;
                        final status = r['status'] as String? ?? 'pending';
                        final rawDate = r['created_at'] as String?;
                        DateTime? date;
                        if (rawDate != null) {
                          date = DateTime.tryParse(rawDate)?.toLocal();
                        }
                        final dateStr = date != null
                            ? '${date.month}/${date.day}/${date.year}'
                            : '—';
                        final done = status == 'completed';
                        return Container(
                          margin: const EdgeInsets.only(bottom: 10),
                          padding: const EdgeInsets.all(16),
                          decoration: BoxDecoration(
                            color: _card,
                            borderRadius: BorderRadius.circular(16),
                          ),
                          child: Row(
                            children: [
                              Container(
                                width: 40,
                                height: 40,
                                decoration: BoxDecoration(
                                  color: done
                                      ? const Color(0xFF34A853)
                                          .withValues(alpha: 0.15)
                                      : Colors.white.withValues(alpha: 0.06),
                                  shape: BoxShape.circle,
                                ),
                                child: Icon(
                                  done
                                      ? Icons.check_circle_rounded
                                      : Icons.hourglass_top_rounded,
                                  color: done
                                      ? const Color(0xFF34A853)
                                      : Colors.white38,
                                  size: 18,
                                ),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(name,
                                        style: const TextStyle(
                                            color: Colors.white,
                                            fontSize: 15,
                                            fontWeight: FontWeight.w600)),
                                    Text(dateStr,
                                        style: TextStyle(
                                            color: Colors.white
                                                .withValues(alpha: 0.4),
                                            fontSize: 12)),
                                  ],
                                ),
                              ),
                              Text(
                                '+\$${bonus.toStringAsFixed(0)}',
                                style: TextStyle(
                                  color: done
                                      ? const Color(0xFF34A853)
                                      : Colors.white38,
                                  fontSize: 16,
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                            ],
                          ),
                        );
                      }),
                    ],

                    const SizedBox(height: 32),

                    // ── How it works ──
                    Container(
                      padding: const EdgeInsets.all(20),
                      decoration: BoxDecoration(
                        color: _card,
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text('How it works',
                              style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 16,
                                  fontWeight: FontWeight.w700)),
                          const SizedBox(height: 16),
                          _howStep('1', 'Share your code',
                              'Send your unique code to friends.'),
                          const SizedBox(height: 12),
                          _howStep('2', 'Friend signs up',
                              'They enter your code when registering.'),
                          const SizedBox(height: 12),
                          _howStep('3', 'You both earn \$10',
                              'Bonus is added to your accounts instantly.'),
                        ],
                      ),
                    ),
                    const SizedBox(height: 32),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _statCard(String value, String label) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 18, horizontal: 16),
        decoration: BoxDecoration(
          color: _card,
          borderRadius: BorderRadius.circular(18),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(value,
                style: const TextStyle(
                    color: _gold,
                    fontSize: 26,
                    fontWeight: FontWeight.w900)),
            const SizedBox(height: 4),
            Text(label,
                style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.45),
                    fontSize: 13,
                    fontWeight: FontWeight.w500)),
          ],
        ),
      ),
    );
  }

  Widget _howStep(String num, String title, String desc) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 28,
          height: 28,
          decoration: BoxDecoration(
            color: _gold.withValues(alpha: 0.15),
            shape: BoxShape.circle,
          ),
          child: Center(
            child: Text(num,
                style: const TextStyle(
                    color: _gold,
                    fontSize: 13,
                    fontWeight: FontWeight.w800)),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title,
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 14,
                      fontWeight: FontWeight.w700)),
              const SizedBox(height: 2),
              Text(desc,
                  style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.45),
                      fontSize: 13)),
            ],
          ),
        ),
      ],
    );
  }
}
