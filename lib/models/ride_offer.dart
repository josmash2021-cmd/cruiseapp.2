import 'package:google_maps_flutter/google_maps_flutter.dart';

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
  });

  factory RideOffer.fromJson(Map<String, dynamic> json) {
    return RideOffer(
      offerId: json['offer_id']?.toString() ?? json['id']?.toString() ?? '',
      riderName: json['rider_name']?.toString() ?? 'Rider',
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
