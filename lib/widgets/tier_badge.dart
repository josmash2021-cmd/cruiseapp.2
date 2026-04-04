import 'dart:math' as math;
import 'package:flutter/material.dart';

/// Tier color/label info derived from ride name.
class TierInfo {
  final Color color;
  final Color highlight;
  final String label;
  final IconData icon;
  final bool isGold;
  final bool isSilver;
  final bool isGreen;

  const TierInfo._({
    required this.color,
    required this.highlight,
    required this.label,
    required this.icon,
    required this.isGold,
    required this.isSilver,
    required this.isGreen,
  });

  /// Resolve tier from ride/vehicle name (case-insensitive).
  factory TierInfo.from(String rideName) {
    final n = rideName.toLowerCase();
    if (n.contains('vip') || n.contains('suv') || n.contains('suburban')) {
      return const TierInfo._(
        color: Color(0xFFE8C547),
        highlight: Color(0xFFFFF4A0),
        label: 'VIP',
        icon: Icons.star_rounded,
        isGold: true,
        isSilver: false,
        isGreen: false,
      );
    }
    if (n.contains('premium') || n.contains('camry') || n.contains('comfort')) {
      return const TierInfo._(
        color: Color(0xFFB8BCC8),
        highlight: Color(0xFFFFFFFF),
        label: 'PREMIUM',
        icon: Icons.auto_awesome_rounded,
        isGold: false,
        isSilver: true,
        isGreen: false,
      );
    }
    return const TierInfo._(
      color: Color(0xFF43A047),
      highlight: Color(0xFFA5D6A7),
      label: 'COMFORT',
      icon: Icons.savings_rounded,
      isGold: false,
      isSilver: false,
      isGreen: true,
    );
  }

  /// Gradient colors for the amount card on receipts.
  List<Color> get gradient {
    if (isGold) return const [Color(0xFFE8C547), Color(0xFFF5D990)];
    if (isSilver) return const [Color(0xFF8E93A0), Color(0xFFB8BCC8)];
    return const [Color(0xFF2E7D32), Color(0xFF43A047)];
  }
}

/// Animated shimmer badge for VIP / Premium / Comfort tiers.
class TierBadge extends StatefulWidget {
  final String rideName;
  final double fontSize;
  final double iconSize;

  const TierBadge({
    super.key,
    required this.rideName,
    this.fontSize = 9,
    this.iconSize = 11,
  });

  @override
  State<TierBadge> createState() => _TierBadgeState();
}

class _TierBadgeState extends State<TierBadge>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2000),
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tier = TierInfo.from(widget.rideName);

    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        final p = _controller.value;

        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: [
                _shimmerColor(tier, p, 0.0),
                _shimmerColor(tier, p, 0.5),
                _shimmerColor(tier, p, 1.0),
              ],
            ),
            borderRadius: BorderRadius.circular(6),
            boxShadow: [
              BoxShadow(
                color: tier.color.withValues(
                  alpha: 0.3 + 0.2 * math.sin(p * math.pi * 2),
                ),
                blurRadius: 8 + 4 * math.sin(p * math.pi * 2),
                offset: const Offset(0, 2),
              ),
            ],
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Transform.scale(
                scale: 0.8 + 0.2 * math.sin(
                  p * math.pi * (tier.isGreen ? 2 : 3),
                ),
                child: Icon(
                  tier.icon,
                  size: widget.iconSize,
                  color: Colors.white.withValues(alpha: 0.95),
                ),
              ),
              const SizedBox(width: 4),
              Text(
                tier.label,
                style: TextStyle(
                  fontSize: widget.fontSize,
                  fontWeight: FontWeight.w900,
                  color: Colors.white,
                  letterSpacing: 0.8,
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Color _shimmerColor(TierInfo tier, double progress, double position) {
    final shimmerPos = (progress * 2 + position) % 2;
    final intensity = shimmerPos < 0.5
        ? shimmerPos * 2
        : (1 - shimmerPos) * 2;
    return Color.lerp(tier.color, tier.highlight, intensity * 0.65)!;
  }
}
