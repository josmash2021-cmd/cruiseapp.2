import 'dart:async';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_stripe/flutter_stripe.dart';
import '../l10n/app_localizations.dart';
import '../config/api_keys.dart';
import '../config/app_theme.dart';
import '../services/api_service.dart';
import '../services/local_data_service.dart';
import '../services/places_service.dart';
import '../widgets/dismiss_keyboard.dart';
import '../widgets/neu_style.dart';

class CreditCardScreen extends StatefulWidget {
  final String? firstName;
  final String? lastName;
  final String? email;

  /// Card details read by CardScanScreen (OCR — number + expiry only).
  /// When present the Stripe field is pre-filled and the rider only
  /// types CVV and billing address.
  final String? scannedNumber;
  final int? scannedExpMonth;
  final int? scannedExpYear;

  const CreditCardScreen({
    super.key,
    this.firstName,
    this.lastName,
    this.email,
    this.scannedNumber,
    this.scannedExpMonth,
    this.scannedExpYear,
  });

  @override
  State<CreditCardScreen> createState() => _CreditCardScreenState();
}

class _CreditCardScreenState extends State<CreditCardScreen> {
  static const _gold = Color(0xFFE8C547);
  static const _goldLight = Color(0xFFF5D990);

  final _nameCtrl = TextEditingController();
  final _addrCtrl = TextEditingController();
  final _aptCtrl = TextEditingController();
  final _cityCtrl = TextEditingController();
  final _stateCtrl = TextEditingController();
  final _zipCtrl = TextEditingController();

  final _places = PlacesService(ApiKeys.webServices);
  Timer? _addrDebounce;
  List<PlaceSuggestion> _addrSuggestions = [];

  bool _cardComplete = false;
  bool _isLoading = false;
  CardFieldInputDetails? _cardDetails;

  /// Controller that seeds the native card field with the scanned number
  /// + expiry. `initialDetails` is forwarded to the platform view on
  /// creation (`cardDetails` creation param), so the rider lands on the
  /// form with everything but the CVV already typed.
  CardFormEditController? _cardFormCtl;

  String _scannedBrand() {
    final n = widget.scannedNumber ?? '';
    if (n.startsWith('4')) return 'visa';
    if (n.startsWith('5')) return 'mastercard';
    if (n.startsWith('3')) return 'amex';
    if (n.startsWith('6')) return 'discover';
    return 'card';
  }

  @override
  void initState() {
    super.initState();
    if (widget.scannedNumber != null && !kIsWeb) {
      _cardFormCtl = CardFormEditController(
        initialDetails: CardFieldInputDetails(
          complete: false,
          number: widget.scannedNumber,
          expiryMonth: widget.scannedExpMonth,
          expiryYear: widget.scannedExpYear,
        ),
      );
      // onCardChanged may not fire for the seeded values — seed the local
      // copy too so brand/last4 are right if the rider only types CVV.
      _cardDetails = CardFieldInputDetails(
        complete: false,
        number: widget.scannedNumber,
        expiryMonth: widget.scannedExpMonth,
        expiryYear: widget.scannedExpYear,
        brand: _scannedBrand(),
        last4: widget.scannedNumber!.length >= 4
            ? widget.scannedNumber!
                .substring(widget.scannedNumber!.length - 4)
            : null,
      );
    }
    _nameCtrl.addListener(_refresh);
    _addrCtrl.addListener(_refresh);
    _aptCtrl.addListener(_refresh);
    _cityCtrl.addListener(_refresh);
    _stateCtrl.addListener(_refresh);
    _zipCtrl.addListener(_refresh);
    _addrCtrl.addListener(_onAddressChanged);
  }

  @override
  void dispose() {
    _addrDebounce?.cancel();
    _cardFormCtl?.dispose();
    _nameCtrl.dispose();
    _addrCtrl.dispose();
    _aptCtrl.dispose();
    _cityCtrl.dispose();
    _stateCtrl.dispose();
    _zipCtrl.dispose();
    super.dispose();
  }

  void _refresh() => setState(() {});

