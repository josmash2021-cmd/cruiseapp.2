import 'dart:async';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_stripe/flutter_stripe.dart';

import '../l10n/app_localizations.dart';
import '../services/api_service.dart';
import '../services/haptic_service.dart';
import '../services/local_data_service.dart';
import '../utils/app_platform.dart';
import '../widgets/neu_style.dart';
import 'card_scan_screen.dart';
import 'ride_payment_method_screen.dart' show PaymentMethodId;

// ═══════════════════════════════════════════════════════════════════
//  Payment bottom sheet — Uber-style picker (user spec 2026-08-04).
//
//  Slides up over the ride-request screen instead of pushing a full
//  screen. Layout mirrors Uber's "Pay with" sheet minus the title:
//  Cruise Balance (toggle) → "More options" list with a check on the
//  selected row → Save. Save persists the choice as the default and
//  the sheet glides back down. "Add debit/credit card" swaps to an
//  in-sheet form (no new route), and any number of cards can be added
//  — the backend keeps them all in rider_payment_methods.
// ═══════════════════════════════════════════════════════════════════

const _gold = Color(0xFFE8C547);

/// Opens the sheet and resolves with the selected method id
/// (PaymentMethodId.*), or null if dismissed.
Future<String?> showCruisePaymentSheet(
  BuildContext context, {
  required String currentMethod,
  bool showTestMode = false,
}) {
  // The default modal sheet arrives in 250 ms — too abrupt for this
  // spec ("fluido sedoso, no de golpe"). A longer controller makes the
  // route's decelerate curve glide instead. NavigatorState is a
  // TickerProvider, so no widget vsync is needed here.
  final ctl = AnimationController(
    vsync: Navigator.of(context),
    duration: const Duration(milliseconds: 560),
    reverseDuration: const Duration(milliseconds: 420),
  );
  return showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    barrierColor: Colors.black.withValues(alpha: 0.55),
    transitionAnimationController: ctl,
    builder: (_) => _CruisePaymentSheet(
      currentMethod: currentMethod,
      showTestMode: showTestMode,
    ),
  ).whenComplete(() {
    // The exit slide may still be running when the future completes —
    // give it time before releasing the controller.
    Future.delayed(const Duration(milliseconds: 600), ctl.dispose);
  });
}

class _SheetCard {
  final int? dbId; // rider_payment_methods.id (null = local-only)
  final String? pmId; // Stripe pm_... (null = pending sync)
  final String brand;
  final String last4;
  const _SheetCard({this.dbId, this.pmId, required this.brand, required this.last4});
}

class _CruisePaymentSheet extends StatefulWidget {
  final String currentMethod;
  final bool showTestMode;
  const _CruisePaymentSheet({
    required this.currentMethod,
    this.showTestMode = false,
  });

  @override
  State<_CruisePaymentSheet> createState() => _CruisePaymentSheetState();
}

class _CruisePaymentSheetState extends State<_CruisePaymentSheet> {
  // 0 = method list, 1 = in-sheet add-card form.
  int _page = 0;

  String _selected = '';
  int _selCardIndex = 0;

  final List<_SheetCard> _cards = [];
  int _cashCents = 0;
  bool _saving = false;

  // Add-card form state (mirrors CreditCardScreen's essentials).
  final _nameCtrl = TextEditingController();
  final _zipCtrl = TextEditingController();
  CardFieldInputDetails? _cardDetails;
  bool _cardComplete = false;
  bool _addingCard = false;

  /// Set when the rider came through the card scanner — the in-sheet
  /// CardField is seeded with the OCR'd number + expiry so only CVV and
  /// ZIP are left to type (scan-first add card, 2026-08-24).
  CardEditController? _cardCtl;

  @override
  void initState() {
    super.initState();
    _selected = widget.currentMethod == 'credit_card'
        ? PaymentMethodId.card
        : widget.currentMethod;
    _nameCtrl.addListener(() => setState(() {}));
    _zipCtrl.addListener(() => setState(() {}));
    _loadEverything();
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _zipCtrl.dispose();
    _cardCtl?.dispose();
    super.dispose();
  }

