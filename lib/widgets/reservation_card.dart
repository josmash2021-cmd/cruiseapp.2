import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../services/place_ranking.dart' show withoutCountry;
import '../utils/name_helper.dart' as nh;
import '../utils/vehicle_tier_style.dart';
import 'neu_style.dart';
import 'route_connector_line.dart';
import 'user_profile_photo.dart';

/// The rider's reservation card — ONE component on Inicio and on Programar
/// (owner 2026-11-08, Lyft-style, drawing
/// https://claude.ai/artifact/KzawVoUMMVyLpHnKS7r7UU): when, from where to
/// where, the car and price, and who is coming once a driver has it.

const _gold = Color(0xFFE8C547);

/// "BHM · Birmingham-Shuttlesworth … — Delta Air Lines" → (place, airline);
/// "3659 Lorna Rd, Hoover, AL, USA" → ("3659 Lorna Rd", "Hoover, AL").
(String, String) splitBookedAddress(String address) {
  final a = address.trim();
  final dash = a.indexOf(' — ');
  if (dash > 0) return (a.substring(0, dash).trim(), a.substring(dash + 3).trim());
  final comma = a.indexOf(',');
  if (comma > 0) {
    return (
      a.substring(0, comma).trim(),
      withoutCountry(a.substring(comma + 1).trim()),
    );
  }
  return (a, '');
}

/// A `/trips/scheduled/rider` row as the cards read it.
class Reservation {
  final Map<String, dynamic> trip;
  final int? id;

  /// Local time of the pickup.
  final DateTime at;
  final String pickupAddress;
  final String dropoffAddress;
  final double? pickupLat;
  final double? pickupLng;
  final double? dropoffLat;
  final double? dropoffLng;
  final String vehicleType;
  final double? fare;
  final bool isAirport;

  /// "Jhon M." — empty until a driver has the reservation.
  final String driverName;
  final String driverPhotoUrl;
  final double? driverRating;

  /// "Toyota Camry · ABC1234" — empty when the server sent no car.
  final String carLine;

  const Reservation._({
    required this.trip,
    required this.id,
    required this.at,
    required this.pickupAddress,
    required this.dropoffAddress,
    required this.pickupLat,
    required this.pickupLng,
    required this.dropoffLat,
    required this.dropoffLng,
    required this.vehicleType,
    required this.fare,
    required this.isAirport,
    required this.driverName,
    required this.driverPhotoUrl,
    required this.driverRating,
    required this.carLine,
  });

  /// The driver is whoever holds `driver_id` — the status words vary by
  /// flow, the id does not.
  bool get hasDriver => trip['driver_id'] != null;

  /// A reservation under way — the driver confirmed and is driving, waiting
  /// or riding. It stays on Inicio and Programar until it ends, whatever
  /// the clock says: a driver who came early is still waiting after the
  /// booked time passes.
  static const liveStatuses = {
    'accepted', 'driver_assigned', 'driver_en_route', 'en_route',
    'en_route_to_pickup', 'driver_arriving', 'arriving', 'arrived',
    'driver_arrived', 'in_trip', 'in_progress',
  };

  static bool isLiveTrip(Map<String, dynamic> t) =>
      liveStatuses.contains((t['status'] ?? '').toString().toLowerCase());

  bool get isLive => isLiveTrip(trip);

  /// Compact / Standard / Electric Pro / Premium / VIP, as the booking
  /// sheet named it (trip rows keep the booking option's name).
  String get tierLabel {
    final k = tripTierKey(vehicleType);
    if (k == kTierElectricPro) return 'Electric Pro';
    if (k == kTierVip) return 'VIP';
    return k[0].toUpperCase() + k.substring(1);
  }

  String get carAsset => tierCarImage(tripTierKey(vehicleType));

  /// The server stores UTC; a zone-less timestamp is UTC too, never the
  /// phone's local time.
  static DateTime? parseAt(dynamic raw) {
    final s = raw?.toString() ?? '';
    if (s.isEmpty) return null;
    final dt = DateTime.tryParse(s);
    if (dt == null) return null;
    final utc = dt.isUtc
        ? dt
        : DateTime.utc(dt.year, dt.month, dt.day, dt.hour, dt.minute,
            dt.second);
    return utc.toLocal();
  }

