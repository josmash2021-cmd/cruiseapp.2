import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';
import '../navigation/nav_state_machine.dart';
import '../l10n/app_localizations.dart';
import '../services/map_launcher_service.dart';
import 'driver_report_dialog.dart';

/// Indicación de navegación turn-by-turn
class NavInstruction {
  final String icon; // 'turn_left', 'turn_right', 'straight', 'uturn', etc.
  final String text;
  final double distanceMiles;

  const NavInstruction({
    required this.icon,
    required this.text,
    required this.distanceMiles,
  });
}

class DriverActionPanel extends StatelessWidget {
  const DriverActionPanel({
    this.instructions,
    this.nextStreet,
    this.onStartNavigation,
    super.key,
    required this.phase,
    required this.onArrivedAtPickup,
    required this.onStartTrip,
    required this.onArrivedAtDropoff,
    required this.onFinishTrip,
    this.distanceToDestination,
    this.etaMinutes,
  });

  final TripPhase phase;
  final VoidCallback onArrivedAtPickup;
  final VoidCallback onStartTrip;
  final VoidCallback onArrivedAtDropoff;
  final VoidCallback onFinishTrip;
  final double? distanceToDestination;
  final int? etaMinutes;
  final List<NavInstruction>? instructions;
  final String? nextStreet;
  final VoidCallback? onStartNavigation;