  Future<void> _loadEverything() async {
    // Local single-card cache first so the row is instant, then the
    // backend list replaces it (all cards, default first).
    final localLast4 = await LocalDataService.getCreditCardLast4();
    final localBrand = await LocalDataService.getCreditCardBrand();
    final localPmId = await LocalDataService.getStripePaymentMethodId();
    if (mounted && localLast4 != null && _cards.isEmpty) {
      setState(() => _cards.add(_SheetCard(
          pmId: localPmId, brand: localBrand ?? 'card', last4: localLast4)));
    }

    unawaited(ApiService.getMyPaymentMethods().then((methods) {
      if (!mounted) return;
      final rows = methods
          .where((m) => m['method_type'] == 'stripe_card')
          .map((m) {
            final name = (m['display_name'] as String?) ?? '';
            final match = RegExp(r'(\d{4})$').firstMatch(name);
            if (match == null) return null;
            return _SheetCard(
              dbId: (m['id'] as num?)?.toInt(),
              pmId: m['stripe_pm_id'] as String?,
              brand: name.split(' ').first.toLowerCase(),
              last4: match.group(1)!,
            );
          })
          .whereType<_SheetCard>()
          .toList();
      if (rows.isNotEmpty) {
        setState(() {
          _cards
            ..clear()
            ..addAll(rows);
          _selCardIndex = _selCardIndex.clamp(0, _cards.length - 1);
        });
      }
    }).catchError((_) {}));

    unawaited(ApiService.getMyReferralInfo().then((res) {
      if (!mounted) return;
      setState(() =>
          _cashCents = (res['balance_cents'] as num?)?.toInt() ?? 0);
    }).catchError((_) {}));
  }

  // ── Save: persist default + glide the sheet back down ──

  Future<void> _save() async {
    if (_saving || _selected.isEmpty) return;
    setState(() => _saving = true);
    HapticService.mediumImpact();

    // Storage uses 'credit_card'; the picker contract returns 'card'.
    final storageId =
        _selected == PaymentMethodId.card ? 'credit_card' : _selected;
    await LocalDataService.setDefaultPaymentMethod(storageId);

    if (_selected == PaymentMethodId.card && _cards.isNotEmpty) {
      final card = _cards[_selCardIndex.clamp(0, _cards.length - 1)];
      await LocalDataService.saveCreditCardBrand(card.brand);
      await LocalDataService.saveCreditCardLast4(card.last4);
      await LocalDataService.linkPaymentMethod('credit_card');
      if (card.pmId != null) {
        await LocalDataService.saveStripePaymentMethodId(card.pmId!);
      }
      // Backend default drives which card chargeTrip (and tips, and
      // scheduled rides) picks up — awaited so the choice is durable
      // before the sheet closes, bounded so a slow network can't hold
      // the pop hostage.
      if (card.dbId != null) {
        try {
          await ApiService.setDefaultRiderPaymentMethod(card.dbId!)
              .timeout(const Duration(seconds: 5));
        } catch (_) {/* non-fatal: local pm id still drives the hold */}
      }
    }

    if (!mounted) return;
    Navigator.of(context).pop(_selected);
  }

  // ── Bank linking removed (2026-08-26): the rider no longer pays by
  // bank account — see _methodRows.

  /// Page 1 → page 0, dropping any scanned-card seed so the next add
  /// starts from an empty field unless the scanner runs again.
  void _backToList() {
    HapticService.selectionClick();
    setState(() {
      _cardCtl?.dispose();
      _cardCtl = null;
      _page = 0;
    });
  }

  /// Scan-first add card (2026-08-24): the camera scanner opens FIRST.
  /// A successful read comes back as a ScannedCard and the in-sheet form
  /// opens pre-seeded (CVV/ZIP still typed); 'manual' opens it empty.
  Future<void> _openAddCard() async {
    HapticService.selectionClick();
    // No OCR on web (ML Kit is native-only) — straight to the form.
    if (kIsWeb) {
      setState(() => _page = 1);
      return;
    }
    final res = await Navigator.of(context).push<Object?>(
      MaterialPageRoute(
          builder: (_) => const CardScanScreen(returnResult: true)),
    );
    if (!mounted) return;
    if (res is ScannedCard) {
      setState(() {
        _cardCtl?.dispose();
        _cardCtl = CardEditController(
          initialDetails: CardFieldInputDetails(
            complete: false,
            number: res.number,
            expiryMonth: res.expMonth,
            expiryYear: res.expYear,
          ),
        );
        _page = 1;
      });
    } else if (res == 'manual') {
      setState(() => _page = 1);
    }
    // null = closed without choosing — stay on the method list.
  }

  // ── In-sheet add card (multiple cards supported) ──

  bool get _canAddCard =>
      _cardComplete &&
      _nameCtrl.text.trim().isNotEmpty &&
      _zipCtrl.text.trim().isNotEmpty &&
      !_addingCard;

