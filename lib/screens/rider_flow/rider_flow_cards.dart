import 'package:flutter/material.dart';

import '../../state/rider_trip_controller.dart';

/// Bottom-sheet cards rendered by [RiderFlowShell] for each shell phase.
///
/// These are **presentation-only** widgets — every tap handler talks to
/// the [RiderTripController] passed in from the shell. The cards NEVER
/// own state machine logic; when a rider taps "Request Ride" on the
/// choose-vehicle card, the card calls `ctrl.selectRideOption(...)` +
/// `ctrl.requestRide()` exactly like the old RideRequestScreen does.
///
/// Day 2b (2026-04-11): first pass, minimal but functional versions of
/// each card. Day 5 polish brings them to pixel parity with the
/// existing ride_request_widgets.dart designs.

const _gold = Color(0xFFE8C547);
const _cardBg = Color(0xFF0F1218);
const _cardBorder = Color(0x40E8C547);

BoxDecoration _cardDecoration() => BoxDecoration(
      color: _cardBg,
      borderRadius: BorderRadius.circular(24),
      border: Border.all(color: _cardBorder),
      boxShadow: [
        BoxShadow(
          color: Colors.black.withValues(alpha: 0.55),
          blurRadius: 30,
          offset: const Offset(0, 10),
        ),
      ],
    );

// ═══════════════════════════════════════════════════════════════════
//  P01 · Choose a ride
// ═══════════════════════════════════════════════════════════════════

class ChooseVehicleCard extends StatelessWidget {
  final RiderTripState state;
  final ValueChanged<RideOption> onSelect;
  final VoidCallback onRequest;

  const ChooseVehicleCard({
    super.key,
    required this.state,
    required this.onSelect,
    required this.onRequest,
  });

  @override
  Widget build(BuildContext context) {
    final options = state.rideOptions;
    final selected = state.selectedOption;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 20),
      decoration: _cardDecoration(),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Choose a ride',
            style: TextStyle(
              color: Colors.white,
              fontSize: 18,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 12),
          if (options.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 20),
              child: Center(
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: _gold,
                ),
              ),
            )
          else
            ...options.map((opt) {
              final isSelected = selected?.id == opt.id;
              return Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: InkWell(
                  onTap: () => onSelect(opt),
                  borderRadius: BorderRadius.circular(14),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 12,
                    ),
                    decoration: BoxDecoration(
                      color: isSelected
                          ? _gold.withValues(alpha: 0.12)
                          : const Color(0xFF151820),
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(
                        color: isSelected
                            ? _gold
                            : Colors.white.withValues(alpha: 0.08),
                      ),
                    ),
                    child: Row(
                      children: [
                        Text(
                          opt.icon,
                          style: const TextStyle(fontSize: 24),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                opt.name,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 15,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              Text(
                                opt.description,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: Colors.white.withValues(alpha: 0.55),
                                  fontSize: 11,
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          '\$${opt.priceEstimate.toStringAsFixed(2)}',
                          style: const TextStyle(
                            color: _gold,
                            fontSize: 15,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              );
            }),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            height: 52,
            child: ElevatedButton(
              onPressed: selected == null ? null : onRequest,
              style: ElevatedButton.styleFrom(
                backgroundColor: _gold,
                foregroundColor: Colors.black,
                disabledBackgroundColor: _gold.withValues(alpha: 0.35),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(26),
                ),
                elevation: 0,
              ),
              child: const Text(
                'Request Ride',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════
//  P02 · Confirming your ride…
// ═══════════════════════════════════════════════════════════════════

class ConfirmingPaymentCard extends StatelessWidget {
  const ConfirmingPaymentCard({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(20, 22, 20, 22),
      decoration: _cardDecoration(),
      child: const Row(
        children: [
          SizedBox(
            width: 24,
            height: 24,
            child: CircularProgressIndicator(strokeWidth: 2.4, color: _gold),
          ),
          SizedBox(width: 14),
          Expanded(
            child: Text(
              'Confirming your ride…',
              style: TextStyle(
                color: Colors.white,
                fontSize: 15,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════
//  P03 · Finding the best driver for you…
// ═══════════════════════════════════════════════════════════════════

class SearchingDriverCard extends StatelessWidget {
  final RiderTripState state;
  final VoidCallback onCancel;

  const SearchingDriverCard({
    super.key,
    required this.state,
    required this.onCancel,
  });

  @override
  Widget build(BuildContext context) {
    final from = state.pickupLabel.isNotEmpty ? state.pickupLabel : 'Pickup';
    final to = state.dropoffLabel.isNotEmpty ? state.dropoffLabel : 'Dropoff';
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 20),
      decoration: _cardDecoration(),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: _gold.withValues(alpha: 0.12),
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.directions_car_rounded,
                    color: _gold, size: 22),
              ),
              const SizedBox(width: 12),
              const Expanded(
                child: Text(
                  'Finding the best driver for you…',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: Text(
                  '$from → $to',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.55),
                    fontSize: 12,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          const Divider(color: Color(0x22FFFFFF), height: 1),
          const SizedBox(height: 8),
          Center(
            child: TextButton(
              onPressed: onCancel,
              child: const Text(
                'Cancel',
                style: TextStyle(
                  color: Colors.white70,
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════
//  P04 · Driver found!  (brief celebration)
// ═══════════════════════════════════════════════════════════════════

class DriverFoundCard extends StatelessWidget {
  final RiderTripState state;

  const DriverFoundCard({super.key, required this.state});

  @override
  Widget build(BuildContext context) {
    final name = state.driver?.name ?? 'Your driver';
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(20, 22, 20, 22),
      decoration: _cardDecoration(),
      child: Row(
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: _gold,
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(
                  color: _gold.withValues(alpha: 0.4),
                  blurRadius: 12,
                ),
              ],
            ),
            child: const Icon(Icons.check_rounded,
                color: Colors.black, size: 26),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Driver found!',
                  style: TextStyle(
                    color: _gold,
                    fontSize: 16,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  '$name is on the way',
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.72),
                    fontSize: 13,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════
//  P05 · Driver on the way
// ═══════════════════════════════════════════════════════════════════

class DriverEnRouteCard extends StatelessWidget {
  final RiderTripState state;

  const DriverEnRouteCard({super.key, required this.state});

  @override
  Widget build(BuildContext context) {
    final drv = state.driver;
    final name = drv?.name ?? 'Driver';
    final rating = drv?.rating ?? 0;
    final vehicle = drv == null
        ? ''
        : '${drv.vehicleColor} ${drv.vehicleMake} ${drv.vehicleModel}'.trim();
    final plate = drv?.vehiclePlate ?? '';
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 20),
      decoration: _cardDecoration(),
      child: Row(
        children: [
          Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              color: const Color(0xFF151820),
              shape: BoxShape.circle,
              border: Border.all(color: _gold, width: 2),
            ),
            alignment: Alignment.center,
            child: Text(
              name.isNotEmpty ? name[0].toUpperCase() : '?',
              style: const TextStyle(
                color: _gold,
                fontSize: 20,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 2),
                Row(
                  children: [
                    const Icon(Icons.star_rounded, color: _gold, size: 13),
                    const SizedBox(width: 3),
                    Text(
                      rating > 0 ? rating.toStringAsFixed(1) : 'New driver',
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.62),
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
                if (vehicle.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  Text(
                    '$vehicle${plate.isNotEmpty ? " · $plate" : ""}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.55),
                      fontSize: 12,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}
