import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../models/lat_lng.dart';
import '../../utils/name_helper.dart' as nh;
import '../../utils/offer_metrics.dart';
import '../../widgets/neu_style.dart';
import '../../widgets/offer_countdown_ring.dart';
import '../../widgets/route_connector_line.dart';

const _gold = Color(0xFFE8C547);

/// The offer cards' ground (owner 2026-11-04, "coloca todos de ese color
/// fondo para las tarjetas de oferta"): the near-black of the reservations
/// map's old floating card, #0B0B0F at 95 %.
const Color kOfferCardBg = Color(0xF20B0B0F);

/// A reservation on the reservations map, drawn as the trip offer card
/// (owner 2026-11-04: "la tarjeta tal cual como la tarjeta de oferta"):
/// the same raised surface, the RESERVADO badge row with the pickup time,
/// the fare with the hourly rate and the two metric pills, the Cruise disc,
/// the gold rail with "away" and "trip" over the two addresses, and the
/// rider row — with the rider's Verificado in gold. Mirrors `_offerCard` /
/// `_buildNormalCardContent` in driver_online_widgets.dart (a part of the
/// online screen's state, so it cannot be reused from here); a change to
/// the offer card's look belongs in both.
class ReservationOfferCard extends StatelessWidget {
  const ReservationOfferCard({
    super.key,
    required this.trip,
    required this.whenLabel,
    this.driverPos,
  });

  /// One ride of `/scheduled-trips/available`.
  final Map<String, dynamic> trip;

  /// "Mañana · 7:00 PM".
  final String whenLabel;

  /// Where the driver is now — the "away" figure, as on an offer.
  final LatLng? driverPos;

  static double _num(Object? v) {
    final d = (v as num?)?.toDouble() ?? 0;
    return d.isFinite ? d : 0;
  }