  // ── Billing address autocomplete ─────────────────────────────────────

  void _onAddressChanged() {
    _addrDebounce?.cancel();
    final q = _addrCtrl.text.trim();
    if (q.length < 3) {
      if (_addrSuggestions.isNotEmpty) {
        setState(() => _addrSuggestions = []);
      }
      return;
    }
    _addrDebounce = Timer(const Duration(milliseconds: 350), () async {
      try {
        final results = await _places.autocomplete(q);
        if (!mounted) return;
        setState(() => _addrSuggestions = results.take(5).toList());
      } catch (_) {}
    });
  }

  /// Fill street / city / state / zip from a suggestion like
  /// "3410 Canopy Trail, Pelham, AL 35124, USA".
  void _pickAddressSuggestion(PlaceSuggestion s) {
    final parts = s.description.split(',').map((p) => p.trim()).toList();
    _addrCtrl.text = parts.isNotEmpty ? parts[0] : s.description;
    if (parts.length >= 3) {
      _cityCtrl.text = parts[1];
      final stateZip =
          parts[2].split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
      if (stateZip.isNotEmpty) _stateCtrl.text = stateZip[0];
      if (stateZip.length > 1) {
        _zipCtrl.text = stateZip.sublist(1).join(' ');
      }
    }
    _places.resetSession();
    setState(() => _addrSuggestions = []);
  }

  bool get _canContinue =>
      _cardComplete &&
      _nameCtrl.text.trim().isNotEmpty &&
      _addrCtrl.text.trim().isNotEmpty &&
      _cityCtrl.text.trim().isNotEmpty &&
      _stateCtrl.text.trim().isNotEmpty &&
      _zipCtrl.text.trim().isNotEmpty &&
      !_isLoading;

  BillingDetails get _billingDetails => BillingDetails(
        name: _nameCtrl.text.trim(),
        email: widget.email,
        address: Address(
          line1: _addrCtrl.text.trim(),
          line2: _aptCtrl.text.trim(),
          city: _cityCtrl.text.trim(),
          state: _stateCtrl.text.trim(),
          postalCode: _zipCtrl.text.trim(),
          country: 'US',
        ),
      );

