import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../services/api_service.dart';
import '../../l10n/app_localizations.dart';
import '../driver/driver_documents_screen.dart';
import '../../config/page_transitions.dart';

/// Vehicle management screen – view and edit car details.
class DriverVehicleScreen extends StatefulWidget {
  const DriverVehicleScreen({super.key});

  @override
  State<DriverVehicleScreen> createState() => _DriverVehicleScreenState();
}

class _DriverVehicleScreenState extends State<DriverVehicleScreen> {
  static const _gold = Color(0xFFE8C547);
  static const _card = Color(0xFF1C1C1E);
  static const _surface = Color(0xFF141414);

  String _make = '';
  String _model = '';
  String _year = '';
  String _color = '';
  String _plate = '';
  String _vehicleType = 'comfort';
  bool _inspectionValid = false;
  bool _insuranceValid = false;
  bool _registrationValid = false;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _fetchVehicle();
  }

  Future<void> _fetchVehicle() async {
    try {
      final v = await ApiService.getVehicle();
      if (!mounted || v == null) return;
      setState(() {
        _make = (v['make'] ?? '') as String;
        _model = (v['model'] ?? '') as String;
        _year = (v['year'] ?? '').toString();
        _color = (v['color'] ?? '') as String;
        _plate = (v['plate'] ?? '') as String;
        _vehicleType = (v['vehicle_type'] ?? 'comfort') as String;
        _inspectionValid = v['inspection_valid'] == true;
        _insuranceValid = v['insurance_valid'] == true;
        _registrationValid = v['registration_valid'] == true;
        _loading = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    return Scaffold(
      backgroundColor: Colors.black,
      body: CustomScrollView(
        physics: const BouncingScrollPhysics(),
        slivers: [
          SliverAppBar(
            backgroundColor: _surface,
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
                child: const Icon(
                  Icons.arrow_back_rounded,
                  color: Colors.white,
                  size: 20,
                ),
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
                  // ── Car visual ──
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(32),
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        colors: [
                          _gold.withValues(alpha: 0.12),
                          Colors.transparent,
                        ],
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                      ),
                      borderRadius: BorderRadius.circular(24),
                      border: Border.all(color: _gold.withValues(alpha: 0.15)),
                    ),
                    child: Column(
                      children: [
                        Container(
                          width: 80,
                          height: 80,
                          decoration: BoxDecoration(
                            color: _gold.withValues(alpha: 0.15),
                            shape: BoxShape.circle,
                          ),
                          child: const Icon(
                            Icons.directions_car_rounded,
                            color: _gold,
                            size: 42,
                          ),
                        ),
                        const SizedBox(height: 16),
                        Text(
                          '$_year $_make $_model',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 22,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 14,
                            vertical: 6,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha: 0.06),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Text(
                            _plate,
                            style: const TextStyle(
                              color: _gold,
                              fontSize: 16,
                              fontWeight: FontWeight.w800,
                              letterSpacing: 2,
                            ),
                          ),
                        ),
                        const SizedBox(height: 12),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            _tag(Icons.palette_rounded, _color),
                            const SizedBox(width: 12),
                            _tag(Icons.category_rounded, _vehicleType),
                          ],
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 24),

                  // ── "Required to go online" banner ──
                  if (!_inspectionValid || !_insuranceValid || !_registrationValid)
                    Container(
                      margin: const EdgeInsets.only(bottom: 16),
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                      decoration: BoxDecoration(
                        color: Colors.red.withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(color: Colors.red.withValues(alpha: 0.4)),
                      ),
                      child: Row(
                        children: [
                          const Icon(Icons.block_rounded, color: Colors.red, size: 22),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Text(
                                  'Required to go online',
                                  style: TextStyle(
                                    color: Colors.red,
                                    fontSize: 15,
                                    fontWeight: FontWeight.w800,
                                  ),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  'Upload all vehicle documents below to activate your driver account.',
                                  style: TextStyle(
                                    color: Colors.white.withValues(alpha: 0.5),
                                    fontSize: 12,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),

                  // ── Inspection status ──
                  _vehicleDocCard(
                    isValid: _inspectionValid,
                    validIcon: Icons.verified_rounded,
                    invalidIcon: Icons.warning_rounded,
                    validColor: const Color(0xFFE8C547),
                    invalidColor: Colors.red,
                    validTitle: s.vehicleInspectionValid,
                    invalidTitle: s.inspectionExpired,
                    validSubtitle: s.nextInspectionDue,
                    invalidSubtitle: 'Required to go online',
                  ),
                  const SizedBox(height: 12),

                  // ── Insurance status ──
                  _vehicleDocCard(
                    isValid: _insuranceValid,
                    validIcon: Icons.security_rounded,
                    invalidIcon: Icons.security_rounded,
                    validColor: const Color(0xFF4CAF50),
                    invalidColor: Colors.red,
                    validTitle: s.vehicleInsuranceValid,
                    invalidTitle: s.insuranceExpiredLabel,
                    validSubtitle: s.insuranceUpToDate,
                    invalidSubtitle: 'Required to go online',
                  ),
                  const SizedBox(height: 12),

                  // ── Registration status ──
                  _vehicleDocCard(
                    isValid: _registrationValid,
                    validIcon: Icons.description_rounded,
                    invalidIcon: Icons.description_rounded,
                    validColor: const Color(0xFF4CAF50),
                    invalidColor: Colors.red,
                    validTitle: 'Registration Valid',
                    invalidTitle: 'Registration Required',
                    validSubtitle: 'Vehicle registration up to date',
                    invalidSubtitle: 'Required to go online',
                  ),
                  const SizedBox(height: 24),

                  // ── Read-only vehicle details (approved) ──
                  _detailRowApproved(s.makeLabel, _make, Icons.directions_car_filled_rounded),
                  _detailRowApproved(s.modelLabel, _model, Icons.local_taxi_rounded),
                  _detailRowApproved(s.yearLabel, _year, Icons.calendar_today_rounded),
                  _detailRowApproved(s.colorLabel, _color, Icons.palette_rounded),
                  _detailRow(s.licensePlate, _plate, Icons.confirmation_number_rounded),
                  // Vehicle type: set by dispatch only
                  _detailRowWithNote(
                    s.typeLabel,
                    _vehicleType.isNotEmpty ? _vehicleType : s.notAssigned,
                    Icons.category_rounded,
                    s.setByDispatch,
                  ),
                  const SizedBox(height: 30),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _tag(IconData icon, String text) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: Colors.white.withValues(alpha: 0.4)),
          const SizedBox(width: 6),
          Text(
            text,
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.6),
              fontSize: 13,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }

  Widget _detailRow(String label, String value, IconData icon) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: _card,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.05),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(
              icon,
              color: Colors.white.withValues(alpha: 0.4),
              size: 18,
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.35),
                    fontSize: 12,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  value,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _vehicleDocCard({
    required bool isValid,
    required IconData validIcon,
    required IconData invalidIcon,
    required Color validColor,
    required Color invalidColor,
    required String validTitle,
    required String invalidTitle,
    required String validSubtitle,
    required String invalidSubtitle,
  }) {
    return GestureDetector(
      onTap: () {
        HapticFeedback.selectionClick();
        Navigator.push(
          context,
          slideFromRightRoute(const DriverDocumentsScreen()),
        );
      },
      child: Container(
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(
          color: isValid
              ? validColor.withValues(alpha: 0.08)
              : invalidColor.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(
            color: isValid
                ? validColor.withValues(alpha: 0.25)
                : invalidColor.withValues(alpha: 0.4),
          ),
        ),
        child: Row(
          children: [
            Icon(
              isValid ? validIcon : invalidIcon,
              color: isValid ? validColor : invalidColor,
              size: 24,
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    isValid ? validTitle : invalidTitle,
                    style: TextStyle(
                      color: isValid ? validColor : invalidColor,
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    isValid ? validSubtitle : invalidSubtitle,
                    style: TextStyle(
                      color: isValid
                          ? Colors.white.withValues(alpha: 0.4)
                          : invalidColor.withValues(alpha: 0.7),
                      fontSize: 12,
                      fontWeight: isValid ? FontWeight.w400 : FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
            Icon(
              isValid ? Icons.check_circle_rounded : Icons.chevron_right_rounded,
              color: isValid ? validColor.withValues(alpha: 0.6) : Colors.white38,
              size: 20,
            ),
          ],
        ),
      ),
    );
  }

  Widget _detailRowApproved(String label, String value, IconData icon) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: _card,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.05),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(
              icon,
              color: Colors.white.withValues(alpha: 0.4),
              size: 18,
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.35),
                    fontSize: 12,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  value,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: const Color(0xFF4CAF50).withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.check_circle_rounded, size: 12, color: const Color(0xFF4CAF50)),
                const SizedBox(width: 4),
                const Text(
                  'Approved',
                  style: TextStyle(
                    color: Color(0xFF4CAF50),
                    fontSize: 10,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _detailRowWithNote(
    String label,
    String value,
    IconData icon,
    String note,
  ) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: _card,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.05),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(icon, color: Colors.white.withValues(alpha: 0.4), size: 18),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.35),
                    fontSize: 12,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  value,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.06),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              note,
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.35),
                fontSize: 10,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
