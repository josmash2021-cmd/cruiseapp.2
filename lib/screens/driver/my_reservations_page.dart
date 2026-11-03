import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart' show DateFormat;
import 'package:shared_preferences/shared_preferences.dart';

import '../../l10n/app_localizations.dart';
import '../../services/api_service.dart';
import '../../services/haptic_service.dart';
import '../../services/notification_service.dart';
import '../../services/scheduled_board_watcher.dart';
import '../../utils/friendly_load_error.dart';
import '../../utils/name_helper.dart' as nh;
import '../../utils/server_time.dart';
import '../../utils/vehicle_tier_style.dart';
import '../../widgets/neu_style.dart';
import '../../widgets/tracking/rider_trip_sheet.dart' show RiderStopPin;
import '../../widgets/verified_avatar.dart';
import 'reservation_detail_page.dart';
import 'scheduled_ride_details_screen.dart';

const _kGold = Color(0xFFE8C547);
const _kFade = Duration(milliseconds: 420);
const _kNoteHiddenKey = 'my_res_note_hidden';

// Tables instead of DateFormat: the project never calls
// initializeDateFormatting, so a Spanish-locale DateFormat throws.
const _kMonthsEn = [
  'Jan',
  'Feb',
  'Mar',
  'Apr',
  'May',
  'Jun',
  'Jul',
  'Aug',
  'Sep',
  'Oct',
  'Nov',
  'Dec',
];
const _kMonthsEs = [
  'ene',
  'feb',
  'mar',
  'abr',
  'may',
  'jun',
  'jul',
  'ago',
  'sep',
  'oct',
  'nov',
  'dic',
];
const _kDaysEn = [
  'Monday',
  'Tuesday',
  'Wednesday',
  'Thursday',
  'Friday',
  'Saturday',
  'Sunday',
];
const _kDaysEs = [
  'Lunes',
  'Martes',
  'Miércoles',
  'Jueves',
  'Viernes',
  'Sábado',
  'Domingo',
];

/// The rows "Mis Reservas" lists, in pickup order — also what the
/// reservations map counts in "Tus viajes (N)", so the two never disagree.
/// Held by this driver (claimed, or confirmed and on the way), not more
/// than 2 h past, and a real reservation: a web booking "for now" also
/// carries scheduled_at, so only one booked at least 3 minutes ahead counts
/// (same rule as the trip screen).
List<Map<String, dynamic>> myReservationRows(
    List<Map<String, dynamic>> all, DateTime now) {
  const held = {'scheduled_accepted', 'scheduled_active', 'driver_en_route'};
  return all.where((t) {
    final st = (t['status'] ?? '').toString();
    final at = parseServerTime(t['scheduled_at']);
    if (!held.contains(st) || at == null) return false;
    final created = parseServerTime(t['created_at']);
    if (created != null && at.isBefore(created.add(const Duration(minutes: 3)))) {
      return false;
    }
    return at.isAfter(now.subtract(const Duration(hours: 2)));
  }).toList()
    ..sort((a, b) => parseServerTime(a['scheduled_at'])!
        .compareTo(parseServerTime(b['scheduled_at'])!));
}

/// The driver's own reserved rides (owner-approved drawing 2026-11-03,
/// Lyft's Ride Finder cards): one card per reservation, by time — when it
/// is, the pay, the go-online deadline, pickup and drop-off, stops, the
/// rider and the ride type. "Ver detalles" opens the reservation's glass
/// page (cancel lives there); a ride already confirmed (EN CAMINO) goes
/// to the pickup instead. Taking new reservations is the map's job.
class MyReservationsPage extends StatefulWidget {
  const MyReservationsPage({super.key});

  @override
  State<MyReservationsPage> createState() => _MyReservationsPageState();
}

class _MyReservationsPageState extends State<MyReservationsPage> {
  List<Map<String, dynamic>> _trips = [];
  bool _loading = true;
  bool _fetching = false;
  bool _reloadQueued = false;
  String? _error;
  bool _noteHidden = false;

  /// Reservations that just left (released, cancelled, reassigned): they
  /// fade out, quietly, before the list closes over them.
  final Set<Object?> _leaving = {};
  Timer? _clock;

