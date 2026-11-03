import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';

import '../../services/haptic_service.dart';
import '../glass_style.dart';
import '../morph_box.dart';

/// Opens and closes a [RiderTripSheet] from outside (the face's Support
/// button opens it on the support page).
class RiderTripSheetController {
  _RiderTripSheetState? _state;

  void open() => _state?._setOpen(true);
  void close() => _state?._setOpen(false);
  bool get isOpen => _state?._open ?? false;
}

/// The rider's trip sheet (owner 2026-11-03, drawing J6zTb8hfeKDqfFbzpx5jXb).
///
/// Dark glass, blurred hard enough that nothing behind it reads, welded to
/// the bottom edge. It rests SEMI-OPEN on [face]; a tap or a swipe up grows
/// the same sheet — following the finger both ways — into [body], tall like
/// the driver's whole-trip panel, while the map behind blurs and dims. A
/// swipe down, a tap on the face's handle or a tap on the map puts it back.
/// The settle is a critically damped spring, a little slower than the
/// driver's ("smooth, fluida y no tan rápida").
///
/// [hint] shows once per [hintTripId] above the resting sheet, the map
/// blurred behind it: gone after 5 s or the moment the sheet is touched.
class RiderTripSheet extends StatefulWidget {
  const RiderTripSheet({
    super.key,
    required this.face,
    required this.body,
    this.hint,
    this.hintTripId,
    this.controller,
    this.onRestHeightChanged,
    this.onOpenChanged,
    this.onClosed,
  });

  final Widget face;
  final Widget body;
  final String? hint;
  final int? hintTripId;
  final RiderTripSheetController? controller;

  /// The resting (semi-open) height from the bottom edge — what the map
  /// frames the route above.
  final ValueChanged<double>? onRestHeightChanged;
  final ValueChanged<bool>? onOpenChanged;

  /// All the way down (the close animation finished).
  final VoidCallback? onClosed;

  @override
  State<RiderTripSheet> createState() => _RiderTripSheetState();
}

/// The trip the hint was last shown for: once per trip, not per mount.
int? _riderSheetHintTrip;

final SpringDescription _riderSheetSpring =
    SpringDescription.withDampingRatio(mass: 1, stiffness: 170, ratio: 1);

const double _kScrimBlur = 14;
const double _kScrimDim = 0.34;
const double _kCommitDrag = 48;
const double _kCommitSpeed = 300; // px/s

/// The handle strip on top of both the face and the body.
const double _kHandleH = 24;

