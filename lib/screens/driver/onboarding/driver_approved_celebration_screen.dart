import 'package:flutter/material.dart';

import '../../../config/page_transitions.dart';
import '../../../l10n/app_localizations.dart';
import '../../../services/api_service.dart';
import '../../../services/user_session.dart';
import '../payout_methods_screen.dart';
import 'first_trip_guide_screen.dart';

/// Post-approval celebration — the entry point of the NEW approved-driver
/// flow (the legacy cinematic `DriverApprovedScreen` and its instructions
/// guide were removed 2026-08-25 — this flow replaces them). Shown once when dispatch approves the driver: from the pending
/// screen's poll or from the approval push tap.
///
/// "Start driving" runs the payout gate (`GET /drivers/stripe-connect/status`
/// via [ApiService.getStripeConnectStatus]): no payout destination yet →
/// [PayoutMethodsScreen] first (leaving without setting one up is fine — a
/// snackbar tells them the menu path). Whatever happens there — bank linked,
/// Skip, or back — the flow ALWAYS continues to the mandatory first-trip
/// guide (2026-10-22), whose own Skip only advances a page; only the
/// guide's last page ends at DriverOnlineScreen.
class DriverApprovedCelebrationScreen extends StatefulWidget {
  const DriverApprovedCelebrationScreen({super.key});

  @override
  State<DriverApprovedCelebrationScreen> createState() =>
      _DriverApprovedCelebrationScreenState();
}

class _DriverApprovedCelebrationScreenState
    extends State<DriverApprovedCelebrationScreen> {
  static const _navy = Color(0xFF14141A);
  static const _gold = Color(0xFFE8C547);

  String _firstName = '';
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _loadName();
  }

  Future<void> _loadName() async {
    final user = await UserSession.getUser();
    final name = (user?['firstName'] ?? '').trim();
    if (mounted && name.isNotEmpty) setState(() => _firstName = name);
  }

  /// True when the driver already has a working payout destination.
  bool _payoutConfigured(Map<String, dynamic> status) =>
      status['payouts_enabled'] == true || status['connected'] == true;

  Future<void> _onStartDriving() async {
    if (_busy) return;
    setState(() => _busy = true);

    // ── Payout gate ──────────────────────────────────────────────────
    var configured = false;
    try {
      configured = _payoutConfigured(await ApiService.getStripeConnectStatus());
    } catch (_) {
      // Network hiccup — don't trap the driver on the gate; the menu path
      // remains available and the snackbar below says so.
      configured = false;
    }
    if (!mounted) return;

    if (!configured) {
      await Navigator.of(context).push(
        onboardingFadeSlideRoute(
            const PayoutMethodsScreen(autoPopOnBankLinked: true)),
      );
      if (!mounted) return;
      // Re-check on return: success → straight to the guide; left without
      // setting one up → they may continue anyway (not a prison).
      try {
        configured = _payoutConfigured(await ApiService.getStripeConnectStatus());
      } catch (_) {
        configured = false;
      }
      if (!mounted) return;
      if (!configured) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            behavior: SnackBarBehavior.floating,
            backgroundColor: const Color(0xFF1C1C24),
            content: Text(S.of(context).addPayoutLaterSnack),
          ),
        );
      }
    }

    await _continueToHome();
  }

  /// The guide is MANDATORY after the payout gate (user spec 2026-10-22):
  /// bank connected, Skip, or back — EVERY exit of the bank page lands on
  /// the guide pages, never straight home. And the guide is a one-way
  /// street: its own Skip only advances a page; only the last page
  /// reaches home.
  Future<void> _continueToHome() async {
    if (!mounted) return;
    Navigator.of(context).pushAndRemoveUntil(
      onboardingFadeSlideRoute(const FirstTripGuideScreen()),
      (_) => false,
    );
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    return Scaffold(
      backgroundColor: _navy,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 28),
          child: Column(
            children: [
              const Spacer(flex: 3),

              // Circular approved photo with a subtle gold glow.
              Container(
                width: 245,
                height: 245,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: _gold.withValues(alpha: 0.55),
                    width: 2.5,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: _gold.withValues(alpha: 0.22),
                      blurRadius: 48,
                      spreadRadius: 2,
                    ),
                    BoxShadow(
                      color: _gold.withValues(alpha: 0.10),
                      blurRadius: 90,
                      spreadRadius: 10,
                    ),
                  ],
                ),
                child: ClipOval(
                  child: Image.asset(
                    'assets/images/onboarding/approved.jpg',
                    fit: BoxFit.cover,
                    width: 245,
                    height: 245,
                  ),
                ),
              ),

              const SizedBox(height: 36),

              Text(
                s.welcomeCruiseInRideTitle(
                  _firstName.isNotEmpty ? _firstName : s.driverFallback,
                ),
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 30,
                  fontWeight: FontWeight.w800,
                  letterSpacing: -0.5,
                ),
              ),

              const SizedBox(height: 16),

              Text(
                s.approvedWelcomeBody,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.6),
                  fontSize: 15,
                  height: 1.5,
                ),
              ),

              const Spacer(flex: 3),

              SizedBox(
                width: double.infinity,
                height: 56,
                child: ElevatedButton(
                  onPressed: _busy ? null : _onStartDriving,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _gold,
                    foregroundColor: Colors.black,
                    disabledBackgroundColor: _gold.withValues(alpha: 0.6),
                    elevation: 4,
                    shadowColor: _gold.withValues(alpha: 0.4),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(18),
                    ),
                  ),
                  child: _busy
                      ? const SizedBox(
                          width: 22,
                          height: 22,
                          child: CircularProgressIndicator(
                            strokeWidth: 2.5,
                            color: Colors.black,
                          ),
                        )
                      : Text(
                          s.startDriving,
                          style: const TextStyle(
                            fontSize: 17,
                            fontWeight: FontWeight.w800,
                            letterSpacing: 0.3,
                          ),
                        ),
                ),
              ),

              const SizedBox(height: 32),
            ],
          ),
        ),
      ),
    );
  }
}
