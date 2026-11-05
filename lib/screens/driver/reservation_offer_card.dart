import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../models/lat_lng.dart';
import '../../utils/name_helper.dart' as nh;
import '../../utils/offer_metrics.dart';
import '../../widgets/route_connector_line.dart';

const _gold = Color(0xFFE8C547);

/// The offer cards' ground (owner 2026-11-04, "coloca todos de ese color
/// fondo para las tarjetas de oferta"): the near-black of the reservations
/// map's old floating card, #0B0B0F at 95 %.
const Color kOfferCardBg = Color(0xF20B0B0F);

/// A reservation on the reservations map (owner 2026-11-04, final: "la
/// tarjeta debe verse así" — Lyft's scheduled-ride card — "pero sin la
/// imagen del rider, con el est rate for this ride, y el reserved del lado
/// derecho donde está el precio más tips, y el tomorrow y hora en dorado";
/// the rail keeps the offer card's markers and colours): the fare with
/// "+ Propinas", the hourly rate under it and RESERVADO on the right; the
/// pickup's day and time in gold over its address and the ride's minutes
/// and miles over the drop-off, on the offer card's rail (gold ring with a
/// dot, the gold-to-white line, the white ring); the rider ("Nombre I.")
/// with Verificado in gold and ★. Ground: the offer cards' #0B0B0F.
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

  /// Where the driver is now: the hourly rate counts the drive to the
  /// pickup, as on an offer.
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
    final awayMin =
        here == null ? 0 : offerLegMinutes(km: _havKm(here, pickup));
    final hourly = offerPayPerHour(fare, offerTotalMinutes(awayMin, tripMin));

    final short = nh.shortName((trip['rider_name'] ?? '').toString());
    final riderName = short.isNotEmpty ? short : s.riderFallback;
    final rating = _num(trip['rider_rating']);
    final verified = trip['rider_verified'] == true;
    final hairline =
        Container(height: 1, color: Colors.white.withValues(alpha: 0.08));

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
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          // ── The pay, the hourly rate, and RESERVADO on the right ──
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 16, 18, 14),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // Shrinks rather than overflows beside a wide badge.
                      FittedBox(
                        fit: BoxFit.scaleDown,
                        alignment: Alignment.centerLeft,
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
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
                            const SizedBox(width: 10),
                            Text(
                              s.plusTips,
                              style: const TextStyle(
                                color: _gold,
                                fontSize: 15,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        s.offerHourlyRate(hourly.toStringAsFixed(2)),
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.85),
                          fontSize: 12.5,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 10),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _badge(s.badgeReserved, Icons.schedule_rounded, _gold),
                    if (isAirport) ...[
                      const SizedBox(height: 6),
                      _badge(s.badgeAirport, Icons.flight_takeoff_rounded,
                          const Color(0xFF3B82F6)),
                    ],
                    if (isCash) ...[
                      const SizedBox(height: 6),
                      _badge(s.badgeCash, Icons.payments_rounded,
                          const Color(0xFF10B981)),
                    ],
                  ],
                ),
              ],
            ),
          ),
          hairline,
          // ── Pickup (its day and time in gold) over the drop-off ──
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 16, 18, 16),
            child: _rail(
              pickupTitle: whenLabel,
              pickupAddr: (trip['pickup_address'] ?? '').toString(),
              dropTitle: '$tripMin min · ${tripMi.toStringAsFixed(1)} mi',
              dropAddr: (trip['dropoff_address'] ?? '').toString(),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 18),
            child: hairline,
          ),
          // ── Who is riding: no photo; Verificado and ★ on the right, as on
          // the offer card (owner 2026-11-04, "a la derecha como estaba") ──
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 14, 18, 16),
            child: Row(
              children: [
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
                  // Gold, never the blue (owner 2026-11-04).
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
          ),
        ],
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

  /// The offer card's rail at the Lyft card's size (owner 2026-11-04,
  /// "esto mantienes el mismo diseño y color"): a gold ring with a dot at
  /// the pickup, the gold-to-white line, a white ring at the drop-off; each
  /// marker level with its title.
  static Widget _rail({
    required String pickupTitle,
    required String pickupAddr,
    required String dropTitle,
    required String dropAddr,
  }) {
    const marker = 13.0;
    const top = 5.0;
    Widget text(String title, String sub, {Color titleColor = Colors.white}) =>
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (title.isNotEmpty)
              Text(title,
                  style: TextStyle(
                      color: titleColor,
                      fontSize: 16,
                      fontWeight: FontWeight.w500)),
            Text(sub,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.6), fontSize: 15)),
          ],
        );
    final pickupRing = Container(
      width: marker,
      height: marker,
      decoration: const BoxDecoration(
        shape: BoxShape.circle,
        border: Border.fromBorderSide(BorderSide(color: _gold, width: 1.8)),
      ),
      alignment: Alignment.center,
      child: Container(
        width: 5,
        height: 5,
        decoration: const BoxDecoration(color: _gold, shape: BoxShape.circle),
      ),
    );
    final dropRing = Container(
      width: marker,
      height: marker,
      decoration: const BoxDecoration(
        shape: BoxShape.circle,
        border:
            Border.fromBorderSide(BorderSide(color: Colors.white, width: 1.8)),
      ),
    );
    return Column(
      children: [
        IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(
                width: 20,
                child: Column(
                  children: [
                    const SizedBox(height: top),
                    pickupRing,
                    const Expanded(child: RouteConnectorLine()),
                  ],
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.only(bottom: 14),
                  child: text(pickupTitle, pickupAddr, titleColor: _gold),
                ),
              ),
            ],
          ),
        ),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 20,
              child: Column(
                children: [
                  // The line runs on to the white ring.
                  Container(width: 2, height: top, color: Colors.white),
                  dropRing,
                ],
              ),
            ),
            const SizedBox(width: 14),
            Expanded(child: text(dropTitle, dropAddr)),
          ],
        ),
      ],
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
