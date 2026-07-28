import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_stripe/flutter_stripe.dart' as stripe;

import '../../l10n/app_localizations.dart';
import '../../services/api_service.dart';
import '../../services/haptic_service.dart';
import '../../widgets/neu_style.dart';

/// Payout Methods screen — Stripe Connect-powered, real end-to-end.
///
/// Two destinations the driver can attach to their Connect account:
///
///   1. **Connect bank account** — opens the Stripe Financial Connections
///      sheet via the native SDK (`collectBankAccountToken`) using the
///      `client_secret` minted by `POST /drivers/financial-connections`.
///      Stripe returns a `btok_...`; the backend attaches it as an
///      external_account, which is where the weekly Tuesday ACH payout
///      lands. Account and routing numbers never reach our servers.
///
///   2. **Add debit card** — a `CardField` sheet tokenizes the PAN
///      client-side (`createToken` with `currency: usd`, which is what
///      marks the token as usable for payouts). We send only the
///      `tok_...`, which the backend attaches as an external_account for
///      **instant cashouts**. The raw PAN never reaches our servers.
///
/// Both flows are native-only — `flutter_stripe` has no web implementation,
/// so on web the buttons explain that instead of throwing.
///
/// Defaults: the backend atomically clears other defaults whenever a row is
/// promoted, so the cashout flow always sees exactly one default row.
class PayoutMethodsScreen extends StatefulWidget {
  const PayoutMethodsScreen({super.key});

  @override
  State<PayoutMethodsScreen> createState() => _PayoutMethodsScreenState();
}

class _PayoutMethodsScreenState extends State<PayoutMethodsScreen> {
  static const _gold = Color(0xFFD4A843);
  static const _green = Color(0xFF4CAF50);
  static const _danger = Color(0xFFFF5252);
  static const _text = Colors.white;

  List<Map<String, dynamic>> _methods = [];
  bool _loading = true;
  bool _busy = false; // any Stripe/back-end call in flight
  String? _loadError;

  @override
  void initState() {
    super.initState();
    _loadMethods();
  }

  Future<void> _loadMethods() async {
    List<Map<String, dynamic>>? loaded;
    bool failed = false;
    try {
      loaded = await ApiService.getPayoutMethods();
    } catch (e) {
      debugPrint('[PayoutMethods] _loadMethods error: $e');
      failed = true;
    }
    if (!mounted) return;
    // The error string is resolved AFTER the await on purpose: _loadMethods
    // is called from initState, and S.of() does an inherited-widget lookup,
    // which throws if it runs before initState has completed.
    setState(() {
      if (loaded != null) _methods = loaded;
      _loading = false;
      _loadError = failed ? S.of(context).couldNotLoadPaymentMethods : null;
    });
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

  void _snack(String msg, {bool error = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          msg,
          style: TextStyle(
            color: error ? Colors.white : Colors.black,
            fontWeight: FontWeight.w600,
          ),
        ),
        backgroundColor: error ? _danger : _gold,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    );
  }

