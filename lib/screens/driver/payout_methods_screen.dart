import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_stripe/flutter_stripe.dart' as stripe;
import 'package:url_launcher/url_launcher.dart';
import '../../l10n/app_localizations.dart';
import '../../services/api_service.dart';
import '../../widgets/gold_particles_background.dart';

/// Payout Methods screen — Stripe Connect-powered, real end-to-end.
///
/// Two ways to add a destination for cashouts:
///
///   1. **Connect bank account** — opens Stripe Connect Express
///      onboarding (hosted flow). Stripe handles bank-account capture,
///      identity verification, and creates the external_account on the
///      Connect account. We poll status every 3-10s for up to 5 min and
///      record the row when both ``charges_enabled`` AND
///      ``payouts_enabled`` flip to true.
///
///   2. **Add debit card** — uses the Stripe Flutter SDK
///      (``flutter_stripe``) to tokenize the PAN client-side. We send
///      only the resulting ``card_token`` (e.g. ``tok_visa``) to the
///      backend, which attaches it to the driver's Connect account as
///      an external_account for **instant cashouts**. The raw PAN
///      never reaches our servers.
///
/// Defaults: backend atomically clears other defaults whenever a row is
/// promoted, so the cashout flow always sees exactly one default row.
class PayoutMethodsScreen extends StatefulWidget {
  const PayoutMethodsScreen({super.key});

  @override
  State<PayoutMethodsScreen> createState() => _PayoutMethodsScreenState();
}

class _PayoutMethodsScreenState extends State<PayoutMethodsScreen> {
  static const _gold = Color(0xFFD4A843);
  static const _card = Color(0xFF1C1C1E);

  List<Map<String, dynamic>> _methods = [];
  bool _loading = true;
  bool _linkingBank = false;

  @override
  void initState() {
    super.initState();
    _loadMethods();
  }

  Future<void> _loadMethods() async {
    try {
      _methods = await ApiService.getPayoutMethods();
    } catch (_) {}
    if (mounted) setState(() => _loading = false);
  }

  bool get _hasDebitCard =>
      _methods.any((m) => m['method_type'] == 'debit_card');

