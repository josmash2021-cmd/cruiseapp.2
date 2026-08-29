import '../utils/app_platform.dart';

import 'package:flutter/material.dart';
import '../config/app_theme.dart';
import '../config/page_transitions.dart';
import '../l10n/app_localizations.dart';
import '../services/api_service.dart';
import '../widgets/neu_style.dart';
import '../widgets/shimmer_placeholders.dart';
import 'payment_accounts_screen.dart';
import 'referral_screen.dart';

/// WalletScreen - Rider payment methods configured for trip payments.
class WalletScreen extends StatefulWidget {
  const WalletScreen({super.key});

  @override
  State<WalletScreen> createState() => _WalletScreenState();
}

class _WalletScreenState extends State<WalletScreen> {
  static const _gold = Color(0xFFE8C547);

  bool _loading = true;
  List<Map<String, dynamic>> _methods = [];
  String? _error;
  int _cruiseCashCents = 0;

  @override
  void initState() {
    super.initState();
    _loadMethods();
    _loadCruiseCash();
  }

  @override
  void dispose() {
    super.dispose();
  }

  Future<void> _loadCruiseCash() async {
    try {
      final res = await ApiService.getMyReferralInfo();
      if (!mounted) return;
      setState(() => _cruiseCashCents =
          (res['balance_cents'] as num?)?.toInt() ?? 0);
    } catch (_) {/* silent */}
  }