  Future<void> _submit() async {
    if (!_canContinue) return;
    setState(() => _isLoading = true);

    // Always capture brand/last4 from the card field for local storage
    final brand = _cardDetails?.brand ?? 'card';
    final last4 = _cardDetails?.last4 ?? '????';

    try {
      // Registration flow has NO account yet — and therefore no JWT. Calling
      // the authed setup-intent endpoint from here answered 401, the global
      // 401 handler cleared the session and the app "restarted" at the login
      // page. So: no token → validate the card directly with Stripe (the
      // publishable key is enough for createToken) and save it; the
      // SetupIntent that attaches it for charging runs once the account
      // exists.
      final token = await ApiService.getToken();
      if (token == null) {
        await Stripe.instance.createToken(
          CreateTokenParams.card(
            params: CardTokenParams(
              name: _nameCtrl.text.trim(),
              address: _billingDetails.address,
            ),
          ),
        );
        await _saveCardLocally(brand, last4);
        if (mounted) Navigator.of(context).pop('$brand:$last4');
        return;
      }

      // Step 1: Get SetupIntent client_secret from backend
      final clientSecret = await ApiService.createSetupIntent().timeout(const Duration(seconds: 15));
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
            billingDetails: _billingDetails,
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
        ).timeout(const Duration(seconds: 15));
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
      backgroundColor: neuBase,
      body: DismissKeyboard(
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
              const SizedBox(height: 12),

              // ── Back button ──
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
                        decoration: neuBox(radius: 16, pressed: true),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 4,
                        ),
                        child: Row(
                          children: [
                            Expanded(
                              // flutter_stripe's card fields are native-only —
                              // on web they throw Platform._operatingSystem.
                              // Show a clean placeholder instead; the "Add
                              // card" button stays disabled because
                              // _cardComplete never becomes true here.
                              //
                              // CardFormField (not CardField) with full
                              // details: createToken reads the card straight
                              // from the field, which is how a rider with no
                              // account yet still gets a REAL Stripe
                              // validation at registration.
                              child: kIsWeb
                                  ? Padding(
                                      padding: const EdgeInsets.symmetric(
                                          vertical: 14, horizontal: 4),
                                      child: Row(
                                        children: [
                                          Icon(Icons.credit_card_rounded,
                                              color: c.textTertiary, size: 20),
                                          const SizedBox(width: 10),
                                          Expanded(
                                            child: Text(
                                              S.of(context).cardEntryMobileOnly,
                                              style: TextStyle(
                                                color: c.textTertiary,
                                                fontSize: 13.5,
                                                height: 1.35,
                                              ),
                                            ),
                                          ),
                                        ],
                                      ),
                                    )
                                  : CardFormField(
                                      controller: _cardFormCtl,
                                      enablePostalCode: false,
                                      dangerouslyGetFullCardDetails: true,
                                      style: CardFormStyle(
                                        textColor: c.textPrimary,
                                        fontSize: 16,
                                        placeholderColor: c.textTertiary,
                                        backgroundColor: Colors.transparent,
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

                      // Billing address — with suggestions as they type
                      _buildField(
                        c,
                        controller: _addrCtrl,
                        hint: S.of(context).billingAddressHint,
                        icon: Icons.location_on_outlined,
                        keyboardType: TextInputType.streetAddress,
                        capitalization: TextCapitalization.words,
                      ),
                      if (_addrSuggestions.isNotEmpty)
                        Container(
                          margin: const EdgeInsets.only(top: 6),
                          decoration: neuBox(radius: 14),
                          child: Column(
                            children: [
                              for (final sg in _addrSuggestions)
                                GestureDetector(
                                  behavior: HitTestBehavior.opaque,
                                  onTap: () => _pickAddressSuggestion(sg),
                                  child: Padding(
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 16, vertical: 12),
                                    child: Row(
                                      children: [
                                        Icon(Icons.place_outlined,
                                            size: 16, color: c.textTertiary),
                                        const SizedBox(width: 10),
                                        Expanded(
                                          child: Text(
                                            sg.description,
                                            maxLines: 2,
                                            overflow: TextOverflow.ellipsis,
                                            style: TextStyle(
                                              color: c.textPrimary,
                                              fontSize: 13.5,
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        ),
                      const SizedBox(height: 16),

                      // Apt / suite — optional
                      _buildField(
                        c,
                        controller: _aptCtrl,
                        hint: S.of(context).aptSuiteOptional,
                        icon: Icons.door_front_door_outlined,
                        capitalization: TextCapitalization.words,
                      ),
                      const SizedBox(height: 16),

                      // City + State + Zip
                      Row(
                        children: [
                          Expanded(
                            flex: 5,
                            child: _buildField(
                              c,
                              controller: _cityCtrl,
                              hint: S.of(context).cityHint,
                              icon: Icons.location_city_rounded,
                              capitalization: TextCapitalization.words,
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            flex: 3,
                            child: _buildField(
                              c,
                              controller: _stateCtrl,
                              hint: S.of(context).stateHint,
                              icon: Icons.map_outlined,
                              capitalization: TextCapitalization.characters,
                              formatters: [LengthLimitingTextInputFormatter(2)],
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            flex: 4,
                            child: _buildField(
                              c,
                              controller: _zipCtrl,
                              hint: S.of(context).zipPostalCode,
                              icon: Icons.markunread_mailbox_outlined,
                              keyboardType: TextInputType.number,
                              formatters: [LengthLimitingTextInputFormatter(10)],
                            ),
                          ),
                        ],
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
                      color: _canContinue ? null : neuPressed,
                      borderRadius: BorderRadius.circular(28),
                      boxShadow: _canContinue
                          ? [
                              BoxShadow(
                                color: _gold.withValues(alpha: 0.35),
                                blurRadius: 20,
                                offset: const Offset(0, 8),
                              ),
                            ]
                          : null,
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
      decoration: neuBox(radius: 16, pressed: true),
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
