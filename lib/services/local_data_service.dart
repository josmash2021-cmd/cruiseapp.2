import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

class FavoritePlace {
  final int? id;
  final String label;
  final String address;
  final double? lat;
  final double? lng;
  final String icon;

  const FavoritePlace({
    this.id,
    required this.label,
    required this.address,
    this.lat,
    this.lng,
    this.icon = 'star',
  });

  Map<String, dynamic> toJson() => {
    if (id != null) 'id': id,
    'label': label,
    'address': address,
    if (lat != null) 'lat': lat,
    if (lng != null) 'lng': lng,
    'icon': icon,
  };

  static FavoritePlace fromJson(Map<String, dynamic> json) {
    return FavoritePlace(
      id: json['id'] as int?,
      label: json['label']?.toString() ?? '',
      address: json['address']?.toString() ?? '',
      lat: (json['lat'] as num?)?.toDouble(),
      lng: (json['lng'] as num?)?.toDouble(),
      icon: json['icon']?.toString() ?? 'star',
    );
  }
}

class TripHistoryItem {
  final int? tripId;
  final String pickup;
  final String dropoff;
  final String rideName;
  final String price;
  final String miles;
  final String duration;
  final DateTime createdAt;

  const TripHistoryItem({
    this.tripId,
    required this.pickup,
    required this.dropoff,
    required this.rideName,
    required this.price,
    required this.miles,
    required this.duration,
    required this.createdAt,
  });

  Map<String, dynamic> toJson() => {
    'tripId': tripId,
    'pickup': pickup,
    'dropoff': dropoff,
    'rideName': rideName,
    'price': price,
    'miles': miles,
    'duration': duration,
    'createdAt': createdAt.toIso8601String(),
  };

  static TripHistoryItem fromJson(Map<String, dynamic> json) {
    return TripHistoryItem(
      tripId: json['tripId'] as int?,
      pickup: json['pickup']?.toString() ?? '',
      dropoff: json['dropoff']?.toString() ?? '',
      rideName: json['rideName']?.toString() ?? '',
      price: json['price']?.toString() ?? '',
      miles: json['miles']?.toString() ?? '',
      duration: json['duration']?.toString() ?? '',
      createdAt:
          DateTime.tryParse(json['createdAt']?.toString() ?? '') ??
          DateTime.now(),
    );
  }
}

class FrequentDestination {
  final String address;
  final int count;

  const FrequentDestination({required this.address, required this.count});
}

class AppNotificationItem {
  final String id;
  final String title;
  final String message;
  final String type;
  final bool read;
  final DateTime createdAt;

  const AppNotificationItem({
    required this.id,
    required this.title,
    required this.message,
    required this.type,
    required this.read,
    required this.createdAt,
  });

  AppNotificationItem copyWith({bool? read}) {
    return AppNotificationItem(
      id: id,
      title: title,
      message: message,
      type: type,
      read: read ?? this.read,
      createdAt: createdAt,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'message': message,
    'type': type,
    'read': read,
    'createdAt': createdAt.toIso8601String(),
  };

  static AppNotificationItem fromJson(Map<String, dynamic> json) {
    return AppNotificationItem(
      id:
          json['id']?.toString() ??
          DateTime.now().millisecondsSinceEpoch.toString(),
      title: json['title']?.toString() ?? '',
      message: json['message']?.toString() ?? '',
      type: json['type']?.toString() ?? 'general',
      read: json['read'] == true,
      createdAt:
          DateTime.tryParse(json['createdAt']?.toString() ?? '') ??
          DateTime.now(),
    );
  }
}

class LocalDataService {
  static const _favoritesKey = 'favorites_v1';
  static const _tripHistoryKey = 'trip_history_v1';
  static const _usageKey = 'destination_usage_v1';
  static const _notificationsKey = 'notifications_v1';
  static const _promoKey = 'active_promo_v1';
  static const _promoMonthKey = 'promo_month_v1';
  static const _recentSearchesKey = 'recent_searches_v1';

  /// Cached SharedPreferences instance â€” avoids 38 platform channel calls.
  static SharedPreferences? _prefs;

  /// Call once at app startup (before any reads).
  static Future<void> init() async {
    _prefs ??= await SharedPreferences.getInstance();
  }

  static SharedPreferences get _p {
    assert(_prefs != null, 'LocalDataService.init() was not called');
    return _prefs!;
  }

