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

  /// Optional fade-in duration forwarded to [ProfileAvatar].
  /// Null keeps the default behavior for all existing callers.
  final Duration? fadeInDuration;

  const VerifiedAvatar({
    super.key,
    this.photoUrl,
    this.photoPath,
    required this.radius,
    this.fallbackName,
    this.uid,
    this.role,
    this.isVerified = false,
    this.fadeInDuration,
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
      fadeInDuration: fadeInDuration,
    );
  }
}
