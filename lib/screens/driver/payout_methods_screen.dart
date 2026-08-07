import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_stripe/flutter_stripe.dart' as stripe;
import 'package:shared_preferences/shared_preferences.dart';

import '../../l10n/app_localizations.dart';

import 'add_bank_account_screen.dart';
import 'stripe_onboarding_screen.dart';

import '../../services/api_service.dart';
import '../../services/haptic_service.dart';
import '../../services/user_session.dart';
import '../../widgets/neu_style.dart';

/// Payout Methods screen — Stripe Connect-powered, real end-to-end.
///
/// Two destinations the driver can attach to their Connect account:
///
///   1. **Connect bank account** — opens the Stripe Financial Connections
///      sheet via the native SDK (`collectBankAccountToken`) using the
///      `client_secret` minted by `POST /drivers/financial-connections`.
///      Stripe returns a `btok_...`; the backend attaches it as an
///      external_account, which is where the weekly Tuesday ACH payout
///      lands. Account and routing numbers never reach our servers.
///
///   2. **Add debit card** — a `CardField` sheet tokenizes the PAN
///      client-side (`createToken` with `currency: usd`, which is what
///      marks the token as usable for payouts). We send only the
///      `tok_...`, which the backend attaches as an external_account for
///      **instant cashouts**. The raw PAN never reaches our servers.
///
/// Both flows are native-only — `flutter_stripe` has no web implementation,
/// so on web the buttons explain that instead of throwing.
///
/// Defaults: the backend atomically clears other defaults whenever a row is
/// promoted, so the cashout flow always sees exactly one default row.
class PayoutMethodsScreen extends StatefulWidget {
  const PayoutMethodsScreen({super.key});

  @override
  State<PayoutMethodsScreen> createState() => _PayoutMethodsScreenState();
}

/// The gold of the payout sub-flow, declared once for the whole file.
///
/// 0xFFE8C547, not the 0xFFD4A843 this file used to carry: everything the
/// screen pushes or is pushed from — AddBankAccountScreen,
/// StripeOnboardingScreen, the cash-out page and its success screen — is on
/// E8C547, so the old value changed gold one tap into the flow. (Much of the
/// rest of the driver app is still on D4A843; this unifies the payout flow,
/// not the app.)
///
/// Top-level rather than three `static const _gold`s in three private
/// classes, which is exactly how the screen and its own two sheets drifted
/// apart in the first place.
const _gold = Color(0xFFE8C547);

class _PayoutMethodsScreenState extends State<PayoutMethodsScreen> {
  static const _green = Color(0xFF4CAF50);
  static const _danger = Color(0xFFFF5252);
  static const _text = Colors.white;

  // Mirrors of the backend constants (INSTANT_FEE_RATE / INSTANT_FEE_MIN /
  // INSTANT_MIN_AMOUNT in backend/routers/drivers.py) so the card can state
  // the terms without a round-trip. The backend re-validates every one of
  // them at cashout time — these are for reading, not for deciding.
  static const _instantFeeLabel = '1.5%';
  static const _instantFeeMinLabel = '\$0.50';
  static const _instantMinAmountLabel = '\$50';

  List<Map<String, dynamic>> _methods = [];
  bool _loading = true;
  bool _busy = false; // any Stripe/back-end call in flight
  String? _loadError;

  /// The last answer the server gave, kept on the device.
  ///
  /// What is attached to a payout destination changes when the driver
  /// changes it and at no other time — there is no reason to make them
  /// watch it be fetched every time they open the screen. Keyed by driver
  /// so two people on one phone never see each other's accounts.
  static const _kCacheKey = 'driver_payout_methods_cache';

  @override
  void initState() {
    super.initState();
    _loadCached();
    _loadMethods();
  }

  Future<String?> _driverKey() async =>
      (await UserSession.getUser())?['userId']?.toString();