  static Future<List<FavoritePlace>> getFavorites() async {
    final prefs = _p;
    final raw = prefs.getString(_favoritesKey);
    if (raw == null || raw.isEmpty) return [];

    try {
      final list = jsonDecode(raw) as List;
      return list
          .map(
            (item) =>
                FavoritePlace.fromJson(Map<String, dynamic>.from(item as Map)),
          )
          .where((place) => place.address.trim().isNotEmpty)
          .toList();
    } catch (_) {
      return [];
    }
  }

  static Future<void> saveFavorite(FavoritePlace favorite) async {
    final existing = await getFavorites();
    final filtered = existing
        .where(
          (item) =>
              item.label.toLowerCase().trim() !=
              favorite.label.toLowerCase().trim(),
        )
        .toList();
    filtered.insert(0, favorite);

    final prefs = _p;
    await prefs.setString(
      _favoritesKey,
      jsonEncode(filtered.map((item) => item.toJson()).toList()),
    );
  }

  static Future<void> removeFavorite(String label) async {
    final existing = await getFavorites();
    final filtered = existing
        .where(
          (item) =>
              item.label.toLowerCase().trim() !=
              label.toLowerCase().trim(),
        )
        .toList();
    final prefs = _p;
    await prefs.setString(
      _favoritesKey,
      jsonEncode(filtered.map((item) => item.toJson()).toList()),
    );
  }

  /// Most-recent-first list of the last destination addresses the user
  /// searched / picked. Deduped by exact-match.
  static Future<List<String>> getRecentSearches({int limit = 10}) async {
    final raw = _p.getString(_recentSearchesKey);
    if (raw == null || raw.isEmpty) return const [];
    try {
      final list = (jsonDecode(raw) as List).cast<String>();
      return list.take(limit).toList();
    } catch (_) {
      return const [];
    }
  }

  /// Add an address to the top of the recents list. Silently ignores empty
  /// or whitespace-only values.
  static Future<void> addRecentSearch(String address) async {
    final trimmed = address.trim();
    if (trimmed.isEmpty) return;
    final current = await getRecentSearches(limit: 20);
    final updated = [
      trimmed,
      ...current.where((s) => s.toLowerCase() != trimmed.toLowerCase()),
    ].take(20).toList();
    await _p.setString(_recentSearchesKey, jsonEncode(updated));
  }

  static Future<List<TripHistoryItem>> getTripHistory() async {
    final prefs = _p;
    final raw = prefs.getString(_tripHistoryKey);
    if (raw == null || raw.isEmpty) return [];

    try {
      final list = jsonDecode(raw) as List;
      final parsed = list
          .map(
            (item) => TripHistoryItem.fromJson(
              Map<String, dynamic>.from(item as Map),
            ),
          )
          .toList();
      parsed.sort((a, b) => b.createdAt.compareTo(a.createdAt));
      return parsed;
    } catch (_) {
      return [];
    }
  }

  static Future<void> addTrip(TripHistoryItem trip) async {
    final existing = await getTripHistory();
    final updated = [trip, ...existing].take(25).toList();

    final prefs = _p;
    await prefs.setString(
      _tripHistoryKey,
      jsonEncode(updated.map((item) => item.toJson()).toList()),
    );

    await incrementDestinationUsage(trip.dropoff);
  }

  static Future<void> incrementDestinationUsage(String address) async {
    final clean = address.trim();
    if (clean.isEmpty) return;

    final prefs = _p;
    final raw = prefs.getString(_usageKey);
    Map<String, dynamic> usage = {};

    if (raw != null && raw.isNotEmpty) {
      try {
        usage = Map<String, dynamic>.from(jsonDecode(raw) as Map);
      } catch (_) {}
    }

    final key = clean.toLowerCase();
    final current = (usage[key] as num?)?.toInt() ?? 0;
    usage[key] = current + 1;
    usage['__address__$key'] = clean;

    await prefs.setString(_usageKey, jsonEncode(usage));
  }

  static Future<List<FrequentDestination>> getTopDestinations({
    int limit = 5,
  }) async {
    final prefs = _p;
    final raw = prefs.getString(_usageKey);
    if (raw == null || raw.isEmpty) return [];

    try {
      final usage = Map<String, dynamic>.from(jsonDecode(raw) as Map);
      final entries = <FrequentDestination>[];

      usage.forEach((key, value) {
        if (key.startsWith('__address__')) return;
        final count = (value as num?)?.toInt() ?? 0;
        if (count <= 0) return;
        final address = usage['__address__$key']?.toString() ?? key;
        entries.add(FrequentDestination(address: address, count: count));
      });

      entries.sort((a, b) => b.count.compareTo(a.count));
      return entries.take(limit).toList();
    } catch (_) {
      return [];
    }
  }