class _RiderTripSheetState extends State<RiderTripSheet>
    with SingleTickerProviderStateMixin {
  // A spring ends within its tolerance of the target, not on it: snap to
  // the exact end so nothing (the blur behind) lingers at 0.0004.
  late final AnimationController _sheet = AnimationController(vsync: this)
    ..addStatusListener((st) {
      if ((st == AnimationStatus.completed ||
              st == AnimationStatus.dismissed) &&
          !_dragging) {
        final v = _sheet.value;
        if (v != 0 && v != 1) _sheet.value = v < 0.5 ? 0 : 1;
        if (_sheet.value == 0) widget.onClosed?.call();
      }
    });
  double _faceH = 0;
  double? _bodyH;
  double _restH = -1;
  double _drag = 0;
  double _dragFrom = 0;
  bool _dragging = false;
  double _pull = 0;
  bool _hint = false;
  bool _hintDone = false;
  Timer? _hintTimer;

  bool get _open => _sheet.value > 0.01 || _sheet.isAnimating;
  double get _travel => math.max(120.0, (_bodyH ?? _faceH + 420) - _faceH);

  @override
  void initState() {
    super.initState();
    widget.controller?._state = this;
    final trip = widget.hintTripId;
    if (widget.hint == null || (trip != null && trip == _riderSheetHintTrip)) {
      _hintDone = true;
    } else {
      _riderSheetHintTrip = trip;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || _hintDone) return;
        setState(() => _hint = true);
        _hintTimer = Timer(const Duration(seconds: 5), () {
          if (mounted) setState(() => _hint = false);
        });
      });
    }
  }

  @override
  void didUpdateWidget(RiderTripSheet old) {
    super.didUpdateWidget(old);
    if (old.controller != widget.controller) {
      old.controller?._state = null;
      widget.controller?._state = this;
    }
  }

  @override
  void dispose() {
    if (widget.controller?._state == this) widget.controller?._state = null;
    _hintTimer?.cancel();
    _sheet.dispose();
    super.dispose();
  }

  /// Touched: the hint is done for this trip, at once and for good.
  void _endHint() {
    if (_hintDone && !_hint) return;
    _hintTimer?.cancel();
    setState(() {
      _hint = false;
      _hintDone = true;
    });
  }

  void _settle(bool open, {double velocityPx = 0}) {
    // Closing drops any keyboard focus inside the body (the route-change
    // search field): a field that stays focused at opacity 0 keeps the
    // keyboard up over the resting sheet.
    if (!open) FocusManager.instance.primaryFocus?.unfocus();
    final v = -velocityPx / _travel;
    final sim =
        SpringSimulation(_riderSheetSpring, _sheet.value, open ? 1.0 : 0.0, v);
    if (open) {
      _sheet.animateWith(sim);
    } else {
      _sheet.animateBackWith(sim);
    }
  }

  void _setOpen(bool open) {
    if (!mounted) return;
    _endHint();
    if (open ==
        (_sheet.value > 0.5 && _sheet.status != AnimationStatus.reverse)) {
      return;
    }
    HapticService.lightImpact();
    widget.onOpenChanged?.call(open);
    _settle(open);
  }

  void _dragStart(DragStartDetails _) {
    _endHint();
    _drag = 0;
    _dragFrom = _sheet.value;
    _dragging = true;
    _sheet.stop();
  }

  void _dragUpdate(DragUpdateDetails d) {
    _drag += d.delta.dy;
    _sheet.value = (_dragFrom - _drag / _travel).clamp(0.0, 1.0);
  }

  void _dragEnd(DragEndDetails d) {
    _dragging = false;
    final v = d.primaryVelocity ?? 0;
    final bool open;
    if (v.abs() > _kCommitSpeed) {
      open = v < 0;
    } else if (_dragFrom < 0.5) {
      open = _drag < -_kCommitDrag;
    } else {
      open = _drag <= _kCommitDrag;
    }
    if (open != (_dragFrom >= 0.5)) widget.onOpenChanged?.call(open);
    _settle(open, velocityPx: v);
  }

  void _dragCancel() {
    _dragging = false;
    _settle(_sheet.value >= 0.5);
  }

  /// The open body scrolls when it is taller than the screen: at its top a
  /// pull down moves the sheet instead, and letting go settles it.
  bool _onBodyScroll(ScrollNotification n) {
    if (n is ScrollStartNotification && n.dragDetails != null) {
      _pull = 0;
      _dragging = true;
      _sheet.stop();
    } else if (n is OverscrollNotification &&
        n.dragDetails != null &&
        n.overscroll < 0) {
      _pull -= n.overscroll;
      _sheet.value = (1 - _pull / _travel).clamp(0.0, 1.0);
    } else if (n is ScrollUpdateNotification &&
        n.dragDetails != null &&
        _pull > 0 &&
        (n.scrollDelta ?? 0) > 0) {
      _pull = math.max(0.0, _pull - n.scrollDelta!);
      _sheet.value = (1 - _pull / _travel).clamp(0.0, 1.0);
    } else if (n is ScrollEndNotification && _dragging) {
      _dragging = false;
      if (_pull <= 0 && _sheet.value > 0 && _sheet.value < 1) {
        // A scroll that began mid-open stopped the spring: finish it.
        _settle(_sheet.value >= 0.5);
      }
      if (_pull > 0) {
        final v = n.dragDetails?.primaryVelocity ?? 0;
        final close = _pull > _kCommitDrag || v > _kCommitSpeed;
        if (close) widget.onOpenChanged?.call(false);
        _settle(!close, velocityPx: v);
      }
      _pull = 0;
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.maybeOf(context);
    final fullWidth = mq?.size.width ?? 390;
    final maxBodyH =
        (mq?.size.height ?? 800) - (mq?.padding.top ?? 0) - 12 - _kHandleH;

    final body = ConstrainedBox(
      constraints: BoxConstraints(maxHeight: maxBodyH),
      child: NotificationListener<ScrollNotification>(
        onNotification: _onBodyScroll,
        child: ScrollConfiguration(
          behavior: ScrollConfiguration.of(context).copyWith(
            overscroll: false,
            physics: const ClampingScrollPhysics(),
          ),
          child: SingleChildScrollView(child: widget.body),
        ),
      ),
    );

    return AnimatedBuilder(
      animation: _sheet,
      builder: (context, _) {
        final t = _sheet.value;
        final sheet = GestureDetector(
          key: const ValueKey('rider-sheet'),
          behavior: HitTestBehavior.opaque,
          onVerticalDragStart: _dragStart,
          onVerticalDragUpdate: _dragUpdate,
          onVerticalDragEnd: _dragEnd,
          onVerticalDragCancel: _dragCancel,
          // A tap anywhere on the resting sheet (outside its buttons) opens it.
          onTap: () {
            if (_sheet.value < 0.02) _setOpen(true);
          },
          child: GlassSurface(
            blur: kGlassSheetBlurOpen,
            tint: glassSheetOpenTint,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(30)),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // The handle: a tap opens or closes.
                GestureDetector(
                  key: const ValueKey('rider-sheet-handle'),
                  behavior: HitTestBehavior.opaque,
                  onTap: () => _setOpen(_sheet.value < 0.5),
                  child: SizedBox(
                    height: _kHandleH,
                    width: double.infinity,
                    child: Center(
                      child: Container(
                        width: 40,
                        height: 5,
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.32),
                          borderRadius: BorderRadius.circular(3),
                        ),
                      ),
                    ),
                  ),
                ),
                MorphBox(
                  key: const ValueKey('rider-sheet-morph'),
                  t: t,
                  fullWidth: fullWidth,
                  onSizes: (face, grown) {
                    if (!mounted) return;
                    _faceH = face;
                    _bodyH = grown;
                    final rest = face + _kHandleH;
                    if ((rest - _restH).abs() > 0.5) {
                      _restH = rest;
                      widget.onRestHeightChanged?.call(rest);
                    }
                  },
                  children: [
                    IgnorePointer(
                      ignoring: t > 0.02,
                      child: Opacity(
                        opacity: (1 - t / 0.4).clamp(0.0, 1.0),
                        child: widget.face,
                      ),
                    ),
                    IgnorePointer(
                      ignoring: t < 0.5,
                      child: Opacity(
                        opacity: ((t - 0.3) / 0.5).clamp(0.0, 1.0),
                        child: body,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
        final showHint = _hint && t < 0.02;
        return Stack(
          children: [
            // Open: the map behind goes soft and dim; a tap on it closes.
            if (t > 0.01)
              Positioned.fill(
                key: const ValueKey('rider-sheet-scrim'),
                child: GestureDetector(
                  onTap: () => _setOpen(false),
                  child: BackdropFilter(
                    filter: ui.ImageFilter.blur(
                        sigmaX: _kScrimBlur * t, sigmaY: _kScrimBlur * t),
                    child: ColoredBox(
                        color: Colors.black.withValues(alpha: _kScrimDim * t)),
                  ),
                ),
              ),
            // The hint's own blur, in and out with it.
            if (!_hintDone)
              Positioned.fill(
                key: const ValueKey('rider-sheet-hint-blur'),
                child: IgnorePointer(
                  child: TweenAnimationBuilder<double>(
                    tween: Tween(end: showHint ? 1.0 : 0.0),
                    duration: const Duration(milliseconds: 450),
                    curve: Curves.easeInOut,
                    builder: (context, v, _) => v <= 0
                        ? const SizedBox.shrink()
                        : BackdropFilter(
                            filter: ui.ImageFilter.blur(
                                sigmaX: 8 * v, sigmaY: 8 * v),
                            child: ColoredBox(
                                color:
                                    Colors.black.withValues(alpha: 0.22 * v)),
                          ),
                  ),
                ),
              ),
            Align(
              key: const ValueKey('rider-sheet-panel'),
              alignment: Alignment.bottomCenter,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (!_hintDone)
                    _HintBubble(
                      text: widget.hint ?? '',
                      visible: showHint,
                      onGone: () {
                        if (mounted && !_hint) {
                          setState(() => _hintDone = true);
                        }
                      },
                    ),
                  sheet,
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}

/// "Desliza hacia arriba…": a light bubble pointing at the sheet, in and out
/// with a fade and a short rise.
class _HintBubble extends StatelessWidget {
  const _HintBubble({
    required this.text,
    required this.visible,
    required this.onGone,
  });

  final String text;
  final bool visible;
  final VoidCallback onGone;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: AnimatedOpacity(
        duration: const Duration(milliseconds: 450),
        opacity: visible ? 1 : 0,
        onEnd: () {
          if (!visible) onGone();
        },
        child: AnimatedSlide(
          duration: const Duration(milliseconds: 600),
          curve: Curves.easeOutCubic,
          offset: visible ? Offset.zero : const Offset(0, 0.15),
          child: Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  constraints: const BoxConstraints(maxWidth: 250),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  decoration: BoxDecoration(
                    color: const Color(0xFFF2F0EA),
                    borderRadius: BorderRadius.circular(16),
                    boxShadow: const [
                      BoxShadow(
                          color: Color(0x66000000),
                          blurRadius: 22,
                          offset: Offset(0, 8)),
                    ],
                  ),
                  child: Text(
                    text,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: Color(0xFF141414),
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      height: 1.3,
                    ),
                  ),
                ),
                CustomPaint(
                  size: const Size(18, 9),
                  painter: _BubbleTailPainter(),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _BubbleTailPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final path = Path()
      ..moveTo(0, 0)
      ..lineTo(size.width, 0)
      ..lineTo(size.width / 2, size.height)
      ..close();
    canvas.drawPath(path, Paint()..color = const Color(0xFFF2F0EA));
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

/// The gold lane marks between the trip's stops (the driver's panel uses the
/// same: 9 on, 6 off, 3 wide, round ends).
class RiderLaneDashes extends StatelessWidget {
  const RiderLaneDashes({super.key, this.color = const Color(0x99E8C547)});

  final Color color;

  @override
  Widget build(BuildContext context) =>
      CustomPaint(painter: _LaneDashesPainter(color), size: Size.infinite);
}

class _LaneDashesPainter extends CustomPainter {
  _LaneDashesPainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round;
    final x = size.width / 2;
    for (double y = 1.5; y < size.height - 1.5; y += 15) {
      canvas.drawLine(
          Offset(x, y), Offset(x, math.min(y + 9, size.height - 1.5)), paint);
    }
  }

  @override
  bool shouldRepaint(covariant _LaneDashesPainter old) => old.color != color;
}

/// A modern map pin, black on the gold stop disc (same mark as the driver's).
class RiderStopPin extends StatelessWidget {
  const RiderStopPin({super.key, this.color = Colors.black});

  final Color color;

  @override
  Widget build(BuildContext context) => CustomPaint(
        size: const Size(18, 23),
        painter: _StopPinPainter(color),
      );
}

class _StopPinPainter extends CustomPainter {
  _StopPinPainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final sx = size.width / 18, sy = size.height / 23;
    final pin = Path()
      ..moveTo(9 * sx, 23 * sy)
      ..cubicTo(5.85 * sx, 16.7 * sy, 0, 13.95 * sy, 0, 9 * sy)
      ..arcToPoint(Offset(18 * sx, 9 * sy),
          radius: Radius.elliptical(9 * sx, 9 * sy))
      ..cubicTo(18 * sx, 13.95 * sy, 12.15 * sx, 16.7 * sy, 9 * sx, 23 * sy)
      ..close();
    final hole = Path()
      ..addOval(Rect.fromCircle(
          center: Offset(9 * sx, 9 * sy), radius: 3.78 * math.min(sx, sy)));
    canvas.drawPath(Path.combine(PathOperation.difference, pin, hole),
        Paint()..color = color);
  }

  @override
  bool shouldRepaint(covariant _StopPinPainter old) => old.color != color;
}
