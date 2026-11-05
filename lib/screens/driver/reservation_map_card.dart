import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../l10n/app_localizations.dart';
import '../../widgets/glass_style.dart';
import 'reservation_offer_card.dart';

// ══════════════════════════════════════════════════════════════════════════
//  The driver's own reservation on the map, before it starts (owner
//  2026-11-05, Lyft's "Reserved Lyft · 5:55 PM"): a callout on its pickup;
//  tapped, the callout turns gold and this card takes the sheet's place —
//  "Scheduled Ride", the pickup address, X, and More info (the
//  reservation's own page, showReservationDetail).
// ══════════════════════════════════════════════════════════════════════════

const List<String> _kWeekEn = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
const List<String> _kWeekEs = ['Lun', 'Mar', 'Mié', 'Jue', 'Vie', 'Sáb', 'Dom'];

/// The callout's second line: the pickup time alone today ("5:55 PM", as
/// Lyft), "Tomorrow · 5:55 PM" tomorrow, the weekday further out.
String reservationCalloutWhen(S s, DateTime at, {DateTime? now}) {
  final n = now ?? DateTime.now();
  final days = DateTime(at.year, at.month, at.day)
      .difference(DateTime(n.year, n.month, n.day))
      .inDays;
  final time = DateFormat('h:mm a', 'en_US').format(at);
  if (days <= 0) return time;
  if (days == 1) return '${s.resDetailTomorrow} · $time';
  final es = s.locale.languageCode == 'es';
  return '${(es ? _kWeekEs : _kWeekEn)[at.weekday - 1]} · $time';
}

/// The card: the sheet's glass, welded to the sides and the bottom with the
/// sheet's top corners, so it reads as the sheet changing face.
class ReservationMapCard extends StatelessWidget {
  const ReservationMapCard({
    super.key,
    required this.address,
    required this.onClose,
    required this.onMoreInfo,
    this.bottomInset = 0,
  });

  final String address;
  final VoidCallback onClose;
  final VoidCallback onMoreInfo;

  /// The home indicator's inset: the button stays clear of it.
  final double bottomInset;

  static const Key closeKey = ValueKey('res-map-card-close');

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    return GlassSurface(
      borderRadius: const BorderRadius.vertical(top: Radius.circular(26)),
      tint: glassSheetTint,
      // Round frost on iOS too (rule 43): the blur over the native map is
      // otherwise a rectangle behind the rounded corners.
      roundFrostOnIOS: true,
      child: Stack(
        children: [
          Padding(
            padding: EdgeInsets.fromLTRB(20, 20, 20, 16 + bottomInset),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Container(
                      width: 44,
                      height: 44,
                      decoration: const BoxDecoration(
                        color: Colors.black,
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(Icons.schedule_rounded,
                          color: Colors.white, size: 24),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            s.resMapCardTitle,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 19,
                              fontWeight: FontWeight.w700,
                              height: 1.2,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            address,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: Colors.white.withValues(alpha: 0.62),
                              fontSize: 14,
                              fontWeight: FontWeight.w400,
                              height: 1.25,
                            ),
                          ),
                        ],
                      ),
                    ),
                    // Room for the X.
                    const SizedBox(width: 30),
                  ],
                ),
                const SizedBox(height: 18),
                ReserveOfferButton(
                    label: s.resDetailMoreInfo, onTap: onMoreInfo),
              ],
            ),
          ),
          Positioned(
            top: 12,
            right: 12,
            child: Semantics(
              button: true,
              label: s.close,
              child: GestureDetector(
                key: closeKey,
                behavior: HitTestBehavior.opaque,
                onTap: onClose,
                child: Padding(
                  padding: const EdgeInsets.all(4),
                  child: Container(
                    width: 30,
                    height: 30,
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.14),
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(Icons.close_rounded,
                        color: Colors.white, size: 18),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
