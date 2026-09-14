import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

/// Which way the mini-map ⇄ navigation morph runs.
enum NavMorphDirection { enter, exit }

/// Diffused mini-map ⇄ full-screen-navigation morph.
///
/// A native Mapbox surface can never be resized, clipped or cross-faded
/// mid-flight — and two live surfaces are the iOS crash — so the morph
/// animates a one-shot `MapboxMap.snapshot()` of the map that is leaving
/// the tree. The image is plain Flutter content, so it can carry what the
/// platform view cannot: feathered edges, blur and a free transform.
///
/// enter — the preview's last frame blooms out of the card rect, edges
///   dissolved into the page colour, over a scrim that fades the trip UI
///   away; once the live nav map signals ready ([revealRequested]) the
///   layer cross-fades out and navigation is simply there.
/// exit — the nav map's last frame contracts back toward the card rect,
///   dissolving at the edges, while the trip sheet fades back in beneath.
class NavMorphOverlay extends StatefulWidget {
  const NavMorphOverlay({
    super.key,
    required this.direction,
    required this.imageBytes,
    required this.sourceRect,
    required this.backgroundColor,
    this.revealRequested = false,
    required this.onFinished,
  });

  final NavMorphDirection direction;

  /// Snapshot of the departing map — its exact last frame.
  final Uint8List imageBytes;

  /// Global rect of the mini-map card the morph blooms from / returns to.
  final Rect sourceRect;

  /// Page background: the scrim and the feather fades dissolve into it.
  final Color backgroundColor;

  /// enter only: the live nav map has its first controller and route drawn.
  final bool revealRequested;

  /// The overlay has fully dissolved and can leave the tree.
  final VoidCallback onFinished;

  @override
  State<NavMorphOverlay> createState() => _NavMorphOverlayState();
}