  /// Strip the hidden ``[ext:xxx]`` Stripe-id suffix from a display name
  /// so the UI shows just "Visa ····1234".
  String _cleanDisplay(String raw) {
    final idx = raw.indexOf('[ext:');
    if (idx < 0) return raw;
    return raw.substring(0, idx).trim();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: GoldParticlesBackground(child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
              child: Stack(
                alignment: Alignment.center,
                children: [
                  Align(
                    alignment: Alignment.centerLeft,
                    child: GestureDetector(
                      onTap: () => Navigator.pop(context),
                      child: Container(
                        width: 40,
                        height: 40,
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.06),
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(
                          Icons.arrow_back_rounded,
                          color: Colors.white,
                          size: 20,
                        ),
                      ),
                    ),
                  ),
                  Text(
                    S.of(context).payoutMethodsTitle,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 20,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 24),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [
                      _gold.withValues(alpha: 0.12),
                      _gold.withValues(alpha: 0.03),
                    ],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: _gold.withValues(alpha: 0.15)),
                ),
                child: Row(
                  children: [
                    Container(
                      width: 48,
                      height: 48,
                      decoration: BoxDecoration(
                        color: _gold.withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: const Icon(
                        Icons.flash_on_rounded,
                        color: _gold,
                        size: 24,
                      ),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            S.of(context).instantCashout,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 16,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            S.of(context).plaidLinkDescription,
                            style: TextStyle(
                              color: Colors.white.withValues(alpha: 0.45),
                              fontSize: 12,
                              height: 1.4,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 24),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Row(
                children: [
                  Text(
                    S.of(context).linkedAccounts,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 18,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const Spacer(),
                  Text(
                    '${_methods.length}',
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.3),
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 10),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 10,
                ),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.03),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: Colors.white.withValues(alpha: 0.05),
                  ),
                ),
                child: Row(
                  children: [
                    Icon(
                      Icons.lock_rounded,
                      color: const Color(0xFF4CAF50).withValues(alpha: 0.7),
                      size: 16,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        S.of(context).plaidSecurityNote,
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.35),
                          fontSize: 11,
                          height: 1.3,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 14),
            Expanded(
              child: _loading
                  ? const Center(
                      child: CircularProgressIndicator(
                        color: _gold,
                        strokeWidth: 2,
                      ),
                    )
                  : _methods.isEmpty
                  ? _buildEmpty()
                  : ListView.separated(
                      physics: const BouncingScrollPhysics(),
                      padding: const EdgeInsets.symmetric(horizontal: 20),
                      itemCount: _methods.length,
                      separatorBuilder: (_, __) => const SizedBox(height: 8),
                      itemBuilder: (_, i) => _buildMethodCard(_methods[i]),
                    ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
              child: Column(
                children: [
                  SizedBox(
                    width: double.infinity,
                    height: 56,
                    child: ElevatedButton.icon(
                      onPressed: _linkingBank ? null : _connectBankAccount,
                      icon: _linkingBank
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(
                                color: Colors.black,
                                strokeWidth: 2,
                              ),
                            )
                          : const Icon(Icons.account_balance_rounded, size: 20),
                      label: Text(
                        _linkingBank
                            ? S.of(context).connectingLabel
                            : S.of(context).connectBankAccount,
                        style: const TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: _gold,
                        foregroundColor: Colors.black,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(16),
                        ),
                      ),
                    ),
                  ),
                  if (!_hasDebitCard) ...[
                    const SizedBox(height: 8),
                    SizedBox(
                      width: double.infinity,
                      height: 50,
                      child: OutlinedButton.icon(
                        onPressed: _linkingBank ? null : _connectDebitCard,
                        icon: const Icon(Icons.credit_card_rounded, size: 20),
                        label: Text(
                          S.of(context).addDebitCard,
                          style: const TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: _gold,
                          side: BorderSide(color: _gold.withValues(alpha: 0.3)),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(16),
                          ),
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      )),
    );
  }

  Widget _buildEmpty() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 80,
            height: 80,
            decoration: BoxDecoration(
              color: _gold.withValues(alpha: 0.06),
              borderRadius: BorderRadius.circular(24),
            ),
            child: Icon(
              Icons.account_balance_rounded,
              color: _gold.withValues(alpha: 0.3),
              size: 36,
            ),
          ),
          const SizedBox(height: 16),
          Text(
            S.of(context).noPayoutMethods,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 17,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            S.of(context).connectBankForCashouts,
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.4),
              fontSize: 13,
              height: 1.4,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 24),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.04),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.shield_rounded,
                  color: _gold.withValues(alpha: 0.6),
                  size: 16,
                ),
                const SizedBox(width: 6),
                Text(
                  S.of(context).poweredByPlaid,
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.35),
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ── Card brand: parse from display_name (e.g. "Visa ····1234") ──
  static _CardBrand _brandFromDisplay(String display) {
    final lower = display.toLowerCase();
    if (lower.contains('visa')) return _CardBrand.visa;
    if (lower.contains('master')) return _CardBrand.mastercard;
    if (lower.contains('amex') || lower.contains('american')) {
      return _CardBrand.amex;
    }
    if (lower.contains('discover')) return _CardBrand.discover;
    return _CardBrand.unknown;
  }

  static Widget _brandIcon(_CardBrand brand, {double size = 28}) {
    switch (brand) {
      case _CardBrand.visa:
        return Container(
          width: size + 8,
          height: size - 4,
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(4),
          ),
          alignment: Alignment.center,
          child: Text(
            'VISA',
            style: TextStyle(
              color: const Color(0xFF1A1F71),
              fontSize: size * 0.38,
              fontWeight: FontWeight.w900,
              letterSpacing: -0.5,
              fontStyle: FontStyle.italic,
            ),
          ),
        );
      case _CardBrand.mastercard:
        return SizedBox(
          width: size + 4,
          height: size - 4,
          child: Stack(
            alignment: Alignment.center,
            children: [
              Positioned(
                left: 0,
                child: Container(
                  width: size * 0.6,
                  height: size * 0.6,
                  decoration: const BoxDecoration(
                    color: Color(0xFFEB001B),
                    shape: BoxShape.circle,
                  ),
                ),
              ),
              Positioned(
                right: 0,
                child: Container(
                  width: size * 0.6,
                  height: size * 0.6,
                  decoration: BoxDecoration(
                    color: const Color(0xFFF79E1B).withValues(alpha: 0.9),
                    shape: BoxShape.circle,
                  ),
                ),
              ),
            ],
          ),
        );
      case _CardBrand.amex:
        return Container(
          width: size + 8,
          height: size - 4,
          decoration: BoxDecoration(
            color: const Color(0xFF2E77BC),
            borderRadius: BorderRadius.circular(4),
          ),
          alignment: Alignment.center,
          child: Text(
            'AMEX',
            style: TextStyle(
              color: Colors.white,
              fontSize: size * 0.32,
              fontWeight: FontWeight.w900,
              letterSpacing: 0.5,
            ),
          ),
        );
      case _CardBrand.discover:
        return Container(
          width: size + 8,
          height: size - 4,
          decoration: BoxDecoration(
            color: const Color(0xFFFF6600),
            borderRadius: BorderRadius.circular(4),
          ),
          alignment: Alignment.center,
          child: Text(
            'D',
            style: TextStyle(
              color: Colors.white,
              fontSize: size * 0.5,
              fontWeight: FontWeight.w900,
              fontStyle: FontStyle.italic,
            ),
          ),
        );
      case _CardBrand.unknown:
        return const Icon(
          Icons.credit_card_rounded,
          color: Color(0xFF2196F3),
          size: 28,
        );
    }
  }

