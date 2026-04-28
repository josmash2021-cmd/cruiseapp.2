import 'package:flutter/material.dart';

/// Smoothly animates changes to any value using AnimatedBuilder.
/// Prevents "de golpe" (abrupt) changes by interpolating between old and new values.
class SmoothAnimatedBuilder<T> extends StatefulWidget {
  final T value;
  final Duration duration;
  final Curve curve;
  final Widget Function(BuildContext context, T animatedValue) builder;

  const SmoothAnimatedBuilder({
    super.key,
    required this.value,
    required this.builder,
    this.duration = const Duration(milliseconds: 300),
    this.curve = Curves.easeOutQuart,
  });

  @override
  State<SmoothAnimatedBuilder<T>> createState() => _SmoothAnimatedBuilderState<T>();
}

class _SmoothAnimatedBuilderState<T> extends State<SmoothAnimatedBuilder<T>>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late T _oldValue;
  late T _newValue;

  @override
  void initState() {
    super.initState();
    _oldValue = widget.value;
    _newValue = widget.value;
    _controller = AnimationController(
      vsync: this,
      duration: widget.duration,
    );
  }

  @override
  void didUpdateWidget(covariant SmoothAnimatedBuilder<T> oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.value != oldWidget.value) {
      _oldValue = oldWidget.value;
      _newValue = widget.value;
      _controller.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        final t = widget.curve.transform(_controller.value);
        // For numeric types, interpolate
        if (_oldValue is double && _newValue is double) {
          final animated = (_oldValue as double) + ((_newValue as double) - (_oldValue as double)) * t;
          return widget.builder(context, animated as T);
        }
        if (_oldValue is int && _newValue is int) {
          final animated = (_oldValue as int) + ((_newValue as int) - (_oldValue as int)) * t;
          return widget.builder(context, animated.round() as T);
        }
        // For other types, just show new value after halfway
        return widget.builder(context, t > 0.5 ? _newValue : _oldValue);
      },
    );
  }
}

/// Fade + slide transition for widgets that appear/disappear.
/// Never shows/hides anything "de golpe".
class SmoothAppear extends StatefulWidget {
  final Widget child;
  final bool visible;
  final Duration duration;
  final Offset slideOffset;

  const SmoothAppear({
    super.key,
    required this.child,
    required this.visible,
    this.duration = const Duration(milliseconds: 300),
    this.slideOffset = const Offset(0, 0.02),
  });

  @override
  State<SmoothAppear> createState() => _SmoothAppearState();
}

class _SmoothAppearState extends State<SmoothAppear>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: widget.duration,
      value: widget.visible ? 1.0 : 0.0,
    );
  }

  @override
  void didUpdateWidget(covariant SmoothAppear oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.visible != oldWidget.visible) {
      if (widget.visible) {
        _controller.forward();
      } else {
        _controller.reverse();
      }
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        final t = Curves.easeOutQuart.transform(_controller.value);
        return Opacity(
          opacity: t,
          child: Transform.translate(
            offset: Offset(
              widget.slideOffset.dx * (1 - t) * 20,
              widget.slideOffset.dy * (1 - t) * 20,
            ),
            child: child,
          ),
        );
      },
      child: widget.visible ? widget.child : const SizedBox.shrink(),
    );
  }
}

/// Smoothly animates the height of a widget (for expanding/collapsing).
class SmoothHeight extends StatefulWidget {
  final Widget child;
  final bool expanded;
  final Duration duration;

  const SmoothHeight({
    super.key,
    required this.child,
    required this.expanded,
    this.duration = const Duration(milliseconds: 300),
  });

  @override
  State<SmoothHeight> createState() => _SmoothHeightState();
}

class _SmoothHeightState extends State<SmoothHeight>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: widget.duration,
      value: widget.expanded ? 1.0 : 0.0,
    );
  }

  @override
  void didUpdateWidget(covariant SmoothHeight oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.expanded != oldWidget.expanded) {
      if (widget.expanded) {
        _controller.forward();
      } else {
        _controller.reverse();
      }
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        return ClipRect(
          child: Align(
            alignment: Alignment.topCenter,
            heightFactor: Curves.easeOutQuart.transform(_controller.value),
            child: Opacity(
              opacity: Curves.easeOut.transform(_controller.value),
              child: child,
            ),
          ),
        );
      },
      child: widget.child,
    );
  }
}
