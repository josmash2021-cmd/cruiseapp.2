import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';
import 'package:flutter/scheduler.dart';

import 'glass_style.dart';

/// THE in-app notification (owner spec 2026-11-01: "todas las
/// notificaciones dentro de la app deben llegar en este estilo — vidrio,
/// borroso — arriba; duran ~7 s, salen deslizando hacia arriba con fade y
/// también se quitan deslizando hacia arriba con el dedo").
///
/// A frosted dark glass card under the status bar, on the ROOT overlay so
/// it shows on every screen — rider and driver — and above every route
/// pushed after it. Tip received, trip/rider/driver updates, chat and
/// support messages, approvals, reservations released: all of them come
/// through [GlassNotificationBanner.show]. Bottom SnackBars are for
/// immediate feedback to the user's own tap (validation, "copied", a
/// failed save), never for something that HAPPENED.
///
/// Constants are top-level (project rule #16).

/// How long a banner stays before it leaves on its own.
const kGlassBannerDuration = Duration(seconds: 7);

/// The driver's own "You declined a ride request" note is shorter (owner
/// spec 2026-11-01): 5 s, same glass, same exit.
const kDeclinedOfferBannerDuration = Duration(seconds: 5);

/// Entrance: slides down from above the screen + fades in.
const kGlassBannerInDuration = Duration(milliseconds: 420);

/// Exit (timer, tap or swipe): slides up + fades out.
const kGlassBannerOutDuration = Duration(milliseconds: 280);

/// Curve of the slide, both ways. Forward it decelerates into place; in
/// reverse the same curve leaves slowly and accelerates away, upwards.
const kGlassBannerCurve = Curves.easeOutCubic;

const kGlassBannerSideMargin = 16.0;

/// Gap between the status bar (safe-area top) and the banner.
const kGlassBannerTopGap = 8.0;
const kGlassBannerRadius = 20.0;

/// Tablets / landscape: the card stops growing here and centres.
const kGlassBannerMaxWidth = 560.0;

/// Extra travel above the safe area for the slide, so the card starts and
/// ends fully off-screen (cards are 68–82 px tall at text scale 1).
const kGlassBannerTravel = 96.0;

/// Frost: the sheet's glass. A light 40 % smoke (2026-11-01, "¿por qué está
/// gris y no transparente blurry?") let the map's own chrome read through
/// on the phone — the earnings "$0.00" was legible under the card (owner
/// 2026-11-02: "no debe verse el contenido que hay detrás"). The sheet's
/// dark smoke hides it; the blur still softens the map at the edges.
const kGlassBannerBlur = kGlassSheetBlur;
const kGlassBannerTint = glassSheetTint; // #1A1A21 @ 90 %

/// The frost covers the WHOLE card, edge to edge, one even tint (owner
/// 2026-11-01: "veo que está como un cuadro, debe ser todo de vidrio
/// blurry"). It used to be inset 6 px with a denser rim, so iOS's
/// rectangular platform-view blur could never poke past the rounded
/// corners — but the rim read as a box inside the card. Same recipe as the
/// online/offline sheet (GlassSurface, full rect): on iOS the blur may
/// square off the 20 px corners slightly, exactly as the sheet's do.

const kGlassBannerIconSize = 40.0; // gold ring
const kGlassBannerGlyphSize = 20.0;
const kGlassBannerGold = Color(0xFFE8C547);

/// Swipe up farther than this, or fling up faster than
/// [kGlassBannerSwipeVelocity], and the banner leaves; less springs back.
const kGlassBannerSwipeDistance = 36.0;
const kGlassBannerSwipeVelocity = 500.0; // px/s

/// Pulling DOWN is allowed a little, with rubber-band resistance.
const kGlassBannerPullDownMax = 14.0;

/// Spring that brings the card back after a short swipe (slightly under
/// critical damping: one soft settle, no wobble).
const kGlassBannerSpring =
    SpringDescription(mass: 1, stiffness: 520, damping: 40);

