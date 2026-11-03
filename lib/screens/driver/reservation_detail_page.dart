import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:intl/intl.dart' show DateFormat;

import '../../l10n/app_localizations.dart';
import '../../services/api_service.dart';
import '../../services/haptic_service.dart';
import '../../utils/name_helper.dart' as nh;
import '../../utils/server_time.dart';
import '../../utils/trip_stops.dart';
import '../../widgets/verified_avatar.dart';
import 'driver_menu_screen.dart' show showDriverHelpSheet;

/// The driver's own reservation, tapped from the gold card (owner
/// 2026-11-03, "una página encima… semitransparente borrosa"): a page laid
/// over the driver's screen in dark frosted glass, the screen behind showing
/// through soft — the price and the rider, the date, the plan-ahead note,
/// the ride's steps (go online by, pickup, stop, drop-off), more info, and
/// Cancel ride (back to the board, up to 1 hour before pickup).
///
/// [onCancelled] runs after a successful cancel (the caller refreshes its
/// card).
Future<void> showReservationDetail(
  BuildContext context,
  Map<String, dynamic> reservation, {
  VoidCallback? onCancelled,
}) {
  final nav = Navigator.maybeOf(context);
  if (nav == null) return Future.value();
  return nav.push(PageRouteBuilder<void>(
    opaque: false,
    barrierColor: Colors.transparent,
    transitionDuration: const Duration(milliseconds: 380),
    reverseTransitionDuration: const Duration(milliseconds: 320),
    pageBuilder: (_, __, ___) => ReservationDetailPage(
      reservation: reservation,
      onCancelled: onCancelled,
    ),
    transitionsBuilder: (_, anim, __, child) {
      final a = CurvedAnimation(parent: anim, curve: Curves.easeOutCubic);
      return FadeTransition(
        opacity: a,
        child: SlideTransition(
          position: Tween<Offset>(
                  begin: const Offset(0, 0.04), end: Offset.zero)
              .animate(a),
          child: child,
        ),
      );
    },
  ));
}

class ReservationDetailPage extends StatefulWidget {
  const ReservationDetailPage({
    super.key,
    required this.reservation,
    this.onCancelled,
  });

  final Map<String, dynamic> reservation;
  final VoidCallback? onCancelled;

  @override
  State<ReservationDetailPage> createState() => _ReservationDetailPageState();
}

class _ReservationDetailPageState extends State<ReservationDetailPage> {
  static const _gold = Color(0xFFE8C547);
  static const _red = Color(0xFFFF6B6B);

  /// The trip with the rider's name, photo and rating (the reservation list
  /// does not carry them).
  Map<String, dynamic>? _trip;
  bool _cancelling = false;

  Map<String, dynamic> get _r => {...widget.reservation, ...?_trip};

  @override
  void initState() {
    super.initState();
    final id = (widget.reservation['id'] as num?)?.toInt();
    if (id != null) {
      ApiService.getTrip(id, riderStats: true).then((t) {
        if (mounted) setState(() => _trip = t);
      }).catchError((Object e) {
        debugPrint('[ReservationDetail] trip load failed: $e');
      });
    }
  }

  String _time(DateTime t) => DateFormat('h:mm a', 'en_US').format(t);

  /// "Hoy · 3 nov a las 3:20 PM" / "Today · Nov 3 at 3:20 PM".
  String _dateLine(S s, DateTime at, String lang) {
    final now = DateTime.now();
    final day = DateTime(at.year, at.month, at.day);
    final today = DateTime(now.year, now.month, now.day);
    final diff = day.difference(today).inDays;
    final date = DateFormat(lang == 'es' ? "d 'de' MMM" : 'MMM d',
            lang == 'es' ? 'es' : 'en_US')
        .format(at);
    final lead = diff == 0
        ? s.resDetailToday
        : diff == 1
            ? s.resDetailTomorrow
            : DateFormat('EEEE', lang == 'es' ? 'es' : 'en_US').format(at);
    final leadCap =
        lead.isEmpty ? lead : lead[0].toUpperCase() + lead.substring(1);
    return '$leadCap · ${s.resDetailDateAt(date, _time(at))}';
  }

