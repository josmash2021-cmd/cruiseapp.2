import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../widgets/neu_style.dart';

/// Cancellation fees by tier, in dollars — the app-side mirror of
/// `SCHEDULED_CANCEL_FEE_BY_TIER` in backend/routers/trips.py.
/// test_schedule_hub_guard_test.dart compares the two sources; if you move
/// one, move the other.
const Map<String, int> kScheduledCancelFeesUsd = {
  'Compact': 10,
  'Standard': 15,
  'Premium': 25,
  'Black': 35,
};

/// "Cancellation policy" page for scheduled rides (2026-08-22) — linked from
/// the datetime page's "Cancel or edit for free". Static copy over the neu
/// ground; the fee rows render from [kScheduledCancelFeesUsd].
class ScheduleCancelPolicyScreen extends StatelessWidget {
  const ScheduleCancelPolicyScreen({super.key});

  static const _gold = Color(0xFFE8C547);

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    return Scaffold(
      backgroundColor: neuBase,
      body: Stack(
        children: [
          const Positioned.fill(child: NeuDotsBackdrop()),
          SafeArea(
            child: Column(
              children: [
                // ── Top row: X / title ──
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
                  child: Row(
                    children: [
                      GestureDetector(
                        onTap: () => Navigator.of(context).pop(),
                        child: Container(
                          width: 38,
                          height: 38,
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha: 0.06),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: const Icon(Icons.close_rounded,
                              color: Colors.white, size: 20),
                        ),
                      ),
                      Expanded(
                        child: Center(
                          child: Text(
                            s.cancelPolicyTitle,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 17,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 38),
                    ],
                  ),
                ),
                Expanded(
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(24, 22, 24, 24),
                    children: [
                      Text(
                        s.cancelPolicyIntro,
                        style: const TextStyle(
                          color: Colors.white70,
                          fontSize: 14,
                          height: 1.55,
                        ),
                      ),
                      const SizedBox(height: 24),
                      // One card per tier, in the page's promised order.
                      ...kScheduledCancelFeesUsd.entries.map(
                        (e) => Padding(
                          padding: const EdgeInsets.only(bottom: 12),
                          child: Container(
                            padding: const EdgeInsets.all(16),
                            decoration: neuBox(radius: 16),
                            child: Row(
                              children: [
                                const Icon(Icons.directions_car_rounded,
                                    color: _gold, size: 20),
                                const SizedBox(width: 14),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        '${e.key} · \$${e.value}',
                                        style: const TextStyle(
                                          color: Colors.white,
                                          fontSize: 15,
                                          fontWeight: FontWeight.w800,
                                        ),
                                      ),
                                      const SizedBox(height: 3),
                                      Text(
                                        s.cancelPolicyFeeLine(e.value),
                                        style: const TextStyle(
                                          color: Colors.white54,
                                          fontSize: 12.5,
                                          height: 1.4,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
