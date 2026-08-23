import 'package:flutter/material.dart';

import '../../../l10n/app_localizations.dart';

/// The six Lyft-style driver onboarding items (Phase 2).
///
/// The [key] matches the backend contract of
/// `GET /auth/onboarding-items` (`{"items": {"plate": {...}, ...}}`).
enum OnboardingItem {
  plate('plate', 'assets/images/onboarding/plate.jpg'),
  ssn('ssn', 'assets/images/onboarding/ssn.jpg'),
  license('license', 'assets/images/onboarding/license.jpg'),
  photo('photo', 'assets/images/onboarding/profile_photo.jpg'),
  background('background', 'assets/images/onboarding/background.jpg'),
  vehicle('vehicle', 'assets/images/onboarding/vehicle.jpg');

  const OnboardingItem(this.key, this.asset);

  /// Backend item key.
  final String key;

  /// Intro hero image (already bundled under assets/images/).
  final String asset;

  static OnboardingItem? fromKey(String key) {
    for (final item in values) {
      if (item.key == key) return item;
    }
    return null;
  }
}

/// Status of one onboarding item as reported by the backend.
enum OnboardingItemStatus { pending, submitted, approved, rejected }

/// One entry of the to-do hub: item + server status + rejection reason.
class OnboardingItemEntry {
  const OnboardingItemEntry({
    required this.item,
    required this.status,
    this.reason,
  });

  final OnboardingItem item;
  final OnboardingItemStatus status;
  final String? reason;

  bool get isCompleted =>
      status == OnboardingItemStatus.submitted ||
      status == OnboardingItemStatus.approved;

  static OnboardingItemEntry parse(String key, Map<String, dynamic>? json) {
    final item = OnboardingItem.fromKey(key) ?? OnboardingItem.values.first;
    final raw = (json?['status'] as String? ?? 'pending').toLowerCase();
    final status = OnboardingItemStatus.values.firstWhere(
      (s) => s.name == raw,
      orElse: () => OnboardingItemStatus.pending,
    );
    final reason = json?['reason'] as String?;
    return OnboardingItemEntry(
      item: item,
      status: status,
      reason: (reason != null && reason.isNotEmpty) ? reason : null,
    );
  }
}

/// Localized intro copy (title/subtitle/CTA) for each item — the exact
/// Lyft-style strings live in `app_localizations.dart`.
class OnboardingIntroCopy {
  const OnboardingIntroCopy({
    required this.title,
    required this.subtitle,
    required this.button,
  });

  final String title;
  final String subtitle;
  final String button;

  static OnboardingIntroCopy of(S s, OnboardingItem item) {
    switch (item) {
      case OnboardingItem.vehicle:
        return OnboardingIntroCopy(
          title: s.obIntroVehicleTitle,
          subtitle: s.obIntroVehicleSub,
          button: s.obIntroVehicleButton,
        );
      case OnboardingItem.plate:
        return OnboardingIntroCopy(
          title: s.obIntroPlateTitle,
          subtitle: s.obIntroPlateSub,
          button: s.next,
        );
      case OnboardingItem.ssn:
        return OnboardingIntroCopy(
          title: s.obIntroSsnTitle,
          subtitle: s.obIntroSsnSub,
          button: s.next,
        );
      case OnboardingItem.license:
        return OnboardingIntroCopy(
          title: s.obIntroLicenseTitle,
          subtitle: s.obIntroLicenseSub,
          button: s.next,
        );
      case OnboardingItem.photo:
        return OnboardingIntroCopy(
          title: s.obIntroPhotoTitle,
          subtitle: s.obIntroPhotoSub,
          button: s.next,
        );
      case OnboardingItem.background:
        return OnboardingIntroCopy(
          title: s.obIntroBackgroundTitle,
          subtitle: s.obIntroBackgroundSub,
          button: s.next,
        );
    }
  }
}

/// Hub card title/subtitle per item.
(String title, String subtitle) onboardingCardCopy(
  S s,
  OnboardingItem item,
) {
  switch (item) {
    case OnboardingItem.plate:
      return (s.obItemPlateTitle, s.obItemPlateSub);
    case OnboardingItem.ssn:
      return (s.obItemSsnTitle, s.obItemSsnSub);
    case OnboardingItem.license:
      return (s.obItemLicenseTitle, s.obItemLicenseSub);
    case OnboardingItem.photo:
      return (s.obItemPhotoTitle, s.obItemPhotoSub);
    case OnboardingItem.background:
      return (s.obItemBackgroundTitle, s.obItemBackgroundSub);
    case OnboardingItem.vehicle:
      return (s.obItemVehicleTitle, s.obItemVehicleSub);
  }
}

/// Gold icon per item for the hub cards.
IconData onboardingItemIcon(OnboardingItem item) {
  switch (item) {
    case OnboardingItem.plate:
      return Icons.pin_rounded;
    case OnboardingItem.ssn:
      return Icons.badge_outlined;
    case OnboardingItem.license:
      return Icons.credit_card_rounded;
    case OnboardingItem.photo:
      return Icons.account_circle_outlined;
    case OnboardingItem.background:
      return Icons.verified_user_outlined;
    case OnboardingItem.vehicle:
      return Icons.directions_car_filled_outlined;
  }
}
