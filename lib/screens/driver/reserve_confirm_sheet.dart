import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:intl/intl.dart' show DateFormat;

import '../../l10n/app_localizations.dart';
import '../../services/haptic_service.dart';

const _kGold = Color(0xFFE8C547);

// Tables instead of DateFormat: the project never calls
// initializeDateFormatting, so a Spanish-locale DateFormat throws.
const _kWeekEs = ['lun', 'mar', 'mié', 'jue', 'vie', 'sáb', 'dom'];
const _kWeekEn = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
const _kMonEs = [
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
const _kMonEn = [
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

/// "Reserve this ride?" (owner 2026-11-03, Lyft's confirm card, identical
/// layout in Cruise glass): what the driver commits to, three important
/// details that are TRUE in Cruise, Reservar and Ver política. Resolves
/// true only on Reservar.
Future<bool> showReserveConfirm(
  BuildContext context, {
  required DateTime? pickupAt,
  required VoidCallback onViewPolicy,
}) async {
  final ok = await showGeneralDialog<bool>(
    context: context,
    barrierDismissible: true,
    barrierLabel: 'reserve-confirm',
    barrierColor: Colors.transparent,
    transitionDuration: const Duration(milliseconds: 320),
    pageBuilder: (ctx, _, __) =>
        ReserveConfirmCard(pickupAt: pickupAt, onViewPolicy: onViewPolicy),
    transitionBuilder: (ctx, anim, _, child) {
      final a = CurvedAnimation(parent: anim, curve: Curves.easeOutCubic);
      return FadeTransition(
        opacity: a,
        child: SlideTransition(
          position:
              Tween<Offset>(begin: const Offset(0, 0.12), end: Offset.zero)
                  .animate(a),
          child: child,
        ),
      );
    },
  );
  return ok == true;
}

class ReserveConfirmCard extends StatelessWidget {
  const ReserveConfirmCard({
    super.key,
    required this.pickupAt,
    required this.onViewPolicy,
  });

  final DateTime? pickupAt;
  final VoidCallback onViewPolicy;

  static String _time(DateTime t) => DateFormat('h:mm a', 'en_US').format(t);

  /// "mar 3 nov, 5:55 PM" / "Tue, Nov 3, 5:55 PM".
  static String _when(DateTime t, bool isEs) => isEs
      ? '${_kWeekEs[t.weekday - 1]} ${t.day} ${_kMonEs[t.month - 1]}, ${_time(t)}'
      : '${_kWeekEn[t.weekday - 1]}, ${_kMonEn[t.month - 1]} ${t.day}, ${_time(t)}';

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final isEs = Localizations.localeOf(context).languageCode == 'es';
    final at = pickupAt;
    final goBy = at?.subtract(const Duration(hours: 1));
    final bottom = MediaQuery.of(context).padding.bottom;
    void close([bool ok = false]) => Navigator.maybeOf(context)?.pop(ok);

    Widget detail(IconData icon, Widget text) => Padding(
          padding: const EdgeInsets.only(top: 16),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 1),
                child: Icon(icon,
                    color: Colors.white.withValues(alpha: 0.9), size: 22),
              ),
              const SizedBox(width: 14),
              Expanded(child: text),
            ],
          ),
        );
    const body = TextStyle(color: Colors.white, fontSize: 15.5, height: 1.4);

    return Stack(
      children: [
        // The map behind goes soft and dim — full screen, so iOS draws no
        // square corners around the card (rule 43).
        Positioned.fill(
          child: GestureDetector(
            onTap: close,
            child: BackdropFilter(
              filter: ui.ImageFilter.blur(sigmaX: 14, sigmaY: 14),
              child: ColoredBox(color: Colors.black.withValues(alpha: 0.35)),
            ),
          ),
        ),
        Align(
          alignment: Alignment.bottomCenter,
          child: Padding(
            padding: EdgeInsets.fromLTRB(12, 0, 12, bottom + 12),
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                Material(
                  key: const ValueKey('reserve-confirm-card'),
                  color: const Color(0xE61E1E26),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(30),
                    side:
                        BorderSide(color: Colors.white.withValues(alpha: 0.12)),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(22, 26, 22, 20),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // Clear of the X in the corner.
                        Padding(
                          padding: const EdgeInsets.only(right: 44),
                          child: Text(s.resvConfirmTitle,
                              style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 25,
                                  fontWeight: FontWeight.w800)),
                        ),
                        if (at != null) ...[
                          const SizedBox(height: 8),
                          Text(s.resvConfirmBody(_when(at, isEs)),
                              style: TextStyle(
                                  color: Colors.white.withValues(alpha: 0.85),
                                  fontSize: 16,
                                  height: 1.4)),
                        ],
                        const SizedBox(height: 20),
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.fromLTRB(18, 18, 18, 20),
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(20),
                            color: Colors.black.withValues(alpha: 0.28),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(s.resvImportant,
                                  style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 16,
                                      fontWeight: FontWeight.w700)),
                              if (goBy != null)
                                detail(
                                  Icons.schedule_rounded,
                                  Text.rich(
                                    TextSpan(children: [
                                      TextSpan(
                                          text: s.resvGoOnlineBold(_time(goBy)),
                                          style: const TextStyle(
                                              fontWeight: FontWeight.w700)),
                                      TextSpan(text: s.resvGoOnlineRest),
                                    ]),
                                    style: body,
                                  ),
                                ),
                              detail(Icons.event_busy_rounded,
                                  Text(s.resvMissed, style: body)),
                              detail(Icons.event_available_rounded,
                                  Text(s.resvCancelInfo, style: body)),
                            ],
                          ),
                        ),
                        const SizedBox(height: 22),
                        // Narrower than the card, as in the reference.
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 24),
                          child: Column(children: [
                            GestureDetector(
                              key: const ValueKey('reserve-confirm-ok'),
                              onTap: () {
                                HapticService.mediumImpact();
                                close(true);
                              },
                              child: Container(
                                height: 56,
                                decoration: BoxDecoration(
                                  color: _kGold,
                                  borderRadius: BorderRadius.circular(999),
                                ),
                                alignment: Alignment.center,
                                child: Text(s.resvReserve,
                                    style: const TextStyle(
                                        color: Colors.black,
                                        fontSize: 18,
                                        fontWeight: FontWeight.w800)),
                              ),
                            ),
                            const SizedBox(height: 10),
                            GestureDetector(
                              key: const ValueKey('reserve-confirm-policy'),
                              onTap: onViewPolicy,
                              child: Container(
                                height: 56,
                                decoration: BoxDecoration(
                                  color: Colors.white.withValues(alpha: 0.10),
                                  borderRadius: BorderRadius.circular(999),
                                ),
                                alignment: Alignment.center,
                                child: Text(s.resvViewPolicy,
                                    style: const TextStyle(
                                        color: Colors.white,
                                        fontSize: 17,
                                        fontWeight: FontWeight.w700)),
                              ),
                            ),
                          ]),
                        ),
                      ],
                    ),
                  ),
                ),
                // The X inside the card's top-right corner, level with the
                // title, as in the reference (owner 2026-11-04).
                Positioned(
                  top: 18,
                  right: 16,
                  child: GestureDetector(
                    key: const ValueKey('reserve-confirm-close'),
                    onTap: close,
                    child: Container(
                      width: 40,
                      height: 40,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: const Color(0xFF2A2A32),
                        border: Border.all(
                            color: Colors.white.withValues(alpha: 0.15)),
                      ),
                      child: const Icon(Icons.close_rounded,
                          color: Colors.white, size: 22),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
