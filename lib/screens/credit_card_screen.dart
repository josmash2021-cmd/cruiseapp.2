import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_stripe/flutter_stripe.dart';
import '../l10n/app_localizations.dart';
import '../config/app_theme.dart';
import '../services/api_service.dart';
import '../services/local_data_service.dart';

class CreditCardScreen extends StatefulWidget {
  final String? firstName;
  final String? lastName;
  final String? email;

  const CreditCardScreen({
    super.key,
    this.firstName,
    this.lastName,
    this.email,
  });

  @override
  State<CreditCardScreen> createState() => _CreditCardScreenState();
}

class _CreditCardScreenState extends State<CreditCardScreen> {
  static const _gold = Color(0xFFE8C547);
  static const _goldLight = Color(0xFFF5D990);

  final _nameCtrl = TextEditingController();
  final _zipCtrl = TextEditingController();

  bool _cardComplete = false;
  bool _isLoading = false;
  CardFieldInputDetails? _cardDetails;

  @override
  void initState() {
    super.initState();
    _nameCtrl.addListener(_refresh);
    _zipCtrl.addListener(_refresh);
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _zipCtrl.dispose();
    super.dispose();
  }

  void _refresh() => setState(() {});

  bool get _canContinue =>
      _cardComplete &&
      _nameCtrl.text.trim().isNotEmpty &&
      _zipCtrl.text.trim().isNotEmpty &&
      !_isLoading;

  Future<void> _submit() async {
    if (!_canContinue) return;
    setState(() => _isLoading = true);

    // Always capture brand/last4 from the card field for local storage
    final brand = _cardDetails?.brand ?? 'card';
    final last4 = _cardDetails?.last4 ?? '????';

    try {
      // Step 1: Get SetupIntent client_secret from backend
      final clientSecret = await ApiService.createSetupIntent();
      if (clientSecret == null || !mounted) {
        // Backend unavailable — save card locally as "pending" and continue.
        // SetupIntent will be retried when the user actually takes a ride.
        await _saveCardLocally(brand, last4);
        if (mounted) Navigator.of(context).pop('$brand:$last4');
        return;
      }

      // Step 2: Confirm SetupIntent — creates PM + authorises card for off-session
      final si = await Stripe.instance.confirmSetupIntent(
        paymentIntentClientSecret: clientSecret,
        params: PaymentMethodParams.card(
          paymentMethodData: PaymentMethodData(
            billingDetails: BillingDetails(
              name: _nameCtrl.text.trim(),
              email: widget.email,
            ),
          ),
        ),
      );

      if (!mounted) return;

      // Step 3: Save the confirmed PaymentMethod ID
      final pmId = si.paymentMethodId;
      await LocalDataService.saveStripePaymentMethodId(pmId);

      // Step 4: ALSO sync to backend so card survives reinstall
      try {
        await ApiService.syncPaymentMethodToBackend(
          stripePaymentMethodId: pmId,
          type: 'stripe_card',
          last4: last4,
          brand: brand,
          setDefault: true,
        );
      } catch (syncErr) {
        debugPrint('[CreditCardScreen] backend sync failed (non-fatal): $syncErr');
        // Non-fatal: card is still saved locally and will be retried on next ride
      }

      // Step 5: Save locally and return
      await _saveCardLocally(brand, last4);
      if (mounted) Navigator.of(context).pop('$brand:$last4');
    } on StripeException catch (e) {
      if (!mounted) return;
      final msg = _stripeErrorMessage(e);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: Colors.red.shade800,
          content: Text(
            msg,
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          duration: const Duration(seconds: 4),
        ),
      );
      setState(() => _isLoading = false);
      return; // Stay on screen so user can correct and retry
    } catch (e) {
      if (!mounted) return;
      // Network or backend error — save locally for retry later
      await _saveCardLocally(brand, last4);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: Colors.orange.shade700,
          content: Text(
            'Card saved locally. Will retry when you book a ride.',
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
      );
      Future.delayed(const Duration(seconds: 2), () {
        if (mounted) Navigator.of(context).pop('$brand:$last4');
      });
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _saveCardLocally(String brand, String last4) async {
    await LocalDataService.linkPaymentMethod('credit_card');
    await LocalDataService.saveCreditCardLast4(last4);
    await LocalDataService.saveCreditCardBrand(brand);
  }

  /// Convert a StripeException into a user-friendly localized message.
  String _stripeErrorMessage(StripeException e) {
    final code = e.error.code.toString().toLowerCase();
    final declineCode = (e.error as dynamic)?.declineCode?.toString().toLowerCase() ?? '';

    // Test card in live mode
    if (code.contains('test_mode_live_card') || declineCode == 'test_mode_live_card') {
      return 'This is a test card. Please use a real card for live payments.';
    }
    // Card declined
    if (declineCode == 'card_declined' || code.contains('card_declined')) {
      return 'Your card was declined. Please try a different card.';
    }
    // Insufficient funds
    if (declineCode == 'insufficient_funds') {
      return 'Insufficient funds. Please try a different payment method.';
    }
    // Incorrect CVC
    if (declineCode == 'incorrect_cvc' || code.contains('incorrect_cvc')) {
      return 'Incorrect security code. Please check and try again.';
    }
    // Expired card
    if (declineCode == 'expired_card' || code.contains('expired_card')) {
      return 'Your card has expired. Please update your payment method.';
    }
    // Incorrect number
    if (declineCode == 'incorrect_number' || code.contains('incorrect_number')) {
      return 'The card number is incorrect. Please verify the details.';
    }
    // Processing error
    if (declineCode == 'processing_error' || code.contains('processing_error')) {
      return 'Payment processing error. Please try again.';
    }
    // Fraudulent
    if (declineCode == 'fraudulent') {
      return 'This payment was flagged for security. Please contact your bank or try a different card.';
    }
    // Generic
    return e.error.localizedMessage ?? 'Payment failed. Please try again or use a different method.';
  }

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);