  Future<void> _submitCard() async {
    if (!_canAddCard) return;
    setState(() => _addingCard = true);
    final s = S.of(context);
    final brand = (_cardDetails?.brand ?? 'card').toLowerCase();
    final last4 = _cardDetails?.last4 ?? '????';
    try {
      final clientSecret = await ApiService.createSetupIntent()
          .timeout(const Duration(seconds: 15));
      if (!mounted) return;
      if (clientSecret == null) {
        _toast(s.genericPaymentError, error: true);
        return;
      }
      final si = await Stripe.instance.confirmSetupIntent(
        paymentIntentClientSecret: clientSecret,
        params: PaymentMethodParams.card(
          paymentMethodData: PaymentMethodData(
            billingDetails: BillingDetails(name: _nameCtrl.text.trim()),
          ),
        ),
      );
      if (!mounted) return;
      final pmId = si.paymentMethodId;
      // Not the default yet — Save is where that decision is made. The
      // response's method_id (rider_payment_methods.id) is kept so Save
      // CAN make it the backend default; without it the new card would
      // silently never become chargeable-by-default server-side.
      int? dbId;
      try {
        final res = await ApiService.syncPaymentMethodToBackend(
          stripePaymentMethodId: pmId,
          type: 'stripe_card',
          last4: last4,
          brand: brand,
          setDefault: false,
        ).timeout(const Duration(seconds: 15));
        dbId = (res['method_id'] as num?)?.toInt();
      } catch (_) {/* non-fatal: synced again on next ride */}
      await LocalDataService.linkPaymentMethod('credit_card');
      if (!mounted) return;
      setState(() {
        // Append locally — getMyPaymentMethods has a 30s response cache
        // and would not show the new card yet.
        _cards.add(
            _SheetCard(dbId: dbId, pmId: pmId, brand: brand, last4: last4));
        _selCardIndex = _cards.length - 1;
        _selected = PaymentMethodId.card;
        _cardDetails = null;
        _cardComplete = false;
        _cardCtl?.dispose();
        _cardCtl = null;
        _nameCtrl.clear();
        _zipCtrl.clear();
        _page = 0;
      });
      HapticService.selectionClick();
    } on StripeException catch (e) {
      if (!mounted) return;
      _toast(e.error.localizedMessage ?? s.genericPaymentError, error: true);
    } catch (_) {
      if (mounted) _toast(s.genericPaymentError, error: true);
    } finally {
      if (mounted) setState(() => _addingCard = false);
    }
  }