class _NavMorphOverlayState extends State<NavMorphOverlay>
    with SingleTickerProviderStateMixin {
  /// Expansion level: 0 = inside the card rect, 1 = covering the screen.
  late final AnimationController _expand;
  late final Animation<double> _expandAnim;

  /// enter only: the final cross-fade onto the live navigation map.
  late final AnimationController _reveal;

  /// Never leave the driver under a frozen snapshot: if the nav map never
  /// signals ready (revoked surface, init failure), reveal anyway.
  Timer? _revealTimeout;
  bool _revealStarted = false;

  bool get _isEnter => widget.direction == NavMorphDirection.enter;

  @override
  void initState() {
    super.initState();
    _expand = AnimationController(
      vsync: this,
      duration: Duration(milliseconds: _isEnter ? 700 : 620),
    );
    _expandAnim =
        CurvedAnimation(parent: _expand, curve: Curves.easeInOutCubic);
    _reveal = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 260),
    );
    _reveal.addStatusListener((status) {
      if (status == AnimationStatus.completed) widget.onFinished();
    });
    if (_isEnter) {
      _expand.addStatusListener((status) {
        if (status == AnimationStatus.completed && widget.revealRequested) {
          _startReveal();
        }
      });
      _expand.forward();
      _revealTimeout = Timer(const Duration(seconds: 4), _startReveal);
    } else {
      _expand.value = 1.0;
      _expand.addStatusListener((status) {
        if (status == AnimationStatus.dismissed) widget.onFinished();
      });
      _expand.reverse();
    }
  }

  @override
  void didUpdateWidget(NavMorphOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_isEnter && widget.revealRequested && !oldWidget.revealRequested) {
      _startReveal();
    }
  }

  void _startReveal() {
    if (!_isEnter || _revealStarted || !mounted) return;
    _revealStarted = true;
    _revealTimeout?.cancel();
    // The cross-fade reads as one motion only from a settled, fully-bloomed
    // frame — if the map got ready mid-bloom, finish the bloom first.
    if (_expand.isCompleted) {
      _reveal.forward();
    } else {
      _expand
          .animateTo(1.0,
              duration: const Duration(milliseconds: 160),
              curve: Curves.easeOut)
          .then((_) {
        if (mounted) _reveal.forward();
      });
    }
  }

  @override
  void dispose() {
    _revealTimeout?.cancel();
    _reveal.dispose();
    _expand.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final screen = MediaQuery.of(context).size;
    final rect = widget.sourceRect;
    final coverScale = math.max(
          screen.width / rect.width,
          screen.height / rect.height,
        ) *
        1.06;
    return GestureDetector(
      // Absorb every touch for the ~1 s the morph owns the screen — a stray
      // tap on a half-dissolved control is a state bug waiting to happen.
      behavior: HitTestBehavior.opaque,
      onTap: () {},
      child: AnimatedBuilder(
        animation: Listenable.merge([_expand, _reveal]),
        builder: (context, _) {
          final p = _expandAnim.value;
          final opacity = _isEnter
              ? 1.0 - _reveal.value
              : (p / 0.55).clamp(0.0, 1.0);
          final scale = _isEnter
              ? 1.0 + (coverScale - 1.0) * p
              : (1.0 / coverScale) + (1.0 - 1.0 / coverScale) * p;
          final blur = _isEnter ? 4.0 * p : 3.0 * (1.0 - p);
          final scrimOpacity =
              _isEnter ? (p / 0.75).clamp(0.0, 1.0) : 0.0;
          // The live nav map ends flush with the screen edges, so the exit
          // frame it hands over carries no feather yet — the dissolve grows
          // as the contraction proceeds. The mini-map card always has one.
          final featherOpacity = _isEnter ? 1.0 : (1.0 - p);
          final radius = _isEnter ? 18.0 * (1.0 - p) : 0.0;

          final image = ImageFiltered(
            imageFilter: ui.ImageFilter.blur(sigmaX: blur, sigmaY: blur),
            child: Image.memory(
              widget.imageBytes,
              fit: BoxFit.fill,
              gaplessPlayback: true,
              filterQuality: FilterQuality.medium,
            ),
          );
          final framed = ClipRRect(
            borderRadius: BorderRadius.circular(radius),
            child: Stack(
              fit: StackFit.expand,
              children: [
                image,
                Opacity(
                  opacity: featherOpacity,
                  child: _Feather(color: widget.backgroundColor),
                ),
              ],
            ),
          );

          return Opacity(
            opacity: opacity,
            child: Stack(
              fit: StackFit.expand,
              children: [
                if (scrimOpacity > 0)
                  Positioned.fill(
                    child: Opacity(
                      opacity: scrimOpacity,
                      child: ColoredBox(color: widget.backgroundColor),
                    ),
                  ),
                Transform.scale(
                  scale: scale,
                  origin: rect.center,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      // enter: the card's frame, growing until it covers.
                      // exit: the full-screen nav frame, shrinking home.
                      if (_isEnter)
                        Positioned.fromRect(rect: rect, child: framed)
                      else
                        Positioned.fill(child: framed),
                    ],
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

/// The same edge-dissolve treatment as the accept screen's
/// `_buildMapEdgeFade`: two multi-stop linear fades plus a radial vignette
/// for the corners, all into the page colour — the map never shows a hard
/// rectangular edge at any point of the morph.
class _Feather extends StatelessWidget {
  const _Feather({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) {
    LinearGradient edge(Alignment begin, Alignment end) => LinearGradient(
          begin: begin,
          end: end,
          colors: [
            color,
            color.withValues(alpha: .85),
            color.withValues(alpha: .35),
            Colors.transparent,
            Colors.transparent,
            color.withValues(alpha: .35),
            color.withValues(alpha: .85),
            color,
          ],
          stops: const [0, .05, .11, .22, .78, .89, .95, 1],
        );
    return Stack(
      fit: StackFit.expand,
      children: [
        DecoratedBox(
          decoration: BoxDecoration(
            gradient: edge(Alignment.topCenter, Alignment.bottomCenter),
          ),
        ),
        DecoratedBox(
          decoration: BoxDecoration(
            gradient: edge(Alignment.centerLeft, Alignment.centerRight),
          ),
        ),
        DecoratedBox(
          decoration: BoxDecoration(
            gradient: RadialGradient(
              center: Alignment.center,
              radius: 1.15,
              colors: [
                Colors.transparent,
                Colors.transparent,
                color.withValues(alpha: .42),
                color,
              ],
              stops: const [0, .48, .76, 1],
            ),
          ),
        ),
      ],
    );
  }
}
