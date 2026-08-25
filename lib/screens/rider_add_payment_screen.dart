import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:pay/pay.dart';

import '../l10n/app_localizations.dart';
import '../services/api_service.dart';
import '../services/local_data_service.dart';
import '../services/payment_service.dart';
import '../utils/app_platform.dart';
import 'card_scan_screen.dart';
import 'ready_to_ride_screen.dart';

/// Rider phone onboarding — step 4, "Add payment method" (Lyft-style).
///
/// Sits between [RiderEmailScreen] and [ReadyToRideScreen]. Vertical list:
/// Apple Pay first on iOS / Google Pay on Android (wallet verification via
/// the `pay` plugin, $0.00 auth — same sheets as the old email-signup
/// onboarding), then "Credit or debit card" which opens the camera scanner
/// FIRST (CardScanScreen) and falls back to the pre-filled manual form.
/// A discreet "Not now" at the bottom skips the step — the existing payment
/// gate at ride request covers riders without a method.
///
/// A rider who already has a saved method (existing user re-entering the
/// flow) never sees this page: initState checks the backend payment methods
/// (plus the locally linked wallets) and jumps straight to ReadyToRide.
class RiderAddPaymentScreen extends StatefulWidget {
  final Map<String, dynamic> user;

  const RiderAddPaymentScreen({super.key, required this.user});

  @override
  State<RiderAddPaymentScreen> createState() => _RiderAddPaymentScreenState();
}

class _RiderAddPaymentScreenState extends State<RiderAddPaymentScreen> {
  static const _navy = Color(0xFF14141A);
  static const _gold = Color(0xFFE8C547);

  /// true while we check for an already-saved method (existing riders skip
  /// this step entirely).
  bool _checking = true;
  bool _finished = false;

  String get _firstName =>
      (widget.user['first_name'] as String? ?? '').trim().split(' ').first;

  @override
  void initState() {
    super.initState();
    _checkExistingMethods();
  }

  /// Existing rider re-entering the flow with a payment method already on
  /// file (backend card/bank, or a locally linked wallet) skips this step.
  Future<void> _checkExistingMethods() async {
    var has = false;
    try {
      final linked = await LocalDataService.getLinkedPaymentMethods();
      if (linked.contains('apple_pay') || linked.contains('google_pay')) {
        has = true;
      } else {
        final methods = await ApiService.getMyPaymentMethods();
        has = methods.isNotEmpty;
      }
    } catch (_) {
      // Non-fatal — on a network hiccup we show the step instead of
      // risking skipping a rider who has no method.
    }
    if (!mounted) return;
    if (has) {
      _goNext(replace: true);
    } else {
      setState(() => _checking = false);
    }
  }

  /// Continues to the redesigned ready-to-ride page (its CTA lands home).
  void _goNext({bool replace = false}) {
    if (_finished) return;
    _finished = true;
    final route = MaterialPageRoute(
      builder: (_) => ReadyToRideScreen(firstName: _firstName),
    );
    if (replace) {
      Navigator.of(context).pushReplacement(route);
    } else {
      Navigator.of(context).push(route);
    }
  }

  // ── Card: scanner first, manual form pre-filled as its fallback ──
  Future<void> _addCard() async {
    final result = await Navigator.of(context).push<String>(
      MaterialPageRoute(builder: (_) => const CardScanScreen()),
    );
    if (result == null || !mounted) return;
    final parts = result.split(':');
    if (parts.length == 2) {
      await LocalDataService.saveCreditCardBrand(parts[0]);
      await LocalDataService.saveCreditCardLast4(parts[1]);
    }
    await LocalDataService.linkPaymentMethod('credit_card');
    await LocalDataService.setDefaultPaymentMethod('credit_card');
    if (!mounted) return;
    _goNext();
  }

  // ── Wallets: $0.00 verification sheet, then mark linked + default ──
  Future<void> _linkApplePay() async {
    final s = S.of(context);
    final available = await PaymentService.isApplePayAvailable();
    if (!mounted) return;
    if (!available) {
      _snack(s.applePayNotSetUp);
      return;
    }
    _showWalletSheet(
      config: await PaymentService.applePayConfig(),
      title: s.confirmApplePay,
      prompt: s.applePayPrompt,
      builder: (config, onResult, onError) => ApplePayButton(
        paymentConfiguration: config,
        paymentItems: [
          PaymentItem(
            label: s.accountVerification,
            amount: '0.00',
            status: PaymentItemStatus.final_price,
          ),
        ],
        type: ApplePayButtonType.inStore,
        style: ApplePayButtonStyle.black,
        height: 54,
        onPaymentResult: onResult,
        loadingIndicator: const Center(
          child: CircularProgressIndicator(color: _gold),
        ),
        onError: onError,
      ),
      methodId: 'apple_pay',
      linkedMsg: s.applePayLinked,
    );
  }

  Future<void> _linkGooglePay() async {
    final s = S.of(context);
    final available = await PaymentService.isGooglePayAvailable();
    if (!mounted) return;
    if (!available) {
      _snack(s.googlePayNotSetUp);
      return;
    }
    _showWalletSheet(
      config: await PaymentService.googlePayConfig(),
      title: s.confirmGooglePay,
      prompt: s.googlePayPrompt,
      builder: (config, onResult, onError) => GooglePayButton(
        paymentConfiguration: config,
        paymentItems: [
          PaymentItem(
            label: s.accountVerification,
            amount: '0.00',
            status: PaymentItemStatus.final_price,
          ),
        ],
        type: GooglePayButtonType.pay,
        theme: GooglePayButtonTheme.dark,
        height: 54,
        onPaymentResult: onResult,
        loadingIndicator: const Center(
          child: CircularProgressIndicator(color: _gold),
        ),
        onError: onError,
      ),
      methodId: 'google_pay',
      linkedMsg: s.googlePayLinked,
    );
  }

