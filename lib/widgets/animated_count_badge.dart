import 'package:flutter/material.dart';

/// Gold count pill that arrives and leaves instead of blinking (owner spec
/// 2026-10-30: "aparecerá de forma animada … y cuando no haya también igual
/// al quitarse el badge de forma animada y smooth").
///
/// 0 → n: pops in (springy scale + fade). n → 0: shrinks and fades out while
/// still showing the last number — it never empties first and then vanishes.
/// n → m: the figure rolls over in place.
class AnimatedCountBadge extends StatefulWidget {
  const AnimatedCountBadge({
    super.key,
    required this.count,
    this.height = 20,
    this.fontSize = 10,
    this.color = const Color(0xFFE8C547),
    this.textColor = Colors.black,
    this.borderColor,
    this.borderWidth = 1.5,
  });

  final int count;
  final double height;
  final double fontSize;
  final Color color;
  final Color textColor;
  final Color? borderColor;
  final double borderWidth;

  @override
  State<AnimatedCountBadge> createState() => _AnimatedCountBadgeState();
}

class _AnimatedCountBadgeState extends State<AnimatedCountBadge>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 460),
    reverseDuration: const Duration(milliseconds: 280),
    value: widget.count > 0 ? 1.0 : 0.0,
  );
  late final Animation<double> _scale = CurvedAnimation(
    parent: _ctrl,
    curve: Curves.easeOutBack,
    reverseCurve: Curves.easeInCubic,
  );
  late final Animation<double> _fade = CurvedAnimation(
    parent: _ctrl,
    curve: const Interval(0.0, 0.55, curve: Curves.easeOut),
    reverseCurve: Curves.easeIn,
  );

  /// What the pill shows — the last non-zero count, so the exit animates
  /// the number that was there rather than an empty pill.
  late int _shown = widget.count;

  @override
  void didUpdateWidget(AnimatedCountBadge old) {
    super.didUpdateWidget(old);
    if (widget.count > 0) {
      _shown = widget.count;
      if (_ctrl.status != AnimationStatus.forward && _ctrl.value < 1.0) {
        _ctrl.forward();
      }
    } else if (old.count > 0) {
      _ctrl.reverse();
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final h = widget.height;
    return AnimatedBuilder(
      animation: _ctrl,
      builder: (context, child) {
        if (_ctrl.value == 0.0) return const SizedBox.shrink();
        return Opacity(
          opacity: _fade.value.clamp(0.0, 1.0),
          child: Transform.scale(
            scale: 0.3 + 0.7 * _scale.value,
            child: child,
          ),
        );
      },
      child: Container(
        constraints: BoxConstraints(minWidth: h),
        height: h,
        padding: EdgeInsets.symmetric(horizontal: h * 0.25),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: widget.color,
          borderRadius: BorderRadius.circular(h / 2),
          border: widget.borderColor == null
              ? null
              : Border.all(
                  color: widget.borderColor!, width: widget.borderWidth),
        ),
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 260),
          transitionBuilder: (child, anim) => FadeTransition(
            opacity: anim,
            child: SlideTransition(
              position: Tween<Offset>(
                begin: const Offset(0, 0.45),
                end: Offset.zero,
              ).animate(anim),
              child: child,
            ),
          ),
          child: Text(
            _shown > 99 ? '99+' : '$_shown',
            key: ValueKey<int>(_shown),
            style: TextStyle(
              fontFamily: 'Poppins',
              color: widget.textColor,
              fontSize: widget.fontSize,
              fontWeight: FontWeight.w800,
              height: 1.0,
            ),
          ),
        ),
      ),
    );
  }
}
