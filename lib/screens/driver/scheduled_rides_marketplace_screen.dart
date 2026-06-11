import 'dart:async';

import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:intl/intl.dart';

import '../../config/app_theme.dart';
import '../../l10n/app_localizations.dart';
import '../../services/api_service.dart';
import '../../utils/debounced.dart';

/// Marketplace screen where drivers browse and claim available scheduled rides.
class ScheduledRidesMarketplaceScreen extends StatefulWidget {
  const ScheduledRidesMarketplaceScreen({super.key});

  @override
  State<ScheduledRidesMarketplaceScreen> createState() =>
      _ScheduledRidesMarketplaceScreenState();
}

class _ScheduledRidesMarketplaceScreenState
    extends State<ScheduledRidesMarketplaceScreen> {
  static const _gold = Color(0xFFE8C547);
  static const _darkBg = Color(0xFF1A1A2E);
  static const _cardBg = Color(0xFF16213E);

  List<Map<String, dynamic>> _trips = [];
  bool _loading = true;
  String? _error;
  int? _claimingId;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() { _loading = true; _error = null; });
    try {
      double lat = 0, lng = 0;
      try {
        final pos = await Geolocator.getLastKnownPosition();
        if (pos != null) { lat = pos.latitude; lng = pos.longitude; }
      } catch (_) {}
      final trips = await ApiService.getAvailableScheduledTrips(
        lat: lat, lng: lng, radiusKm: 50,
      );
      if (!mounted) return;
      setState(() { _trips = trips; _loading = false; });
    } catch (e) {
      if (!mounted) return;
      setState(() { _error = e.toString(); _loading = false; });
    }
  }

  Future<void> _claim(int tripId) async {
    setState(() => _claimingId = tripId);
    try {
      final result = await ApiService.claimScheduledTrip(tripId);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            result['message'] ?? S.of(context).scheduledRideConfirmed,
            style: const TextStyle(color: Colors.black),
          ),
          backgroundColor: _gold,
        ),
      );
      _load(); // refresh list
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error: $e'), backgroundColor: Colors.red),
      );
    } finally {
      if (mounted) setState(() => _claimingId = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    return Scaffold(
      backgroundColor: _darkBg,
      appBar: AppBar(
        backgroundColor: _darkBg,
        foregroundColor: Colors.white,
        title: Text(
          s.scheduledRidesTitle,
          style: const TextStyle(fontWeight: FontWeight.w700),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _load,
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator(color: _gold))
          : _error != null
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.error_outline, color: Colors.red, size: 48),
                      const SizedBox(height: 12),
                      Text(_error!, style: const TextStyle(color: Colors.white70)),
                      const SizedBox(height: 16),
                      ElevatedButton(onPressed: debounce(_load), child: Text(s.retry)),
                    ],
                  ),
                )
              : _trips.isEmpty
                  ? Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.event_busy, color: _gold.withValues(alpha:0.5), size: 64),
                          const SizedBox(height: 16),
                          Text(
                            s.noScheduledTrips,
                            style: const TextStyle(color: Colors.white70, fontSize: 16),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            s.scheduledTripsHint,
                            style: const TextStyle(color: Colors.white38, fontSize: 13),
                          ),
                        ],
                      ),
                    )
                  : RefreshIndicator(
                      onRefresh: _load,
                      color: _gold,
                      child: ListView.builder(
                        padding: const EdgeInsets.all(16),
                        itemCount: _trips.length,
                        itemBuilder: (context, index) => _buildCard(context, _trips[index]),
                      ),
                    ),
    );
  }

  Widget _buildCard(BuildContext context, Map<String, dynamic> trip) {
    final s = S.of(context);
    final tripId = trip['id'] as int;
    final fare = (trip['fare'] as num?)?.toDouble() ?? 0;
    final pickup = trip['pickup_address'] ?? '';
    final dropoff = trip['dropoff_address'] ?? '';
    final distKm = (trip['distance_km'] as num?)?.toDouble() ?? 0;
    final vehicleType = trip['vehicle_type'] ?? 'standard';
    final scheduledAt = trip['scheduled_at'] != null
        ? DateTime.tryParse(trip['scheduled_at'])
        : null;

    final now = DateTime.now().toUtc();
    final minutesUntil = scheduledAt != null
        ? scheduledAt.difference(now).inMinutes
        : 0;
    final hoursUntil = (minutesUntil / 60).floor();

    String timeLabel;
    if (hoursUntil >= 24) {
      timeLabel = '${(hoursUntil / 24).floor()}d ${hoursUntil % 24}h';
    } else if (hoursUntil >= 1) {
      timeLabel = '${hoursUntil}h ${minutesUntil % 60}min';
    } else {
      timeLabel = '${minutesUntil}min';
    }

    final dateStr = scheduledAt != null
        ? DateFormat('EEE d MMM, h:mm a').format(scheduledAt.toLocal())
        : '';

    final isClaiming = _claimingId == tripId;

    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      decoration: BoxDecoration(
        color: _cardBg,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: _gold.withValues(alpha:0.2)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header: time + fare
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: BoxDecoration(
              color: _gold.withValues(alpha:0.1),
              borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
            ),
            child: Row(
              children: [
                const Icon(Icons.schedule, color: _gold, size: 20),
                const SizedBox(width: 8),
                Text(
                  dateStr,
                  style: const TextStyle(
                    color: Colors.white, fontWeight: FontWeight.w600, fontSize: 14,
                  ),
                ),
                const Spacer(),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: _gold,
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(
                    '\$${fare.toStringAsFixed(2)}',
                    style: const TextStyle(
                      color: Colors.black, fontWeight: FontWeight.w800, fontSize: 15,
                    ),
                  ),
                ),
              ],
            ),
          ),
          // Body: addresses
          Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Time until + distance + vehicle
                Row(
                  children: [
                    _chip('${s.pickupInLabel} $timeLabel', Icons.timer, _gold),
                    const SizedBox(width: 8),
                    if (distKm > 0) _chip('${distKm.toStringAsFixed(1)} km', Icons.near_me, Colors.blue),
                    const Spacer(),
                    _chip(vehicleType.toUpperCase(), Icons.directions_car, Colors.white54),
                  ],
                ),
                const SizedBox(height: 14),
                // Pickup
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Icon(Icons.circle, color: Colors.green, size: 10),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        pickup,
                        style: const TextStyle(color: Colors.white, fontSize: 13),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
                Padding(
                  padding: const EdgeInsets.only(left: 4),
                  child: Container(width: 1.5, height: 16, color: Colors.white24),
                ),
                // Dropoff
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Icon(Icons.circle, color: Colors.red, size: 10),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        dropoff,
                        style: const TextStyle(color: Colors.white70, fontSize: 13),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                // Claim button
                SizedBox(
                  width: double.infinity,
                  height: 48,
                  child: ElevatedButton(
                    onPressed: isClaiming ? null : () => _claim(tripId),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: _gold,
                      foregroundColor: Colors.black,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    child: isClaiming
                        ? const SizedBox(
                            width: 20, height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2, color: Colors.black),
                          )
                        : Text(
                            s.acceptRideButton,
                            style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15),
                          ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _chip(String label, IconData icon, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha:0.15),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: color),
          const SizedBox(width: 4),
          Text(
            label,
            style: TextStyle(color: color, fontSize: 11, fontWeight: FontWeight.w600),
          ),
        ],
      ),
    );
  }
}
