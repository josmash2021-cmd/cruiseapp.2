import 'package:flutter/material.dart';
import 'user_profile_photo.dart';

/// Gold verified badge overlaid bottom-right on any profile photo circle.
///
/// Wraps [UserProfilePhoto] in a [Stack] with a gold check badge
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
    final badgeSize = radius * 0.72;
    final iconSize = radius * 0.42;

    return Stack(
      clipBehavior: Clip.none,
      children: [
        UserProfilePhoto(
          photoUrl: photoUrl,
          photoPath: photoPath,
          radius: radius,
          fallbackName: fallbackName,
          uid: uid,
        ),
        if (isVerified)
          Positioned(
            bottom: -1,
            right: -1,
            child: Container(
              width: badgeSize,
              height: badgeSize,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: const Color(0xFFFFD700),
                border: Border.all(
                  color: Theme.of(context).scaffoldBackgroundColor,
                  width: 2,
                ),
              ),
              child: Icon(
                Icons.check,
                color: Colors.black,
                size: iconSize,
              ),
            ),
          ),
      ],
    );
  }
}