  static Reservation? fromTrip(Map<String, dynamic> t) {
    final at = parseAt(t['scheduled_at']);
    if (at == null) return null;
    double? d(String k) => (t[k] as num?)?.toDouble();
    final make = '${t['vehicle_make'] ?? ''} ${t['vehicle_model'] ?? ''}'
        .trim();
    final plate = (t['vehicle_plate'] ?? '').toString().trim();
    return Reservation._(
      trip: t,
      id: (t['id'] as num?)?.toInt(),
      at: at,
      pickupAddress: (t['pickup_address'] ?? '').toString().trim(),
      dropoffAddress: (t['dropoff_address'] ?? '').toString().trim(),
      pickupLat: d('pickup_lat'),
      pickupLng: d('pickup_lng'),
      dropoffLat: d('dropoff_lat'),
      dropoffLng: d('dropoff_lng'),
      vehicleType: (t['vehicle_type'] ?? '').toString(),
      fare: d('fare'),
      isAirport: t['is_airport'] == true ||
          (t['airport_code'] ?? '').toString().isNotEmpty,
      driverName: nh.shortName((t['driver_name'] ?? '').toString()),
      driverPhotoUrl: (t['driver_photo_url'] ?? '').toString(),
      driverRating: d('driver_rating'),
      carLine: [make, plate].where((p) => p.isNotEmpty).join(' · '),
    );
  }
}

enum ReservationCardStyle {
  /// Inicio: "Próxima reserva", the day in the title, a countdown in the
  /// last hour, "Ver las N" with more than one.
  home,

  /// Programar: the day as the label, the time as the title.
  list,
}

class ReservationCard extends StatelessWidget {
  const ReservationCard({
    super.key,
    required this.reservation,
    this.style = ReservationCardStyle.list,
    this.count = 1,
    this.onTap,
    this.onSeeAll,
    this.now,
  });

  final Reservation reservation;
  final ReservationCardStyle style;

  /// How many reservations the rider has (home's "Ver las N").
  final int count;
  final VoidCallback? onTap;
  final VoidCallback? onSeeAll;

  /// The clock the card reads — tests pin it.
  final DateTime? now;

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final r = reservation;
    final now = this.now ?? DateTime.now();
    final home = style == ReservationCardStyle.home;
    final minsAway = r.at.difference(now).inMinutes;
    final soon = home && minsAway >= 0 && minsAway <= 60;
    final rel = s.reservationRelDay(r.at, now);
    final clock = s.bookedClock(r.at);
    final fare = r.fare;

    // Top right: the countdown in the last hour, otherwise the status.
    final String label;
    final String title;
    if (home) {
      label = soon || r.isLive ? s.yourReservation : s.nextReservation;
      title = '${rel ?? s.reservationDate(r.at)} · $clock';
    } else {
      label = rel != null ? '$rel · ${s.reservationDate(r.at)}' : s.reservationDate(r.at);
      title = clock;
    }
    final status = ReservationStatusPill(
      hasDriver: r.hasDriver,
      label: r.hasDriver
          ? (home ? s.reservationConfirmed : s.reservationDriverAssigned)
          : s.findingDriverLabel,
    );
    final Widget trailing = soon
        ? _CountdownChip(s.reservationInMinutes(minsAway < 1 ? 1 : minsAway))
        : status;

    // Bottom right: "Ver las N" — or, counting down with nobody yet, the
    // status the countdown took the corner from.
    Widget? footerEnd;
    if (soon && !r.hasDriver) {
      footerEnd = status;
    } else if (home && count > 1) {
      footerEnd = GestureDetector(
        key: const ValueKey('reservation-see-all'),
        behavior: HitTestBehavior.opaque,
        onTap: onSeeAll,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                s.seeAllReservations(count),
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.7),
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                ),
              ),
              Icon(Icons.chevron_right_rounded,
                  size: 18, color: Colors.white.withValues(alpha: 0.7)),
            ],
          ),
        ),
      );
    }

    final Widget who = r.hasDriver
        ? ReservationDriverRow(
            reservation: r,
            subtitle: r.carLine.isNotEmpty ? r.carLine : r.tierLabel,
          )
        : Row(
            children: [
              SizedBox(
                width: 58,
                height: 24,
                child: Image.asset(
                  r.carAsset,
                  fit: BoxFit.contain,
                  errorBuilder: (_, __, ___) => Image.asset(
                    'assets/images/cruisert3.png',
                    fit: BoxFit.contain,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Flexible(
                child: Text(
                  r.tierLabel,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.75),
                    fontSize: 13.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          );

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
        decoration: neuBox(radius: 20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    label.toUpperCase(),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: _gold,
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 1.1,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                trailing,
              ],
            ),
            const SizedBox(height: 2),
            Row(
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                Expanded(
                  child: Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 24,
                      fontWeight: FontWeight.w800,
                      letterSpacing: -0.3,
                      height: 1.2,
                    ),
                  ),
                ),
                if (fare != null && fare > 0)
                  Text(
                    '\$${fare.toStringAsFixed(2)}',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
              decoration: neuBox(radius: 14, pressed: true),
              child: ReservationRail(
                pickup: r.pickupAddress,
                dropoff: r.dropoffAddress,
                gap: 8,
                titleMaxLines: 1,
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(child: who),
                if (footerEnd != null) ...[
                  const SizedBox(width: 8),
                  footerEnd,
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Pickup → drop-off on the app's rail: gold ring with a dot, the
/// gold→white connector, a white ring; each stop as place + line.
class ReservationRail extends StatelessWidget {
  const ReservationRail({
    super.key,
    required this.pickup,
    required this.dropoff,
    this.gap = 14,
    this.titleMaxLines = 2,
  });

  final String pickup;
  final String dropoff;

  /// Space between the two stops.
  final double gap;

  /// The cards keep each place to one line; the reservation page shows it
  /// whole.
  final int titleMaxLines;

  @override
  Widget build(BuildContext context) {
    final (pickTitle, pickSub) = splitBookedAddress(pickup);
    final (dropTitle, dropSub) = splitBookedAddress(dropoff);
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            width: 20,
            child: Column(
              children: [
                const SizedBox(height: 4),
                _ring(pickup: true),
                const Expanded(
                  child: Padding(
                    padding: EdgeInsets.symmetric(vertical: 2),
                    child: RouteConnectorLine(),
                  ),
                ),
                _ring(pickup: false),
                SizedBox(height: dropSub.isEmpty ? 4 : 18),
              ],
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _place(pickTitle, pickSub),
                SizedBox(height: gap),
                _place(dropTitle, dropSub),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _ring({required bool pickup}) {
    final color = pickup ? _gold : Colors.white;
    return Container(
      width: 13,
      height: 13,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.fromBorderSide(BorderSide(color: color, width: 1.8)),
      ),
      alignment: Alignment.center,
      child: pickup
          ? Container(
              width: 5,
              height: 5,
              decoration:
                  const BoxDecoration(color: _gold, shape: BoxShape.circle),
            )
          : null,
    );
  }

  Widget _place(String title, String sub) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          maxLines: titleMaxLines,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 14.5,
            fontWeight: FontWeight.w600,
          ),
        ),
        if (sub.isNotEmpty)
          Text(
            sub,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.55),
              fontSize: 12.5,
            ),
          ),
      ],
    );
  }
}

