import 'package:flutter/material.dart';
import 'user_profile_photo.dart';

/// Gold verified badge overlaid bottom-right on any profile photo circle.
///
/// Wraps [UserProfilePhoto] in a [Stack] with a gold-bordered blue-check badge
/// that appears only when [isVerified] is true.
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
    final badgeSize = radius * 0.75;
    final iconSize = radius * 0.42;

    return SizedBox(
      width: radius * 2 + 8,
      height: radius * 2 + 8,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Positioned(
            top: 0,
            left: 0,
            child: Container(
              width: radius * 2,
              height: radius * 2,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(
                  color: const Color(0xFFFFD700),
                  width: 2.5,
                ),
              ),
              child: ClipOval(
                child: UserProfilePhoto(
                  photoUrl: photoUrl,
                  photoPath: photoPath,
                  radius: radius - 2.5,
                  fallbackName: fallbackName,
                  uid: uid,
                  noBorder: true,
                ),
              ),
            ),
          ),
          if (isVerified)
            Positioned(
              bottom: 0,
              right: 0,
              child: Container(
                width: badgeSize,
                height: badgeSize,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: const Color(0xFF1A1A1A),
                  border: Border.all(
                    color: const Color(0xFFFFD700),
                    width: 2.0,
                  ),
                ),
                child: Center(
                  child: Icon(
                    Icons.check_rounded,
                    color: const Color(0xFF1DA1F2),
                    size: iconSize,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