  Widget _buildMethodCard(Map<String, dynamic> method) {
    final type = method['method_type'] ?? 'bank_account';
    final rawDisplay = (method['display_name'] ?? 'Bank account').toString();
    final display = _cleanDisplay(rawDisplay);
    final isDefault = method['is_default'] == true;
    final id = method['id'];
    Widget leadingIcon;
    if (type == 'debit_card') {
      leadingIcon = _brandIcon(_brandFromDisplay(display), size: 32);
    } else {
      leadingIcon = const Icon(
        Icons.account_balance_rounded,
        color: Color(0xFF4CAF50),
        size: 24,
      );
    }
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: _card,
        borderRadius: BorderRadius.circular(18),
        border: isDefault
            ? Border.all(color: _gold.withValues(alpha: 0.3))
            : null,
      ),
      child: Row(
        children: [
          Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              color: type == 'debit_card'
                  ? Colors.white.withValues(alpha: 0.06)
                  : const Color(0xFF4CAF50).withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(14),
            ),
            child: Center(child: leadingIcon),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        display,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    if (isDefault)
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 3,
                        ),
                        decoration: BoxDecoration(
                          color: _gold.withValues(alpha: 0.15),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(
                          S.of(context).defaultBadge,
                          style: const TextStyle(
                            color: _gold,
                            fontSize: 10,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  type == 'debit_card'
                      ? S.of(context).instantCashout
                      : S.of(context).bankTransferType,
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.35),
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          if (!isDefault)
            GestureDetector(
              onTap: () => _setDefault(id),
              child: Container(
                margin: const EdgeInsets.only(right: 6),
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: BoxDecoration(
                  color: _gold.withValues(alpha: 0.10),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: _gold.withValues(alpha: 0.35)),
                ),
                child: const Text(
                  'Set Default',
                  style: TextStyle(
                    color: _gold,
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ),
          GestureDetector(
            onTap: () => _confirmDelete(id, display),
            child: Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.04),
                shape: BoxShape.circle,
              ),
              child: Icon(
                Icons.delete_outline_rounded,
                color: Colors.white.withValues(alpha: 0.3),
                size: 18,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _setDefault(dynamic id) async {
    HapticFeedback.lightImpact();
    try {
      await ApiService.setDefaultPayoutMethod(
        id is int ? id : int.parse(id.toString()),
      );
      await _loadMethods();
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(S.of(context).failedToAddMethod),
            backgroundColor: Colors.red,
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
          ),
        );
      }
    }
  }

  Future<void> _connectBankAccount() async {
    HapticFeedback.mediumImpact();
    setState(() => _linkingBank = true);
    try {
      final url = await ApiService.getStripeConnectLink();
      if (!mounted) return;
      if (url.isEmpty) {
        // No Stripe configured server-side — bail out cleanly.
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Bank linking is temporarily unavailable.'),
            duration: Duration(seconds: 4),
          ),
        );
        return;
      }
      await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);

