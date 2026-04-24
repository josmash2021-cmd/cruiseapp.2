import 'package:flutter/material.dart';

/// Tier for the vehicle badge shown on ride cards.
///
/// Pixel-matches the Shopify widget's `.vipRide__badge--vip/--premium/--comfort`.
enum VehicleTier { vip, premium, comfort }

/// Three-variant badge (VIP / PREMIUM / COMFORT) that matches the
/// Shopify booking widget exactly:
///
/// * **VIP** — dark gradient, gold border, 6s pulsing gold halo, white
///   text, crown icon with 3 sparkles that twinkle on a 2.4s loop
///   offset by 0 / .8s / 1.6s.
/// * **PREMIUM** — gold gradient, black text, star icon, static glow.
/// * **COMFORT** — silver gradient, dark text, `✦` diamond icon,
///   subtle silver glow.
class VehicleTierBadge extends StatefulWidget {
  final VehicleTier tier;
  final double width;
  final double height;
  final double fontSize;

  const VehicleTierBadge({
    super.key,
    required this.tier,
    this.width = 78,
    this.height = 22,
    this.fontSize = 9,
  });

  @override
  State<VehicleTierBadge> createState() => _VehicleTierBadgeState();
}

class _VehicleTierBadgeState extends State<VehicleTierBadge>
    with TickerProviderStateMixin {
  AnimationController? _halo; // VIP only — 6s halo pulse
  AnimationController? _twinkle; // VIP only — 2.4s sparkle twinkle

  @override
  void initState() {
    super.initState();
    if (widget.tier == VehicleTier.vip) {
      _halo = AnimationController(
        vsync: this,
        duration: const Duration(seconds: 6),
      )..repeat();
      _twinkle = AnimationController(
        vsync: this,
        duration: const Duration(milliseconds: 2400),
      )..repeat();
    }
  }

  @override
  void dispose() {
    _halo?.dispose();
    _twinkle?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    switch (widget.tier) {
      case VehicleTier.vip:
        return _buildVip();
      case VehicleTier.premium:
        return _buildPremium();
      case VehicleTier.comfort:
        return _buildComfort();
    }
  }

  Widget _buildVip() {
    return AnimatedBuilder(
      animation: _halo!,
      builder: (_, __) {
        // 0 and 1 → baseline; 0.5 → peak glow. Matches the CSS @keyframes vipHalo.
        final t = _halo!.value;
        final peak = (1 - (t - 0.5).abs() * 2).clamp(0.0, 1.0); // tri-wave
        return Container(
          width: widget.width,
          height: widget.height,
          decoration: BoxDecoration(
            gradient: const LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [Color(0xFF1A1A1A), Color(0xFF000000)],
            ),
            borderRadius: BorderRadius.circular(6),
            border: Border.all(
              color: const Color(0xFFE8C547).withValues(alpha: 0.30),
              width: 1,
            ),
            boxShadow: [
              // Base drop shadow (always present)
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.5 + 0.05 * peak),
                blurRadius: 8 + 2 * peak,
                offset: const Offset(0, 2),
              ),
              // Gold halo (peaks at 50%)
              BoxShadow(
                color: const Color(0xFFE8C547)
                    .withValues(alpha: 0.08 + 0.27 * peak),
                blurRadius: 4 + 12 * peak,
              ),
            ],
          ),
          alignment: Alignment.center,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              // Web uses a 13×13 crown SVG directly in-flow.
              SizedBox(
                width: 13,
                height: 13,
                child: CustomPaint(
                  painter: _VipCrownPainter(twinkle: _twinkle!),
                ),
              ),
              // .vipRide__badge: gap:1px between icon and text.
              const SizedBox(width: 1),
              Text(
                'VIP',
                style: TextStyle(
                  fontFamily: 'Poppins',
                  color: Colors.white,
                  fontSize: widget.fontSize,
                  // .vipRide__badge: font-weight 800, letter-spacing .08em
                  // (≈0.72px at font-size 9px).
                  fontWeight: FontWeight.w800,
                  letterSpacing: 0.72,
                  height: 1.0,
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildPremium() {
    return Container(
      width: widget.width,
      height: widget.height,
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFFF5DC7A), Color(0xFFE8C547), Color(0xFFB08800)],
        ),
        borderRadius: BorderRadius.circular(6),
        boxShadow: const [
          BoxShadow(
            color: Color(0x66D4AF37),
            blurRadius: 8,
            offset: Offset(0, 2),
          ),
          BoxShadow(color: Color(0x40E8C547), blurRadius: 14),
        ],
      ),
      alignment: Alignment.center,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          // Web uses a ★ glyph at base font-size (9px) — no upscale.
          Text(
            '★',
            style: TextStyle(
              color: Colors.black,
              fontSize: widget.fontSize,
              height: 1.0,
            ),
          ),
          // .vipRide__badge: gap:1px.
          const SizedBox(width: 1),
          Text(
            'PREMIUM',
            style: TextStyle(
              fontFamily: 'Poppins',
              color: Colors.black,
              fontSize: widget.fontSize,
              fontWeight: FontWeight.w800,
              letterSpacing: 0.72,
              height: 1.0,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildComfort() {
    return Container(
      width: widget.width,
      height: widget.height,
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFFE8E8E8), Color(0xFFB0B0B0)],
        ),
        borderRadius: BorderRadius.circular(6),
        boxShadow: const [
          BoxShadow(
            color: Color(0x4DC0C0C0),
            blurRadius: 8,
            offset: Offset(0, 2),
          ),
          BoxShadow(color: Color(0x26C8C8C8), blurRadius: 12),
        ],
      ),
      alignment: Alignment.center,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          // Web uses .vipRide__badgeIcon--lg on comfort: font-size 2.3em
          // (≈20.7px at 9px base), line-height 1, translateY(-1.5px).
          Transform.translate(
            offset: const Offset(0, -1.5),
            child: Text(
              '✦',
              style: TextStyle(
                color: const Color(0xFF1A1A1A),
                fontSize: widget.fontSize * 2.3,
                height: 1.0,
              ),
            ),
          ),
          const SizedBox(width: 1),
          Text(
            'COMFORT',
            style: TextStyle(
              fontFamily: 'Poppins',
              color: const Color(0xFF1A1A1A),
              fontSize: widget.fontSize,
              fontWeight: FontWeight.w800,
              letterSpacing: 0.72,
              height: 1.0,
            ),
          ),
        ],
      ),
    );
  }
}

