import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../services/haptic_service.dart';
import 'verified_avatar.dart';
import '../models/lat_lng.dart';
import 'package:url_launcher/url_launcher.dart';

import '../config/app_theme.dart';
import '../l10n/app_localizations.dart';
import '../navigation/car_icon_loader.dart';

/// Indicación de navegación turn-by-turn
class NavInstruction {
  final String type; // 'turn_left', 'turn_right', 'straight', 'uturn', 'merge', 'exit', 'roundabout'
  final String text;
  final double distanceMiles;
  final String? exitNumber; // Para salidas de autopista

  const NavInstruction({
    required this.type,
    required this.text,
    required this.distanceMiles,
    this.exitNumber,
  });
}

/// Panel de navegación estilo Google Maps para drivers
/// Muestra instrucciones turn-by-turn, carrito 3D, y controles de navegación
class DriverNavigationPanel extends StatefulWidget {
  const DriverNavigationPanel({
    super.key,
    required this.phase, // 'toPickup', 'onTrip', 'arrived'
    required this.instructions,
    required this.etaMinutes,
    required this.totalDistanceMiles,
    required this.currentSpeedMph,
    required this.onArrived,
    required this.onStartTrip,
    required this.onFinishTrip,
    required this.onStartExternalNav,
    this.riderName = '' ,
    this.riderPhotoUrl = '',
    this.riderId,
    this.pickupLabel = '',
    this.dropoffLabel = '',
    this.destinationLat,
    this.destinationLng,
  });

  final String phase;
  final List<NavInstruction> instructions;
  final int etaMinutes;
  final double totalDistanceMiles;
  final double currentSpeedMph;
  final VoidCallback onArrived;
  final VoidCallback onStartTrip;
  final VoidCallback onFinishTrip;
  final VoidCallback onStartExternalNav;
  final String riderName;
  final String riderPhotoUrl;
  final int? riderId;
  final String pickupLabel;
  final String dropoffLabel;
  final double? destinationLat;
  final double? destinationLng;

  static const Color _navy = Color(0xFF0A2463);
  static const Color _green = Color(0xFF34A853);
  static const Color _red = Color(0xFFEF5350);
  static const Color _gold = Color(0xFFE8C547);
  static const Color _cardBg = Color(0xFF1A1E2E);
  static const Color _cardBorder = Color(0xFF2A2F42);

  @override
  State<DriverNavigationPanel> createState() => _DriverNavigationPanelState();
}

class _DriverNavigationPanelState extends State<DriverNavigationPanel> {
  Uint8List? _carIconBytes;
  bool _carIconLoading = false;

  @override
  void initState() {
    super.initState();
    _loadCarIcon();
  }

