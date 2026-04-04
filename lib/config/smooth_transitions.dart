import 'package:flutter/material.dart';

/// Transiciones ultra-suaves y profesionales para toda la app
/// Todas las curvas están optimizadas para 60 FPS
class SmoothTransitions {
  SmoothTransitions._();

  // ── Duraciones ──
  static const Duration _quick = Duration(milliseconds: 200);
  static const Duration _normal = Duration(milliseconds: 300);
  static const Duration _smooth = Duration(milliseconds: 400);
  static const Duration _dramatic = Duration(milliseconds: 500);

  // ── Curvas optimizadas ──
  static const Curve _easeOutExpo = Cubic(0.16, 1, 0.3, 1);
  static const Curve _easeInOutQuint = Cubic(0.83, 0, 0.17, 1);
  static const Curve _easeOutBack = Cubic(0.34, 1.56, 0.64, 1);
  static const Curve _easeOutQuart = Cubic(0.25, 1, 0.5, 1);
  static const Curve _spring = Cubic(0.175, 0.885, 0.32, 1.275);

  // ═══════════════════════════════════════════════════════════
  // TRANSICIONES DE PÁGINA COMPLETAS — pure fade only
  // ═══════════════════════════════════════════════════════════

  static const _fadeDuration = Duration(milliseconds: 280);
  static const _fadeReverse = Duration(milliseconds: 220);

  /// Forward navigation — smooth fade in/out (no slide)
  static PageRouteBuilder<T> fadeSlide<T>({
    required Widget page,
    bool fromRight = true,
  }) {
    return PageRouteBuilder<T>(
      transitionDuration: _fadeDuration,
      reverseTransitionDuration: _fadeReverse,
      pageBuilder: (context, animation, secondaryAnimation) => page,
      transitionsBuilder: (context, animation, secondaryAnimation, child) {
        return FadeTransition(
          opacity: CurvedAnimation(parent: animation, curve: Curves.easeInOut),
          child: child,
        );
      },
    );
  }

  /// Modal/dialog navigation — smooth fade in/out (no slide/scale)
  static PageRouteBuilder<T> scaleFade<T>(Widget page) {
    return PageRouteBuilder<T>(
      transitionDuration: _fadeDuration,
      reverseTransitionDuration: _fadeReverse,
      pageBuilder: (context, animation, secondaryAnimation) => page,
      transitionsBuilder: (context, animation, secondaryAnimation, child) {
        return FadeTransition(
          opacity: CurvedAnimation(parent: animation, curve: Curves.easeInOut),
          child: child,
        );
      },
    );
  }

  /// Modal/overlay navigation — smooth fade in/out (no slide)
  static PageRouteBuilder<T> slideUp<T>(Widget page) {
    return PageRouteBuilder<T>(
      transitionDuration: const Duration(milliseconds: 350),
      reverseTransitionDuration: const Duration(milliseconds: 280),
      pageBuilder: (context, animation, secondaryAnimation) => page,
      transitionsBuilder: (context, animation, secondaryAnimation, child) {
        return FadeTransition(
          opacity: CurvedAnimation(parent: animation, curve: Curves.easeInOut),
          child: child,
        );
      },
    );
  }

  /// Fade transition for shared element routes
  static PageRouteBuilder<T> sharedAxis<T>({
    required Widget page,
    Axis axis = Axis.horizontal,
  }) {
    return PageRouteBuilder<T>(
      transitionDuration: _fadeDuration,
      reverseTransitionDuration: _fadeReverse,
      pageBuilder: (context, animation, secondaryAnimation) => page,
      transitionsBuilder: (context, animation, secondaryAnimation, child) {
        return FadeTransition(
          opacity: CurvedAnimation(parent: animation, curve: Curves.easeInOut),
          child: child,
        );
      },
    );
  }

  /// Fade transition for circular reveal
  static PageRouteBuilder<T> circularReveal<T>({
    required Widget page,
    required Offset center,
  }) {
    return PageRouteBuilder<T>(
      transitionDuration: _fadeDuration,
      reverseTransitionDuration: _fadeReverse,
      pageBuilder: (context, animation, secondaryAnimation) => page,
      transitionsBuilder: (context, animation, secondaryAnimation, child) {
        return FadeTransition(
          opacity: CurvedAnimation(parent: animation, curve: Curves.easeInOut),
          child: child,
        );
      },
    );
  }

