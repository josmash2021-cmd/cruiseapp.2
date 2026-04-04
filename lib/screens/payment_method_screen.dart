import 'dart:io';
import 'package:flutter/material.dart';
import 'package:pay/pay.dart';
import '../config/app_theme.dart';
import '../config/page_transitions.dart';
import '../l10n/app_localizations.dart';
import '../services/local_data_service.dart';
import '../services/payment_service.dart';
import '../services/analytics_service.dart';
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

  bool _gpayAvailable = false;
  bool _apayAvailable = false;

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

  void _addMethod(String id) async {
    if (id == 'paypal') {
      await _openPayPal();
      return;
    }

    if (id == 'credit_card') {
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
        AnalyticsService.instance.logPaymentAdded('credit_card');
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
              if (!mounted) return;
              _goToNextScreen(id);
            },
          ),
        );
      } else {
        _showSetupSnack(S.of(context).googlePayNotSetUp);
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
              if (!mounted) return;
              _goToNextScreen(id);
            },
          ),
        );
      } else {
        _showSetupSnack(S.of(context).applePayNotSetUp);
        if (!mounted) return;
        _goToNextScreen(id);
      }
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
    final paypalLinkedMsg = S.of(context).paypalLinked;
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
      _showSetupSnack(paypalLinkedMsg);
      if (!mounted) return;
      _goToNextScreen('paypal');
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
                S.of(context).addPaymentMethod,
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
              const SizedBox(height: 36),

              // ── Payment options with Add buttons ──

              // Apple Pay (iOS) / Google Pay (Android)
              if (Platform.isIOS)
                _paymentRow(
                  c,
                  icon: const _ApplePayIcon(),
                  label: 'Apple Pay',
                  onAdd: () => _addMethod('apple_pay'),
                ),
              if (Platform.isAndroid)
                _paymentRow(
                  c,
                  icon: const _GooglePayIcon(),
                  label: 'Google Pay',
                  onAdd: () => _addMethod('google_pay'),
                ),

              if (Platform.isIOS || Platform.isAndroid)
                const SizedBox(height: 16),

              // PayPal (Coming Soon)
              ClipRRect(
                borderRadius: BorderRadius.circular(14),
                child: Stack(
                  children: [
                    Opacity(
                      opacity: 0.45,
                      child: _paymentRow(
                        c,
                        icon: const _PayPalIcon(),
                        label: 'PayPal',
                        onAdd: () {},
                      ),
                    ),
                    Positioned(
                      top: 6,
                      right: -18,
                      child: Transform.rotate(
                        angle: 0.45,
                        child: Container(
                          width: 100,
                          padding: const EdgeInsets.symmetric(vertical: 3),
                          color: const Color(0xFFD4A843),
                          child: const Text(
                            'Coming Soon',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color: Colors.black,
                              fontSize: 9,
                              fontWeight: FontWeight.w800,
                              letterSpacing: 0.3,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),

              // Credit or debit card
              _paymentRow(
                c,
                icon: _CardIcon(color: c),
                label: S.of(context).creditOrDebitCard,
                onAdd: () => _addMethod('credit_card'),
              ),

              const SizedBox(height: 32),

              // ── Security notice ──
              Text(
                S.of(context).paymentInfoSecure,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 12,
                  color: c.textTertiary,
                  height: 1.5,
                ),
              ),

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

  /// Payment row with icon, label, and gold "Add" button — matches photo 3
  Widget _paymentRow(
    AppColors c, {
    required Widget icon,
    required String label,
    required VoidCallback onAdd,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          SizedBox(width: 36, height: 36, child: icon),
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
          SizedBox(
            height: 34,
            child: ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: _gold,
                foregroundColor: Colors.black,
                elevation: 0,
                padding: const EdgeInsets.symmetric(horizontal: 20),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(17),
                ),
              ),
              onPressed: onAdd,
              child: Text(
                S.of(context).add,
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
//  Brand icon widgets
// ─────────────────────────────────────────────────────────────────────────────

/// Apple Pay icon — Apple logo in black circle
class _ApplePayIcon extends StatelessWidget {
  const _ApplePayIcon();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 36,
      height: 36,
      decoration: BoxDecoration(
        color: Colors.black,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.white.withValues(alpha: 0.15)),
      ),
      child: const Center(
        child: Icon(Icons.apple, color: Colors.white, size: 22),
      ),
    );
  }
}

/// Google Pay icon — colored G
class _GooglePayIcon extends StatelessWidget {
  const _GooglePayIcon();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 36,
      height: 36,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Center(
        child: RichText(
          text: const TextSpan(
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
            children: [
              TextSpan(text: 'G', style: TextStyle(color: Color(0xFF4285F4))),
            ],
          ),
        ),
      ),
    );
  }
}

/// PayPal icon — P in blue circle
class _PayPalIcon extends StatelessWidget {
  const _PayPalIcon();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 36,
      height: 36,
      decoration: BoxDecoration(
        color: const Color(0xFF003087),
        borderRadius: BorderRadius.circular(10),
      ),
      child: const Center(
        child: Text(
          'P',
          style: TextStyle(
            color: Colors.white,
            fontSize: 20,
            fontWeight: FontWeight.w800,
            fontStyle: FontStyle.italic,
          ),
        ),
      ),
    );
  }
}

/// Credit card icon
class _CardIcon extends StatelessWidget {
  final AppColors color;
  const _CardIcon({required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 36,
      height: 36,
      decoration: BoxDecoration(
        color: const Color(0xFF6B7280).withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(10),
      ),
      child: const Center(
        child: Icon(
          Icons.credit_card_rounded,
          color: Color(0xFF6B7280),
          size: 20,
        ),
      ),
    );
  }
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
