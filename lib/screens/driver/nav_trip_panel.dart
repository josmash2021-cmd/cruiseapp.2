import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';
import 'package:flutter/rendering.dart';
import 'package:intl/intl.dart';

import '../../l10n/app_localizations.dart';
import '../../services/haptic_service.dart';
import '../../widgets/glass_style.dart';
import '../../widgets/morph_box.dart';
import '../../widgets/smooth_reveal.dart';
import '../../widgets/verified_avatar.dart';

/// Where the leg stands — it decides what the closed panel carries.
enum NavPanelStage {
  /// Driving toward the next point.
  driving,

  /// Under ~200 m from the pickup: photo, name, Contactar and "Llegué".
  approaching,

  /// "Llegué" tapped: the free wait runs, the slider picks the rider up.
  waitingPickup,

  /// "Llegué" at the rider's stop: the same wait, the slider heads to the
  /// destination, and the no-show bar says the rider did not come back.
  waitingStop,

  /// At the destination: the slider finishes the ride.
  arrivedDropoff,
}

/// What the title at the point says (see [_NavTripPanelState._waitRow]).
enum _WaitTitle { notified, scheduled, counting, over }

/// The navigation's bottom panel (owner design 2026-11-02, approved "tal
/// cual": https://claude.ai/artifact/HJUuivr8N4vih8WmmqGnTX).
///
/// Closed it floats as frosted glass with the trip's face. Driving, every
/// way of opening it (⋮, a tap, a swipe) gives only "Opciones del viaje";
/// parked, the ⋮ turns into the rider's photo (tap = the rider's info) and
/// a swipe raises the whole trip. Open it runs edge to edge. The glass is
/// the open-sheet frost: nothing behind it can be made out.
class NavTripPanel extends StatefulWidget {
  const NavTripPanel({
    super.key,
    required this.etaLabel,
    required this.riderName,
    required this.riderPhotoUrl,
    required this.riderId,
    required this.toPickup,
    required this.pickupAddress,
    required this.dropoffAddress,
    required this.fare,
    required this.moving,
    required this.stage,
    required this.onOpenChat,
    required this.onSupport,
    required this.onCancelTrip,
    required this.onArrived,
    required this.onSlidePickUp,
    required this.onSlideFinish,
    this.stopLabel = '',
    this.hasStop = false,
    this.stopLeg = false,
    this.stopDone = false,
    this.pickupNote = '',
    this.dropoffNote = '',
    this.onSlideFromStop,
    this.riderRating,
    this.riderTrips,
    this.riderDays,
    this.riderVerified = false,
    this.canPickUp = true,
    this.codeEntry,
    this.waitClock = '',
    this.waitProgress = 0,
    this.waitStartsAt,
    this.receivingRides = true,
    this.lastTrip = false,
    this.chatUnread,
    this.supportUnread = 0,
    this.queuedCanceled = false,
    this.onToggleReceiving,
    this.onToggleLastTrip,
    this.onNoShow,
    this.onHeightChanged,
    this.onRestHeightChanged,
    this.onOpenChanged,
    this.mapControls,
    this.hintTripId,
  });

  final String etaLabel;
  final String riderName;
  final String riderPhotoUrl;
  final int? riderId;
  final bool toPickup;
  final String pickupAddress;
  final String dropoffAddress;
  final String stopLabel;
  final bool hasStop;

  /// The current leg ends at the rider's stop (the rider is aboard and the
  /// stop is still ahead).
  final bool stopLeg;

  /// The driver already left the stop for the destination.
  final bool stopDone;

  /// The rider's own instructions for the pickup / the destination (gate
  /// codes, "the blue door"), under each address in the whole trip.
  final String pickupNote;
  final String dropoffNote;

  /// "Desliza para ir al destino" at the stop.
  final VoidCallback? onSlideFromStop;
  final double fare;

  /// Driving (not parked): opening gives only the trip options.
  final bool moving;
  final NavPanelStage stage;

  final double? riderRating;
  final int? riderTrips;
  final int? riderDays;
  final bool riderVerified;

  /// waitingPickup: false until the rider confirms the pickup — the slider
  /// stays locked on "Esperando a tu pasajero…".
  final bool canPickUp;

  /// The pickup code row, above the slider in the closed panel while
  /// waiting at the pickup (owner-approved drawing 2026-11-03). Only the
  /// closed face carries it: it holds the code's one text field.
  final Widget? codeEntry;

  /// waitingPickup: "4:59" and how much of the free wait has gone (0 → 1).
  final String waitClock;
  final double waitProgress;

  /// When the free wait starts counting, if that is still ahead: a
  /// reservation the driver reached early (its pickup time, rule #57).
  final DateTime? waitStartsAt;

  final bool receivingRides;
  final bool lastTrip;
  final Stream<int>? chatUnread;
  final int supportUnread;

  /// The ride queued behind this one was cancelled: a gold line slides in
  /// at the top of the panel while this is true (owner design 2026-11-02,
  /// drawing 15).
  final bool queuedCanceled;

  final VoidCallback onOpenChat;
  final VoidCallback onSupport;
  final VoidCallback onCancelTrip;
  final VoidCallback onArrived;
  final VoidCallback onSlidePickUp;
  final VoidCallback onSlideFinish;
  final VoidCallback? onToggleReceiving;
  final VoidCallback? onToggleLastTrip;

  /// The wait is over and the rider never came: the red slider cancels.
  final VoidCallback? onNoShow;

  /// The panel's height on screen, so the map controls and the camera can
  /// ride on top of it.
  final ValueChanged<double>? onHeightChanged;

  /// The floating panel's height at rest (closed), even while it is open:
  /// the map's buttons and the mph stay above THIS (owner 2026-11-02: "los
  /// botones del mapa y velocímetro deben de quedarse donde están cuando el
  /// sheet se abra") — the opening panel goes over them.
  final ValueChanged<double>? onRestHeightChanged;

  /// Open (options / whole trip / rider info) or closed.
  final ValueChanged<bool>? onOpenChanged;

  /// The map's own buttons (mph, safety, route), positioned against the
  /// whole screen. Laid between the blurred-map scrim and the panel, so they
  /// rise with the sheet's top edge sharp instead of fading under the blur.
  final Widget? mapControls;

  /// The trip the swipe hint belongs to: it shows once per trip, not every
  /// time the navigation opens again (owner 2026-11-02). Null shows it on
  /// every mount.
  final int? hintTripId;

  @override
  State<NavTripPanel> createState() => _NavTripPanelState();
}

/// The last trip the swipe hint was shown for (see [NavTripPanel.hintTripId]).
int? _swipeHintTrip;

enum _Mode { closed, options, full, profile }

const Color _gold = Color(0xFFE8C547);
const Color _red = Color(0xFFFF6B6B);
const Color _ink = Color(0xFF141414);
// The iOS sheet curve, shared by every lift of the panel's insides.
const Cubic _glide = Cubic(0.32, 0.72, 0, 1);
const Duration _glideDur = Duration(milliseconds: 750);

