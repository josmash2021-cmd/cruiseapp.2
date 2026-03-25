import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../config/page_transitions.dart';
import 'home_screen.dart';
import 'scheduled_rides_screen.dart';

/// Confirmation screen shown after rider books a scheduled ride.
class RideBookingConfirmedScreen extends StatefulWidget {
  final DateTime scheduledAt;
  final String pickupAddress;
  final String dropoffAddress;
  final String vehicleType;
  final double fare;

  const RideBookingConfirmedScreen({
    super.key,
    required this.scheduledAt,
    required this.pickupAddress,
    required this.dropoffAddress,
    required this.vehicleType,
    required this.fare,
  });

  @override
  State<RideBookingConfirmedScreen> createState() =>
      _RideBookingConfirmedScreenState();
}

class _RideBookingConfirmedScreenState extends State<RideBookingConfirmedScreen>
    with SingleTickerProviderStateMixin {
  static const _gold = Color(0xFFD4AF37);

  late AnimationController _ctrl;
  late Animation<double> _scaleAnim;
  late Animation<double> _fadeAnim;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 800),
    );

    _scaleAnim = TweenSequence<double>([
      TweenSequenceItem(
        tween:
            Tween(begin: 0.0, end: 1.15).chain(CurveTween(curve: Curves.easeOutCubic)),
        weight: 60,
      ),
      TweenSequenceItem(
        tween:
            Tween(begin: 1.15, end: 1.0).chain(CurveTween(curve: Curves.elasticOut)),
        weight: 40,
      ),
    ]).animate(_ctrl);

    _fadeAnim = CurvedAnimation(
      parent: _ctrl,
      curve: const Interval(0.0, 0.5, curve: Curves.easeIn),
    );

    _ctrl.forward();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  String _formatDateTime(DateTime dt) {
    return DateFormat('EEEE, MMM d · h:mm a').format(dt);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0A0D1A),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Spacer(),

              // Animated checkmark
              FadeTransition(
                opacity: _fadeAnim,
                child: Container(
                  width: 100,
                  height: 100,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: _gold.withValues(alpha: 0.15),
                    border: Border.all(color: _gold, width: 2),
                    boxShadow: [
                      BoxShadow(
                        color: _gold.withValues(alpha: 0.3),
                        blurRadius: 30,
                        spreadRadius: 5,
                      ),
                    ],
                  ),
                  child: const Icon(
                    Icons.check_rounded,
                    color: _gold,
                    size: 52,
                  ),
                ),
              ),

              const SizedBox(height: 32),

              // Title
              FadeTransition(
                opacity: _fadeAnim,
                child: const Text(
                  'Ride Booked!',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 26,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),

              const SizedBox(height: 12),

              // Subtitle
              FadeTransition(
                opacity: _fadeAnim,
                child: const Text(
                  'We\'ll send you a notification once\nwe have a driver available for your ride.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: Colors.white60,
                    fontSize: 15,
                    height: 1.5,
                  ),
                ),
              ),

              const SizedBox(height: 32),

              // Ride details card
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: const Color(0xFF1A1F35),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: _gold.withValues(alpha: 0.2)),
                ),
                child: Column(
                  children: [
                    _buildDetailRow(
                      Icons.access_time_rounded,
                      'Date & Time',
                      _formatDateTime(widget.scheduledAt),
                    ),
                    Divider(color: Colors.white.withValues(alpha: 0.06)),
                    _buildDetailRow(
                      Icons.location_on_rounded,
                      'Pickup',
                      widget.pickupAddress,
                    ),
                    Divider(color: Colors.white.withValues(alpha: 0.06)),
                    _buildDetailRow(
                      Icons.flag_rounded,
                      'Destination',
                      widget.dropoffAddress,
                    ),
                    Divider(color: Colors.white.withValues(alpha: 0.06)),
                    _buildDetailRow(
                      Icons.directions_car_rounded,
                      'Vehicle',
                      '${widget.vehicleType} · \$${widget.fare.toStringAsFixed(2)}',
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 16),

              // Status badge
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                decoration: BoxDecoration(
                  color: Colors.orange.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: Colors.orange.withValues(alpha: 0.4)),
                ),
                child: const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.schedule_rounded, color: Colors.orange, size: 16),
                    SizedBox(width: 8),
                    Text(
                      'Pending driver assignment',
                      style: TextStyle(
                        color: Colors.orange,
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),

              const Spacer(),

              // View scheduled rides button
              SizedBox(
                width: double.infinity,
                height: 52,
                child: ElevatedButton(
                  onPressed: () {
                    Navigator.of(context).pushAndRemoveUntil(
                      slideFromRightRoute(const ScheduledRidesScreen()),
                      (route) => route.isFirst,
                    );
                  },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _gold,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  child: const Text(
                    'View My Bookings',
                    style: TextStyle(
                      color: Colors.black,
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ),

              const SizedBox(height: 12),

              // Back to home
              TextButton(
                onPressed: () {
                  Navigator.of(context).pushAndRemoveUntil(
                    slideFromRightRoute(const HomeScreen()),
                    (_) => false,
                  );
                },
                child: const Text(
                  'Back to Home',
                  style: TextStyle(color: Colors.white54, fontSize: 14),
                ),
              ),

              const SizedBox(height: 16),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildDetailRow(IconData icon, String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(
        children: [
          Icon(icon, color: _gold, size: 18),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: const TextStyle(color: Colors.white38, fontSize: 11),
                ),
                Text(
                  value,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
