import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import '../services/photo_recovery_service.dart';

/// Robust profile photo widget that loads from URL first (cross-device),
/// falls back to local file, and shows gold initials as last resort.
///
/// Uses 4-source recovery chain to find photos:
///   1. Local SharedPreferences cache (fastest)
///   2. Firebase Auth photoURL
///   3. Firestore users doc
///   4. Firebase Storage direct
///
/// Priority order for display:
/// 1. [photoUrl] — CachedNetworkImage from Firebase Storage URL
/// 2. Recovered URL from 4-source chain (if uid provided)
/// 3. [photoPath] — Local file (fast, already downloaded)
/// 4. Gold initials derived from [fallbackName]
class UserProfilePhoto extends StatefulWidget {
  final String? photoUrl;
  final String? photoPath;
  final double radius;
  final String? fallbackName;
  /// User ID used as cache key — ensures photos never leak between accounts.
  /// When provided, triggers 4-source recovery chain on init.
  final String? uid;

  /// When true, skips the outer CircleAvatar wrapper (used inside VerifiedAvatar
  /// which provides its own border).
  final bool noBorder;

  /// Custom cache manager with 30-day stale period for profile photos.
  static final _cacheManager = CacheManager(
    Config(
      'cruiseProfilePhotos',
      stalePeriod: const Duration(days: 30),
      maxNrOfCacheObjects: 100,
    ),
  );

  /// Clear all cached profile photos — call on logout.
  static Future<void> clearCache() async {
    await _cacheManager.emptyCache();
  }

  const UserProfilePhoto({
    super.key,
    this.photoUrl,
    this.photoPath,
    this.radius = 24,
    this.fallbackName,
    this.uid,
    this.noBorder = false,
  });

  @override
  State<UserProfilePhoto> createState() => _UserProfilePhotoState();
}

class _UserProfilePhotoState extends State<UserProfilePhoto> {
  String? _recoveredPhotoUrl;
  bool _recoveryAttempted = false;

  @override
  void initState() {
    super.initState();
    // If uid is provided and no explicit photoUrl, attempt recovery chain
    if (widget.uid != null && (widget.photoUrl == null || widget.photoUrl!.isEmpty)) {
      _attemptPhotoRecovery();
    }
  }

  Future<void> _attemptPhotoRecovery() async {
    if (_recoveryAttempted || widget.uid == null) return;
    _recoveryAttempted = true;

    try {
      final recovered = await PhotoRecoveryService.resolvePhotoUrl(widget.uid!);
      if (mounted && recovered != null && recovered.isNotEmpty) {
        setState(() => _recoveredPhotoUrl = recovered);
      }
    } catch (e) {
      debugPrint('[UserProfilePhoto] Recovery failed: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.noBorder) {
      return SizedBox(
        width: widget.radius * 2,
        height: widget.radius * 2,
        child: _buildContent(),
      );
    }
    return CircleAvatar(
      radius: widget.radius,
      backgroundColor: const Color(0xFF1A1A1A),
      child: ClipOval(
        child: SizedBox(
          width: widget.radius * 2,
          height: widget.radius * 2,
          child: _buildContent(),
        ),
      ),
    );
  }

  Widget _buildContent() {
    // 1. Explicit photoUrl takes priority
    final urlToUse = (widget.photoUrl != null && widget.photoUrl!.isNotEmpty)
        ? widget.photoUrl
        : _recoveredPhotoUrl;

    if (urlToUse != null && urlToUse.isNotEmpty && urlToUse.startsWith('http')) {
      return CachedNetworkImage(
        imageUrl: urlToUse,
        cacheKey: widget.uid != null ? 'photo_${widget.uid}' : null,
        width: widget.radius * 2,
        height: widget.radius * 2,
        fit: BoxFit.cover,
        cacheManager: UserProfilePhoto._cacheManager,
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
        widget.photoPath != null &&
        widget.photoPath!.isNotEmpty &&
        !widget.photoPath!.startsWith('http')) {
      final file = File(widget.photoPath!);
      if (file.existsSync()) {
        return Image.file(
          file,
          fit: BoxFit.cover,
          width: widget.radius * 2,
          height: widget.radius * 2,
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
      width: widget.radius * 2,
      height: widget.radius * 2,
      color: const Color(0xFF1A1A1A),
      child: Center(
        child: Text(
          text,
          style: TextStyle(
            color: const Color(0xFFFFD700),
            fontSize: widget.radius * 0.75,
            fontWeight: FontWeight.bold,
          ),
        ),
      ),
    );
  }

  String _deriveInitials() {
    if (widget.fallbackName == null || widget.fallbackName!.trim().isEmpty) return '?';
    return widget.fallbackName!
        .trim()
        .split(' ')
        .where((w) => w.isNotEmpty)
        .map((w) => w[0].toUpperCase())
        .take(2)
        .join();
  }
}
