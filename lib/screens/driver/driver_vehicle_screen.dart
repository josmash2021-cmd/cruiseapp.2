import 'package:flutter/material.dart';
import '../../utils/vehicle_tier_style.dart';
import '../../widgets/neu_style.dart';
import 'driver_vehicle_detail_screen.dart';
import 'add_vehicle_screen.dart';
import '../../services/haptic_service.dart';
import '../../services/api_service.dart';
import '../../services/user_session.dart';
import '../../config/page_transitions.dart';
import '../../l10n/app_localizations.dart';
import '../home_screen.dart';

/// Vehicle management screen – view car details & upload vehicle documents.
class DriverVehicleScreen extends StatefulWidget {
  const DriverVehicleScreen({super.key});

  @override
  State<DriverVehicleScreen> createState() => _DriverVehicleScreenState();
}

class _DriverVehicleScreenState extends State<DriverVehicleScreen> {
  static const _gold = Color(0xFFE8C547);

  // Multi-vehicle (2026-08-29): the screen lists every vehicle the driver
  // owns. The active one receives trips; pending ones wait on dispatch.
  List<Map<String, dynamic>> _vehicles = const [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _enforceDriverRole();
    _fetchVehicles();
  }

  void _enforceDriverRole() {
    UserSession.getMode().then((mode) {
      if (mode != 'driver' && mounted) {
        Navigator.of(context).pushAndRemoveUntil(
          fadeThroughRoute(const HomeScreen()),
          (_) => false,
        );
      }
    });
  }

