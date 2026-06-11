import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import '../models/lat_lng.dart';

import '../models/ride_offer.dart';
import '../services/api_service.dart';
import '../services/analytics_service.dart';
import '../services/user_session.dart';

/// Controller that uses SSE (Server-Sent Events) for instant offer delivery
/// with automatic fallback to HTTP polling if SSE is unavailable.
class OffersController {
  /// Current driver position — set before calling [start].
  LatLng driverLatLng = const LatLng(0, 0);

  final ValueNotifier<List<RideOffer>> offersNotifier =
      ValueNotifier<List<RideOffer>>([]);

  Timer? _pollTimer;
  int? _driverId;
  final Set<String> _acceptingOffers = {}; // Fix H6: anti-double-accept guard
  StreamSubscription? _sseSub;
  Timer? _sseReconnectTimer;
  bool _sseActive = false;

  /// Start SSE stream + polling fallback for offers.
  void start({int? driverId}) {
    _driverId = driverId;
    _poll(); // immediate first fetch
    _startSSE(); // try SSE for sub-second delivery
    // Reduced polling to 8s — SSE handles real-time, polling is safety net
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(const Duration(seconds: 15), (_) {
      if (!_sseActive) _poll(); // Only poll when SSE is down
    });
  }

  void _startSSE() async {
    final id = _driverId ?? await _resolveDriverId();
    if (id == null) return;

    _sseSub?.cancel();
    _sseSub = ApiService.streamDriverOffers(id).listen(
      (offers) {
        _sseActive = true;
        _applyOffers(offers);
      },
      onError: (e) {
        debugPrint('[SSE] Stream error: $e — falling back to polling');
        _sseActive = false;
      },
      onDone: () {
        _sseActive = false;
        debugPrint('[SSE] Stream closed — reconnecting in 3s');
        // Auto-reconnect SSE after brief delay
        _sseReconnectTimer?.cancel();
        _sseReconnectTimer = Timer(const Duration(seconds: 3), () {
          if (_pollTimer != null) _startSSE();
        });
      },
    );
  }

  void _applyOffers(List<Map<String, dynamic>> raw) {
    final offers = raw.map((json) {
      final offer = RideOffer.fromJson(json);
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
          riderPhotoUrl: offer.riderPhotoUrl,
          riderRating: offer.riderRating,
          riderRatingsCount: offer.riderRatingsCount,
          riderIsNew: offer.riderIsNew,
          riderId: offer.riderId,
          tripId: offer.tripId,
        );
      }
      return offer;
    }).toList();
    offersNotifier.value = offers;
  }

  Future<void> _poll() async {
    // M4: skip poll when offline — avoids hammering backend with failed requests
    if (!await ApiService.isOnline()) return;
    try {
      final id = _driverId ?? await _resolveDriverId();
      if (id == null) return;

      final raw = await ApiService.getDriverPendingOffers(id);
      _applyOffers(raw);
    } catch (e) {
      debugPrint('OffersController poll error: $e');
    }
  }

  /// Accept an offer. Returns an [AcceptedOffer] on success, or null.
  Future<AcceptedOffer?> acceptOffer(String offerId) async {
    // Fix H6: prevent double-tap from sending duplicate accept requests
    if (_acceptingOffers.contains(offerId)) return null;
    _acceptingOffers.add(offerId);
    try {
      final id = _driverId ?? await _resolveDriverId();
      if (id == null) return null;

      final response = await ApiService.acceptRideOffer(
        offerId: int.parse(offerId),
        driverId: id,
      );
      AnalyticsService.instance.logRideAccepted();

      // Extract trip ID from the accept response — the backend returns
      // {"status": "accepted", "trip": {"id": <trip_id>, ...}}
      final tripData = response['trip'];
      final int tripId = (tripData is Map && tripData['id'] != null)
          ? (tripData['id'] as num).toInt()
          : 0;

      // Write accepted status to Firestore immediately so rider's listener fires
      // without waiting for the backend's async Firestore sync (1-3s delay).
      final resolvedTripId = tripId > 0 ? tripId : null;
      if (resolvedTripId != null) {
        try {
          final driverUser = await UserSession.getUser();
          final firstName = driverUser?['firstName']?.toString() ?? '';
          final lastName = driverUser?['lastName']?.toString() ?? '';
          final phone = driverUser?['phone']?.toString() ?? '';
          final photo = driverUser?['photoUrl']?.toString() ?? '';
          final fullName = '$firstName $lastName'.trim();
          FirebaseFirestore.instance
              .collection('trips')
              .doc('sql_$resolvedTripId')
              .set({
            'status': 'driver_en_route',
            'driver_id': id,
            'driverId': id.toString(),
            'driver_name': fullName.isNotEmpty ? fullName : 'Driver',
            'driverName': fullName.isNotEmpty ? fullName : 'Driver',
            'driver_phone': phone,
            'driverPhone': phone,
            'driver_photo_url': photo,
            'driverPhotoUrl': photo,
            'acceptedAt': FieldValue.serverTimestamp(),
          }, SetOptions(merge: true)).catchError((_) {});
        } catch (_) {}
      }

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
        tripId: tripId > 0 ? tripId : (offer.tripId ?? 0),
        pickupLatLng: offer.pickupLatLng,
        dropoffLatLng: offer.dropoffLatLng,
        riderName: offer.riderName,
        riderPhotoUrl: offer.riderPhotoUrl,
        riderRating: offer.riderRating,
        riderRatingsCount: offer.riderRatingsCount,
        riderIsNew: offer.riderIsNew,
        pickupAddress: offer.pickupAddress,
        dropoffAddress: offer.dropoffAddress,
      );
    } catch (e) {
      debugPrint('OffersController accept error: $e');
      return null;
    } finally {
      _acceptingOffers.remove(offerId); // always release the guard
    }
  }

  /// Reject an offer — removes it locally and notifies the backend with reason.
  void rejectOffer(String offerId, {String? reason}) {
    AnalyticsService.instance.logRideDeclined();
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
    int? toInt(dynamic v) {
      if (v == null) return null;
      if (v is int) return v;
      if (v is double) return v.toInt();
      if (v is String) return int.tryParse(v);
      return null;
    }

    try {
      final me = await ApiService.getMe();
      if (me != null && me['id'] != null) {
        _driverId = toInt(me['id']);
        return _driverId;
      }
    } catch (_) {}
    return null;
  }

  void dispose() {
    _sseReconnectTimer?.cancel();
    _pollTimer?.cancel();
    _pollTimer = null;
    _sseSub?.cancel();
    _sseSub = null;
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
