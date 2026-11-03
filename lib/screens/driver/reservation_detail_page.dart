import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:intl/intl.dart' show DateFormat;

import '../../config/page_transitions.dart';
import '../../l10n/app_localizations.dart';
import '../../services/api_service.dart';
import '../../services/haptic_service.dart';
import '../../utils/name_helper.dart' as nh;
import '../../utils/server_time.dart';
import '../../utils/trip_stops.dart';
import '../../widgets/verified_avatar.dart';
import '../help_screen.dart' show CruiseSupportChatScreen;
import '../schedule_cancel_policy_screen.dart' show kScheduledCancelFeesUsd;

/// The "More info" pages, inside the same glass (owner-approved drawing
/// 2026-11-03): they slide in from the right over the reservation, the back
/// arrow slides them out again.
enum _ResSub { how, policy, faq }

const _kSubSlide = Duration(milliseconds: 360);

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
          position:
              Tween<Offset>(begin: const Offset(0, 0.04), end: Offset.zero)
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

  /// The "More info" page on screen (null = the reservation itself), and the
  /// last one opened — it stays built while it slides back out.
  _ResSub? _sub;
  _ResSub _shownSub = _ResSub.how;

  /// The FAQ answers that are open (the first one starts open).
  final Set<int> _openFaq = {0};

  void _openSub(_ResSub sub) => setState(() {
        _sub = sub;
        _shownSub = sub;
      });

  void _closeSub() => setState(() => _sub = null);

  /// The card's own values win (its `fare` is the driver's pay, the trip's
  /// may be the rider's price); the trip only adds what the card lacks.
  Map<String, dynamic> get _r => {...?_trip, ...widget.reservation};

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

  int _daysFromToday(DateTime at) {
    final now = DateTime.now();
    return DateTime(at.year, at.month, at.day)
        .difference(DateTime(now.year, now.month, now.day))
        .inDays;
  }

  String _shortDate(DateTime at, bool isEs) => isEs
      ? '${at.day} de ${_kMonthsEs[at.month - 1]}'
      : '${_kMonthsEn[at.month - 1]} ${at.day}';

  /// "Hoy · 3 de nov a las 3:20 PM" / "Today · Nov 3 at 3:20 PM".
  String _dateLine(S s, DateTime at, bool isEs) {
    final diff = _daysFromToday(at);
    final lead = diff == 0
        ? s.resDetailToday
        : diff == 1
            ? s.resDetailTomorrow
            : (isEs ? _kDaysEs : _kDaysEn)[at.weekday - 1];
    return '$lead · ${s.resDetailDateAt(_shortDate(at, isEs), _time(at))}';
  }

  /// "Tu reserva: hoy, recogida a las 3:20 PM" — the sub pages' lead line.
  String _subLead(S s, DateTime at, bool isEs) {
    final diff = _daysFromToday(at);
    final day = diff == 0
        ? s.resDetailToday.toLowerCase()
        : diff == 1
            ? s.resDetailTomorrow.toLowerCase()
            : isEs
                ? '${_kDaysEs[at.weekday - 1].toLowerCase()} '
                    '${_shortDate(at, true)}'
                : '${_kDaysEn[at.weekday - 1]}, ${_shortDate(at, false)}';
    return s.resSubLead(day, _time(at));
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
                style:
                    const TextStyle(color: _red, fontWeight: FontWeight.w700)),
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

  /// The round glass button top-left: X on the reservation, back arrow on
  /// a "More info" page.
  Widget _disc(IconData icon, VoidCallback onTap, {required Key key}) {
    return Align(
      alignment: Alignment.centerLeft,
      child: GestureDetector(
        key: key,
        onTap: onTap,
        child: Container(
          width: 52,
          height: 52,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: Colors.white.withValues(alpha: 0.12),
          ),
          child: Icon(icon, color: Colors.white, size: 27),
        ),
      ),
    );
  }

  Widget _subTitle(String title, String? lead) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 18),
        Text(title,
            style: const TextStyle(
                color: Colors.white,
                fontSize: 30,
                fontWeight: FontWeight.w800,
                height: 1.2)),
        if (lead != null) ...[
          const SizedBox(height: 10),
          Text(lead,
              style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.7), fontSize: 15)),
        ],
      ],
    );
  }

  /// One step of "How to complete your ride": the icon in its sunk well, a
  /// gold line down to the next one, the clock time above the title.
  Widget _howStep({
    required IconData icon,
    required String label,
    required String title,
    required String body,
    bool last = false,
  }) {
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            width: 46,
            child: Column(
              children: [
                Container(
                  width: 46,
                  height: 46,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: Colors.white.withValues(alpha: 0.08),
                    border:
                        Border.all(color: Colors.white.withValues(alpha: 0.06)),
                  ),
                  child: Icon(icon, color: _gold, size: 24),
                ),
                if (!last)
                  Expanded(
                    child: Container(
                      width: 2,
                      margin: const EdgeInsets.symmetric(vertical: 6),
                      color: _gold.withValues(alpha: 0.45),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Padding(
              padding: EdgeInsets.only(top: 4, bottom: last ? 0 : 24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label,
                      style: const TextStyle(
                          color: _gold,
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 1)),
                  const SizedBox(height: 2),
                  Text(title,
                      style: const TextStyle(
                          color: Colors.white,
                          fontSize: 17,
                          fontWeight: FontWeight.w600,
                          height: 1.3)),
                  const SizedBox(height: 4),
                  Text(body,
                      style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.72),
                          fontSize: 14.5,
                          height: 1.45)),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// One case of the cancel policy, on a soft glass card.
  Widget _policyCard({
    required IconData icon,
    required String title,
    required String body,
    Widget? extra,
  }) {
    return Container(
      margin: const EdgeInsets.only(top: 14),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        color: Colors.white.withValues(alpha: 0.06),
        border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: _gold, size: 24),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 17,
                        fontWeight: FontWeight.w600)),
                const SizedBox(height: 6),
                Text(body,
                    style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.75),
                        fontSize: 14.5,
                        height: 1.45)),
                if (extra != null) ...[const SizedBox(height: 10), extra],
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// One question: tap opens or closes its answer, smoothly.
  Widget _faqItem(int i, String q, String a) {
    final open = _openFaq.contains(i);
    final line = Colors.white.withValues(alpha: 0.07);
    return Container(
      key: ValueKey('res-faq-$i'),
      decoration:
          BoxDecoration(border: Border(bottom: BorderSide(color: line))),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            onTap: () {
              HapticService.selectionClick();
              setState(() => open ? _openFaq.remove(i) : _openFaq.add(i));
            },
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 16),
              child: Row(
                children: [
                  Expanded(
                    child: Text(q,
                        style: const TextStyle(
                            color: Colors.white,
                            fontSize: 16.5,
                            fontWeight: FontWeight.w600,
                            height: 1.35)),
                  ),
                  const SizedBox(width: 10),
                  AnimatedRotation(
                    turns: open ? 0.5 : 0,
                    duration: const Duration(milliseconds: 300),
                    curve: Curves.easeOutCubic,
                    child: Icon(Icons.expand_more_rounded,
                        color: Colors.white.withValues(alpha: 0.7)),
                  ),
                ],
              ),
            ),
          ),
          ClipRect(
            child: AnimatedSize(
              duration: const Duration(milliseconds: 300),
              curve: Curves.easeOutCubic,
              alignment: Alignment.topCenter,
              child: open
                  ? Padding(
                      padding: const EdgeInsets.only(bottom: 16),
                      child: Text(a,
                          style: TextStyle(
                              color: Colors.white.withValues(alpha: 0.75),
                              fontSize: 14.5,
                              height: 1.5)),
                    )
                  : const SizedBox(width: double.infinity),
            ),
          ),
        ],
      ),
    );
  }

  /// The "More info" page [sub], built for [at] (the pickup time).
  Widget _buildSub(S s, _ResSub sub, DateTime? at, bool isEs, double bottom) {
    String t(DateTime? d) => d == null ? '—' : _time(d);
    final goBy = at?.subtract(const Duration(hours: 1));
    final lead = at == null ? null : _subLead(s, at, isEs);
    final back = _disc(Icons.arrow_back_rounded, _closeSub,
        key: const ValueKey('res-sub-back'));
    final List<Widget> body;
    switch (sub) {
      case _ResSub.how:
        body = [
          back,
          _subTitle(s.resDetailHowTo, lead),
          const SizedBox(height: 24),
          _howStep(
            icon: Icons.power_settings_new_rounded,
            label: t(goBy),
            title: s.goOnlineBy(t(goBy)),
            // The server's reminder goes out 15 min before that deadline,
            // only to a driver still offline (main.py).
            body: s.resHowStep1Body(
                t(goBy?.subtract(const Duration(minutes: 15)))),
          ),
          _howStep(
            icon: Icons.do_not_disturb_on_rounded,
            label: '${t(goBy)} – ${t(at)}',
            title: s.resHowStep2Title,
            body: s.resHowStep2Body,
          ),
          _howStep(
            icon: Icons.navigation_rounded,
            label: t(at?.subtract(const Duration(minutes: 30))),
            title: s.resHowStep3Title,
            body: s.resHowStep3Body,
          ),
          _howStep(
            icon: Icons.hail,
            label: t(at),
            title: s.resHowStep4Title,
            body: s.resHowStep4Body,
            last: true,
          ),
        ];
      case _ResSub.policy:
        body = [
          back,
          _subTitle(s.resDetailCancelPolicy, lead),
          const SizedBox(height: 10),
          _policyCard(
            icon: Icons.event_busy_rounded,
            title: s.resPolYouTitle,
            body: s.resPolYouBody(t(goBy)),
          ),
          _policyCard(
            icon: Icons.wifi_off_rounded,
            title: s.resPolOfflineTitle,
            body: s.resPolOfflineBody(t(goBy)),
          ),
          _policyCard(
            icon: Icons.person_remove_rounded,
            title: s.resPolRiderTitle,
            body: s.resPolRiderBody,
            // The same table the rider's own policy page shows.
            extra: Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final e in kScheduledCancelFeesUsd.entries)
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(999),
                      color: _gold.withValues(alpha: 0.12),
                    ),
                    child: Text('${e.key} \$${e.value}',
                        style: const TextStyle(
                            color: Color(0xFFF2D46A),
                            fontSize: 13,
                            fontWeight: FontWeight.w600)),
                  ),
              ],
            ),
          ),
          _policyCard(
            icon: Icons.timer_off_rounded,
            title: s.resPolNoShowTitle,
            body: s.resPolNoShowBody(s.navRiderNoShow),
          ),
        ];
      case _ResSub.faq:
        final qa = [
          (s.resFaqQ1, s.resFaqA1),
          (s.resFaqQ2, s.resFaqA2),
          (s.resFaqQ3, s.resFaqA3),
          (s.resFaqQ4, s.resFaqA4),
          (s.resFaqQ5, s.resFaqA5),
          (s.resFaqQ6, s.resFaqA6),
        ];
        body = [
          back,
          _subTitle(s.resDetailFaq, null),
          const SizedBox(height: 18),
          Container(
            decoration: BoxDecoration(
              border: Border(
                  top: BorderSide(color: Colors.white.withValues(alpha: 0.07))),
            ),
            child: Column(
              children: [
                for (var i = 0; i < qa.length; i++)
                  _faqItem(i, qa[i].$1, qa[i].$2),
              ],
            ),
          ),
          const SizedBox(height: 26),
          GestureDetector(
            key: const ValueKey('res-faq-support'),
            onTap: () {
              HapticService.selectionClick();
              Navigator.maybeOf(context)
                  ?.push(slideFromRightRoute(const CruiseSupportChatScreen()));
            },
            child: Container(
              height: 56,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(999),
                color: _gold,
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(Icons.chat_rounded, color: Colors.black, size: 22),
                  const SizedBox(width: 8),
                  Text(s.resFaqSupport,
                      style: const TextStyle(
                          color: Colors.black,
                          fontSize: 17,
                          fontWeight: FontWeight.w700)),
                ],
              ),
            ),
          ),
        ];
    }
    return ListView(
      // A fresh list per page: it always opens at the top.
      key: ValueKey('res-sub-${sub.name}'),
      padding: EdgeInsets.fromLTRB(22, 10, 22, bottom),
      children: body,
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
    final isEs = Localizations.localeOf(context).languageCode == 'es';
    final mq = MediaQuery.of(context);
    final bottom = mq.padding.bottom + 28;

    return PopScope(
      // Back (gesture or Android button) on a "More info" page returns to
      // the reservation; on the reservation it closes the page.
      canPop: _sub == null,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _sub != null) _closeSub();
      },
      child: Material(
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
              child: ClipRect(
                child: Stack(
                  children: [
                    Positioned.fill(
                      child: IgnorePointer(
                        ignoring: _sub != null,
                        child: AnimatedSlide(
                          offset: _sub == null
                              ? Offset.zero
                              : const Offset(-0.28, 0),
                          duration: _kSubSlide,
                          curve: Curves.easeOutCubic,
                          child: AnimatedOpacity(
                            opacity: _sub == null ? 1 : 0,
                            duration: _kSubSlide,
                            curve: Curves.easeOutCubic,
                            child: _buildMain(s, isEs, bottom),
                          ),
                        ),
                      ),
                    ),
                    Positioned.fill(
                      child: IgnorePointer(
                        ignoring: _sub == null,
                        child: AnimatedSlide(
                          offset:
                              _sub == null ? const Offset(1, 0) : Offset.zero,
                          duration: _kSubSlide,
                          curve: Curves.easeOutCubic,
                          child: _buildSub(
                              s,
                              _shownSub,
                              parseServerTime(_r['scheduled_at']),
                              isEs,
                              bottom),
                        ),
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

  /// The reservation itself (Lyft's scheduled-ride detail).
  Widget _buildMain(S s, bool isEs, double bottom) {
    final r = _r;
    final at = parseServerTime(r['scheduled_at']);
    final goBy = at?.subtract(const Duration(hours: 1));
    final fare = (r['fare'] as num?)?.toDouble() ?? 0;
    final rider = nh.shortName((r['rider_name'] ?? '').toString());
    final firstName = rider.split(' ').first;
    final rating = (r['rider_rating'] as num?)?.toDouble();
    final photo = (r['rider_photo_url'] ?? '').toString();
    final stop = parseTripStop(r);

    return ListView(
      key: const ValueKey('reservation-detail'),
      padding: EdgeInsets.fromLTRB(22, 10, 22, bottom),
      children: [
        _disc(Icons.close_rounded, () => Navigator.maybeOf(context)?.pop(),
            key: const ValueKey('reservation-detail-close')),
        const SizedBox(height: 18),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              // "CRUISE" in capitals and gold (owner 2026-11-03).
              child: Text.rich(
                TextSpan(children: [
                  TextSpan(text: '\$${fare.toStringAsFixed(2)} '),
                  const TextSpan(
                      text: 'CRUISE', style: TextStyle(color: _gold)),
                  if (firstName.isNotEmpty)
                    TextSpan(text: '\n${s.resDetailWith(firstName)}'),
                ]),
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
          Text(_dateLine(s, at, isEs),
              style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.85), fontSize: 16)),
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
          title: at == null ? s.trackPickup : s.resDetailPickupAt(_time(at)),
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
          () => _openSub(_ResSub.how),
          key: const ValueKey('res-how-to'),
        ),
        _infoRow(
          s.resDetailCancelPolicy,
          s.resDetailCancelPolicySub,
          () => _openSub(_ResSub.policy),
          key: const ValueKey('res-cancel-policy'),
        ),
        _infoRow(
          s.resDetailFaq,
          s.resDetailFaqSub,
          () => _openSub(_ResSub.faq),
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