  Future<void> _fetchVehicles() async {
    try {
      final results = await Future.wait([
        ApiService.getVehicles(),
        ApiService.getDocuments(),
      ]);
      if (!mounted) return;
      final vehicles = (results[0] as List<dynamic>? ?? [])
          .cast<Map<String, dynamic>>();
      final docs = results[1] as List<dynamic>? ?? [];

      // Map each vehicle id to its document statuses (insurance /
      // registration) so a card can say how many docs are still missing.
      final docsByVehicle = <int, Map<String, String>>{};
      for (final d in docs) {
        final vid = d['vehicle_id'] as int?;
        final type = d['doc_type'] as String? ?? '';
        final status = d['status'] as String? ?? '';
        if (vid == null) continue;
        docsByVehicle.putIfAbsent(vid, () => {});
        final m = docsByVehicle[vid]!;
        if (type == 'insurance' && (m['insurance'] ?? '').isEmpty) {
          m['insurance'] = status;
        }
        if (type == 'registration' && (m['registration'] ?? '').isEmpty) {
          m['registration'] = status;
        }
      }

      setState(() {
        _vehicles = vehicles.map((v) {
          final vid = v['id'] as int? ?? 0;
          final docStatuses = docsByVehicle[vid] ?? {};
          return {
            ...v,
            'insurance_status': docStatuses['insurance'] ?? '',
            'registration_status': docStatuses['registration'] ?? '',
          };
        }).toList();
        _loading = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  /// The driver's own garage art: three-quarter views (driver_tier_*),
  /// shown ONLY on this screen and its detail page. The rider keeps the
  /// side-profile `cruisert*` set — tierCarImage() — everywhere else.
  String _carImageFor(String vehicleType) {
    switch (tierKey(vehicleType)) {
      case kTierBlack:
        return 'assets/images/driver_tier_black.png';
      case kTierPremium:
        return 'assets/images/driver_tier_premium.png';
      case kTierCompact:
        return 'assets/images/driver_tier_compact.png';
      default:
        return 'assets/images/driver_tier_standard.png';
    }
  }

  /// Tier label, colour and icon for ONE vehicle.
  ({String label, Color color, IconData icon}) _tierInfoFor(String vehicleType) => (
        label: tierLabel(vehicleType),
        color: tierColor(vehicleType),
        icon: tierIcon(vehicleType),
      );

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    return Scaffold(
      // The app's own ground, not black. Black is not a neutral here —
      // neumorphic shadows are invisible on it, which is why neuBase is
      // #14141A and not #000000.
      backgroundColor: neuBase,
      body: Stack(
        children: [
          const Positioned.fill(child: NeuDotsBackdrop()),
          _loading
          ? const Center(
              child: CircularProgressIndicator(color: _gold, strokeWidth: 2))
          : Stack(
              children: [
                CustomScrollView(
                  physics: const BouncingScrollPhysics(),
                  slivers: [
                    SliverAppBar(
                      // Same ground as the page, so the colour runs behind
                      // the title instead of stopping at a seam under it.
                      // _surface was #141414 against a black page: near
                      // enough to look like a mistake, far enough to show.
                      backgroundColor: neuBase,
                      surfaceTintColor: neuBase,
                      actions: [
                        // Add a new vehicle — opens the form, not a support
                        // snackbar (2026-08-29 multi-vehicle).
                        Padding(
                          padding: const EdgeInsets.only(right: 12),
                          child: GestureDetector(
                            onTap: () {
                              HapticService.selectionClick();
                              Navigator.of(context)
                                  .push(slideFromRightRoute(
                                      const AddVehicleScreen()))
                                  .then((_) => _fetchVehicles());
                            },
                            child: Container(
                              width: 38,
                              height: 38,
                              decoration: neuBox(radius: 19),
                              child: const Icon(
                                Icons.add_rounded,
                                color: _gold,
                                size: 22,
                              ),
                            ),
                          ),
                        ),
                      ],
                      pinned: true,
                      expandedHeight: 110,
                      leading: IconButton(
                        icon: Container(
                          width: 38,
                          height: 38,
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha: 0.06),
                            shape: BoxShape.circle,
                          ),
                          child: const Icon(Icons.arrow_back_rounded,
                              color: Colors.white, size: 20),
                        ),
                        onPressed: () => Navigator.pop(context),
                      ),
                      centerTitle: true,
                      title: Text(
                        s.vehicleTitle,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 20,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                    ),
                    SliverToBoxAdapter(
                      child: Padding(
                        padding: const EdgeInsets.all(20),
                        child: Column(
                          children: [
                            for (final v in _vehicles) _buildVehicleCard(v),
                            const SizedBox(height: 30),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
        ],
      ),
    );
  }

  // ══════════════════════════════════════════════════════════════════
  //  W I D G E T S
  // ══════════════════════════════════════════════════════════════════

  /// One card per vehicle (2026-08-29 multi-vehicle).
  ///
  /// The card shows the year and name on the left, the plate and colour chip
  /// under them, the car small on the right, and one bottom row that opens
  /// the detail. The active vehicle carries a plain "In use" line; a car
  /// missing paperwork carries "Requires attention"; "Pending approval" is
  /// reserved for a fully-uploaded car still waiting on dispatch.
  Widget _buildVehicleCard(Map<String, dynamic> vehicle) {
    final s = S.of(context);
    final make = (vehicle['make'] ?? '') as String;
    final model = (vehicle['model'] ?? '') as String;
    final year = (vehicle['year'] ?? '').toString();
    final color = (vehicle['color'] ?? '') as String;
    final plate = (vehicle['plate'] ?? '') as String;
    final vehicleType = (vehicle['vehicle_type'] ?? 'comfort') as String;
    final isActive = vehicle['is_active'] == true;
    final approvalStatus = (vehicle['approval_status'] ?? 'pending') as String;
    final insuranceStatus = (vehicle['insurance_status'] ?? '') as String;
    final registrationStatus = (vehicle['registration_status'] ?? '') as String;
    final insuranceValid = vehicle['insurance_valid'] == true;
    final registrationValid = vehicle['registration_valid'] == true;

    final title = '$make $model'.trim();
    final tier = _tierInfoFor(vehicleType);
    final carImage = _carImageFor(vehicleType);

    final missingDocs = (insuranceValid || insuranceStatus == 'pending' ? 0 : 1) +
        (registrationValid || registrationStatus == 'pending' ? 0 : 1);
    final isApproved = approvalStatus == 'approved';
    // Missing paperwork is "Requires attention", never "Pending approval" —
    // the car is waiting on the driver, not on dispatch (user spec
    // 2026-08-29). "Pending approval" is only for a car with everything
    // uploaded that dispatch has not reviewed yet, and it never shows on
    // the car in use: an active car is, by definition, one dispatch lets
    // work, whatever the legacy approval flag says.
    final needsAttention = missingDocs > 0;
    final awaitingReview = !isApproved && !needsAttention && !isActive;

    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      padding: const EdgeInsets.fromLTRB(18, 18, 18, 6),
      decoration: neuBox(radius: 22),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (year.isNotEmpty)
                      Text(
                        year,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 24,
                          fontWeight: FontWeight.w800,
                          height: 1.15,
                          letterSpacing: -0.4,
                        ),
                      ),
                    Text(
                      title.isEmpty ? s.noVehicleOnFile : title,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 24,
                        fontWeight: FontWeight.w800,
                        height: 1.15,
                        letterSpacing: -0.4,
                      ),
                    ),
                    const SizedBox(height: 8),
                    if (plate.isNotEmpty)
                      Row(
                        children: [
                          const Icon(Icons.confirmation_number_rounded,
                              color: Colors.white54, size: 14),
                          const SizedBox(width: 6),
                          Text(
                            plate.toUpperCase(),
                            style: TextStyle(
                              color: Colors.white.withValues(alpha: 0.45),
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                              letterSpacing: 1.1,
                            ),
                          ),
                        ],
                      ),
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        if (color.isNotEmpty)
                          _vehicleChip(null, color, null),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              Column(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(tier.icon, size: 15, color: tier.color),
                      const SizedBox(width: 6),
                      Text(
                        tier.label,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 12.5,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 1.1,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  SizedBox(
                    width: 116,
                    height: 84,
                    child: Image.asset(
                      carImage,
                      fit: BoxFit.contain,
                      errorBuilder: (_, __, ___) => Icon(
                        Icons.directions_car_rounded,
                        color: _gold.withValues(alpha: 0.5),
                        size: 40,
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 10),

          // ── Status badges ──
          if (isActive || awaitingReview || needsAttention)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Wrap(
                spacing: 8,
                runSpacing: 6,
                children: [
                  if (isActive) _inUseLabel(s),
                  if (awaitingReview)
                    _statusBadge(s.pendingApproval, const Color(0xFFFFA726),
                        Icons.hourglass_top_rounded),
                  if (needsAttention)
                    _statusBadge(s.requiresAttention, const Color(0xFFEF5350),
                        Icons.warning_amber_rounded),
                ],
              ),
            ),

          Divider(height: 1, color: Colors.white.withValues(alpha: 0.06)),
          InkWell(
            onTap: () {
              HapticService.selectionClick();
              Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => DriverVehicleDetailScreen(
                    make: make,
                    model: model,
                    year: year,
                    color: color,
                    plate: plate,
                    carImage: carImage,
                    tierLabel: tier.label,
                    tierColor: tier.color,
                    tierIcon: tier.icon,
                    vehicleId: vehicle['id'] as int?,
                    isActive: isActive,
                    approvalStatus: approvalStatus,
                  ),
                ),
              ).then((_) => _fetchVehicles());
            },
            borderRadius: BorderRadius.circular(12),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 14),
              child: Row(
                children: [
                  Icon(
                    Icons.info_outline_rounded,
                    color: Colors.white.withValues(alpha: 0.6),
                    size: 19,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      s.seeDetails,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  Icon(
                    Icons.chevron_right_rounded,
                    color: Colors.white.withValues(alpha: 0.35),
                    size: 22,
                  ),
                ],
              ),
            ),
          ),

          // ── Use button (approved vehicles that are not active) ──
          if (!isActive && isApproved)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: SizedBox(
                width: double.infinity,
                height: 44,
                child: OutlinedButton(
                  onPressed: () => _useVehicle(vehicle['id'] as int),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: _gold,
                    side: const BorderSide(color: _gold, width: 1.2),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  child: Text(
                    s.useThisVehicle,
                    style: const TextStyle(
                        fontSize: 14, fontWeight: FontWeight.w800),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// "In use" is a fact, not an alert: plain text, no pill, no tint
  /// (user spec 2026-08-29).
  Widget _inUseLabel(S s) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.check_circle_rounded,
              size: 13, color: Colors.white.withValues(alpha: 0.55)),
          const SizedBox(width: 6),
          Text(
            s.inUse,
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.55),
              fontSize: 11.5,
              fontWeight: FontWeight.w800,
              letterSpacing: 0.3,
            ),
          ),
        ],
      ),
    );
  }

  Widget _statusBadge(String label, Color color, IconData icon) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 13, color: color),
          const SizedBox(width: 6),
          Text(
            label,
            style: TextStyle(
              color: color,
              fontSize: 11.5,
              fontWeight: FontWeight.w800,
              letterSpacing: 0.3,
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _useVehicle(int vehicleId) async {
    try {
      await ApiService.useVehicle(vehicleId);
      if (mounted) await _fetchVehicles();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(S.of(context).connectionError)),
        );
      }
    }
  }

  Widget _vehicleChip(IconData? icon, String label, Color? accent) {
    final c = accent ?? Colors.white.withValues(alpha: 0.6);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
      decoration: neuBox(radius: 10, pressed: true),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 13, color: c),
            const SizedBox(width: 6),
          ] else ...[
            // Colour chip: a filled circle in the car's own colour (user spec
            // 2026-08-29), not a palette icon.
            Container(
              width: 13,
              height: 13,
              decoration: BoxDecoration(
                color: _colorFromName(label),
                shape: BoxShape.circle,
                border: Border.all(color: Colors.white.withValues(alpha: 0.25)),
              ),
            ),
            const SizedBox(width: 6),
          ],
          Text(
            label,
            style: TextStyle(
              color: c,
              fontSize: 12,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.3,
            ),
          ),
        ],
      ),
    );
  }

  Color _colorFromName(String name) {
    switch (name.toLowerCase()) {
      case 'black': return Colors.black;
      case 'white': return Colors.white;
      case 'silver': return const Color(0xFFC0C0C0);
      case 'gray': return const Color(0xFF808080);
      case 'blue': return Colors.blue;
      case 'red': return Colors.red;
      case 'green': return Colors.green;
      case 'brown': return const Color(0xFF795548);
      case 'beige': return const Color(0xFFF5F5DC);
      case 'gold': return const Color(0xFFFFD700);
      case 'orange': return Colors.orange;
      case 'yellow': return Colors.yellow;
      case 'purple': return Colors.purple;
      case 'pink': return Colors.pink;
      default: return Colors.white54;
    }
  }
}
