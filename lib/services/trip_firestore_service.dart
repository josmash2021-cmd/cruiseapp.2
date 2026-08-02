import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import '../models/lat_lng.dart';

/// Writes ride requests directly to the shared Firestore `trips` collection
/// so Dispatch Admin sees them in real time.
class TripFirestoreService {
  static final _db = FirebaseFirestore.instance;
  static CollectionReference get _trips => _db.collection('trips');

  /// Retry a Firestore operation with auth recovery on permission-denied.
  /// This handles the race condition where auth hasn't propagated to Firestore yet.
  static Future<T> _withAuthRetry<T>(Future<T> Function() operation, {String? label}) async {
    for (int attempt = 1; attempt <= 3; attempt++) {
      try {
        return await operation();
      } on FirebaseException catch (e) {
        if (e.code == 'permission-denied' && attempt < 3) {
          debugPrint('[Firestore] $label permission-denied (attempt $attempt) — re-authenticating...');
          // Force re-auth and retry
          try {
            await FirebaseAuth.instance.signInAnonymously();
            await Future.delayed(const Duration(milliseconds: 300));
          } catch (_) {}
          continue;
        }
        rethrow;
      }
    }
    throw Exception('$label failed after 3 attempts');
  }

  /// Submit a new ride request. Returns the Firestore document ID.
  static Future<String> submitRideRequest({
    required String passengerName,
    required String passengerPhone,
    required String pickupAddress,
    required String dropoffAddress,
    required double pickupLat,
    required double pickupLng,
    required double dropoffLat,
    required double dropoffLng,
    required double fare,
    required double distanceKm,
    required int durationMin,
    required String vehicleType,
    String paymentMethod = 'Cash',
    DateTime? scheduledAt,
    bool isAirportTrip = false,
  }) async {
    final now = DateTime.now();
    final docRef = await _withAuthRetry(
      () => _trips.add({
        'tripId': '',
        'passengerId': '',
        'passengerName': passengerName,
        'passengerPhone': passengerPhone,
        'driverId': null,
        'driverName': null,
        'driverPhone': null,
        'pickupAddress': pickupAddress,
        'pickupLat': pickupLat,
        'pickupLng': pickupLng,
        'dropoffAddress': dropoffAddress,
        'dropoffLat': dropoffLat,
        'dropoffLng': dropoffLng,
        'status': scheduledAt != null ? 'scheduled' : 'requested',
        'fare': fare,
        'distance': distanceKm,
        'duration': durationMin,
        'paymentMethod': paymentMethod,
        'vehicleType': vehicleType,
        'isAirportTrip': isAirportTrip,
        'scheduledAt': scheduledAt != null ? Timestamp.fromDate(scheduledAt) : null,
        'rating': null,
        'cancelReason': null,
        'createdAt': Timestamp.fromDate(now),
        'acceptedAt': null,
        'driverArrivedAt': null,
        'startedAt': null,
        'completedAt': null,
        'cancelledAt': null,
      }),
      label: 'submitRideRequest',
    );

    // Back-fill the tripId field with the real Firestore ID (fire-and-forget)
    unawaited(
      _withAuthRetry(() => docRef.update({'tripId': docRef.id}), label: 'backfillTripId')
        .catchError((e) {
          debugPrint('⚠️ Firestore backfill failed: $e');
          return null;
        }),
    );
    debugPrint('✅ Trip submitted to Firestore: ${docRef.id}');
    return docRef.id;
  }

  /// Watch a trip's status in real time (so the passenger can see updates).
  static Stream<Map<String, dynamic>?> watchTrip(String tripId) {
    return _trips
        .doc(tripId)
        .snapshots()
        .handleError(_logSnapshotError)
        .map((snap) {
          if (!snap.exists) return null;
          return snap.data() as Map<String, dynamic>;
        });
  }

  /// Keep a rejected snapshot from becoming an unhandled error.
  ///
  /// A `.snapshots()` listener with no onError throws into the zone, and
  /// Crashlytics files it under EventChannelExtension — 160 events across
  /// eleven users, all of them [cloud_firestore/permission-denied], which
  /// is what every rule that reads `auth != null` returns when the
  /// Firebase session never established.
  ///
  /// Handled, not silenced: the stream stays alive so it recovers the
  /// moment auth does, and the reason reaches the log instead of the
  /// crash report.
  static void _logSnapshotError(Object e, StackTrace _) {
    debugPrint('[TripFirestore] snapshot rejected: $e');
  }

  /// Cancel a trip from the passenger side.
  static Future<void> cancelTrip(String tripId) async {
    await _trips.doc(tripId).update({
      'status': 'cancelled',
      'cancelledBy': 'rider',
      'cancellationReason': 'rider_cancelled',
      'cancelReason': 'Cancelled by passenger',
      'cancelledAt': FieldValue.serverTimestamp(),
    });
  }