  @override
  void initState() {
    super.initState();
    NotificationService.scheduledRideRefreshNotifier.addListener(_onBoard);
    // Live board: a change anywhere refreshes this page at once.
    ScheduledBoardWatcher.acquire();
    // "en 3 h 25 min" keeps counting.
    _clock = Timer.periodic(const Duration(minutes: 1), (_) {
      if (mounted) setState(() {});
    });
    unawaited(_restoreNote());
    unawaited(_load());
  }

  @override
  void dispose() {
    NotificationService.scheduledRideRefreshNotifier.removeListener(_onBoard);
    ScheduledBoardWatcher.release();
    _clock?.cancel();
    super.dispose();
  }

  void _onBoard() => unawaited(_load());

  Future<void> _restoreNote() async {
    try {
      final p = await SharedPreferences.getInstance();
      if (mounted && p.getBool(_kNoteHiddenKey) == true) {
        setState(() => _noteHidden = true);
      }
    } catch (_) {}
  }

  Future<void> _hideNote() async {
    setState(() => _noteHidden = true);
    try {
      final p = await SharedPreferences.getInstance();
      await p.setBool(_kNoteHiddenKey, true);
    } catch (_) {}
  }

  Future<void> _load() async {
    if (_fetching) {
      // A refresh asked for mid-load (a cancel, the live board) must not
      // be dropped: it runs once this one ends.
      _reloadQueued = true;
      return;
    }
    _fetching = true;
    try {
      final uid = await ApiService.getCurrentUserId();
      if (uid == null) {
        if (mounted) setState(() => _loading = false);
        return;
      }
      final all = await ApiService.getDriverScheduledTrips(uid);
      if (!mounted) return;
      final fresh = myReservationRows(all, DateTime.now());
      final ids = fresh.map((t) => t['id']).toSet();
      final gone = _trips.where((t) => !ids.contains(t['id'])).toList();
      setState(() {
        _error = null; // data arrived
        _loading = false;
        // One that came back is no longer on its way out.
        _leaving.removeAll(ids);
        if (gone.isEmpty) {
          _trips = fresh;
        } else {
          // Keep the vanished ones a moment, fading, then close the gap.
          _leaving.addAll(gone.map((t) => t['id']));
          _trips = [...fresh, ...gone]..sort((a, b) =>
              parseServerTime(a['scheduled_at'])!
                  .compareTo(parseServerTime(b['scheduled_at'])!));
        }
      });
      if (gone.isNotEmpty) {
        Future.delayed(_kFade, () {
          if (!mounted) return;
          // Only the ones still leaving: a later load may have brought one
          // back, or added new ones this load never saw.
          final drop = gone.map((t) => t['id']).where(_leaving.contains).toSet();
          setState(() {
            _trips = _trips.where((t) => !drop.contains(t['id'])).toList();
            _leaving.removeAll(drop);
          });
        });
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        if (_trips.isEmpty) _error = friendlyLoadError(context, e);
      });
    } finally {
      _fetching = false;
      if (_reloadQueued && mounted) {
        _reloadQueued = false;
        unawaited(_load());
      }
    }
  }

  // ── Time words ──

  String _time(DateTime t) => DateFormat('h:mm a', 'en_US').format(t);

  /// "Hoy · 3:20 PM · en 3 h 25 min" / "Mañana · 7:40 AM" /
  /// "Jueves 5 de nov · 7:40 AM".
  String _whenLine(S s, DateTime at, bool isEs) {
    final now = DateTime.now();
    final diff = DateTime(at.year, at.month, at.day)
        .difference(DateTime(now.year, now.month, now.day))
        .inDays;
    final String day;
    if (diff == 0) {
      day = s.resDetailToday;
    } else if (diff == 1) {
      day = s.resDetailTomorrow;
    } else {
      final wd = (isEs ? _kDaysEs : _kDaysEn)[at.weekday - 1];
      day = isEs
          ? '$wd ${at.day} de ${_kMonthsEs[at.month - 1]}'
          : '$wd, ${_kMonthsEn[at.month - 1]} ${at.day}';
    }
    var line = '$day · ${_time(at)}';
    final left = at.difference(now);
    if (diff == 0 && left.inMinutes > 0) {
      final h = left.inHours;
      final m = left.inMinutes % 60;
      final dur = h == 0 ? '$m min' : (m == 0 ? '$h h' : '$h h $m min');
      line += ' · ${s.myResIn(dur)}';
    }
    return line;
  }

  static String _tierName(Object? vehicleType) {
    switch (tierKey(vehicleType?.toString())) {
      case 'vip':
        return 'VIP';
      case 'premium':
        return 'Premium';
      case kTierElectricPro:
        return 'Electric Pro';
      case 'compact':
        return 'Compact';
      default:
        return 'Standard';
    }
  }

  static int _stopCount(Object? raw) {
    try {
      final list = raw is String ? jsonDecode(raw) : raw;
      return list is List ? list.length : 0;
    } catch (_) {
      return 0;
    }
  }

  // ── Actions ──

  void _openDetails(Map<String, dynamic> trip) {
    HapticService.selectionClick();
    unawaited(showReservationDetail(context, trip, onCancelled: _load));
  }

  Future<void> _navigate(Map<String, dynamic> trip) async {
    HapticService.selectionClick();
    final at = parseServerTime(trip['scheduled_at']);
    final minutes =
        at == null ? 0.0 : at.difference(DateTime.now()).inSeconds / 60.0;
    await Navigator.maybeOf(context)?.push(PageRouteBuilder<String>(
      pageBuilder: (_, __, ___) =>
          ScheduledRideDetailsScreen(trip: trip, minutesUntil: minutes),
      transitionsBuilder: (_, anim, __, child) =>
          FadeTransition(opacity: anim, child: child),
      transitionDuration: _kFade,
    ));
    if (mounted) unawaited(_load());
  }

  // ── Build ──

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final isEs = Localizations.localeOf(context).languageCode == 'es';
    final bottom = MediaQuery.of(context).padding.bottom;
    return Scaffold(
      backgroundColor: neuBase,
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
              child: Row(
                children: [
                  _squareButton(
                    key: const ValueKey('my-res-back'),
                    icon: Icons.chevron_left_rounded,
                    onTap: () => Navigator.maybeOf(context)?.maybePop(),
                  ),
                  Expanded(
                    child: Text(
                      s.scheduledRidesTitle,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 20,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  _squareButton(
                    key: const ValueKey('my-res-refresh'),
                    icon: Icons.refresh_rounded,
                    onTap: () {
                      HapticService.selectionClick();
                      unawaited(_load());
                    },
                  ),
                ],
              ),
            ),
            Expanded(child: _body(s, isEs, bottom)),
          ],
        ),
      ),
    );
  }

  Widget _squareButton({
    required Key key,
    required IconData icon,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      key: key,
      onTap: onTap,
      child: Container(
        width: 44,
        height: 44,
        decoration: neuBox(radius: 12),
        child: Icon(icon, color: Colors.white.withValues(alpha: 0.85)),
      ),
    );
  }

  Widget _body(S s, bool isEs, double bottom) {
    if (_loading && _trips.isEmpty) {
      return const Center(
        child: CircularProgressIndicator(color: _kGold, strokeWidth: 2.5),
      );
    }
    if (_error != null && _trips.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Text(_error!,
              textAlign: TextAlign.center,
              style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.6), fontSize: 14)),
        ),
      );
    }
    if (_trips.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.event_available_rounded,
                  color: _kGold, size: 40),
              const SizedBox(height: 16),
              Text(s.noUpcomingRides,
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 18,
                      fontWeight: FontWeight.w700)),
              const SizedBox(height: 8),
              Text(s.scheduledRidesAssigned,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.45),
                      fontSize: 13,
                      height: 1.5)),
            ],
          ),
        ),
      );
    }
    return RefreshIndicator(
      color: _kGold,
      backgroundColor: neuSurface,
      onRefresh: _load,
      child: ListView(
        key: const ValueKey('my-res-list'),
        padding: EdgeInsets.fromLTRB(16, 10, 16, bottom + 28),
        children: [
          if (!_noteHidden) _note(s),
          for (final t in _trips)
            AnimatedOpacity(
              key: ValueKey('my-res-card-${t['id']}'),
              opacity: _leaving.contains(t['id']) ? 0 : 1,
              duration: const Duration(milliseconds: 420),
              curve: Curves.easeOut,
              child: _card(s, isEs, t),
            ),
          _endNote(s),
        ],
      ),
    );
  }

  Widget _note(S s) {
    return Container(
      key: const ValueKey('my-res-note'),
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.fromLTRB(14, 14, 8, 14),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        color: Colors.white.withValues(alpha: 0.07),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.info_outline_rounded,
              color: Colors.white.withValues(alpha: 0.85), size: 22),
          const SizedBox(width: 10),
          Expanded(
            child: Text(s.myResNote,
                style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.88),
                    fontSize: 14,
                    height: 1.4)),
          ),
          GestureDetector(
            key: const ValueKey('my-res-note-close'),
            onTap: _hideNote,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6),
              child: Icon(Icons.close_rounded,
                  color: Colors.white.withValues(alpha: 0.75), size: 20),
            ),
          ),
        ],
      ),
    );
  }

  Widget _endNote(S s) {
    return GestureDetector(
      key: const ValueKey('my-res-faq'),
      onTap: () {
        HapticService.selectionClick();
        unawaited(showReservationFaq(context));
      },
      child: Container(
        margin: const EdgeInsets.only(top: 14),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 16),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          color: Colors.white.withValues(alpha: 0.07),
        ),
        child: Row(
          children: [
            Icon(Icons.fact_check_outlined,
                color: Colors.white.withValues(alpha: 0.8), size: 22),
            const SizedBox(width: 10),
            Expanded(
              child: Text(s.myResEnd,
                  style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.88),
                      fontSize: 14.5)),
            ),
            Icon(Icons.chevron_right_rounded,
                color: Colors.white.withValues(alpha: 0.8)),
          ],
        ),
      ),
    );
  }

  Widget _hairline() => Container(
        height: 1,
        margin: const EdgeInsets.symmetric(vertical: 14),
        color: Colors.white.withValues(alpha: 0.1),
      );

  Widget _card(S s, bool isEs, Map<String, dynamic> t) {
    final at = parseServerTime(t['scheduled_at']);
    final enRoute = (t['status'] ?? '').toString() == 'driver_en_route';
    final fare = (t['fare'] as num?)?.toDouble() ?? 0;
    final minutes = (t['duration_minutes'] ?? t['duration']) as num?;
    final miles = (t['distance_miles'] ?? t['distance']) as num?;
    final dropMeta = [
      if (minutes != null && minutes > 0) '${minutes.round()} min',
      if (miles != null && miles > 0) '${miles.toStringAsFixed(1)} mi',
    ].join(' · ');
    final stops = _stopCount(t['stops']);
    final rider = nh.shortName((t['rider_name'] ?? '').toString());
    final rating = (t['rider_rating'] as num?)?.toDouble();
    final photo = (t['rider_photo_url'] ?? '').toString();

    return Container(
      margin: const EdgeInsets.only(top: 14),
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(22),
        color: const Color(0xFF0B0B0F),
        border: Border.all(color: Colors.white.withValues(alpha: 0.07)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.event_available_rounded,
                  color: _kGold, size: 24),
              const SizedBox(width: 8),
              Expanded(
                child: Text(s.myResCardTitle,
                    style: const TextStyle(
                        color: _kGold,
                        fontSize: 22,
                        fontWeight: FontWeight.w800)),
              ),
              if (enRoute)
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(999),
                    color: const Color(0xFF4CD964).withValues(alpha: 0.14),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.navigation_rounded,
                          color: Color(0xFF6EE7A0), size: 14),
                      const SizedBox(width: 4),
                      Text(s.myResOnTheWay,
                          style: const TextStyle(
                              color: Color(0xFF6EE7A0),
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                              letterSpacing: 0.5)),
                    ],
                  ),
                ),
            ],
          ),
          if (at != null) ...[
            const SizedBox(height: 4),
            Text(_whenLine(s, at, isEs),
                style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.6),
                    fontSize: 13.5)),
          ],
          _hairline(),
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text('\$${fare.toStringAsFixed(2)}',
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 30,
                      fontWeight: FontWeight.w800)),
              const SizedBox(width: 10),
              Text(s.plusTips,
                  style: const TextStyle(
                      color: _kGold,
                      fontSize: 15,
                      fontWeight: FontWeight.w600)),
            ],
          ),
          const SizedBox(height: 2),
          Text(
            enRoute
                ? s.myResConfirmed
                : (at == null
                    ? ''
                    : s.goOnlineBy(
                        _time(at.subtract(const Duration(hours: 1))))),
            style: TextStyle(
                color: Colors.white.withValues(alpha: 0.88), fontSize: 15),
          ),
          const SizedBox(height: 16),
          _timeline(
            pickupTitle:
                at == null ? s.trackPickup : s.resDetailPickupAt(_time(at)),
            pickupAddr: (t['pickup_address'] ?? '').toString(),
            dropTitle: dropMeta.isEmpty ? s.trackDestination : dropMeta,
            dropAddr: (t['dropoff_address'] ?? '').toString(),
          ),
          if (stops > 0) ...[
            const SizedBox(height: 14),
            Row(
              key: const ValueKey('my-res-stops'),
              children: [
                Container(
                  width: 22,
                  height: 22,
                  decoration: const BoxDecoration(
                    shape: BoxShape.circle,
                    color: _kGold,
                  ),
                  alignment: Alignment.center,
                  child: const SizedBox(
                    width: 11,
                    height: 14,
                    child: FittedBox(child: RiderStopPin()),
                  ),
                ),
                const SizedBox(width: 10),
                Text(s.myResStops(stops),
                    style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.65),
                        fontSize: 14.5)),
              ],
            ),
          ],
          _hairline(),
          Row(
            children: [
              VerifiedAvatar(
                photoUrl: photo.isEmpty ? null : photo,
                radius: 23,
                fallbackName: rider,
                role: 'rider',
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(rider.isEmpty ? '—' : rider,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            color: Colors.white,
                            fontSize: 16,
                            fontWeight: FontWeight.w600)),
                    if (rating != null)
                      Row(
                        children: [
                          Icon(Icons.star_rounded,
                              color: Colors.white.withValues(alpha: 0.8),
                              size: 16),
                          const SizedBox(width: 3),
                          Text(rating.toStringAsFixed(1),
                              style: TextStyle(
                                  color: Colors.white.withValues(alpha: 0.8),
                                  fontSize: 14)),
                        ],
                      ),
                  ],
                ),
              ),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(999),
                  color: _kGold.withValues(alpha: 0.12),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.directions_car_rounded,
                        color: _kGold, size: 18),
                    const SizedBox(width: 6),
                    Text(_tierName(t['vehicle_type']),
                        style: const TextStyle(
                            color: _kGold,
                            fontSize: 14,
                            fontWeight: FontWeight.w600)),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          GestureDetector(
            key: ValueKey('my-res-cta-${t['id']}'),
            onTap: () => enRoute ? unawaited(_navigate(t)) : _openDetails(t),
            child: Container(
              height: 54,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(999),
                color: _kGold,
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  if (enRoute) ...[
                    const Icon(Icons.navigation_rounded,
                        color: Colors.black, size: 20),
                    const SizedBox(width: 8),
                  ],
                  Text(enRoute ? s.myResNavigate : s.myResDetails,
                      style: const TextStyle(
                          color: Colors.black,
                          fontSize: 17,
                          fontWeight: FontWeight.w700)),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _timeline({
    required String pickupTitle,
    required String pickupAddr,
    required String dropTitle,
    required String dropAddr,
  }) {
    Widget ring({bool filled = false}) => Container(
          width: 14,
          height: 14,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(color: _kGold, width: 2.5),
          ),
          alignment: Alignment.center,
          child: filled
              ? Container(
                  width: 5,
                  height: 5,
                  decoration: const BoxDecoration(
                      shape: BoxShape.circle, color: _kGold),
                )
              : null,
        );
    Widget text(String title, String sub) => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title,
                style: const TextStyle(
                    color: Colors.white,
                    fontSize: 15,
                    fontWeight: FontWeight.w600)),
            if (sub.isNotEmpty)
              Text(sub,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.6),
                      fontSize: 14.5)),
          ],
        );
    // One step per row: the ring sits at the title, the gold rail runs
    // from the pickup down to the drop-off.
    Widget step({required bool last, required Widget content}) =>
        IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(
                width: 20,
                child: Column(
                  children: [
                    const SizedBox(height: 4),
                    ring(filled: last),
                    if (!last)
                      Expanded(
                        child: Container(
                          width: 2,
                          margin: const EdgeInsets.only(top: 3),
                          color: _kGold.withValues(alpha: 0.8),
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Padding(
                  padding: EdgeInsets.only(bottom: last ? 0 : 14),
                  child: content,
                ),
              ),
            ],
          ),
        );
    return Column(
      children: [
        step(last: false, content: text(pickupTitle, pickupAddr)),
        step(last: true, content: text(dropTitle, dropAddr)),
      ],
    );
  }
}
