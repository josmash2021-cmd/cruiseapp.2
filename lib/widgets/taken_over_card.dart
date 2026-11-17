import 'dart:ui' as ui;

import 'package:flutter/material.dart';

/// The whole "another driver took it" run, in ms (owner 2026-11-06, approved
/// demo https://claude.ai/artifact/1ysaVs28Z9MD3pAqVoAbEg). Top-level, not
/// `static const` (CLAUDE.md #16).
const int kTakenOverCardMs = 3390;

/// When the card and the notice start to leave.
const int kTakenOverCardExitMs = 2940;

/// "Otro conductor lo tomó" ON the card the driver tapped: the card frosts
/// in place (blur 10, a dark veil 0.45, 450 ms ease-out) and its button
/// greys out; the notice rises onto the card — no box of its own, the frosted
/// card is its ground (from 120 ms, 420 ms); from [exitMs] both slide 40 down
/// and fade (450 ms). Nothing on it takes a tap.
///
/// Shared by the instant offer (driver_online_widgets `_takenOnCard`) and a
/// reservation claimed a moment too late (scheduled_rides_map_screen, owner
/// 2026-11-16: "igual que las ofertas") — one look, one place to change it.
///
/// The blur is an ImageFiltered on the card's own pixels, never a
/// BackdropFilter (that would have to see the native map, rule 43), and
/// clipped to the card's radius so its edge stays crisp.
class TakenOverCard extends StatelessWidget {
  const TakenOverCard({
    super.key,
    required this.controller,
    required this.card,
    required this.button,
    required this.title,
    required this.body,
    this.sideInset = 0,
    this.radius = 20,
    this.totalMs = kTakenOverCardMs,
    this.exitMs = kTakenOverCardExitMs,
  });

  /// Runs 0 → 1 over [totalMs].
  final AnimationController controller;
  final Widget card;
  final Widget button;
  final String title;
  final String body;
  final double sideInset;
  final double radius;
  final int totalMs;
  final int exitMs;

  static const _gold = Color(0xFFE8C547);

  @override
  Widget build(BuildContext context) {
    const settle = Cubic(0.22, 1, 0.36, 1);
    double seg(double ms, int start, int dur, Curve c) =>
        c.transform(((ms - start) / dur).clamp(0.0, 1.0));
    return IgnorePointer(
      child: AnimatedBuilder(
        animation: controller,
        builder: (context, _) {
          final ms = controller.value * totalMs;
          final kF = seg(ms, 0, 450, Curves.easeOutCubic);
          final kN = seg(ms, 120, 420, settle);
          final kRing = seg(ms, 160, 520, settle);
          final kPulse = seg(ms, 300, 900, Curves.easeOutCubic);
          final kOut = seg(ms, exitMs, 450, Curves.fastOutSlowIn);
          final blur = 10 * kF;
          final notice = Opacity(
            opacity: kN,
            child: Transform.translate(
              offset: Offset(0, 10 * (1 - kN)),
              child: Transform.scale(
                scale: 0.96 + 0.04 * kN,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 30),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Transform.scale(
                        scale: 0.86 + 0.14 * kRing,
                        child: Container(
                          width: 56,
                          height: 56,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: _gold.withValues(alpha: 0.12),
                            border: Border.all(color: _gold, width: 1.5),
                            boxShadow: [
                              if (kPulse > 0 && kPulse < 1)
                                BoxShadow(
                                  color: _gold.withValues(
                                      alpha: 0.22 * (1 - kPulse)),
                                  spreadRadius: 12 * kPulse,
                                ),
                            ],
                          ),
                          child: const Icon(
                            Icons.swap_horiz_rounded,
                            color: _gold,
                            size: 30,
                          ),
                        ),
                      ),
                      const SizedBox(height: 14),
                      Text(
                        title,
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 20,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        body,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.55),
                          fontSize: 13,
                          height: 1.5,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          );
          return Opacity(
            opacity: 1 - kOut,
            child: Transform.translate(
              offset: Offset(0, 40 * kOut),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Padding(
                    padding: EdgeInsets.symmetric(
                        horizontal: sideInset, vertical: 4),
                    child: Stack(
                      alignment: Alignment.center,
                      children: [
                        ClipRRect(
                          borderRadius: BorderRadius.circular(radius),
                          child: ImageFiltered(
                            enabled: blur > 0.01,
                            imageFilter:
                                ui.ImageFilter.blur(sigmaX: blur, sigmaY: blur),
                            child: card,
                          ),
                        ),
                        Positioned.fill(
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(radius),
                            child: ColoredBox(
                              color: Colors.black.withValues(alpha: 0.45 * kF),
                            ),
                          ),
                        ),
                        Positioned.fill(child: Center(child: notice)),
                      ],
                    ),
                  ),
                  Padding(
                    padding: EdgeInsets.fromLTRB(sideInset, 4, sideInset, 8),
                    child: Opacity(
                      opacity: 1 - 0.7 * kF,
                      child: ImageFiltered(
                        enabled: kF > 0.01,
                        imageFilter: ui.ImageFilter.blur(
                            sigmaX: 3 * kF, sigmaY: 3 * kF),
                        child: button,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}
