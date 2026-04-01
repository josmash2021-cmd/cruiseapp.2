import 'lat_lng.dart';

/// A ride offer shown to the driver in the offers screen.
class RideOffer {
  final String offerId;
  final String riderName;
  final String pickupAddress;
  final String dropoffAddress;
  final LatLng pickupLatLng;
  final LatLng dropoffLatLng;
  final double fareUsd;
  final double distanceToPickupKm;
  final int estimatedMinutes;
  final String vehicleType;
  final String riderPhotoUrl;
  final double riderRating;
  final DateTime? createdAt;
  final int offerTimeoutSeconds;

  const RideOffer({
    required this.offerId,
    required this.riderName,
    required this.pickupAddress,
    required this.dropoffAddress,
    required this.pickupLatLng,
    required this.dropoffLatLng,
    required this.fareUsd,
    required this.distanceToPickupKm,
    required this.estimatedMinutes,
    required this.vehicleType,
    this.riderPhotoUrl = '',
    this.riderRating = 5.0,
    this.createdAt,
    this.offerTimeoutSeconds = 20,
  });

  /// Seconds remaining before this offer expires (0 if already expired).
  int get secondsRemaining {
    if (createdAt == null) return offerTimeoutSeconds;
    final elapsed = DateTime.now().difference(createdAt!).inSeconds;
    final remaining = offerTimeoutSeconds - elapsed;
    return remaining > 0 ? remaining : 0;
  }

  factory RideOffer.fromJson(Map<String, dynamic> json) {
    final riderObj = json['rider'];
    final riderMap = riderObj is Map ? riderObj : null;
    return RideOffer(
      offerId: json['offer_id']?.toString() ?? json['id']?.toString() ?? '',
      riderName: json['rider_name']?.toString() ??
          json['riderName']?.toString() ??
          riderMap?['name']?.toString() ??
          riderMap?['rider_name']?.toString() ??
          'Rider',
      pickupAddress: json['pickup_address']?.toString() ?? '',
      dropoffAddress: json['dropoff_address']?.toString() ?? '',
      pickupLatLng: LatLng(
        (json['pickup_lat'] as num?)?.toDouble() ?? 0,
        (json['pickup_lng'] as num?)?.toDouble() ?? 0,
      ),
      dropoffLatLng: LatLng(
        (json['dropoff_lat'] as num?)?.toDouble() ?? 0,
        (json['dropoff_lng'] as num?)?.toDouble() ?? 0,
      ),
      fareUsd: (json['fare'] as num?)?.toDouble() ?? 0,
      distanceToPickupKm:
          (json['distance_to_pickup_km'] as num?)?.toDouble() ?? 0,
      estimatedMinutes: (json['estimated_minutes'] as num?)?.toInt() ?? 0,
      vehicleType: json['vehicle_type']?.toString() ?? 'Fusion',
        riderPhotoUrl: json['rider_photo_url']?.toString() ??
          json['riderPhotoUrl']?.toString() ??
          json['passenger_photo_url']?.toString() ??
          json['passengerPhotoUrl']?.toString() ??
          riderMap?['photo_url']?.toString() ??
          riderMap?['photoUrl']?.toString() ??
          '',
      riderRating: (json['rider_rating'] as num?)?.toDouble() ?? 5.0,
      createdAt: json['created_at'] != null
          ? DateTime.tryParse(json['created_at'].toString())
          : null,
      offerTimeoutSeconds: (json['offer_timeout_seconds'] as num?)?.toInt() ?? 20,
    );
  }
}

/// Represents an accepted offer with the trip details needed for navigation.
class AcceptedOffer {
  final String offerId;
  final LatLng pickupLatLng;
  final LatLng dropoffLatLng;
  final String riderName;
  final String riderPhotoUrl;
  final double riderRating;
  final String pickupAddress;
  final String dropoffAddress;

  const AcceptedOffer({
    required this.offerId,
    required this.pickupLatLng,
    required this.dropoffLatLng,
    required this.riderName,
    this.riderPhotoUrl = '',
    this.riderRating = 0,
    this.pickupAddress = '',
    this.dropoffAddress = '',
  });
}
