import 'package:flutter/physics.dart';
import 'package:flutter/widgets.dart';

/// Mixin providing velocity-aware spring animation for custom draggable panels.
///
/// Usage:
/// 1. Mix into a State that uses `TickerProviderStateMixin`
/// 2. Call [initPanelAnimation] in `initState`
/// 3. Call [disposePanelAnimation] in `dispose`
/// 4. Use [panelExtent] as the current 0..1 position
/// 5. In drag handlers, call [updatePanelDrag] and [endPanelDrag]
mixin VelocityAwarePanelMixin<T extends StatefulWidget>
    on State<T>, TickerProviderStateMixin<T> {
  late AnimationController _panelAnimCtrl;
  double _panelExtent = 0.0;

  /// Current normalized panel position (0 = collapsed, 1 = expanded).
  double get panelExtent => _panelExtent;
  set panelExtent(double v) => _panelExtent = v.clamp(0.0, 1.0);

  /// Height range the panel travels (expanded - collapsed).
  double get panelTravelHeight;

  /// Snap points sorted ascending (e.g. [0.0, 1.0] or [0.0, 0.5, 1.0]).
  List<double> get panelSnapPoints => const [0.0, 1.0];

  /// Velocity threshold (px/s) above which a fling overrides position snapping.
  double get flingThreshold => 700.0;

  void initPanelAnimation() {
    _panelAnimCtrl = AnimationController.unbounded(vsync: this);
    _panelAnimCtrl.addListener(_onPanelTick);
  }

  void disposePanelAnimation() {
    _panelAnimCtrl.removeListener(_onPanelTick);
    _panelAnimCtrl.dispose();
  }

  void _onPanelTick() {
    if (!mounted) return;
    setState(() {
      _panelExtent = _panelAnimCtrl.value.clamp(0.0, 1.0);
    });
  }

  /// Call from [onVerticalDragUpdate]. [primaryDelta] is `details.primaryDelta`.
  void updatePanelDrag(double primaryDelta) {
    _panelAnimCtrl.stop();
    setState(() {
      _panelExtent =
          (_panelExtent - primaryDelta / panelTravelHeight).clamp(0.0, 1.0);
    });
  }

  /// Call from [onVerticalDragEnd]. Animates to the appropriate snap point
  /// using spring physics whose initial velocity matches the user's fling.
  void endPanelDrag(double primaryVelocity) {
    final normalizedV = -primaryVelocity / panelTravelHeight;
    final target = _resolveSnapTarget(primaryVelocity);
    _springTo(target, normalizedV);
  }

  /// Programmatically animate to a snap point.
  void animatePanelTo(double target, {double velocity = 0.0}) {
    _springTo(target.clamp(0.0, 1.0), velocity);
  }

  double _resolveSnapTarget(double velocity) {
    final pts = List<double>.from(panelSnapPoints)..sort();
    // Fast fling → pick direction
    if (velocity.abs() > flingThreshold) {
      if (velocity < 0) {
        // Swipe up → next snap point above current
        for (final p in pts) {
          if (p > _panelExtent + 0.01) return p;
        }
        return pts.last;
      } else {
        // Swipe down → next snap point below current
        for (final p in pts.reversed) {
          if (p < _panelExtent - 0.01) return p;
        }
        return pts.first;
      }
    }
    // Slow release → nearest snap point
    double nearest = pts.first;
    double minDist = (_panelExtent - nearest).abs();
    for (final p in pts) {
      final d = (_panelExtent - p).abs();
      if (d < minDist) {
        minDist = d;
        nearest = p;
      }
    }
    return nearest;
  }

  void _springTo(double target, double normalizedVelocity) {
    final sim = SpringSimulation(
      const SpringDescription(mass: 1.0, stiffness: 600.0, damping: 32.0),
      _panelExtent,
      target,
      normalizedVelocity,
    );
    _panelAnimCtrl.animateWith(sim);
  }
}
