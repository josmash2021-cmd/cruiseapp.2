import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:intl/intl.dart' show DateFormat;

import '../l10n/app_localizations.dart';
import '../services/haptic_service.dart';

/// How long "Llegaste temprano" stays up on its own.
const kEarlyArrivalAutoClose = Duration(seconds: 10);

/// "Llegaste temprano" (owner 2026-11-03, Lyft's "You're here early"; laid
/// out as Lyft's, owner 2026-11-04 "idéntica, mismo diseño tal cual"): the
/// driver swiped "Llegué" before a reservation's pickup time. The rider is
/// told the driver is there (the usual arrival push); the wait only starts
/// counting at [waitStartsAt] (server: wait_clock_start) — Cruise does not
/// pay the early wait, so the copy says when it starts, not "paid to wait".
/// A panel with its handle holds the card (white clock, title, the X whose
/// ring empties as the auto-close runs) and a narrower Okay under it; the
/// map stays in sight. Closes with Okay, the X, or by itself.
///
/// Solid, no blur: on iOS a blur over the native map is rectangular and
/// shows square corners around a floating rounded card (rule 43).
Future<void> showEarlyArrivalSheet(
  BuildContext context, {
  required String riderFirstName,
  required DateTime waitStartsAt,
}) {
  return showGeneralDialog<void>(
    context: context,
    barrierDismissible: true,
    barrierLabel: 'early-arrival',
    barrierColor: Colors.transparent,
    transitionDuration: const Duration(milliseconds: 320),
    pageBuilder: (ctx, _, __) => EarlyArrivalCard(
      riderFirstName: riderFirstName,
      waitStartsAt: waitStartsAt,
    ),
    transitionBuilder: (ctx, anim, _, child) {
      final a = CurvedAnimation(parent: anim, curve: Curves.easeOutCubic);
      return FadeTransition(
        opacity: a,
        child: SlideTransition(
          position:
              Tween<Offset>(begin: const Offset(0, 0.15), end: Offset.zero)
                  .animate(a),
          child: child,
        ),
      );
    },
  );
}

class EarlyArrivalCard extends StatefulWidget {
  const EarlyArrivalCard({
    super.key,
    required this.riderFirstName,
    required this.waitStartsAt,
  });

  final String riderFirstName;
  final DateTime waitStartsAt;

  @override
  State<EarlyArrivalCard> createState() => _EarlyArrivalCardState();
}

class _EarlyArrivalCardState extends State<EarlyArrivalCard>
    with SingleTickerProviderStateMixin {
  static const _gold = Color(0xFFE8C547);

  late final AnimationController _clock = AnimationController(
    vsync: this,
    duration: kEarlyArrivalAutoClose,
  )..forward();
  bool _closed = false;
  ModalRoute<dynamic>? _route;

  @override
  void initState() {
    super.initState();
    _clock.addStatusListener((s) {
      if (s == AnimationStatus.completed) _close();
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _route = ModalRoute.of(context);
  }

  /// Closes THIS card's route only. A bare pop() is wrong twice over:
  /// when the card is already on its way out (barrier tap or back in the
  /// last 320 ms of the clock) it pops the trip screen underneath — pop
  /// ignores that screen's canPop: false — and when something was pushed
  /// on top it pops that instead.
  void _close() {
    if (_closed || !mounted) return;
    _closed = true;
    final route = _route;
    if (route == null || !route.isActive) return;
    final nav = route.navigator;
    if (nav == null) return;
    if (route.isCurrent) {
      nav.pop();
    } else {
      nav.removeRoute(route);
    }
  }

  @override
  void dispose() {
    _clock.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final time = DateFormat('h:mm a', 'en_US').format(widget.waitStartsAt);
    final bottom = MediaQuery.of(context).padding.bottom;
    return Align(
      alignment: Alignment.bottomCenter,
      child: Padding(
        // Where the nav panel floats: 8 at the sides, half the home bar.
        padding: EdgeInsets.fromLTRB(8, 0, 8, 8 + bottom * 0.5),
        child: DecoratedBox(
          // A soft lift off the map; a Material elevation of 12 read as a
          // hard black band round the panel.
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(30),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.35),
                blurRadius: 24,
                offset: const Offset(0, 6),
              ),
            ],
          ),
          child: Material(
            key: const ValueKey('early-arrival-card'),
            color: const Color(0xF71A1A21),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(30),
              side: BorderSide(color: Colors.white.withValues(alpha: 0.10)),
            ),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(10, 8, 10, 22),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // The panel's handle.
                  Container(
                    width: 36,
                    height: 4,
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.3),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                  const SizedBox(height: 14),
                  Container(
                    padding: const EdgeInsets.fromLTRB(18, 18, 12, 20),
                    decoration: BoxDecoration(
                      color: const Color(0xFF2A2A32),
                      borderRadius: BorderRadius.circular(24),
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Padding(
                          padding: EdgeInsets.only(top: 2),
                          child: Icon(Icons.schedule_rounded,
                              color: Colors.white, size: 30),
                        ),
                        const SizedBox(width: 16),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(s.earlyArrivalTitle,
                                  style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 22,
                                      fontWeight: FontWeight.w800)),
                              const SizedBox(height: 8),
                              Text(
                                s.earlyArrivalBody(widget.riderFirstName, time),
                                style: TextStyle(
                                    color: Colors.white.withValues(alpha: 0.85),
                                    fontSize: 15,
                                    height: 1.45),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 6),
                        GestureDetector(
                          key: const ValueKey('early-arrival-close'),
                          onTap: _close,
                          child: SizedBox(
                            width: 40,
                            height: 40,
                            child: AnimatedBuilder(
                              animation: _clock,
                              builder: (_, child) => CustomPaint(
                                painter: _CloseRing(1 - _clock.value),
                                child: child,
                              ),
                              child: const Center(
                                child: Icon(Icons.close_rounded,
                                    color: Colors.white, size: 22),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 22),
                  // Narrower than the card, centred, as in the reference.
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 48),
                    child: GestureDetector(
                      key: const ValueKey('early-arrival-ok'),
                      onTap: () {
                        HapticService.selectionClick();
                        _close();
                      },
                      child: Container(
                        height: 52,
                        decoration: BoxDecoration(
                          color: _gold,
                          borderRadius: BorderRadius.circular(999),
                        ),
                        alignment: Alignment.center,
                        child: Text(s.earlyArrivalOk,
                            style: const TextStyle(
                                color: Colors.black,
                                fontSize: 17,
                                fontWeight: FontWeight.w800)),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The X's ring: what is left of the auto-close, from 12 o'clock.
class _CloseRing extends CustomPainter {
  _CloseRing(this.left);

  final double left;

  @override
  void paint(Canvas canvas, Size size) {
    final r = math.min(size.width, size.height) / 2 - 2;
    final c = size.center(Offset.zero);
    canvas.drawCircle(
        c, r, Paint()..color = Colors.white.withValues(alpha: 0.10));
    if (left <= 0) return;
    canvas.drawArc(
      Rect.fromCircle(center: c, radius: r),
      -math.pi / 2,
      math.pi * 2 * left,
      false,
      Paint()
        ..color = const Color(0xFFE8C547)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3
        ..strokeCap = StrokeCap.round,
    );
  }

  @override
  bool shouldRepaint(covariant _CloseRing old) => old.left != left;
}
