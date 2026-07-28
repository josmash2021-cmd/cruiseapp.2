import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../l10n/app_localizations.dart';
import '../models/airport_models.dart';
import '../widgets/neu_style.dart';

/// Neumorphic airport direction picker — step 1 of the airport flow.
/// Shows "Take me TO the airport" / "Pick me up FROM the airport" cards
/// and returns the chosen [AirportDirection] via Navigator.pop
/// (null if the user goes back).
class AirportDirectionScreen extends StatefulWidget {
  const AirportDirectionScreen({super.key});

  @override
  State<AirportDirectionScreen> createState() =>
      _AirportDirectionScreenState();
}

class _AirportDirectionScreenState extends State<AirportDirectionScreen>
    with TickerProviderStateMixin {
  late final AnimationController _entryCtl;
  late final AnimationController _floatCtl;

  // Background video (same asset the old airport sheet used).
  VideoPlayerController? _video;
  bool _videoReady = false;

  @override
  void initState() {
    super.initState();
    _entryCtl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 650),
    )..forward();
    _floatCtl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 3600),
    )..repeat();
    _initVideo();
  }

  Future<void> _initVideo() async {
    try {
      _video = VideoPlayerController.asset('assets/videos/airport_bg.mp4');
      await _video!.initialize();
      await _video!.setLooping(true);
      await _video!.setVolume(0);
      if (mounted) {
        setState(() => _videoReady = true);
        _video!.play();
      }
    } catch (_) {
      // No video — the neuBase background stays as fallback.
    }
  }

  @override
  void dispose() {
    _entryCtl.dispose();
    _floatCtl.dispose();
    _video?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);

    return Scaffold(
      backgroundColor: neuBase,
      body: Stack(
        fit: StackFit.expand,
        children: [
          // ── Video background with dark scrim ──
          if (_videoReady && _video != null)
            SizedBox.expand(
              child: FittedBox(
                fit: BoxFit.cover,
                child: SizedBox(
                  width: _video!.value.size.width,
                  height: _video!.value.size.height,
                  child: VideoPlayer(_video!),
                ),
              ),
            ),
          if (_videoReady)
            ColoredBox(color: Colors.black.withValues(alpha: 0.78)),

          // ── Content ──
          // Height-adaptive: on short screens the two cards + spacers can
          // exceed the available height (RenderFlex overflow). Let the
          // column scroll in that case while keeping the spacer
          // distribution when there is room.
          SafeArea(
            child: LayoutBuilder(
              builder: (context, constraints) {
                return SingleChildScrollView(
                  physics: const BouncingScrollPhysics(),
                  child: ConstrainedBox(
                    constraints:
                        BoxConstraints(minHeight: constraints.maxHeight),
                    child: IntrinsicHeight(
                      child: Column(
          children: [
            // ── Header: back + title ──
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
              child: Row(
                children: [
                  GestureDetector(
                    onTap: () => Navigator.pop(context),
                    child: Container(
                      width: 40,
                      height: 40,
                      decoration: neuBox(radius: 14, pressed: true),
                      child: const Icon(
                        Icons.arrow_back_rounded,
                        color: Colors.white,
                        size: 20,
                      ),
                    ),
                  ),
                  Expanded(
                    child: Center(
                      child: Padding(
                        padding: const EdgeInsets.only(right: 44),
                        child: Text(
                          s.airportRideTitle,
                          style: const TextStyle(
                            fontFamily: 'Poppins',
                            color: Colors.white,
                            fontSize: 18,
                            fontWeight: FontWeight.w700,
                            letterSpacing: -0.2,
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),

            const Spacer(flex: 2),

            // ── TO the airport ──
            _Staggered(
              controller: _entryCtl,
              delay: 0.0,
              child: _DirectionCard(
                imageAsset: 'assets/airport/airport_takeoff.png',
                title: s.takeMeToAirport,
                subtitle: s.flyingOutSubtitle,
                isToAirport: true,
                floatCtl: _floatCtl,
                onTap: () =>
                    Navigator.pop(context, AirportDirection.toAirport),
              ),
            ),

            const SizedBox(height: 28),

            // ── FROM the airport ──
            _Staggered(
              controller: _entryCtl,
              delay: 0.18,
              child: _DirectionCard(
                imageAsset: 'assets/airport/airport_landing.png',
                title: s.pickMeUpFromAirport,
                subtitle: s.justLandedSubtitle,
                isToAirport: false,
                floatCtl: _floatCtl,
                onTap: () =>
                    Navigator.pop(context, AirportDirection.fromAirport),
              ),
            ),

            const Spacer(flex: 3),
          ],
        ),
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _Staggered extends StatelessWidget {
  final AnimationController controller;
  final double delay;
  final Widget child;

  const _Staggered({
    required this.controller,
    required this.delay,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    final anim = CurvedAnimation(
      parent: controller,
      curve: Interval(delay, 1.0, curve: Curves.easeOutCubic),
    );
    return AnimatedBuilder(
      animation: anim,
      builder: (_, c) => Opacity(
        opacity: anim.value,
        child: Transform.translate(
          offset: Offset(0, 28 * (1 - anim.value)),
          child: c,
        ),
      ),
      child: child,
    );
  }
}

class _DirectionCard extends StatefulWidget {
  final String imageAsset;
  final String title;
  final String subtitle;
  final bool isToAirport;
  final AnimationController floatCtl;
  final VoidCallback onTap;

  const _DirectionCard({
    required this.imageAsset,
    required this.title,
    required this.subtitle,
    required this.isToAirport,
    required this.floatCtl,
    required this.onTap,
  });

  @override
  State<_DirectionCard> createState() => _DirectionCardState();
}

class _DirectionCardState extends State<_DirectionCard> {
  static const _gold = Color(0xFFE8C547);
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: widget.onTap,
      onTapDown: (_) => setState(() => _pressed = true),
      onTapCancel: () => setState(() => _pressed = false),
      onTapUp: (_) => setState(() => _pressed = false),
      child: AnimatedScale(
        scale: _pressed ? 0.97 : 1.0,
        duration: const Duration(milliseconds: 130),
        child: AnimatedOpacity(
          opacity: _pressed ? 0.85 : 1.0,
          duration: const Duration(milliseconds: 130),
          child: Container(
            width: double.infinity,
            margin: const EdgeInsets.symmetric(horizontal: 24),
            constraints: const BoxConstraints(maxWidth: 420),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 20),
            // Sin cuadro: la tarjeta es transparente — solo quedan las
            // sombras (pozo del avión, badge) y los textos sobre el video.
            child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Plane tile — sunken neumorphic well, floating plane,
              // gold arrow badge top-right.
              AnimatedBuilder(
                animation: widget.floatCtl,
                builder: (context, _) {
                  final t = widget.floatCtl.value;
                  final dx = (widget.isToAirport ? 4.0 : -4.0) *
                      math.sin(t * 2 * math.pi);
                  final dy = -5 * math.sin(t * 2 * math.pi);
                  final rot = (widget.isToAirport ? 1.5 : -1.5) *
                      math.sin(t * 2 * math.pi);
                  return Stack(
                    clipBehavior: Clip.none,
                    children: [
                      Container(
                        width: 150,
                        height: 150,
                        decoration: neuBox(radius: 22, pressed: true),
                        child: Padding(
                          padding: const EdgeInsets.all(14),
                          child: Transform.translate(
                            offset: Offset(dx, dy),
                            child: Transform.rotate(
                              angle: rot * math.pi / 180,
                              child: Image.asset(
                                widget.imageAsset,
                                fit: BoxFit.contain,
                              ),
                            ),
                          ),
                        ),
                      ),
                      Positioned(
                        top: -6,
                        right: -6,
                        child: Container(
                          width: 28,
                          height: 28,
                          decoration: BoxDecoration(
                            color: _gold,
                            shape: BoxShape.circle,
                            boxShadow: [
                              BoxShadow(
                                color: _gold.withValues(alpha: 0.45),
                                blurRadius: 10,
                                offset: const Offset(0, 3),
                              ),
                            ],
                          ),
                          child: Icon(
                            widget.isToAirport
                                ? Icons.arrow_forward_rounded
                                : Icons.arrow_back_rounded,
                            color: Colors.black,
                            size: 15,
                          ),
                        ),
                      ),
                    ],
                  );
                },
              ),
              const SizedBox(height: 18),
              Text(
                widget.title,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontFamily: 'Poppins',
                  color: Colors.white,
                  fontSize: 20,
                  fontWeight: FontWeight.w700,
                  height: 1.25,
                  letterSpacing: -0.2,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                widget.subtitle,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontFamily: 'Poppins',
                  color: Colors.white.withValues(alpha: 0.5),
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                  height: 1.3,
                ),
              ),
            ],
          ),
        ),
          ),
      ),
    );
  }
}
