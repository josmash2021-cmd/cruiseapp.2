const quoteTierIds = <String>{
  'standard',
  'compact',
  'electric_pro',
  'premium',
  'vip',
};

String canonicalRideTier(String? value) {
  switch ((value ?? '').trim().toLowerCase()) {
    case 'fusion':
    case 'comfort':
    case 'standard':
      return 'standard';
    case 'camry':
    case 'sedan':
    case 'compact':
      return 'compact';
    case 'electric_pro':
    case 'electric':
      return 'electric_pro';
    case 'suv_xl':
    case 'premium':
      return 'premium';
    case 'suburban':
    case 'black':
    case 'vip':
      return 'vip';
    default:
      return 'standard';
  }
}

class RideOption {
  final String id;
  final String name;
  final String description;
  final double priceEstimate;
  final int etaMinutes;
  final String icon;
  final int capacity;
  final double surgeMultiplier;
  final int? originalTotalCents;
  final int? promoTotalCents;
  final int discountPercent;
  final int discountAmountCents;
  final bool isFree;
  final double? freeMaxMiles;
  final String? freeIneligibleReason;
  final int scheduledSurchargeCents;
  final int airportFeeCents;
  final int meetGreetFeeCents;

  const RideOption({
    required this.id,
    required this.name,
    required this.description,
    required this.priceEstimate,
    required this.etaMinutes,
    required this.icon,
    this.capacity = 4,
    this.surgeMultiplier = 1.0,
    this.originalTotalCents,
    this.promoTotalCents,
    this.discountPercent = 0,
    this.discountAmountCents = 0,
    this.isFree = false,
    this.freeMaxMiles,
    this.freeIneligibleReason,
    this.scheduledSurchargeCents = 0,
    this.airportFeeCents = 0,
    this.meetGreetFeeCents = 0,
  });

  factory RideOption.fromQuote(
    Map<String, dynamic> json, {
    required int durationMinutes,
  }) {
    final tier = json['tier']?.toString() ?? '';
    if (!quoteTierIds.contains(tier)) {
      throw FormatException('Unknown quote tier: $tier');
    }
    final original = (json['original_total_cents'] as num?)?.toInt();
    final promo = (json['promo_total_cents'] as num?)?.toInt();
    if (original == null || promo == null || original < 0 || promo < 0) {
      throw FormatException('Invalid quote totals for $tier');
    }
    final isFree = json['is_free'] == true && promo == 0;
    if (promo == 0 && !isFree) {
      throw const FormatException('A zero fare requires a free promotion');
    }
    final duration = durationMinutes < 1 ? 1 : durationMinutes;
    final surge = (json['surge_multiplier'] as num?)?.toDouble() ?? 1.0;
    switch (tier) {
      case 'vip':
        return RideOption(
          id: 'suburban',
          name: 'VIP',
          description: 'Spacious • Leather • Snacks & Drinks',
          priceEstimate: promo / 100.0,
          etaMinutes: duration + 3,
          icon: '🚐',
          capacity: 7,
          surgeMultiplier: surge,
          originalTotalCents: original,
          promoTotalCents: promo,
          discountPercent: (json['discount_percent'] as num?)?.toInt() ?? 0,
          discountAmountCents:
              (json['discount_amount_cents'] as num?)?.toInt() ?? 0,
          isFree: isFree,
          freeMaxMiles: (json['free_max_miles'] as num?)?.toDouble(),
          freeIneligibleReason: json['free_ineligible_reason']?.toString(),
          scheduledSurchargeCents:
              (json['scheduled_surcharge_cents'] as num?)?.toInt() ?? 0,
          airportFeeCents: (json['airport_fee_cents'] as num?)?.toInt() ?? 0,
          meetGreetFeeCents:
              (json['meet_greet_fee_cents'] as num?)?.toInt() ?? 0,
        );
      case 'premium':
        return RideOption(
          id: 'suv_xl',
          name: 'SUV XL',
          description: 'Up to 6 • XL luggage • Climate',
          priceEstimate: promo / 100.0,
          etaMinutes: duration + 2,
          icon: '🚙',
          capacity: 6,
          surgeMultiplier: surge,
          originalTotalCents: original,
          promoTotalCents: promo,
          discountPercent: (json['discount_percent'] as num?)?.toInt() ?? 0,
          discountAmountCents:
              (json['discount_amount_cents'] as num?)?.toInt() ?? 0,
          isFree: isFree,
          freeMaxMiles: (json['free_max_miles'] as num?)?.toDouble(),
          freeIneligibleReason: json['free_ineligible_reason']?.toString(),
          scheduledSurchargeCents:
              (json['scheduled_surcharge_cents'] as num?)?.toInt() ?? 0,
          airportFeeCents: (json['airport_fee_cents'] as num?)?.toInt() ?? 0,
          meetGreetFeeCents:
              (json['meet_greet_fee_cents'] as num?)?.toInt() ?? 0,
        );
      case 'electric_pro':
        return RideOption(
          id: 'electric_pro',
          name: 'Electric Pro',
          description: 'Electric • Zero emissions • Silent ride',
          priceEstimate: promo / 100.0,
          etaMinutes: duration + 2,
          icon: '⚡',
          capacity: 5,
          surgeMultiplier: surge,
          originalTotalCents: original,
          promoTotalCents: promo,
          discountPercent: (json['discount_percent'] as num?)?.toInt() ?? 0,
          discountAmountCents:
              (json['discount_amount_cents'] as num?)?.toInt() ?? 0,
          isFree: isFree,
          freeMaxMiles: (json['free_max_miles'] as num?)?.toDouble(),
          freeIneligibleReason: json['free_ineligible_reason']?.toString(),
          scheduledSurchargeCents:
              (json['scheduled_surcharge_cents'] as num?)?.toInt() ?? 0,
          airportFeeCents: (json['airport_fee_cents'] as num?)?.toInt() ?? 0,
          meetGreetFeeCents:
              (json['meet_greet_fee_cents'] as num?)?.toInt() ?? 0,
        );
      case 'compact':
        return RideOption(
          id: 'camry',
          name: 'Sedan',
          description: 'Comfort • Climate • Charger',
          priceEstimate: promo / 100.0,
          etaMinutes: duration + 2,
          icon: '🚙',
          capacity: 4,
          surgeMultiplier: surge,
          originalTotalCents: original,
          promoTotalCents: promo,
          discountPercent: (json['discount_percent'] as num?)?.toInt() ?? 0,
          discountAmountCents:
              (json['discount_amount_cents'] as num?)?.toInt() ?? 0,
          isFree: isFree,
          freeMaxMiles: (json['free_max_miles'] as num?)?.toDouble(),
          freeIneligibleReason: json['free_ineligible_reason']?.toString(),
          scheduledSurchargeCents:
              (json['scheduled_surcharge_cents'] as num?)?.toInt() ?? 0,
          airportFeeCents: (json['airport_fee_cents'] as num?)?.toInt() ?? 0,
          meetGreetFeeCents:
              (json['meet_greet_fee_cents'] as num?)?.toInt() ?? 0,
        );
      default:
        return RideOption(
          id: 'fusion',
          name: 'Comfort',
          description: 'Clean • Safe • Efficient',
          priceEstimate: promo / 100.0,
          etaMinutes: duration,
          icon: '🚗',
          capacity: 4,
          surgeMultiplier: surge,
          originalTotalCents: original,
          promoTotalCents: promo,
          discountPercent: (json['discount_percent'] as num?)?.toInt() ?? 0,
          discountAmountCents:
              (json['discount_amount_cents'] as num?)?.toInt() ?? 0,
          isFree: isFree,
          freeMaxMiles: (json['free_max_miles'] as num?)?.toDouble(),
          freeIneligibleReason: json['free_ineligible_reason']?.toString(),
          scheduledSurchargeCents:
              (json['scheduled_surcharge_cents'] as num?)?.toInt() ?? 0,
          airportFeeCents: (json['airport_fee_cents'] as num?)?.toInt() ?? 0,
          meetGreetFeeCents:
              (json['meet_greet_fee_cents'] as num?)?.toInt() ?? 0,
        );
    }
  }