  static Future<List<AppNotificationItem>> getNotifications() async {
    final prefs = _p;
    final raw = prefs.getString(_notificationsKey);
    if (raw == null || raw.isEmpty) return [];

    try {
      final list = jsonDecode(raw) as List;
      final notifications = list
          .map(
            (item) => AppNotificationItem.fromJson(
              Map<String, dynamic>.from(item as Map),
            ),
          )
          .toList();
      notifications.sort((a, b) => b.createdAt.compareTo(a.createdAt));
      return notifications;
    } catch (_) {
      return [];
    }
  }

  static Future<void> addNotification({
    required String title,
    required String message,
    String type = 'general',
  }) async {
    final existing = await getNotifications();
    final notification = AppNotificationItem(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      title: title,
      message: message,
      type: type,
      read: false,
      createdAt: DateTime.now(),
    );

    final updated = [notification, ...existing].take(50).toList();
    final prefs = _p;
    await prefs.setString(
      _notificationsKey,
      jsonEncode(updated.map((item) => item.toJson()).toList()),
    );
  }

  static Future<void> markNotificationsAsRead() async {
    final notifications = await getNotifications();
    if (notifications.isEmpty) return;

    final updated = notifications
        .map((item) => item.copyWith(read: true))
        .toList();
    final prefs = _p;
    await prefs.setString(
      _notificationsKey,
      jsonEncode(updated.map((item) => item.toJson()).toList()),
    );
  }

  // â”€â”€ Payment linking â”€â”€

  static const _linkedPaymentsKey = 'linked_payments_v1';

  /// Returns a Set of linked payment method IDs (e.g. 'google_pay', 'paypal', 'credit_card').
  static Future<Set<String>> getLinkedPaymentMethods() async {
    final prefs = _p;
    final list = prefs.getStringList(_linkedPaymentsKey) ?? [];
    return list.toSet();
  }

  /// Mark a payment method as linked.
  static Future<void> linkPaymentMethod(String id) async {
    final prefs = _p;
    final current = prefs.getStringList(_linkedPaymentsKey) ?? [];
    if (!current.contains(id)) {
      current.add(id);
      await prefs.setStringList(_linkedPaymentsKey, current);
    }
  }

  /// Mark a payment method as unlinked.
  static Future<void> unlinkPaymentMethod(String id) async {
    final prefs = _p;
    final current = prefs.getStringList(_linkedPaymentsKey) ?? [];
    current.remove(id);
    await prefs.setStringList(_linkedPaymentsKey, current);
  }

  // â”€â”€ Credit card last 4 + brand â”€â”€

  static const _cardLast4Key = 'credit_card_last4';
  static const _cardBrandKey = 'credit_card_brand';
  static const _stripePaymentMethodIdKey = 'stripe_pm_id';

  /// Save the Stripe PaymentMethod ID for charging later.
  static Future<void> saveStripePaymentMethodId(String pmId) async {
    final prefs = _p;
    await prefs.setString(_stripePaymentMethodIdKey, pmId);
  }

  /// Get the stored Stripe PaymentMethod ID (null if none).
  static Future<String?> getStripePaymentMethodId() async {
    final prefs = _p;
    return prefs.getString(_stripePaymentMethodIdKey);
  }

  /// Save the last 4 digits of a linked credit card.
  static Future<void> saveCreditCardLast4(String last4) async {
    final prefs = _p;
    await prefs.setString(_cardLast4Key, last4);
  }

  /// Get the stored last 4 digits (null if no card saved).
  static Future<String?> getCreditCardLast4() async {
    final prefs = _p;
    return prefs.getString(_cardLast4Key);
  }

  /// Save the card brand (e.g. 'visa', 'mastercard', 'amex').
  static Future<void> saveCreditCardBrand(String brand) async {
    final prefs = _p;
    await prefs.setString(_cardBrandKey, brand);
  }

  /// Get the stored card brand (null if no card saved).
  static Future<String?> getCreditCardBrand() async {
    final prefs = _p;
    return prefs.getString(_cardBrandKey);
  }

