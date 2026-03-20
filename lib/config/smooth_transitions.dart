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
  // TRANSICIONES DE PÁGINA COMPLETAS
  // ═══════════════════════════════════════════════════════════

  /// Transición fade suave con slide (la más usada)
  static PageRouteBuilder<T> fadeSlide<T>({
    required Widget page,
    bool fromRight = true,
  }) {
    return PageRouteBuilder<T>(
      transitionDuration: _smooth,
      reverseTransitionDuration: _normal,
      pageBuilder: (context, animation, secondaryAnimation) => page,
      transitionsBuilder: (context, animation, secondaryAnimation, child) {
        final slideAnimation = Tween<Offset>(
          begin: fromRight ? const Offset(0.08, 0) : const Offset(-0.08, 0),
          end: Offset.zero,
        ).animate(CurvedAnimation(
          parent: animation,
          curve: _easeOutExpo,
        ));

        final fadeAnimation = Tween<double>(
          begin: 0.0,
          end: 1.0,
        ).animate(CurvedAnimation(
          parent: animation,
          curve: const Interval(0.0, 0.6, curve: Curves.easeOut),
        ));

        final scaleAnimation = Tween<double>(
          begin: 0.96,
          end: 1.0,
        ).animate(CurvedAnimation(
          parent: animation,
          curve: _easeOutQuart,
        ));

        return FadeTransition(
          opacity: fadeAnimation,
          child: SlideTransition(
            position: slideAnimation,
            child: ScaleTransition(
              scale: scaleAnimation,
              child: child,
            ),
          ),
        );
      },
    );
  }

  /// Transición scale con fade (para modales/dialogs)
  static PageRouteBuilder<T> scaleFade<T>(Widget page) {
    return PageRouteBuilder<T>(
      transitionDuration: _smooth,
      reverseTransitionDuration: _quick,
      pageBuilder: (context, animation, secondaryAnimation) => page,
      transitionsBuilder: (context, animation, secondaryAnimation, child) {
        final scaleAnimation = Tween<double>(
          begin: 0.85,
          end: 1.0,
        ).animate(CurvedAnimation(
          parent: animation,
          curve: _spring,
        ));

        final fadeAnimation = Tween<double>(
          begin: 0.0,
          end: 1.0,
        ).animate(CurvedAnimation(
          parent: animation,
          curve: const Interval(0.0, 0.5, curve: Curves.easeOut),
        ));

        return FadeTransition(
          opacity: fadeAnimation,
          child: ScaleTransition(
            scale: scaleAnimation,
            alignment: Alignment.center,
            child: child,
          ),
        );
      },
    );
  }

  /// Transición slide vertical (para bottom sheets/full screen)
  static PageRouteBuilder<T> slideUp<T>(Widget page) {
    return PageRouteBuilder<T>(
      transitionDuration: _smooth,
      reverseTransitionDuration: _normal,
      pageBuilder: (context, animation, secondaryAnimation) => page,
      transitionsBuilder: (context, animation, secondaryAnimation, child) {
        final slideAnimation = Tween<Offset>(
          begin: const Offset(0, 0.15),
          end: Offset.zero,
        ).animate(CurvedAnimation(
          parent: animation,
          curve: _easeOutBack,
        ));

        final fadeAnimation = Tween<double>(
          begin: 0.0,
          end: 1.0,
        ).animate(CurvedAnimation(
          parent: animation,
          curve: const Interval(0.0, 0.4, curve: Curves.easeOut),
        ));

        return FadeTransition(
          opacity: fadeAnimation,
          child: SlideTransition(
            position: slideAnimation,
            child: child,
          ),
        );
      },
    );
  }

  /// Transición shared element (Hero-like para rutas)
  static PageRouteBuilder<T> sharedAxis<T>({
    required Widget page,
    Axis axis = Axis.horizontal,
  }) {
    return PageRouteBuilder<T>(
      transitionDuration: _smooth,
      reverseTransitionDuration: _normal,
      pageBuilder: (context, animation, secondaryAnimation) => page,
      transitionsBuilder: (context, animation, secondaryAnimation, child) {
        final isReversing = animation.status == AnimationStatus.reverse;

        final slideAnimation = Tween<Offset>(
          begin: axis == Axis.horizontal
              ? (isReversing ? const Offset(-0.1, 0) : const Offset(0.1, 0))
              : (isReversing ? const Offset(0, -0.1) : const Offset(0, 0.1)),
          end: Offset.zero,
        ).animate(CurvedAnimation(
          parent: animation,
          curve: _easeOutExpo,
        ));

        final fadeAnimation = Tween<double>(
          begin: 0.0,
          end: 1.0,
        ).animate(CurvedAnimation(
          parent: animation,
          curve: const Interval(0.1, 0.8, curve: Curves.easeOut),
        ));

        return FadeTransition(
          opacity: fadeAnimation,
          child: SlideTransition(
            position: slideAnimation,
            child: child,
          ),
        );
      },
    );
  }

  /// Transición circular reveal (para FAB a pantalla)
  static PageRouteBuilder<T> circularReveal<T>({
    required Widget page,
    required Offset center,
  }) {
    return PageRouteBuilder<T>(
      transitionDuration: _dramatic,
      reverseTransitionDuration: _smooth,
      pageBuilder: (context, animation, secondaryAnimation) => page,
      transitionsBuilder: (context, animation, secondaryAnimation, child) {
        final screenSize = MediaQuery.of(context).size;
        final maxRadius = screenSize.shortestSide * 1.5;

        final radiusAnimation = Tween<double>(
          begin: 0.0,
          end: maxRadius,
        ).animate(CurvedAnimation(
          parent: animation,
          curve: _easeOutExpo,
        ));

        final fadeAnimation = Tween<double>(
          begin: 0.0,
          end: 1.0,
        ).animate(CurvedAnimation(
          parent: animation,
          curve: const Interval(0.2, 0.8, curve: Curves.easeOut),
        ));

        return ClipPath(
          clipper: _CircularRevealClipper(
            center: center,
            radius: radiusAnimation.value,
          ),
          child: FadeTransition(
            opacity: fadeAnimation,
            child: child,
          ),
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
    return ScaleTransition(
      scale: _animation,
      child: FadeTransition(
        opacity: _animation,
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
    return SlideTransition(
      position: _animation,
      child: FadeTransition(
        opacity: _controller,
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