/// Crown icon with 3 sparkles that twinkle in sequence (0ms / 800ms /
/// 1600ms delays on a 2.4s loop). Matches the VIP badge SVG from the
/// Shopify widget.
class _VipCrownPainter extends CustomPainter {
  final Animation<double> twinkle;
  _VipCrownPainter({required this.twinkle}) : super(repaint: twinkle);

  double _sparkleScale(double t, double delay) {
    // t ∈ [0,1] on a 2.4s loop. Sparkle animates like vrTw:
    //   0 & 1 → opacity .3, scale .7
    //   0.5 → opacity 1, scale 1.15
    // We shift the phase by `delay` (fraction of total loop: 0, 1/3, 2/3).
    double phase = (t + delay) % 1.0;
    // Tri-wave for scale 0.7 → 1.15 → 0.7
    double tri = 1 - (phase - 0.5).abs() * 2; // 0 → 1 → 0
    return 0.7 + 0.45 * tri;
  }

  double _sparkleOpacity(double t, double delay) {
    double phase = (t + delay) % 1.0;
    double tri = 1 - (phase - 0.5).abs() * 2;
    return 0.3 + 0.7 * tri;
  }

  @override
  void paint(Canvas canvas, Size size) {
    final gold = const Color(0xFFE8C547);
    final strokePaint = Paint()
      ..color = gold
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    // Normalize 28×28 viewBox to this size. The original SVG draws a
    // simple crown in the top two-thirds; we redraw a cleaner crown
    // that reads better at ~13px.
    final w = size.width;
    final h = size.height;
    // Crown silhouette (tight and clean, not too tall)
    final crown = Path()
      ..moveTo(w * 0.15, h * 0.55)
      ..lineTo(w * 0.25, h * 0.30)
      ..lineTo(w * 0.40, h * 0.48)
      ..lineTo(w * 0.50, h * 0.22)
      ..lineTo(w * 0.60, h * 0.48)
      ..lineTo(w * 0.75, h * 0.30)
      ..lineTo(w * 0.85, h * 0.55)
      ..lineTo(w * 0.78, h * 0.72)
      ..lineTo(w * 0.22, h * 0.72)
      ..close();
    canvas.drawPath(crown, strokePaint);

    // Base line
    canvas.drawLine(
      Offset(w * 0.22, h * 0.78),
      Offset(w * 0.78, h * 0.78),
      strokePaint,
    );

    // 3 sparkles, twinkling in sequence
    final t = twinkle.value;
    final sparkles = [
      (Offset(w * 0.12, h * 0.14), 0.0),
      (Offset(w * 0.88, h * 0.18), 1 / 3),
      (Offset(w * 0.16, h * 0.88), 2 / 3),
    ];
    for (final (pos, delay) in sparkles) {
      final scale = _sparkleScale(t, delay);
      final op = _sparkleOpacity(t, delay);
      final paint = Paint()
        ..color = gold.withValues(alpha: op)
        ..style = PaintingStyle.fill;
      final r = 1.2 * scale;
      _drawSparkle(canvas, pos, r, paint);
    }
  }

  void _drawSparkle(Canvas canvas, Offset c, double r, Paint paint) {
    // 4-pointed sparkle (star)
    final p = Path()
      ..moveTo(c.dx, c.dy - r * 1.4)
      ..lineTo(c.dx + r * 0.4, c.dy - r * 0.4)
      ..lineTo(c.dx + r * 1.4, c.dy)
      ..lineTo(c.dx + r * 0.4, c.dy + r * 0.4)
      ..lineTo(c.dx, c.dy + r * 1.4)
      ..lineTo(c.dx - r * 0.4, c.dy + r * 0.4)
      ..lineTo(c.dx - r * 1.4, c.dy)
      ..lineTo(c.dx - r * 0.4, c.dy - r * 0.4)
      ..close();
    canvas.drawPath(p, paint);
  }

  @override
  bool shouldRepaint(covariant _VipCrownPainter old) => old.twinkle != twinkle;
}