  static Future<List<String>?> getStringList(String key) async {
    final prefs = _p;
    return prefs.getStringList(key);
  }

  static Future<void> saveStringList(String key, List<String> value) async {
    final prefs = _p;
    await prefs.setStringList(key, value);
  }

  /// Detect card brand from the card number (BIN ranges).
  static String detectCardBrand(String cardNumber) {
    final digits = cardNumber.replaceAll(RegExp(r'\s'), '');
    if (digits.isEmpty) return 'card';

    // Visa
    if (digits.startsWith('4')) return 'visa';

    // Mastercard: 51-55, 2221-2720
    if (digits.length >= 2) {
      final first2 = int.tryParse(digits.substring(0, 2)) ?? 0;
      if (first2 >= 51 && first2 <= 55) return 'mastercard';
      if (digits.length >= 4) {
        final first4 = int.tryParse(digits.substring(0, 4)) ?? 0;
        if (first4 >= 2221 && first4 <= 2720) return 'mastercard';
      }
    }

    // Amex: 34, 37
    if (digits.startsWith('34') || digits.startsWith('37')) return 'amex';

    // Discover: 6011, 644-649, 65
    if (digits.startsWith('6011') || digits.startsWith('65')) return 'discover';
    if (digits.length >= 3) {
      final first3 = int.tryParse(digits.substring(0, 3)) ?? 0;
      if (first3 >= 644 && first3 <= 649) return 'discover';
    }

    // Diners: 300-305, 36, 38
    if (digits.startsWith('36') || digits.startsWith('38')) return 'diners';
    if (digits.length >= 3) {
      final first3 = int.tryParse(digits.substring(0, 3)) ?? 0;
      if (first3 >= 300 && first3 <= 305) return 'diners';
    }

    // JCB: 3528-3589
    if (digits.length >= 4) {
      final first4 = int.tryParse(digits.substring(0, 4)) ?? 0;
      if (first4 >= 3528 && first4 <= 3589) return 'jcb';
    }

    return 'card';
  }

  // â”€â”€ Promo / Discount system â”€â”€

  /// Returns the current month key, e.g. '2025-01'.
  static String _currentMonthKey() {
    final now = DateTime.now();
    return '${now.year}-${now.month.toString().padLeft(2, '0')}';
  }

  /// Check whether there is an active (unused) promo.
  static Future<bool> hasActivePromo() async {
    final prefs = _p;
    final raw = prefs.getString(_promoKey);
    if (raw == null || raw.isEmpty) return false;
    try {
      final data = jsonDecode(raw) as Map<String, dynamic>;
      return data['usedAt'] == null;
    } catch (_) {
      return false;
    }
  }

  /// Get the active promo details (null if none or already used).
  static Future<Map<String, dynamic>?> getActivePromo() async {
    final prefs = _p;
    final raw = prefs.getString(_promoKey);
    if (raw == null || raw.isEmpty) return null;
    try {
      final data = jsonDecode(raw) as Map<String, dynamic>;
      if (data['usedAt'] != null) return null; // already used
      return data;
    } catch (_) {
      return null;
    }
  }

  /// Get the discount percentage of the active promo (0 if none).
  static Future<int> getPromoDiscountPercent() async {
    final promo = await getActivePromo();
    if (promo == null) return 0;
    return (promo['discountPercent'] as num?)?.toInt() ?? 0;
  }

  /// Mark the active promo as used.
  static Future<void> usePromo() async {
    final prefs = _p;
    final raw = prefs.getString(_promoKey);
    if (raw == null || raw.isEmpty) return;
    try {
      final data = jsonDecode(raw) as Map<String, dynamic>;
      data['usedAt'] = DateTime.now().toIso8601String();
      await prefs.setString(_promoKey, jsonEncode(data));
    } catch (_) {}
  }

  /// Check if first-ride 10% promo has been used.
  static Future<bool> getPromoUsed() async {
    final prefs = _p;
    return prefs.getBool('first_ride_promo_used') ?? false;
  }

  /// Mark first-ride 10% promo as used and start the 3-trip cooldown
  /// so the rider has to complete 3 rides before unlocking the next
  /// monthly discount. Both writes happen together so the home screen
  /// always sees a consistent state on the next _loadSavedData.
  static Future<void> setPromoUsed() async {
    final prefs = _p;
    await prefs.setBool('first_ride_promo_used', true);
    await prefs.setInt('promo_trips_left', 3);
  }

