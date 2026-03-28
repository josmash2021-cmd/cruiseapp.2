import 'package:flutter/material.dart';
import '../user_profile_photo.dart';

const _defaultGold = Color(0xFFD4A843);

/// Clean circular profile avatar with 3D gold shadow fade and optional
/// verification badge.  Drop-in replacement for the old sawtooth
/// [VerifiedAvatar].
///
/// Works at any [size] — from 32 px (chat) to 120 px (profile).
class ProfileAvatar extends StatelessWidget {
  /// Network URL for the photo (Firebase Storage, etc.).
  final String? imageUrl;

  /// Local file path (fallback if [imageUrl] is null/empty).
  final String? imagePath;

  /// User name — used to derive initials when no photo is available.
  final String? name;

  /// Diameter of the avatar circle.  Default 56 px.
  final double size;

  /// Whether to show the bottom-right verified badge.
  final bool isVerified;

  /// Override for the glow / shadow colour (defaults to gold).
  final Color? borderColor;

  /// User UID — When provided with role, enables recovery chain for photo persistence.
  /// Prevents cross-account photo contamination.
  final String? uid;

  /// User role — Should be provided with uid ('rider' or 'driver').
  /// Ensures rider and driver photos never mix.
  final String? role;

  const ProfileAvatar({
    super.key,
    this.imageUrl,
    this.imagePath,
    this.name,
    this.size = 56,
    this.isVerified = false,
    this.borderColor,
    this.uid,
    this.role,
  });

  @override
  Widget build(BuildContext context) {
    final glow = borderColor ?? _defaultGold;
    final badgeD = (size * 0.32).clamp(14.0, 28.0);

    return SizedBox(
      width: size + 8, // room for outer shadow
      height: size + 8,
      child: Stack(
        clipBehavior: Clip.none,
        alignment: Alignment.center,
        children: [
          // ── Circle + 3-layer gold shadow ──
          Container(
            width: size,
            height: size,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(color: glow.withValues(alpha: 0.6), width: 1.5),
              boxShadow: [
                BoxShadow(
                  color: glow.withValues(alpha: 0.6),
                  blurRadius: 4,
                  spreadRadius: 1,
                ),
                BoxShadow(
                  color: glow.withValues(alpha: 0.3),
                  blurRadius: 8,
                  spreadRadius: 2,
                ),
                BoxShadow(
                  color: glow.withValues(alpha: 0.1),
                  blurRadius: 16,
                  spreadRadius: 4,
                ),
              ],
            ),
            child: ClipOval(
              child: UserProfilePhoto(
                photoUrl: imageUrl,
                photoPath: imagePath,
                radius: size / 2,
                fallbackName: name,
                uid: uid,
                role: role,
                noBorder: true,
              ),
            ),
          ),

          // ── Verified badge (bottom-right) ──
          if (isVerified)
            Positioned(
              bottom: (size + 8 - size) / 2 - 2, // accounts for parent SizedBox offset
              right: (size + 8 - size) / 2 - 2,
              child: Container(
                width: badgeD,
                height: badgeD,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: glow,
                  border: Border.all(
                    color: const Color(0xFF0A0A0A),
                    width: 2,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.4),
                      blurRadius: 3,
                      offset: const Offset(0, 1),
                    ),
                  ],
                ),
                child: Icon(
                  Icons.check_rounded,
                  color: Colors.white,
                  size: badgeD * 0.6,
                ),
              ),
            ),
        ],
      ),
    );
  }
}