  static double _havKm(LatLng a, LatLng b) {
    const r = 6371.0;
    final dLat = (b.latitude - a.latitude) * math.pi / 180;
    final dLng = (b.longitude - a.longitude) * math.pi / 180;
    final h = math.pow(math.sin(dLat / 2), 2) +
        math.cos(a.latitude * math.pi / 180) *
            math.cos(b.latitude * math.pi / 180) *
            math.pow(math.sin(dLng / 2), 2);
    final km = 2 * r * math.asin(math.sqrt(h));
    return km.isFinite ? km : 0;
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final fare = _num(trip['fare']);
    final pickup = LatLng(_num(trip['pickup_lat']), _num(trip['pickup_lng']));
    final dropoff =
        LatLng(_num(trip['dropoff_lat']), _num(trip['dropoff_lng']));
    final isAirport = trip['is_airport'] == true;
    final isCash =
        (trip['payment_method'] ?? '').toString().toLowerCase() == 'cash';

    // The ride's own minutes and miles; the offer card's straight-line
    // estimate only when the booking carried none.
    final tripKm = _havKm(pickup, dropoff);
    final tripMin = (trip['duration_minutes'] as num?)?.round() ??
        offerLegMinutes(km: tripKm);
    final tripMi =
        (trip['distance_miles'] as num?)?.toDouble() ?? tripKm * 0.621371;
    final here = driverPos;
    final awayKm = here == null ? 0.0 : _havKm(here, pickup);
    final awayMin = offerLegMinutes(km: awayKm);
    final awayMi = awayKm * 0.621371;
    final totalMin = offerTotalMinutes(awayMin, tripMin);
    final hourly = offerPayPerHour(fare, totalMin);

    final short = nh.shortName((trip['rider_name'] ?? '').toString());
    final riderName = short.isNotEmpty ? short : s.riderFallback;
    final rating = _num(trip['rider_rating']);
    final verified = trip['rider_verified'] == true;

    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: kOfferCardBg,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.white.withValues(alpha: 0.05)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.55),
            offset: const Offset(0, 16),
            blurRadius: 32,
            spreadRadius: -8,
          ),
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.35),
            offset: const Offset(0, 4),
            blurRadius: 10,
            spreadRadius: -3,
          ),
          BoxShadow(
            color: Colors.white.withValues(alpha: 0.06),
            offset: const Offset(0, -1),
            blurRadius: 2,
          ),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 14),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ── Badges (centred, owner 2026-11-04) and the pickup time ──
            SizedBox(
              width: double.infinity,
              child: Wrap(
                alignment: WrapAlignment.center,
                spacing: 6,
                runSpacing: 6,
                children: [
                  // Gold, never the purple (owner 2026-11-04).
                  _badge(s.badgeReserved, Icons.schedule_rounded, _gold),
                  if (isAirport)
                    _badge(s.badgeAirport, Icons.flight_takeoff_rounded,
                        const Color(0xFF3B82F6)),
                  if (isCash)
                    _badge(s.badgeCash, Icons.payments_rounded,
                        const Color(0xFF10B981)),
                ],
              ),
            ),
            const SizedBox(height: 4),
            Row(
              children: [
                const Icon(Icons.access_time_rounded, size: 14, color: _gold),
                const SizedBox(width: 4),
                Flexible(
                  child: Text(
                    whenLabel,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: _gold,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            // ── Fare, hourly rate, metrics, and the disc ──
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.baseline,
                        textBaseline: TextBaseline.alphabetic,
                        children: [
                          Text(
                            '\$${fare.toStringAsFixed(2)}',
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 30,
                              fontWeight: FontWeight.w800,
                              letterSpacing: -0.5,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Flexible(
                            child: Text(
                              s.plusTips,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: _gold,
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Text(
                        s.offerHourlyRate(hourly.toStringAsFixed(2)),
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 12.5,
                        ),
                      ),
                      const SizedBox(height: 10),
                      Wrap(
                        spacing: 8,
                        runSpacing: 6,
                        children: [
                          _metric(Icons.access_time_rounded,
                              s.offerDuration(totalMin)),
                          _metric(Icons.route_rounded,
                              '${(awayMi + tripMi).toStringAsFixed(1)} mi'),
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 10),
                // The Cruise disc, still — a reservation has no clock.
                Container(
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: neuSurface,
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.5),
                        offset: const Offset(0, 5),
                        blurRadius: 12,
                        spreadRadius: -3,
                      ),
                      BoxShadow(
                        color: Colors.white.withValues(alpha: 0.07),
                        offset: const Offset(0, -1),
                        blurRadius: 2,
                      ),
                    ],
                  ),
                  child: OfferCountdownRing(
                    active: false,
                    onExpired: () {},
                    child: Image.asset(
                      'assets/images/cruise_logo.png',
                      fit: BoxFit.contain,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 18),
            // ── Pickup over dropoff on the gold rail ──
            _route(
              s,
              pickupMeta: here == null
                  ? whenLabel
                  : s.offerAway(awayMin, awayMi.toStringAsFixed(1)),
              pickupAddr: (trip['pickup_address'] ?? '').toString(),
              dropoffMeta: s.offerTrip(tripMin, tripMi.toStringAsFixed(1)),
              dropoffAddr: (trip['dropoff_address'] ?? '').toString(),
            ),
            const SizedBox(height: 16),
            Container(height: 1, color: Colors.white.withValues(alpha: 0.05)),
            const SizedBox(height: 16),
            // ── Who is riding ──
            Row(
              children: [
                _avatar(riderName),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    riderName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                if (verified) ...[
                  const SizedBox(width: 8),
                  // Verified in gold (owner 2026-11-04), never the blue.
                  const Icon(Icons.verified_rounded, color: _gold, size: 15),
                  const SizedBox(width: 3),
                  Text(
                    s.faceVerified,
                    style: const TextStyle(
                      color: _gold,
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
                const SizedBox(width: 10),
                if (rating <= 0)
                  Text(
                    s.newRiderLabel,
                    style: const TextStyle(
                      color: _gold,
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                    ),
                  )
                else ...[
                  const Icon(Icons.star_rounded, color: _gold, size: 15),
                  const SizedBox(width: 3),
                  Text(
                    rating.toStringAsFixed(1),
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }

  // The outline only — no filled box (owner 2026-11-04).
  static Widget _badge(String label, IconData icon, Color color) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: color, width: 1.2),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 14, color: color),
            const SizedBox(width: 5),
            Text(
              label,
              style: TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.w800,
                letterSpacing: 0.6,
                color: color,
              ),
            ),
          ],
        ),
      );

  static Widget _metric(IconData icon, String value) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: _gold, size: 12),
            const SizedBox(width: 5),
            Text(
              value,
              style: const TextStyle(
                color: _gold,
                fontSize: 12,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
      );

  static Widget _avatar(String riderName) {
    final initial =
        riderName.trim().isNotEmpty ? riderName.trim()[0].toUpperCase() : '?';
    return Container(
      width: 30,
      height: 30,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(color: Colors.white.withValues(alpha: 0.15)),
      ),
      alignment: Alignment.center,
      child: Text(
        initial,
        style: const TextStyle(
          color: _gold,
          fontSize: 13,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }

  static Widget _route(
    S s, {
    required String pickupMeta,
    required String pickupAddr,
    required String dropoffMeta,
    required String dropoffAddr,
  }) {
    const stopH = 34.0;
    const halfPad = (stopH - 11) / 2;
    const goldRingDot = BoxDecoration(
      shape: BoxShape.circle,
      border: Border.fromBorderSide(BorderSide(color: _gold, width: 1.5)),
    );
    const whiteRing = BoxDecoration(
      shape: BoxShape.circle,
      border:
          Border.fromBorderSide(BorderSide(color: Colors.white, width: 1.5)),
    );
    Widget stopText(String meta, String address) => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(meta,
                style: const TextStyle(color: Colors.white, fontSize: 11)),
            const SizedBox(height: 2),
            Text(
              address,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.4),
                fontSize: 14,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        );
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        // The card's own ground with a hairline (owner 2026-11-04: the neu
        // grey read as a different colour from the card).
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
      ),
      child: IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(
              width: 16,
              child: Column(
                children: [
                  const SizedBox(height: halfPad),
                  Container(
                    width: 11,
                    height: 11,
                    decoration: goldRingDot,
                    child: Center(
                      child: Container(
                        width: 4,
                        height: 4,
                        decoration: const BoxDecoration(
                          color: _gold,
                          shape: BoxShape.circle,
                        ),
                      ),
                    ),
                  ),
                  const Expanded(child: RouteConnectorLine()),
                  Container(width: 11, height: 11, decoration: whiteRing),
                  const SizedBox(height: halfPad),
                ],
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  stopText(pickupMeta, pickupAddr),
                  const SizedBox(height: 22),
                  stopText(dropoffMeta, dropoffAddr),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The Reservar pill under the card: the offer card's Aceptar, exactly as
/// wide as the card above it (owner 2026-11-04: "mismo ancho que la
/// tarjeta, no más grande").
class ReserveOfferButton extends StatefulWidget {
  const ReserveOfferButton({
    super.key,
    required this.label,
    required this.onTap,
    this.busy = false,
    this.resting = false,
  });

  final String label;
  final VoidCallback? onTap;
  final bool busy;

  /// The driver is on a mandatory rest: grey, the rest label.
  final bool resting;

  @override
  State<ReserveOfferButton> createState() => _ReserveOfferButtonState();
}

class _ReserveOfferButtonState extends State<ReserveOfferButton> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final enabled = !widget.busy && widget.onTap != null;
    return GestureDetector(
      key: const ValueKey('reserve-offer-button'),
      onTapDown: enabled ? (_) => setState(() => _pressed = true) : null,
      onTapUp: enabled
          ? (_) {
              setState(() => _pressed = false);
              widget.onTap!();
            }
          : null,
      onTapCancel: () => setState(() => _pressed = false),
      child: AnimatedScale(
        scale: _pressed ? 0.97 : 1.0,
        duration: const Duration(milliseconds: 100),
        child: Container(
          width: double.infinity,
          height: 54,
          decoration: BoxDecoration(
            color: widget.resting
                ? const Color(0xFF6B6B70)
                : widget.busy
                    ? _gold.withValues(alpha: 0.55)
                    : _gold,
            borderRadius: BorderRadius.circular(27),
          ),
          alignment: Alignment.center,
          child: widget.busy
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(
                    strokeWidth: 2.5,
                    valueColor: AlwaysStoppedAnimation(Colors.black),
                  ),
                )
              : Text(
                  widget.label,
                  style: TextStyle(
                    color: widget.resting ? Colors.white : Colors.black,
                    fontSize: 16,
                    fontWeight: FontWeight.w800,
                  ),
                ),
        ),
      ),
    );
  }
}
