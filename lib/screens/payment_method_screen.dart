import 'dart:io';
import 'package:flutter/material.dart';
import 'package:pay/pay.dart';
import '../config/app_theme.dart';
import '../config/page_transitions.dart';
import '../l10n/app_localizations.dart';
import '../services/local_data_service.dart';
import '../services/payment_service.dart';
import 'credit_card_screen.dart';
import 'paypal_checkout_screen.dart';
import 'profile_photo_screen.dart';

class PaymentMethodScreen extends StatefulWidget {
  final String firstName;
  final String lastName;
  final String email;
  final String phone;

  const PaymentMethodScreen({
    super.key,
    required this.firstName,
    required this.lastName,
    required this.email,
    this.phone = '',
  });

  @override
  State<PaymentMethodScreen> createState() => _PaymentMethodScreenState();
}

class _PaymentMethodScreenState extends State<PaymentMethodScreen> {
  static const _gold = Color(0xFFE8C547);

  String? _selectedMethod;
  bool _gpayAvailable = false;
  bool _apayAvailable = false;

  List<_PaymentOption> get _options => [
    const _PaymentOption(
      id: 'paypal',
      label: 'PayPal',
      icon: Icons.account_balance_wallet_rounded,
      iconColor: Colors.white70,
    ),
    _PaymentOption(
      id: 'cruise_cash',
      label: S.of(context).cruiseCash,
      icon: Icons.monetization_on_rounded,
      iconColor: const Color(0xFFE8C547),
    ),
    if (Platform.isAndroid)
      const _PaymentOption(
        id: 'google_pay',
        label: 'Google Pay',
        icon: Icons.g_mobiledata_rounded,
        iconColor: Colors.white,
      ),
    if (Platform.isIOS)
      const _PaymentOption(
        id: 'apple_pay',
        label: 'Apple Pay',
        icon: Icons.apple,
        iconColor: Colors.white,
      ),
    _PaymentOption(
      id: 'credit_card',
      label: S.of(context).creditOrDebitCard,
      icon: Icons.credit_card_rounded,
      iconColor: const Color(0xFF6B7280),
    ),
  ];

  @override
  void initState() {
    super.initState();
    _checkWalletAvailability();
  }

  Future<void> _checkWalletAvailability() async {
    final gp = await PaymentService.isGooglePayAvailable();
    final ap = await PaymentService.isApplePayAvailable();
    if (!mounted) return;
    setState(() {
      _gpayAvailable = gp;
      _apayAvailable = ap;
    });
  }

  void _selectMethod(String id) async {
    setState(() => _selectedMethod = id);

    if (id == 'paypal') {
      await _openPayPal();
      return;
    }

    if (id == 'credit_card') {
      await Future.delayed(const Duration(milliseconds: 200));
      if (!mounted) return;
      final result = await Navigator.of(context).push<String>(
        slideFromRightRoute(
          CreditCardScreen(
            firstName: widget.firstName,
            lastName: widget.lastName,
            email: widget.email,
          ),
        ),
      );
      if (!mounted) return;
      if (result != null) {
        // Parse brand:last4 format
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
        if (!mounted) return;
        _goToNextScreen(result);
      }
      return;
    }

    if (id == 'google_pay') {
      if (_gpayAvailable) {
        if (!mounted) return;
        showModalBottomSheet(
          context: context,
          backgroundColor: Colors.transparent,
          builder: (ctx) => _OnboardingGPaySheet(
            onSuccess: (result) async {
              await LocalDataService.linkPaymentMethod('google_pay');
              if (!mounted) return;
              _showSetupSnack(S.of(context).googlePayLinked);
              await Future.delayed(const Duration(milliseconds: 400));
              if (!mounted) return;
              _goToNextScreen(id);
            },
          ),
        );
      } else {
        _showSetupSnack(S.of(context).googlePayNotSetUp);
        await Future.delayed(const Duration(milliseconds: 600));
        if (!mounted) return;
        _goToNextScreen(id);
      }
      return;
    }

    if (id == 'apple_pay') {
      if (_apayAvailable) {
        if (!mounted) return;
        showModalBottomSheet(
          context: context,
          backgroundColor: Colors.transparent,
          builder: (ctx) => _OnboardingApplePaySheet(
            onSuccess: (result) async {
              await LocalDataService.linkPaymentMethod('apple_pay');
              if (!mounted) return;
              _showSetupSnack(S.of(context).applePayLinked);
              await Future.delayed(const Duration(milliseconds: 400));
              if (!mounted) return;
              _goToNextScreen(id);
            },
          ),
        );
      } else {
        _showSetupSnack(S.of(context).applePayNotSetUp);
        await Future.delayed(const Duration(milliseconds: 600));
        if (!mounted) return;
        _goToNextScreen(id);
      }
      return;
    }

    if (id == 'cruise_cash') {
      _showSetupSnack(S.of(context).cruiseCashActivated);
      await Future.delayed(const Duration(milliseconds: 600));
      if (!mounted) return;
      _goToNextScreen(id);
      return;
    }
  }

  void _goToNextScreen(String method) {
    Navigator.of(context).push(
      slideFromRightRoute(
        ProfilePhotoScreen(
          firstName: widget.firstName,
          lastName: widget.lastName,
          email: widget.email,
          phone: widget.phone,
          paymentMethod: method,
        ),
      ),
    );
  }