      // Poll Stripe Connect status until both charges_enabled AND
      // payouts_enabled flip true (up to ~5 min).
      bool connected = false;
      for (int attempt = 0; attempt < 30 && mounted; attempt++) {
        final delay = attempt < 10 ? 3 : (attempt < 20 ? 6 : 10);
        await Future.delayed(Duration(seconds: delay));
        if (!mounted) break;
        try {
          final status = await ApiService.getStripeConnectStatus();
          final ok = status['connected'] == true &&
              status['payouts_enabled'] == true;
          if (ok) {
            connected = true;
            if (!mounted) break;
            final acctId = (status['stripe_account_id'] ?? '').toString();
            final tail = acctId.length > 4
                ? acctId.substring(acctId.length - 4)
                : acctId;
            await _addBankMethod('Bank account ····$tail');
            break;
          }
        } catch (_) {}
      }
      if (!connected && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Complete Stripe onboarding to activate your bank account.',
            ),
            duration: Duration(seconds: 5),
          ),
        );
      }
      if (mounted) await _loadMethods();
    } catch (e) {
      debugPrint('[Payout] Stripe Connect error: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(S.of(context).failedToAddMethod),
            backgroundColor: Colors.red,
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _linkingBank = false);
    }
  }

  Future<void> _addBankMethod(String displayName) async {
    try {
      await ApiService.addPayoutMethod(
        methodType: 'bank_account',
        displayName: displayName,
        setDefault: _methods.isEmpty,
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(S.of(context).bankAccountLinked),
            backgroundColor: _gold,
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
          ),
        );
      }
    } catch (_) {
      // Silent — _loadMethods() will surface anything that did persist
      // server-side. Most likely cause is a duplicate row from a retry.
    }
  }

  /// Open the Stripe Flutter SDK card sheet, tokenize the PAN, then send
  /// the resulting card_token to our backend so it can be attached as a
  /// Stripe Connect external_account. The raw PAN never reaches our
  /// servers.
  Future<void> _connectDebitCard() async {
    HapticFeedback.mediumImpact();
    setState(() => _linkingBank = true);
    try {
      // Stripe.instance.createToken with CardTokenParams.
      // The Stripe SDK raises a native sheet when called the first time
      // in a session if no card is buffered. For drivers we use the
      // embedded CardField approach in the Wallet flow already, so here
      // we present a SetupIntent-style sheet.
      final tokenResult = await stripe.Stripe.instance.createToken(
        const stripe.CreateTokenParams.card(
          params: stripe.CardTokenParams(
            type: stripe.TokenType.Card,
          ),
        ),
      );
      final tokenId = tokenResult.id;
      if (tokenId.isEmpty) {
        throw Exception('Empty card token from Stripe');
      }

      await ApiService.addDebitCardPayout(
        cardToken: tokenId,
        setDefault: _methods.isEmpty,
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(S.of(context).debitCardAdded),
            backgroundColor: _gold,
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
          ),
        );
      }
      if (mounted) await _loadMethods();
    } on stripe.StripeException catch (e) {
      if (e.error.code == stripe.FailureCode.Canceled) {
        // User dismissed the card sheet — silent no-op.
      } else if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              e.error.localizedMessage ?? S.of(context).failedToAddMethod,
            ),
            backgroundColor: Colors.red,
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
          ),
        );
      }
    } catch (e) {
      debugPrint('[Payout] addDebitCard error: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(S.of(context).failedToAddMethod),
            backgroundColor: Colors.red,
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _linkingBank = false);
    }
  }

  void _confirmDelete(dynamic id, String name) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) => Container(
        padding: const EdgeInsets.all(28),
        decoration: const BoxDecoration(
          color: _card,
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
            Icon(
              Icons.warning_amber_rounded,
              color: Colors.red.withValues(alpha: 0.7),
              size: 42,
            ),
            const SizedBox(height: 16),
            Text(
              S.of(context).removePayoutMethod,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 18,
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              S.of(context).confirmRemoveMethod(name),
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.5),
                fontSize: 14,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            Row(
              children: [
                Expanded(
                  child: SizedBox(
                    height: 50,
                    child: OutlinedButton(
                      onPressed: () => Navigator.pop(ctx),
                      style: OutlinedButton.styleFrom(
                        side: BorderSide(
                          color: Colors.white.withValues(alpha: 0.15),
                        ),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14),
                        ),
                      ),
                      child: Text(
                        S.of(context).cancel,
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: SizedBox(
                    height: 50,
                    child: ElevatedButton(
                      onPressed: () async {
                        Navigator.pop(ctx);
                        await _deleteMethod(id);
                      },
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.red.withValues(alpha: 0.8),
                        foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14),
                        ),
                      ),
                      child: Text(
                        S.of(context).removeLabel,
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  Future<void> _deleteMethod(dynamic id) async {
    try {
      await ApiService.deletePayoutMethod(
        id is int ? id : int.parse(id.toString()),
      );
      setState(() => _methods.removeWhere((m) => m['id'] == id));
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(S.of(context).payoutMethodRemoved),
            backgroundColor: _gold,
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
          ),
        );
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(S.of(context).failedToRemoveMethod),
            backgroundColor: Colors.red,
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
          ),
        );
      }
    }
  }
}

// ═══════════════════════════════════════════════════════════════
//  Card brand enum
// ═══════════════════════════════════════════════════════════════
enum _CardBrand { visa, mastercard, amex, discover, unknown }
