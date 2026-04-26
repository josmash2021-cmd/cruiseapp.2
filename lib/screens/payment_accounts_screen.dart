import 'package:flutter/material.dart';
import '../config/app_theme.dart';
import '../config/page_transitions.dart';
import '../l10n/app_localizations.dart';
import '../services/api_service.dart';
import '../services/error_service.dart';
import '../services/local_data_service.dart';
import 'credit_card_screen.dart';

/// Screen where users can link / manage their payment accounts
/// (Google Pay, PayPal) and manage saved cards.
class PaymentAccountsScreen extends StatefulWidget {
  const PaymentAccountsScreen({super.key});

  @override
  State<PaymentAccountsScreen> createState() => _PaymentAccountsScreenState();
}

class _PaymentAccountsScreenState extends State<PaymentAccountsScreen> {
  static const _gold = Color(0xFFE8C547);

  // Local state (SharedPreferences) — only persistent methods live here.
  // Apple Pay / Google Pay are device wallets, not saved methods, so they
  // are NOT tracked here. They surface automatically at checkout when the
  // device wallet is configured.
  String? _savedCardLast4;
  String? _savedCardBrand;

  // Server-synced methods (cards only — bank account is "coming soon")
  List<Map<String, dynamic>> _serverMethods = [];
  bool _loadingServer = true;

  @override
  void initState() {
    super.initState();
    _loadLinkedState();
    _loadServerMethods();
  }

  Future<void> _loadLinkedState() async {
    final linked = await LocalDataService.getLinkedPaymentMethods();
    final cardLast4 = await LocalDataService.getCreditCardLast4();
    final cardBrand = await LocalDataService.getCreditCardBrand();
    if (!mounted) return;
    setState(() {
      if (linked.contains('credit_card') && cardLast4 != null) {
        _savedCardLast4 = cardLast4;
        _savedCardBrand = cardBrand;
      }
    });
  }