/// "Buscando conductor" (a breathing gold dot) or a gold "✓ Conductor
/// asignado" — the check is an icon: the font may not carry the glyph.
class ReservationStatusPill extends StatefulWidget {
  const ReservationStatusPill({
    super.key,
    required this.hasDriver,
    required this.label,
  });

  final bool hasDriver;
  final String label;

  @override
  State<ReservationStatusPill> createState() => _ReservationStatusPillState();
}

class _ReservationStatusPillState extends State<ReservationStatusPill>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1400),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final still = MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    if (!widget.hasDriver && !still) {
      if (!_pulse.isAnimating) _pulse.repeat(reverse: true);
    } else {
      _pulse.stop();
    }
  }

  @override
  void didUpdateWidget(ReservationStatusPill old) {
    super.didUpdateWidget(old);
    if (widget.hasDriver != old.hasDriver) didChangeDependencies();
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final assigned = widget.hasDriver;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: assigned ? _gold : Colors.white.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (assigned)
            const Icon(Icons.check_rounded, size: 13, color: Colors.black)
          else
            FadeTransition(
              opacity: Tween<double>(begin: 1, end: 0.25).animate(_pulse),
              child: Container(
                width: 7,
                height: 7,
                decoration:
                    const BoxDecoration(color: _gold, shape: BoxShape.circle),
              ),
            ),
          const SizedBox(width: 6),
          Text(
            widget.label,
            style: TextStyle(
              color: assigned ? Colors.black : Colors.white.withValues(alpha: 0.9),
              fontSize: 11.5,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

/// The driver who has the reservation: photo (or initials) in a gold ring,
/// "Jhon M.", and one line under it.
class ReservationDriverRow extends StatelessWidget {
  const ReservationDriverRow({
    super.key,
    required this.reservation,
    required this.subtitle,
    this.size = 38,
  });

  final Reservation reservation;
  final String subtitle;
  final double size;

  @override
  Widget build(BuildContext context) {
    final r = reservation;
    final rating = r.driverRating;
    return Row(
      children: [
        Container(
          width: size,
          height: size,
          padding: const EdgeInsets.all(2),
          decoration: const BoxDecoration(
            shape: BoxShape.circle,
            color: _gold,
          ),
          child: UserProfilePhoto(
            photoUrl: r.driverPhotoUrl.isEmpty ? null : r.driverPhotoUrl,
            radius: size / 2 - 2,
            fallbackName: r.driverName,
            noBorder: true,
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Flexible(
                    child: Text(
                      r.driverName.isEmpty ? '—' : r.driverName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  if (rating != null) ...[
                    const SizedBox(width: 6),
                    const Icon(Icons.star_rounded, size: 14, color: _gold),
                    Text(
                      rating.toStringAsFixed(1),
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.75),
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ],
              ),
              Text(
                subtitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.6),
                  fontSize: 12,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _CountdownChip extends StatelessWidget {
  const _CountdownChip(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const ValueKey('reservation-countdown'),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: _gold.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: _gold.withValues(alpha: 0.45)),
      ),
      child: Text(
        text,
        style: const TextStyle(
          color: _gold,
          fontSize: 11.5,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}
