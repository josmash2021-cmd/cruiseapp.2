import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_stripe/flutter_stripe.dart';
import '../config/app_theme.dart';
import '../config/page_transitions.dart';
import '../l10n/app_localizations.dart';
import '../services/api_service.dart';
import '../services/error_service.dart';
import '../services/haptic_service.dart';
import '../services/local_data_service.dart';
import '../widgets/neu_style.dart';
import 'credit_card_screen.dart';

/// Screen where users can link / manage their payment accounts
/// (cards, bank account via ACH) and manage saved methods.
class PaymentAccountsScreen extends StatefulWidget {
  const PaymentAccountsScreen({super.key});

  @override
  State<PaymentAccountsScreen> createState() => _PaymentAccountsScreenState();
}

class _PaymentAccountsScreenState extends State<PaymentAccountsScreen>
    with WidgetsBindingObserver {
  static const _gold = Color(0xFFE8C547);

  // Local state (SharedPreferences) — only persistent methods live here.
  // Apple Pay / Google Pay are device wallets, not saved methods, so they
  // are NOT tracked here. They surface automatically at checkout when the
  // device wallet is configured.
  String? _savedCardLast4;
  String? _savedCardBrand;

  // Linked bank account (ACH) — when present the bank tile shows the
  // bank name / last 4 instead of the linking prompt.
  String? _bankLast4;
  String? _bankName;

  // Server-synced methods (cards + bank accounts)
  List<Map<String, dynamic>> _serverMethods = [];
  bool _loadingServer = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadLinkedState();
    _loadServerMethods();
    _loadBankInfo();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Refresh bank info when returning from the linking browser flow.
    if (state == AppLifecycleState.resumed) {
      _loadBankInfo();
      _loadServerMethods();
    }
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

  /// True when this device holds a saved card that the server doesn't know
  /// about, so the Added list can still show it instead of silently
  /// dropping it.
  bool get _localCardMissingFromServer {
    final last4 = _savedCardLast4;
    if (last4 == null || last4.isEmpty) return false;
    return !_serverMethods.any(
      (m) => (m['display_name'] as String? ?? '').contains(last4),
    );
  }

  /// Only persistent payment methods belong on this screen. Apple Pay and
  /// Google Pay are device wallets — they cannot be "saved", they appear
  /// at checkout when the device has them configured.
  bool _isAllowedMethodType(String methodType) {
    return methodType == 'stripe_card' ||
        methodType == 'paypal' ||
        methodType == 'bank_account';
  }

  /// Loads the linked bank account from the backend and caches it
  /// locally so the tile (and the ACH charge path) can use it offline.
  Future<void> _loadBankInfo() async {
    try {
      final accounts = await ApiService.getBankAccounts();
      if (!mounted) return;
      if (accounts.isEmpty) return;
      final first = accounts.first;
      final pmId = first['stripe_pm_id'] as String?;
      final last4 = first['last4'] as String?;
      final bankName = first['bank_name'] as String?;
      if (pmId != null) {
        await LocalDataService.saveStripeBankPmId(pmId);
        await LocalDataService.linkPaymentMethod('bank_account');
      }
      if (last4 != null) await LocalDataService.saveBankLast4(last4);
      if (!mounted) return;
      setState(() {
        _bankLast4 = last4;
        _bankName = bankName;
      });
    } catch (_) {
      // Non-fatal — the tile keeps its "Bank Account" linking prompt.
    }
  }

  bool _linkingBank = false;

  /// Opens the native Stripe Financial Connections sheet to link a bank
  /// account (ACH), then attaches it server-side so it can be charged.
  Future<void> _openBankConnection() async {
    if (_linkingBank) return; // double-tap guard
    HapticService.selectionClick();
    final s = S.of(context);

    if (kIsWeb) {
      // flutter_stripe's FC sheet is native-only; Stripe hosts no web URL
      // for this flow (the session object only carries a client_secret).
      _showBankError(s.bankLinkMobileOnly);
      return;
    }

    _linkingBank = true;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => const Center(
        child: CircularProgressIndicator(color: _gold),
      ),
    );

    try {
      final result = await ApiService.createFinancialConnectionsSession();
      final clientSecret = result?['client_secret'] as String?;
      if (!mounted) return;
      // Dismiss the loading spinner before presenting the native sheet.
      if (Navigator.of(context, rootNavigator: true).canPop()) {
        Navigator.of(context, rootNavigator: true).pop();
      }
      if (clientSecret == null) {
        _showBankError(s.genericPaymentError);
        return;
      }

      final collected =
          await Stripe.instance.collectFinancialConnectionsAccounts(
        clientSecret: clientSecret,
        params: const CollectFinancialConnectionsAccountsParams(),
      );
      if (!mounted) return;

      final accounts = collected.session.accounts;
      if (accounts.isEmpty) return; // sheet closed without selecting
      final attached = await ApiService.attachBankAccount(accounts.first.id);
      if (!mounted) return;

      final last4 = attached?['last4'] as String? ?? accounts.first.last4;
      final bankName =
          attached?['bank_name'] as String? ?? accounts.first.institutionName;
      final pmId = attached?['stripe_pm_id'] as String?;
      if (pmId != null) {
        await LocalDataService.saveStripeBankPmId(pmId);
        await LocalDataService.linkPaymentMethod('bank_account');
      }
      if (last4 != null) await LocalDataService.saveBankLast4(last4);
      if (!mounted) return;
      setState(() {
        _bankLast4 = last4;
        _bankName = bankName;
      });
      _showSnack(s.bankAccountLinked);
      await _loadServerMethods();
    } on StripeException catch (e) {
      if (!mounted) return;
      if (Navigator.of(context, rootNavigator: true).canPop()) {
        Navigator.of(context, rootNavigator: true).pop(); // dismiss loading
      }
      // User cancelled the native sheet — stay silent, that's fine.
      final code = e.error.code.toString().toLowerCase();
      if (!code.contains('cancel')) {
        _showBankError(
            e.error.localizedMessage ?? s.genericPaymentError);
      }
    } catch (e) {
      if (!mounted) return;
      if (Navigator.of(context, rootNavigator: true).canPop()) {
        Navigator.of(context, rootNavigator: true).pop(); // dismiss loading
      }
      _showBankError('${s.genericPaymentError} (${e.toString()})');
    } finally {
      _linkingBank = false;
    }
  }

  void _showBankError(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg),
        backgroundColor: Colors.red.shade800,
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  /// Ids currently collapsing out of the list.
  ///
  /// The row used to vanish the instant the request returned — a card is on
  /// screen, then the ones below it jump up into the gap. Marking it here
  /// first lets it fold away, and the list closes behind it, before it is
  /// actually removed.
  final Set<int> _removingIds = <int>{};

  Future<void> _deleteServerMethod(int id) async {
    final target = _serverMethods.firstWhere(
      (m) => m['id'] == id,
      orElse: () => const {},
    );
    try {
      await ApiService.deleteRiderPaymentMethod(id);
      if (!mounted) return;
      // Fold it away first, drop it from the list once the fold has played.
      setState(() => _removingIds.add(id));
      await Future<void>.delayed(const Duration(milliseconds: 260));
      if (!mounted) return;
      setState(() {
        _serverMethods.removeWhere((m) => m['id'] == id);
        _removingIds.remove(id);
      });
      // If the deleted method was the bank account, wipe its local cache
      // so no stale ACH PaymentMethod id survives.
      if (target['method_type'] == 'bank_account') {
        await LocalDataService.clearBankAccount();
        if (!mounted) return;
        setState(() {
          _bankLast4 = null;
          _bankName = null;
        });
      }
      _showSnack('Payment method removed');
    } catch (_) {
      if (!mounted) return;
      // Put it back if it was mid-fold — a row that half-disappeared and
      // then failed reads as the delete having half-worked.
      setState(() => _removingIds.remove(id));
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
      backgroundColor: neuBase,
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SizedBox(height: 12),
              // ── Back ──
              GestureDetector(
                onTap: () => Navigator.of(context).pop(),
                child: Container(
                  width: 42,
                  height: 42,
                  decoration: neuBox(radius: 21),
                  alignment: Alignment.center,
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
              const SizedBox(height: 24),

              // ── Device-wallet explainer ──
              // Sits at the top: Apple Pay / Google Pay are detected at
              // checkout and are not something you add here, so saying so
              // first stops riders hunting for them in the lists below.
              const _DeviceWalletNote(),

              const SizedBox(height: 28),

              // ── Add new methods section ──
              Text(
                S.of(context).addPaymentMethod,
                style: TextStyle(fontSize: 13, color: c.textTertiary, fontWeight: FontWeight.w700, letterSpacing: 0.5),
              ),
              const SizedBox(height: 12),

              // ── Add a card ──
              // Always an "add" action, never a linked/added state: riders
              // keep more than one card, and showing the saved card here as
              // "Added" left no way to attach a second one. Cards you have
              // already added live in the Added Payment Methods list below,
              // where they can be removed or promoted to default.
              _accountTile(
                c: c,
                logoWidget: _cardBrandLogo(null),
                label: S.of(context).addDebitCreditCardAction,
                linked: false,
                onTap: _linkCreditCard,
              ),
              const SizedBox(height: 12),

              // ── Bank Account (ACH via Stripe Financial Connections) ──
              _accountTile(
                c: c,
                logoWidget: Container(
                  width: 40,
                  height: 40,
                  decoration: neuBox(radius: 12, pressed: true),
                  alignment: Alignment.center,
                  child: const Icon(Icons.account_balance_rounded,
                      color: Color(0xFF22C55E), size: 20),
                ),
                label: _bankLast4 != null
                    ? (_bankName != null
                        ? '$_bankName •••• $_bankLast4'
                        : 'Bank •••• $_bankLast4')
                    : 'Bank Account',
                linked: _bankLast4 != null,
                onTap: _bankLast4 != null ? () {} : _openBankConnection,
              ),

              // ── Added payment methods ──
              // Every card and bank the rider has attached, each removable
              // and promotable to default.
              if (_loadingServer) ...[
                const SizedBox(height: 24),
                const Center(child: CircularProgressIndicator(color: _gold, strokeWidth: 2)),
              ] else if (_serverMethods.isNotEmpty) ...[
                const SizedBox(height: 28),
                Text(
                  S.of(context).addedPaymentMethods,
                  style: TextStyle(fontSize: 13, color: c.textTertiary, fontWeight: FontWeight.w700, letterSpacing: 0.5),
                ),
                const SizedBox(height: 12),
                ..._serverMethods.map((m) {
                  final removing = _removingIds.contains(m['id']);
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
                    default:
                      icon = Icons.payment_rounded;
                      iconColor = const Color(0xFF6B7280);
                  }
                  // Folds shut instead of blinking out: height to zero and
                  // fading as it goes, so the rows underneath slide up into
                  // the space rather than jumping into it.
                  return AnimatedSize(
                    duration: const Duration(milliseconds: 260),
                    curve: Curves.easeInOutCubic,
                    alignment: Alignment.topCenter,
                    child: AnimatedOpacity(
                      duration: const Duration(milliseconds: 200),
                      opacity: removing ? 0.0 : 1.0,
                      child: removing
                          ? const SizedBox(width: double.infinity, height: 0)
                          : Container(
                    margin: const EdgeInsets.only(bottom: 12),
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                    decoration: neuBox(radius: 16).copyWith(
                      border: isDefault
                          ? Border.all(color: _gold.withValues(alpha: 0.45), width: 1.4)
                          : Border.all(color: Colors.white.withValues(alpha: 0.04), width: 1),
                    ),
                    child: Row(
                      children: [
                        Container(
                          width: 40,
                          height: 40,
                          decoration: neuBox(radius: 12, pressed: true),
                          alignment: Alignment.center,
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
                                Text(S.of(context).defaultBadge, style: TextStyle(fontSize: 11, color: _gold, fontWeight: FontWeight.w700)),
                            ],
                          ),
                        ),
                        if (!isDefault)
                          GestureDetector(
                            onTap: () => _setDefaultServerMethod(m['id'] as int),
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                              decoration: neuBox(radius: 10, pressed: true),
                              child: Text(S.of(context).setDefault, style: TextStyle(fontSize: 11, color: _gold, fontWeight: FontWeight.w700)),
                            ),
                          ),
                        const SizedBox(width: 8),
                        GestureDetector(
                          onTap: () => _deleteServerMethod(m['id'] as int),
                          child: Container(
                            width: 34,
                            height: 34,
                            decoration: neuBox(radius: 17, pressed: true),
                            alignment: Alignment.center,
                            child: Icon(Icons.delete_outline_rounded, color: Colors.red.shade400, size: 18),
                          ),
                        ),
                      ],
                    ),
                          ),
                    ),
                  );
                }),
              ],

              // A card saved on this device that never reached the server
              // (the sync in credit_card_screen is deliberately non-fatal
              // and retries later). It used to be visible in the add tile;
              // now that the tile is always an add action, list it here so
              // the rider can still see what they attached.
              if (!_loadingServer && _localCardMissingFromServer) ...[
                if (_serverMethods.isEmpty) ...[
                  const SizedBox(height: 28),
                  Text(
                    S.of(context).addedPaymentMethods,
                    style: TextStyle(fontSize: 13, color: c.textTertiary, fontWeight: FontWeight.w700, letterSpacing: 0.5),
                  ),
                  const SizedBox(height: 12),
                ],
                Container(
                  margin: const EdgeInsets.only(bottom: 12),
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                  decoration: neuBox(radius: 16),
                  child: Row(
                    children: [
                      _cardBrandLogo(_savedCardBrand),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          '${_capitalizedBrand(_savedCardBrand)} •••• $_savedCardLast4',
                          style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
                            color: c.textPrimary,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
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
        decoration: neuBox(radius: 12, pressed: true),
        alignment: Alignment.center,
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
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: neuBox(radius: 16),
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
                  vertical: 5,
                ),
                decoration: neuBox(radius: 12, pressed: true),
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
                  horizontal: 14,
                  vertical: 7,
                ),
                decoration: BoxDecoration(
                  color: _gold,
                  borderRadius: BorderRadius.circular(20),
                  boxShadow: [
                    BoxShadow(
                      color: _gold.withValues(alpha: 0.28),
                      blurRadius: 12,
                      offset: const Offset(0, 4),
                    ),
                  ],
                ),
                child: Text(
                  S.of(context).addBtn,
                  style: const TextStyle(
                    color: Colors.black,
                    fontSize: 12,
                    fontWeight: FontWeight.w800,
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
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: neuBox(radius: 16, pressed: true),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          const Icon(
            Icons.smartphone_rounded,
            color: Color(0xFFE8C547),
            size: 20,
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
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: Colors.white,
                  ),
                ),
                SizedBox(height: 2),
                Text(
                  'Nothing to add here — pick it at checkout when you '
                  'request a ride.',
                  style: TextStyle(
                    fontFamily: 'Poppins',
                    fontSize: 12,
                    height: 1.35,
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
