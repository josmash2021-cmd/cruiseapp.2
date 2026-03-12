import 'dart:io';
import 'package:flutter/material.dart';
import 'package:pay/pay.dart';
import 'package:url_launcher/url_launcher.dart';
import '../config/app_theme.dart';
import '../config/page_transitions.dart';
import '../l10n/app_localizations.dart';
import '../services/api_service.dart';
import '../services/local_data_service.dart';
import '../services/payment_service.dart';
import 'credit_card_screen.dart';
import 'paypal_checkout_screen.dart';

/// Screen where users can link / manage their payment accounts
/// (Google Pay, PayPal) and manage saved cards.
class PaymentAccountsScreen extends StatefulWidget {
  const PaymentAccountsScreen({super.key});

  @override
  State<PaymentAccountsScreen> createState() => _PaymentAccountsScreenState();
}

class _PaymentAccountsScreenState extends State<PaymentAccountsScreen> {
  static const _gold = Color(0xFFE8C547);

  // Local state (SharedPreferences)
  bool _googlePayLinked = false;
  bool _applePayLinked = false;
  bool _paypalLinked = false;
  String? _savedCardLast4;
  String? _savedCardBrand;

  // Server-synced methods (cards + bank accounts)
  List<Map<String, dynamic>> _serverMethods = [];
  bool _loadingServer = true;

  // Platform availability
  bool _googlePayAvailable = false;
  bool _applePayAvailable = false;

  @override
  void initState() {
    super.initState();
    _loadLinkedState();
    _checkPlatformAvailability();
    _loadServerMethods();
  }

  Future<void> _checkPlatformAvailability() async {
    final gpay = await PaymentService.isGooglePayAvailable();
    final apay = await PaymentService.isApplePayAvailable();
    if (!mounted) return;
    setState(() {
      _googlePayAvailable = gpay;
      _applePayAvailable = apay;
    });
  }

  Future<void> _loadLinkedState() async {
    final linked = await LocalDataService.getLinkedPaymentMethods();
    final cardLast4 = await LocalDataService.getCreditCardLast4();
    final cardBrand = await LocalDataService.getCreditCardBrand();
    if (!mounted) return;
    setState(() {
      _googlePayLinked = linked.contains('google_pay');
      _applePayLinked = linked.contains('apple_pay');
      _paypalLinked = linked.contains('paypal');
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
        _serverMethods = methods;
        _loadingServer = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _loadingServer = false);
    }
  }

  Future<void> _deleteServerMethod(int id) async {
    try {
      await ApiService.deleteRiderPaymentMethod(id);
      if (!mounted) return;
      setState(() => _serverMethods.removeWhere((m) => m['id'] == id));
      _showSnack('Payment method removed');
    } catch (_) {
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

  // ── External app launchers ──

  // ── Google Pay / Apple Pay via `pay` package ──

  Future<void> _linkGooglePay() async {
    if (!_googlePayAvailable) {
      // Device doesn't have Google Pay set up — open Google Wallet to add a card
      _showSnack(S.of(context).setupGooglePayFirst);
      await _launchGooglePayWallet();
      return;
    }
    // Device already supports Google Pay → show native payment sheet with $0.01
    // verification charge just to confirm the account is ready.
    if (!mounted) return;
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) => _GooglePayLinkSheet(
        onSuccess: (result) async {
          await LocalDataService.linkPaymentMethod('google_pay');
          ApiService.addRiderPaymentMethod(
            methodType: 'google_pay',
            displayName: 'Google Pay',
            setDefault: false,
          ).catchError((_) {});
          if (!mounted) return;
          setState(() => _googlePayLinked = true);
          _showSnack(S.of(context).googlePayLinked);
          await _loadServerMethods();
        },
      ),
    );
  }

  /// Opens the Google Pay / Google Wallet app on the device.
  Future<void> _launchGooglePayWallet() async {
    const List<String> uris = [
      'intent://pay.google.com/#Intent;scheme=https;package=com.google.android.apps.walletnfcrel;end',
      'https://pay.google.com/gp/w/home',
      'https://play.google.com/store/apps/details?id=com.google.android.apps.walletnfcrel',
    ];
    for (final u in uris) {
      try {
        if (await canLaunchUrl(Uri.parse(u))) {
          await launchUrl(Uri.parse(u), mode: LaunchMode.externalApplication);
          return;
        }
      } catch (_) {}
    }
  }

  // ── Apple Pay ──

