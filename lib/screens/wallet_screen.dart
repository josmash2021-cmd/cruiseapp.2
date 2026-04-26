import 'dart:io';

import 'package:flutter/material.dart';
import '../config/app_theme.dart';
import '../config/page_transitions.dart';
import '../l10n/app_localizations.dart';
import '../services/api_service.dart';
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
    if (methodType == 'stripe_card' || methodType == 'paypal') return true;
    if (Platform.isIOS) return methodType == 'apple_pay';
    if (Platform.isAndroid) return methodType == 'google_pay';
    return false;
  }

  void _showSnack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(
        content: Text(msg),
        // Uses global snackBarTheme
      ));
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

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final loc = S.of(context);

    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(height: 8),

            // ── Back button + refresh ──
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Row(
                children: [
                  GestureDetector(
                    onTap: () => Navigator.pop(context),
                    child: Container(
                      width: 40,
                      height: 40,
                      decoration: BoxDecoration(
                        color: c.surface,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: c.border),
                      ),
                      child: Icon(Icons.arrow_back_ios_new_rounded, size: 18, color: c.textPrimary),
                    ),
                  ),
                  const Spacer(),
                  GestureDetector(
                    onTap: _loadMethods,
                    child: Icon(Icons.refresh_rounded, color: c.textPrimary, size: 22),
                  ),
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
                  ? const Center(child: CircularProgressIndicator(color: _gold))
                  : _error != null
                      ? _buildError()
                      : _buildContent(c, loc),
            ),
          ],
        ),
      ),
    );
  }

  Widget _backButton(AppColors c) {
    return Padding(
      padding: const EdgeInsets.only(left: 12, top: 8, bottom: 8),
      child: GestureDetector(
        onTap: () => Navigator.pop(context),
        child: Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            color: c.surface,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: c.border),
          ),
          child: Icon(Icons.arrow_back_ios_new_rounded, size: 18, color: c.textPrimary),
        ),
      ),
    );
  }

  Widget _buildError() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.error_outline_rounded, size: 48, color: Colors.red.shade300),
          const SizedBox(height: 16),
          Text(_error!, style: const TextStyle(color: Colors.white70)),
          const SizedBox(height: 24),
          ElevatedButton(
            onPressed: _loadMethods,
            style: ElevatedButton.styleFrom(backgroundColor: _gold),
            child: Text(S.of(context).retry, style: const TextStyle(color: Colors.black)),
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
          _buildCruiseCashCard(c),
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
              TextButton.icon(
                onPressed: _openPaymentAccounts,
                icon: const Icon(Icons.edit_rounded, size: 16),
                label: Text(S.of(context).manageLabel),
              ),
            ],
          ),
          const SizedBox(height: 12),
          if (_methods.isEmpty)
            _buildEmptyMethods(c)
          else
            ..._methods.map((m) => _buildMethodItem(m, c)),
        ],
      ),
    );
  }

  Widget _buildCruiseCashCard(AppColors c) {
    final dollars = (_cruiseCashCents / 100.0).toStringAsFixed(2);
    return GestureDetector(
      onTap: () async {
        await Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => const ReferralScreen()),
        );
        if (mounted) _loadCruiseCash();
      },
      child: Container(
        padding: const EdgeInsets.fromLTRB(20, 18, 18, 18),
        decoration: BoxDecoration(
          color: const Color(0xFF111111),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: _gold.withValues(alpha: 0.30), width: 1.2),
          boxShadow: [
            BoxShadow(
              color: _gold.withValues(alpha: 0.10),
              blurRadius: 22,
              spreadRadius: 1,
            ),
          ],
        ),
        child: Row(
          children: [
            Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(
                color: _gold.withValues(alpha: 0.14),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(
                    color: _gold.withValues(alpha: 0.40), width: 1),
              ),
              alignment: Alignment.center,
              child: const Icon(Icons.card_giftcard_rounded,
                  color: _gold, size: 22),
            ),
            const SizedBox(width: 14),
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
                  const SizedBox(height: 4),
                  Text(
                    '\$$dollars',
                    style: const TextStyle(
                      fontFamily: 'Poppins',
                      color: _gold,
                      fontSize: 28,
                      fontWeight: FontWeight.w900,
                      letterSpacing: -0.6,
                    ),
                  ),
                ],
              ),
            ),
            const Icon(Icons.chevron_right_rounded,
                color: _gold, size: 22),
          ],
        ),
      ),
    );
  }

  Widget _buildEmptyMethods(AppColors c) {
    return Container(
      padding: const EdgeInsets.all(32),
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: c.border),
      ),
      child: Column(
        children: [
          Icon(Icons.credit_card_off_rounded, size: 40, color: c.textTertiary),
          const SizedBox(height: 12),
          Text(S.of(context).noPaymentMethods, style: TextStyle(
            color: c.textSecondary,
            fontSize: 14,
          )),
          const SizedBox(height: 4),
          Text(S.of(context).addMethodDescription, style: TextStyle(
            color: c.textTertiary,
            fontSize: 12,
          )),
          const SizedBox(height: 16),
          ElevatedButton.icon(
            onPressed: _openPaymentAccounts,
            icon: const Icon(Icons.add_rounded),
            label: Text(S.of(context).addPaymentMethod),
            style: ElevatedButton.styleFrom(
              backgroundColor: _gold,
              foregroundColor: Colors.black,
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
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: isDefault ? _gold.withValues(alpha: 0.08) : c.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: isDefault ? _gold.withValues(alpha: 0.40) : c.border,
          width: isDefault ? 1.5 : 1,
        ),
      ),
      child: Row(
        children: [
          Container(
            width: 42,
            height: 42,
            decoration: BoxDecoration(
              color: iconColor.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(10),
            ),
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
                  style: TextStyle(color: c.textTertiary, fontSize: 11),
                ),
              ],
            ),
          ),
          if (isDefault)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: _gold.withValues(alpha: 0.14),
                borderRadius: BorderRadius.circular(8),
              ),
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
