import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:mapbox_maps_flutter/mapbox_maps_flutter.dart' as mapbox;
import 'package:url_launcher/url_launcher.dart';

import '../../config/map_theme.dart';
import '../../config/mapbox_config.dart';
import '../../config/app_theme.dart';
import '../../l10n/app_localizations.dart';
import '../../services/api_service.dart';

/// Full-screen countdown + details for an upcoming scheduled ride.
/// Shown when driver is "locked" (<=30 min before pickup).
class ScheduledRideDetailsScreen extends StatefulWidget {
  final Map<String, dynamic> trip;
  final double minutesUntil;

  const ScheduledRideDetailsScreen({
    super.key,
    required this.trip,
    required this.minutesUntil,
  });

  @override
  State<ScheduledRideDetailsScreen> createState() =>
      _ScheduledRideDetailsScreenState();
}

class _ScheduledRideDetailsScreenState extends State<ScheduledRideDetailsScreen>
    with SingleTickerProviderStateMixin {
  static const _gold = Color(0xFFE8C547);
  static const _darkBg = Color(0xFF0A0E21);
  static const _cardBg = Color(0xFF1A1A2E);

  late int _secondsRemaining;
  Timer? _countdownTimer;
  bool _starting = false;
  bool _cancelling = false;
  late final AnimationController _pulseCtrl;

  @override
  void initState() {
    super.initState();
    _secondsRemaining = (widget.minutesUntil * 60).round().clamp(0, 999999);
    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() {
        _secondsRemaining = (_secondsRemaining - 1).clamp(0, 999999);
      });
    });
    _pulseCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _countdownTimer?.cancel();
    _pulseCtrl.dispose();
    super.dispose();
  }

  int get _tripId => widget.trip['id'] as int;

  Future<void> _startRide() async {
    setState(() => _starting = true);
    try {
      await ApiService.startScheduledTrip(_tripId);
      if (!mounted) return;
      Navigator.of(context).pop('started');
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error: $e'), backgroundColor: Colors.red),
      );
    } finally {
      if (mounted) setState(() => _starting = false);
    }
  }

  Future<void> _cancelRide() async {
    final s = S.of(context);
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        final ls = S.of(ctx);
        return AlertDialog(
          backgroundColor: _cardBg,
          title: Text(ls.cancelRideTitle, style: const TextStyle(color: Colors.white)),
          content: Text(
            ls.cancelRideBody,
            style: const TextStyle(color: Colors.white70),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(ls.no, style: const TextStyle(color: Colors.white54)),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(ls.cancel, style: const TextStyle(color: Colors.red)),
            ),
          ],
        );
      },
    );
    if (confirm != true) return;

    setState(() => _cancelling = true);
    try {
      await ApiService.cancelScheduledTrip(_tripId);
      if (!mounted) return;
      Navigator.of(context).pop('cancelled');
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error: $e'), backgroundColor: Colors.red),
      );
    } finally {
      if (mounted) setState(() => _cancelling = false);
    }
  }

  String get _countdownText {
    final h = _secondsRemaining ~/ 3600;
    final m = (_secondsRemaining % 3600) ~/ 60;
    final s = _secondsRemaining % 60;
    if (h > 0) return '${h}h ${m.toString().padLeft(2, '0')}m ${s.toString().padLeft(2, '0')}s';
    return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final loc = S.of(context);
    final trip = widget.trip;
    final pickup = trip['pickup_address'] ?? '';
    final dropoff = trip['dropoff_address'] ?? '';
    final fare = (trip['fare'] as num?)?.toDouble() ?? 0;
    final riderName = trip['rider_name'] ?? '';
    final riderPhone = trip['rider_phone'] ?? '';
    final riderPhoto = trip['rider_photo_url']?.toString() ?? '';
    final vehicleType = trip['vehicle_type'] ?? 'standard';
    final pickupLat = (trip['pickup_lat'] as num?)?.toDouble();
    final pickupLng = (trip['pickup_lng'] as num?)?.toDouble();
    final scheduledAt = trip['scheduled_at'] != null
        ? DateTime.tryParse(trip['scheduled_at'])
        : null;
    final dateStr = scheduledAt != null
        ? DateFormat('EEEE d MMMM, h:mm a').format(scheduledAt.toLocal())
        : '';

    final canStart = _secondsRemaining <= 600; // Can start 10 min early

    return Scaffold(
      backgroundColor: _darkBg,
      body: Stack(
        children: [
          // ── Blurry map background ──
          if (pickupLat != null && pickupLng != null)
            Positioned.fill(
              child: IgnorePointer(
                child: mapbox.MapWidget(
                  styleUri: MapboxConfig.styleDark,
                  cameraOptions: mapbox.CameraOptions(
                    center: mapbox.Point(
                      coordinates: mapbox.Position(pickupLng, pickupLat),
                    ),
                    zoom: 13.0,
                    pitch: 0.0,
                  ),
                  onMapCreated: (ctrl) async {
                    ctrl.scaleBar.updateSettings(mapbox.ScaleBarSettings(enabled: false));
                    ctrl.compass.updateSettings(mapbox.CompassSettings(enabled: false));
                    ctrl.attribution.updateSettings(mapbox.AttributionSettings(enabled: false));
                    ctrl.logo.updateSettings(mapbox.LogoSettings(enabled: false));
                  },
                  onStyleLoadedListener: (_) {},
                ),
              ),
            ),
          // ── Blur + dark tint overlay ──
          Positioned.fill(
            child: BackdropFilter(
              filter: ui.ImageFilter.blur(sigmaX: 18, sigmaY: 18),
              child: Container(
                color: _darkBg.withValues(alpha: 0.78),
              ),
            ),
          ),
          // ── Content ──
          SafeArea(
        child: Column(
          children: [
            // Top bar
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    decoration: BoxDecoration(
                      color: _gold.withValues(alpha:0.15),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.event, color: _gold, size: 16),
                        const SizedBox(width: 6),
                        Text(
                          S.of(context).scheduledRideLabel,
                          style: TextStyle(
                            color: _gold,
                            fontSize: 12,
                            fontWeight: FontWeight.w800,
                            letterSpacing: 1,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const Spacer(),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    decoration: BoxDecoration(
                      color: _gold,
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Text(
                      '\$${fare.toStringAsFixed(2)}',
                      style: const TextStyle(
                        color: Colors.black, fontWeight: FontWeight.w900, fontSize: 16,
                      ),
                    ),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 20),

            // Countdown circle
            AnimatedBuilder(
              animation: _pulseCtrl,
              builder: (context, child) {
                final scale = 1.0 + _pulseCtrl.value * 0.03;
                return Transform.scale(scale: scale, child: child);
              },
              child: Container(
                width: 200,
                height: 200,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: RadialGradient(
                    colors: [
                      _gold.withValues(alpha:0.2),
                      _gold.withValues(alpha:0.05),
                      Colors.transparent,
                    ],
                  ),
                  border: Border.all(color: _gold.withValues(alpha:0.4), width: 3),
                ),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      _secondsRemaining <= 0 ? loc.nowLabel.toUpperCase() : _countdownText,
                      style: TextStyle(
                        color: _secondsRemaining <= 0 ? Colors.green : _gold,
                        fontSize: _secondsRemaining <= 0 ? 32 : 36,
                        fontWeight: FontWeight.w900,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                    if (_secondsRemaining > 0)
                      Text(
                        loc.forPickup,
                        style: const TextStyle(color: Colors.white54, fontSize: 12),
                      ),
                  ],
                ),
              ),
            ),

            const SizedBox(height: 8),
            Text(
              dateStr,
              style: const TextStyle(color: Colors.white70, fontSize: 14),
            ),

            const SizedBox(height: 24),

            // Trip details card
            Expanded(
              child: Container(
                margin: const EdgeInsets.symmetric(horizontal: 16),
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  color: _cardBg,
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: _gold.withValues(alpha:0.15)),
                ),
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Rider info
                      if (riderName.isNotEmpty)
                        Row(
                          children: [
                            CircleAvatar(
                              backgroundColor: _gold.withValues(alpha:0.2),
                              radius: 22,
                              backgroundImage: riderPhoto.isNotEmpty
                                  ? NetworkImage(riderPhoto)
                                  : null,
                              child: riderPhoto.isEmpty
                                  ? Text(
                                      riderName.isNotEmpty ? riderName[0].toUpperCase() : '?',
                                      style: TextStyle(color: _gold, fontWeight: FontWeight.bold, fontSize: 18),
                                    )
                                  : null,
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    riderName,
                                    style: const TextStyle(
                                      color: Colors.white, fontSize: 16, fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                  Text(
                                    vehicleType.toUpperCase(),
                                    style: TextStyle(color: _gold, fontSize: 11, fontWeight: FontWeight.w700),
                                  ),
                                ],
                              ),
                            ),
                            if (riderPhone.isNotEmpty)
                              IconButton(
                                icon: const Icon(Icons.phone, color: Colors.green),
                                onPressed: () => launchUrl(Uri.parse('tel:$riderPhone')),
                              ),
                          ],
                        ),

                      if (riderName.isNotEmpty) const SizedBox(height: 20),

                      // Pickup
                      _addressRow(
                        icon: Icons.circle,
                        color: Colors.green,
                        label: S.of(context).pickupUpperLabel,
                        address: pickup,
                      ),
                      Padding(
                        padding: const EdgeInsets.only(left: 7),
                        child: Container(width: 2, height: 20, color: Colors.white12),
                      ),
                      // Dropoff
                      _addressRow(
                        icon: Icons.circle,
                        color: Colors.red,
                        label: S.of(context).dropoffUpperLabel,
                        address: dropoff,
                      ),

                      const SizedBox(height: 24),

                      // No more offers banner
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                        decoration: BoxDecoration(
                          color: Colors.orange.withValues(alpha:0.1),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: Colors.orange.withValues(alpha:0.3)),
                        ),
                        child: Row(
                          children: [
                            const Icon(Icons.block, color: Colors.orange, size: 18),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                loc.noNewRidesUntilComplete,
                                style: const TextStyle(color: Colors.orange, fontSize: 12),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),

            const SizedBox(height: 16),

            // Bottom buttons
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: Row(
                children: [
                  // Cancel button
                  Expanded(
                    flex: 1,
                    child: SizedBox(
                      height: 52,
                      child: OutlinedButton(
                        onPressed: _cancelling ? null : _cancelRide,
                        style: OutlinedButton.styleFrom(
                          side: const BorderSide(color: Colors.red, width: 1.5),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(14),
                          ),
                        ),
                        child: _cancelling
                            ? const SizedBox(
                                width: 18, height: 18,
                                child: CircularProgressIndicator(strokeWidth: 2, color: Colors.red),
                              )
                            : Text(
                                loc.cancel.toUpperCase(),
                                style: const TextStyle(
                                  color: Colors.red, fontWeight: FontWeight.w700, fontSize: 13,
                                ),
                              ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  // Start ride button
                  Expanded(
                    flex: 2,
                    child: SizedBox(
                      height: 52,
                      child: ElevatedButton(
                        onPressed: canStart && !_starting ? _startRide : null,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: canStart ? _gold : Colors.grey[700],
                          foregroundColor: Colors.black,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(14),
                          ),
                        ),
                        child: _starting
                            ? const SizedBox(
                                width: 20, height: 20,
                                child: CircularProgressIndicator(strokeWidth: 2, color: Colors.black),
                              )
                            : Text(
                                canStart
                                    ? loc.startRideButton
                                    : '${loc.availableInLabel} ${(_secondsRemaining ~/ 60) - 10} MIN',
                                style: TextStyle(
                                  fontWeight: FontWeight.w800,
                                  fontSize: canStart ? 16 : 12,
                                ),
                              ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
        ], // Stack children
      ), // Stack
    );
  }

  Widget _addressRow({
    required IconData icon,
    required Color color,
    required String label,
    required String address,
  }) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 2),
          child: Icon(icon, color: color, size: 14),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: TextStyle(
                  color: color.withValues(alpha:0.7),
                  fontSize: 10,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 1,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                address,
                style: const TextStyle(color: Colors.white, fontSize: 14),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
      ],
    );
  }
}
