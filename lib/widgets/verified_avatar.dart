import 'package:flutter/material.dart';
import 'user_profile_photo.dart';

/// Verified badge overlaid bottom-right on any profile photo circle.
///
/// Wraps [UserProfilePhoto] in a [Stack] with the Badge_verified.png asset
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
              child: Image.asset(
                'assets/images/Badge_verified.png',
                width: badgeSize,
                height: badgeSize,
                fit: BoxFit.contain,
                filterQuality: FilterQuality.high,
                isAntiAlias: true,
              ),
            ),
        ],
      ),
    );
  }
}
