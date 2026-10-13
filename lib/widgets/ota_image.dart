import 'package:flutter/material.dart';

import '../services/api_service.dart';

/// The network rung of the OTA image chain (user spec 2026-10-13: "que por
/// OTA funcionen las fotos"). Shorebird patches carry no NEW assets — a
/// PNG shipped today exists only in store builds — so when the bundled
/// copy errors, the backend-hosted twin at `/static/<fileName>` streams
/// in (deployed with the backend, no store release needed). Same pattern
/// as maintenance_hero.png. [fallback] is the offline last resort.
Widget otaImageFallback(
  String fileName,
  Widget fallback, {
  double? width,
  double? height,
  BoxFit fit = BoxFit.contain,
  AlignmentGeometry alignment = Alignment.center,
}) {
  return Image.network(
    '${ApiService.currentBaseUrl}/static/$fileName',
    width: width,
    height: height,
    fit: fit,
    alignment: alignment,
    errorBuilder: (_, __, ___) => fallback,
  );
}