  Future<void> _cancel() async {
    final s = S.of(context);
    final id = (widget.reservation['id'] as num?)?.toInt();
    if (id == null || _cancelling) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF141414),
        surfaceTintColor: Colors.transparent,
        title: Text(s.resDetailCancelConfirm,
            style: const TextStyle(
                color: Colors.white, fontWeight: FontWeight.w700)),
        content: Text(s.resDetailCancelConfirmBody,
            style: TextStyle(color: Colors.white.withValues(alpha: 0.7))),
        actions: [
          TextButton(
            onPressed: () => Navigator.maybeOf(ctx)?.pop(false),
            child: Text(s.resDetailKeep,
                style: const TextStyle(color: Colors.white70)),
          ),
          TextButton(
            onPressed: () => Navigator.maybeOf(ctx)?.pop(true),
            child: Text(s.cancelRide,
                style: const TextStyle(
                    color: _red, fontWeight: FontWeight.w700)),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _cancelling = true);
    try {
      await ApiService.cancelScheduledTrip(id);
      if (!mounted) return;
      HapticService.mediumImpact();
      ScaffoldMessenger.maybeOf(context)
          ?.showSnackBar(SnackBar(content: Text(s.resDetailCancelled)));
      widget.onCancelled?.call();
      Navigator.maybeOf(context)?.pop();
    } catch (e) {
      debugPrint('[ReservationDetail] cancel failed: $e');
      if (!mounted) return;
      setState(() => _cancelling = false);
      final tooLate = e is ApiException && e.statusCode == 400;
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(
        content: Text(tooLate ? s.resDetailCancelTooLate : s.connectionError),
      ));
    }
  }

  void _showInfo(String title, String body) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF1A1A21),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(26)),
      ),
      builder: (ctx) => SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(22, 14, 22, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 40,
                  height: 5,
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.3),
                    borderRadius: BorderRadius.circular(3),
                  ),
                ),
              ),
              const SizedBox(height: 18),
              Text(title,
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 20,
                      fontWeight: FontWeight.w800)),
              const SizedBox(height: 12),
              Text(body,
                  style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.8),
                      fontSize: 15,
                      height: 1.45)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _band() => Container(
        height: 8,
        margin: const EdgeInsets.symmetric(vertical: 18),
        color: Colors.black.withValues(alpha: 0.28),
      );

  /// One step of the ride: ring on the left (filled for the drop-off), the
  /// rail down to the next one — dotted from "go online" to the pickup,
  /// solid along the ride.
  Widget _step({
    required String title,
    String? sub,
    required bool last,
    bool filled = false,
    bool dottedBelow = false,
  }) {
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            width: 28,
            child: Column(
              children: [
                const SizedBox(height: 3),
                Container(
                  width: 20,
                  height: 20,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(color: _gold, width: 3),
                    color: filled ? _gold.withValues(alpha: 0.9) : null,
                  ),
                  child: filled
                      ? Center(
                          child: Container(
                            width: 7,
                            height: 7,
                            decoration: const BoxDecoration(
                                shape: BoxShape.circle, color: Colors.black),
                          ),
                        )
                      : null,
                ),
                if (!last)
                  Expanded(
                    child: dottedBelow
                        ? CustomPaint(
                            painter: _DottedRail(_gold.withValues(alpha: 0.7)),
                            size: Size.infinite,
                          )
                        : Container(
                            width: 3,
                            color: _gold.withValues(alpha: 0.7),
                          ),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Padding(
              padding: EdgeInsets.only(bottom: last ? 0 : 22),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title,
                      style: const TextStyle(
                          color: Colors.white,
                          fontSize: 17,
                          fontWeight: FontWeight.w600)),
                  if (sub != null && sub.trim().isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(sub,
                        style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.7),
                            fontSize: 14.5)),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _infoRow(String title, String? sub, VoidCallback onTap,
      {required Key key}) {
    return InkWell(
      key: key,
      onTap: () {
        HapticService.selectionClick();
        onTap();
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 14),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title,
                      style: const TextStyle(
                          color: Colors.white,
                          fontSize: 17,
                          fontWeight: FontWeight.w500)),
                  if (sub != null) ...[
                    const SizedBox(height: 2),
                    Text(sub,
                        style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.6),
                            fontSize: 14)),
                  ],
                ],
              ),
            ),
            Icon(Icons.chevron_right_rounded,
                color: Colors.white.withValues(alpha: 0.75), size: 28),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final lang = Localizations.localeOf(context).languageCode;
    final mq = MediaQuery.of(context);
    final r = _r;
    final at = parseServerTime(r['scheduled_at']);
    final goBy = at?.subtract(const Duration(hours: 1));
    final fare = (r['fare'] as num?)?.toDouble() ?? 0;
    final rider = nh.shortName((r['rider_name'] ?? '').toString());
    final firstName = rider.split(' ').first;
    final rating = (r['rider_rating'] as num?)?.toDouble();
    final photo = (r['rider_photo_url'] ?? '').toString();
    final stop = parseTripStop(r);

    return Material(
      type: MaterialType.transparency,
      child: Stack(
        children: [
          // Frosted glass over the driver's screen: it shows through, soft
          // and dark, never readable.
          Positioned.fill(
            child: BackdropFilter(
              filter: ui.ImageFilter.blur(sigmaX: 30, sigmaY: 30),
              child: const ColoredBox(color: Color(0xDB14141A)),
            ),
          ),
          SafeArea(
            bottom: false,
            child: ListView(
              key: const ValueKey('reservation-detail'),
              padding: EdgeInsets.fromLTRB(22, 10, 22, mq.padding.bottom + 28),
              children: [
                Align(
                  alignment: Alignment.centerLeft,
                  child: GestureDetector(
                    key: const ValueKey('reservation-detail-close'),
                    onTap: () => Navigator.maybeOf(context)?.pop(),
                    child: Container(
                      width: 52,
                      height: 52,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: Colors.white.withValues(alpha: 0.12),
                      ),
                      child: const Icon(Icons.close_rounded,
                          color: Colors.white, size: 28),
                    ),
                  ),
                ),
                const SizedBox(height: 18),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Text(
                        firstName.isEmpty
                            ? '\$${fare.toStringAsFixed(2)} Cruise'
                            : '\$${fare.toStringAsFixed(2)} Cruise\n${s.resDetailWith(firstName)}',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 30,
                          fontWeight: FontWeight.w800,
                          height: 1.2,
                        ),
                      ),
                    ),
                    if (_trip != null)
                      Container(
                        padding: const EdgeInsets.fromLTRB(4, 4, 14, 4),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(999),
                          color: Colors.white.withValues(alpha: 0.1),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            VerifiedAvatar(
                              photoUrl: photo.isEmpty ? null : photo,
                              radius: 20,
                              fallbackName: rider,
                              role: 'rider',
                            ),
                            if (rating != null) ...[
                              const SizedBox(width: 8),
                              const Icon(Icons.star_rounded,
                                  color: Colors.white, size: 18),
                              const SizedBox(width: 3),
                              Text(rating.toStringAsFixed(1),
                                  style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 16,
                                      fontWeight: FontWeight.w600)),
                            ],
                          ],
                        ),
                      ),
                  ],
                ),
                if (at != null) ...[
                  const SizedBox(height: 12),
                  Text(_dateLine(s, at, lang),
                      style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.85),
                          fontSize: 16)),
                ],
                const SizedBox(height: 22),
                Row(
                  children: [
                    Icon(Icons.payments_outlined,
                        color: Colors.white.withValues(alpha: 0.9), size: 26),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(s.resDetailPlanTitle,
                              style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 16,
                                  fontWeight: FontWeight.w600)),
                          Text(s.resDetailPlanSub,
                              style: TextStyle(
                                  color: Colors.white.withValues(alpha: 0.6),
                                  fontSize: 14)),
                        ],
                      ),
                    ),
                  ],
                ),
                _band(),
                Text(s.resDetailRideDetails,
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 26,
                        fontWeight: FontWeight.w800)),
                const SizedBox(height: 16),
                if (goBy != null)
                  _step(
                    title: s.goOnlineBy(_time(goBy)),
                    sub: s.resDetailGoOnlineSub,
                    last: false,
                    dottedBelow: true,
                  ),
                _step(
                  title: at == null
                      ? s.trackPickup
                      : s.resDetailPickupAt(_time(at)),
                  sub: (r['pickup_address'] ?? '').toString(),
                  last: false,
                ),
                if (stop != null)
                  _step(title: s.trackStop, sub: stop.label, last: false),
                _step(
                  title: s.trackDestination,
                  sub: (r['dropoff_address'] ?? '').toString(),
                  last: true,
                  filled: true,
                ),
                _band(),
                Text(s.resDetailMoreInfo,
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 26,
                        fontWeight: FontWeight.w800)),
                const SizedBox(height: 6),
                _infoRow(
                  s.resDetailHowTo,
                  null,
                  () => _showInfo(s.resDetailHowTo,
                      s.resDetailHowToBody(goBy == null ? '—' : _time(goBy))),
                  key: const ValueKey('res-how-to'),
                ),
                _infoRow(
                  s.resDetailCancelPolicy,
                  s.resDetailCancelPolicySub,
                  () => _showInfo(
                      s.resDetailCancelPolicy, s.resDetailCancelPolicyBody),
                  key: const ValueKey('res-cancel-policy'),
                ),
                _infoRow(
                  s.resDetailFaq,
                  s.resDetailFaqSub,
                  () => showDriverHelpSheet(context),
                  key: const ValueKey('res-faq'),
                ),
                const SizedBox(height: 26),
                GestureDetector(
                  key: const ValueKey('res-cancel'),
                  onTap: _cancelling ? null : _cancel,
                  child: Container(
                    height: 58,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(999),
                      color: Colors.white.withValues(alpha: 0.10),
                    ),
                    alignment: Alignment.center,
                    child: _cancelling
                        ? const SizedBox(
                            width: 22,
                            height: 22,
                            child: CircularProgressIndicator(
                                strokeWidth: 2.4, color: _red),
                          )
                        : Text(s.cancelRide,
                            style: const TextStyle(
                                color: _red,
                                fontSize: 18,
                                fontWeight: FontWeight.w700)),
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

/// The dotted rail from "go online by" down to the pickup.
class _DottedRail extends CustomPainter {
  _DottedRail(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()..color = color;
    final x = size.width / 2;
    for (double y = 6; y < size.height - 2; y += 8) {
      canvas.drawCircle(Offset(x, y), 1.6, p);
    }
  }

  @override
  bool shouldRepaint(covariant _DottedRail old) => old.color != color;
}
