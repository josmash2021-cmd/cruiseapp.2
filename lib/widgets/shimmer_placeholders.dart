import 'package:flutter/material.dart';

// ─────────────────────────────────────────────────────────────────────────────
//  Shimmer base — lightweight animated gradient sweep (no external package)
// ─────────────────────────────────────────────────────────────────────────────
class ShimmerBox extends StatefulWidget {
  final double width;
  final double height;
  final double borderRadius;
  final BoxShape shape;

  const ShimmerBox({
    super.key,
    required this.width,
    required this.height,
    this.borderRadius = 8,
    this.shape = BoxShape.rectangle,
  });

  @override
  State<ShimmerBox> createState() => _ShimmerBoxState();
}

class _ShimmerBoxState extends State<ShimmerBox>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    )..repeat();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _ctrl,
      builder: (_, __) {
        return Container(
          width: widget.width,
          height: widget.height,
          decoration: BoxDecoration(
            shape: widget.shape,
            borderRadius: widget.shape == BoxShape.circle
                ? null
                : BorderRadius.circular(widget.borderRadius),
            gradient: LinearGradient(
              begin: Alignment(-1.0 + 2.0 * _ctrl.value, 0),
              end: Alignment(-0.4 + 2.0 * _ctrl.value, 0),
              colors: const [
                Color(0xFF1A1F35),
                Color(0xFF2A3045),
                Color(0xFF1A1F35),
              ],
            ),
          ),
        );
      },
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
//  Offer card shimmer — matches the shape of RideOfferCard
// ─────────────────────────────────────────────────────────────────────────────
class OfferCardShimmer extends StatelessWidget {
  const OfferCardShimmer({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF1A1F35),
        borderRadius: BorderRadius.circular(20),
      ),
      child: const Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Rider profile row
          Row(
            children: [
              ShimmerBox(width: 56, height: 56, shape: BoxShape.circle),
              SizedBox(width: 12),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  ShimmerBox(width: 120, height: 16),
                  SizedBox(height: 6),
                  ShimmerBox(width: 80, height: 12),
                ],
              ),
            ],
          ),
          SizedBox(height: 16),
          // Map placeholder
          ShimmerBox(width: double.infinity, height: 120, borderRadius: 12),
          SizedBox(height: 12),
          // Fare row
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              ShimmerBox(width: 80, height: 24),
              ShimmerBox(width: 60, height: 24),
            ],
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
//  Rider profile shimmer — avatar + name + rating
// ─────────────────────────────────────────────────────────────────────────────
class RiderProfileShimmer extends StatelessWidget {
  const RiderProfileShimmer({super.key});

  @override
  Widget build(BuildContext context) {
    return const Row(
      children: [
        ShimmerBox(width: 56, height: 56, shape: BoxShape.circle),
        SizedBox(width: 12),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ShimmerBox(width: 120, height: 16),
            SizedBox(height: 6),
            ShimmerBox(width: 80, height: 12),
          ],
        ),
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
//  Earnings card shimmer
// ─────────────────────────────────────────────────────────────────────────────
class EarningsShimmer extends StatelessWidget {
  const EarningsShimmer({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF1A1F35),
        borderRadius: BorderRadius.circular(16),
      ),
      child: const Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ShimmerBox(width: 100, height: 14),
          SizedBox(height: 8),
          ShimmerBox(width: 140, height: 32),
          SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              ShimmerBox(width: 70, height: 12),
              ShimmerBox(width: 50, height: 12),
            ],
          ),
        ],
      ),
    );
  }
}
