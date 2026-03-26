import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'user_profile_photo.dart';

const _gold = Color(0xFFD4A843);

/// Verified avatar with sawtooth/triangle crown border and optional badge.
class VerifiedAvatar extends StatelessWidget {
  final String? photoUrl;
  final String? photoPath;
  final double radius;
  final String? fallbackName;
  final String? uid;
  final bool isVerified;

  const VerifiedAvatar({
    super.key,
    this.photoUrl,
    this.photoPath,
    required this.radius,
    this.fallbackName,
    this.uid,
    this.isVerified = false,
  });

  @override
  Widget build(BuildContext context) {
    // Tooth height scales with avatar size (4-6px range)
    final toothH = (radius * 0.12).clamp(3.5, 6.0);
    final outerR = radius + toothH + 1;
    final totalSize = outerR * 2;
    final badgeD = (radius * 0.55).clamp(18.0, 26.0);

    return SizedBox(
      width: totalSize + badgeD * 0.3,
      height: totalSize + badgeD * 0.3,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          // Sawtooth ring + photo
          Positioned(
            top: 0,
            left: 0,
            child: CustomPaint(
              painter: _SawtoothBorderPainter(
                innerRadius: radius,
                toothHeight: toothH,
                color: _gold,
              ),
              child: SizedBox(
                width: outerR * 2,
                height: outerR * 2,
                child: Center(
                  child: ClipOval(
                    child: SizedBox(
                      width: radius * 2 - 2,
                      height: radius * 2 - 2,
                      child: UserProfilePhoto(
                        photoUrl: photoUrl,
                        photoPath: photoPath,
                        radius: radius - 1,
                        fallbackName: fallbackName,
                        uid: uid,
                        noBorder: true,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),

          // Verified badge with mini sawtooth border
          if (isVerified)
            Positioned(
              bottom: 0,
              right: 0,
              child: _VerifiedBadge(diameter: badgeD),
            ),
        ],
      ),
    );
  }
}

/// Badge circle with its own mini sawtooth ring + checkmark.
class _VerifiedBadge extends StatelessWidget {
  final double diameter;
  const _VerifiedBadge({required this.diameter});

  @override
  Widget build(BuildContext context) {
    final innerR = diameter / 2 - 2;
    final toothH = (innerR * 0.18).clamp(1.5, 3.0);
    final outerR = innerR + toothH + 0.5;
    final full = outerR * 2;

    return Container(
      width: full,
      height: full,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.45),
            blurRadius: 4,
            offset: const Offset(0, 1),
          ),
        ],
      ),
      child: CustomPaint(
        painter: _SawtoothBorderPainter(
          innerRadius: innerR,
          toothHeight: toothH,
          color: _gold,
          fillCenter: true,
        ),
        child: SizedBox(
          width: full,
          height: full,
          child: Icon(
            Icons.check_rounded,
            color: const Color(0xFF0A0A0A),
            size: innerR * 1.15,
          ),
        ),
      ),
    );
  }
}

/// Draws a circular sawtooth / crown border around a circle.
class _SawtoothBorderPainter extends CustomPainter {
  final double innerRadius;
  final double toothHeight;
  final Color color;
  final bool fillCenter;

  _SawtoothBorderPainter({
    required this.innerRadius,
    required this.toothHeight,
    required this.color,
    this.fillCenter = false,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final cx = size.width / 2;
    final cy = size.height / 2;
    final outerR = innerRadius + toothHeight;

    // Number of teeth scales with circumference
    final teeth = (innerRadius * 0.65).round().clamp(12, 48);
    final step = (2 * math.pi) / teeth;

    final path = Path();
    for (int i = 0; i < teeth; i++) {
      final a0 = step * i - math.pi / 2;
      final aMid = a0 + step / 2;
      final a1 = a0 + step;

      final x0 = cx + innerRadius * math.cos(a0);
      final y0 = cy + innerRadius * math.sin(a0);
      final xT = cx + outerR * math.cos(aMid);
      final yT = cy + outerR * math.sin(aMid);
      final x1 = cx + innerRadius * math.cos(a1);
      final y1 = cy + innerRadius * math.sin(a1);

      if (i == 0) {
        path.moveTo(x0, y0);
      }
      path.lineTo(xT, yT);
      path.lineTo(x1, y1);
    }
    path.close();

    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.fill
      ..isAntiAlias = true;

    canvas.drawPath(path, paint);

    if (fillCenter) {
      canvas.drawCircle(
        Offset(cx, cy),
        innerRadius,
        Paint()
          ..color = color
          ..style = PaintingStyle.fill,
      );
    }
  }

  @override
  bool shouldRepaint(_SawtoothBorderPainter old) =>
      old.innerRadius != innerRadius ||
      old.toothHeight != toothHeight ||
      old.color != color ||
      old.fillCenter != fillCenter;
}