  static const _navy = Color(0xFF0A2463);
  static const _green = Color(0xFF34A853);
  static const _red = Color(0xFFEF5350);
  static const _gold = Color(0xFFD4A24C);
  static const _cardBg = Color(0xFF1A1E2E);
  static const _cardBorder = Color(0xFF2A2F42);
  static const _textPrimary = Color(0xFFF0F0F5);
  static const _textSecondary = Color(0xFF8A8FA0);

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    
    switch (phase) {
      case TripPhase.toPickup:
        return _buildNavigatingToPickupPanel(context, s);
      case TripPhase.arrivedPickup:
        return _buildArrivedAtPickupPanel(context, s);
      case TripPhase.onTrip:
        return _buildOnTripPanel(context, s);
      case TripPhase.arrivedDropoff:
        return _buildArrivedAtDropoffPanel(context, s);
      default:
        return const SizedBox.shrink();
    }
  }

  Widget _buildNavigatingToPickupPanel(BuildContext context, S s) {
    final hasInstructions = instructions != null && instructions!.isNotEmpty;
    final nextInstruction = hasInstructions ? instructions!.first : null;
    
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // ── Panel superior con instrucciones turn-by-turn ──
        if (hasInstructions)
          Container(
            margin: const EdgeInsets.fromLTRB(16, 16, 16, 0),
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(16),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.2),
                  blurRadius: 15,
                  offset: const Offset(0, 5),
                ),
              ],
            ),
            child: Column(
              children: [
                // Próxima instrucción
                Row(
                  children: [
                    Container(
                      width: 56,
                      height: 56,
                      decoration: BoxDecoration(
                        color: const Color(0xFF2E7D32).withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Icon(
                        _getNavIcon(nextInstruction?.icon ?? 'straight'),
                        color: const Color(0xFF2E7D32),
                        size: 32,
                      ),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            nextInstruction?.text ?? s.headToPickup,
                            style: const TextStyle(
                              color: Colors.black87,
                              fontSize: 18,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          if (nextInstruction != null)
                            Text(
                              'En ${(nextInstruction.distanceMiles * 5280).toInt()} ft',
                              style: TextStyle(
                                color: Colors.grey[600],
                                fontSize: 14,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                        ],
                      ),
                    ),
                    // ETA grande
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                      decoration: BoxDecoration(
                        color: const Color(0xFF2E7D32),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Text(
                        '${etaMinutes ?? 0} min',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 16,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                // Próximas instrucciones
                if (instructions!.length > 1)
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.grey[100],
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Row(
                      children: [
                        Icon(
                          _getNavIcon(instructions![1].icon),
                          color: Colors.grey[600],
                          size: 20,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            '${instructions![1].text} · ${instructions![1].distanceMiles.toStringAsFixed(1)} mi',
                            style: TextStyle(
                              color: Colors.grey[700],
                              fontSize: 13,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        
        // ── Panel principal de acciones ──
        Container(
          margin: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            gradient: const LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [Color(0xFF2E7D32), Color(0xFF1B5E20)],
            ),
            borderRadius: BorderRadius.circular(20),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.3),
                blurRadius: 20,
                offset: const Offset(0, 8),
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  children: [
                    // Info de distancia y tiempo
                    Row(
                      children: [
                        Expanded(
                          child: _buildInfoItem(
                            icon: Icons.schedule_rounded,
                            value: '${etaMinutes ?? 0} min',
                            label: 'Tiempo',
                          ),
                        ),
                        Container(width: 1, height: 40, color: Colors.white.withValues(alpha: 0.3)),
                        Expanded(
                          child: _buildInfoItem(
                            icon: Icons.route_rounded,
                            value: '${distanceToDestination?.toStringAsFixed(1) ?? '0.0'} mi',
                            label: 'Distancia',
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    
                    // Botón Start Navigation
                    SizedBox(
                      width: double.infinity,
                      height: 52,
                      child: OutlinedButton.icon(
                        onPressed: () {
                          HapticFeedback.mediumImpact();
                          if (onStartNavigation != null) {
                            onStartNavigation!();
                          } else {
                            _launchGoogleMaps();
                          }
                        },
                        icon: const Icon(Icons.navigation_rounded, size: 22),
                        label: const Text(
                          'INICIAR NAVEGACIÓN',
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w800,
                            letterSpacing: 0.8,
                          ),
                        ),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: Colors.white,
                          side: BorderSide(color: Colors.white.withValues(alpha: 0.5), width: 2),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    
                    // Botón Arrived
                    SizedBox(
                      width: double.infinity,
                      height: 56,
                      child: ElevatedButton.icon(
                        onPressed: () {
                          HapticFeedback.heavyImpact();
                          onArrivedAtPickup();
                        },
                        icon: const Icon(Icons.check_circle_rounded, size: 24),
                        label: Text(
                          s.arrivedAtPickup.toUpperCase(),
                          style: const TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w900,
                            letterSpacing: 1.0,
                          ),
                        ),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.white,
                          foregroundColor: const Color(0xFF2E7D32),
                          elevation: 0,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(16),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    _buildReportButton(context),
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  // Helper para construir items de info
  Widget _buildInfoItem({required IconData icon, required String value, required String label}) {
    return Column(
      children: [
        Icon(icon, color: Colors.white.withValues(alpha: 0.9), size: 20),
        const SizedBox(height: 4),
        Text(
          value,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 16,
            fontWeight: FontWeight.w800,
          ),
        ),
        Text(
          label,
          style: TextStyle(
            color: Colors.white.withValues(alpha: 0.7),
            fontSize: 12,
          ),
        ),
      ],
    );
  }

  // Helper para obtener icono de navegación
  IconData _getNavIcon(String icon) {
    switch (icon) {
      case 'turn_left':
        return Icons.turn_left_rounded;
      case 'turn_right':
        return Icons.turn_right_rounded;
      case 'uturn':
        return Icons.u_turn_left_rounded;
      case 'roundabout':
        return Icons.roundabout_left_rounded;
      case 'merge':
        return Icons.merge_rounded;
      case 'straight':
      default:
        return Icons.straight_rounded;
    }
  }

  // Abrir Google Maps con navegación
  void _launchGoogleMaps({double? lat, double? lng}) {
    if (lat != null && lng != null) {
      MapLauncherService.launch(lat, lng);
    }
  }

  Widget _buildArrivedAtPickupPanel(BuildContext context, S s) {
    return Container(
      margin: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [_gold, Color(0xFFB8892A)],
        ),
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: _gold.withValues(alpha: 0.4),
            blurRadius: 20,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.25),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Icon(
                        Icons.person_pin_circle_rounded,
                        color: Colors.white,
                        size: 28,
                      ),
                      const SizedBox(width: 12),
                      Text(
                        s.arrivedAtPickup,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 20,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 20),
                Text(
                  'Esperando al pasajero',
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.95),
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 16),
                SizedBox(
                  width: double.infinity,
                  height: 56,
                  child: ElevatedButton.icon(
                    onPressed: () {
                      HapticFeedback.heavyImpact();
                      onStartTrip();
                    },
                    icon: const Icon(Icons.play_arrow_rounded, size: 28),
                    label: Text(
                      s.startTrip.toUpperCase(),
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w900,
                        letterSpacing: 1.2,
                      ),
                    ),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.white,
                      foregroundColor: Colors.black,
                      elevation: 0,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                _buildReportButton(context),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildOnTripPanel(BuildContext context, S s) {
    return Container(
      margin: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF1565C0), Color(0xFF0D47A1)],
        ),
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: Colors.blue.withValues(alpha: 0.3),
            blurRadius: 20,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              children: [
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.2),
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(
                        Icons.local_taxi_rounded,
                        color: Colors.white,
                        size: 28,
                      ),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'En viaje al destino',
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 18,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const SizedBox(height: 4),
                          if (etaMinutes != null)
                            Text(
                              '$etaMinutes min · ${distanceToDestination?.toStringAsFixed(1) ?? '0.0'} mi',
                              style: TextStyle(
                                color: Colors.white.withValues(alpha: 0.9),
                                fontSize: 14,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                SizedBox(
                  width: double.infinity,
                  height: 56,
                  child: ElevatedButton.icon(
                    onPressed: () {
                      HapticFeedback.heavyImpact();
                      onArrivedAtDropoff();
                    },
                    icon: const Icon(Icons.location_on_rounded, size: 24),
                    label: Text(
                      'LLEGUÉ AL DESTINO',
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w900,
                        letterSpacing: 1.0,
                      ),
                    ),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.white,
                      foregroundColor: const Color(0xFF1565C0),
                      elevation: 0,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                _buildReportButton(context),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildArrivedAtDropoffPanel(BuildContext context, S s) {
    return Container(
      margin: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [_gold, Color(0xFFB8892A)],
        ),
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: _gold.withValues(alpha: 0.4),
            blurRadius: 20,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.25),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Icon(
                        Icons.check_circle_rounded,
                        color: Colors.white,
                        size: 32,
                      ),
                      const SizedBox(width: 12),
                      Text(
                        s.arrivedAtDest,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 20,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 20),
                Text(
                  'Pasajero ha llegado a su destino',
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.95),
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 16),
                SizedBox(
                  width: double.infinity,
                  height: 56,
                  child: ElevatedButton.icon(
                    onPressed: () {
                      HapticFeedback.heavyImpact();
                      onFinishTrip();
                    },
                    icon: const Icon(Icons.flag_rounded, size: 28),
                    label: Text(
                      'FINALIZAR VIAJE',
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w900,
                        letterSpacing: 1.2,
                      ),
                    ),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.white,
                      foregroundColor: Colors.black,
                      elevation: 0,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                _buildReportButton(context),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildReportButton(BuildContext context) {
    return TextButton.icon(
      onPressed: () => DriverReportDialog.show(context),
      icon: const Icon(Icons.report_problem_outlined, size: 18),
      label: const Text(
        'Reportar Problema',
        style: TextStyle(fontSize: 13),
      ),
      style: TextButton.styleFrom(
        foregroundColor: Colors.white70,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
          side: const BorderSide(color: Colors.white24),
        ),
      ),
    );
  }
}