  void _toast(String msg, {bool error = false}) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg,
            style: const TextStyle(fontWeight: FontWeight.w600)),
        backgroundColor: error ? Colors.red.shade800 : null,
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  // ═════════════════════════════════════════════════════════════════
  //  Build
  // ═════════════════════════════════════════════════════════════════

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    return AnimatedPadding(
      // Rises with the keyboard on the add-card page.
      duration: const Duration(milliseconds: 260),
      curve: Curves.easeOutCubic,
      padding: EdgeInsets.only(bottom: mq.viewInsets.bottom),
      child: Container(
        constraints: BoxConstraints(maxHeight: mq.size.height * 0.88),
        decoration: BoxDecoration(
          color: neuBase,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
          border: Border(
            top: BorderSide(color: _gold.withValues(alpha: 0.18), width: 1),
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.6),
              blurRadius: 30,
              offset: const Offset(0, -10),
            ),
          ],
        ),
        // The two pages morph into each other: AnimatedSize glides the
        // sheet height while AnimatedSwitcher cross-fades the content —
        // nothing pops in ("no aparezca nada de golpe").
        child: AnimatedSize(
          duration: const Duration(milliseconds: 380),
          curve: Curves.easeInOutCubicEmphasized,
          alignment: Alignment.topCenter,
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 340),
            switchInCurve: Curves.easeOutCubic,
            switchOutCurve: Curves.easeInCubic,
            transitionBuilder: (child, anim) => FadeTransition(
              opacity: anim,
              child: SlideTransition(
                position: Tween<Offset>(
                  begin: const Offset(0, 0.035),
                  end: Offset.zero,
                ).animate(anim),
                child: child,
              ),
            ),
            child: SingleChildScrollView(
              key: ValueKey('page$_page'),
              padding: EdgeInsets.fromLTRB(
                  20, 10, 20, 16 + mq.viewPadding.bottom),
              // BOTH pages hold the same 72%-of-screen height (user spec
              // 2026-08-04: switching to add-card must not collapse the
              // sheet) — each page's flexible filler pushes its buttons
              // to the bottom edge.
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  minHeight: mq.size.height * 0.72 -
                      (26 + 16 + mq.viewPadding.bottom),
                ),
                child: IntrinsicHeight(
                  child:
                      _page == 0 ? _buildListPage() : _buildAddCardPage(),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  // ── Page 0: method list ──

  Widget _buildListPage() {
    final s = S.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _grabber(),
        const SizedBox(height: 10),
        // Just the close button — the corner "+ Add card" pill is gone
        // (user spec 2026-08-04); the Add Debit/Credit Card row below is
        // the one way into the card form.
        _roundButton(Icons.close_rounded, () => Navigator.of(context).pop()),
        const SizedBox(height: 18),

        // ── Cruise Balance ──
        Row(
          children: [
            Expanded(
              child: Text(
                s.cruiseBalance,
                style: const TextStyle(
                  fontFamily: 'Poppins',
                  color: Colors.white,
                  fontSize: 17,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
            // The toggle IS a payment-method choice (user spec
            // 2026-08-04): ON selects Cruise Cash and unmarks every row
            // below; picking any row flips it back off. Whether the
            // balance actually covers the fare is enforced at the
            // Request/Reserve button, not here.
            Switch(
              value: _selected == PaymentMethodId.cruiseCash,
              onChanged: (v) {
                HapticService.selectionClick();
                setState(() =>
                    _selected = v ? PaymentMethodId.cruiseCash : '');
                unawaited(LocalDataService.setUseCruiseCash(v));
              },
              activeThumbColor: Colors.black,
              activeTrackColor: _gold,
              inactiveThumbColor: Colors.white.withValues(alpha: 0.85),
              inactiveTrackColor: Colors.white.withValues(alpha: 0.15),
            ),
          ],
        ),
        const SizedBox(height: 6),
        Row(
          children: [
            Image.asset('assets/images/cruise_logo.png',
                width: 32, height: 32),
            const SizedBox(width: 12),
            Text(
              '${s.cruiseCash}: \$${(_cashCents / 100.0).toStringAsFixed(2)}',
              style: TextStyle(
                fontFamily: 'Poppins',
                color: Colors.white.withValues(
                    alpha: _selected == PaymentMethodId.cruiseCash
                        ? 0.95
                        : 0.4),
                fontSize: 14.5,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
        const SizedBox(height: 22),

        // ── More options ──
        Text(
          s.moreOptions,
          style: TextStyle(
            fontFamily: 'Poppins',
            color: Colors.white.withValues(alpha: 0.55),
            fontSize: 12.5,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.4,
          ),
        ),
        const SizedBox(height: 4),
        ..._methodRows(s),
        const SizedBox(height: 18),
        // Filler so Save rides the sheet's bottom edge — the sheet is
        // min-height'd taller than its content.
        const Expanded(child: SizedBox.shrink()),

        // ── Save ──
        GestureDetector(
          onTap: _selected.isEmpty ? null : _save,
          child: AnimatedOpacity(
            duration: const Duration(milliseconds: 200),
            opacity: _selected.isEmpty ? 0.35 : (_saving ? 0.6 : 1.0),
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
                s.save,
                style: const TextStyle(
                  fontFamily: 'Poppins',
                  color: Color(0xFF1A1400),
                  fontSize: 15,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  List<Widget> _methodRows(S s) {
    final rows = <Widget>[];

    // Platform pay — Apple ONLY on iOS (user spec 2026-08-04: never on
    // Android, and not in the web preview either), Google on Android.
    if (AppPlatform.isIOS) {
      rows.add(_methodRow(
        selected: _selected == PaymentMethodId.apple,
        leading: _logoTile(
          Colors.black,
          const Icon(Icons.apple, color: Colors.white, size: 19),
        ),
        label: 'Apple Pay',
        onTap: () => _pick(PaymentMethodId.apple),
      ));
    }
    if (AppPlatform.isAndroid) {
      rows.add(_methodRow(
        selected: _selected == PaymentMethodId.google,
        leading: _logoTile(
          Colors.white,
          const Text('G',
              style: TextStyle(
                  color: Color(0xFF4285F4),
                  fontSize: 15,
                  fontWeight: FontWeight.w800)),
        ),
        label: 'Google Pay',
        onTap: () => _pick(PaymentMethodId.google),
      ));
    }

    // Every saved card — any number of them.
    for (var i = 0; i < _cards.length; i++) {
      final card = _cards[i];
      rows.add(_methodRow(
        selected: _selected == PaymentMethodId.card && _selCardIndex == i,
        leading: _brandTile(card.brand),
        label:
            '${card.brand[0].toUpperCase()}${card.brand.substring(1)} •••• ${card.last4}',
        onTap: () => setState(() {
          _selCardIndex = i;
          _pick(PaymentMethodId.card);
        }),
      ));
    }

    // Bank Account removed for riders (user spec 2026-08-26): ACH never
    // supported holds anyway, so the option only led to a broken payment
    // path. Cards, wallets and Cruise Cash are the rider's methods now.

    // Add card row — scan-first (camera), then this in-sheet form.
    rows.add(_methodRow(
      selected: false,
      leading: _logoTile(
        Colors.white.withValues(alpha: 0.07),
        const Icon(Icons.add_card_rounded, color: Colors.white, size: 17),
      ),
      label: s.addDebitCreditCard,
      trailingChevron: true,
      onTap: _openAddCard,
    ));

    if (widget.showTestMode) {
      rows.add(_methodRow(
        selected: _selected == PaymentMethodId.test,
        leading: _logoTile(
          const Color(0xFF1A1A1A),
          const Icon(Icons.tune_rounded, color: _gold, size: 17),
        ),
        label: s.testModeLabel,
        onTap: () => _pick(PaymentMethodId.test),
      ));
    }

    // Hairline dividers between rows, indented past the logo tile.
    final out = <Widget>[];
    for (var i = 0; i < rows.length; i++) {
      out.add(rows[i]);
      if (i != rows.length - 1) {
        out.add(Padding(
          padding: const EdgeInsets.only(left: 54),
          child: Container(
              height: 1, color: Colors.white.withValues(alpha: 0.05)),
        ));
      }
    }
    return out;
  }

  void _pick(String id) {
    HapticService.selectionClick();
    setState(() => _selected = id);
  }

  Widget _methodRow({
    required bool selected,
    required Widget leading,
    required String label,
    required VoidCallback? onTap,
    bool trailingChevron = false,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: SizedBox(
        height: 56,
        child: Row(
          children: [
            leading,
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
            if (trailingChevron)
              Icon(Icons.chevron_right_rounded,
                  color: Colors.white.withValues(alpha: 0.4), size: 22)
            else
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 220),
                switchInCurve: Curves.easeOutBack,
                transitionBuilder: (child, anim) =>
                    ScaleTransition(scale: anim, child: child),
                child: selected
                    ? Container(
                        key: const ValueKey('on'),
                        width: 24,
                        height: 24,
                        decoration: const BoxDecoration(
                            color: _gold, shape: BoxShape.circle),
                        child: const Icon(Icons.check_rounded,
                            color: Colors.black, size: 16),
                      )
                    : Container(
                        key: const ValueKey('off'),
                        width: 24,
                        height: 24,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          border: Border.all(
                              color: Colors.white.withValues(alpha: 0.25),
                              width: 1.5),
                        ),
                      ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _logoTile(Color bg, Widget child) {
    return Container(
      width: 40,
      height: 28,
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
      ),
      alignment: Alignment.center,
      child: child,
    );
  }

  Widget _brandTile(String brand) {
    final b = brand.toLowerCase();
    if (b.contains('visa')) {
      return _logoTile(
        const Color(0xFF1A1F71),
        const Text('VISA',
            style: TextStyle(
                color: Colors.white,
                fontSize: 9,
                fontWeight: FontWeight.w800,
                letterSpacing: 0.5)),
      );
    }
    if (b.contains('master')) {
      return _logoTile(
        const Color(0xFF16161C),
        SizedBox(
          width: 22,
          height: 13,
          child: Stack(
            children: [
              Positioned(
                left: 0,
                child: Container(
                    width: 13,
                    height: 13,
                    decoration: const BoxDecoration(
                        color: Color(0xFFEB001B), shape: BoxShape.circle)),
              ),
              Positioned(
                right: 0,
                child: Container(
                    width: 13,
                    height: 13,
                    decoration: BoxDecoration(
                        color: const Color(0xFFF79E1B)
                            .withValues(alpha: 0.9),
                        shape: BoxShape.circle)),
              ),
            ],
          ),
        ),
      );
    }
    return _logoTile(
      const Color(0xFF2A2A2A),
      const Icon(Icons.credit_card_rounded, color: Colors.white, size: 16),
    );
  }

  // ── Page 1: in-sheet add card ──

  Widget _buildAddCardPage() {
    final s = S.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _grabber(),
        const SizedBox(height: 10),
        Row(
          children: [
            _roundButton(Icons.arrow_back_rounded, _backToList),
            const SizedBox(width: 14),
            Expanded(
              child: Text(
                s.addYourCard,
                style: const TextStyle(
                  fontFamily: 'Poppins',
                  color: Colors.white,
                  fontSize: 18,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        Padding(
          padding: const EdgeInsets.only(left: 52),
          child: Text(
            s.enterCardDetails,
            style: TextStyle(
                fontSize: 13,
                color: Colors.white.withValues(alpha: 0.55)),
          ),
        ),
        const SizedBox(height: 20),

        // Card number — Stripe's secure field on native; the web build
        // can't tokenize (flutter_stripe has no web implementation).
        Container(
          decoration: neuBox(radius: 16, pressed: true),
          padding:
              const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          child: kIsWeb
              ? Padding(
                  padding: const EdgeInsets.symmetric(
                      vertical: 14, horizontal: 4),
                  child: Row(
                    children: [
                      Icon(Icons.credit_card_rounded,
                          color: Colors.white.withValues(alpha: 0.4),
                          size: 20),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          s.cardEntryMobileOnly,
                          style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.5),
                            fontSize: 13,
                            height: 1.35,
                          ),
                        ),
                      ),
                    ],
                  ),
                )
              : CardField(
                  controller: _cardCtl,
                  enablePostalCode: false,
                  style:
                      const TextStyle(color: Colors.white, fontSize: 16),
                  decoration: InputDecoration(
                    border: InputBorder.none,
                    hintStyle: TextStyle(
                      color: Colors.white.withValues(alpha: 0.35),
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
        const SizedBox(height: 12),
        _formField(_nameCtrl, s.nameOnCard, Icons.person_outline_rounded),
        const SizedBox(height: 12),
        _formField(_zipCtrl, s.zipPostalCode, Icons.place_outlined,
            keyboard: TextInputType.number),
        const SizedBox(height: 20),
        // Filler so Add card + Cancel ride the bottom edge and the sheet
        // keeps the list page's height instead of collapsing.
        const Expanded(child: SizedBox.shrink()),

        GestureDetector(
          onTap: _canAddCard ? _submitCard : null,
          child: AnimatedOpacity(
            duration: const Duration(milliseconds: 200),
            opacity: _canAddCard ? 1.0 : 0.35,
            child: Container(
              height: 52,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: _gold,
                borderRadius: BorderRadius.circular(16),
              ),
              child: _addingCard
                  ? const SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(
                          strokeWidth: 2.4, color: Color(0xFF1A1400)),
                    )
                  : Text(
                      s.addCard,
                      style: const TextStyle(
                        fontFamily: 'Poppins',
                        color: Color(0xFF1A1400),
                        fontSize: 15,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
            ),
          ),
        ),
        const SizedBox(height: 8),
        Center(
          child: TextButton(
            onPressed: _backToList,
            child: Text(
              s.cancel,
              style: TextStyle(
                fontFamily: 'Poppins',
                color: Colors.white.withValues(alpha: 0.6),
                fontSize: 14,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _formField(TextEditingController ctrl, String hint, IconData icon,
      {TextInputType? keyboard}) {
    return Container(
      decoration: neuBox(radius: 16, pressed: true),
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: TextField(
        controller: ctrl,
        keyboardType: keyboard,
        style: const TextStyle(color: Colors.white, fontSize: 15),
        decoration: InputDecoration(
          border: InputBorder.none,
          icon: Icon(icon,
              color: Colors.white.withValues(alpha: 0.4), size: 20),
          hintText: hint,
          hintStyle:
              TextStyle(color: Colors.white.withValues(alpha: 0.35)),
        ),
      ),
    );
  }

  // ── Shared bits ──

  Widget _grabber() => Center(
        child: Container(
          width: 38,
          height: 4,
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.18),
            borderRadius: BorderRadius.circular(2),
          ),
        ),
      );

  Widget _roundButton(IconData icon, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 38,
        height: 38,
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.07),
          shape: BoxShape.circle,
          border:
              Border.all(color: Colors.white.withValues(alpha: 0.10)),
        ),
        child: Icon(icon, color: Colors.white, size: 20),
      ),
    );
  }
}
