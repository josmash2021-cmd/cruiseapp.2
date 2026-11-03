import 'package:flutter/material.dart';

/// How long a [SmoothReveal] takes, in and out alike.
const Duration kSmoothRevealDuration = Duration(milliseconds: 380);

/// The curve of a [SmoothReveal], the same both ways.
const Curve kSmoothRevealCurve = Curves.easeInOutCubic;

/// The gold of the navigation's highlights (the "Luego" tab): one flat,
/// solid gold — 2D, no gradient, no shadow (owner 2026-11-02: "debe de
/// verse dorada, no opaco" — gold glass over the navy map read dull — and
/// then "no quiero que se vea como 3D, quiero que se vea 2D normal").
const Color kNavGold = Color(0xFFE8C547);

/// Shows or hides [child] the same way both ways (owner 2026-11-02: "así
/// como se abre se cierra smooth, y así para todo"): it unfolds and fades
/// in, and on the way out it keeps drawing while it folds and fades — where
/// a plain `cond ? child : SizedBox()` under an AnimatedSize vanished at
/// once and left an empty box to shrink.
class SmoothReveal extends StatelessWidget {
  const SmoothReveal({
    super.key,
    required this.visible,
    required this.child,
    this.duration = kSmoothRevealDuration,
  });

  final bool visible;
  final Widget child;
  final Duration duration;

  @override
  Widget build(BuildContext context) {
    return AnimatedSwitcher(
      duration: duration,
      reverseDuration: duration,
      switchInCurve: kSmoothRevealCurve,
      switchOutCurve: kSmoothRevealCurve,
      transitionBuilder: (child, anim) => FadeTransition(
        opacity: anim,
        child: SizeTransition(
          sizeFactor: anim,
          axisAlignment: -1,
          child: child,
        ),
      ),
      layoutBuilder: (cur, prev) => Stack(
        alignment: Alignment.topCenter,
        children: [...prev, if (cur != null) cur],
      ),
      child: visible
          ? KeyedSubtree(key: const ValueKey(true), child: child)
          : const SizedBox(key: ValueKey(false), width: double.infinity),
    );
  }
}