  Future<void> _loadCached() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_kCacheKey);
      if (raw == null || !mounted) return;
      final card = jsonDecode(raw) as Map<String, dynamic>;
      if (card['id']?.toString() != await _driverKey()) return;
      final list = (card['methods'] as List?)
          ?.whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();
      // Only if the network has not already answered — a fresh list must
      // never be overwritten by a stale one that lost the race.
      if (list == null || !mounted || !_loading) return;
      setState(() {
        _methods = list;
        _loading = false;
      });
    } catch (e) {
      debugPrint('[PayoutMethods] cached list unavailable: $e');
    }
  }

  Future<void> _cacheMethods() async {
    try {
      final id = await _driverKey();
      if (id == null || id.isEmpty) return;
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _kCacheKey,
        jsonEncode(<String, dynamic>{'id': id, 'methods': _methods}),
      );
    } catch (e) {
      debugPrint('[PayoutMethods] could not cache the list: $e');
    }
  }

  Future<void> _loadMethods() async {
    List<Map<String, dynamic>>? loaded;
    bool failed = false;
    try {
      loaded = await ApiService.getPayoutMethods();
    } catch (e) {
      debugPrint('[PayoutMethods] _loadMethods error: $e');
      failed = true;
    }
    if (!mounted) return;
    // The error string is resolved AFTER the await on purpose: _loadMethods
    // is called from initState, and S.of() does an inherited-widget lookup,
    // which throws if it runs before initState has completed.
    setState(() {
      if (loaded != null) _methods = loaded;
      _loading = false;
      _loadError = failed ? S.of(context).couldNotLoadPaymentMethods : null;
    });
    if (loaded != null) unawaited(_cacheMethods());
  }

  /// Strip the hidden ``[ext:xxx]`` Stripe-id suffix from a display name
  /// so the UI shows just "Visa ····1234".
  String _cleanDisplay(String raw) {
    final idx = raw.indexOf('[ext:');
    if (idx < 0) return raw;
    return raw.substring(0, idx).trim();
  }

  void _snack(String msg, {bool error = false}) {
    if (!mounted) return;
    // maybeOf, not of: every caller reaches here after an await, and per
    // project rule 26 `mounted` does not cover the window where the element
    // is deactivated but not yet disposed — `.of` resolves to a null-check
    // crash there, and only in release.
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (messenger == null) return;
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          msg,
          style: TextStyle(
            color: error ? Colors.white : Colors.black,
            fontWeight: FontWeight.w600,
          ),
        ),
        backgroundColor: error ? _danger : _gold,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    );
  }

  // ═══════════════════════════════════════════════════
  //  BUILD
  // ═══════════════════════════════════════════════════
  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    return Scaffold(
      backgroundColor: neuBase,
      // The same speckled ground the driver menu that links here carries,
      // so arriving does not read as landing in a different app.
      body: Stack(
        children: [
          const Positioned.fill(child: NeuDotsBackdrop()),
          SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ── Header ──
            //
            // Back, the page's name, and a way to ask what any of this
            // means. The intro paragraph that used to sit under a large
            // left-aligned title is gone: it explained the payday and the
            // fee in prose, and both now live on the card they belong to,
            // where a driver comparing the two can read them side by side.
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 6, 16, 16),
              child: Row(
                children: [
                  _headerButton(
                    Icons.arrow_back_rounded,
                    () => Navigator.pop(context),
                  ),
                  Expanded(
                    child: Text(
                      s.payoutMethodsTitle,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        color: _text,
                        fontSize: 18,
                        fontWeight: FontWeight.w800,
                        letterSpacing: -0.3,
                      ),
                    ),
                  ),
                  _headerButton(Icons.help_outline_rounded, _showHelpSheet),
                ],
              ),
            ),

            // The page does not wait on the network to exist.
            //
            // It used to hand the whole body to a spinner until the request
            // came back, and with the retry that request can take most of a
            // minute on a bad signal — a driver staring at a turning circle
            // under a title, with nothing to read and nothing to press.
            //
            // Both rows are structural: Express Pay and Weekly payouts are
            // there whatever the server says. Only what is *attached* to
            // them is unknown, so only that waits — see the row's own
            // pending state.
            Expanded(
              child: RefreshIndicator(
                          color: _gold,
                          backgroundColor: neuSurface,
                          onRefresh: _loadMethods,
                          child: ListView(
                            physics: const AlwaysScrollableScrollPhysics(
                              parent: BouncingScrollPhysics(),
                            ),
                            padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
                            children: [
                              if (_loadError != null) ...[
                                _errorStrip(_loadError!),
                                const SizedBox(height: 14),
                              ],
                              _sectionLabel(s.payoutAvailableSection),
                              // Two ways to be paid, always both shown, each
                              // answering the same three questions in the same
                              // order: what it costs, when it lands, where it
                              // goes. A driver deciding between them is
                              // comparing exactly those three things, and the
                              // old two-line rows made them guess at two of
                              // the three.
                              //
                              // Weekly first because it is what happens on its
                              // own — the backend sweeps every balance to the
                              // bank each Monday whether or not the driver ever
                              // opens this screen. Instant is the thing you go
                              // out of your way to do.
                              _payoutOptionCard(
                                icon: Icons.calendar_month_rounded,
                                title: s.payoutWeekly,
                                fee: s.payoutFeeFree,
                                cadence: s.payoutWhenWeekly,
                                destinationIcon: Icons.account_balance_rounded,
                                destinationEmpty: s.payoutNoBankLinked,
                                method: _methodOfType('bank_account'),
                                addLabel: s.payoutAddBank,
                                changeLabel: s.payoutChangeBank,
                                onTap: _connectBankAccount,
                              ),
                              const SizedBox(height: 14),
                              _payoutOptionCard(
                                icon: Icons.flash_on_rounded,
                                title: s.instantCashout,
                                fee: s.payoutFeePercent(
                                  _instantFeeLabel,
                                  _instantFeeMinLabel,
                                ),
                                cadence: s.payoutWhenInstant,
                                destinationIcon: Icons.credit_card_rounded,
                                destinationEmpty: s.payoutNoCardLinked,
                                method: _methodOfType('debit_card'),
                                addLabel: s.payoutAddCard,
                                changeLabel: s.payoutChangeCard,
                                footnote: s.payoutInstantMinimum(
                                  _instantMinAmountLabel,
                                ),
                                onTap: _connectDebitCard,
                              ),
                              // Anything the two rows are not already showing
                              // — a driver who linked a second card — still
                              // gets a card of its own, so nothing they
                              // attached is invisible.
                              ..._extraMethods().map(
                                (m) => Padding(
                                  padding: const EdgeInsets.only(top: 10),
                                  child: _buildMethodCard(m),
                                ),
                              ),
                            ],
                          ),
              ),
            ),
          ],
        ),
          ),
        ],
      ),
    );
  }

  /// The default destination of [type], or the first one, or null.
  Map<String, dynamic>? _methodOfType(String type) {
    final of = _methods.where((m) => m['method_type'] == type).toList();
    if (of.isEmpty) return null;
    return of.firstWhere(
      (m) => m['is_default'] == true,
      orElse: () => of.first,
    );
  }

  /// Everything the two rows above are not already showing.
  List<Map<String, dynamic>> _extraMethods() {
    final shown = <Object?>{
      _methodOfType('debit_card')?['id'],
      _methodOfType('bank_account')?['id'],
    }..remove(null);
    return _methods.where((m) => !shown.contains(m['id'])).toList();
  }

  /// A 40 pt round control for the header row.
  ///
  /// Two of them, one on each side, so the page title sits optically
  /// centred without measuring it.
  Widget _headerButton(IconData icon, VoidCallback onTap) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () {
        HapticService.selectionClick();
        onTap();
      },
      child: Container(
        width: 40,
        height: 40,
        alignment: Alignment.center,
        decoration: neuBox(radius: 14, pressed: true),
        child: Icon(icon, color: _text, size: 20),
      ),
    );
  }

  Widget _sectionLabel(String label) {
    return Padding(
      padding: const EdgeInsets.only(left: 4, bottom: 14),
      child: Text(
        label,
        style: const TextStyle(
          color: _text,
          fontSize: 22,
          fontWeight: FontWeight.w800,
          letterSpacing: -0.5,
        ),
      ),
    );
  }

  /// One way of being paid: what it costs, when it lands, and where it goes.
  ///
  /// The three lines are always in that order and always present, even when
  /// nothing is attached yet — a driver choosing between the two cards is
  /// comparing those three facts, and a card that omits one because it is
  /// not set up hides the very thing being compared. What changes with the
  /// linked state is the third line's value, the pill, and the button.
  Widget _payoutOptionCard({
    required IconData icon,
    required String title,
    required String fee,
    required String cadence,
    required IconData destinationIcon,
    required String destinationEmpty,
    required Map<String, dynamic>? method,
    required String addLabel,
    required String changeLabel,
    required VoidCallback onTap,
    String? footnote,
  }) {
    final s = S.of(context);
    // `linked` must never be reassigned. Flow analysis carries the null
    // check through the boolean only while it keeps its original SSA node;
    // any write to it — `if (_busy) linked = false;` looks harmless — drops
    // the stored promotion and the `m['display_name']` / `m['id']` reads
    // below stop compiling.
    final m = method;
    final linked = m != null;
    final display =
        linked ? _cleanDisplay((m['display_name'] ?? '').toString()) : '';
    return Opacity(
      // Dimmed only while a Stripe call is in flight, never while the list
      // is merely loading: the card's own content is structural and true
      // before the server answers.
      opacity: _busy ? 0.5 : 1,
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: neuBox(radius: 22),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 44,
                  height: 44,
                  alignment: Alignment.center,
                  decoration: neuBox(radius: 14, pressed: true),
                  child: Icon(
                    icon,
                    size: 21,
                    color: linked ? _gold : Colors.white.withValues(alpha: 0.45),
                  ),
                ),
                const SizedBox(width: 13),
                Expanded(
                  child: Text(
                    title,
                    style: const TextStyle(
                      color: _text,
                      fontSize: 17,
                      fontWeight: FontWeight.w800,
                      letterSpacing: -0.2,
                    ),
                  ),
                ),
                // The pill is the one thing that genuinely has to wait: until
                // the list arrives the card cannot honestly say either
                // "Active" or "Set up", so it says nothing rather than
                // putting a spinner where an answer will be.
                if (_busy)
                  const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                      color: _gold,
                      strokeWidth: 2,
                    ),
                  )
                else if (!_loading)
                  _statusPill(
                    linked ? s.payoutActive : s.payoutSetUp,
                    linked: linked,
                  ),
              ],
            ),
            const SizedBox(height: 16),
            _infoLine(Icons.payments_outlined, fee),
            const SizedBox(height: 10),
            _infoLine(Icons.event_rounded, cadence),
            const SizedBox(height: 10),
            _infoLine(
              destinationIcon,
              linked ? display : destinationEmpty,
              strong: linked,
              // The bin is the ONLY way to remove a bank or the express-pay
              // card — `_extraMethods` never lists either of them — so it
              // has to live on the line that names what would be removed.
              trailing: (linked && !_busy && !_loading)
                  ? _deleteButton(m['id'], display)
                  : null,
            ),
            if (footnote != null) ...[
              const SizedBox(height: 12),
              Text(
                footnote,
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.32),
                  fontSize: 11.5,
                  height: 1.3,
                ),
              ),
            ],
            const SizedBox(height: 16),
            // Deaf while a Stripe call is in flight. Two taps on "Add"
            // opens two sheets, and the second lands on a Connect account
            // the first is halfway through changing.
            _ctaPill(
              label: linked ? changeLabel : addLabel,
              primary: !linked,
              onTap: _busy ? null : onTap,
            ),
          ],
        ),
      ),
    );
  }

  /// One fact about a payout option, in a sunken well the eye can run down.
  Widget _infoLine(
    IconData icon,
    String text, {
    bool strong = false,
    Widget? trailing,
  }) {
    return Row(
      children: [
        Container(
          width: 26,
          height: 26,
          alignment: Alignment.center,
          decoration: neuBox(radius: 9, pressed: true),
          child: Icon(
            icon,
            size: 14,
            color: Colors.white.withValues(alpha: strong ? 0.55 : 0.38),
          ),
        ),
        const SizedBox(width: 11),
        Expanded(
          child: Text(
            text,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: Colors.white.withValues(alpha: strong ? 0.88 : 0.6),
              fontSize: 13.5,
              fontWeight: strong ? FontWeight.w600 : FontWeight.w400,
            ),
          ),
        ),
        if (trailing != null) ...[
          const SizedBox(width: 8),
          trailing,
        ],
      ],
    );
  }

  /// A 30 pt well inside a 44 pt target.
  ///
  /// The well is small on purpose — it sits on a line of text, not in a
  /// row of controls — but this is the only way to remove a payout
  /// destination, so the tappable area is the full 44 and the drawn box
  /// just floats in the middle of it.
  Widget _deleteButton(dynamic id, String name) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () {
        HapticService.selectionClick();
        _confirmDelete(id, name);
      },
      child: SizedBox(
        width: 44,
        height: 44,
        child: Center(
          child: Container(
            width: 30,
            height: 30,
            alignment: Alignment.center,
            decoration: neuBox(radius: 10, pressed: true),
            child: Icon(
              Icons.delete_outline_rounded,
              color: Colors.white.withValues(alpha: 0.4),
              size: 16,
            ),
          ),
        ),
      ),
    );
  }

  /// The card's action. Filled gold when there is nothing attached yet,
  /// because then it is the thing to do; a sunken well afterwards, because
  /// then it only offers to change something already working.
  Widget _ctaPill({
    required String label,
    required bool primary,
    VoidCallback? onTap,
  }) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap == null
          ? null
          : () {
              HapticService.mediumImpact();
              onTap();
            },
      child: Container(
        width: double.infinity,
        height: 46,
        alignment: Alignment.center,
        decoration: primary
            ? BoxDecoration(
                color: _gold,
                borderRadius: BorderRadius.circular(14),
              )
            : neuBox(radius: 14, pressed: true),
        child: Text(
          label,
          style: TextStyle(
            color: primary ? neuBase : _gold,
            fontSize: 14,
            fontWeight: FontWeight.w800,
          ),
        ),
      ),
    );
  }

  /// What the two cards mean, for a driver who has never been paid before.
  ///
  /// `isScrollControlled` and a scroll view, like the other two sheets in
  /// this file: without them the sheet is capped at 9/16 of the screen and
  /// this content measures ~418 pt, so on a 375x667 phone the "Got it"
  /// button is clipped away entirely — not visible and not tappable. The
  /// in-app text-size slider goes to 1.6, which puts every phone over.
  void _showHelpSheet() {
    final s = S.of(context);
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (ctx) => Container(
        padding: const EdgeInsets.fromLTRB(24, 12, 24, 24),
        decoration: const BoxDecoration(
          color: neuBase,
          borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
        ),
        child: SafeArea(
          top: false,
          child: SingleChildScrollView(
            child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 36,
                  height: 4,
                  decoration: BoxDecoration(
                    color: Colors.white12,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 20),
              Text(
                s.payoutHelpTitle,
                style: const TextStyle(
                  color: _text,
                  fontSize: 22,
                  fontWeight: FontWeight.w800,
                  letterSpacing: -0.4,
                ),
              ),
              const SizedBox(height: 18),
              _helpBlock(
                Icons.calendar_month_rounded,
                s.payoutWeekly,
                s.payoutHelpWeekly,
              ),
              const SizedBox(height: 14),
              _helpBlock(
                Icons.flash_on_rounded,
                s.instantCashout,
                s.payoutHelpInstant,
              ),
              const SizedBox(height: 22),
              GestureDetector(
                onTap: () => Navigator.pop(ctx),
                child: Container(
                  width: double.infinity,
                  height: 50,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: _gold,
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Text(
                    s.gotIt,
                    style: const TextStyle(
                      color: neuBase,
                      fontSize: 15,
                      fontWeight: FontWeight.w800,
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

  Widget _helpBlock(IconData icon, String title, String body) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: neuBox(radius: 16, pressed: true),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: _gold, size: 18),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    color: _text,
                    fontSize: 13.5,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  body,
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.5),
                    fontSize: 12,
                    height: 1.45,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// The load failed, said inline, above rows that still work.
  ///
  /// Replacing the page with an error and a Retry button was the old
  /// behaviour, and it threw away two controls that do not depend on the
  /// answer: a driver can still attach a card or a bank while we do not yet
  /// know what they had.
  Widget _errorStrip(String message) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: neuBox(
        radius: 14,
        borderColor: _danger.withValues(alpha: 0.35),
      ),
      child: Row(
        children: [
          Icon(Icons.error_outline_rounded, color: _danger, size: 18),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              message,
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.7),
                fontSize: 12.5,
                height: 1.3,
              ),
            ),
          ),
          const SizedBox(width: 8),
          GestureDetector(
            onTap: () {
              HapticService.selectionClick();
              setState(() {
                _loading = true;
                _loadError = null;
              });
              _loadMethods();
            },
            child: Text(
              S.of(context).retry,
              style: const TextStyle(
                color: _gold,
                fontSize: 12.5,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Green for a destination that is working, gold for one still to set up.
  Widget _statusPill(String label, {required bool linked}) {
    final c = linked ? _green : _gold;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: c.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(11),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: c,
          fontSize: 11,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }






  // ── Card brand: parse from display_name (e.g. "Visa ····1234") ──
  static _CardBrand _brandFromDisplay(String display) {
    final lower = display.toLowerCase();
    if (lower.contains('visa')) return _CardBrand.visa;
    if (lower.contains('master')) return _CardBrand.mastercard;
    if (lower.contains('amex') || lower.contains('american')) {
      return _CardBrand.amex;
    }
    if (lower.contains('discover')) return _CardBrand.discover;
    return _CardBrand.unknown;
  }

  static Widget _brandIcon(_CardBrand brand, {double size = 28}) {
    switch (brand) {
      case _CardBrand.visa:
        return Container(
          width: size + 8,
          height: size - 4,
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(4),
          ),
          alignment: Alignment.center,
          child: Text(
            'VISA',
            style: TextStyle(
              color: const Color(0xFF1A1F71),
              fontSize: size * 0.38,
              fontWeight: FontWeight.w900,
              letterSpacing: -0.5,
              fontStyle: FontStyle.italic,
            ),
          ),
        );
      case _CardBrand.mastercard:
        return SizedBox(
          width: size + 4,
          height: size - 4,
          child: Stack(
            alignment: Alignment.center,
            children: [
              Positioned(
                left: 0,
                child: Container(
                  width: size * 0.6,
                  height: size * 0.6,
                  decoration: const BoxDecoration(
                    color: Color(0xFFEB001B),
                    shape: BoxShape.circle,
                  ),
                ),
              ),
              Positioned(
                right: 0,
                child: Container(
                  width: size * 0.6,
                  height: size * 0.6,
                  decoration: BoxDecoration(
                    color: const Color(0xFFF79E1B).withValues(alpha: 0.9),
                    shape: BoxShape.circle,
                  ),
                ),
              ),
            ],
          ),
        );
      case _CardBrand.amex:
        return Container(
          width: size + 8,
          height: size - 4,
          decoration: BoxDecoration(
            color: const Color(0xFF2E77BC),
            borderRadius: BorderRadius.circular(4),
          ),
          alignment: Alignment.center,
          child: Text(
            'AMEX',
            style: TextStyle(
              color: Colors.white,
              fontSize: size * 0.32,
              fontWeight: FontWeight.w900,
              letterSpacing: 0.5,
            ),
          ),
        );
      case _CardBrand.discover:
        return Container(
          width: size + 8,
          height: size - 4,
          decoration: BoxDecoration(
            color: const Color(0xFFFF6600),
            borderRadius: BorderRadius.circular(4),
          ),
          alignment: Alignment.center,
          child: Text(
            'D',
            style: TextStyle(
              color: Colors.white,
              fontSize: size * 0.5,
              fontWeight: FontWeight.w900,
              fontStyle: FontStyle.italic,
            ),
          ),
        );
      case _CardBrand.unknown:
        return const Icon(
          Icons.credit_card_rounded,
          color: Color(0xFF2196F3),
          size: 28,
        );
    }
  }

  Widget _buildMethodCard(Map<String, dynamic> method) {
    final s = S.of(context);
    final type = method['method_type'] ?? 'bank_account';
    final rawDisplay = (method['display_name'] ?? 'Bank account').toString();
    final display = _cleanDisplay(rawDisplay);
    final isDefault = method['is_default'] == true;
    final id = method['id'];
    final isCard = type == 'debit_card';

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: neuBox(
        radius: 20,
        borderColor: isDefault ? _gold.withValues(alpha: 0.45) : null,
      ),
      child: Column(
        children: [
          Row(
            children: [
              Container(
                width: 48,
                height: 48,
                alignment: Alignment.center,
                decoration: neuBox(radius: 15, pressed: true),
                child: isCard
                    ? _brandIcon(_brandFromDisplay(display), size: 30)
                    : const Icon(
                        Icons.account_balance_rounded,
                        color: _green,
                        size: 24,
                      ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            display,
                            style: const TextStyle(
                              color: _text,
                              fontSize: 15,
                              fontWeight: FontWeight.w700,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (isDefault)
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 3,
                            ),
                            decoration: BoxDecoration(
                              color: _gold.withValues(alpha: 0.15),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Text(
                              s.defaultBadge,
                              style: const TextStyle(
                                color: _gold,
                                fontSize: 10,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: 3),
                    Text(
                      isCard ? s.instantCashout : s.bankTransferType,
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.35),
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              GestureDetector(
                onTap: () => _confirmDelete(id, display),
                child: Container(
                  width: 38,
                  height: 38,
                  alignment: Alignment.center,
                  decoration: neuBox(radius: 13, pressed: true),
                  child: Icon(
                    Icons.delete_outline_rounded,
                    color: Colors.white.withValues(alpha: 0.35),
                    size: 18,
                  ),
                ),
              ),
            ],
          ),
          // Full-width action so the label can't be clipped on narrow phones
          // the way the old inline chip was.
          if (!isDefault) ...[
            const SizedBox(height: 12),
            GestureDetector(
              onTap: () => _setDefault(id),
              child: Container(
                width: double.infinity,
                height: 40,
                alignment: Alignment.center,
                decoration: neuBox(radius: 13, pressed: true),
                child: Text(
                  s.setDefault,
                  style: const TextStyle(
                    color: _gold,
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  // ═══════════════════════════════════════════════════
  //  ACTIONS
  // ═══════════════════════════════════════════════════
  Future<void> _setDefault(dynamic id) async {
    HapticService.lightImpact();
    try {
      await ApiService.setDefaultPayoutMethod(
        id is int ? id : int.parse(id.toString()),
      );
      await _loadMethods();
    } catch (e) {
      debugPrint('[Payout] _setDefault error: $e');
      if (!mounted) return;
      _snack(S.of(context).failedToSetDefault, error: true);
    }
  }

  /// Link a bank account through the Stripe Financial Connections sheet.
  ///
  /// The backend mints a Financial Connections session and returns its
  /// `client_secret` — it has no hosted URL, so this must go through the
  /// native SDK. Stripe hands back a `btok_...` which the backend attaches
  /// as the Connect external_account that weekly payouts are sent to.
  Future<void> _connectBankAccount() async {
    HapticService.mediumImpact();
    if (kIsWeb) {
      _snack(S.of(context).bankLinkMobileOnly, error: true);
      return;
    }

    // Our own form, full screen: routing, account, re-enter. The driver
    // asked for the numbers to be typed here rather than in a Stripe sheet,
    // and that is safe because the digits go from the SDK straight to Stripe
    // — AddBankAccountScreen posts only the resulting btok_ back to us.
    //
    // Everything below (the Financial Connections sheet) stays as the
    // fallback for a driver who would rather pick their bank by logging into
    // it, and for the case where Stripe rejects a manually typed account.
    // One bank at a time. If there is already one attached this is an edit,
    // and the old row goes once the new one is safely in — never before, or a
    // failure halfway would leave the driver with no payout destination at
    // all and the weekly transfer nowhere to land.
    final existing = _methodOfType('bank_account');
    final added = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => AddBankAccountScreen(replacing: existing != null),
      ),
    );
    if (!mounted) return;
    if (added == true) {
      final oldId = existing?['id'];
      if (oldId is int) {
        try {
          await ApiService.deletePayoutMethod(oldId);
        } catch (e) {
          debugPrint('[Payout] could not remove the replaced bank: $e');
        }
      }
      if (!mounted) return;
      _snack(S.of(context).bankAccountLinked);
      await _loadMethods();
      return;
    }

    // Our page first, Stripe's window second.
    //
    // The bank flow used to drop the driver straight into Stripe's sheet
    // from a row labelled "Weekly payouts", with nothing in between saying
    // what the account will be used for or warning them off attaching
    // someone else's. This is that missing page — the heading, the terms
    // and the security note — and the button on it is what opens Stripe.
    //
    // The routing and account numbers are still typed into Stripe's own
    // window and never touch this app. That is not a shortcut: taking them
    // in our own fields would put the app inside the compliance scope those
    // numbers carry, for no gain the driver would ever see.
    final go = await showModalBottomSheet<bool>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (_) => const _AddBankIntroSheet(),
    );
    if (go != true || !mounted) return;

    setState(() => _busy = true);
    try {
      // ── Stripe Connect onboarding comes first ──────────────────────────
      //
      // The bank sheet cannot open on a Restricted account, and every account
      // this app creates starts Restricted: the backend calls Account.create
      // when the driver first reaches this screen, which mints an Express
      // account with no identity, no tax details and nothing submitted.
      // Financial Connections then refuses the session and the driver got
      // "Failed to add method" with no way forward — every account in the
      // Stripe dashboard sat Restricted, none ever Enabled.
      //
      // The backend has always had the onboarding link (AccountLink with
      // type="account_onboarding") and ApiService has always had the call.
      // Nothing invoked it: `getStripeConnectLink` had no caller anywhere in
      // the app. This is that missing step.
      final status = await ApiService.getStripeConnectStatus();
      if (!mounted) return;
      final ready = status['payouts_enabled'] == true;
      if (!ready) {
        final url = await ApiService.getStripeConnectLink();
        if (!mounted) return;
        // In our own frame, not the browser. Handing the driver to Safari in
        // the middle of getting paid is where they lose the thread; this
        // keeps our header and back button around Stripe's page, and returns
        // true the moment Stripe redirects to one of our return URLs.
        final done = await Navigator.of(context).push<bool>(
          MaterialPageRoute(
            builder: (_) => StripeOnboardingScreen(url: url),
          ),
        );
        if (!mounted) return;
        if (done == true) {
          // Stripe's onboarding collects a bank account of its own as part of
          // the requirements, so by the time it hands the driver back there
          // is often nothing left to ask. Re-read the methods first and only
          // show our form if it really did not come back with one —
          // otherwise we would make them type the same account twice.
          await _loadMethods();
          if (!mounted) return;
          if (_methodOfType('bank_account') != null) {
            _snack(S.of(context).bankAccountLinked);
            return;
          }
          await _connectBankAccount();
          return;
        }
        // Backed out partway. The same link resumes a half-finished
        // account, so tapping again carries on where they left off.
        _snack(S.of(context).verifyIdentityToGetPaid);
        return;
      }

      final session = await ApiService.createDriverFinancialConnectionsSession();
      if (!mounted) return;

      final clientSecret = (session['client_secret'] ?? '').toString();
      if (clientSecret.isEmpty) {
        // Was indistinguishable from every other failure: the driver saw the
        // same "Failed to add method" whether Stripe refused, the sheet was
        // dismissed, or the server answered 200 with nothing usable in it.
        // Only this branch means "the session came back empty", and it is
        // the one that points at the backend rather than at Stripe.
        debugPrint('[Payout] FC session had no client_secret — keys: '
            '${session.keys.toList()}');
        _snack(S.of(context).failedToAddMethod, error: true);
        return;
      }
      debugPrint('[Payout] FC session ok — account='
          '${session['stripe_account_id']} secret=${clientSecret.length} chars');

      // The session belongs to the driver's connected account, not to the
      // platform — the backend builds it with
      // `account_holder: {type: "account", account: <connect id>}`. Without
      // telling the SDK which account it is acting for, it asks the
      // platform about a session the platform does not own, and the sheet
      // never opens: "Failed to add method", with a 200 OK in the server
      // log a second earlier.
      //
      // The backend has been returning stripe_account_id all along, and
      // ApiService even documents it in the return type. Nothing read it.
      final accountId = (session['stripe_account_id'] ?? '').toString();
      final previousAccount = stripe.Stripe.stripeAccountId;
      final stripe.FinancialConnectionTokenResult result;
      try {
        if (accountId.isNotEmpty) {
          stripe.Stripe.stripeAccountId = accountId;
        }
        result = await stripe.Stripe.instance.collectBankAccountToken(
          clientSecret: clientSecret,
        );
      } finally {
        // Put it back. Leaving it set would point every later Stripe call
        // — the rider's payment sheet included — at this driver's account.
        stripe.Stripe.stripeAccountId = previousAccount;
      }
      if (!mounted) return;

      final bankToken = result.token.id ?? '';
      if (bankToken.isEmpty) {
        // Sheet completed without producing a token (e.g. the driver backed
        // out on the final step). Nothing to attach.
        return;
      }

      await ApiService.addBankAccountPayout(
        bankToken: bankToken,
        setDefault: _methods.isEmpty,
      );
      if (!mounted) return;
      _snack(S.of(context).bankAccountLinked);
      await _loadMethods();
    } on stripe.StripeException catch (e) {
      if (e.error.code == stripe.FailureCode.Canceled) return; // user dismissed
      debugPrint('[Payout] Bank link Stripe error: ${e.error}');
      if (!mounted) return;
      _snack(
        e.error.localizedMessage ?? S.of(context).failedToAddMethod,
        error: true,
      );
    } catch (e) {
      debugPrint('[Payout] Bank link error: $e');
      if (!mounted) return;
      _snack(
        e is ApiException ? e.message : S.of(context).failedToAddMethod,
        error: true,
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Collect a debit card and attach it as an external_account for instant
  /// cashouts. The `CardField` sheet buffers the PAN inside the Stripe SDK;
  /// `createToken` turns that buffer into a `tok_...`. Only the token
  /// leaves the device.
  Future<void> _connectDebitCard() async {
    HapticService.mediumImpact();
    if (kIsWeb) {
      _snack(S.of(context).cardEntryMobileOnly, error: true);
      return;
    }

    final cardToken = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (_) => const _AddDebitCardSheet(),
    );
    if (cardToken == null || cardToken.isEmpty || !mounted) return;

    setState(() => _busy = true);
    try {
      await ApiService.addDebitCardPayout(
        cardToken: cardToken,
        setDefault: _methods.isEmpty,
      );
      if (!mounted) return;
      _snack(S.of(context).debitCardAdded);
      await _loadMethods();
    } catch (e) {
      debugPrint('[Payout] addDebitCard error: $e');
      if (!mounted) return;
      _snack(
        e is ApiException ? e.message : S.of(context).failedToAddMethod,
        error: true,
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _confirmDelete(dynamic id, String name) {
    final s = S.of(context);
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) => Container(
        padding: const EdgeInsets.all(28),
        decoration: const BoxDecoration(
          color: neuBase,
          borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
        ),
        child: SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.white12,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(height: 24),
              Container(
                width: 64,
                height: 64,
                alignment: Alignment.center,
                decoration: neuBox(radius: 22, pressed: true),
                child: Icon(
                  Icons.warning_amber_rounded,
                  color: _danger.withValues(alpha: 0.85),
                  size: 32,
                ),
              ),
              const SizedBox(height: 16),
              Text(
                s.removePayoutMethod,
                style: const TextStyle(
                  color: _text,
                  fontSize: 18,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                s.confirmRemoveMethod(name),
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.5),
                  fontSize: 14,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 24),
              Row(
                children: [
                  Expanded(
                    child: GestureDetector(
                      onTap: () => Navigator.pop(ctx),
                      child: Container(
                        height: 50,
                        alignment: Alignment.center,
                        decoration: neuBox(radius: 16),
                        child: Text(
                          s.cancel,
                          style: const TextStyle(
                            color: _text,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: GestureDetector(
                      onTap: () async {
                        Navigator.pop(ctx);
                        await _deleteMethod(id);
                      },
                      child: Container(
                        height: 50,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: _danger.withValues(alpha: 0.85),
                          borderRadius: BorderRadius.circular(16),
                        ),
                        child: Text(
                          s.removeLabel,
                          style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _deleteMethod(dynamic id) async {
    try {
      await ApiService.deletePayoutMethod(
        id is int ? id : int.parse(id.toString()),
      );
      if (!mounted) return;
      _snack(S.of(context).payoutMethodRemoved);
      // Reload rather than removing locally: deleting the default makes the
      // backend promote another row, and that new default has to show up.
      await _loadMethods();
    } catch (e) {
      debugPrint('[Payout] _deleteMethod error: $e');
      if (!mounted) return;
      _snack(S.of(context).failedToRemoveMethod, error: true);
    }
  }
}

// ═══════════════════════════════════════════════════════════════
//  ADD DEBIT CARD SHEET
// ═══════════════════════════════════════════════════════════════

/// Collects a debit card and returns the Stripe token id (`tok_...`).
///
/// `createToken` reads the card details buffered by the mounted
/// [stripe.CardField] — without a live field on screen there is nothing to
/// tokenize, which is why this has to be its own sheet rather than a bare
/// SDK call. `currency: 'usd'` is required: it marks the token as a payout
/// destination, which is what `Account.create_external_account` accepts.
class _AddDebitCardSheet extends StatefulWidget {
  const _AddDebitCardSheet();

  @override
  State<_AddDebitCardSheet> createState() => _AddDebitCardSheetState();
}

/// What Weekly payouts is, before Stripe's window opens over it.
///
/// The bank half of the reference design: heading, the terms in a sentence,
/// the security note, and one button. What it does not have is fields for a
/// routing and account number, because those are typed into Stripe's own
/// window — see the comment in _connectBankAccount for why that is a
/// deliberate line and not a missing feature.
class _AddBankIntroSheet extends StatelessWidget {
  const _AddBankIntroSheet();


  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    return Container(
      padding: const EdgeInsets.fromLTRB(24, 12, 24, 24),
      decoration: const BoxDecoration(
        color: neuBase,
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.white12,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 18),
            Center(
              child: Text(
                s.payoutWeekly.toUpperCase(),
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.35),
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1.4,
                ),
              ),
            ),
            const SizedBox(height: 14),
            Text(
              s.payoutUpdateBank,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 24,
                fontWeight: FontWeight.w800,
                letterSpacing: -0.5,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              s.payoutUpdateBankDesc,
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.45),
                fontSize: 13,
                height: 1.45,
              ),
            ),
            const SizedBox(height: 16),
            _keepSecureNote(s.payoutKeepSecureBank),
            const SizedBox(height: 14),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  Icons.lock_rounded,
                  size: 14,
                  color: Colors.white.withValues(alpha: 0.3),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    s.payoutBankHandledByStripe,
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.32),
                      fontSize: 11.5,
                      height: 1.35,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 22),
            GestureDetector(
              onTap: () {
                HapticService.mediumImpact();
                Navigator.pop(context, true);
              },
              child: Container(
                width: double.infinity,
                height: 54,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: _gold,
                  borderRadius: BorderRadius.circular(16),
                  boxShadow: [
                    BoxShadow(
                      color: _gold.withValues(alpha: 0.25),
                      blurRadius: 16,
                      offset: const Offset(0, 4),
                    ),
                  ],
                ),
                child: Text(
                  s.payoutOpenBankSheet,
                  style: const TextStyle(
                    color: neuBase,
                    fontSize: 15,
                    fontWeight: FontWeight.w800,
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

/// The "keep your earnings secure" panel both payout sheets carry.
///
/// It is here rather than inside either one because the two warnings are
/// the same warning about the same fraud: someone talks a driver into
/// attaching an account that is not theirs, and the earnings go somewhere
/// else every week until they notice.
///
/// Amber, not red. Nothing has gone wrong — this is a caution being read
/// before anything is typed, and a red panel over a form the driver opened
/// deliberately reads as an error they have already made.
Widget _keepSecureNote(String body) {
  const amber = Color(0xFFD4A843);
  return Builder(
    builder: (context) => Container(
      padding: const EdgeInsets.all(14),
      decoration: neuBox(radius: 16, pressed: true),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.shield_outlined, color: amber, size: 18),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  S.of(context).payoutKeepSecure,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  body,
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.5),
                    fontSize: 12,
                    height: 1.4,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    ),
  );
}

class _AddDebitCardSheetState extends State<_AddDebitCardSheet> {

  final _nameCtrl = TextEditingController();
  bool _complete = false;
  bool _submitting = false;
  String? _error;

  @override
  void dispose() {
    _nameCtrl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_complete || _submitting) return;
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      final token = await stripe.Stripe.instance.createToken(
        stripe.CreateTokenParams.card(
          params: stripe.CardTokenParams(
            type: stripe.TokenType.Card,
            name: _nameCtrl.text.trim().isEmpty
                ? null
                : _nameCtrl.text.trim(),
            currency: 'usd',
          ),
        ),
      );
      if (!mounted) return;
      if (token.id.isEmpty) {
        setState(() {
          _submitting = false;
          _error = S.of(context).failedToAddMethod;
        });
        return;
      }
      Navigator.pop(context, token.id);
    } on stripe.StripeException catch (e) {
      if (!mounted) return;
      if (e.error.code == stripe.FailureCode.Canceled) {
        Navigator.pop(context);
        return;
      }
      setState(() {
        _submitting = false;
        _error = e.error.localizedMessage ?? S.of(context).failedToAddMethod;
      });
    } catch (e) {
      debugPrint('[AddDebitCard] createToken error: $e');
      if (!mounted) return;
      setState(() {
        _submitting = false;
        _error = S.of(context).failedToAddMethod;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    return Padding(
      // Lift above the keyboard so the card field stays visible.
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: Container(
        padding: const EdgeInsets.fromLTRB(24, 12, 24, 24),
        decoration: const BoxDecoration(
          color: neuBase,
          borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
        ),
        child: SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 36,
                  height: 4,
                  decoration: BoxDecoration(
                    color: Colors.white12,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 18),
              // Which destination this is, then what is being done to it —
              // the same name the card that opened this sheet carries, so
              // the driver can see they are where they aimed. It said
              // "EXPRESS PAY" while the card said "Instant cashout": two
              // plausible product names one tap apart, and "Express Pay"
              // is now a word the app uses nowhere else.
              Center(
                child: Text(
                  s.instantCashout.toUpperCase(),
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.35),
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 1.4,
                  ),
                ),
              ),
              const SizedBox(height: 14),
              Text(
                s.payoutUpdateCard,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 24,
                  fontWeight: FontWeight.w800,
                  letterSpacing: -0.5,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                s.payoutUpdateCardDesc,
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.45),
                  fontSize: 13,
                  height: 1.45,
                ),
              ),
              const SizedBox(height: 16),
              _keepSecureNote(s.payoutKeepSecureCard),
              const SizedBox(height: 18),

              // ── Stripe secure card field ──
              Container(
                decoration: neuBox(radius: 16, pressed: true),
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 4,
                ),
                child: stripe.CardField(
                  enablePostalCode: false,
                  style: const TextStyle(color: Colors.white, fontSize: 16),
                  decoration: InputDecoration(
                    border: InputBorder.none,
                    hintStyle: TextStyle(
                      color: Colors.white.withValues(alpha: 0.35),
                      fontSize: 16,
                    ),
                  ),
                  onCardChanged: (details) {
                    setState(() => _complete = details?.complete ?? false);
                  },
                ),
              ),
              const SizedBox(height: 14),

              // ── Cardholder name ──
              Container(
                decoration: neuBox(radius: 16, pressed: true),
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: TextField(
                  controller: _nameCtrl,
                  style: const TextStyle(color: Colors.white, fontSize: 15),
                  textCapitalization: TextCapitalization.words,
                  decoration: InputDecoration(
                    border: InputBorder.none,
                    hintText: s.cardholderNameLabel,
                    hintStyle: TextStyle(
                      color: Colors.white.withValues(alpha: 0.35),
                      fontSize: 15,
                    ),
                    icon: Icon(
                      Icons.person_outline_rounded,
                      color: Colors.white.withValues(alpha: 0.35),
                      size: 20,
                    ),
                  ),
                ),
              ),

              if (_error != null) ...[
                const SizedBox(height: 14),
                Row(
                  children: [
                    const Icon(
                      Icons.error_outline_rounded,
                      color: Color(0xFFFF5252),
                      size: 16,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        _error!,
                        style: const TextStyle(
                          color: Color(0xFFFF5252),
                          fontSize: 12.5,
                        ),
                      ),
                    ),
                  ],
                ),
              ],

              const SizedBox(height: 16),
              Row(
                children: [
                  Icon(
                    Icons.lock_rounded,
                    color: const Color(0xFF4CAF50).withValues(alpha: 0.7),
                    size: 14,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      s.infoEncryptedSecure,
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.35),
                        fontSize: 11,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 20),

              // ── Submit ──
              GestureDetector(
                onTap: (_complete && !_submitting) ? _submit : null,
                child: AnimatedOpacity(
                  duration: const Duration(milliseconds: 150),
                  opacity: (_complete && !_submitting) ? 1 : 0.45,
                  child: Container(
                    width: double.infinity,
                    height: 54,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: _gold,
                      borderRadius: BorderRadius.circular(18),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.55),
                          offset: const Offset(5, 5),
                          blurRadius: 12,
                        ),
                      ],
                    ),
                    child: _submitting
                        ? const SizedBox(
                            width: 22,
                            height: 22,
                            child: CircularProgressIndicator(
                              color: Colors.black,
                              strokeWidth: 2,
                            ),
                          )
                        : Text(
                            s.addCardButton,
                            style: const TextStyle(
                              color: Colors.black,
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
                  onPressed: _submitting
                      ? null
                      : () => Navigator.pop(context),
                  child: Text(
                    s.cancel,
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.5),
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

// ═══════════════════════════════════════════════════════════════
//  Card brand enum
// ═══════════════════════════════════════════════════════════════
enum _CardBrand { visa, mastercard, amex, discover, unknown }