/// Icon for a push `type` (the push payload's `data.type`).
IconData glassBannerIconForType(String type) {
  switch (type) {
    case 'tip':
    case 'tip_received':
      return Icons.attach_money_rounded;
    case 'chat_message':
      return Icons.chat_bubble_rounded;
    case 'support_message':
    case 'support_followup':
      return Icons.support_agent_rounded;
    case 'instant_cashout':
    case 'payout_sent':
    case 'payout':
    case 'cashout':
      return Icons.account_balance_wallet_rounded;
    case 'trip_canceled':
    case 'trip_cancelled':
    case 'rider_cancelled':
    case 'driver_cancelled':
    case 'scheduled_cancelled':
    case 'scheduled_driver_cancelled':
      return Icons.close_rounded;
    case 'trip_reassigned':
    case 'ride_reassigned':
      return Icons.swap_horiz_rounded;
    case 'driver_assigned':
    case 'driver_found':
    case 'driver_arriving':
    case 'driver_arrived':
    case 'arrived':
    case 'in_trip':
      return Icons.local_taxi_rounded;
    case 'completed':
    case 'arrived_dropoff':
      return Icons.flag_rounded;
    case 'driver_approved':
    case 'rider_approved':
    case 'face_check_approved':
      return Icons.verified_rounded;
    case 'driver_rejected':
    case 'rider_rejected':
    case 'face_check_rejected':
    case 'driver_waitlisted':
      return Icons.error_outline_rounded;
    case 'level_up':
    case 'level_down':
      return Icons.workspace_premium_rounded;
    case 'scheduled_ride':
    case 'scheduled_claimed':
    case 'scheduled_reminder':
    case 'scheduled_trip_starting':
    case 'scheduled_available':
      return Icons.event_rounded;
    case 'drivers_available':
    case 'fast_ride':
      return Icons.near_me_rounded;
    default:
      return Icons.notifications_rounded;
  }
}

/// Shows / replaces the one in-app notification banner.
///
/// One at a time, newest wins: a new banner replaces the current one (the
/// old card slides up and out while the new one slides in). No queue — a
/// queue of 7 s banners would show stale news ("driver arriving" after the
/// driver arrived); every push is in the inbox anyway. The same title +
/// body arriving again while it is still up only restarts its 7 s.
class GlassNotificationBanner {
  GlassNotificationBanner._();

  /// The root navigator. main() sets it, so code without a widget context
  /// (push handlers, services) can show a banner; [show]'s `context` is the
  /// fallback (tests, or before main wired it).
  static GlobalKey<NavigatorState>? navigatorKey;

  static OverlayEntry? _entry;
  static GlobalKey<_GlassBannerState>? _stateKey;
  static String? _signature;

  /// True while a banner is on screen (entering, resting or leaving).
  static bool get isShowing => _entry != null;

  static void show({
    BuildContext? context,
    required String title,
    String? body,
    IconData icon = Icons.notifications_rounded,
    Color accent = kGlassBannerGold,
    VoidCallback? onTap,
    Duration duration = kGlassBannerDuration,
  }) {
    final t = title.trim();
    final b = (body ?? '').trim();
    if (t.isEmpty && b.isEmpty) return;
    // Inserting into the overlay rebuilds it — never in the middle of a
    // build; wait for the frame to finish.
    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      SchedulerBinding.instance.addPostFrameCallback((_) => show(
            context: context,
            title: t,
            body: b,
            icon: icon,
            accent: accent,
            onTap: onTap,
            duration: duration,
          ));
      return;
    }
    final overlay = _resolveOverlay(context);
    if (overlay == null) {
      debugPrint('[GlassBanner] no overlay — dropped "$t"');
      return;
    }
    final signature = '$t\u0000$b';
    final current = _stateKey?.currentState;
    if (current != null && !current.isLeaving && _signature == signature) {
      current.restartTimer(duration);
      return;
    }
    // Replace: the old card leaves with its exit animation (it removes its
    // own entry when done). One inserted but not built yet has no state to
    // animate — just drop it.
    if (current != null) {
      current.dismiss();
    } else if (_entry != null && _entry!.mounted) {
      _entry!.remove();
    }

    final key = GlobalKey<_GlassBannerState>();
    late final OverlayEntry entry;
    entry = OverlayEntry(
      builder: (_) => _GlassBanner(
        key: key,
        title: t,
        body: b,
        icon: icon,
        accent: accent,
        onTap: onTap,
        duration: duration,
        onGone: () {
          if (entry.mounted) entry.remove();
          _forget(entry);
        },
        onDisposed: () => _forget(entry),
      ),
    );
    _entry = entry;
    _stateKey = key;
    _signature = signature;
    overlay.insert(entry);
  }

  /// Sends the current banner away (slide up + fade).
  static void dismiss() => _stateKey?.currentState?.dismiss();

  static void _forget(OverlayEntry entry) {
    if (!identical(_entry, entry)) return;
    _entry = null;
    _stateKey = null;
    _signature = null;
  }

  static OverlayState? _resolveOverlay(BuildContext? context) {
    final root = navigatorKey?.currentState?.overlay;
    if (root != null && root.mounted) return root;
    if (context != null && context.mounted) {
      return Overlay.maybeOf(context, rootOverlay: true);
    }
    return null;
  }

  /// Tests: forget the current banner without animating.
  @visibleForTesting
  static void debugReset() {
    final e = _entry;
    _entry = null;
    _stateKey = null;
    _signature = null;
    if (e != null && e.mounted) e.remove();
  }
}

