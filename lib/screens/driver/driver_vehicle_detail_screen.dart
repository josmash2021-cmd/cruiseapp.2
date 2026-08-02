import 'package:flutter/material.dart';

import '../../config/page_transitions.dart';
import '../../l10n/app_localizations.dart';
import '../../services/haptic_service.dart';
import '../../widgets/neu_style.dart';
import 'driver_documents_screen.dart';

/// One vehicle, in full.
///
/// Three questions in the order a driver asks them: what car is this, what
/// work can it take, and what can I do about it. The list screen answers
/// the first in a line; this is where the rest lives, so the list can stay
/// a list.
class DriverVehicleDetailScreen extends StatelessWidget {
  const DriverVehicleDetailScreen({
    super.key,
    required this.make,
    required this.model,
    required this.year,
    required this.color,
    required this.plate,
    required this.carImage,
    required this.tierLabel,
    required this.tierColor,
    required this.tierIcon,
  });

  final String make;
  final String model;
  final String year;
  final String color;
  final String plate;
  final String carImage;
  final String tierLabel;
  final Color tierColor;
  final IconData tierIcon;

  static const _gold = Color(0xFFE8C547);

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    return Scaffold(
      backgroundColor: neuBase,
      appBar: AppBar(
        backgroundColor: neuBase,
        elevation: 0,
        scrolledUnderElevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_rounded, color: Colors.white),
          onPressed: () => Navigator.pop(context),
        ),
      ),
      body: ListView(
        physics: const BouncingScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 40),
        children: [
          _header(s),
          const SizedBox(height: 26),
          _rideTypes(s),
          const SizedBox(height: 26),
          _manage(context, s),
        ],
      ),
    );
  }

  /// Make small above the model, the facts stacked under it, the car to
  /// the right — the same reading order as the card that opened this.
  Widget _header(S s) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: neuBox(radius: 22),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (make.isNotEmpty)
                  Text(
                    make.toUpperCase(),
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.45),
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 1.2,
                    ),
                  ),
                const SizedBox(height: 2),
                Text(
                  model.isEmpty ? '—' : model,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 26,
                    fontWeight: FontWeight.w800,
                    letterSpacing: -0.5,
                  ),
                ),
                const SizedBox(height: 14),
                _fact(
                  Icons.directions_car_rounded,
                  [year, color.toUpperCase()]
                      .where((v) => v.isNotEmpty)
                      .join('  '),
                ),
                if (plate.isNotEmpty)
                  _fact(Icons.confirmation_number_rounded, plate.toUpperCase()),
                _fact(tierIcon, tierLabel.toUpperCase(), tint: tierColor),
              ],
            ),
          ),
          const SizedBox(width: 10),
          SizedBox(
            width: 128,
            height: 96,
            child: Image.asset(
              carImage,
              fit: BoxFit.contain,
              errorBuilder: (_, __, ___) => Icon(
                Icons.directions_car_rounded,
                color: _gold.withValues(alpha: 0.5),
                size: 44,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _fact(IconData icon, String text, {Color? tint}) {
    if (text.trim().isEmpty) return const SizedBox.shrink();
    final c = tint ?? Colors.white.withValues(alpha: 0.75);
    return Padding(
      padding: const EdgeInsets.only(bottom: 7),
      child: Row(
        children: [
          Icon(icon, size: 16, color: c),
          const SizedBox(width: 10),
          Flexible(
            child: Text(
              text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: c,
                fontSize: 14,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.3,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// What this car is allowed to carry.
  ///
  /// The tier is decided by the vehicle on file, not by anything the
  /// driver can toggle here, so this states it rather than offering it.
  Widget _rideTypes(S s) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          s.availableRideTypes,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 19,
            fontWeight: FontWeight.w800,
            letterSpacing: -0.3,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          s.rideTypesSubject,
          style: TextStyle(
            color: Colors.white.withValues(alpha: 0.45),
            fontSize: 13.5,
            height: 1.45,
          ),
        ),
        const SizedBox(height: 14),
        Container(
          padding: const EdgeInsets.all(16),
          decoration: neuBox(radius: 20),
          child: Row(
            children: [
              Container(
                width: 42,
                height: 42,
                decoration: neuBox(radius: 13, pressed: true),
                child: Icon(tierIcon, color: tierColor, size: 20),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      tierLabel,
                      style: TextStyle(
                        color: tierColor,
                        fontSize: 16,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      s.tierFromYourVehicle,
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.45),
                        fontSize: 12.5,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _manage(BuildContext context, S s) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          s.manageCar,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 19,
            fontWeight: FontWeight.w800,
            letterSpacing: -0.3,
          ),
        ),
        const SizedBox(height: 14),
        Container(
          decoration: neuBox(radius: 20),
          child: Column(
            children: [
              // This used to pop the screen. A row that says "view
              // documents" and closes the page instead is not a missing
              // feature, it is a wrong one.
              _manageRow(
                context,
                Icons.description_outlined,
                s.viewDocuments,
                () => Navigator.of(context).push(
                  slideFromRightRoute(const DriverDocumentsScreen()),
                ),
              ),
              Divider(
                height: 1,
                indent: 62,
                color: Colors.white.withValues(alpha: 0.05),
              ),
              // Removing a car is not something to do by accident, and it
              // is not something this screen can undo, so it asks first.
              _manageRow(
                context,
                Icons.delete_outline_rounded,
                s.removeVehicle,
                () => _confirmRemove(context, s),
                danger: true,
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _manageRow(
    BuildContext context,
    IconData icon,
    String label,
    VoidCallback onTap, {
    bool danger = false,
  }) {
    final c = danger ? const Color(0xFFE57373) : Colors.white;
    return InkWell(
      onTap: () {
        HapticService.selectionClick();
        onTap();
      },
      borderRadius: BorderRadius.circular(20),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
        child: Row(
          children: [
            Container(
              width: 34,
              height: 34,
              decoration: neuBox(radius: 11, pressed: true),
              child: Icon(icon, size: 17, color: danger ? c : _gold),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                label,
                style: TextStyle(
                  color: c,
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            Icon(
              Icons.chevron_right_rounded,
              color: Colors.white.withValues(alpha: 0.3),
              size: 22,
            ),
          ],
        ),
      ),
    );
  }

  void _confirmRemove(BuildContext context, S s) {
    showDialog<void>(
      context: context,
      builder: (dctx) => AlertDialog(
        backgroundColor: neuSurface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
        ),
        title: Text(
          s.removeVehicle,
          style: const TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.w800,
          ),
        ),
        content: Text(
          s.removeVehicleAsk,
          style: TextStyle(color: Colors.white.withValues(alpha: 0.6)),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dctx),
            child: Text(
              s.cancel,
              style: TextStyle(color: Colors.white.withValues(alpha: 0.6)),
            ),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(dctx);
              // Removing the car a driver works from takes their documents
              // and their tier with it, so it goes through support rather
              // than a tap on this screen.
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text(s.removeVehicleContactSupport)),
              );
            },
            child: const Text(
              'OK',
              style: TextStyle(
                color: Color(0xFFE57373),
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
