import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';

/// Robust profile photo widget that loads from URL first (cross-device),
/// falls back to local file, and shows gold initials as last resort.
///
/// Priority order:
/// 1. [photoUrl] — CachedNetworkImage from Firebase Storage URL
/// 2. [photoPath] — Local file (fast, already downloaded)
/// 3. Gold initials derived from [fallbackName]
class UserProfilePhoto extends StatelessWidget {
  final String? photoUrl;
  final String? photoPath;
  final double radius;
  final String? fallbackName;

  /// Custom cache manager with 30-day stale period for profile photos.
  static final _cacheManager = CacheManager(
    Config(
      'cruiseProfilePhotos',
      stalePeriod: const Duration(days: 30),
      maxNrOfCacheObjects: 100,
    ),
  );

  const UserProfilePhoto({
    super.key,
    this.photoUrl,
    this.photoPath,
    this.radius = 24,
    this.fallbackName,
  });

  @override
  Widget build(BuildContext context) {
    return CircleAvatar(
      radius: radius,
      backgroundColor: const Color(0xFF1A1A1A),
      child: ClipOval(
        child: SizedBox(
          width: radius * 2,
          height: radius * 2,
          child: _buildContent(),
        ),
      ),
    );
  }

  Widget _buildContent() {
    // 1. Network URL — works across devices
    if (photoUrl != null &&
        photoUrl!.isNotEmpty &&
        photoUrl!.startsWith('http')) {
      return CachedNetworkImage(
        imageUrl: photoUrl!,
        width: radius * 2,
        height: radius * 2,
        fit: BoxFit.cover,
        cacheManager: _cacheManager,
        placeholder: (_, __) => _localOrInitials(),
        errorWidget: (_, __, ___) => _localOrInitials(),
      );
    }

    // 2. Local file or initials
    return _localOrInitials();
  }

  /// Show local file if available, otherwise gold initials.
  Widget _localOrInitials() {
    if (!kIsWeb &&
        photoPath != null &&
        photoPath!.isNotEmpty &&
        !photoPath!.startsWith('http')) {
      final file = File(photoPath!);
      if (file.existsSync()) {
        return Image.file(
          file,
          fit: BoxFit.cover,
          width: radius * 2,
          height: radius * 2,
          gaplessPlayback: true,
          errorBuilder: (_, __, ___) => _initials(),
        );
      }
    }
    return _initials();
  }

  Widget _initials() {
    final text = _deriveInitials();
    return Container(
      width: radius * 2,
      height: radius * 2,
      color: const Color(0xFF1A1A1A),
      child: Center(
        child: Text(
          text,
          style: TextStyle(
            color: const Color(0xFFD4AF37),
            fontSize: radius * 0.7,
            fontWeight: FontWeight.bold,
          ),
        ),
      ),
    );
  }

  String _deriveInitials() {
    if (fallbackName == null || fallbackName!.trim().isEmpty) return '?';
    return fallbackName!
        .trim()
        .split(' ')
        .where((w) => w.isNotEmpty)
        .map((w) => w[0].toUpperCase())
        .take(2)
        .join();
  }
}