  // ─── Real-time sync: push backend status changes to Firestore ───

  /// Assign driver info + mark trip as accepted in Firestore.
  static Future<void> syncDriverAssigned(
    String tripId, {
    required String driverName,
    String? driverPhone,
    String? driverId,
  }) async {
    try {
      // Batch write: single round-trip for all fields
      final batch = _db.batch();
      batch.update(_trips.doc(tripId), {
        'status': 'accepted',
        'driverId': driverId,
        'driverName': driverName,
        'driverPhone': driverPhone,
        'acceptedAt': FieldValue.serverTimestamp(),
      });
      await batch.commit();
      debugPrint('🔄 Firestore synced: accepted (driver: $driverName)');
    } catch (e) {
      debugPrint('⚠️ Firestore sync (accepted) failed: $e');
    }
  }

  /// Sync status: driver arrived at pickup.
  static Future<void> syncDriverArrived(String tripId) async {
    try {
      await _trips.doc(tripId).update({
        'status': 'driver_arrived',
        'driverArrivedAt': FieldValue.serverTimestamp(),
      });
      debugPrint('🔄 Firestore synced: driver_arrived');
    } catch (e) {
      debugPrint('⚠️ Firestore sync (driver_arrived) failed: $e');
    }
  }

  /// Sync status: trip in progress (passenger picked up).
  static Future<void> syncTripStarted(String tripId) async {
    try {
      await _trips.doc(tripId).update({
        'status': 'in_progress',
        'startedAt': FieldValue.serverTimestamp(),
      });
      debugPrint('🔄 Firestore synced: in_progress');
    } catch (e) {
      debugPrint('⚠️ Firestore sync (in_progress) failed: $e');
    }
  }

  /// Sync status: trip completed.
  static Future<void> syncTripCompleted(String tripId) async {
    try {
      await _trips.doc(tripId).update({
        'status': 'completed',
        'completedAt': FieldValue.serverTimestamp(),
      });
      debugPrint('🔄 Firestore synced: completed');
    } catch (e) {
      debugPrint('⚠️ Firestore sync (completed) failed: $e');
    }
  }

  /// Sync status: trip cancelled.
  static Future<void> syncTripCancelled(
    String tripId, {
    String cancelledBy = 'driver',
    String cancellationReason = 'driver_cancelled',
    String reason = 'Cancelled',
  }) async {
    try {
      await _trips.doc(tripId).update({
        'status': 'cancelled',
        'cancelledBy': cancelledBy,
        'cancellationReason': cancellationReason,
        'cancelReason': reason,
        'cancelledAt': FieldValue.serverTimestamp(),
      });
      debugPrint('🔄 Firestore synced: cancelled');
    } catch (e) {
      debugPrint('⚠️ Firestore sync (cancelled) failed: $e');
    }
  }

  // ── Driver live-location ──────────────────────────────────────────────────

  /// Throttle tracker so we don't write to Firestore more than once per 500 ms.
  static DateTime? _lastLocationWrite;

  /// Write driver's current GPS position to the trip document (~2 Hz).
  static Future<void> syncDriverLocation(
    String tripId,
    double lat,
    double lng,
    double bearing,
  ) async {
    final now = DateTime.now();
    if (_lastLocationWrite != null &&
        now.difference(_lastLocationWrite!).inMilliseconds < 500) {
      return;
    }
    _lastLocationWrite = now;
    try {
      await _trips.doc(tripId).update({
        'driverLat': lat,
        'driverLng': lng,
        'driverBearing': bearing,
      });
    } catch (_) {}
  }

  /// Clear live driver-location fields from Firestore once the trip is over.
  static Future<void> clearDriverLocation(String tripId) async {
    try {
      await _trips.doc(tripId).update({
        'driverLat': FieldValue.delete(),
        'driverLng': FieldValue.delete(),
        'driverBearing': FieldValue.delete(),
      });
    } catch (_) {}
  }

  /// Stream of driver [LatLng] positions from Firestore — use on rider side.
  static Stream<LatLng> watchDriverLocation(String tripId) {
    return _trips
        .doc(tripId)
        .snapshots()
        .handleError(_logSnapshotError)
        .map((snap) {
          if (!snap.exists) return null;
          final d = snap.data() as Map<String, dynamic>?;
          if (d == null) return null;
          final lat = (d['driverLat'] as num?)?.toDouble();
          final lng = (d['driverLng'] as num?)?.toDouble();
          if (lat == null || lng == null) return null;
          return LatLng(lat, lng);
        })
        .where((ll) => ll != null)
        .cast<LatLng>();
  }
}