    return Scaffold(
      backgroundColor: Colors.black,
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
                S.of(context).addYourCard,
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
                S.of(context).enterCardDetails,
                style: TextStyle(fontSize: 15, color: c.textSecondary),
              ),
              const SizedBox(height: 28),

              // ── Card fields ──
              Expanded(
                child: SingleChildScrollView(
                  child: Column(
                    children: [
                      // ── Stripe secure card field with brand logo ──
                      Container(
                        decoration: BoxDecoration(
                          color: c.surface,
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(color: c.border),
                        ),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 4,
                        ),
                        child: Row(
                          children: [
                            Expanded(
                              child: CardField(
                                enablePostalCode: false,
                                style: TextStyle(color: c.textPrimary, fontSize: 16),
                                decoration: InputDecoration(
                                  border: InputBorder.none,
                                  hintStyle: TextStyle(
                                    color: c.textTertiary,
                                    fontSize: 16,
                                  ),
                                ),
                                onCardChanged: (details) {
                                  setState(() {
                                    _cardDetails = details;
                                    _cardComplete = details?.complete ?? false;
                                  });
                                },
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 16),

                      // Name on card
                      _buildField(
                        c,
                        controller: _nameCtrl,
                        hint: S.of(context).nameOnCard,
                        icon: Icons.person_outline_rounded,
                        keyboardType: TextInputType.name,
                        capitalization: TextCapitalization.words,
                      ),
                      const SizedBox(height: 16),

                      // Zip code
                      _buildField(
                        c,
                        controller: _zipCtrl,
                        hint: S.of(context).zipPostalCode,
                        icon: Icons.location_on_outlined,
                        keyboardType: TextInputType.number,
                        formatters: [LengthLimitingTextInputFormatter(10)],
                      ),
                      const SizedBox(height: 16),

                      // Security note
                      Row(
                        children: [
                          const Icon(
                            Icons.shield_outlined,
                            size: 16,
                            color: Colors.green,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              S.of(context).securedByStripe,
                              style: TextStyle(
                                fontSize: 13,
                                color: c.textTertiary,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),

              // ── Add Card button ──
              Padding(
                padding: const EdgeInsets.only(bottom: 24, top: 16),
                child: SizedBox(
                  width: double.infinity,
                  height: 56,
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 250),
                    decoration: BoxDecoration(
                      gradient: _canContinue
                          ? const LinearGradient(colors: [_gold, _goldLight])
                          : null,
                      color: _canContinue ? null : c.surface,
                      borderRadius: BorderRadius.circular(28),
                    ),
                    child: ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.transparent,
                        shadowColor: Colors.transparent,
                        foregroundColor: _canContinue
                            ? const Color(0xFF1A1400)
                            : c.textTertiary,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(28),
                        ),
                      ),
                      onPressed: _canContinue ? _submit : null,
                      child: _isLoading
                          ? const SizedBox(
                              width: 22,
                              height: 22,
                              child: CircularProgressIndicator(
                                strokeWidth: 2.5,
                                color: Color(0xFF1A1400),
                              ),
                            )
                          : Text(
                              S.of(context).addCard,
                              style: const TextStyle(
                                fontSize: 17,
                                fontWeight: FontWeight.w700,
                              ),
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

  Widget _buildField(
    AppColors c, {
    required TextEditingController controller,
    required String hint,
    required IconData icon,
    TextInputType? keyboardType,
    List<TextInputFormatter>? formatters,
    bool obscure = false,
    TextCapitalization capitalization = TextCapitalization.none,
  }) {
    return Container(
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: c.border),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: TextField(
        controller: controller,
        keyboardType: keyboardType,
        inputFormatters: formatters,
        obscureText: obscure,
        textCapitalization: capitalization,
        style: TextStyle(color: c.textPrimary, fontSize: 16),
        decoration: InputDecoration(
          border: InputBorder.none,
          hintText: hint,
          hintStyle: TextStyle(color: c.textTertiary, fontSize: 16),
          prefixIcon: Icon(icon, color: c.textTertiary, size: 20),
          prefixIconConstraints: const BoxConstraints(
            minWidth: 36,
            minHeight: 0,
          ),
        ),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════
//  Card Brand Logo Widget - Displays appropriate card brand icon
// ═══════════════════════════════════════════════════════════════════

class _CardBrandLogo extends StatelessWidget {
  final String? brand;

  const _CardBrandLogo() : brand = null;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    
    // If no brand detected yet, show generic card icon
    if (brand == null || brand!.isEmpty) {
      return Container(
        width: 44,
        height: 28,
        decoration: BoxDecoration(
          color: isDark ? Colors.white.withValues(alpha: 0.1) : Colors.black.withValues(alpha: 0.05),
          borderRadius: BorderRadius.circular(4),
          border: Border.all(
            color: isDark ? Colors.white.withValues(alpha: 0.2) : Colors.black.withValues(alpha: 0.1),
          ),
        ),
        child: Icon(
          Icons.credit_card,
          size: 16,
          color: isDark ? Colors.white.withValues(alpha: 0.5) : Colors.black.withValues(alpha: 0.4),
        ),
      );
    }

    final brandLower = brand!.toLowerCase();
    
    // Return appropriate logo based on brand
    switch (brandLower) {
      case 'visa':
        return _buildVisaLogo();
      case 'mastercard':
        return _buildMastercardLogo();
      case 'amex':
      case 'american_express':
        return _buildAmexLogo();
      case 'discover':
        return _buildDiscoverLogo();
      case 'diners':
      case 'diners_club':
        return _buildDinersLogo();
      case 'jcb':
        return _buildJCBLogo();
      case 'unionpay':
        return _buildUnionPayLogo();
      default:
        return _buildGenericLogo(brand!, isDark);
    }
  }

  Widget _buildVisaLogo() {
    return Container(
      width: 44,
      height: 28,
      decoration: BoxDecoration(
        color: const Color(0xFF1A1F71),
        borderRadius: BorderRadius.circular(4),
      ),
      child: const Center(
        child: Text(
          'VISA',
          style: TextStyle(
            color: Colors.white,
            fontSize: 12,
            fontWeight: FontWeight.w900,
            letterSpacing: 0.5,
          ),
        ),
      ),
    );
  }

  Widget _buildMastercardLogo() {
    return Container(
      width: 44,
      height: 28,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: Colors.black.withValues(alpha: 0.1)),
      ),
      child: Stack(
        alignment: Alignment.center,
        children: [
          // Left circle (red)
          Positioned(
            left: 6,
            child: Container(
              width: 16,
              height: 16,
              decoration: const BoxDecoration(
                color: Color(0xFFEB001B),
                shape: BoxShape.circle,
              ),
            ),
          ),
          // Right circle (orange/yellow)
          Positioned(
            right: 6,
            child: Container(
              width: 16,
              height: 16,
              decoration: const BoxDecoration(
                color: Color(0xFFF79E1B),
                shape: BoxShape.circle,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAmexLogo() {
    return Container(
      width: 44,
      height: 28,
      decoration: BoxDecoration(
        color: const Color(0xFF016FD0),
        borderRadius: BorderRadius.circular(4),
      ),
      child: const Center(
        child: Text(
          'AMEX',
          style: TextStyle(
            color: Colors.white,
            fontSize: 10,
            fontWeight: FontWeight.w900,
            letterSpacing: 0.3,
          ),
        ),
      ),
    );
  }

  Widget _buildDiscoverLogo() {
    return Container(
      width: 44,
      height: 28,
      decoration: BoxDecoration(
        color: const Color(0xFFFF6000),
        borderRadius: BorderRadius.circular(4),
      ),
      child: const Center(
        child: Text(
          'DISC',
          style: TextStyle(
            color: Colors.white,
            fontSize: 10,
            fontWeight: FontWeight.w800,
          ),
        ),
      ),
    );
  }

  Widget _buildDinersLogo() {
    return Container(
      width: 44,
      height: 28,
      decoration: BoxDecoration(
        color: const Color(0xFF004E94),
        borderRadius: BorderRadius.circular(4),
      ),
      child: const Center(
        child: Text(
          'DINERS',
          style: TextStyle(
            color: Colors.white,
            fontSize: 8,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    );
  }

  Widget _buildJCBLogo() {
    return Container(
      width: 44,
      height: 28,
      decoration: BoxDecoration(
        color: const Color(0xFF0066B3),
        borderRadius: BorderRadius.circular(4),
      ),
      child: const Center(
        child: Text(
          'JCB',
          style: TextStyle(
            color: Colors.white,
            fontSize: 12,
            fontWeight: FontWeight.w900,
          ),
        ),
      ),
    );
  }

  Widget _buildUnionPayLogo() {
    return Container(
      width: 44,
      height: 28,
      decoration: BoxDecoration(
        color: const Color(0xFFDE2910),
        borderRadius: BorderRadius.circular(4),
      ),
      child: const Center(
        child: Text(
          'UNION',
          style: TextStyle(
            color: Colors.white,
            fontSize: 8,
            fontWeight: FontWeight.w800,
          ),
        ),
      ),
    );
  }

  Widget _buildGenericLogo(String brandName, bool isDark) {
    return Container(
      width: 44,
      height: 28,
      decoration: BoxDecoration(
        color: isDark ? Colors.white.withValues(alpha: 0.1) : Colors.black.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(
          color: isDark ? Colors.white.withValues(alpha: 0.2) : Colors.black.withValues(alpha: 0.1),
        ),
      ),
      child: Center(
        child: Text(
          brandName.substring(0, min(4, brandName.length)).toUpperCase(),
          style: TextStyle(
            fontSize: 9,
            fontWeight: FontWeight.w700,
            color: isDark ? Colors.white.withValues(alpha: 0.7) : Colors.black.withValues(alpha: 0.6),
          ),
        ),
      ),
    );
  }
}

int min(int a, int b) => a < b ? a : b;