/// The open sheet rides a spring (owner report 2026-11-02: "no se guarda
/// fluido y smooth, se guarda así de golpe… se abre de golpe… lo intento
/// deslizar y no se desliza"): critically damped, so it settles without
/// bouncing past the edge, and a release hands it the finger's speed.
final SpringDescription _sheetSpring =
    SpringDescription.withDampingRatio(mass: 1, stiffness: 240, ratio: 1);

/// The map behind the whole trip / the rider's info: blurred and dimmed in
/// step with the sheet (owner 2026-11-02: "el contenido del mapa no se pone
/// borroso"). 14 / 0.34 left the turn box readable through it (owner
/// 2026-11-04: "está borroso pero se puede leer o ver aún").
/// How long "Pasajero notificado" stays up after "Llegué".
const Duration _kNotifiedFor = Duration(seconds: 4);

const double _kScrimBlur = 32;
const double _kScrimDim = 0.55;

/// A drag farther than this (or a flick) commits; less springs back.
const double _kCommitDrag = 48;
const double _kCommitSpeed = 300; // px/s

class _NavTripPanelState extends State<NavTripPanel>
    with SingleTickerProviderStateMixin {
  _Mode _mode = _Mode.closed;
  bool _stopCollapsed = false;
  bool _noShowShown = false;
  bool _hint = false;
  // The hint has faded out for good: it leaves the layout too.
  bool _hintDone = false;
  Timer? _hintTimer;
  double _drag = 0;

  /// 0 = the floating face, 1 = the panel grown into the open body
  /// (options / whole trip / rider's info). The SAME panel transforms
  /// (owner 2026-11-02: "este mismo sheet es el que se debe transformar"):
  /// its height, side margins and lower corners follow this value under the
  /// finger both ways, the face fading out as the body fades in. It used to
  /// swap its insides in a quarter second while the frame glided, which read
  /// as a jump, and a scrolling whole trip swallowed the swipe down (it
  /// bounced instead of closing — the owner's photo 3).
  late final AnimationController _sheet = AnimationController(vsync: this)
    ..addStatusListener(_onSheetStatus);

  /// Natural heights of the face and the open body (from [_Morph]); the
  /// finger's travel is the gap between them.
  double _faceH = 0;
  double? _bodyH;
  double _restH = -1;
  double _dragFrom = 0;
  bool _dragging = false;

  /// Whole trip: how far an overscroll at its top has pulled the sheet down.
  double _pull = 0;

  bool get _open => _mode != _Mode.closed;
  bool get _scrim => _mode == _Mode.full || _mode == _Mode.profile;
  double get _travel => math.max(120.0, (_bodyH ?? _faceH + 420) - _faceH);

  @override
  void initState() {
    super.initState();
    // The swipe hint (owner 2026-11-02): once per trip — gone after 5 s or
    // the moment the panel opens, whichever comes first, and not back when
    // the panel closes or the navigation is opened again. It used to come
    // back on every mount and stay 7 s. A new trip shows it again.
    final trip = widget.hintTripId;
    if (trip != null && trip == _swipeHintTrip) {
      _hintDone = true;
    } else {
      _swipeHintTrip = trip;
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
  void didUpdateWidget(NavTripPanel old) {
    super.didUpdateWidget(old);
    // Driving again: the whole trip and the rider's info fold away — only
    // the options may stay open while the car moves.
    if (widget.moving && (_mode == _Mode.full || _mode == _Mode.profile)) {
      _setMode(_Mode.closed);
    }
    if (widget.stage != old.stage) _noShowShown = false;
    // Just arrived ("Llegué"): "Pasajero notificado" first, 4 s, then the
    // wait (owner 2026-11-04, Lyft). Only on the way in — a reopened
    // screen already mid-wait goes straight to the clock.
    final wasWaiting = old.stage == NavPanelStage.waitingPickup ||
        old.stage == NavPanelStage.waitingStop;
    if (_waiting && !wasWaiting) {
      _notifiedTimer?.cancel();
      _notifying = true;
      _notifiedTimer = Timer(_kNotifiedFor, () {
        if (mounted) setState(() => _notifying = false);
      });
    }
  }

  /// The panel opened: the hint is done for this trip — out of the layout
  /// at once (the panel covers its spot) and never back.
  void _endHint() {
    _hintTimer?.cancel();
    _hint = false;
    _hintDone = true;
  }

  @override
  void dispose() {
    _notifiedTimer?.cancel();
    _hintTimer?.cancel();
    _sheet.dispose();
    super.dispose();
  }

  void _onSheetStatus(AnimationStatus st) {
    // All the way down: the sheet's content leaves the tree.
    if (st == AnimationStatus.dismissed &&
        !_dragging &&
        _mode != _Mode.closed &&
        mounted) {
      setState(() {
        _mode = _Mode.closed;
        _bodyH = null;
      });
    }
  }

  void _settle(bool open, {double velocityPx = 0}) {
    // Spring units are the sheet's own 0..1; up is positive.
    final v = -velocityPx / _travel;
    final sim =
        SpringSimulation(_sheetSpring, _sheet.value, open ? 1.0 : 0.0, v);
    if (open) {
      _sheet.animateWith(sim);
    } else {
      _sheet.animateBackWith(sim);
    }
  }

  void _setMode(_Mode m) {
    if (m == _Mode.closed) {
      if (!_open) return;
      widget.onOpenChanged?.call(false);
      _settle(false);
      return;
    }
    final wasOpen = _open && _sheet.status != AnimationStatus.reverse;
    setState(() {
      _mode = m;
      _endHint();
    });
    if (!wasOpen) widget.onOpenChanged?.call(true);
    _settle(true);
  }

  bool get _waiting =>
      widget.stage == NavPanelStage.waitingPickup ||
      widget.stage == NavPanelStage.waitingStop;

  bool get _waitOver => _waiting && widget.waitProgress >= 1;

  bool _notifying = false;
  Timer? _notifiedTimer;

  _WaitTitle get _waitTitle {
    if (_notifying) return _WaitTitle.notified;
    final at = widget.waitStartsAt;
    if (at != null && DateTime.now().isBefore(at)) return _WaitTitle.scheduled;
    return _waitOver ? _WaitTitle.over : _WaitTitle.counting;
  }

  /// What a swipe up on the floating panel raises — null when it reveals
  /// the no-show slider instead (at the pickup with the wait over, owner
  /// 2026-11-02), which stays inside the floating panel.
  _Mode? get _swipeTarget {
    if (widget.moving) return _Mode.options;
    if (_waitOver && widget.onNoShow != null && !_noShowShown) return null;
    return _Mode.full;
  }

  void _openUp() {
    HapticService.lightImpact();
    final target = _swipeTarget;
    if (target == null) {
      setState(() {
        _noShowShown = true;
        _endHint();
      });
    } else {
      _setMode(target);
    }
  }

  void _close() {
    if (_noShowShown && _mode == _Mode.closed) {
      setState(() => _noShowShown = false);
      return;
    }
    _setMode(_Mode.closed);
  }

  // ── Drags ───────────────────────────────────────────────────────────────

  /// The panel follows the finger: up grows the face into the open body,
  /// down shrinks it back.
  void _dragStart(DragStartDetails _) {
    _drag = 0;
    _dragFrom = _sheet.value;
    _dragging = true;
    _sheet.stop();
  }

  void _dragUpdate(DragUpdateDetails d) {
    _drag += d.delta.dy;
    if (!_open) {
      final target = _swipeTarget;
      if (target == null || _drag >= 0) return;
      HapticService.lightImpact();
      setState(() {
        _mode = target;
        _endHint();
      });
      widget.onOpenChanged?.call(true);
    }
    _sheet.value = (_dragFrom - _drag / _travel).clamp(0.0, 1.0);
  }

  void _dragEnd(DragEndDetails d) {
    _dragging = false;
    final v = d.primaryVelocity ?? 0;
    if (!_open) {
      // Never grew: the no-show reveal (or hiding it again).
      if (_drag < -_kCommitDrag || v < -_kCommitSpeed) {
        _openUp();
      } else if (_drag > 24 || v > _kCommitSpeed) {
        _close();
      }
      return;
    }
    final bool open;
    if (v.abs() > _kCommitSpeed) {
      open = v < 0;
    } else if (_dragFrom < 0.5) {
      open = _drag < -_kCommitDrag;
    } else {
      open = _drag <= _kCommitDrag;
    }
    if (!open) widget.onOpenChanged?.call(false);
    _settle(open, velocityPx: v);
  }

  /// A swipe the system took away (a call, a second finger): the sheet
  /// goes to whichever end it is nearer, never left hanging half way.
  void _dragCancel() {
    _dragging = false;
    if (!_open) return;
    if (_sheet.value >= 0.5) {
      _settle(true);
    } else {
      widget.onOpenChanged?.call(false);
      _settle(false);
    }
  }

  void _release(double velocityPx, double pulled) {
    if (pulled > _kCommitDrag || velocityPx > _kCommitSpeed) {
      widget.onOpenChanged?.call(false);
      _settle(false, velocityPx: velocityPx);
    } else {
      _settle(true, velocityPx: velocityPx);
    }
  }

  /// The whole trip scrolls when it is taller than the screen: at its top a
  /// pull down moves the sheet instead (clamped physics, so nothing
  /// bounces), and letting go settles it like any other drag.
  bool _onFullScroll(ScrollNotification n) {
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
      // Back up after pulling down: the sheet climbs back first.
      _pull = math.max(0.0, _pull - n.scrollDelta!);
      _sheet.value = (1 - _pull / _travel).clamp(0.0, 1.0);
    } else if (n is ScrollEndNotification && _dragging) {
      _dragging = false;
      if (_pull > 0) {
        _release(n.dragDetails?.primaryVelocity ?? 0, _pull);
      }
      _pull = 0;
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final bottomPad = MediaQuery.maybeOf(context)?.padding.bottom ?? 0;
    final open = _open;

    // The open body: sized by what it carries; a switch between options,
    // the whole trip and the rider's info glides inside it.
    Widget body() => Padding(
          padding: EdgeInsets.only(bottom: bottomPad),
          child: AnimatedSize(
            duration: _glideDur,
            curve: _glide,
            alignment: Alignment.topCenter,
            child: AnimatedSwitcher(
              duration: kSmoothRevealDuration,
              switchInCurve: kSmoothRevealCurve,
              switchOutCurve: kSmoothRevealCurve,
              // The incoming body alone sets the height; the outgoing one
              // fades out without holding the panel tall (it used to, and
              // ghosted over the new one).
              layoutBuilder: (cur, prev) => Stack(
                clipBehavior: Clip.hardEdge,
                alignment: Alignment.topCenter,
                children: [
                  for (final p in prev)
                    Positioned(left: 0, right: 0, top: 0, child: p),
                  if (cur != null) cur,
                ],
              ),
              child: KeyedSubtree(
                key: ValueKey(_mode),
                child: switch (_mode) {
                  _Mode.closed => const SizedBox(width: double.infinity),
                  _Mode.options => _optionsBody(s),
                  _Mode.full => _fullBody(s, context),
                  _Mode.profile => _profileBody(s),
                },
              ),
            ),
          ),
        );

    final fullWidth = MediaQuery.maybeOf(context)?.size.width ?? 390;

    return AnimatedBuilder(
      animation: _sheet,
      builder: (context, _) {
        final t = _sheet.value;
        final k = 1 - t;
        final corner = Radius.circular(30 * k);
        final panel = GestureDetector(
          behavior: HitTestBehavior.opaque,
          onVerticalDragStart: _dragStart,
          onVerticalDragUpdate: _dragUpdate,
          onVerticalDragEnd: _dragEnd,
          onVerticalDragCancel: _dragCancel,
          onTap: () {
            // Driving, a tap on the closed panel opens the options too.
            if (!_open && widget.moving) _openUp();
          },
          // Floating with its margins and round corners when closed; edge to
          // edge, square at the bottom, when open — every step in between.
          child: Padding(
            padding:
                EdgeInsets.fromLTRB(8 * k, 0, 8 * k, (8 + bottomPad * 0.5) * k),
            // Closed: see-through frost with real round corners (owner
            // 2026-11-04, "semi transparente borroso pero sin esquinas");
            // it darkens to the open tint as it grows.
            child: GlassSurface(
              blur: kGlassSheetBlurOpen,
              tint: Color.lerp(glassNavRestTint, glassSheetOpenTint, t)!,
              roundFrostOnIOS: true,
              borderRadius: BorderRadius.only(
                topLeft: const Radius.circular(30),
                topRight: const Radius.circular(30),
                bottomLeft: corner,
                bottomRight: corner,
              ),
              child: MorphBox(
                key: const ValueKey('nav-panel-morph'),
                t: t,
                fullWidth: fullWidth,
                inset: 8,
                onSizes: (face, grown) {
                  if (!mounted) return;
                  _faceH = face;
                  _bodyH = grown;
                  // The face plus the margins it floats on when closed.
                  final rest = face + 8 + bottomPad * 0.5;
                  if ((rest - _restH).abs() > 0.5) {
                    _restH = rest;
                    widget.onRestHeightChanged?.call(rest);
                  }
                },
                children: [
                  // The face: fades out over the first part of the way.
                  IgnorePointer(
                    ignoring: t > 0.02,
                    child: Opacity(
                      opacity: (1 - t / 0.4).clamp(0.0, 1.0),
                      child: AnimatedSize(
                        duration: _glideDur,
                        curve: _glide,
                        alignment: Alignment.bottomCenter,
                        child: _closedBody(s),
                      ),
                    ),
                  ),
                  if (open)
                    IgnorePointer(
                      ignoring: t < 0.5,
                      child: Opacity(
                        opacity: ((t - 0.3) / 0.5).clamp(0.0, 1.0),
                        child: body(),
                      ),
                    ),
                ],
              ),
            ),
          ),
        );
        return Stack(
          children: [
            // The whole trip and the rider's info: the map behind goes soft
            // and dim; a tap on it puts the panel away.
            if (_scrim && t > 0)
              Positioned.fill(
                key: const ValueKey('scrim'),
                child: GestureDetector(
                  key: const ValueKey('nav-panel-scrim'),
                  onTap: _close,
                  child: BackdropFilter(
                    filter: ui.ImageFilter.blur(
                        sigmaX: _kScrimBlur * t, sigmaY: _kScrimBlur * t),
                    child: ColoredBox(
                        color: Colors.black.withValues(alpha: _kScrimDim * t)),
                  ),
                ),
              ),
            // The map's buttons ride the panel's top above the blur.
            if (widget.mapControls != null)
              Positioned.fill(
                key: const ValueKey('controls'),
                child: widget.mapControls!,
              ),
            Align(
              // Keyed: the scrim comes and goes around it, and an unkeyed
              // panel would be rebuilt mid-swipe (cancelling it).
              key: const ValueKey('panel'),
              alignment: Alignment.bottomCenter,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // The hint is never part of the measured height, and never
                  // in the layout once it is gone or the panel is open — the
                  // whole trip needs every pixel.
                  if (!open && !_hintDone) _hintBubble(s),
                  _HeightReporter(
                    onHeight: (h) {
                      if (mounted) widget.onHeightChanged?.call(h);
                    },
                    child: panel,
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }

  // ── Swipe hint ──────────────────────────────────────────────────────────

  Widget _hintBubble(S s) {
    return IgnorePointer(
      child: AnimatedOpacity(
        // Out as softly as in (owner 2026-11-02: "así como se abre se
        // cierra smooth").
        duration: const Duration(milliseconds: 450),
        opacity: _hint ? 1 : 0,
        onEnd: () {
          if (!_hint && mounted) setState(() => _hintDone = true);
        },
        child: AnimatedSlide(
          duration: const Duration(milliseconds: 600),
          curve: _glide,
          offset: _hint ? Offset.zero : const Offset(0, 0.15),
          child: Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  constraints: const BoxConstraints(maxWidth: 220),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                  decoration: BoxDecoration(
                    color: const Color(0xFFF2F0EA),
                    borderRadius: BorderRadius.circular(14),
                    boxShadow: const [
                      BoxShadow(
                          color: Color(0x59000000),
                          blurRadius: 18,
                          offset: Offset(0, 6)),
                    ],
                  ),
                  child: Text(
                    widget.moving ? s.navSwipeHintOptions : s.navSwipeHintFull,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: _ink,
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      height: 1.3,
                    ),
                  ),
                ),
                CustomPaint(
                  size: const Size(16, 8),
                  painter: _TrianglePainter(const Color(0xFFF2F0EA)),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ── Closed ──────────────────────────────────────────────────────────────

  Widget _handle() => Container(
        margin: const EdgeInsets.only(top: 10),
        width: 40,
        height: 5,
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.35),
          borderRadius: BorderRadius.circular(3),
        ),
      );

  String get _firstName => widget.riderName.trim().split(' ').first;

  String _legLabel(S s) => widget.toPickup
      ? s.navPickUpName(_firstName)
      : (widget.stopLeg
          ? s.navStopOf(_firstName)
          : s.navDropOffName(_firstName));

  Widget _closedBody(S s) {
    final stage = widget.stage;
    final atPoint = stage != NavPanelStage.driving;
    return Column(
      key: const ValueKey('closed'),
      mainAxisSize: MainAxisSize.min,
      children: [
        _handle(),
        SmoothReveal(
          visible: widget.queuedCanceled,
          child: Column(
            key: const ValueKey('nav-queued-canceled'),
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                child: Text(
                  s.navQueuedRideCanceled,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: _gold,
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              Container(
                height: 1,
                margin: const EdgeInsets.symmetric(horizontal: 18),
                color: Colors.white.withValues(alpha: 0.12),
              ),
            ],
          ),
        ),
        if (_waiting) _waitRow(s),
        Padding(
          padding: EdgeInsets.fromLTRB(18, 14, 18, atPoint ? 16 : 24),
          child: Row(
            children: [
              // Driving: ⋮ opens the options. Parked: the rider's photo —
              // tap for the rider's info (owner 2026-11-02).
              if (widget.moving && !atPoint)
                _disc(
                  child: const Icon(Icons.more_vert_rounded,
                      color: Colors.white, size: 26),
                  onTap: () => _setMode(_Mode.options),
                )
              else
                _photo(58,
                    key: const ValueKey('nav-panel-photo'),
                    onTap: () => _setMode(_Mode.profile)),
              const SizedBox(width: 14),
              Expanded(
                child: atPoint
                    ? Text(
                        _firstName,
                        textAlign: TextAlign.center,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 23,
                          fontWeight: FontWeight.w700,
                        ),
                      )
                    : Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            widget.etaLabel.isEmpty ? '—' : widget.etaLabel,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 23,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          Text(
                            _legLabel(s),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: Colors.white.withValues(alpha: 0.7),
                              fontSize: 18,
                            ),
                          ),
                        ],
                      ),
              ),
              const SizedBox(width: 14),
              _contactDisc(),
            ],
          ),
        ),
        if (stage == NavPanelStage.approaching)
          _goldButton(s.arrived, widget.onArrived),
        if (stage == NavPanelStage.waitingPickup && widget.codeEntry != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 0, 14, 12),
            child: widget.codeEntry!,
          ),
        if (stage == NavPanelStage.waitingPickup)
          widget.canPickUp
              ? _SlideBar(
                  label: s.navSlideToPickUp, onDone: widget.onSlidePickUp)
              : _SlideBar.locked(
                  label: widget.codeEntry != null
                      ? s.navWaitingCode
                      : s.waitingForYourRider),
        if (stage == NavPanelStage.waitingStop)
          _SlideBar(
              label: s.navSlideToDropoff,
              onDone: widget.onSlideFromStop ?? () {}),
        if (stage == NavPanelStage.arrivedDropoff)
          _SlideBar(label: s.navSlideToFinish, onDone: widget.onSlideFinish),
        // The red no-show slider, under a hairline (owner 2026-11-02).
        SmoothReveal(
          visible: _noShowShown && widget.onNoShow != null,
          child: Container(
            margin: const EdgeInsets.symmetric(horizontal: 14),
            padding: const EdgeInsets.only(top: 14),
            decoration: BoxDecoration(
              border: Border(
                top: BorderSide(color: Colors.white.withValues(alpha: 0.10)),
              ),
            ),
            child: _SlideBar(
              label: stage == NavPanelStage.waitingStop
                  ? s.navRiderNoReturn
                  : s.navRiderNoShow,
              sub: s.navSlideToCancelTrip,
              danger: true,
              inset: false,
              onDone: widget.onNoShow ?? () {},
            ),
          ),
        ),
      ],
    );
  }

  // The title at the point, centred over a thin gold line (owner
  // 2026-11-04, Lyft's "Pickup scheduled for 9:55 PM" → "Passenger
  // notified"): "Pasajero notificado" as the driver arrives, then the
  // reservation's time while it is ahead, then "Espera 4:59" with the line
  // filling, then "Puedes cancelar el viaje o seguir esperando". Each title
  // slides in from below and leaves the way it came; the clock ticks
  // inside its title without a transition.
  Widget _waitRow(S s) {
    final p = widget.waitProgress.clamp(0.0, 1.0);
    final title = _waitTitle;
    final text = switch (title) {
      _WaitTitle.notified => s.navPassengerNotified,
      _WaitTitle.scheduled => s.navPickupScheduledFor(
          DateFormat('h:mm a', 'en_US').format(widget.waitStartsAt!)),
      _WaitTitle.counting => s.navWaitFor(widget.waitClock),
      _WaitTitle.over => s.navWaitOver,
    };
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 10, 18, 4),
      child: Column(
        children: [
          AnimatedSize(
            duration: const Duration(milliseconds: 450),
            curve: _glide,
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 450),
              switchInCurve: _glide,
              switchOutCurve: _glide,
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
              child: SizedBox(
                key: ValueKey(title),
                width: double.infinity,
                child: Text(
                  text,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: title == _WaitTitle.over ? 16 : 18,
                    fontWeight: FontWeight.w600,
                    height: 1.3,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 12),
          SizedBox(
            height: 3,
            child: LayoutBuilder(
              builder: (context, c) => Stack(
                children: [
                  Container(
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.14),
                      borderRadius: BorderRadius.circular(1.5),
                    ),
                  ),
                  AnimatedContainer(
                    duration: const Duration(milliseconds: 900),
                    curve: _glide,
                    width: c.maxWidth * p,
                    decoration: BoxDecoration(
                      color: _gold,
                      borderRadius: BorderRadius.circular(1.5),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 4),
        ],
      ),
    );
  }

  // ── Options (driving) ───────────────────────────────────────────────────

  Widget _optionsBody(S s) {
    return Padding(
      key: const ValueKey('options'),
      padding: const EdgeInsets.fromLTRB(22, 6, 22, 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            height: 66,
            child: Stack(
              alignment: Alignment.center,
              children: [
                Text(
                  s.navTripOptions,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 22,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                Positioned(
                  right: -6,
                  child: _disc(
                    size: 52,
                    child: const Icon(Icons.close_rounded,
                        color: Colors.white, size: 26),
                    onTap: _close,
                  ),
                ),
              ],
            ),
          ),
          _optionRow(
            icon: Icons.block_rounded,
            label: s.navCancelCurrentTrip,
            onTap: () {
              _setMode(_Mode.closed);
              widget.onCancelTrip();
            },
          ),
          // "Último viaje": Online ⇄ Offline (owner 2026-11-02). On, no more
          // rides during this one and the driver lands offline at the end.
          _optionRow(
            icon: Icons.power_settings_new_rounded,
            label: s.navLastTrip,
            trailing: widget.lastTrip ? s.navOffline : s.navOnline,
            onTap: widget.onToggleLastTrip,
          ),
        ],
      ),
    );
  }

  Widget _optionRow({
    required IconData icon,
    required String label,
    String? trailing,
    VoidCallback? onTap,
  }) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap == null
          ? null
          : () {
              HapticService.lightImpact();
              onTap();
            },
      child: Container(
        height: 66,
        decoration: BoxDecoration(
          border: Border(
            top: BorderSide(color: Colors.white.withValues(alpha: 0.10)),
          ),
        ),
        child: Row(
          children: [
            Icon(icon, color: Colors.white, size: 27),
            const SizedBox(width: 16),
            Expanded(
              child: Text(
                label,
                style: const TextStyle(color: Colors.white, fontSize: 19),
              ),
            ),
            if (trailing != null)
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 200),
                child: Text(
                  trailing,
                  key: ValueKey(trailing),
                  style: const TextStyle(
                    color: _gold,
                    fontSize: 19,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  // ── The whole trip (parked) ─────────────────────────────────────────────

  Widget _fullBody(S s, BuildContext context) {
    final mq = MediaQuery.maybeOf(context);
    final maxH = (mq?.size.height ?? 800) - (mq?.padding.top ?? 0) - 12;
    final pickupDone = !widget.toPickup;
    final stage = widget.stage;
    final pickupActs = widget.toPickup
        ? _acts([
            // Red X, red word, light red disc (owner 2026-11-02).
            _act(Icons.close_rounded, s.cancel, widget.onCancelTrip,
                tint: _red),
            _actContact(s),
          ])
        : null;
    final dropActs = !widget.toPickup ? _acts([_actContact(s)]) : null;
    Widget? slider;
    if (stage == NavPanelStage.waitingPickup) {
      slider = widget.canPickUp
          ? _SlideBar(
              label: s.navSlideToPickUp,
              onDone: widget.onSlidePickUp,
              inset: false)
          : _SlideBar.locked(
              label: widget.codeEntry != null
                  ? s.navWaitingCode
                  : s.waitingForYourRider,
              inset: false);
    } else if (stage == NavPanelStage.waitingStop) {
      slider = _SlideBar(
          label: s.navSlideToDropoff,
          onDone: widget.onSlideFromStop ?? () {},
          inset: false);
    } else if (stage == NavPanelStage.arrivedDropoff) {
      slider = _SlideBar(
          label: s.navSlideToFinish,
          onDone: widget.onSlideFinish,
          inset: false);
    }
    return ConstrainedBox(
      key: const ValueKey('full'),
      constraints: BoxConstraints(maxHeight: maxH),
      child: NotificationListener<ScrollNotification>(
        onNotification: _onFullScroll,
        child: ScrollConfiguration(
          behavior: ScrollConfiguration.of(context).copyWith(
            overscroll: false,
            physics: const ClampingScrollPhysics(),
          ),
          child: SingleChildScrollView(
            // Room between everything (owner 2026-11-03: "expándelo para
            // que esté más espacio y no tan todo junto").
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Center(child: _handle()),
                const SizedBox(height: 10),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'CRUISE IN RIDE',
                            // Gold (owner 2026-11-02).
                            style: TextStyle(
                              color: _gold,
                              fontSize: 15,
                              letterSpacing: 0.9,
                            ),
                          ),
                          Text(
                            s.currentTrip,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 23,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text.rich(
                            TextSpan(children: [
                              TextSpan(
                                text: '\$${widget.fare.toStringAsFixed(2)} ',
                                style: const TextStyle(
                                    fontSize: 21, fontWeight: FontWeight.w800),
                              ),
                              // Gold (owner 2026-11-02: "el + tips colócalo
                              // dorado").
                              TextSpan(
                                text: s.navPlusTips,
                                style: const TextStyle(color: _gold),
                              ),
                            ]),
                            style: const TextStyle(
                                color: Colors.white, fontSize: 19),
                          ),
                        ],
                      ),
                    ),
                    // Support: the headset face the chat already uses, with the
                    // unread support count (owner 2026-11-02).
                    _badged(
                      count: widget.supportUnread,
                      child: _disc(
                        size: 50,
                        child: const Icon(Icons.support_agent_rounded,
                            color: _gold, size: 28),
                        onTap: widget.onSupport,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 22),
                _stepRow(
                  lead: _photo(44, onTap: () => _setMode(_Mode.profile)),
                  done: pickupDone,
                  verified: widget.riderVerified,
                  title: s.navPickUpName(_firstName),
                  lines: [widget.pickupAddress, widget.pickupNote.trim()],
                  acts: pickupActs,
                  line: true,
                ),
                if (widget.hasStop)
                  SmoothReveal(
                    visible: !_stopCollapsed,
                    child: _stepRow(
                      lead: _pinDisc(),
                      done: widget.stopDone,
                      title: s.navStopOf(_firstName),
                      lines: [widget.stopLabel],
                      line: true,
                    ),
                  ),
                _stepRow(
                  lead: _photo(44, onTap: () => _setMode(_Mode.profile)),
                  done: false,
                  title: s.navDropOffName(_firstName),
                  lines: [widget.dropoffAddress, widget.dropoffNote.trim()],
                  acts: dropActs,
                  // On to the expand button under it (owner 2026-11-02:
                  // "que conecte con el botón de expandir").
                  line: widget.hasStop,
                ),
                if (widget.hasStop)
                  GestureDetector(
                    onTap: () =>
                        setState(() => _stopCollapsed = !_stopCollapsed),
                    child: Container(
                      margin: const EdgeInsets.only(left: 7, bottom: 14),
                      width: 30,
                      height: 30,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        border: Border.all(
                            color: Colors.white.withValues(alpha: 0.4),
                            width: 1.5),
                      ),
                      child: Icon(
                        _stopCollapsed
                            ? Icons.unfold_more_rounded
                            : Icons.unfold_less_rounded,
                        color: Colors.white,
                        size: 20,
                      ),
                    ),
                  ),
                _rowDivider(),
                // "Recibiendo viajes" ⇄ "Te has desconectado" (owner 2026-11-02).
                _toggleRow(
                  on: widget.receivingRides,
                  icon: Icons.directions_car_rounded,
                  logo: true,
                  title: widget.receivingRides
                      ? s.navReceivingRides
                      : s.navNotReceivingRides,
                  sub: widget.receivingRides
                      ? s.navTapToTurnOff
                      : s.navTapToTurnOn,
                  onTap: widget.onToggleReceiving,
                ),
                _rowDivider(),
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () {
                    HapticService.lightImpact();
                    _setMode(_Mode.closed);
                    widget.onCancelTrip();
                  },
                  child: Row(
                    children: [
                      _disc(
                        size: 52,
                        color: _red.withValues(alpha: 0.16),
                        child: const Icon(Icons.block_rounded, color: _red),
                      ),
                      const SizedBox(width: 16),
                      Text(
                        s.cancelTrip,
                        style: const TextStyle(
                          color: Color(0xFFFF8A8A),
                          fontSize: 17,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
                if (slider != null) ...[
                  const SizedBox(height: 18),
                  slider,
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _rowDivider() => Container(
        margin: const EdgeInsets.symmetric(vertical: 16),
        height: 1,
        color: Colors.white.withValues(alpha: 0.10),
      );

  Widget _stepRow({
    required Widget lead,
    required bool done,
    required String title,
    required List<String> lines,
    required bool line,
    bool verified = false,
    Widget? acts,
  }) {
    final dim = Colors.white.withValues(alpha: 0.42);
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            width: 44,
            child: Column(
              children: [
                lead,
                if (line)
                  Expanded(
                    child: Container(
                      margin: const EdgeInsets.symmetric(vertical: 4),
                      child: const _DottedLine(),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(bottom: 24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (verified)
                    Text(
                      '✓ ${S.of(context).faceVerified}',
                      style: TextStyle(
                          color: done ? dim : const Color(0xFF7FA8FF),
                          fontSize: 15),
                    ),
                  Text(
                    title,
                    style: TextStyle(
                      color: done ? dim : Colors.white,
                      fontSize: 17,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  for (final l in lines.where((l) => l.isNotEmpty))
                    Text(
                      l,
                      style: TextStyle(
                        color:
                            done ? dim : Colors.white.withValues(alpha: 0.75),
                        fontSize: 16,
                      ),
                    ),
                  if (acts != null) acts,
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _acts(List<Widget> children) => Padding(
        padding: const EdgeInsets.only(top: 14, bottom: 6),
        child: Row(
          children: [
            for (var i = 0; i < children.length; i++) ...[
              if (i > 0) const SizedBox(width: 26),
              children[i],
            ],
          ],
        ),
      );

  /// A round action under a stop. [tint] colours the glyph and the label
  /// and lays a light wash of it in the disc.
  Widget _act(IconData icon, String label, VoidCallback onTap,
          {Color? tint}) =>
      Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _disc(
              size: 56,
              color: tint?.withValues(alpha: 0.16),
              child: Icon(icon, color: tint ?? Colors.white, size: 26),
              onTap: onTap),
          const SizedBox(height: 6),
          Text(label,
              style: TextStyle(color: tint ?? Colors.white, fontSize: 15)),
        ],
      );

  Widget _actContact(S s) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _contactDisc(size: 56),
          const SizedBox(height: 6),
          Text(s.navContact,
              style: const TextStyle(color: Colors.white, fontSize: 15)),
        ],
      );

  Widget _toggleRow({
    required bool on,
    required IconData icon,
    required String title,
    required String sub,
    VoidCallback? onTap,
    bool logo = false,
  }) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap == null
          ? null
          : () {
              HapticService.lightImpact();
              onTap();
            },
      child: Row(
        children: [
          if (logo)
            // The Cruise logo (gold car in its gold ring, owner 2026-11-02):
            // full gold while rides come in, faded when they are off.
            AnimatedOpacity(
              duration: const Duration(milliseconds: 220),
              opacity: on ? 1 : 0.35,
              child: Image.asset('assets/images/cruise_logo.png',
                  width: 52, height: 52),
            )
          else
            AnimatedContainer(
              duration: const Duration(milliseconds: 220),
              width: 52,
              height: 52,
              decoration: BoxDecoration(
                color: on ? _gold : Colors.white.withValues(alpha: 0.12),
                shape: BoxShape.circle,
              ),
              child: Icon(icon,
                  color: on ? _ink : Colors.white.withValues(alpha: 0.6)),
            ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 17,
                        fontWeight: FontWeight.w600)),
                Text(sub,
                    style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.7),
                        fontSize: 15)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ── The rider's info (parked, tap on the photo) ─────────────────────────

  Widget _profileBody(S s) {
    Widget stat(String value, String label) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 10),
          child: Column(
            children: [
              Text(value,
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 24,
                      fontWeight: FontWeight.w700)),
              Text(label,
                  style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.7),
                      fontSize: 14)),
            ],
          ),
        );
    final rating = widget.riderRating;
    final stats = <Widget>[
      if (widget.riderTrips != null) stat('${widget.riderTrips}', s.tripsLabel),
      if (rating != null && rating > 0)
        stat('★${rating.toStringAsFixed(1)}', s.rating),
      if (widget.riderDays != null) stat('${widget.riderDays}', s.navRiderDays),
    ];
    return Padding(
      key: const ValueKey('profile'),
      padding: const EdgeInsets.fromLTRB(18, 24, 16, 24),
      child: Stack(
        children: [
          Row(
            children: [
              Expanded(
                flex: 5,
                child: Column(
                  children: [
                    Container(
                      width: 132,
                      height: 132,
                      padding: const EdgeInsets.all(3),
                      decoration: const BoxDecoration(
                          color: _gold, shape: BoxShape.circle),
                      child: _photo(126),
                    ),
                    const SizedBox(height: 10),
                    Text(
                      _firstName,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                          color: Colors.white,
                          fontSize: 26,
                          fontWeight: FontWeight.w700),
                    ),
                    if (widget.riderVerified)
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.check_circle_rounded,
                              color: _gold, size: 18),
                          const SizedBox(width: 5),
                          Flexible(
                            child: Text(s.faceVerified,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                    color: _gold,
                                    fontSize: 17,
                                    fontWeight: FontWeight.w500)),
                          ),
                        ],
                      ),
                  ],
                ),
              ),
              if (stats.isNotEmpty) ...[
                Container(
                  width: 1,
                  height: 190,
                  margin: const EdgeInsets.symmetric(horizontal: 14),
                  color: Colors.white.withValues(alpha: 0.12),
                ),
                Expanded(
                  flex: 4,
                  child: Padding(
                    padding: const EdgeInsets.only(top: 26),
                    child: Column(
                      children: [
                        for (var i = 0; i < stats.length; i++) ...[
                          if (i > 0)
                            Container(
                                height: 1,
                                color: Colors.white.withValues(alpha: 0.12)),
                          stats[i],
                        ],
                      ],
                    ),
                  ),
                ),
              ],
            ],
          ),
          Positioned(
            right: 0,
            top: -10,
            child: _disc(
              size: 38,
              child: const Icon(Icons.close_rounded,
                  color: Colors.white, size: 22),
              onTap: _close,
            ),
          ),
        ],
      ),
    );
  }

  // ── Pieces ──────────────────────────────────────────────────────────────

  Widget _disc({
    required Widget child,
    VoidCallback? onTap,
    double size = 58,
    Color? color,
  }) {
    return GestureDetector(
      onTap: onTap == null
          ? null
          : () {
              HapticService.lightImpact();
              onTap();
            },
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: color ?? Colors.white.withValues(alpha: 0.10),
          shape: BoxShape.circle,
        ),
        alignment: Alignment.center,
        child: child,
      ),
    );
  }

  Widget _photo(double size, {Key? key, VoidCallback? onTap}) {
    return GestureDetector(
      key: key,
      onTap: onTap == null
          ? null
          : () {
              HapticService.lightImpact();
              onTap();
            },
      child: VerifiedAvatar(
        photoUrl: widget.riderPhotoUrl,
        radius: size / 2,
        fallbackName: widget.riderName,
        uid: widget.riderId?.toString(),
        role: 'rider',
        isVerified: false,
      ),
    );
  }

  // The stop: a gold disc with a black pin (owner 2026-11-02), a modern
  // drawn pin rather than the stock glyph ("colócalo más moderno").
  Widget _pinDisc() => Container(
        width: 44,
        height: 44,
        alignment: Alignment.center,
        decoration: const BoxDecoration(
          color: _gold,
          shape: BoxShape.circle,
        ),
        child: const CustomPaint(
          size: Size(18, 23),
          painter: _ModernPinPainter(Colors.black),
        ),
      );

  /// Contactar: straight into the chat with the rider (the call lives in
  /// the chat's header), with the unread count (owner 2026-11-02).
  Widget _contactDisc({double size = 58}) {
    final disc = _disc(
      size: size,
      child: const Icon(Icons.perm_phone_msg_rounded,
          color: Colors.white, size: 26),
      onTap: widget.onOpenChat,
    );
    final stream = widget.chatUnread;
    if (stream == null) return disc;
    return StreamBuilder<int>(
      stream: stream,
      builder: (_, snap) => _badged(count: snap.data ?? 0, child: disc),
    );
  }

  Widget _badged({required int count, required Widget child}) {
    return Stack(
      clipBehavior: Clip.none,
      children: [
        child,
        if (count > 0)
          Positioned(
            top: -2,
            right: -2,
            child: Container(
              width: 22,
              height: 22,
              alignment: Alignment.center,
              decoration:
                  const BoxDecoration(color: _gold, shape: BoxShape.circle),
              child: Text(
                count > 9 ? '9+' : '$count',
                style: const TextStyle(
                    color: _ink, fontSize: 12, fontWeight: FontWeight.w700),
              ),
            ),
          ),
      ],
    );
  }

  Widget _goldButton(String label, VoidCallback onTap) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 0, 14, 16),
      child: SizedBox(
        width: double.infinity,
        height: 60,
        child: ElevatedButton(
          onPressed: () {
            HapticService.mediumImpact();
            onTap();
          },
          style: ElevatedButton.styleFrom(
            backgroundColor: _gold,
            foregroundColor: _ink,
            elevation: 0,
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(30)),
          ),
          child: Text(label,
              style:
                  const TextStyle(fontSize: 19, fontWeight: FontWeight.w700)),
        ),
      ),
    );
  }
}

/// A slide-to-confirm bar: a round knob dragged across a glass track. Gold
/// for the trip's next step, red for the no-show cancel.
class _SlideBar extends StatefulWidget {
  const _SlideBar({
    required this.label,
    required this.onDone,
    this.sub,
    this.danger = false,
    this.inset = true,
  }) : locked = false;

  const _SlideBar.locked({required this.label, this.inset = true})
      : onDone = _noop,
        sub = null,
        danger = false,
        locked = true;

  static void _noop() {}

  final String label;
  final String? sub;
  final VoidCallback onDone;
  final bool danger;
  final bool locked;

  /// Its own side/bottom margins inside the closed panel.
  final bool inset;

  @override
  State<_SlideBar> createState() => _SlideBarState();
}

class _SlideBarState extends State<_SlideBar>
    with SingleTickerProviderStateMixin {
  late final AnimationController _back = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 260),
  );
  double _x = 0;
  bool _done = false;

  @override
  void dispose() {
    _back.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    const h = 64.0;
    const knob = 56.0;
    final color = widget.danger ? const Color(0xFFFF6B6B) : _gold;
    final bar = LayoutBuilder(builder: (context, c) {
      final maxX = c.maxWidth - knob - 8;
      return Container(
        height: h,
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: widget.locked ? 0.05 : 0.08),
          borderRadius: BorderRadius.circular(h / 2),
          border: Border.all(color: Colors.white.withValues(alpha: 0.10)),
        ),
        child: Stack(
          alignment: Alignment.centerLeft,
          children: [
            Positioned.fill(
              child: Padding(
                padding: const EdgeInsets.only(left: knob + 4, right: 12),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      widget.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: widget.danger
                            ? const Color(0xFFFF9A9A)
                            : Colors.white
                                .withValues(alpha: widget.locked ? 0.55 : 0.88),
                        fontSize: widget.sub == null ? 19 : 17,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    if (widget.sub != null)
                      Text(
                        widget.sub!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color:
                              const Color(0xFFFF9A9A).withValues(alpha: 0.75),
                          fontSize: 13,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                  ],
                ),
              ),
            ),
            AnimatedBuilder(
              animation: _back,
              builder: (_, __) {
                final x = _back.isAnimating ? _x * (1 - _back.value) : _x;
                return Positioned(
                  left: 4 + x,
                  child: GestureDetector(
                    key: const ValueKey('nav-slide-knob'),
                    onHorizontalDragUpdate: widget.locked || _done
                        ? null
                        : (d) => setState(
                            () => _x = (_x + d.delta.dx).clamp(0.0, maxX)),
                    onHorizontalDragEnd: widget.locked || _done
                        ? null
                        : (_) {
                            if (_x >= maxX * 0.82) {
                              setState(() {
                                _x = maxX;
                                _done = true;
                              });
                              HapticService.heavyImpact();
                              widget.onDone();
                            } else {
                              _back.forward(from: 0).then((_) {
                                if (mounted) {
                                  setState(() => _x = 0);
                                  _back.reset();
                                }
                              });
                            }
                          },
                    child: Container(
                      width: knob,
                      height: knob,
                      decoration: BoxDecoration(
                        color: widget.locked
                            ? Colors.white.withValues(alpha: 0.12)
                            : color,
                        shape: BoxShape.circle,
                      ),
                      child: Icon(
                        widget.locked
                            ? Icons.lock_rounded
                            : (widget.danger
                                ? Icons.close_rounded
                                : Icons.arrow_forward_rounded),
                        color: widget.locked
                            ? Colors.white.withValues(alpha: 0.6)
                            : _ink,
                      ),
                    ),
                  ),
                );
              },
            ),
          ],
        ),
      );
    });
    return widget.inset
        ? Padding(padding: const EdgeInsets.fromLTRB(14, 0, 14, 16), child: bar)
        : Padding(padding: const EdgeInsets.only(bottom: 16), child: bar);
  }
}