  void _showWalletSheet({
    required PaymentConfiguration config,
    required String title,
    required String prompt,
    required Widget Function(
      PaymentConfiguration config,
      void Function(Map<String, dynamic>) onResult,
      void Function(Object? error) onError,
    ) builder,
    required String methodId,
    required String linkedMsg,
  }) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) => Container(
        decoration: const BoxDecoration(
          color: Color(0xFF1C1C22),
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
        padding: const EdgeInsets.fromLTRB(24, 16, 24, 36),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 20),
            Text(
              title,
              style: GoogleFonts.poppins(
                fontSize: 20,
                fontWeight: FontWeight.w800,
                color: Colors.white,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              prompt,
              textAlign: TextAlign.center,
              style: GoogleFonts.inter(
                fontSize: 14,
                color: Colors.white.withValues(alpha: 0.65),
              ),
            ),
            const SizedBox(height: 24),
            builder(
              config,
              (result) async {
                Navigator.of(ctx).pop();
                await LocalDataService.linkPaymentMethod(methodId);
                await LocalDataService.setDefaultPaymentMethod(methodId);
                if (!mounted) return;
                _snack(linkedMsg);
                _goNext();
              },
              (error) {
                Navigator.of(ctx).pop();
                if (!mounted) return;
                _snack(
                  methodId == 'apple_pay'
                      ? S.of(context).applePayError('$error')
                      : S.of(context).googlePayError('$error'),
                );
              },
            ),
            const SizedBox(height: 12),
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: Text(
                S.of(ctx).cancel,
                style: TextStyle(color: Colors.white.withValues(alpha: 0.5)),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _snack(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        backgroundColor: _gold,
        behavior: SnackBarBehavior.floating,
        content: Text(
          msg,
          style: const TextStyle(
            color: Colors.black,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final pad = MediaQuery.of(context).padding;
    final s = S.of(context);

    return Scaffold(
      backgroundColor: _navy,
      body: _checking
          ? const Center(
              child: CircularProgressIndicator(color: _gold),
            )
          : SafeArea(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // ── Back ──
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                    child: GestureDetector(
                      onTap: () => Navigator.of(context).pop(),
                      child: const SizedBox(
                        width: 40,
                        height: 40,
                        child: Icon(
                          Icons.arrow_back_rounded,
                          color: Colors.white,
                          size: 24,
                        ),
                      ),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 28),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const SizedBox(height: 24),
                        Text(
                          s.addPaymentMethod,
                          style: GoogleFonts.poppins(
                            fontSize: 28,
                            fontWeight: FontWeight.w700,
                            letterSpacing: -0.5,
                            color: Colors.white,
                            height: 1.15,
                          ),
                        ),
                        const SizedBox(height: 10),
                        Text(
                          s.addPaymentMethodMsg,
                          style: GoogleFonts.inter(
                            fontSize: 15,
                            color: Colors.white.withValues(alpha: 0.65),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 32),

                  // ── Lyft-style method list ──
                  Expanded(
                    child: ListView(
                      physics: const BouncingScrollPhysics(),
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      children: [
                        if (AppPlatform.isIOS) ...[
                          _MethodRow(
                            iconBg: Colors.black,
                            icon: const Icon(Icons.apple,
                                color: Colors.white, size: 20),
                            label: 'Apple Pay',
                            onTap: _linkApplePay,
                          ),
                          _divider(),
                        ],
                        if (AppPlatform.isAndroid) ...[
                          _MethodRow(
                            iconBg: Colors.white,
                            icon: const Icon(Icons.payments_outlined,
                                color: Colors.black, size: 18),
                            label: 'Google Pay',
                            onTap: _linkGooglePay,
                          ),
                          _divider(),
                        ],
                        _MethodRow(
                          iconBg: Colors.white.withValues(alpha: 0.07),
                          icon: const Icon(Icons.credit_card_rounded,
                              color: Colors.white, size: 18),
                          label: s.creditDebitCard,
                          chevron: true,
                          onTap: _addCard,
                        ),
                      ],
                    ),
                  ),

                  // ── Not now ──
                  Padding(
                    padding: EdgeInsets.fromLTRB(28, 8, 28, pad.bottom + 8),
                    child: Center(
                      child: TextButton(
                        onPressed: _goNext,
                        child: Text(
                          s.notNow,
                          style: GoogleFonts.inter(
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
                            color: Colors.white.withValues(alpha: 0.55),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
    );
  }

  Widget _divider() => Padding(
        padding: const EdgeInsets.only(left: 58),
        child: Container(
          height: 1,
          color: Colors.white.withValues(alpha: 0.06),
        ),
      );
}

/// Lyft-style row, same geometry as the ride payment picker list.
class _MethodRow extends StatelessWidget {
  final Color iconBg;
  final Widget icon;
  final String label;
  final bool chevron;
  final VoidCallback onTap;

  const _MethodRow({
    required this.iconBg,
    required this.icon,
    required this.label,
    this.chevron = false,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: SizedBox(
        height: 58,
        child: Row(
          children: [
            Container(
              width: 44,
              height: 30,
              decoration: BoxDecoration(
                color: iconBg,
                borderRadius: BorderRadius.circular(7),
                border:
                    Border.all(color: Colors.white.withValues(alpha: 0.08)),
              ),
              alignment: Alignment.center,
              child: icon,
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontFamily: 'Poppins',
                  color: Colors.white,
                  fontSize: 14.5,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            if (chevron)
              Icon(Icons.chevron_right_rounded,
                  color: Colors.white.withValues(alpha: 0.4), size: 22),
          ],
        ),
      ),
    );
  }
}
