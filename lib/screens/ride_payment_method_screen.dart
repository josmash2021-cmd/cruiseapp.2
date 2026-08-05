import '../utils/app_platform.dart';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_stripe/flutter_stripe.dart';
import '../services/haptic_service.dart';
import '../services/api_service.dart';
import '../services/local_data_service.dart';

import '../l10n/app_localizations.dart';
import '../widgets/neu_style.dart';
import 'credit_card_screen.dart';
import 'ride_payment_sheet.dart';

// ═══════════════════════════════════════════════════════════════════
//  Payment Method — Grid 2×2 de tarjetas cuadradas como en la web de Shopify
//
//  Layout: Cuadrícula 2×2 con:
//    - Apple Pay (fondo negro, icono blanco)
//    - Google Pay (fondo blanco, icono de colores)
//    - Tarjeta Débito/Crédito (fondo gris oscuro, icono blanco)
//    - Tap to Pay (fondo azul oscuro, icono NFC azul)
//    - Bank Account (coming soon)
//    - Modo de Prueba (fondo oscuro dorado, icono dorado)
// ═══════════════════════════════════════════════════════════════════

const _gold = Color(0xFFE8C547);
// Neumorphic page background (shows through over the dark map).
const _bg = neuBase;

class PaymentMethodId {
  static const apple = 'apple_pay';
  static const google = 'google_pay';
  static const card = 'card';
  static const bank = 'bank_account';
  static const tapToPay = 'tap_to_pay';
  static const test = 'test_mode';

  /// Pay the ride with the Cruise Cash balance (sheet toggle). Only
  /// requestable while the balance covers the full fare — the Request
  /// button is disabled otherwise.
  static const cruiseCash = 'cruise_cash';
}

/// Opens the payment method picker and returns the selected method id.
///
/// Since 2026-08-04 this is the Uber-style bottom sheet
/// (ride_payment_sheet.dart), not the old full-screen 2×2 grid. The
/// contract is unchanged: resolves with a PaymentMethodId.* string, or
/// null when dismissed. RidePaymentMethodScreen below is kept as the
/// grid fallback but has no callers on this path anymore.
Future<String?> showRidePaymentMethodPicker(
  BuildContext context, {
  required String currentMethod,
  bool showTestMode = false,
}) {
  return showCruisePaymentSheet(
    context,
    currentMethod: currentMethod,
    showTestMode: showTestMode,
  );
}

class RidePaymentMethodScreen extends StatefulWidget {
  final String currentMethod;
  final bool showTestMode;

  const RidePaymentMethodScreen({
    super.key,
    required this.currentMethod,
    this.showTestMode = false,
  });

  @override
  State<RidePaymentMethodScreen> createState() =>
      _RidePaymentMethodScreenState();
}

