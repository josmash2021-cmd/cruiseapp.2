import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import 'glass_notification_banner.dart';

/// "New ride offer" heads-up — now the shared [GlassNotificationBanner]
/// (owner spec 2026-11-01: one glass banner for every in-app notification).
/// This is the NOTIFICATION, not the offer card the driver accepts from.
class OfferBanner {
  /// Show a "New Ride Offer" banner at the top of the screen.
  static void show(BuildContext context, {String? pickup, String? dropoff}) {
    GlassNotificationBanner.show(
      context: context,
      title: S.of(context).newRideOffer,
      body: pickup,
      icon: Icons.local_taxi_rounded,
    );
  }

  static void dismiss() => GlassNotificationBanner.dismiss();
}
