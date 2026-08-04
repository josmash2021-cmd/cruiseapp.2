import 'package:flutter/material.dart';

/// Tier for the map label — drives the icon + the prominent "RECOGIDA"
/// or "DESTINO" kind text.
enum MapLabelKind { pickup, dropoff }

/// Floating pill label that sits beside a pickup/dropoff pin. Matches
/// the Shopify widget's `.vipRide__mapLabel` — dark navy box with a
/// gold icon chip, a gold kind label (RECOGIDA / DESTINO), and the
/// address underneath.
///
/// It reveals itself with a bouncy 3D-ish scale-in (480ms elastic)
/// and then keeps a slow, continuous gold-glow breath on its shadow
/// (3.2s sinusoidal loop).
class AnimatedMapLabel extends StatefulWidget {
  final MapLabelKind kind;
  final String address;
  final String pickupText;
  final String dropoffText;
  final bool visible;
  final bool alignEnd;
  final int revealDelayMs;

  /// Trip minutes (pickup → dropoff) shown as a gold box GLUED to the
  /// pill's right edge — e.g. "11" renders as a stacked 11 / MIN chip.
  /// Null hides the box entirely (pickup label, or route not loaded yet).
  final String? etaMinutes;

  const AnimatedMapLabel({
    super.key,
    required this.kind,
    required this.address,
    required this.pickupText,
    required this.dropoffText,
    required this.visible,
    this.alignEnd = false,
    this.revealDelayMs = 0,
    this.etaMinutes,
  });

  @override
  State<AnimatedMapLabel> createState() => _AnimatedMapLabelState();
}

class _AnimatedMapLabelState extends State<AnimatedMapLabel>
    with TickerProviderStateMixin {
  late final AnimationController _entryCtl;
  late final AnimationController _breathCtl;
  bool _queuedShow = false;

  static const _gold = Color(0xFFE8C547);

  @override
  void initState() {
    super.initState();
    _entryCtl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 480),
    );
    _breathCtl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 3200),
    );
    if (widget.visible) _scheduleReveal();
  }

  @override
  void didUpdateWidget(covariant AnimatedMapLabel old) {
    super.didUpdateWidget(old);
    if (widget.visible && !old.visible && !_queuedShow) {
      _scheduleReveal();
    } else if (!widget.visible && old.visible) {
      _entryCtl.reverse();
      _breathCtl.stop();
    }
  }

  void _scheduleReveal() {
    _queuedShow = true;
    Future.delayed(Duration(milliseconds: widget.revealDelayMs), () {
      if (!mounted) return;
      _entryCtl.forward();
      Future.delayed(const Duration(milliseconds: 600), () {
        if (mounted) _breathCtl.repeat();
      });
    });
  }

  @override
  void dispose() {
    _entryCtl.dispose();
    _breathCtl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isPickup = widget.kind == MapLabelKind.pickup;
    final kindText = isPickup ? widget.pickupText : widget.dropoffText;
    final icon = isPickup ? Icons.place_rounded : Icons.flag_rounded;

    return AnimatedBuilder(
      animation: Listenable.merge([_entryCtl, _breathCtl]),
      builder: (_, __) {
        // Entry: 3D tilt from ±40° rotateY + scale 0.8 → 1.0, bouncy ease.
        final t = Curves.easeOutBack.transform(_entryCtl.value);
        final opacity = _entryCtl.value.clamp(0.0, 1.0);
        final scale = 0.8 + 0.2 * t;
        final rotY = (1 - t) * (widget.alignEnd ? 0.7 : -0.7);

        // Breathing glow: tri-wave 0 → 1 → 0 on a 3.2s loop.
        final b = _breathCtl.value;
        final peak = 1 - (b - 0.5).abs() * 2; // 0 → 1 → 0
        final glowAlpha = 0.12 + 0.10 * peak;
        final blur = 22.0 + 14.0 * peak;

        return Opacity(
          opacity: opacity,
          child: Transform(
            alignment:
                widget.alignEnd ? Alignment.centerRight : Alignment.centerLeft,
            transform: Matrix4.identity()
              ..setEntry(3, 2, 0.0025) // perspective
              ..rotateY(rotY)
              ..scaleByDouble(scale, scale, 1.0, 1.0),
            child: _pill(kindText, widget.address, icon, glowAlpha, blur),
          ),
        );
      },
    );
  }

  Widget _pill(String kind, String address, IconData icon, double glowAlpha,
      double blur) {
    final eta = widget.etaMinutes;
    return Container(
      decoration: BoxDecoration(
        // Pure black per the 2026-04-27 spec — was navy (0xF50F1120).
        color: Colors.black,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: _gold.withValues(alpha: 0.35),
          width: 1,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.55),
            blurRadius: 16,
            offset: const Offset(0, 4),
          ),
          BoxShadow(
            color: _gold.withValues(alpha: glowAlpha),
            blurRadius: blur,
          ),
        ],
      ),
      // Clip so the gold ETA section's corners follow the pill's radius —
      // it must read as one piece ("pegado"), not a floating chip.
      child: ClipRRect(
        borderRadius: BorderRadius.circular(9),
        child: IntrinsicHeight(
          child: Row(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(5, 5, 10, 5),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // Gold icon chip
                    Container(
                      width: 19,
                      height: 19,
                      decoration: BoxDecoration(
                        gradient: const LinearGradient(
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                          colors: [Color(0xFFF5DC7A), Color(0xFFD4A800)],
                        ),
                        borderRadius: BorderRadius.circular(5),
                      ),
                      alignment: Alignment.center,
                      child: Icon(icon, color: Colors.black, size: 11),
                    ),
                    const SizedBox(width: 6),
                    // Kind + address stack
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 130),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            kind,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontFamily: 'Poppins',
                              color: _gold,
                              fontSize: 7.5,
                              fontWeight: FontWeight.w800,
                              letterSpacing: 1.2,
                              height: 1.0,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            address,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontFamily: 'Poppins',
                              color: Colors.white,
                              fontSize: 10.5,
                              fontWeight: FontWeight.w600,
                              height: 1.15,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              // Trip-minutes box, full pill height, flush on the right.
              if (eta != null)
                Container(
                  constraints: const BoxConstraints(minWidth: 32),
                  padding: const EdgeInsets.symmetric(horizontal: 7),
                  decoration: const BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [Color(0xFFF5DC7A), Color(0xFFD4A800)],
                    ),
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        eta,
                        maxLines: 1,
                        style: const TextStyle(
                          fontFamily: 'Poppins',
                          color: Colors.black,
                          fontSize: 12.5,
                          fontWeight: FontWeight.w800,
                          height: 1.0,
                        ),
                      ),
                      const Text(
                        'MIN',
                        maxLines: 1,
                        style: TextStyle(
                          fontFamily: 'Poppins',
                          color: Colors.black,
                          fontSize: 6.5,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 0.8,
                          height: 1.1,
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
