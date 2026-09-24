import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';

/// The rider's reason set (user spec 2026-09-23): same reference design as
/// the driver's sheet, rider-specific options. The machine string goes to
/// the API as `cancel_reason`.
List<(String, String)> riderCancelReasons(S s) => [
      (s.riderCancelReasonNotNeeded, 'no_longer_needed'),
      (s.riderCancelReasonWaitLong, 'wait_too_long'),
      (s.driverCancelReasonWrongPickup, 'wrong_pickup'),
      (s.riderCancelReasonWrongDropoff, 'wrong_dropoff'),
      (s.riderCancelReasonByAccident, 'booked_by_accident'),
      (s.riderCancelReasonPrice, 'price_issue'),
      (s.otherLabel, 'other'),
    ];

/// Reference cancel-reasons sheet (user spec 2026-09-19): X close at
/// top-left, big title, note, radio reasons, and a gold "Siguiente" armed
/// only once a reason is picked. Returns the reason's MACHINE string for
/// the API, or null when dismissed. Shared by the rider and driver cancel
/// flows (the driver's lives inline in driver_trip_accept_screen.dart).
Future<String?> showCancelReasonSheet(
  BuildContext context, {
  required String title,
  required String note,
  required List<(String label, String machine)> reasons,
  required String nextLabel,
  Color accent = const Color(0xFFE8C547),
}) {
  final pad = MediaQuery.of(context).padding;
  final fullHeight = MediaQuery.of(context).size.height;
  var selected = -1;
  return showModalBottomSheet<String>(
    context: context,
    backgroundColor: Colors.transparent,
    isScrollControlled: true,
    builder: (ctx) => StatefulBuilder(
      // FULL SCREEN (user spec 2026-09-23, "debe salir completa no a mitad
      // de pantalla"): the sheet takes the whole viewport like the
      // reference, X under the status bar — not a half-sheet over the map.
      builder: (ctx, setSheet) => Container(
        height: fullHeight,
        decoration: const BoxDecoration(color: Color(0xFF141417)),
        padding: EdgeInsets.fromLTRB(16, pad.top + 8, 16, pad.bottom + 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            GestureDetector(
              onTap: () => Navigator.pop(ctx),
              child: const Padding(
                padding: EdgeInsets.all(8),
                child: Icon(Icons.close_rounded, color: Colors.white, size: 24),
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(left: 8),
              child: Text(title,
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 26,
                      fontWeight: FontWeight.w800,
                      height: 1.15)),
            ),
            const SizedBox(height: 6),
            Padding(
              padding: const EdgeInsets.only(left: 8),
              child: Text(note,
                  style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.55),
                      fontSize: 14,
                      fontWeight: FontWeight.w500)),
            ),
            const SizedBox(height: 18),
            ...List.generate(reasons.length, (i) {
              final on = i == selected;
              return GestureDetector(
                onTap: () => setSheet(() => selected = i),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 13),
                  child: Row(children: [
                    Container(
                      width: 24,
                      height: 24,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        border: Border.all(
                          color:
                              on ? accent : Colors.white.withValues(alpha: 0.45),
                          width: 2,
                        ),
                      ),
                      child: on
                          ? Center(
                              child: Container(
                                width: 12,
                                height: 12,
                                decoration: BoxDecoration(
                                    color: accent, shape: BoxShape.circle),
                              ),
                            )
                          : null,
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Text(reasons[i].$1,
                          style: TextStyle(
                            color: on
                                ? Colors.white
                                : Colors.white.withValues(alpha: 0.75),
                            fontSize: 15.5,
                            fontWeight: FontWeight.w600,
                          )),
                    ),
                  ]),
                ),
              );
            }),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              height: 52,
              child: ElevatedButton(
                onPressed: selected < 0
                    ? null
                    : () => Navigator.pop(ctx, reasons[selected].$2),
                style: ElevatedButton.styleFrom(
                  backgroundColor: accent,
                  foregroundColor: Colors.black,
                  disabledBackgroundColor:
                      Colors.white.withValues(alpha: 0.14),
                  disabledForegroundColor:
                      Colors.white.withValues(alpha: 0.38),
                  elevation: 0,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(26)),
                ),
                child: Text(nextLabel,
                    style: const TextStyle(
                        fontSize: 16, fontWeight: FontWeight.w800)),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}