  /// Generate a monthly promo if none exists for the current month.
  /// Returns true if a new promo was created, false if it already existed.
  static Future<bool> generateMonthlyPromoIfNeeded() async {
    final prefs = _p;
    final lastMonth = prefs.getString(_promoMonthKey) ?? '';
    final currentMonth = _currentMonthKey();

    if (lastMonth == currentMonth) return false; // already generated this month

    // Create new 10% promo
    final promo = {
      'discountPercent': 10,
      'createdAt': DateTime.now().toIso8601String(),
      'monthKey': currentMonth,
      'usedAt': null,
    };
    await prefs.setString(_promoKey, jsonEncode(promo));
    await prefs.setString(_promoMonthKey, currentMonth);
    return true;
  }

  // â”€â”€ Active Ride State â”€â”€
  static const _activeRideKey = 'active_ride_v1';

  static Future<void> setActiveRide(ActiveRideInfo ride) async {
    final prefs = _p;
    await prefs.setString(_activeRideKey, jsonEncode(ride.toJson()));
  }

  static Future<ActiveRideInfo?> getActiveRide() async {
    final prefs = _p;
    final raw = prefs.getString(_activeRideKey);
    if (raw == null) return null;
    try {
      return ActiveRideInfo.fromJson(jsonDecode(raw));
    } catch (_) {
      return null;
    }
  }

  static Future<void> clearActiveRide() async {
    final prefs = _p;
    await prefs.remove(_activeRideKey);
  }

  // â”€â”€ Identity verification â”€â”€

  static const _verifiedKey = 'identity_verified_v1';
  static const _docTypeKey = 'id_document_type_v1';
  static const _biometricKey = 'biometric_login_enabled';

  /// Sync getter — safe to call after init(), used to prevent UI flash.
  static bool get isVerifiedSync => _prefs?.getBool(_verifiedKey) ?? false;

  static Future<bool> isIdentityVerified() async {
    final prefs = _p;
    return prefs.getBool(_verifiedKey) ?? false;
  }

  static Future<void> setIdentityVerified(String documentType) async {
    final prefs = _p;
    await prefs.setBool(_verifiedKey, true);
    await prefs.setString(_docTypeKey, documentType);
  }

  static const _driverApprovalKey = 'driver_approval_status_v1';

  static Future<void> setDriverApprovalStatus(String status) async {
    final prefs = _p;
    await prefs.setString(_driverApprovalKey, status);
  }

  static Future<String> getDriverApprovalStatus() async {
    final prefs = _p;
    return prefs.getString(_driverApprovalKey) ?? 'none';
  }

  static Future<String?> getIdDocumentType() async {
    final prefs = _p;
    return prefs.getString(_docTypeKey);
  }

  static Future<bool> isBiometricLoginEnabled() async {
    final prefs = _p;
    return prefs.getBool(_biometricKey) ?? false;
  }

  static Future<void> setBiometricLogin(bool enabled) async {
    final prefs = _p;
    await prefs.setBool(_biometricKey, enabled);
  }

  /// Clear ALL user-specific data on logout so accounts are independent.
  static Future<void> clearAllUserData() async {
    final prefs = _p;
    await prefs.remove(_favoritesKey);
    await prefs.remove(_tripHistoryKey);
    await prefs.remove(_usageKey);
    await prefs.remove(_notificationsKey);
    await prefs.remove(_promoKey);
    await prefs.remove(_promoMonthKey);
    await prefs.remove(_linkedPaymentsKey);
    await prefs.remove(_cardLast4Key);
    await prefs.remove(_cardBrandKey);
    await prefs.remove(_stripePaymentMethodIdKey);
    await prefs.remove(_activeRideKey);
    await prefs.remove(_verifiedKey);
    await prefs.remove(_docTypeKey);
    await prefs.remove(_biometricKey);
    await prefs.remove(_driverApprovalKey);
    await prefs.remove('first_ride_promo_used');
    await prefs.remove('promo_trips_left');
    await prefs.remove('notif_ride');
    await prefs.remove('notif_promo');
    await prefs.remove('notif_safety');
    await prefs.remove('notif_payment');
    await prefs.remove('notif_sounds');
    await prefs.remove('notif_vibrate');
  }
}

/// Persisted info about a ride in progress so the rider can resume it.
class ActiveRideInfo {
  final double pickupLat;
  final double pickupLng;
  final double dropoffLat;
  final double dropoffLng;
  final String pickupLabel;
  final String dropoffLabel;
  final String driverName;
  final double driverRating;
  final String vehicleMake;
  final String vehicleModel;
  final String vehicleColor;
  final String vehiclePlate;
  final String vehicleYear;
  final String rideName;
  final double price;
  final List<List<double>> routePoints;
  final int? tripId;
  final String? firestoreTripId;
  // Persisted state for resuming
  final String? phase; // 'arriving', 'arrived', 'onTrip'
  final double? driverLat;
  final double? driverLng;
  final double? traveledMeters;
  final String? driverPhotoUrl;
  final String? driverId;
  final int? etaMinutes;
  final int? routeDurationSec;