  // ═══════════════════════════════════════════════════════════
  // MICRO-TRANSICIONES PARA WIDGETS
  // ═══════════════════════════════════════════════════════════

  /// Fade in suave para cualquier widget
  static Widget fadeIn({
    required Widget child,
    Duration delay = Duration.zero,
    Duration duration = _normal,
  }) {
    return _DelayedFadeIn(
      delay: delay,
      duration: duration,
      child: child,
    );
  }

  /// Scale in con bounce sutil
  static Widget scaleIn({
    required Widget child,
    Duration delay = Duration.zero,
  }) {
    return _ScaleIn(
      delay: delay,
      child: child,
    );
  }

  /// Slide in desde abajo
  static Widget slideInUp({
    required Widget child,
    Duration delay = Duration.zero,
  }) {
    return _SlideInUp(
      delay: delay,
      child: child,
    );
  }

  /// Stagger animation para listas
  static Widget staggeredList({
    required List<Widget> children,
    Duration itemDelay = const Duration(milliseconds: 50),
  }) {
    return _StaggeredList(
      itemDelay: itemDelay,
      children: children,
    );
  }

  // ═══════════════════════════════════════════════════════════
  // EFECTOS DE PRESION Y FEEDBACK
  // ═══════════════════════════════════════════════════════════

  /// Botón con feedback táctil suave
  static Widget smoothButton({
    required Widget child,
    required VoidCallback onTap,
    double scaleDown = 0.97,
  }) {
    return _SmoothPressable(
      onTap: onTap,
      scaleDown: scaleDown,
      child: child,
    );
  }

  /// Card con elevación animada al hover/tap
  static Widget smoothCard({
    required Widget child,
    VoidCallback? onTap,
  }) {
    return _SmoothCard(
      onTap: onTap,
      child: child,
    );
  }
}

// ═══════════════════════════════════════════════════════════
// IMPLEMENTACIÓN DE WIDGETS INTERNOS
// ═══════════════════════════════════════════════════════════

class _CircularRevealClipper extends CustomClipper<Path> {
  final Offset center;
  final double radius;

  _CircularRevealClipper({required this.center, required this.radius});

  @override
  Path getClip(Size size) {
    return Path()
      ..addOval(Rect.fromCircle(center: center, radius: radius));
  }

  @override
  bool shouldReclip(_CircularRevealClipper oldClipper) {
    return oldClipper.radius != radius || oldClipper.center != center;
  }
}

class _DelayedFadeIn extends StatefulWidget {
  final Duration delay;
  final Duration duration;
  final Widget child;

  const _DelayedFadeIn({
    required this.delay,
    required this.duration,
    required this.child,
  });

  @override
  State<_DelayedFadeIn> createState() => _DelayedFadeInState();
}

class _DelayedFadeInState extends State<_DelayedFadeIn>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _animation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: widget.duration,
    );
    _animation = CurvedAnimation(
      parent: _controller,
      curve: Curves.easeOut,
    );
    Future.delayed(widget.delay, () {
      if (mounted) _controller.forward();
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _animation,
      child: widget.child,
    );
  }
}

class _ScaleIn extends StatefulWidget {
  final Duration delay;
  final Widget child;

  const _ScaleIn({required this.delay, required this.child});

  @override
  State<_ScaleIn> createState() => _ScaleInState();
}

class _ScaleInState extends State<_ScaleIn>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _animation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 400),
    );
    _animation = Tween<double>(begin: 0.8, end: 1.0).animate(
      CurvedAnimation(
        parent: _controller,
        curve: const Cubic(0.175, 0.885, 0.32, 1.275),
      ),
    );
    Future.delayed(widget.delay, () {
      if (mounted) _controller.forward();
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _animation,
      child: ScaleTransition(
        scale: _animation,
        child: widget.child,
      ),
    );
  }
}

class _SlideInUp extends StatefulWidget {
  final Duration delay;
  final Widget child;

  const _SlideInUp({required this.delay, required this.child});

  @override
  State<_SlideInUp> createState() => _SlideInUpState();
}

