import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart' show DragStartBehavior;
import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

import '../l10n/app_localizations.dart';
import '../services/support_bubble_controller.dart';
import 'animated_count_badge.dart';
import 'neu_style.dart';

/// The rider's floating support bubble (owner 2026-11-07): when support
/// writes to the rider — or the rider writes to support — a gold-ringed
/// bubble floats over every screen; a tap opens the support chat.
///
/// Mounted once above the navigator (MaterialApp `builder:` in main.dart);
/// [SupportBubbleController] decides when it is visible. Solid surface and
/// a drop shadow, never a backdrop blur: over the Mapbox map iOS draws a
/// blur RECTANGULAR (CLAUDE.md #43).
///
/// Draggable: it follows the finger and springs to the nearest side edge;
/// dropped on the close target at the bottom it hides until a newer
/// message. A new support message pops a generic preview next to it —
/// never the message text (owner rule for support notices).
///
/// Constants are top-level (project rule #16).

const kSupportBubbleSize = 58.0;
const kSupportBubbleGold = Color(0xFFE8C547);
const kSupportBubbleRingWidth = 1.5;

/// Gap to the side edge it docks on (inside the safe area).
const kSupportBubbleEdgeMargin = 12.0;

/// Below the status bar / safe-area top.
const kSupportBubbleTopGap = 8.0;

/// Kept this far above the bottom of the safe area (home indicator, the
/// screens' bottom buttons).
const kSupportBubbleBottomClear = 120.0;

/// Where it first docks: right edge, centre at 45 % of the screen height.
const kSupportBubbleDefaultYFraction = 0.45;

const kSupportBubbleInDuration = Duration(milliseconds: 380);
const kSupportBubbleOutDuration = Duration(milliseconds: 220);
const kSupportBubblePulseDuration = Duration(milliseconds: 560);

/// How long the "Support wrote to you" preview stays.
const kSupportBubblePreviewFor = Duration(milliseconds: 4500);
const kSupportBubblePreviewMaxWidth = 230.0;
const kSupportBubblePreviewGap = 10.0;

/// The close target that fades in at bottom-centre while dragging.
const kSupportBubbleDismissSize = 56.0;
const kSupportBubbleDismissBottom = 40.0;

/// Bubble centre within this distance of the target centre = drop closes.
const kSupportBubbleDismissCatch = 64.0;

/// The snap to the edge: a touch under critical damping, a small settle.
const kSupportBubbleSpring =
    SpringDescription(mass: 1, stiffness: 420, damping: 30);

/// The overlay. [onOpen] opens the support chat at that id (main.dart's
/// `_navigateToSupportChat`).
class SupportBubbleOverlay extends StatefulWidget {
  const SupportBubbleOverlay({
    super.key,
    required this.controller,
    required this.onOpen,
    this.observeLifecycle = true,
  });

  final SupportBubbleController controller;
  final void Function(int chatId) onOpen;

  /// Forward the app lifecycle to the controller (off in widget tests).
  final bool observeLifecycle;

  @override
  State<SupportBubbleOverlay> createState() => _SupportBubbleOverlayState();
}

class _Bounds {
  const _Bounds({
    required this.width,
    required this.height,
    required this.minX,
    required this.maxX,
    required this.minY,
    required this.maxY,
    required this.dragMinY,
    required this.dragMaxY,
    required this.targetCenter,
  });

  static const zero = _Bounds(
    width: 0,
    height: 0,
    minX: 0,
    maxX: 0,
    minY: 0,
    maxY: 0,
    dragMinY: 0,
    dragMaxY: 0,
    targetCenter: Offset.zero,
  );

  factory _Bounds.of(Size size, EdgeInsets pad, double keyboard) {
    const s = kSupportBubbleSize;
    final minX = pad.left + kSupportBubbleEdgeMargin;
    final maxX =
        math.max(minX, size.width - pad.right - kSupportBubbleEdgeMargin - s);
    final minY = pad.top + kSupportBubbleTopGap;
    final reserve = math.max(pad.bottom + kSupportBubbleBottomClear,
        keyboard + kSupportBubbleEdgeMargin);
    final maxY = math.max(minY, size.height - reserve - s);
    final dragMinY = pad.top;
    final dragMaxY =
        math.max(dragMinY, size.height - math.max(pad.bottom, keyboard) - s);
    final targetY = size.height -
        math.max(pad.bottom, keyboard) -
        kSupportBubbleDismissBottom -
        kSupportBubbleDismissSize / 2;
    return _Bounds(
      width: size.width,
      height: size.height,
      minX: minX,
      maxX: maxX,
      minY: minY,
      maxY: maxY,
      dragMinY: dragMinY,
      dragMaxY: dragMaxY,
      targetCenter: Offset(size.width / 2, targetY),
    );
  }

