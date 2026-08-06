import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_stripe/flutter_stripe.dart' as stripe;
import 'package:shared_preferences/shared_preferences.dart';

import '../../l10n/app_localizations.dart';
import 'package:url_launcher/url_launcher.dart';

import 'add_bank_account_screen.dart';

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

class _PayoutMethodsScreenState extends State<PayoutMethodsScreen> {
  static const _gold = Color(0xFFD4A843);
  static const _green = Color(0xFF4CAF50);
  static const _danger = Color(0xFFFF5252);
  static const _text = Colors.white;

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
    ScaffoldMessenger.of(context).showSnackBar(
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
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ── Header ──
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
              child: Align(
                alignment: Alignment.centerLeft,
                child: GestureDetector(
                  onTap: () => Navigator.pop(context),
                  child: Container(
                    width: 40,
                    height: 40,
                    alignment: Alignment.center,
                    decoration: neuBox(radius: 14, pressed: true),
                    child: const Icon(
                      Icons.arrow_back_rounded,
                      color: _text,
                      size: 20,
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 18),

            // Title on the left at reading size, with the sentence that
            // explains the two rows underneath it — rather than a centred
            // page title over a card explaining only one of them.
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    s.payoutYourMethods,
                    style: const TextStyle(
                      color: _text,
                      fontSize: 26,
                      fontWeight: FontWeight.w800,
                      letterSpacing: -0.6,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    s.payoutMethodsIntro,
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.45),
                      fontSize: 13.5,
                      height: 1.4,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 22),

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
                              // Two destinations, always both shown.
                              //
                              // The old screen listed whatever happened to be
                              // linked and hid the rest behind two buttons at
                              // the foot of the page, so a driver with no card
                              // had no way to learn that instant cashout
                              // existed. A row that is not set up says so and
                              // offers to be — the absence is information too.
                              Container(
                                decoration: neuBox(radius: 20),
                                padding:
                                    const EdgeInsets.symmetric(horizontal: 16),
                                child: Column(
                                  children: [
                                    _destinationRow(
                                      icon: Icons.flash_on_rounded,
                                      title: s.payoutExpressPay,
                                      emptyDesc: s.payoutExpressPayDesc,
                                      method: _methodOfType('debit_card'),
                                      statusLabel: s.payoutOnRequest,
                                      onTap: _connectDebitCard,
                                    ),
                                    Divider(
                                      height: 1,
                                      color:
                                          Colors.white.withValues(alpha: 0.05),
                                    ),
                                    _destinationRow(
                                      icon: Icons.calendar_month_rounded,
                                      title: s.payoutWeekly,
                                      emptyDesc: s.payoutWeeklyDesc,
                                      method: _methodOfType('bank_account'),
                                      statusLabel: s.payoutActive,
                                      onTap: _connectBankAccount,
                                    ),
                                  ],
                                ),
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

  /// One payout destination: what it is, what is attached, and its state.
  Widget _destinationRow({
    required IconData icon,
    required String title,
    required String emptyDesc,
    required Map<String, dynamic>? method,
    required String statusLabel,
    required VoidCallback onTap,
  }) {
    final s = S.of(context);
    final linked = method != null;
    final sub = linked
        ? _cleanDisplay((method['display_name'] ?? '').toString())
        : emptyDesc;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      // Deaf while a Stripe call is in flight. Two taps on "Set up" opens
      // two sheets, and the second one lands on a Connect account the first
      // is halfway through changing.
      // Live while the list is still arriving. Only a Stripe call in flight
      // closes the row.
      //
      // Dimming it and turning taps off during the fetch made the whole card
      // read as disabled for as long as the request took — and the tap is
      // harmless either way: it opens the sheet that attaches an account,
      // which is the right thing whether one is already attached or not.
      onTap: _busy
          ? null
          : () {
              HapticService.mediumImpact();
              onTap();
            },
      child: Opacity(
        opacity: _busy ? 0.5 : 1,
        child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 16),
        child: Row(
          children: [
            Icon(
              icon,
              size: 20,
              color: linked ? _gold : Colors.white.withValues(alpha: 0.45),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(
                      color: _text,
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    sub,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.4),
                      fontSize: 12.5,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 10),
            // The pill is the one thing that genuinely has to wait: until
            // the list arrives, the row cannot honestly say either "Active"
            // or "Set up". So it says nothing, rather than putting a
            // spinner where an answer will be — a small turning circle in a
            // row is read as the row working, not as one field pending.
            if (_busy)
              const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(color: _gold, strokeWidth: 2),
              )
            else if (!_loading)
              _statusPill(linked ? statusLabel : s.payoutSetUp,
                  linked: linked),
            const SizedBox(width: 6),
            // A linked row gets a bin instead of a chevron.
            //
            // `_confirmDelete` and `_deleteMethod` were written and had no
            // caller: the redesign replaced the per-method cards with these
            // two structural rows and the delete button went with them. A
            // driver could attach a card and never take it off.
            if (linked && !_busy && !_loading)
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () {
                  HapticService.selectionClick();
                  _confirmDelete(
                    method['id'],
                    _cleanDisplay((method['display_name'] ?? '').toString()),
                  );
                },
                child: Container(
                  width: 34,
                  height: 34,
                  alignment: Alignment.center,
                  decoration: neuBox(radius: 12, pressed: true),
                  child: Icon(
                    Icons.delete_outline_rounded,
                    color: Colors.white.withValues(alpha: 0.4),
                    size: 17,
                  ),
                ),
              )
            else
              Icon(
                Icons.chevron_right_rounded,
                color: Colors.white.withValues(alpha: 0.3),
                size: 20,
              ),
          ],
        ),
        ),
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
    final added = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => const AddBankAccountScreen()),
    );
    if (!mounted) return;
    if (added == true) {
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
        final opened = await launchUrl(
          Uri.parse(url),
          mode: LaunchMode.externalApplication,
        );
        if (!mounted) return;
        // The same link resumes a half-finished account, so a driver who
        // backs out partway can tap this again and carry on where they were.
        _snack(
          opened
              ? S.of(context).verifyIdentityToGetPaid
              : S.of(context).failedToAddMethod,
          error: !opened,
        );
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

  static const _gold = Color(0xFFD4A843);

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
  static const _gold = Color(0xFFD4A843);

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
              // the same two-line header the row that opened this sheet
              // uses, so the driver can see they are where they aimed.
              Center(
                child: Text(
                  s.payoutExpressPay.toUpperCase(),
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