  Future<void> _loadServerMethods() async {
    try {
      final methods = await ApiService.getRiderPaymentMethods();
      if (!mounted) return;
      setState(() {
        _serverMethods = methods
            .where((m) => _isAllowedMethodType(m['method_type'] as String? ?? ''))
            .toList();
        _loadingServer = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _loadingServer = false);
    }
  }

  /// Only persistent payment methods belong on this screen. Apple Pay and
  /// Google Pay are device wallets — they cannot be "saved", they appear
  /// at checkout when the device has them configured.
  bool _isAllowedMethodType(String methodType) {
    return methodType == 'stripe_card' ||
        methodType == 'paypal' ||
        methodType == 'bank_account';
  }

  Future<void> _deleteServerMethod(int id) async {
    try {
      await ApiService.deleteRiderPaymentMethod(id);
      if (!mounted) return;
      setState(() => _serverMethods.removeWhere((m) => m['id'] == id));
      _showSnack('Payment method removed');
    } catch (_) {
      if (!mounted) return;
      _showSnack('Could not remove method. Try again.');
    }
  }

  Future<void> _setDefaultServerMethod(int id) async {
    try {
      await ApiService.setDefaultRiderPaymentMethod(id);
      await _loadServerMethods();
    } catch (_) {
      _showSnack('Could not update default. Try again.');
    }
  }

  // ── Bank Account (ACH) ──
  // Stub for now: shows an informational dialog. Full Stripe Financial
  // Connections / Plaid integration ships in a follow-up commit; the
  // entry point is wired so the UI is feature-complete.
  Future<void> _linkBankAccount() async {
    if (!mounted) return;
    final c = AppColors.of(context);
    await showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: c.panel,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
        ),
        title: Row(
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: const Color(0xFF22C55E).withValues(alpha: 0.18),
                borderRadius: BorderRadius.circular(10),
              ),
              alignment: Alignment.center,
              child: const Icon(Icons.account_balance_rounded,
                  color: Color(0xFF22C55E), size: 22),
            ),
            const SizedBox(width: 12),
            const Expanded(
              child: Text(
                'Bank Account',
                style: TextStyle(
                  fontFamily: 'Poppins',
                  color: Colors.white,
                  fontWeight: FontWeight.w800,
                  fontSize: 18,
                ),
              ),
            ),
          ],
        ),
        content: Text(
          'Linking your bank account is coming soon. You\'ll be able to '
          'connect your account via secure ACH and pay directly from your '
          'balance.',
          style: TextStyle(
            fontFamily: 'Poppins',
            color: c.textSecondary,
            fontSize: 13.5,
            height: 1.4,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text(
              'OK',
              style: TextStyle(
                color: Color(0xFFE8C547),
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _linkCreditCard() async {
    final result = await Navigator.of(
      context,
    ).push<String>(slideFromRightRoute(const CreditCardScreen()));
    if (!mounted || result == null || result.isEmpty) return;
    // result = "brand:last4" e.g. "visa:4242"
    String brand = 'card';
    String last4 = result;
    if (result.contains(':')) {
      final parts = result.split(':');
      brand = parts[0];
      last4 = parts[1];
    }
    final cardMsg = S.of(context).cardAddedMsg('${_capitalizedBrand(brand)} •••• $last4');
    await LocalDataService.linkPaymentMethod('credit_card');
    await LocalDataService.saveCreditCardLast4(last4);
    await LocalDataService.saveCreditCardBrand(brand);
    final stripePmId = await LocalDataService.getStripePaymentMethodId();
    try {
      await ApiService.addRiderPaymentMethod(
        methodType: 'stripe_card',
        displayName: '${_capitalizedBrand(brand)} •••• $last4',
        stripePmId: stripePmId,
        setDefault: true,
      );
    } catch (_) {
      if (mounted) ErrorService.show(context, 'Failed to save card on server. Please retry.');
    }
    setState(() {
      _savedCardLast4 = last4;
      _savedCardBrand = brand;
    });
    _showSnack(cardMsg);
    await _loadServerMethods();
  }

  String _capitalizedBrand(String? brand) {
    switch (brand) {
      case 'visa':
        return 'Visa';
      case 'mastercard':
        return 'Mastercard';
      case 'amex':
        return 'Amex';
      case 'discover':
        return 'Discover';
      case 'diners':
        return 'Diners Club';
      case 'jcb':
        return 'JCB';
      default:
        return 'Card';
    }
  }

  void _showSnack(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        backgroundColor: const Color(0xFFE8C547),
        content: Text(msg, style: const TextStyle(fontWeight: FontWeight.w600)),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    );
  }

  // ── Build ──

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);

    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SizedBox(height: 8),
              // ── Back ──
              GestureDetector(
                onTap: () => Navigator.of(context).pop(),
                child: Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: c.surface,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(
                    Icons.arrow_back_ios_new_rounded,
                    color: c.textPrimary,
                    size: 18,
                  ),
                ),
              ),
              const SizedBox(height: 28),
              Text(
                S.of(context).paymentAccounts,
                style: TextStyle(
                  fontSize: 28,
                  fontWeight: FontWeight.w800,
                  color: c.textPrimary,
                  height: 1.2,
                  letterSpacing: -0.5,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                S.of(context).linkAccountsMsg,
                style: TextStyle(fontSize: 15, color: c.textSecondary),
              ),
              const SizedBox(height: 28),

              // ── Add new methods section ──
              Text(
                S.of(context).addPaymentMethod,
                style: TextStyle(fontSize: 13, color: c.textTertiary, fontWeight: FontWeight.w700, letterSpacing: 0.5),
              ),
              const SizedBox(height: 10),

              // Apple Pay / Google Pay are device wallets, not saved
              // methods. They show up automatically at checkout when the
              // device wallet is configured — there's nothing to "save"
              // here. Only persistent methods (cards, bank, PayPal) live
              // on this screen.

              // ── Credit / Debit Card ──
              _accountTile(
                c: c,
                logoWidget: _cardBrandLogo(_savedCardBrand),
                label: _savedCardLast4 != null
                    ? '${_capitalizedBrand(_savedCardBrand)} •••• $_savedCardLast4'
                    : S.of(context).creditOrDebitCard,
                linked: _savedCardLast4 != null,
                onTap: _linkCreditCard,
              ),
              Divider(color: c.divider, height: 1),

              // ── Bank Account (ACH — coming soon dialog for now) ──
              _accountTile(
                c: c,
                logoWidget: Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    color: const Color(0xFF22C55E).withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  alignment: Alignment.center,
                  child: const Icon(Icons.account_balance_rounded,
                      color: Color(0xFF22C55E), size: 20),
                ),
                label: 'Bank Account',
                linked: false,
                onTap: _linkBankAccount,
              ),

              const SizedBox(height: 24),

              // ── Device-wallet explainer ──
              // Replaces the old fake "Add Apple Pay / Add Google Pay"
              // tiles. Communicates that those wallets are detected at
              // checkout and don't need to be linked here.
              const _DeviceWalletNote(),

              // ── Saved methods from server ──
              if (_loadingServer) ...[
                const SizedBox(height: 20),
                const Center(child: CircularProgressIndicator(color: _gold, strokeWidth: 2)),
              ] else if (_serverMethods.isNotEmpty) ...[
                const SizedBox(height: 24),
                Text(
                  'Saved Methods',
                  style: TextStyle(fontSize: 13, color: c.textTertiary, fontWeight: FontWeight.w700, letterSpacing: 0.5),
                ),
                const SizedBox(height: 8),
                ..._serverMethods.map((m) {
                  final isDefault = m['is_default'] == true;
                  final type = m['method_type'] as String? ?? '';
                  IconData icon;
                  Color iconColor;
                  switch (type) {
                    case 'bank_account':
                      icon = Icons.account_balance_rounded;
                      iconColor = const Color(0xFF4CAF50);
                      break;
                    case 'stripe_card':
                      icon = Icons.credit_card_rounded;
                      iconColor = const Color(0xFF2196F3);
                      break;
                    case 'paypal':
                      icon = Icons.account_balance_wallet_rounded;
                      iconColor = const Color(0xFF003087);
                      break;
                    case 'google_pay':
                      icon = Icons.g_mobiledata_rounded;
                      iconColor = const Color(0xFF4285F4);
                      break;
                    case 'apple_pay':
                      icon = Icons.apple;
                      iconColor = Colors.white;
                      break;
                    default:
                      icon = Icons.payment_rounded;
                      iconColor = const Color(0xFF6B7280);
                  }
                  return Container(
                    margin: const EdgeInsets.only(bottom: 8),
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                    decoration: BoxDecoration(
                      color: isDefault ? _gold.withValues(alpha: 0.08) : c.surface,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: isDefault ? _gold.withValues(alpha: 0.4) : c.divider,
                        width: isDefault ? 1.5 : 1,
                      ),
                    ),
                    child: Row(
                      children: [
                        Container(
                          width: 38,
                          height: 38,
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
                              Text(
                                m['display_name'] as String? ?? type,
                                style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: c.textPrimary),
                              ),
                              if (isDefault)
                                Text('Default', style: TextStyle(fontSize: 11, color: _gold, fontWeight: FontWeight.w700)),
                            ],
                          ),
                        ),
                        if (!isDefault)
                          GestureDetector(
                            onTap: () => _setDefaultServerMethod(m['id'] as int),
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                              decoration: BoxDecoration(
                                border: Border.all(color: _gold.withValues(alpha: 0.4)),
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: Text('Set Default', style: TextStyle(fontSize: 11, color: _gold, fontWeight: FontWeight.w600)),
                            ),
                          ),
                        const SizedBox(width: 8),
                        GestureDetector(
                          onTap: () => _deleteServerMethod(m['id'] as int),
                          child: Icon(Icons.delete_outline_rounded, color: Colors.red.shade400, size: 20),
                        ),
                      ],
                    ),
                  );
                }),
              ],

              const SizedBox(height: 20),

              // ── Footer ──
              Padding(
                padding: const EdgeInsets.only(bottom: 28),
                child: Text(
                  S.of(context).paymentSecurityNote,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 13,
                    color: c.textTertiary,
                    height: 1.5,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ── Brand logos ──

  Widget _cardBrandLogo(String? brand) {
    final Map<String, ({String letter, Color color, bool italic})> brands = {
      'visa': (letter: 'V', color: const Color(0xFF1A1F71), italic: true),
      'mastercard': (
        letter: 'M',
        color: const Color(0xFFEB001B),
        italic: false,
      ),
      'amex': (letter: 'A', color: const Color(0xFF006FCF), italic: false),
      'discover': (letter: 'D', color: const Color(0xFFFF6000), italic: false),
      'diners': (letter: 'D', color: const Color(0xFF0079BE), italic: false),
      'jcb': (letter: 'J', color: const Color(0xFF0B7CBE), italic: false),
    };
    final info = brands[brand];
    if (info == null) {
      return Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          color: const Color(0xFF4285F4).withValues(alpha: 0.15),
          borderRadius: BorderRadius.circular(12),
        ),
        child: const Icon(
          Icons.credit_card_rounded,
          color: Color(0xFF4285F4),
          size: 22,
        ),
      );
    }
    return Container(
      width: 40,
      height: 40,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.grey.shade300, width: 0.5),
      ),
      child: Center(
        child: Text(
          info.letter,
          style: TextStyle(
            color: info.color,
            fontSize: 22,
            fontWeight: FontWeight.w900,
            fontStyle: info.italic ? FontStyle.italic : FontStyle.normal,
            fontFamily: 'Roboto',
          ),
        ),
      ),
    );
  }

  Widget _accountTile({
    required AppColors c,
    required Widget logoWidget,
    required String label,
    required bool linked,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 16),
        child: Row(
          children: [
            logoWidget,
            const SizedBox(width: 14),
            Expanded(
              child: Text(
                label,
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: c.textPrimary,
                ),
              ),
            ),
            if (linked)
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 4,
                ),
                decoration: BoxDecoration(
                  color: const Color(0xFFE8C547).withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  S.of(context).added,
                  style: const TextStyle(
                    color: Color(0xFFE8C547),
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              )
            else
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 6,
                ),
                decoration: BoxDecoration(
                  color: _gold,
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  S.of(context).addBtn,
                  style: const TextStyle(
                    color: Colors.black,
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Subtle informational tile that explains why Apple Pay / Google Pay
/// don't appear in the "Add Payment Method" list. Shown only on the
/// Payment Accounts screen — replaces the old fake "Add Apple Pay /
/// Add Google Pay" rows that did a $0.00 verification and stored a flag.
///
/// Reasoning:
///   Apple Pay and Google Pay are device wallets, not saved payment
///   methods. They cannot be persisted on our side — what gets passed to
///   Stripe is a single-use, per-transaction tokenized PAN. Asking the
///   user to "link" them is double-friction with zero value: the same
///   Face ID / Touch ID prompt happens at the moment of the actual ride.
class _DeviceWalletNote extends StatelessWidget {
  const _DeviceWalletNote();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.04),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.06),
              borderRadius: BorderRadius.circular(10),
            ),
            alignment: Alignment.center,
            child: const Icon(
              Icons.smartphone_rounded,
              color: Color(0xFFE8C547),
              size: 20,
            ),
          ),
          const SizedBox(width: 12),
          const Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Apple Pay & Google Pay',
                  style: TextStyle(
                    fontFamily: 'Poppins',
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    color: Colors.white,
                  ),
                ),
                SizedBox(height: 4),
                Text(
                  "Available automatically at checkout when your device "
                  "wallet is set up. Nothing to add here — pick it when "
                  "you request a ride.",
                  style: TextStyle(
                    fontFamily: 'Poppins',
                    fontSize: 12.5,
                    height: 1.4,
                    color: Color(0xFFB0B0B6),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