  final double width;
  final double height;
  final double minX;
  final double maxX;
  final double minY;
  final double maxY;
  final double dragMinY;
  final double dragMaxY;
  final Offset targetCenter;

  double get defaultY =>
      height * kSupportBubbleDefaultYFraction - kSupportBubbleSize / 2;

  Offset get targetTopLeft =>
      targetCenter - const Offset(kSupportBubbleSize / 2, kSupportBubbleSize / 2);
}

class _SupportBubbleOverlayState extends State<SupportBubbleOverlay>
    with TickerProviderStateMixin, WidgetsBindingObserver {
  late final AnimationController _appear = AnimationController(
    vsync: this,
    duration: kSupportBubbleInDuration,
    reverseDuration: kSupportBubbleOutDuration,
  );
  late final Animation<double> _appearScale = CurvedAnimation(
    parent: _appear,
    curve: Curves.easeOutBack,
    reverseCurve: Curves.easeInCubic,
  );
  late final Animation<double> _appearFade = CurvedAnimation(
    parent: _appear,
    curve: const Interval(0.0, 0.6, curve: Curves.easeOut),
    reverseCurve: Curves.easeIn,
  );

  /// Free position while dragging / springing (top-left of the bubble).
  late final AnimationController _x = AnimationController.unbounded(vsync: this);
  late final AnimationController _y = AnimationController.unbounded(vsync: this);

  late final AnimationController _pulse =
      AnimationController(vsync: this, duration: kSupportBubblePulseDuration);
  late final AnimationController _preview = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 260),
    reverseDuration: const Duration(milliseconds: 220),
  );
  late final AnimationController _target = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 200),
  );

  /// Pulls the bubble onto the close target while it is over it.
  late final AnimationController _magnet = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 160),
  );

  Timer? _previewTimer;
  Timer? _previewDelay;

  _Bounds _b = _Bounds.zero;

  /// Docked side and resting top (null = the default spot).
  bool _right = true;
  double? _yRest;

  bool _dragging = false;
  bool _armed = false;
  bool _springing = false;
  int _springGen = 0;

  /// Dropped on the close target: drawn there until it has faded out,
  /// then back to where it rested before the drag.
  bool _dropped = false;
  bool _restRight = true;
  double? _restY;

  bool _shown = false;
  int _seenPreviewSeq = 0;
  bool _rebuildQueued = false;

  SupportBubbleController get _c => widget.controller;

  @override
  void initState() {
    super.initState();
    _seenPreviewSeq = _c.previewSeq;
    _c.addListener(_onControllerChanged);
    if (widget.observeLifecycle) WidgetsBinding.instance.addObserver(this);
    _appear.addStatusListener(_onAppearStatus);
    _shown = _c.visible;
    if (_shown) _appear.value = 1;
    _c.overlayMounted();
  }

  @override
  void didUpdateWidget(SupportBubbleOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_onControllerChanged);
      oldWidget.controller.overlayUnmounted();
      widget.controller.addListener(_onControllerChanged);
      widget.controller.overlayMounted();
      _seenPreviewSeq = widget.controller.previewSeq;
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _c.appLifecycleChanged(state);
  }

  @override
  void dispose() {
    _c.removeListener(_onControllerChanged);
    _c.overlayUnmounted();
    if (widget.observeLifecycle) WidgetsBinding.instance.removeObserver(this);
    _previewTimer?.cancel();
    _previewDelay?.cancel();
    _appear.dispose();
    _x.dispose();
    _y.dispose();
    _pulse.dispose();
    _preview.dispose();
    _target.dispose();
    _magnet.dispose();
    super.dispose();
  }

  /// Controller changes can land mid-frame (a chat screen's initState /
  /// dispose, a navigator callback): setState then waits for the frame end.
  void _onControllerChanged() {
    if (!mounted) return;
    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      if (_rebuildQueued) return;
      _rebuildQueued = true;
      SchedulerBinding.instance.addPostFrameCallback((_) {
        _rebuildQueued = false;
        if (mounted) _sync();
      });
      SchedulerBinding.instance.ensureVisualUpdate();
      return;
    }
    _sync();
  }

  void _sync() {
    final vis = _c.visible;
    if (vis != _shown) {
      _shown = vis;
      if (vis) {
        _appear.forward();
      } else {
        _hidePreview();
        if (_dragging) _endDragInPlace();
        _appear.reverse();
      }
    }
    if (_c.previewSeq != _seenPreviewSeq) {
      _seenPreviewSeq = _c.previewSeq;
      if (vis) _schedulePreview(haptic: _c.previewHaptic);
    }
    setState(() {});
  }

  void _onAppearStatus(AnimationStatus status) {
    if (status != AnimationStatus.dismissed || !mounted) return;
    if (_dropped) {
      setState(() {
        _dropped = false;
        _right = _restRight;
        _yRest = _restY;
        _magnet.value = 0;
      });
    }
  }

  // ── Preview ──

  void _schedulePreview({required bool haptic}) {
    _previewDelay?.cancel();
    // Wait for the entrance to land first.
    final left = _appear.value >= 1
        ? Duration.zero
        : Duration(
            milliseconds: (kSupportBubbleInDuration.inMilliseconds *
                        (1 - _appear.value))
                    .round() +
                60);
    _previewDelay = Timer(left, () {
      _previewDelay = null;
      if (!mounted || !_shown || _dragging) return;
      _showPreview(haptic: haptic);
    });
  }

  void _showPreview({required bool haptic}) {
    _previewTimer?.cancel();
    _preview.forward();
    _pulse.forward(from: 0);
    if (haptic) {
      unawaited(HapticFeedback.lightImpact().catchError((Object _) {}));
    }
    _previewTimer = Timer(kSupportBubblePreviewFor, () {
      _previewTimer = null;
      if (mounted) _preview.reverse();
    });
  }

  void _hidePreview() {
    _previewDelay?.cancel();
    _previewDelay = null;
    _previewTimer?.cancel();
    _previewTimer = null;
    if (_preview.value > 0) _preview.reverse();
  }

  // ── Tap ──

  void _open() {
    final id = _c.chatId;
    if (id == null || !_shown) return;
    _hidePreview();
    widget.onOpen(id);
  }

  void _dismissFromSemantics() {
    if (!_shown) return;
    _hidePreview();
    _c.dismiss();
  }

  // ── Drag ──

  Offset get _restingTopLeft => Offset(
        _right ? _b.maxX : _b.minX,
        (_yRest ?? _b.defaultY).clamp(_b.minY, _b.maxY).toDouble(),
      );

  bool get _free => _dragging || _springing || _dropped;

  Offset get _drawnTopLeft {
    final raw = _free ? Offset(_x.value, _y.value) : _restingTopLeft;
    final m = Curves.easeOutCubic.transform(_magnet.value);
    return m == 0 ? raw : Offset.lerp(raw, _b.targetTopLeft, m)!;
  }

  void _onPanStart(DragStartDetails d) {
    if (!_shown) return;
    final at = _drawnTopLeft;
    _springGen++;
    _x.stop();
    _y.stop();
    _x.value = at.dx;
    _y.value = at.dy;
    if (!_springing) {
      _restRight = _right;
      _restY = _yRest;
    }
    _springing = false;
    _dragging = true;
    _armed = false;
    _hidePreview();
    _target.forward();
    setState(() {});
  }

  void _onPanUpdate(DragUpdateDetails d) {
    if (!_dragging) return;
    _x.value = (_x.value + d.delta.dx)
        .clamp(0.0, math.max(0.0, _b.width - kSupportBubbleSize))
        .toDouble();
    _y.value =
        (_y.value + d.delta.dy).clamp(_b.dragMinY, _b.dragMaxY).toDouble();
    final centre = Offset(_x.value, _y.value) +
        const Offset(kSupportBubbleSize / 2, kSupportBubbleSize / 2);
    final armed =
        (centre - _b.targetCenter).distance < kSupportBubbleDismissCatch;
    if (armed != _armed) {
      _armed = armed;
      if (armed) {
        _magnet.forward();
        unawaited(HapticFeedback.selectionClick().catchError((Object _) {}));
      } else {
        _magnet.reverse();
      }
      setState(() {});
    }
  }

  void _onPanEnd(DragEndDetails d) {
    if (!_dragging) return;
    _dragging = false;
    _target.reverse();
    if (_armed) {
      _armed = false;
      // Stays on the target while it fades out, then back to its spot.
      _x.value = _b.targetTopLeft.dx;
      _y.value = _b.targetTopLeft.dy;
      _magnet.value = 0;
      _dropped = true;
      unawaited(HapticFeedback.mediumImpact().catchError((Object _) {}));
      _c.dismiss();
      setState(() {});
      return;
    }
    _magnet.reverse();
    final centreX = _x.value + kSupportBubbleSize / 2;
    _right = centreX >= _b.width / 2;
    final tx = _right ? _b.maxX : _b.minX;
    final ty = _y.value.clamp(_b.minY, _b.maxY).toDouble();
    _yRest = ty;
    final v = d.velocity.pixelsPerSecond;
    final gen = ++_springGen;
    _springing = true;
    var running = 2;
    void done() {
      if (--running > 0 || gen != _springGen || !mounted) return;
      setState(() => _springing = false);
    }

    _x
        .animateWith(SpringSimulation(kSupportBubbleSpring, _x.value, tx, v.dx))
        .whenCompleteOrCancel(done);
    _y
        .animateWith(
            SpringSimulation(kSupportBubbleSpring, _y.value, ty, v.dy * 0.4))
        .whenCompleteOrCancel(done);
    setState(() {});
  }

  /// Hidden mid-drag (a chat opened, a sheet came up): dock where it is.
  void _endDragInPlace() {
    _dragging = false;
    _armed = false;
    _magnet.value = 0;
    _target.reverse();
    _right = _x.value + kSupportBubbleSize / 2 >= _b.width / 2;
    _yRest = _y.value.clamp(_b.minY, _b.maxY).toDouble();
  }

  // ── Build ──

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    return LayoutBuilder(
      builder: (context, box) {
        _b = _Bounds.of(box.biggest, mq.padding, mq.viewInsets.bottom);
        return AnimatedBuilder(
          animation: Listenable.merge(
              [_appear, _x, _y, _pulse, _preview, _target, _magnet]),
          builder: (context, _) => _layer(context),
        );
      },
    );
  }

  Widget _layer(BuildContext context) {
    if (_appear.value == 0 && _target.value == 0 && _preview.value == 0) {
      return const SizedBox.shrink();
    }
    final s = S.of(context);
    final at = _drawnTopLeft;
    final children = <Widget>[];

    if (_target.value > 0) {
      final t = Curves.easeOut.transform(_target.value);
      // Keyed: the list changes while a drag is live, and an unkeyed swap
      // would hand the bubble's gesture state to another child.
      children.add(Positioned(
        key: const ValueKey('layer-target'),
        left: _b.targetCenter.dx - kSupportBubbleDismissSize / 2,
        top: _b.targetCenter.dy - kSupportBubbleDismissSize / 2,
        width: kSupportBubbleDismissSize,
        height: kSupportBubbleDismissSize,
        child: IgnorePointer(
          child: Opacity(
            opacity: t,
            child: Transform.translate(
              offset: Offset(0, 16 * (1 - t)),
              child: AnimatedScale(
                scale: _armed ? 1.18 : 1.0,
                duration: const Duration(milliseconds: 160),
                curve: Curves.easeOutBack,
                child: SupportBubbleDismissTarget(armed: _armed),
              ),
            ),
          ),
        ),
      ));
    }

    if (_preview.value > 0) {
      final t = Curves.easeOutCubic.transform(_preview.value);
      final onRight = at.dx + kSupportBubbleSize / 2 >= _b.width / 2;
      final room = onRight
          ? at.dx - kSupportBubblePreviewGap - kSupportBubbleEdgeMargin
          : _b.width -
              (at.dx + kSupportBubbleSize + kSupportBubblePreviewGap) -
              kSupportBubbleEdgeMargin;
      if (room > 80) {
        children.add(Positioned(
          key: const ValueKey('layer-preview'),
          top: at.dy - 24,
          height: kSupportBubbleSize + 48,
          left: onRight
              ? null
              : at.dx + kSupportBubbleSize + kSupportBubblePreviewGap,
          right: onRight ? _b.width - at.dx + kSupportBubblePreviewGap : null,
          child: Align(
            alignment: onRight ? Alignment.centerRight : Alignment.centerLeft,
            child: Opacity(
              opacity: t,
              child: Transform.translate(
                offset: Offset((onRight ? 12 : -12) * (1 - t), 0),
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                    maxWidth: math.min(kSupportBubblePreviewMaxWidth, room),
                  ),
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: _open,
                    child: SupportBubblePreview(
                      title: s.supportBubblePreviewTitle,
                      body: s.supportBubblePreviewBody,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ));
      }
    }

    if (_appear.value > 0) {
      final pulse = 1 + 0.12 * math.sin(math.pi * _pulse.value);
      final scale = (0.6 + 0.4 * _appearScale.value) * pulse;
      final unread = _c.unread;
      final label = unread > 0
          ? '${s.supportBubbleLabel}, ${s.supportBubbleUnread(unread)}'
          : s.supportBubbleLabel;
      children.add(Positioned(
        key: const ValueKey('layer-bubble'),
        left: at.dx,
        top: at.dy,
        width: kSupportBubbleSize,
        height: kSupportBubbleSize,
        child: IgnorePointer(
          ignoring: !_shown,
          child: Opacity(
            opacity: _appearFade.value.clamp(0.0, 1.0),
            child: Transform.scale(
              scale: scale,
              child: Semantics(
                button: true,
                label: label,
                onTap: _open,
                onDismiss: _dismissFromSemantics,
                excludeSemantics: true,
                child: GestureDetector(
                  key: const ValueKey('support-bubble'),
                  behavior: HitTestBehavior.opaque,
                  // From the touch-down: the bubble stays under the finger
                  // (with `start` it would lag by the drag slop).
                  dragStartBehavior: DragStartBehavior.down,
                  onTap: _open,
                  onPanStart: _onPanStart,
                  onPanUpdate: _onPanUpdate,
                  onPanEnd: _onPanEnd,
                  onPanCancel: () {
                    if (_dragging) {
                      _onPanEnd(DragEndDetails());
                    }
                  },
                  child: SupportBubbleButton(unread: unread),
                ),
              ),
            ),
          ),
        ),
      ));
    }

    return DefaultTextStyle(
      style: const TextStyle(
        fontFamily: 'Poppins',
        color: Colors.white,
        fontSize: 13,
        decoration: TextDecoration.none,
      ),
      child: Stack(children: children),
    );
  }
}

/// The bubble itself: solid [neuBase] circle, gold ring, soft drop shadow,
/// gold support icon, and the unread count top-right (hidden at 0).
class SupportBubbleButton extends StatelessWidget {
  const SupportBubbleButton({super.key, required this.unread});

  final int unread;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: kSupportBubbleSize,
      height: kSupportBubbleSize,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: neuBase,
                border: Border.all(
                  color: kSupportBubbleGold,
                  width: kSupportBubbleRingWidth,
                ),
                boxShadow: const [
                  BoxShadow(
                    color: Color(0x73000000), // black 45 %
                    blurRadius: 14,
                    offset: Offset(0, 5),
                    spreadRadius: -1,
                  ),
                ],
              ),
              child: const Center(
                child: Icon(
                  Icons.support_agent_rounded,
                  color: kSupportBubbleGold,
                  size: 28,
                ),
              ),
            ),
          ),
          Positioned(
            top: -4,
            right: -4,
            child: AnimatedCountBadge(
              count: unread,
              height: 21,
              fontSize: 11,
              borderColor: neuBase,
              borderWidth: 2,
            ),
          ),
        ],
      ),
    );
  }
}