  String get canonicalTier => canonicalRideTier(id);

  bool get hasServerPrice =>
      originalTotalCents != null &&
      promoTotalCents != null &&
      (promoTotalCents! > 0 || isFree);

  double get originalPriceEstimate =>
      (originalTotalCents ?? (priceEstimate * 100).round()) / 100.0;

  bool get hasPercentageDiscount =>
      hasServerPrice &&
      !isFree &&
      discountPercent > 0 &&
      originalTotalCents! > promoTotalCents!;
}

class RideQuote {
  final String id;
  final DateTime expiresAt;
  final int pricingVersion;
  final double distanceMiles;
  final int durationMinutes;
  final String routingSource;

  const RideQuote({
    required this.id,
    required this.expiresAt,
    required this.pricingVersion,
    required this.distanceMiles,
    required this.durationMinutes,
    required this.routingSource,
  });

  factory RideQuote.fromJson(Map<String, dynamic> json) {
    final id = json['quote_id']?.toString() ?? '';
    final expiresAt = DateTime.tryParse(json['expires_at']?.toString() ?? '');
    if (id.isEmpty || expiresAt == null) {
      throw const FormatException('Quote id and expiry are required');
    }
    return RideQuote(
      id: id,
      expiresAt: expiresAt,
      pricingVersion: (json['pricing_version'] as num?)?.toInt() ?? 0,
      distanceMiles: (json['distance_miles'] as num?)?.toDouble() ?? 0,
      durationMinutes: (json['duration_minutes'] as num?)?.toInt() ?? 0,
      routingSource: json['routing_source']?.toString() ?? '',
    );
  }

  bool expiresWithin(Duration window, {DateTime? now}) =>
      expiresAt.difference(now ?? DateTime.now()) <= window;
}

List<RideOption> rideOptionsFromQuote(Map<String, dynamic> json) {
  final quote = RideQuote.fromJson(json);
  final raw = json['quotes'];
  if (raw is! List) throw const FormatException('Quote tiers are required');
  return raw
      .map((item) => RideOption.fromQuote(
            Map<String, dynamic>.from(item as Map),
            durationMinutes: quote.durationMinutes,
          ))
      .toList();
}

int applicableCruiseCashCents({
  required RideOption option,
  required int balanceCents,
}) {
  if (!option.hasServerPrice || option.isFree) return 0;
  final available = balanceCents < 0 ? 0 : balanceCents;
  final capped = available > 5000 ? 5000 : available;
  final fare = option.promoTotalCents!;
  return capped > fare ? fare : capped;
}

int rideHoldAmountCents({
  required RideOption option,
  required int balanceCents,
}) {
  if (!option.hasServerPrice) {
    throw ArgumentError('A server quote is required before payment');
  }
  return option.promoTotalCents! -
      applicableCruiseCashCents(option: option, balanceCents: balanceCents);
}