class _DottedLine extends StatelessWidget {
  const _DottedLine();

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      size: const Size(3, double.infinity),
      painter: _DotsPainter(),
    );
  }
}

/// The line between the stops, drawn like a road's lane markings (owner
/// 2026-11-02: "la línea de puntos haz que sea como líneas de vía"): gold
/// dashes with round ends.
class _DotsPainter extends CustomPainter {
  static const double _dash = 9;
  static const double _gap = 6;

  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()
      ..color = _gold.withValues(alpha: 0.6)
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round;
    final x = size.width / 2;
    for (var y = 1.5; y < size.height - 1.5; y += _dash + _gap) {
      final end = (y + _dash).clamp(0.0, size.height - 1.5);
      canvas.drawLine(Offset(x, y), Offset(x, end), p);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

/// A flat, modern map pin: a clean teardrop with a round hole in its head
/// (the disc behind shows through). Drawn, so it never depends on a glyph
/// being in the icon font.
class _ModernPinPainter extends CustomPainter {
  const _ModernPinPainter(this.color);
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final r = w / 2;
    final cx = w / 2;
    final cy = r;
    final tip = size.height;
    final pin = Path()
      ..fillType = PathFillType.evenOdd
      ..moveTo(cx, tip)
      ..cubicTo(cx - r * 0.35, tip - r * 0.7, cx - r, cy + r * 0.55, cx - r, cy)
      ..arcToPoint(Offset(cx + r, cy), radius: Radius.circular(r))
      ..cubicTo(cx + r, cy + r * 0.55, cx + r * 0.35, tip - r * 0.7, cx, tip)
      ..close()
      ..addOval(Rect.fromCircle(center: Offset(cx, cy), radius: r * 0.42));
    canvas.drawPath(pin, Paint()..color = color);
  }

  @override
  bool shouldRepaint(covariant _ModernPinPainter old) => old.color != color;
}

class _TrianglePainter extends CustomPainter {
  _TrianglePainter(this.color);
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final path = Path()
      ..moveTo(0, 0)
      ..lineTo(size.width, 0)
      ..lineTo(size.width / 2, size.height)
      ..close();
    canvas.drawPath(path, Paint()..color = color);
  }

  @override
  bool shouldRepaint(covariant _TrianglePainter old) => old.color != color;
}

/// Reports its child's laid-out height whenever it changes — every frame of
/// an AnimatedSize included — so the map controls ride the panel's top.
class _HeightReporter extends SingleChildRenderObjectWidget {
  const _HeightReporter({required this.onHeight, super.child});

  final ValueChanged<double> onHeight;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderHeightReporter(onHeight);

  @override
  void updateRenderObject(
      BuildContext context, _RenderHeightReporter renderObject) {
    renderObject.onHeight = onHeight;
  }
}

class _RenderHeightReporter extends RenderProxyBox {
  _RenderHeightReporter(this.onHeight);

  ValueChanged<double> onHeight;
  double? _last;

  @override
  void performLayout() {
    super.performLayout();
    final h = size.height;
    if (h != _last) {
      _last = h;
      // Never call out during layout — the listener may rebuild.
      WidgetsBinding.instance.addPostFrameCallback((_) => onHeight(h));
    }
  }
}