class _SlideInUpState extends State<_SlideInUp>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<Offset> _animation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 400),
    );
    _animation = Tween<Offset>(
      begin: const Offset(0, 0.2),
      end: Offset.zero,
    ).animate(CurvedAnimation(
      parent: _controller,
      curve: const Cubic(0.16, 1, 0.3, 1),
    ));
    Future.delayed(widget.delay, () {
      if (mounted) _controller.forward();
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _controller,
      child: SlideTransition(
        position: _animation,
        child: widget.child,
      ),
    );
  }
}

class _StaggeredList extends StatelessWidget {
  final List<Widget> children;
  final Duration itemDelay;

  const _StaggeredList({
    required this.children,
    required this.itemDelay,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      children: children.asMap().entries.map((entry) {
        return SmoothTransitions.fadeIn(
          delay: itemDelay * entry.key,
          child: entry.value,
        );
      }).toList(),
    );
  }
}

class _SmoothPressable extends StatefulWidget {
  final Widget child;
  final VoidCallback onTap;
  final double scaleDown;

  const _SmoothPressable({
    required this.child,
    required this.onTap,
    required this.scaleDown,
  });

  @override
  State<_SmoothPressable> createState() => _SmoothPressableState();
}

class _SmoothPressableState extends State<_SmoothPressable>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _animation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 100),
      reverseDuration: const Duration(milliseconds: 200),
    );
    _animation = Tween<double>(begin: 1.0, end: widget.scaleDown).animate(
      CurvedAnimation(
        parent: _controller,
        curve: Curves.easeOut,
        reverseCurve: const Cubic(0.175, 0.885, 0.32, 1.275),
      ),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTapDown: (_) => _controller.forward(),
      onTapUp: (_) {
        _controller.reverse();
        widget.onTap();
      },
      onTapCancel: () => _controller.reverse(),
      child: ScaleTransition(
        scale: _animation,
        child: widget.child,
      ),
    );
  }
}

class _SmoothCard extends StatefulWidget {
  final Widget child;
  final VoidCallback? onTap;

  const _SmoothCard({required this.child, this.onTap});

  @override
  State<_SmoothCard> createState() => _SmoothCardState();
}

class _SmoothCardState extends State<_SmoothCard>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _elevation;
  late Animation<double> _scale;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 200),
    );
    _elevation = Tween<double>(begin: 2, end: 8).animate(_controller);
    _scale = Tween<double>(begin: 1.0, end: 1.02).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeOut),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => _controller.forward(),
      onExit: (_) => _controller.reverse(),
      child: GestureDetector(
        onTapDown: (_) => _controller.forward(),
        onTapUp: (_) {
          _controller.reverse();
          widget.onTap?.call();
        },
        onTapCancel: () => _controller.reverse(),
        child: AnimatedBuilder(
          animation: _controller,
          builder: (context, child) {
            return Transform.scale(
              scale: _scale.value,
              child: Material(
                elevation: _elevation.value,
                borderRadius: BorderRadius.circular(12),
                shadowColor: Colors.black26,
                child: widget.child,
              ),
            );
          },
        ),
      ),
    );
  }
}

/// Public scale-on-press wrapper. Drop it around any tappable widget to add
/// a subtle scale-down + spring-back animation on every tap.
///
/// Usage:
/// ```dart
/// TapScale(
///   onTap: () => ...,
///   child: YourButton(),
/// )
/// ```
class TapScale extends StatefulWidget {
  final Widget child;
  final VoidCallback? onTap;
  final double scale;

  const TapScale({
    super.key,
    required this.child,
    this.onTap,
    this.scale = 0.96,
  });

  @override
  State<TapScale> createState() => _TapScaleState();
}

class _TapScaleState extends State<TapScale> with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  late final Animation<double> _anim;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 90),
      reverseDuration: const Duration(milliseconds: 180),
    );
    _anim = Tween<double>(begin: 1.0, end: widget.scale).animate(
      CurvedAnimation(
        parent: _ctrl,
        curve: Curves.easeOut,
        reverseCurve: const Cubic(0.175, 0.885, 0.32, 1.275),
      ),
    );
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: (_) => _ctrl.forward(),
      onTapUp: (_) {
        _ctrl.reverse();
        widget.onTap?.call();
      },
      onTapCancel: () => _ctrl.reverse(),
      child: ScaleTransition(scale: _anim, child: widget.child),
    );
  }
}