class _RidePaymentMethodScreenState extends State<RidePaymentMethodScreen>
    with TickerProviderStateMixin, WidgetsBindingObserver {
  late String _selected;
  late final AnimationController _entryCtl;

  // Saved debit/credit card — when present the card tile shows the brand
  // logo + last 4 digits instead of the "Add card" prompt.
  String? _cardBrand;
  String? _cardLast4;

  // Linked bank account (ACH) — when present the bank tile shows the
  // bank name / last 4 instead of the linking prompt.
  String? _bankLast4;
  String? _bankName;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _selected = widget.currentMethod;
    _entryCtl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 500),
    )..forward();
    _loadCardInfo();
    _loadBankInfo();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Refresh bank info when returning from the linking browser flow.
    if (state == AppLifecycleState.resumed) _loadBankInfo();
  }

  /// Loads the saved card from local cache instantly, then refreshes from
  /// the backend so cards survive reinstalls (same contract as the
  /// ride-request controller: display_name "Visa ending in 4242").
  Future<void> _loadCardInfo() async {
    final last4 = await LocalDataService.getCreditCardLast4();
    final brand = await LocalDataService.getCreditCardBrand();
    if (!mounted) return;
    setState(() {
      _cardLast4 = last4;
      _cardBrand = brand;
    });

    try {
      final methods = await ApiService.getMyPaymentMethods();
      final stripeCards =
          methods.where((m) => m['method_type'] == 'stripe_card').toList();
      if (stripeCards.isEmpty) return;
      final defaultCard = stripeCards.firstWhere(
        (m) => m['is_default'] == true,
        orElse: () => stripeCards.first,
      );
      final displayName = defaultCard['display_name'] as String? ?? '';
      final match = RegExp(r'(\d{4})$').firstMatch(displayName);
      if (match == null) return;
      final freshBrand = displayName.split(' ').first.toLowerCase();
      await LocalDataService.saveCreditCardLast4(match.group(1)!);
      await LocalDataService.saveCreditCardBrand(freshBrand);
      if (!mounted) return;
      setState(() {
        _cardLast4 = match.group(1);
        _cardBrand = freshBrand;
      });
    } catch (_) {
      // Non-fatal — the local cache (if any) is already showing.
    }
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

  /// Opens the add-card flow; on success ("brand:last4") the tile updates
  /// to the brand logo + last 4 digits.
  Future<void> _addCard() async {
    HapticService.selectionClick();
    final result = await Navigator.of(context).push<String>(
      MaterialPageRoute(builder: (_) => const CreditCardScreen()),
    );
    if (result == null || !mounted) return;
    final parts = result.split(':');
    if (parts.length == 2) {
      await LocalDataService.saveCreditCardBrand(parts[0]);
      await LocalDataService.saveCreditCardLast4(parts[1]);
      await LocalDataService.linkPaymentMethod('credit_card');
      if (!mounted) return;
      setState(() {
        _cardBrand = parts[0];
        _cardLast4 = parts[1];
      });
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _entryCtl.dispose();
    super.dispose();
  }

  void _pick(String id) {
    HapticService.selectionClick();
    // Select and stay.
    //
    // This used to close the screen 260 ms after a tap, which left no
    // moment in which "set as default" could exist — the rider was already
    // gone. Choosing and keeping are two different decisions, and the
    // second one needs the screen to still be there to make it on.
    setState(() => _selected = id);
  }

  bool _linkingBank = false;

  /// Opens the native Stripe Financial Connections sheet to link a bank
  /// account (ACH), then attaches it server-side so it can be charged.
  Future<void> _openBankConnection(BuildContext ctx) async {
    if (_linkingBank) return; // double-tap guard
    HapticService.selectionClick();
    final s = S.of(ctx);

    if (kIsWeb) {
      // flutter_stripe's FC sheet is native-only; Stripe hosts no web URL
      // for this flow (the session object only carries a client_secret).
      _showBankError(ctx, s.bankLinkMobileOnly);
      return;
    }

    _linkingBank = true;
    showDialog(
      context: ctx,
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
        _showBankError(ctx, s.genericPaymentError);
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

      // Stripe still wants microdeposit verification — the ACH mandate isn't
      // live, so any ride charged to this account would decline. Don't cache
      // the pm id or mark the method linked; tell the rider what's pending.
      if (attached?['requires_verification'] == true) {
        _showBankError(ctx, s.bankNeedsVerification);
        return;
      }

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
      if (mounted) {
        ScaffoldMessenger.of(ctx).showSnackBar(
          SnackBar(
            content: Text(s.bankAccountLinked),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } on StripeException catch (e) {
      if (!mounted) return;
      if (Navigator.of(context, rootNavigator: true).canPop()) {
        Navigator.of(context, rootNavigator: true).pop(); // dismiss loading
      }
      // User cancelled the native sheet — stay silent, that's fine.
      final code = e.error.code.toString().toLowerCase();
      if (!code.contains('cancel')) {
        _showBankError(
            ctx, e.error.localizedMessage ?? s.genericPaymentError);
      }
    } catch (e) {
      if (!mounted) return;
      if (Navigator.of(context, rootNavigator: true).canPop()) {
        Navigator.of(context, rootNavigator: true).pop(); // dismiss loading
      }
      _showBankError(ctx, '${s.genericPaymentError} (${e.toString()})');
    } finally {
      _linkingBank = false;
    }
  }

  void _showBankError(BuildContext ctx, String msg) {
    ScaffoldMessenger.of(ctx).showSnackBar(
      SnackBar(
        content: Text(msg),
        backgroundColor: Colors.red.shade800,
        behavior: SnackBarBehavior.floating,
      ),
    );
  }


  @override
  Widget build(BuildContext context) {
    final s = S.of(context);

    return Scaffold(
      backgroundColor: _bg,
      body: SafeArea(
        child: Column(
          children: [
            _Header(
              title: s.paymentMethodTitle,
              // Carries the choice back for THIS ride. Nothing is
              // written to storage on this path — only Continue below
              // persists the choice as the default.
              onBack: () => Navigator.of(context)
                  .pop(_selected.isEmpty ? null : _selected),
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
                child: GridView.count(
                  crossAxisCount: 2,
                  mainAxisSpacing: 12,
                  crossAxisSpacing: 12,
                  childAspectRatio: 1.0,
                  physics: const BouncingScrollPhysics(),
                  // iOS shows Apple Pay; Android shows Google Pay. Both
                  // platforms also see Card + Bank Account (coming soon)
                  // and — when enabled — the Test Mode tile for QA.
                  children: [
                    if (AppPlatform.isIOS)
                      _PayCard(
                        entryCtl: _entryCtl,
                        staggerDelay: 0.00,
                        id: PaymentMethodId.apple,
                        selected: _selected == PaymentMethodId.apple,
                        iconBg: Colors.black,
                        label: 'Apple Pay',
                        icon: const Icon(Icons.apple,
                            color: Colors.white, size: 32),
                        onTap: () => _pick(PaymentMethodId.apple),
                      ),
                    if (AppPlatform.isAndroid)
                      _PayCard(
                        entryCtl: _entryCtl,
                        staggerDelay: 0.00,
                        id: PaymentMethodId.google,
                        selected: _selected == PaymentMethodId.google,
                        iconBg: Colors.white,
                        label: 'Google Pay',
                        icon: _GoogleGLogo(size: 32),
                        onTap: () => _pick(PaymentMethodId.google),
                      ),
                    // Saved card: brand logo + last 4 digits. Tapping it
                    // selects it as the payment method.
                    if (_cardLast4 != null)
                      _PayCard(
                        entryCtl: _entryCtl,
                        staggerDelay: 0.08,
                        id: PaymentMethodId.card,
                        selected: _selected == PaymentMethodId.card,
                        iconBg: const Color(0xFF2A2A2A),
                        label: '•••• $_cardLast4',
                        icon: _CardBrandBadge(brand: _cardBrand),
                        onTap: () => _pick(PaymentMethodId.card),
                      ),
                    // Add card — ALWAYS on screen, never selectable.
                    //
                    // This used to be an either/or with the tile above: the
                    // moment a card was on file the add tile vanished, so a
                    // rider had no way to add or change a card from here at
                    // all. The only escape was having no card.
                    _PayCard(
                      entryCtl: _entryCtl,
                      staggerDelay: _cardLast4 != null ? 0.12 : 0.08,
                      id: PaymentMethodId.card,
                      selected: false,
                      iconBg: const Color(0xFF2A2A2A),
                      label: s.addDebitCreditCard,
                      icon: const Icon(
                        Icons.add_card_rounded,
                        color: Colors.white,
                        size: 28,
                      ),
                      onTap: _addCard,
                    ),
                    // Tap to Pay - NFC Contactless Payment
                    // Only visible on Android. iOS requires Apple's
                    // proximity-reader entitlement which is per-app and
                    // pending approval — the SDK throws at runtime
                    // without it, so we hide the option entirely.
                    if (AppPlatform.isAndroid)
                      _PayCard(
                        entryCtl: _entryCtl,
                        staggerDelay: 0.12,
                        id: PaymentMethodId.tapToPay,
                        selected: _selected == PaymentMethodId.tapToPay,
                        iconBg: const Color(0xFF1A237E), // Deep blue
                        iconBorder:
                            const Color(0xFF4A90D9).withValues(alpha: 0.5),
                        label: 'Tap to Pay',
                        secondary: 'Hold card to phone',
                        icon: const Icon(
                          Icons.contactless,
                          color: Color(0xFF4A90D9),
                          size: 32,
                        ),
                        onTap: () => _pick(PaymentMethodId.tapToPay),
                      ),
                    _PayCard(
                      entryCtl: _entryCtl,
                      staggerDelay: 0.16,
                      id: PaymentMethodId.bank,
                      selected: _selected == PaymentMethodId.bank,
                      iconBg: const Color(0xFF0F1A12),
                      iconBorder:
                          const Color(0xFF22C55E).withValues(alpha: 0.45),
                      label: _bankLast4 != null
                          ? (_bankName != null
                              ? '$_bankName •••• $_bankLast4'
                              : 'Bank •••• $_bankLast4')
                          : 'Bank Account',
                      icon: const Icon(Icons.account_balance_rounded,
                          color: Color(0xFF22C55E), size: 28),
                      onTap: _bankLast4 != null
                          ? () => _pick(PaymentMethodId.bank)
                          : () => _openBankConnection(context),
                    ),
                    if (widget.showTestMode)
                      _PayCard(
                        entryCtl: _entryCtl,
                        staggerDelay: 0.24,
                        id: PaymentMethodId.test,
                        selected: _selected == PaymentMethodId.test,
                        iconBg: const Color(0xFF1A1A1A),
                        iconBorder: _gold.withValues(alpha: 0.50),
                        label: s.testModeLabel,
                        secondary: s.simulatePayment,
                        icon: const Icon(Icons.tune_rounded,
                            color: _gold, size: 28),
                        onTap: () => _pick(PaymentMethodId.test),
                      ),
                  ],
                ),
              ),
            ),

            // ── Confirm ──
            //
            // One button at the bottom (user spec 2026-08-04: the "Set as
            // default" button is gone — Continue replaces it). Continue
            // confirms the selected method for this ride AND quietly keeps
            // it as the default for the next ones, so the choice sticks
            // without a second decision. Slides up only once something is
            // selected — a button that materialises under the thumb is a
            // button people press by accident.
            AnimatedSize(
              duration: const Duration(milliseconds: 340),
              curve: Curves.easeInOutCubicEmphasized,
              alignment: Alignment.topCenter,
              child: _selected.isEmpty
                  ? const SizedBox(width: double.infinity, height: 0)
                  : SafeArea(
                      top: false,
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
                        child: GestureDetector(
                          onTap: () {
                            HapticService.selectionClick();
                            // Fire-and-forget: persisting the default must
                            // never delay the pop. Storage uses
                            // 'credit_card' (what the request screen
                            // restores); the picker contract returns
                            // 'card' — same mapping the live sheet does.
                            LocalDataService.setDefaultPaymentMethod(
                                _selected == PaymentMethodId.card
                                    ? 'credit_card'
                                    : _selected);
                            Navigator.of(context).pop(_selected);
                          },
                          child: Container(
                            height: 52,
                            alignment: Alignment.center,
                            decoration: BoxDecoration(
                              color: _gold,
                              borderRadius: BorderRadius.circular(16),
                              boxShadow: [
                                BoxShadow(
                                  color: _gold.withValues(alpha: 0.3),
                                  offset: const Offset(0, 4),
                                  blurRadius: 12,
                                ),
                              ],
                            ),
                            child: Text(
                              S.of(context).continueBtn,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: Color(0xFF1A1400),
                                fontSize: 15,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
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
}

// ═══════════════════════════════════════════════════════════════════
//  Header — .vipRide__payOverlay__header:
//    display:flex; align-items:center; gap:14px; padding:16px 16px 12px.
//  Back button: 38×38 circle, bg rgba(255,255,255,.07), border .10.
//  Title: 18px w700 #fff.
// ═══════════════════════════════════════════════════════════════════

class _Header extends StatelessWidget {
  final String title;
  final VoidCallback onBack;
  const _Header({required this.title, required this.onBack});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
      child: Row(
        children: [
          Material(
            color: Colors.transparent,
            shape: const CircleBorder(),
            child: InkWell(
              onTap: onBack,
              customBorder: const CircleBorder(),
              child: Container(
                width: 40,
                height: 40,
                decoration: neuBox(radius: 14, pressed: true),
                alignment: Alignment.center,
                child: const Icon(Icons.arrow_back_rounded,
                    color: Colors.white, size: 18),
              ),
            ),
          ),
          const SizedBox(width: 14),
          Text(
            title,
            style: const TextStyle(
              fontFamily: 'Poppins',
              color: Colors.white,
              fontSize: 18,
              fontWeight: FontWeight.w700,
              letterSpacing: -0.2,
            ),
          ),
        ],
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════
//  Card — Tarjeta cuadrada para método de pago (Grid 2×2)
//  Layout: Icono grande arriba, label abajo, check esquina superior derecha
// ═══════════════════════════════════════════════════════════════════

class _PayCard extends StatefulWidget {
  final AnimationController entryCtl;
  final double staggerDelay;
  final String id;
  final bool selected;
  final Color iconBg;
  final Color? iconBorder;
  final String label;
  final String? secondary;
  final Widget icon;
  final VoidCallback onTap;
  /// When true the card is dimmed (45% opacity) and a gold "Coming Soon"
  /// diagonal ribbon is overlaid in the upper-right corner. Tap is
  /// effectively swallowed.
  final bool comingSoon;

  const _PayCard({
    required this.entryCtl,
    required this.staggerDelay,
    required this.id,
    required this.selected,
    required this.iconBg,
    this.iconBorder,
    required this.label,
    this.secondary,
    required this.icon,
    required this.onTap,
    // ignore: unused_element_parameter
    this.comingSoon = false,
  });

  @override
  State<_PayCard> createState() => _PayCardState();
}

class _PayCardState extends State<_PayCard> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final anim = CurvedAnimation(
      parent: widget.entryCtl,
      curve: Interval(
        widget.staggerDelay,
        (widget.staggerDelay + 0.55).clamp(0.0, 1.0),
        curve: Curves.easeOutCubic,
      ),
    );

    return AnimatedBuilder(
      animation: anim,
      builder: (_, child) {
        final t = anim.value;
        return Opacity(
          opacity: t,
          child: Transform.translate(
            offset: Offset(0, 12 * (1 - t)),
            child: child,
          ),
        );
      },
      child: ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: Stack(
          children: [
            Opacity(
              opacity: widget.comingSoon ? 0.55 : 1.0,
              child: _buildCardBody(),
            ),
            if (widget.comingSoon)
              Positioned(
                top: 14,
                right: -28,
                child: Transform.rotate(
                  angle: 0.45,
                  child: Container(
                    width: 110,
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    color: const Color(0xFFE8C547),
                    child: const Text(
                      'COMING SOON',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontFamily: 'Poppins',
                        color: Colors.black,
                        fontSize: 9,
                        fontWeight: FontWeight.w900,
                        letterSpacing: 0.6,
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

  Widget _buildCardBody() {
    return GestureDetector(
        onTap: widget.comingSoon ? null : widget.onTap,
        onTapDown: (_) => setState(() => _pressed = true),
        onTapCancel: () => setState(() => _pressed = false),
        onTapUp: (_) => setState(() => _pressed = false),
        behavior: HitTestBehavior.opaque,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 140),
          // Neumorphic tile; selected gets the thin gold border (same
          // treatment as the fleet cards), press sinks the surface.
          decoration: widget.selected
              ? neuBox(radius: 20).copyWith(
                  border: Border.all(
                    color: _gold.withValues(alpha: 0.45),
                    width: 1,
                  ),
                )
              : neuBox(radius: 20, pressed: _pressed),
          child: Stack(
            children: [
              // Check en esquina superior derecha
              Positioned(
                top: 12,
                right: 12,
                child: _Check(selected: widget.selected),
              ),
              // Contenido centrado
              Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // Icon inside a pressed neumorphic well
                    Container(
                      width: 56,
                      height: 56,
                      decoration: neuBox(radius: 12, pressed: true),
                      alignment: Alignment.center,
                      child: widget.icon,
                    ),
                    const SizedBox(height: 16),
                    // Label
                    Text(
                      widget.label,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        fontFamily: 'Poppins',
                        color: Colors.white,
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    // Sub-label (opcional)
                    if (widget.secondary != null) ...[
                      const SizedBox(height: 4),
                      Text(
                        widget.secondary!,
                        style: TextStyle(
                          fontFamily: 'Poppins',
                          color: _gold.withValues(alpha: 0.70),
                          fontSize: 11,
                          fontWeight: FontWeight.w500,
                        ),
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
}

class _Check extends StatelessWidget {
  final bool selected;
  const _Check({required this.selected});

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      width: 22,
      height: 22,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: selected ? _gold : Colors.transparent,
        border: Border.all(
          color: selected
              ? _gold
              // rgba(255,255,255,.15)
              : Colors.white.withValues(alpha: 0.15),
          width: 1.5,
        ),
      ),
      alignment: Alignment.center,
      child: selected
          ? const Icon(Icons.check_rounded, color: Colors.black, size: 14)
          : const SizedBox.shrink(),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════
//  Google "G" — 4-color SVG logo, 1:1 with web (ride-request.liquid:201).
//  Uses a CustomPainter with the four official Google brand color paths
//  so the logo renders identically to the marketing asset.
// ═══════════════════════════════════════════════════════════════════

class _GoogleGLogo extends StatelessWidget {
  final double size;

  const _GoogleGLogo({this.size = 20});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(painter: _GoogleGPainter()),
    );
  }
}

// SVG source (web): viewBox 0 0 24 24 — 4 brand-color paths.
class _GoogleGPainter extends CustomPainter {
  static final _blue   = Paint()..color = const Color(0xFF4285F4)..style = PaintingStyle.fill;
  static final _green  = Paint()..color = const Color(0xFF34A853)..style = PaintingStyle.fill;
  static final _yellow = Paint()..color = const Color(0xFFFBBC05)..style = PaintingStyle.fill;
  static final _red    = Paint()..color = const Color(0xFFEA4335)..style = PaintingStyle.fill;

  @override
  void paint(Canvas canvas, Size size) {
    // Scale 24-unit viewBox to the actual size.
    final s = size.width / 24.0;
    canvas.scale(s, s);

    // Blue arc (top-right)
    final blue = Path()
      ..moveTo(22.56, 12.25)
      ..cubicTo(22.56, 11.47, 22.49, 10.72, 22.36, 10.0)
      ..lineTo(12, 10.0)
      ..lineTo(12, 14.26)
      ..lineTo(17.92, 14.26)
      ..cubicTo(17.66, 15.63, 16.88, 16.79, 15.72, 17.58)
      ..lineTo(15.72, 20.35)
      ..lineTo(19.29, 20.35)
      ..cubicTo(21.37, 18.43, 22.56, 15.61, 22.56, 12.25)
      ..close();
    canvas.drawPath(blue, _blue);

    // Green arc (bottom-right)
    final green = Path()
      ..moveTo(12, 23)
      ..cubicTo(14.97, 23, 17.46, 22.02, 19.28, 20.34)
      ..lineTo(15.71, 17.57)
      ..cubicTo(14.73, 18.23, 13.48, 18.63, 12, 18.63)
      ..cubicTo(9.14, 18.63, 6.71, 16.70, 5.84, 14.10)
      ..lineTo(2.18, 14.10)
      ..lineTo(2.18, 16.94)
      ..cubicTo(3.99, 20.53, 7.70, 23, 12, 23)
      ..close();
    canvas.drawPath(green, _green);

    // Yellow arc (left)
    final yellow = Path()
      ..moveTo(5.84, 14.09)
      ..cubicTo(5.62, 13.43, 5.50, 12.73, 5.50, 12.0)
      ..cubicTo(5.50, 11.28, 5.62, 10.58, 5.84, 9.91)
      ..lineTo(5.84, 7.07)
      ..lineTo(2.18, 7.07)
      ..cubicTo(1.43, 8.55, 1.0, 10.22, 1.0, 12.0)
      ..cubicTo(1.0, 13.94, 1.46, 15.77, 2.18, 17.42)
      ..lineTo(5.84, 14.58)
      ..lineTo(5.84, 14.09)
      ..close();
    canvas.drawPath(yellow, _yellow);

    // Red arc (top-left)
    final red = Path()
      ..moveTo(12, 5.38)
      ..cubicTo(13.62, 5.38, 15.06, 5.94, 16.21, 7.02)
      ..lineTo(19.36, 3.87)
      ..cubicTo(17.45, 2.09, 14.97, 1.0, 12, 1.0)
      ..cubicTo(7.70, 1.0, 3.99, 3.47, 2.18, 7.07)
      ..lineTo(5.84, 9.91)
      ..cubicTo(6.71, 7.31, 9.14, 5.38, 12, 5.38)
      ..close();
    canvas.drawPath(red, _red);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

// ─── Card brand badge — Visa / Mastercard / Amex / Discover ───
// Compact brand chip shown inside the payment card tile when the rider has
// a saved debit/credit card. Falls back to a generic card icon for unknown
// brands.
class _CardBrandBadge extends StatelessWidget {
  final String? brand;

  const _CardBrandBadge({required this.brand});

  @override
  Widget build(BuildContext context) {
    switch ((brand ?? '').toLowerCase()) {
      case 'visa':
        return const _BrandText(
          'VISA',
          color: Color(0xFF1A56DB),
          italic: true,
        );
      case 'mastercard':
        return SizedBox(
          width: 34,
          height: 22,
          child: Stack(
            children: [
              Positioned(
                left: 0,
                child: _Circle(const Color(0xFFEB001B)),
              ),
              Positioned(
                right: 0,
                child: _Circle(const Color(0xFFF79E1B)),
              ),
            ],
          ),
        );
      case 'amex':
      case 'american_express':
      case 'american express':
        return const _BrandText('AMEX', color: Color(0xFF2E77BC));
      case 'discover':
        return const _BrandText('DISC', color: Color(0xFFFF6000));
      default:
        return const Icon(
          Icons.credit_card_rounded,
          color: Colors.white,
          size: 28,
        );
    }
  }
}

class _BrandText extends StatelessWidget {
  final String text;
  final Color color;
  final bool italic;

  const _BrandText(this.text, {required this.color, this.italic = false});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        text,
        style: TextStyle(
          color: color,
          fontSize: 12,
          fontWeight: FontWeight.w900,
          fontStyle: italic ? FontStyle.italic : FontStyle.normal,
          letterSpacing: 0.5,
        ),
      ),
    );
  }
}

class _Circle extends StatelessWidget {
  final Color color;

  const _Circle(this.color);

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 20,
      height: 20,
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.9),
        shape: BoxShape.circle,
      ),
    );
  }
}
