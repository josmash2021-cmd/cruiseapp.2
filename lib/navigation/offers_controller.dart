import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

import '../models/ride_offer.dart';
import '../services/api_service.dart';

/// Controller that polls the backend for pending ride offers and exposes
/// them via a [ValueNotifier] so the UI rebuilds automatically.
class OffersController {
  /// Current driver position — set before calling [start].
  LatLng driverLatLng = const LatLng(0, 0);

  final ValueNotifier<List<RideOffer>> offersNotifier =
      ValueNotifier<List<RideOffer>>([]);

  Timer? _pollTimer;
  int? _driverId;

  /// Start polling for offers.
  void start({int? driverId}) {
    _driverId = driverId;
    _poll(); // immediate first fetch
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(const Duration(seconds: 5), (_) => _poll());
  }

  Future<void> _poll() async {
    try {
      final id = _driverId ?? await _resolveDriverId();
      if (id == null) return;

      final raw = await ApiService.getDriverPendingOffers(id);
      final offers = raw.map((json) {
        final offer = RideOffer.fromJson(json);
        // Compute distance to pickup if not provided by server
        if (offer.distanceToPickupKm <= 0) {
          final km = _haversineKm(driverLatLng, offer.pickupLatLng);
          return RideOffer(
            offerId: offer.offerId,
            riderName: offer.riderName,
            pickupAddress: offer.pickupAddress,
            dropoffAddress: offer.dropoffAddress,
            pickupLatLng: offer.pickupLatLng,
            dropoffLatLng: offer.dropoffLatLng,
            fareUsd: offer.fareUsd,
            distanceToPickupKm: km,
            estimatedMinutes:
                offer.estimatedMinutes > 0 ? offer.estimatedMinutes : (km / 0.5).ceil().clamp(1, 99),
            vehicleType: offer.vehicleType,
          );
        }
        return offer;
      }).toList();

      offersNotifier.value = offers;
    } catch (e) {
      debugPrint('OffersController poll error: $e');
    }
  }

  /// Accept an offer. Returns an [AcceptedOffer] on success, or null.
  Future<AcceptedOffer?> acceptOffer(String offerId) async {
    try {
      final id = _driverId ?? await _resolveDriverId();
      if (id == null) return null;

      await ApiService.acceptRideOffer(
        offerId: int.parse(offerId),
        driverId: id,
      );

      // Find the offer in our local list to get its details
      final offer = offersNotifier.value.firstWhere(
        (o) => o.offerId == offerId,
        orElse: () => offersNotifier.value.first,
      );

      // Remove accepted offer from list
      offersNotifier.value =
          offersNotifier.value.where((o) => o.offerId != offerId).toList();

      return AcceptedOffer(
        offerId: offerId,
        pickupLatLng: offer.pickupLatLng,
        dropoffLatLng: offer.dropoffLatLng,
        riderName: offer.riderName,
      );
    } catch (e) {
      debugPrint('OffersController accept error: $e');
      return null;
    }
  }

  /// Reject an offer — removes it locally and notifies the backend with reason.
  void rejectOffer(String offerId, {String? reason}) {
    offersNotifier.value =
        offersNotifier.value.where((o) => o.offerId != offerId).toList();
    _rejectOnBackend(offerId, reason: reason);
  }

  Future<void> _rejectOnBackend(String offerId, {String? reason}) async {
    try {
      final id = _driverId ?? await _resolveDriverId();
      if (id == null) return;
      await ApiService.rejectRideOffer(
        offerId: int.parse(offerId),
        driverId: id,
        reason: reason,
      );
    } catch (e) {
      debugPrint('OffersController reject error: $e');
    }
  }

  Future<int?> _resolveDriverId() async {
    try {
      final me = await ApiService.getMe();
      if (me != null && me['id'] != null) {
        _driverId = me['id'] as int;
        return _driverId;
      }
    } catch (_) {}
    return null;
  }

  void dispose() {
    _pollTimer?.cancel();
    offersNotifier.dispose();
  }

  static double _haversineKm(LatLng a, LatLng b) {
    const R = 6371.0;
    final dLat = _r(b.latitude - a.latitude);
    final dLng = _r(b.longitude - a.longitude);
    final x =
        math.sin(dLat / 2) * math.sin(dLat / 2) +
        math.cos(_r(a.latitude)) *
            math.cos(_r(b.latitude)) *
            math.sin(dLng / 2) *
            math.sin(dLng / 2);
    return R * 2 * math.atan2(math.sqrt(x), math.sqrt(1 - x));
  }

  static double _r(double d) => d * math.pi / 180;
}