class _GlassBanner extends StatefulWidget {
  const _GlassBanner({
    super.key,
    required this.title,
    required this.body,
    required this.icon,
    required this.accent,
    required this.duration,
    required this.onGone,
    required this.onDisposed,
    this.onTap,
  });

  final String title;
  final String body;
  final IconData icon;
  final Color accent;
  final Duration duration;
  final VoidCallback? onTap;

  /// Exit animation finished: remove the entry.
  final VoidCallback onGone;

  /// Removed from outside (overlay torn down, [GlassNotificationBanner.
  /// debugReset]): only forget it — removing it again would throw.
  final VoidCallback onDisposed;

  @override
  State<_GlassBanner> createState() => _GlassBannerState();
}

class _GlassBannerState extends State<_GlassBanner>
    with TickerProviderStateMixin {
  late final AnimationController _presence = AnimationController(
    vsync: this,
    duration: kGlassBannerInDuration,
    reverseDuration: kGlassBannerOutDuration,
  );
  late final CurvedAnimation _slide =
      CurvedAnimation(parent: _presence, curve: kGlassBannerCurve);

  /// The finger's vertical offset (negative = up); springs back to 0.
  late final AnimationController _drag = AnimationController.unbounded(
    vsync: this,
  );

  Timer? _timer;
  double _dragRaw = 0;
  bool _dragging = false;
  bool _expired = false;
  bool _leaving = false;
  bool _goneCalled = false;

  bool get isLeaving => _leaving;

  @override
  void initState() {
    super.initState();
    _presence.forward();
    restartTimer(widget.duration);
  }

  void restartTimer(Duration d) {
    _timer?.cancel();
    _expired = false;
    _timer = Timer(d, _onExpire);
  }

  void _onExpire() {
    if (!mounted) return;
    // Never yank it from under a finger: leave on release instead.
    if (_dragging) {
      _expired = true;
      return;
    }
    dismiss();
  }

  void dismiss() {
    if (_leaving || !mounted) return;
    _leaving = true;
    _timer?.cancel();
    _drag.stop();
    setState(() {}); // IgnorePointer on while it leaves
    _presence.reverse().whenCompleteOrCancel(_gone);
  }

  void _gone() {
    if (_goneCalled) return;
    _goneCalled = true;
    widget.onGone();
  }

  void _onTap() {
    if (_leaving) return;
    try {
      widget.onTap?.call();
    } finally {
      dismiss();
    }
  }

  void _onDragStart(DragStartDetails d) {
    if (_leaving) return;
    _dragging = true;
    _drag.stop();
    _dragRaw = _drag.value;
  }

  void _onDragUpdate(DragUpdateDetails d) {
    if (_leaving) return;
    _dragRaw += d.delta.dy;
    _drag.value = _dragRaw <= 0
        ? _dragRaw
        : kGlassBannerPullDownMax * (1 - math.exp(-_dragRaw / 60));
  }

  void _onDragEnd(DragEndDetails d) {
    if (_leaving) return;
    _dragging = false;
    final v = d.velocity.pixelsPerSecond.dy;
    final dy = _drag.value;
    final flungUp = v <= -kGlassBannerSwipeVelocity;
    final pushedUp = dy <= -kGlassBannerSwipeDistance && v < 300;
    if (flungUp || pushedUp || _expired) {
      dismiss();
      return;
    }
    _drag.animateWith(SpringSimulation(kGlassBannerSpring, dy, 0, v));
  }

  void _onDragCancel() {
    if (!_dragging) return;
    _onDragEnd(DragEndDetails());
  }

  @override
  void dispose() {
    _timer?.cancel();
    // Before the controllers go: disposing one mid-exit cancels its
    // TickerFuture, whose whenCompleteOrCancel would then call onGone.
    final wasGone = _goneCalled;
    _goneCalled = true;
    _slide.dispose();
    _presence.dispose();
    _drag.dispose();
    if (!wasGone) widget.onDisposed();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final topPad =
        (MediaQuery.maybeOf(context)?.padding.top ?? 0) + kGlassBannerTopGap;
    final travel = topPad + kGlassBannerTravel;
    return Positioned(
      top: topPad,
      left: 0,
      right: 0,
      child: AnimatedBuilder(
        animation: Listenable.merge([_presence, _drag]),
        builder: (context, child) {
          final dy = _drag.value - (1 - _slide.value) * travel;
          // Opacity is exactly 1.0 at rest: the engine skips the layer
          // then, so the frost keeps seeing the map (a BackdropFilter
          // inside opacity < 1 only sees that layer — rule #43). While it
          // fades in/out the frost briefly reads as plain tint.
          return IgnorePointer(
            ignoring: _leaving,
            child: Transform.translate(
              offset: Offset(0, dy),
              child: Opacity(
                opacity: _presence.value.clamp(0.0, 1.0),
                child: child,
              ),
            ),
          );
        },
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(
              maxWidth: kGlassBannerMaxWidth + 2 * kGlassBannerSideMargin,
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(
                  horizontal: kGlassBannerSideMargin),
              child: _card(context),
            ),
          ),
        ),
      ),
    );
  }

  Widget _card(BuildContext context) {
    final theme = Theme.of(context);
    final hasBody = widget.body.isNotEmpty;
    // Poppins comes from the app theme (title* styles) — never a direct
    // GoogleFonts call, which would hit the network in tests.
    final titleStyle = (theme.textTheme.titleMedium ?? const TextStyle())
        .copyWith(
      color: Colors.white,
      fontSize: 15,
      fontWeight: FontWeight.w600,
      height: 1.25,
      letterSpacing: 0,
      decoration: TextDecoration.none,
    );
    final bodyStyle = (theme.textTheme.titleSmall ?? const TextStyle())
        .copyWith(
      color: Colors.white.withValues(alpha: 0.72),
      fontSize: 13,
      fontWeight: FontWeight.w400,
      height: 1.25,
      letterSpacing: 0,
      decoration: TextDecoration.none,
    );
    final accent = widget.accent;

    final content = Padding(
      padding: const EdgeInsets.fromLTRB(14, 14, 12, 14),
      child: Row(
        children: [
          Container(
            width: kGlassBannerIconSize,
            height: kGlassBannerIconSize,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: accent.withValues(alpha: 0.14),
              border: Border.all(
                  color: accent.withValues(alpha: 0.9), width: 1.5),
            ),
            child: Icon(widget.icon,
                size: kGlassBannerGlyphSize, color: accent),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  widget.title.isNotEmpty ? widget.title : widget.body,
                  maxLines: hasBody && widget.title.isNotEmpty ? 1 : 2,
                  overflow: TextOverflow.ellipsis,
                  style: titleStyle,
                ),
                if (hasBody && widget.title.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(
                    widget.body,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: bodyStyle,
                  ),
                ],
              ],
            ),
          ),
          if (widget.onTap != null) ...[
            const SizedBox(width: 8),
            Icon(Icons.chevron_right_rounded,
                size: 22, color: Colors.white.withValues(alpha: 0.55)),
          ],
        ],
      ),
    );

    final radius = BorderRadius.circular(kGlassBannerRadius);
    return Semantics(
      container: true,
      liveRegion: true,
      button: widget.onTap != null,
      label: hasBody && widget.title.isNotEmpty
          ? '${widget.title}. ${widget.body}'
          : (widget.title.isNotEmpty ? widget.title : widget.body),
      excludeSemantics: true,
      onTap: widget.onTap != null ? _onTap : null,
      onDismiss: dismiss,
      child: GestureDetector(
        key: const ValueKey('glass-notification-banner'),
        behavior: HitTestBehavior.opaque,
        onTap: _onTap,
        onVerticalDragStart: _onDragStart,
        onVerticalDragUpdate: _onDragUpdate,
        onVerticalDragEnd: _onDragEnd,
        onVerticalDragCancel: _onDragCancel,
        child: Material(
          type: MaterialType.transparency,
          child: Stack(
            children: [
              // The frost: the whole card, one even tint, the hairline of
              // light on the edge — the sheet's glass, nothing inset.
              Positioned.fill(
                child: GlassSurface(
                  borderRadius: radius,
                  blur: kGlassBannerBlur,
                  tint: kGlassBannerTint,
                  borderColor: glassEdge,
                  child: const SizedBox.expand(),
                ),
              ),
              content,
            ],
          ),
        ),
      ),
    );
  }
}
