import 'package:flutter/material.dart';

import '../services/api_service.dart';

/// Onboarding photo (dress code + selfie verification): backend-hosted
/// /static FIRST, so phones whose OTA patch delivered only Dart still get
/// the real photos even when the bundled asset is missing (new assets never
/// ride Shorebird patches — proven on device 2026-10-23). The bundled asset
/// is the offline fallback, and a dignified gold icon is the last resort if
/// both fail. ONE source for the onboarding image slots.
class OnboardingImage extends StatelessWidget {
  const OnboardingImage({
    super.key,
    required this.filename,
    this.fit = BoxFit.cover,
    this.height,
    this.fallbackIcon = Icons.person_outline_rounded,
  });

  /// e.g. `guide_selfie_vip_m.png` / `guide_dress_std_f.png`.
  final String filename;
  final BoxFit fit;
  final double? height;
  final IconData fallbackIcon;

  @override
  Widget build(BuildContext context) {
    final url = '${ApiService.publicBaseUrl}/static/onboarding/$filename';
    return Image.network(
      url,
      fit: fit,
      height: height,
      errorBuilder: (context, error, stackTrace) => Image.asset(
        'assets/images/onboarding/$filename',
        fit: fit,
        height: height,
        errorBuilder: (context, error, stackTrace) => Center(
          child: Icon(fallbackIcon, color: const Color(0xFFE8C547), size: 72),
        ),
      ),
    );
  }
}