  void _skipPayment() {
    Navigator.of(context).push(
      slideFromRightRoute(
        ProfilePhotoScreen(
          firstName: widget.firstName,
          lastName: widget.lastName,
          email: widget.email,
          phone: widget.phone,
          paymentMethod: 'none',
        ),
      ),
    );
  }

  void _showSetupSnack(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        backgroundColor: const Color(0xFFE8C547),
        content: Text(
          message,
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    );
  }

  Future<void> _openPayPal() async {
    if (!mounted) return;
    final approved = await Navigator.of(context).push<bool>(
      slideFromRightRoute(PayPalCheckoutScreen(
        amount: '1.00',
        currency: 'USD',
        description: S.of(context).cruiseAccountVerificationDesc,
      )),
    );
    if (!mounted) return;
    if (approved == true) {
      await LocalDataService.linkPaymentMethod('paypal');
      _showSetupSnack(S.of(context).paypalLinked);
      await Future.delayed(const Duration(milliseconds: 400));
      if (!mounted) return;
      _goToNextScreen('paypal');
    } else {
      setState(() => _selectedMethod = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);

    return Scaffold(
      backgroundColor: c.bg,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SizedBox(height: 8),

              // ── Back button ──
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

              // ── Title ──
              Text(
                S.of(context).howWouldYouLikeToPay,
                style: TextStyle(
                  fontSize: 28,
                  fontWeight: FontWeight.w800,
                  color: c.textPrimary,
                  height: 1.2,
                  letterSpacing: -0.5,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                S.of(context).chargedAfterRide,
                style: TextStyle(fontSize: 15, color: c.textSecondary),
              ),
              const SizedBox(height: 28),

              // ── Payment options ──
              ...List.generate(_options.length, (i) {
                final opt = _options[i];
                final selected = _selectedMethod == opt.id;
                return Column(
                  children: [
                    GestureDetector(
                      onTap: () => _selectMethod(opt.id),
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 200),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 18,
                        ),
                        decoration: BoxDecoration(
                          color: selected
                              ? _gold.withValues(alpha: 0.08)
                              : Colors.transparent,
                          borderRadius: BorderRadius.circular(14),
                          border: selected
                              ? Border.all(
                                  color: _gold.withValues(alpha: 0.4),
                                  width: 1.5,
                                )
                              : null,
                        ),
                        child: Row(
                          children: [
                            Container(
                              width: 36,
                              height: 36,
                              decoration: BoxDecoration(
                                color: opt.iconColor.withValues(alpha: 0.12),
                                borderRadius: BorderRadius.circular(10),
                              ),
                              child: Icon(
                                opt.icon,
                                color: opt.iconColor,
                                size: 20,
                              ),
                            ),
                            const SizedBox(width: 14),
                            Expanded(
                              child: Text(
                                opt.label,
                                style: TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.w600,
                                  color: c.textPrimary,
                                ),
                              ),
                            ),
                            Icon(
                              Icons.chevron_right_rounded,
                              color: c.chevron,
                              size: 22,
                            ),
                          ],
                        ),
                      ),
                    ),
                    if (i < _options.length - 1)
                      Divider(color: c.divider, height: 1),
                  ],
                );
              }),

              const Spacer(),

              // ── Skip payment button ──
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: SizedBox(
                  width: double.infinity,
                  height: 50,
                  child: OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      foregroundColor: _gold,
                      side: const BorderSide(color: _gold, width: 1.5),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(25),
                      ),
                    ),
                    onPressed: _skipPayment,
                    icon: const Icon(Icons.skip_next_rounded, size: 22),
                    label: Text(
                      S.of(context).setUpLater,
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                      ),
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

class _PaymentOption {
  final String id;
  final String label;
  final IconData icon;
  final Color iconColor;

  const _PaymentOption({
    required this.id,
    required this.label,
    required this.icon,
    required this.iconColor,
  });
}

// ─────────────────────────────────────────────────────────────────────────────
//  Google Pay onboarding bottom sheet
// ─────────────────────────────────────────────────────────────────────────────
class _OnboardingGPaySheet extends StatefulWidget {
  final void Function(Map<String, dynamic>) onSuccess;
  const _OnboardingGPaySheet({required this.onSuccess});
  @override
  State<_OnboardingGPaySheet> createState() => _OnboardingGPaySheetState();
}

class _OnboardingGPaySheetState extends State<_OnboardingGPaySheet> {
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
            S.of(context).googlePayPrompt,
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

// ─────────────────────────────────────────────────────────────────────────────
//  Apple Pay onboarding bottom sheet (iOS only)
// ─────────────────────────────────────────────────────────────────────────────
class _OnboardingApplePaySheet extends StatefulWidget {
  final void Function(Map<String, dynamic>) onSuccess;
  const _OnboardingApplePaySheet({required this.onSuccess});
  @override
  State<_OnboardingApplePaySheet> createState() =>
      _OnboardingApplePaySheetState();
}

class _OnboardingApplePaySheetState extends State<_OnboardingApplePaySheet> {
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
            S.of(context).applePayPrompt,
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
