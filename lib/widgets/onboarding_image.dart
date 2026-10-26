import 'package:flutter/material.dart';

import '../services/api_service.dart';

/// The bundled asset is immediate and needs no network. Older releases
/// without that asset fall back to the backend copy; a gold icon is the last
/// resort. [localPath] and [remoteUrl] also cover artwork outside onboarding.
class OnboardingImage extends StatelessWidget {
  const OnboardingImage({
    super.key,
    required this.filename,
    this.fit = BoxFit.cover,
    this.height,
    this.width,
    this.localPath,
    this.remoteUrl,
    this.fallbackIcon = Icons.person_outline_rounded,
  });

  /// e.g. `guide_selfie_vip_m.png` / `guide_dress_std_f.png`.
  final String filename;
  final BoxFit fit;
  final double? height;
  final double? width;
  final String? localPath;
  final String? remoteUrl;
  final IconData fallbackIcon;

  static String assetPath(String filename) =>
      'assets/images/onboarding/$filename';

  static String networkUrl(String filename) =>
      '${ApiService.publicBaseUrl}/static/onboarding/$filename';

  static Future<void> preload(
    BuildContext context,
    String filename, {
    String? localPath,
    String? remoteUrl,
  }) async {
    final path = localPath ?? assetPath(filename);
    try {
      await precacheImage(AssetImage(path), context);
      return;
    } catch (error) {
      debugPrint('[OnboardingImage] asset preload FAILED $path -> $error');
    }
    if (!context.mounted) return;
    final url = remoteUrl ?? networkUrl(filename);
    try {
      await precacheImage(NetworkImage(url), context);
    } catch (error) {
      debugPrint('[OnboardingImage] network preload FAILED $url -> $error');
    }
  }

  @override
  Widget build(BuildContext context) {
    final path = localPath ?? assetPath(filename);
    return Image.asset(
      path,
      fit: fit,
      height: height,
      width: width,
      gaplessPlayback: true,
      errorBuilder: (context, error, stackTrace) {
        final url = remoteUrl ?? networkUrl(filename);
        debugPrint('[OnboardingImage] asset FAILED $path -> $error');
        return Image.network(
          url,
          fit: fit,
          height: height,
          width: width,
          gaplessPlayback: true,
          errorBuilder: (context, error, stackTrace) {
            debugPrint('[OnboardingImage] network FAILED $url -> $error');
            return Center(
              child:
                  Icon(fallbackIcon, color: const Color(0xFFE8C547), size: 72),
            );
          },
        );
      },
    );
  }
}