  Future<void> _linkApplePay() async {
    if (!_applePayAvailable) {
      _showSnack(S.of(context).setupApplePayInSettings);
      return;
    }
    if (!mounted) return;
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) => _ApplePayLinkSheet(
        onSuccess: (result) async {
          await LocalDataService.linkPaymentMethod('apple_pay');
          ApiService.addRiderPaymentMethod(
            methodType: 'apple_pay',
            displayName: 'Apple Pay',
            setDefault: false,
          ).catchError((_) {});
          if (!mounted) return;
          setState(() => _applePayLinked = true);
          _showSnack(S.of(context).applePayLinked);
          await _loadServerMethods();
        },
      ),
    );
  }

  // ── PayPal via PayPalCheckoutScreen (WebView + REST API) ──

  Future<void> _linkPayPal() async {
    if (!mounted) return;
    final approved = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => PayPalCheckoutScreen(
          amount: '1.00',
          currency: 'USD',
          description: S.of(context).cruiseAccountVerificationDesc,
        ),
      ),
    );
    if (!mounted) return;
    if (approved == true) {
      await LocalDataService.linkPaymentMethod('paypal');
      ApiService.addRiderPaymentMethod(
        methodType: 'paypal',
        displayName: 'PayPal',
        setDefault: false,
      ).catchError((_) {});
      setState(() => _paypalLinked = true);
      _showSnack(S.of(context).paypalLinked);
      await _loadServerMethods();
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
    await LocalDataService.linkPaymentMethod('credit_card');
    await LocalDataService.saveCreditCardLast4(last4);
    await LocalDataService.saveCreditCardBrand(brand);
    final stripePmId = await LocalDataService.getStripePaymentMethodId();
    ApiService.addRiderPaymentMethod(
      methodType: 'stripe_card',
      displayName: '${_capitalizedBrand(brand)} •••• $last4',
      stripePmId: stripePmId,
      setDefault: true,
    ).catchError((_) {});
    setState(() {
      _savedCardLast4 = last4;
      _savedCardBrand = brand;
    });
    _showSnack(
      S.of(context).cardAddedMsg('${_capitalizedBrand(brand)} •••• $last4'),
    );
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
      backgroundColor: c.bg,
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
                'Add Payment Method',
                style: TextStyle(fontSize: 13, color: c.textTertiary, fontWeight: FontWeight.w700, letterSpacing: 0.5),
              ),
              const SizedBox(height: 10),

              // ── Google Pay (Android only) ──
              if (Platform.isAndroid) ...[
                _accountTile(
                  c: c,
                  logoWidget: _googlePayLogo(),
                  label: _googlePayAvailable
                      ? 'Google Pay'
                      : S.of(context).googlePaySetUpInWallet,
                  linked: _googlePayLinked,
                  onTap: _linkGooglePay,
                ),
                Divider(color: c.divider, height: 1),
              ],

              // ── Apple Pay (iOS only) ──
              if (Platform.isIOS) ...[
                _accountTile(
                  c: c,
                  logoWidget: _applePayLogo(),
                  label: _applePayAvailable
                      ? 'Apple Pay'
                      : S.of(context).applePaySetUpInWallet,
                  linked: _applePayLinked,
                  onTap: _linkApplePay,
                ),
                Divider(color: c.divider, height: 1),
              ],

              // ── PayPal ──
              _accountTile(
                c: c,
                logoWidget: _paypalLogo(),
                label: 'PayPal',
                linked: _paypalLinked,
                onTap: _linkPayPal,
              ),
              Divider(color: c.divider, height: 1),

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

  Widget _googlePayLogo() {
    return Container(
      width: 40,
      height: 40,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.grey.shade300, width: 0.5),
      ),
      child: Padding(
        padding: const EdgeInsets.all(7),
        child: Image.asset('assets/images/google_g.png', fit: BoxFit.contain),
      ),
    );
  }

  Widget _paypalLogo() {
    return Container(
      width: 40,
      height: 40,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.grey.shade300, width: 0.5),
      ),
      child: Padding(
        padding: const EdgeInsets.all(6),
        child: Image.asset(
          'assets/images/paypal_logo.png',
          fit: BoxFit.contain,
        ),
      ),
    );
  }

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
          color: const Color(0xFF6B7280).withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(12),
        ),
        child: const Icon(
          Icons.credit_card_rounded,
          color: Color(0xFF6B7280),
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

  Widget _applePayLogo() {
    return Container(
      width: 40,
      height: 40,
      decoration: BoxDecoration(
        color: Colors.black,
        borderRadius: BorderRadius.circular(12),
      ),
      child: const Center(
        child: Icon(Icons.apple, color: Colors.white, size: 26),
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

// ─────────────────────────────────────────────────────────────────
//  Google Pay bottom sheet (confirms account is ready)
// ─────────────────────────────────────────────────────────────────
class _GooglePayLinkSheet extends StatefulWidget {
  final void Function(Map<String, dynamic>) onSuccess;
  const _GooglePayLinkSheet({required this.onSuccess});
  @override
  State<_GooglePayLinkSheet> createState() => _GooglePayLinkSheetState();
}

class _GooglePayLinkSheetState extends State<_GooglePayLinkSheet> {
  static const _gold = Color(0xFFE8C547);
  PaymentConfiguration? _config;

  @override
  void initState() {
    super.initState();
    PaymentService.googlePayConfig().then((c) {
      if (mounted) setState(() => _config = c);
    });
  }

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return Container(
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
      ),
      padding: const EdgeInsets.fromLTRB(24, 16, 24, 36),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 40,
            height: 4,
            decoration: BoxDecoration(
              color: c.divider,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(height: 20),
          Text(
            S.of(context).confirmGooglePay,
            style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.w800,
              color: c.textPrimary,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            S.of(context).confirmGooglePayVerifyMsg,
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 14, color: c.textSecondary),
          ),
          const SizedBox(height: 24),
          if (_config == null)
            const Center(child: CircularProgressIndicator(color: _gold))
          else
            GooglePayButton(
              paymentConfiguration: _config!,
              paymentItems: [
                PaymentItem(
                  label: S.of(context).accountVerification,
                  amount: '0.00',
                  status: PaymentItemStatus.final_price,
                ),
              ],
              type: GooglePayButtonType.pay,
              theme: GooglePayButtonTheme.dark,
              height: 54,
              onPaymentResult: (result) {
                Navigator.of(context).pop();
                widget.onSuccess(result);
              },
              loadingIndicator: const Center(
                child: CircularProgressIndicator(color: _gold),
              ),
              onError: (error) {
                Navigator.of(context).pop();
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text(S.of(context).googlePayError('$error')),
                  ),
                );
              },
            ),
          const SizedBox(height: 12),
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(
              S.of(context).cancel,
              style: TextStyle(color: c.textTertiary),
            ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────
//  Apple Pay bottom sheet (iOS only)
// ─────────────────────────────────────────────────────────────────
class _ApplePayLinkSheet extends StatefulWidget {
  final void Function(Map<String, dynamic>) onSuccess;
  const _ApplePayLinkSheet({required this.onSuccess});
  @override
  State<_ApplePayLinkSheet> createState() => _ApplePayLinkSheetState();
}

class _ApplePayLinkSheetState extends State<_ApplePayLinkSheet> {
  static const _gold = Color(0xFFE8C547);
  PaymentConfiguration? _config;

  @override
  void initState() {
    super.initState();
    PaymentService.applePayConfig().then((c) {
      if (mounted) setState(() => _config = c);
    });
  }

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return Container(
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
      ),
      padding: const EdgeInsets.fromLTRB(24, 16, 24, 36),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 40,
            height: 4,
            decoration: BoxDecoration(
              color: c.divider,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(height: 20),
          Text(
            S.of(context).confirmApplePay,
            style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.w800,
              color: c.textPrimary,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            S.of(context).confirmApplePayVerifyMsg,
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 14, color: c.textSecondary),
          ),
          const SizedBox(height: 24),
          if (_config == null)
            const Center(child: CircularProgressIndicator(color: _gold))
          else
            ApplePayButton(
              paymentConfiguration: _config!,
              paymentItems: [
                PaymentItem(
                  label: S.of(context).accountVerification,
                  amount: '0.00',
                  status: PaymentItemStatus.final_price,
                ),
              ],
              type: ApplePayButtonType.inStore,
              style: ApplePayButtonStyle.black,
              height: 54,
              onPaymentResult: (result) {
                Navigator.of(context).pop();
                widget.onSuccess(result);
              },
              loadingIndicator: const Center(
                child: CircularProgressIndicator(color: _gold),
              ),
              onError: (error) {
                Navigator.of(context).pop();
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text(S.of(context).applePayError('$error')),
                  ),
                );
              },
            ),
          const SizedBox(height: 12),
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(
              S.of(context).cancel,
              style: TextStyle(color: c.textTertiary),
            ),
          ),
        ],
      ),
    );
  }
}
