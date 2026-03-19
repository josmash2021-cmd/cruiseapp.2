import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_stripe/flutter_stripe.dart';
import '../l10n/app_localizations.dart';
import '../config/app_theme.dart';
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

    try {
      // Create a PaymentMethod via Stripe SDK (tokenizes the card securely)
      final paymentMethod = await Stripe.instance.createPaymentMethod(
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

      // Extract card brand and last4 from Stripe's response
      final card = paymentMethod.card;
      final brand = card.brand ?? 'card';
      final last4 = card.last4 ?? '????';

      // Persist the Stripe payment method ID for future charges
      await LocalDataService.saveStripePaymentMethodId(paymentMethod.id);

      if (!mounted) return;
      // Return brand:last4 so caller can persist both
      Navigator.of(context).pop('$brand:$last4');
    } on StripeException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: Colors.red.shade700,
          content: Text(
            e.error.localizedMessage ?? S.of(context).cardCouldNotBeProcessed,
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: Colors.red.shade700,
          content: Text(
            S.of(context).somethingWentWrong,
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
      );
    } finally {
      if (mounted) setState(() => _isLoading = false);
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
                            // Card brand logo
                            _CardBrandLogo(brand: _cardDetails?.brand),
                            const SizedBox(width: 8),
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

  const _CardBrandLogo({this.brand});

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
        return _buildGenericLogo(brand!);
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

  Widget _buildGenericLogo(String brandName) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
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