  Future<void> _loadMethods() async {
    if (!mounted) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final methods = await ApiService.getRiderPaymentMethods();
      if (!mounted) return;
      setState(() {
        _methods = methods
            .where((m) => _isAllowedMethodType(m['method_type'] as String? ?? ''))
            .toList();
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      debugPrint('[Wallet] methods load error: $e');
      setState(() {
        _error = 'Failed to load payment methods';
        _loading = false;
      });
    }
  }

  bool _isAllowedMethodType(String methodType) {
    if (methodType == 'stripe_card' ||
        methodType == 'paypal' ||
        methodType == 'bank_account') {
      return true;
    }
    if (AppPlatform.isIOS) return methodType == 'apple_pay';
    if (AppPlatform.isAndroid) return methodType == 'google_pay';
    return false;
  }

  Future<void> _openPaymentAccounts() async {
    await Navigator.push(
      context,
      slideFromRightRoute(const PaymentAccountsScreen()),
    );
    if (!mounted) return;
    await _loadMethods();
  }

  String _methodLabel(Map<String, dynamic> m) {
    final display = (m['display_name'] as String?)?.trim() ?? '';
    if (display.isNotEmpty) return display;
    return _methodTypeLabel(m['method_type'] as String? ?? '');
  }

  String _methodTypeLabel(String methodType) {
    switch (methodType) {
      case 'stripe_card':
        return 'Card';
      case 'paypal':
        return 'PayPal';
      case 'google_pay':
        return 'Google Pay';
      case 'apple_pay':
        return 'Apple Pay';
      case 'bank_account':
        return 'Bank account';
      default:
        return 'Payment method';
    }
  }

  IconData _methodIcon(String methodType) {
    switch (methodType) {
      case 'stripe_card':
        return Icons.credit_card_rounded;
      case 'paypal':
        return Icons.account_balance_wallet_rounded;
      case 'google_pay':
        return Icons.g_mobiledata_rounded;
      case 'apple_pay':
        return Icons.apple;
      case 'bank_account':
        return Icons.account_balance_rounded;
      default:
        return Icons.payment_rounded;
    }
  }

  Color _methodColor(String methodType) {
    switch (methodType) {
      case 'stripe_card':
        return const Color(0xFF2196F3);
      case 'paypal':
        return const Color(0xFF003087);
      case 'google_pay':
        return const Color(0xFF4285F4);
      case 'apple_pay':
        return Colors.white;
      case 'bank_account':
        return const Color(0xFF4CAF50);
      default:
        return const Color(0xFF9CA3AF);
    }
  }

  /// Circular neumorphic icon button (back / refresh).
  Widget _neuIconButton(IconData icon, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 42,
        height: 42,
        decoration: neuBox(radius: 21),
        alignment: Alignment.center,
        child: Icon(icon, size: 18, color: Colors.white),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final loc = S.of(context);

    return Scaffold(
      backgroundColor: neuBase,
      // The shared backdrop, so this page sits on the same
      // surface as the menu it is reached from.
      body: Stack(
        children: [
          const Positioned.fill(child: NeuDotsBackdrop()),
          SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(height: 12),

            // ── Back button + refresh ──
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Row(
                children: [
                  _neuIconButton(
                    Icons.arrow_back_ios_new_rounded,
                    () => Navigator.pop(context),
                  ),
                  const Spacer(),
                  _neuIconButton(Icons.refresh_rounded, _loadMethods),
                ],
              ),
            ),
            const SizedBox(height: 28),

            // ── Title ──
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Text(
                loc.wallet,
                style: TextStyle(
                  fontSize: 28,
                  fontWeight: FontWeight.w800,
                  color: c.textPrimary,
                  letterSpacing: -0.5,
                ),
              ),
            ),
            const SizedBox(height: 20),

            // ── Content ──
            Expanded(
              child: _loading
                  // The screen's own layout, shimmering — a spinner on a
                  // blank page told the rider nothing about what was coming.
                  ? const WalletShimmer()
                  : _error != null
                      ? _buildError()
                      : _buildContent(c, loc),
            ),
          ],
        ),
      ),
        ],
      ),
    );
  }

  Widget _buildError() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            width: 64,
            height: 64,
            decoration: neuBox(radius: 32, pressed: true),
            alignment: Alignment.center,
            child: Icon(Icons.error_outline_rounded,
                size: 30, color: Colors.red.shade300),
          ),
          const SizedBox(height: 16),
          Text(_error!, style: const TextStyle(color: Colors.white70)),
          const SizedBox(height: 24),
          GestureDetector(
            onTap: _loadMethods,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 12),
              decoration: BoxDecoration(
                color: _gold,
                borderRadius: BorderRadius.circular(24),
                boxShadow: [
                  BoxShadow(
                    color: _gold.withValues(alpha: 0.30),
                    blurRadius: 16,
                    offset: const Offset(0, 6),
                  ),
                ],
              ),
              child: Text(
                S.of(context).retry,
                style: const TextStyle(
                  color: Colors.black,
                  fontWeight: FontWeight.w800,
                  fontSize: 14,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildContent(AppColors c, S loc) {
    return RefreshIndicator(
      onRefresh: () async {
        await _loadMethods();
        await _loadCruiseCash();
      },
      color: _gold,
      child: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          // ── Cruise Cash card — referral credit balance ──
          _buildCruiseCashCard(),
          const SizedBox(height: 24),
          Row(
            children: [
              Expanded(
                child: Text(
                  loc.paymentMethods,
                  style: TextStyle(
                    color: c.textPrimary,
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              GestureDetector(
                onTap: _openPaymentAccounts,
                child: Row(
                  children: [
                    const Icon(Icons.edit_rounded, size: 15, color: _gold),
                    const SizedBox(width: 5),
                    Text(
                      S.of(context).manageLabel,
                      style: const TextStyle(
                        color: _gold,
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          if (_methods.isEmpty)
            _buildEmptyMethods(c)
          else
            ..._methods.map((m) => _buildMethodItem(m, c)),
        ],
      ),
    );
  }

  Widget _buildCruiseCashCard() {
    final dollars = (_cruiseCashCents / 100.0).toStringAsFixed(2);
    return GestureDetector(
      onTap: () async {
        await Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => const ReferralScreen()),
        );
        if (mounted) _loadCruiseCash();
      },
      // Built like a saved payment method, because that is what it is.
      //
      // No gold rim (user spec 2026-08-29): it reads as another card in the
      // wallet, not as a banner sitting above the list.
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: neuBox(radius: 16),
        child: Row(
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: neuBox(radius: 12, pressed: true),
              alignment: Alignment.center,
              child: const Icon(Icons.card_giftcard_rounded,
                  color: _gold, size: 20),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'CRUISE CASH',
                    style: TextStyle(
                      fontFamily: 'Poppins',
                      color: _gold.withValues(alpha: 0.80),
                      fontSize: 10.5,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 1.2,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '\$$dollars',
                    style: const TextStyle(
                      fontFamily: 'Poppins',
                      color: _gold,
                      fontSize: 17,
                      fontWeight: FontWeight.w800,
                      letterSpacing: -0.3,
                    ),
                  ),
                ],
              ),
            ),
            const Icon(Icons.chevron_right_rounded,
                color: _gold, size: 20),
          ],
        ),
      ),
    );
  }

  Widget _buildEmptyMethods(AppColors c) {
    return Container(
      padding: const EdgeInsets.all(32),
      decoration: neuBox(radius: 22),
      child: Column(
        children: [
          Container(
            width: 60,
            height: 60,
            decoration: neuBox(radius: 30, pressed: true),
            alignment: Alignment.center,
            child: Icon(Icons.credit_card_off_rounded,
                size: 26, color: c.textTertiary),
          ),
          const SizedBox(height: 16),
          Text(S.of(context).noPaymentMethods, style: TextStyle(
            color: c.textSecondary,
            fontSize: 14,
            fontWeight: FontWeight.w600,
          )),
          const SizedBox(height: 4),
          Text(S.of(context).addMethodDescription, style: TextStyle(
            color: c.textTertiary,
            fontSize: 12,
          )),
          const SizedBox(height: 20),
          GestureDetector(
            onTap: _openPaymentAccounts,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 12),
              decoration: BoxDecoration(
                color: _gold,
                borderRadius: BorderRadius.circular(24),
                boxShadow: [
                  BoxShadow(
                    color: _gold.withValues(alpha: 0.30),
                    blurRadius: 16,
                    offset: const Offset(0, 6),
                  ),
                ],
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.add_rounded, color: Colors.black, size: 18),
                  const SizedBox(width: 6),
                  Text(
                    S.of(context).addPaymentMethod,
                    style: const TextStyle(
                      color: Colors.black,
                      fontWeight: FontWeight.w800,
                      fontSize: 13.5,
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

  Widget _buildMethodItem(Map<String, dynamic> method, AppColors c) {
    final methodType = method['method_type'] as String? ?? '';
    final isDefault = method['is_default'] == true;
    final icon = _methodIcon(methodType);
    final iconColor = _methodColor(methodType);
    final label = _methodLabel(method);

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(14),
      decoration: neuBox(radius: 16).copyWith(
        border: isDefault
            ? Border.all(color: _gold.withValues(alpha: 0.45), width: 1.4)
            : Border.all(color: Colors.white.withValues(alpha: 0.04), width: 1),
      ),
      child: Row(
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: neuBox(radius: 12, pressed: true),
            alignment: Alignment.center,
            child: Icon(icon, color: iconColor, size: 20),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: TextStyle(
                  color: c.textPrimary,
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                )),
                Text(
                  _methodTypeLabel(methodType),
                  style: TextStyle(color: c.textTertiary, fontSize: 12),
                ),
              ],
            ),
          ),
          if (isDefault)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              decoration: neuBox(radius: 10, pressed: true),
              child: const Text(
                'Default',
                style: TextStyle(
                  color: _gold,
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
        ],
      ),
    );
  }
}