  const ActiveRideInfo({
    required this.pickupLat,
    required this.pickupLng,
    required this.dropoffLat,
    required this.dropoffLng,
    required this.pickupLabel,
    required this.dropoffLabel,
    required this.driverName,
    required this.driverRating,
    required this.vehicleMake,
    required this.vehicleModel,
    required this.vehicleColor,
    required this.vehiclePlate,
    required this.vehicleYear,
    required this.rideName,
    required this.price,
    required this.routePoints,
    this.tripId,
    this.firestoreTripId,
    this.phase,
    this.driverLat,
    this.driverLng,
    this.traveledMeters,
    this.driverPhotoUrl,
    this.driverId,
    this.etaMinutes,
    this.routeDurationSec,
  });

  Map<String, dynamic> toJson() => {
    'pickupLat': pickupLat,
    'pickupLng': pickupLng,
    'dropoffLat': dropoffLat,
    'dropoffLng': dropoffLng,
    'pickupLabel': pickupLabel,
    'dropoffLabel': dropoffLabel,
    'driverName': driverName,
    'driverRating': driverRating,
    'vehicleMake': vehicleMake,
    'vehicleModel': vehicleModel,
    'vehicleColor': vehicleColor,
    'vehiclePlate': vehiclePlate,
    'vehicleYear': vehicleYear,
    'rideName': rideName,
    'price': price,
    'routePoints': routePoints,
    'tripId': tripId,
    'firestoreTripId': firestoreTripId,
    'phase': phase,
    'driverLat': driverLat,
    'driverLng': driverLng,
    'traveledMeters': traveledMeters,
    'driverPhotoUrl': driverPhotoUrl,
    'driverId': driverId,
    'etaMinutes': etaMinutes,
    'routeDurationSec': routeDurationSec,
  };

  static ActiveRideInfo fromJson(Map<String, dynamic> j) => ActiveRideInfo(
    pickupLat: (j['pickupLat'] as num).toDouble(),
    pickupLng: (j['pickupLng'] as num).toDouble(),
    dropoffLat: (j['dropoffLat'] as num).toDouble(),
    dropoffLng: (j['dropoffLng'] as num).toDouble(),
    pickupLabel: j['pickupLabel'] ?? '',
    dropoffLabel: j['dropoffLabel'] ?? '',
    driverName: j['driverName'] ?? '',
    driverRating: (j['driverRating'] as num?)?.toDouble() ?? 4.9,
    vehicleMake: j['vehicleMake'] ?? '',
    vehicleModel: j['vehicleModel'] ?? '',
    vehicleColor: j['vehicleColor'] ?? '',
    vehiclePlate: j['vehiclePlate'] ?? '',
    vehicleYear: j['vehicleYear'] ?? '',
    rideName: j['rideName'] ?? '',
    price: (j['price'] as num?)?.toDouble() ?? 0,
    routePoints:
        (j['routePoints'] as List?)
            ?.map((p) => (p as List).map((v) => (v as num).toDouble()).toList())
            .toList() ??
        [],
    tripId: j['tripId'] as int?,
    firestoreTripId: j['firestoreTripId'] as String?,
    phase: j['phase'] as String?,
    driverLat: (j['driverLat'] as num?)?.toDouble(),
    driverLng: (j['driverLng'] as num?)?.toDouble(),
    traveledMeters: (j['traveledMeters'] as num?)?.toDouble(),
    driverPhotoUrl: j['driverPhotoUrl'] as String?,
    driverId: j['driverId'] as String?,
    etaMinutes: j['etaMinutes'] as int?,
    routeDurationSec: j['routeDurationSec'] as int?,
  );
}
