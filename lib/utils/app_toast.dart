import 'package:flutter/material.dart';

import '../widgets/glass_notification_banner.dart';

/// Legacy top toast — now a thin alias of [GlassNotificationBanner] (owner
/// spec 2026-11-01: every in-app notification is the one glass banner at
/// the top, 7 s, slide up + fade out, swipe up to dismiss). Kept so older
/// call sites keep compiling; new code calls [GlassNotificationBanner.show].
class AppToast {
  static void show(
    BuildContext context,
    String message, {
    // The old solid-colour pill styling is gone: the banner is always the
    // dark glass. [backgroundColor] tints the icon ring instead.
    Color backgroundColor = kGlassBannerGold,
    Color textColor = Colors.white,
    IconData? icon,
    Duration duration = kGlassBannerDuration,
  }) {
    GlassNotificationBanner.show(
      context: context,
      title: message,
      icon: icon ?? Icons.notifications_rounded,
      accent: backgroundColor,
      duration: duration,
    );
  }

  static void success(BuildContext context, String message) => show(
        context,
        message,
        icon: Icons.check_circle_outline_rounded,
      );

  static void error(BuildContext context, String message) => show(
        context,
        message,
        backgroundColor: const Color(0xFFFF5252),
        icon: Icons.error_outline_rounded,
      );
}
