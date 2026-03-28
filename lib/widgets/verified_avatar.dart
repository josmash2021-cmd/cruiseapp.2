import 'package:flutter/material.dart';
import 'common/profile_avatar.dart';

/// Verified avatar with clean circle, 3D gold shadow fade, and optional
/// verified badge at bottom-right.
///
/// This is a thin wrapper around [ProfileAvatar] that keeps the legacy
/// constructor signature so every call-site in the app continues to compile.
class VerifiedAvatar extends StatelessWidget {
  final String? photoUrl;
  final String? photoPath;
  final double radius;
  final String? fallbackName;
  final String? uid;
  /// User role ('rider' or 'driver'). When uid is provided, role should also be provided.
  /// Defaults to 'rider' if not specified.
  final String? role;
  final bool isVerified;

  const VerifiedAvatar({
    super.key,
    this.photoUrl,
    this.photoPath,
    required this.radius,
    this.fallbackName,
    this.uid,
    this.role,
    this.isVerified = false,
  });

  @override
  Widget build(BuildContext context) {
    return ProfileAvatar(
      imageUrl: photoUrl,
      imagePath: photoPath,
      name: fallbackName,
      size: radius * 2,
      isVerified: isVerified,
      uid: uid,
      role: role,
    );
  }
}
