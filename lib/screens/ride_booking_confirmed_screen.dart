import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import 'home_screen.dart';

/// Confirmation screen shown after rider books a scheduled ride.
/// Styled like "Viaje Aceptado" — gold check, bold title, auto-fades to home.
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
    with TickerProviderStateMixin {
  static const _gold = Color(0xFFE8C547);

  late AnimationController _enterCtrl;
  late Animation<double> _checkScale;
  late Animation<double> _checkFade;
  late Animation<double> _textFade;
  late Animation<double> _cardSlide;

  late AnimationController _fadeOutCtrl;

  @override
  void initState() {
    super.initState();

    // ── Enter animations ──
    _enterCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1000),
    );

    _checkScale = TweenSequence<double>([
      TweenSequenceItem(
        tween: Tween(begin: 0.0, end: 1.2)
            .chain(CurveTween(curve: Curves.easeOutCubic)),
        weight: 55,
      ),
      TweenSequenceItem(
        tween: Tween(begin: 1.2, end: 1.0)
            .chain(CurveTween(curve: Curves.elasticOut)),
        weight: 45,
      ),
    ]).animate(_enterCtrl);

    _checkFade = CurvedAnimation(
      parent: _enterCtrl,
      curve: const Interval(0.0, 0.4, curve: Curves.easeIn),
    );

    _textFade = CurvedAnimation(
      parent: _enterCtrl,
      curve: const Interval(0.25, 0.65, curve: Curves.easeOut),
    );

    _cardSlide = CurvedAnimation(
      parent: _enterCtrl,
      curve: const Interval(0.4, 0.85, curve: Curves.easeOutCubic),
    );

    // ── Fade-out to home ──
    _fadeOutCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 800),
    );

    _enterCtrl.forward();

    // Auto-navigate after 3.5 seconds
    Future.delayed(const Duration(milliseconds: 3500), () {
      if (!mounted) return;
      _fadeOutCtrl.forward().then((_) {
        if (!mounted) return;
        Navigator.of(context).pushAndRemoveUntil(
          PageRouteBuilder(
            pageBuilder: (_, __, ___) => const HomeScreen(),
            transitionDuration: Duration.zero,
          ),
          (_) => false,
        );
      });
    });
  }

  @override
  void dispose() {
    _enterCtrl.dispose();
    _fadeOutCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final timeStr = DateFormat('EEEE, MMM d · h:mm a').format(widget.scheduledAt);

    return AnimatedBuilder(
      animation: _fadeOutCtrl,
      builder: (context, child) => Opacity(
        opacity: 1.0 - _fadeOutCtrl.value,
        child: child,
      ),
      child: Scaffold(
        backgroundColor: const Color(0xFF0A0D1A),
        body: SafeArea(
          child: Center(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 28),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // ── Animated gold check circle ──
                  AnimatedBuilder(
                    animation: _enterCtrl,
                    builder: (context, child) => FadeTransition(
                      opacity: _checkFade,
                      child: ScaleTransition(
                        scale: _checkScale,
                        child: child,
                      ),
                    ),
                    child: Container(
                      width: 100,
                      height: 100,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: _gold.withValues(alpha: 0.12),
                        border: Border.all(color: _gold, width: 2.5),
                        boxShadow: [
                          BoxShadow(
                            color: _gold.withValues(alpha: 0.35),
                            blurRadius: 40,
                            spreadRadius: 8,
                          ),
                        ],
                      ),
                      child: const Icon(
                        Icons.check_rounded,
                        color: _gold,
                        size: 54,
                      ),
                    ),
                  ),

                  const SizedBox(height: 28),

                  // ── Title ──
                  FadeTransition(
                    opacity: _textFade,
                    child: const Text(
                      'Ride Reservado',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: _gold,
                        fontSize: 28,
                        fontWeight: FontWeight.w800,
                        letterSpacing: -0.3,
                      ),
                    ),
                  ),

                  const SizedBox(height: 14),

                  // ── Subtitle ──
                  FadeTransition(
                    opacity: _textFade,
                    child: const Text(
                      'Te notificaremos cuando ya tengas\nun driver asignado',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: Colors.white60,
                        fontSize: 15,
                        height: 1.5,
                      ),
                    ),
                  ),

                  const SizedBox(height: 32),

                  // ── Ride details card ──
                  SlideTransition(
                    position: Tween<Offset>(
                      begin: const Offset(0, 0.3),
                      end: Offset.zero,
                    ).animate(_cardSlide),
                    child: FadeTransition(
                      opacity: _cardSlide,
                      child: Container(
                        padding: const EdgeInsets.all(18),
                        decoration: BoxDecoration(
                          color: const Color(0xFF151929),
                          borderRadius: BorderRadius.circular(18),
                          border: Border.all(
                            color: _gold.withValues(alpha: 0.15),
                          ),
                        ),
                        child: Column(
                          children: [
                            _row(Icons.access_time_rounded, timeStr),
                            _divider(),
                            _row(Icons.location_on_rounded, widget.pickupAddress),
                            _divider(),
                            _row(Icons.flag_rounded, widget.dropoffAddress),
                            _divider(),
                            _row(
                              Icons.directions_car_rounded,
                              '${widget.vehicleType} · \$${widget.fare.toStringAsFixed(2)}',
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),

                  const SizedBox(height: 20),

                  // ── Status badge ──
                  FadeTransition(
                    opacity: _cardSlide,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 9,
                      ),
                      decoration: BoxDecoration(
                        color: _gold.withValues(alpha: 0.10),
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(color: _gold.withValues(alpha: 0.3)),
                      ),
                      child: const Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.schedule_rounded, color: _gold, size: 16),
                          SizedBox(width: 8),
                          Text(
                            'Pendiente de asignacion',
                            style: TextStyle(
                              color: _gold,
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _row(IconData icon, String text) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(
        children: [
          Icon(icon, color: _gold, size: 18),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              text,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }

  Widget _divider() =>
      Divider(color: Colors.white.withValues(alpha: 0.06), height: 1);
}