  Future<void> _loadCarIcon() async {
    if (_carIconLoading || _carIconBytes != null) return;
    _carIconLoading = true;
    try {
      final bytes = await CarIconLoader.loadUberBytes();
      if (mounted && bytes != null) {
        setState(() => _carIconBytes = bytes);
      }
    } catch (_) {}
    _carIconLoading = false;
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Panel superior con instrucciones
        _buildTopInstructionsPanel(),
        
        const Spacer(),
        
        // Panel inferior con controles
        _buildBottomControlPanel(),
      ],
    );
  }

  /// Panel superior con instrucciones turn-by-turn (estilo Google Maps)
  Widget _buildTopInstructionsPanel() {
    final nextInstruction = widget.instructions.isNotEmpty 
        ? widget.instructions.first 
        : null;
    
    return Container(
      margin: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.2),
            blurRadius: 20,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Barra de progreso con tiempo y distancia
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: BoxDecoration(
              color: DriverNavigationPanel._green,
              borderRadius: const BorderRadius.only(
                topLeft: Radius.circular(16),
                topRight: Radius.circular(16),
              ),
            ),
            child: Row(
              children: [
                // ETA grande
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    '${widget.etaMinutes} min',
                    style: const TextStyle(
                      color: DriverNavigationPanel._green,
                      fontSize: 20,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                // Distancia y tiempo
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${widget.totalDistanceMiles.toStringAsFixed(1)} mi',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      Text(
                        widget.phase == 'toPickup' 
                            ? S.of(context).headToPickup
                            : S.of(context).headToDestination,
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.8),
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
                // Velocidad actual
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.2),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    '${widget.currentSpeedMph.toInt()} mph',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
          ),
          
          // Instrucción principal
          if (nextInstruction != null)
            Container(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  // Icono grande de la instrucción
                  Container(
                    width: 64,
                    height: 64,
                    decoration: BoxDecoration(
                      color: DriverNavigationPanel._green.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Center(
                      child: _buildNavIcon(nextInstruction.type, size: 40),
                    ),
                  ),
                  const SizedBox(width: 16),
                  // Texto de la instrucción
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (nextInstruction.exitNumber != null)
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                            margin: const EdgeInsets.only(bottom: 4),
                            decoration: BoxDecoration(
                              color: DriverNavigationPanel._green,
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Text(
                              S.of(context).exitNumberLabel(int.tryParse(nextInstruction.exitNumber ?? '0') ?? 0),
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 12,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                        Text(
                          nextInstruction.text,
                          style: const TextStyle(
                            color: Colors.black87,
                            fontSize: 18,
                            fontWeight: FontWeight.w700,
                          ),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 4),
                        Text(
                          _formatDistance(nextInstruction.distanceMiles),
                          style: TextStyle(
                            color: Colors.grey[600],
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          
          // Próximas instrucciones (si hay)
          if (widget.instructions.length > 1)
            Container(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: Column(
                children: [
                  Divider(color: Colors.grey[200], height: 1),
                  const SizedBox(height: 12),
                  for (int i = 1; i < math.min(widget.instructions.length, 3); i++)
                    _buildNextInstructionRow(widget.instructions[i]),
                ],
              ),
            ),
        ],
      ),
    );
  }

  /// Panel inferior con controles
  Widget _buildBottomControlPanel() {
    final isArrived = widget.phase == 'arrivedPickup' || widget.phase == 'arrivedDropoff';
    
    return Container(
      margin: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: DriverNavigationPanel._cardBg,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: DriverNavigationPanel._cardBorder, width: 1),
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
          // Info del rider (si es fase de pickup)
          if (widget.phase == 'toPickup' || widget.phase == 'arrivedPickup')
            _buildRiderInfoRow(),
          
          // Botones de acción
          Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              children: [
                // Botón de navegación externa (si no ha llegado)
                if (!isArrived)
                  SizedBox(
                    width: double.infinity,
                    height: 52,
                    child: OutlinedButton.icon(
                      onPressed: () {
                        HapticService.mediumImpact();
                        _launchExternalNavigation();
                      },
                      icon: const Icon(Icons.navigation_rounded, size: 22),
                      label: Text(
                        S.of(context).openInGoogleMaps,
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 0.8,
                        ),
                      ),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: Colors.white,
                        side: const BorderSide(color: Colors.white54, width: 2),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                    ),
                  ),
                
                if (!isArrived)
                  const SizedBox(height: 12),
                
                // Botón principal de acción
                SizedBox(
                  width: double.infinity,
                  height: 56,
                  child: ElevatedButton.icon(
                    onPressed: () {
                      HapticService.heavyImpact();
                      _handleMainAction();
                    },
                    icon: Icon(_getActionIcon(), size: 24),
                    label: Text(
                      _getActionText().toUpperCase(),
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w900,
                        letterSpacing: 1.0,
                      ),
                    ),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: _getActionColor(),
                      foregroundColor: Colors.white,
                      elevation: 0,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16),
                      ),
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

  /// Info del rider
  Widget _buildRiderInfoRow() {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
      child: Row(
        children: [
          // Avatar del rider
          VerifiedAvatar(
            photoUrl: widget.riderPhotoUrl.isNotEmpty ? widget.riderPhotoUrl : null,
            radius: 22,
            fallbackName: widget.riderName,
            uid: widget.riderId?.toString(),
            role: 'rider',
            isVerified: true,
          ),
          const SizedBox(width: 12),
          // Nombre y dirección
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  widget.riderName.isNotEmpty ? widget.riderName : S.of(context).passengerFallback,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  widget.phase == 'toPickup' 
                      ? widget.pickupLabel
                      : widget.dropoffLabel,
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.7),
                    fontSize: 13,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          // Botones de contacto
          _buildContactButton(Icons.message_rounded, () {}),
          const SizedBox(width: 8),
          _buildContactButton(Icons.phone_rounded, () {}),
        ],
      ),
    );
  }

  Widget _buildContactButton(IconData icon, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          color: DriverNavigationPanel._cardBorder,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Icon(icon, color: Colors.white70, size: 20),
      ),
    );
  }

  /// Fila de próxima instrucción
  Widget _buildNextInstructionRow(NavInstruction instruction) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          _buildNavIcon(instruction.type, size: 20, color: Colors.grey[600]!),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              instruction.text,
              style: TextStyle(
                color: Colors.grey[700],
                fontSize: 13,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          Text(
            _formatDistance(instruction.distanceMiles),
            style: TextStyle(
              color: Colors.grey[600],
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }

  /// Icono de navegación
  Widget _buildNavIcon(String type, {required double size, Color? color}) {
    final iconColor = color ?? DriverNavigationPanel._green;
    
    IconData iconData;
    switch (type) {
      case 'turn_left':
        iconData = Icons.turn_left_rounded;
        break;
      case 'turn_right':
        iconData = Icons.turn_right_rounded;
        break;
      case 'uturn':
        iconData = Icons.u_turn_left_rounded;
        break;
      case 'roundabout':
        iconData = Icons.roundabout_left_rounded;
        break;
      case 'merge':
        iconData = Icons.merge_rounded;
        break;
      case 'exit':
        iconData = Icons.exit_to_app_rounded;
        break;
      case 'straight':
      default:
        iconData = Icons.straight_rounded;
        break;
    }
    
    return Icon(iconData, color: iconColor, size: size);
  }

  /// Formatear distancia
  String _formatDistance(double miles) {
    if (miles < 0.1) {
      return '${(miles * 5280).toInt()} ft';
    }
    return '${miles.toStringAsFixed(1)} mi';
  }

  /// Color del botón principal según fase
  Color _getActionColor() {
    switch (widget.phase) {
      case 'toPickup':
        return DriverNavigationPanel._green;
      case 'arrivedPickup':
        return DriverNavigationPanel._gold;
      case 'onTrip':
        return DriverNavigationPanel._red;
      case 'arrivedDropoff':
        return DriverNavigationPanel._gold;
      default:
        return DriverNavigationPanel._green;
    }
  }

  /// Texto del botón principal según fase
  String _getActionText() {
    switch (widget.phase) {
      case 'toPickup':
        return 'Llegué al Pickup';
      case 'arrivedPickup':
        return 'Iniciar Viaje';
      case 'onTrip':
        return 'Llegué al Destino';
      case 'arrivedDropoff':
        return 'Finalizar Viaje';
      default:
        return 'Continuar';
    }
  }

  /// Icono del botón principal según fase
  IconData _getActionIcon() {
    switch (widget.phase) {
      case 'toPickup':
        return Icons.check_circle_rounded;
      case 'arrivedPickup':
        return Icons.play_arrow_rounded;
      case 'onTrip':
        return Icons.location_on_rounded;
      case 'arrivedDropoff':
        return Icons.flag_rounded;
      default:
        return Icons.arrow_forward_rounded;
    }
  }

  /// Manejar acción principal
  void _handleMainAction() {
    switch (widget.phase) {
      case 'toPickup':
        widget.onArrived();
        break;
      case 'arrivedPickup':
        widget.onStartTrip();
        break;
      case 'onTrip':
        widget.onArrived();
        break;
      case 'arrivedDropoff':
        widget.onFinishTrip();
        break;
    }
  }

  /// Abrir navegación externa
  Future<void> _launchExternalNavigation() async {
    if (widget.destinationLat == null || widget.destinationLng == null) return;
    
    final url = Uri.parse(
      'https://www.google.com/maps/dir/?api=1&destination=${widget.destinationLat},${widget.destinationLng}&travelmode=driving',
    );
    
    if (await canLaunchUrl(url)) {
      await launchUrl(url, mode: LaunchMode.externalApplication);
    }
  }
}