/// The generic two-line preview: who wrote, and what a tap does. Solid
/// dark surface with a hairline rim — no blur.
class SupportBubblePreview extends StatelessWidget {
  const SupportBubblePreview({
    super.key,
    required this.title,
    required this.body,
  });

  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 9, 14, 10),
      decoration: BoxDecoration(
        color: neuSurface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: Colors.white.withValues(alpha: 0.09),
          width: 0.8,
        ),
        boxShadow: const [
          BoxShadow(
            color: Color(0x66000000),
            blurRadius: 14,
            offset: Offset(0, 5),
            spreadRadius: -2,
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontFamily: 'Poppins',
              color: Colors.white,
              fontSize: 13,
              fontWeight: FontWeight.w700,
              height: 1.3,
              decoration: TextDecoration.none,
            ),
          ),
          const SizedBox(height: 1),
          Text(
            body,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontFamily: 'Poppins',
              color: Colors.white.withValues(alpha: 0.7),
              fontSize: 13,
              fontWeight: FontWeight.w400,
              height: 1.3,
              decoration: TextDecoration.none,
            ),
          ),
        ],
      ),
    );
  }
}

/// The close target: a dark circle with a white close icon.
class SupportBubbleDismissTarget extends StatelessWidget {
  const SupportBubbleDismissTarget({super.key, required this.armed});

  final bool armed;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      key: const ValueKey('support-bubble-dismiss'),
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: neuSurface,
        border: Border.all(
          color: Colors.white.withValues(alpha: armed ? 0.55 : 0.14),
          width: armed ? 1.5 : 1,
        ),
        boxShadow: const [
          BoxShadow(
            color: Color(0x73000000),
            blurRadius: 14,
            offset: Offset(0, 5),
            spreadRadius: -1,
          ),
        ],
      ),
      child: const Center(
        child: Icon(Icons.close_rounded, color: Colors.white, size: 26),
      ),
    );
  }
}