  // ═══════════════════════════════════════════════════
  //  BUILD
  // ═══════════════════════════════════════════════════
  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    return Scaffold(
      backgroundColor: neuBase,
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ── Header ──
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
                        alignment: Alignment.center,
                        decoration: neuBox(radius: 14, pressed: true),
                        child: const Icon(
                          Icons.arrow_back_rounded,
                          color: _text,
                          size: 20,
                        ),
                      ),
                    ),
                  ),
                  Text(
                    s.payoutMethodsTitle,
                    style: const TextStyle(
                      color: _text,
                      fontSize: 20,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 24),

            // ── Instant cashout explainer — raised neu card ──
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.all(18),
                decoration: neuBox(radius: 22),
                child: Row(
                  children: [
                    Container(
                      width: 48,
                      height: 48,
                      alignment: Alignment.center,
                      decoration: neuBox(radius: 15, pressed: true),
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
                            s.instantCashout,
                            style: const TextStyle(
                              color: _text,
                              fontSize: 16,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            s.plaidLinkDescription,
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

            // ── Section header ──
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Row(
                children: [
                  Text(
                    s.linkedAccounts,
                    style: const TextStyle(
                      color: _text,
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

            // ── Security note — sunken strip ──
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 10,
                ),
                decoration: neuBox(radius: 14, pressed: true),
                child: Row(
                  children: [
                    Icon(
                      Icons.lock_rounded,
                      color: _green.withValues(alpha: 0.7),
                      size: 16,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        s.plaidSecurityNote,
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

            // ── List / empty / error ──
            Expanded(
              child: _loading
                  ? const Center(
                      child: CircularProgressIndicator(
                        color: _gold,
                        strokeWidth: 2,
                      ),
                    )
                  : _loadError != null
                  ? _buildError(_loadError!)
                  : _methods.isEmpty
                  ? _buildEmpty()
                  : RefreshIndicator(
                      color: _gold,
                      backgroundColor: neuSurface,
                      onRefresh: _loadMethods,
                      child: ListView.separated(
                        physics: const AlwaysScrollableScrollPhysics(
                          parent: BouncingScrollPhysics(),
                        ),
                        padding: const EdgeInsets.symmetric(horizontal: 20),
                        itemCount: _methods.length,
                        separatorBuilder: (_, __) => const SizedBox(height: 10),
                        itemBuilder: (_, i) => _buildMethodCard(_methods[i]),
                      ),
                    ),
            ),

            // ── Actions ──
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
              child: Column(
                children: [
                  _primaryButton(
                    icon: Icons.account_balance_rounded,
                    label: s.connectBankAccount,
                    busyLabel: s.connectingLabel,
                    onTap: _connectBankAccount,
                  ),
                  if (!_hasDebitCard) ...[
                    const SizedBox(height: 10),
                    _secondaryButton(
                      icon: Icons.credit_card_rounded,
                      label: s.addDebitCard,
                      onTap: _connectDebitCard,
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Gold filled primary action, raised.
  Widget _primaryButton({
    required IconData icon,
    required String label,
    required String busyLabel,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: _busy ? null : onTap,
      child: AnimatedOpacity(
        duration: const Duration(milliseconds: 150),
        opacity: _busy ? 0.6 : 1,
        child: Container(
          width: double.infinity,
          height: 56,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: _gold,
            borderRadius: BorderRadius.circular(18),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.55),
                offset: const Offset(5, 5),
                blurRadius: 12,
              ),
              BoxShadow(
                color: Colors.white.withValues(alpha: 0.05),
                offset: const Offset(-4, -4),
                blurRadius: 10,
              ),
            ],
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (_busy)
                const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(
                    color: Colors.black,
                    strokeWidth: 2,
                  ),
                )
              else
                Icon(icon, size: 20, color: Colors.black),
              const SizedBox(width: 10),
              Text(
                _busy ? busyLabel : label,
                style: const TextStyle(
                  color: Colors.black,
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Raised neu surface with gold label.
  Widget _secondaryButton({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: _busy ? null : onTap,
      child: AnimatedOpacity(
        duration: const Duration(milliseconds: 150),
        opacity: _busy ? 0.5 : 1,
        child: Container(
          width: double.infinity,
          height: 52,
          alignment: Alignment.center,
          decoration: neuBox(radius: 18),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 20, color: _gold),
              const SizedBox(width: 10),
              Text(
                label,
                style: const TextStyle(
                  color: _gold,
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildEmpty() {
    final s = S.of(context);
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 80,
            height: 80,
            alignment: Alignment.center,
            decoration: neuBox(radius: 26, pressed: true),
            child: Icon(
              Icons.account_balance_rounded,
              color: _gold.withValues(alpha: 0.45),
              size: 36,
            ),
          ),
          const SizedBox(height: 16),
          Text(
            s.noPayoutMethods,
            style: const TextStyle(
              color: _text,
              fontSize: 17,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            s.connectBankForCashouts,
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
            decoration: neuBox(radius: 20, pressed: true),
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
                  s.poweredByPlaid,
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

  Widget _buildError(String message) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 40),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 72,
              height: 72,
              alignment: Alignment.center,
              decoration: neuBox(radius: 24, pressed: true),
              child: Icon(
                Icons.error_outline_rounded,
                color: _danger.withValues(alpha: 0.8),
                size: 34,
              ),
            ),
            const SizedBox(height: 16),
            Text(
              message,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: Colors.white70,
                fontSize: 15,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 20),
            GestureDetector(
              onTap: () {
                setState(() => _loading = true);
                _loadMethods();
              },
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 20,
                  vertical: 12,
                ),
                decoration: neuBox(radius: 16),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.refresh_rounded, color: _gold, size: 18),
                    const SizedBox(width: 8),
                    Text(
                      S.of(context).retry,
                      style: const TextStyle(
                        color: _gold,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
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
    final s = S.of(context);
    final type = method['method_type'] ?? 'bank_account';
    final rawDisplay = (method['display_name'] ?? 'Bank account').toString();
    final display = _cleanDisplay(rawDisplay);
    final isDefault = method['is_default'] == true;
    final id = method['id'];
    final isCard = type == 'debit_card';

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: neuBox(
        radius: 20,
        borderColor: isDefault ? _gold.withValues(alpha: 0.45) : null,
      ),
      child: Column(
        children: [
          Row(
            children: [
              Container(
                width: 48,
                height: 48,
                alignment: Alignment.center,
                decoration: neuBox(radius: 15, pressed: true),
                child: isCard
                    ? _brandIcon(_brandFromDisplay(display), size: 30)
                    : const Icon(
                        Icons.account_balance_rounded,
                        color: _green,
                        size: 24,
                      ),
              ),
              const SizedBox(width: 14),
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
                              color: _text,
                              fontSize: 15,
                              fontWeight: FontWeight.w700,
                            ),
                            overflow: TextOverflow.ellipsis,
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
                              s.defaultBadge,
                              style: const TextStyle(
                                color: _gold,
                                fontSize: 10,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: 3),
                    Text(
                      isCard ? s.instantCashout : s.bankTransferType,
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.35),
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              GestureDetector(
                onTap: () => _confirmDelete(id, display),
                child: Container(
                  width: 38,
                  height: 38,
                  alignment: Alignment.center,
                  decoration: neuBox(radius: 13, pressed: true),
                  child: Icon(
                    Icons.delete_outline_rounded,
                    color: Colors.white.withValues(alpha: 0.35),
                    size: 18,
                  ),
                ),
              ),
            ],
          ),
          // Full-width action so the label can't be clipped on narrow phones
          // the way the old inline chip was.
          if (!isDefault) ...[
            const SizedBox(height: 12),
            GestureDetector(
              onTap: () => _setDefault(id),
              child: Container(
                width: double.infinity,
                height: 40,
                alignment: Alignment.center,
                decoration: neuBox(radius: 13, pressed: true),
                child: Text(
                  s.setDefault,
                  style: const TextStyle(
                    color: _gold,
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  // ═══════════════════════════════════════════════════
  //  ACTIONS
  // ═══════════════════════════════════════════════════
  Future<void> _setDefault(dynamic id) async {
    HapticService.lightImpact();
    try {
      await ApiService.setDefaultPayoutMethod(
        id is int ? id : int.parse(id.toString()),
      );
      await _loadMethods();
    } catch (e) {
      debugPrint('[Payout] _setDefault error: $e');
      if (!mounted) return;
      _snack(S.of(context).failedToSetDefault, error: true);
    }
  }

  /// Link a bank account through the Stripe Financial Connections sheet.
  ///
  /// The backend mints a Financial Connections session and returns its
  /// `client_secret` — it has no hosted URL, so this must go through the
  /// native SDK. Stripe hands back a `btok_...` which the backend attaches
  /// as the Connect external_account that weekly payouts are sent to.
  Future<void> _connectBankAccount() async {
    HapticService.mediumImpact();
    if (kIsWeb) {
      _snack(S.of(context).bankLinkMobileOnly, error: true);
      return;
    }
    setState(() => _busy = true);
    try {
      final session = await ApiService.createDriverFinancialConnectionsSession();
      if (!mounted) return;

      final clientSecret = (session['client_secret'] ?? '').toString();
      if (clientSecret.isEmpty) {
        _snack(S.of(context).failedToAddMethod, error: true);
        return;
      }

      final result = await stripe.Stripe.instance.collectBankAccountToken(
        clientSecret: clientSecret,
      );
      if (!mounted) return;

      final bankToken = result.token.id ?? '';
      if (bankToken.isEmpty) {
        // Sheet completed without producing a token (e.g. the driver backed
        // out on the final step). Nothing to attach.
        return;
      }

      await ApiService.addBankAccountPayout(
        bankToken: bankToken,
        setDefault: _methods.isEmpty,
      );
      if (!mounted) return;
      _snack(S.of(context).bankAccountLinked);
      await _loadMethods();
    } on stripe.StripeException catch (e) {
      if (e.error.code == stripe.FailureCode.Canceled) return; // user dismissed
      debugPrint('[Payout] Bank link Stripe error: ${e.error}');
      if (!mounted) return;
      _snack(
        e.error.localizedMessage ?? S.of(context).failedToAddMethod,
        error: true,
      );
    } catch (e) {
      debugPrint('[Payout] Bank link error: $e');
      if (!mounted) return;
      _snack(
        e is ApiException ? e.message : S.of(context).failedToAddMethod,
        error: true,
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Collect a debit card and attach it as an external_account for instant
  /// cashouts. The `CardField` sheet buffers the PAN inside the Stripe SDK;
  /// `createToken` turns that buffer into a `tok_...`. Only the token
  /// leaves the device.
  Future<void> _connectDebitCard() async {
    HapticService.mediumImpact();
    if (kIsWeb) {
      _snack(S.of(context).cardEntryMobileOnly, error: true);
      return;
    }

    final cardToken = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (_) => const _AddDebitCardSheet(),
    );
    if (cardToken == null || cardToken.isEmpty || !mounted) return;

    setState(() => _busy = true);
    try {
      await ApiService.addDebitCardPayout(
        cardToken: cardToken,
        setDefault: _methods.isEmpty,
      );
      if (!mounted) return;
      _snack(S.of(context).debitCardAdded);
      await _loadMethods();
    } catch (e) {
      debugPrint('[Payout] addDebitCard error: $e');
      if (!mounted) return;
      _snack(
        e is ApiException ? e.message : S.of(context).failedToAddMethod,
        error: true,
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _confirmDelete(dynamic id, String name) {
    final s = S.of(context);
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) => Container(
        padding: const EdgeInsets.all(28),
        decoration: const BoxDecoration(
          color: neuBase,
          borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
        ),
        child: SafeArea(
          top: false,
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
                width: 64,
                height: 64,
                alignment: Alignment.center,
                decoration: neuBox(radius: 22, pressed: true),
                child: Icon(
                  Icons.warning_amber_rounded,
                  color: _danger.withValues(alpha: 0.85),
                  size: 32,
                ),
              ),
              const SizedBox(height: 16),
              Text(
                s.removePayoutMethod,
                style: const TextStyle(
                  color: _text,
                  fontSize: 18,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                s.confirmRemoveMethod(name),
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
                    child: GestureDetector(
                      onTap: () => Navigator.pop(ctx),
                      child: Container(
                        height: 50,
                        alignment: Alignment.center,
                        decoration: neuBox(radius: 16),
                        child: Text(
                          s.cancel,
                          style: const TextStyle(
                            color: _text,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: GestureDetector(
                      onTap: () async {
                        Navigator.pop(ctx);
                        await _deleteMethod(id);
                      },
                      child: Container(
                        height: 50,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: _danger.withValues(alpha: 0.85),
                          borderRadius: BorderRadius.circular(16),
                        ),
                        child: Text(
                          s.removeLabel,
                          style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w700,
                          ),
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
      ),
    );
  }

  Future<void> _deleteMethod(dynamic id) async {
    try {
      await ApiService.deletePayoutMethod(
        id is int ? id : int.parse(id.toString()),
      );
      if (!mounted) return;
      _snack(S.of(context).payoutMethodRemoved);
      // Reload rather than removing locally: deleting the default makes the
      // backend promote another row, and that new default has to show up.
      await _loadMethods();
    } catch (e) {
      debugPrint('[Payout] _deleteMethod error: $e');
      if (!mounted) return;
      _snack(S.of(context).failedToRemoveMethod, error: true);
    }
  }
}

// ═══════════════════════════════════════════════════════════════
//  ADD DEBIT CARD SHEET
// ═══════════════════════════════════════════════════════════════

/// Collects a debit card and returns the Stripe token id (`tok_...`).
///
/// `createToken` reads the card details buffered by the mounted
/// [stripe.CardField] — without a live field on screen there is nothing to
/// tokenize, which is why this has to be its own sheet rather than a bare
/// SDK call. `currency: 'usd'` is required: it marks the token as a payout
/// destination, which is what `Account.create_external_account` accepts.
class _AddDebitCardSheet extends StatefulWidget {
  const _AddDebitCardSheet();

  @override
  State<_AddDebitCardSheet> createState() => _AddDebitCardSheetState();
}

class _AddDebitCardSheetState extends State<_AddDebitCardSheet> {
  static const _gold = Color(0xFFD4A843);

  final _nameCtrl = TextEditingController();
  bool _complete = false;
  bool _submitting = false;
  String? _error;

  @override
  void dispose() {
    _nameCtrl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_complete || _submitting) return;
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      final token = await stripe.Stripe.instance.createToken(
        stripe.CreateTokenParams.card(
          params: stripe.CardTokenParams(
            type: stripe.TokenType.Card,
            name: _nameCtrl.text.trim().isEmpty
                ? null
                : _nameCtrl.text.trim(),
            currency: 'usd',
          ),
        ),
      );
      if (!mounted) return;
      if (token.id.isEmpty) {
        setState(() {
          _submitting = false;
          _error = S.of(context).failedToAddMethod;
        });
        return;
      }
      Navigator.pop(context, token.id);
    } on stripe.StripeException catch (e) {
      if (!mounted) return;
      if (e.error.code == stripe.FailureCode.Canceled) {
        Navigator.pop(context);
        return;
      }
      setState(() {
        _submitting = false;
        _error = e.error.localizedMessage ?? S.of(context).failedToAddMethod;
      });
    } catch (e) {
      debugPrint('[AddDebitCard] createToken error: $e');
      if (!mounted) return;
      setState(() {
        _submitting = false;
        _error = S.of(context).failedToAddMethod;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    return Padding(
      // Lift above the keyboard so the card field stays visible.
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: Container(
        padding: const EdgeInsets.fromLTRB(24, 12, 24, 24),
        decoration: const BoxDecoration(
          color: neuBase,
          borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
        ),
        child: SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 36,
                  height: 4,
                  decoration: BoxDecoration(
                    color: Colors.white12,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 22),
              Text(
                s.addDebitCardTitle,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 20,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                s.addDebitForCashouts,
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.45),
                  fontSize: 13,
                  height: 1.4,
                ),
              ),
              const SizedBox(height: 20),

              // ── Stripe secure card field ──
              Container(
                decoration: neuBox(radius: 16, pressed: true),
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 4,
                ),
                child: stripe.CardField(
                  enablePostalCode: false,
                  style: const TextStyle(color: Colors.white, fontSize: 16),
                  decoration: InputDecoration(
                    border: InputBorder.none,
                    hintStyle: TextStyle(
                      color: Colors.white.withValues(alpha: 0.35),
                      fontSize: 16,
                    ),
                  ),
                  onCardChanged: (details) {
                    setState(() => _complete = details?.complete ?? false);
                  },
                ),
              ),
              const SizedBox(height: 14),

              // ── Cardholder name ──
              Container(
                decoration: neuBox(radius: 16, pressed: true),
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: TextField(
                  controller: _nameCtrl,
                  style: const TextStyle(color: Colors.white, fontSize: 15),
                  textCapitalization: TextCapitalization.words,
                  decoration: InputDecoration(
                    border: InputBorder.none,
                    hintText: s.cardholderNameLabel,
                    hintStyle: TextStyle(
                      color: Colors.white.withValues(alpha: 0.35),
                      fontSize: 15,
                    ),
                    icon: Icon(
                      Icons.person_outline_rounded,
                      color: Colors.white.withValues(alpha: 0.35),
                      size: 20,
                    ),
                  ),
                ),
              ),

              if (_error != null) ...[
                const SizedBox(height: 14),
                Row(
                  children: [
                    const Icon(
                      Icons.error_outline_rounded,
                      color: Color(0xFFFF5252),
                      size: 16,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        _error!,
                        style: const TextStyle(
                          color: Color(0xFFFF5252),
                          fontSize: 12.5,
                        ),
                      ),
                    ),
                  ],
                ),
              ],

              const SizedBox(height: 16),
              Row(
                children: [
                  Icon(
                    Icons.lock_rounded,
                    color: const Color(0xFF4CAF50).withValues(alpha: 0.7),
                    size: 14,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      s.infoEncryptedSecure,
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.35),
                        fontSize: 11,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 20),

              // ── Submit ──
              GestureDetector(
                onTap: (_complete && !_submitting) ? _submit : null,
                child: AnimatedOpacity(
                  duration: const Duration(milliseconds: 150),
                  opacity: (_complete && !_submitting) ? 1 : 0.45,
                  child: Container(
                    width: double.infinity,
                    height: 54,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: _gold,
                      borderRadius: BorderRadius.circular(18),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.55),
                          offset: const Offset(5, 5),
                          blurRadius: 12,
                        ),
                      ],
                    ),
                    child: _submitting
                        ? const SizedBox(
                            width: 22,
                            height: 22,
                            child: CircularProgressIndicator(
                              color: Colors.black,
                              strokeWidth: 2,
                            ),
                          )
                        : Text(
                            s.addCardButton,
                            style: const TextStyle(
                              color: Colors.black,
                              fontSize: 15,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Center(
                child: TextButton(
                  onPressed: _submitting
                      ? null
                      : () => Navigator.pop(context),
                  child: Text(
                    s.cancel,
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.5),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════
//  Card brand enum
// ═══════════════════════════════════════════════════════════════
enum _CardBrand { visa, mastercard, amex, discover, unknown }
