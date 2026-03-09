import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../services/api_service.dart';
import '../../l10n/app_localizations.dart';

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
  String _vin = '';
  String _vehicleType = 'Sedan';
  bool _inspectionValid = false;
  bool _loading = true;
  bool _saving = false;

  bool _isEditing = false;
  late TextEditingController _makeCtrl;
  late TextEditingController _modelCtrl;
  late TextEditingController _yearCtrl;
  late TextEditingController _colorCtrl;
  late TextEditingController _plateCtrl;

  @override
  void initState() {
    super.initState();
    _makeCtrl = TextEditingController();
    _modelCtrl = TextEditingController();
    _yearCtrl = TextEditingController();
    _colorCtrl = TextEditingController();
    _plateCtrl = TextEditingController();
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
        _vin = (v['vin'] ?? '') as String;
        _vehicleType = (v['vehicle_type'] ?? 'Sedan') as String;
        _inspectionValid = v['inspection_valid'] == true;
        _makeCtrl.text = _make;
        _modelCtrl.text = _model;
        _yearCtrl.text = _year;
        _colorCtrl.text = _color;
        _plateCtrl.text = _plate;
        _loading = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  void dispose() {
    _makeCtrl.dispose();
    _modelCtrl.dispose();
    _yearCtrl.dispose();
    _colorCtrl.dispose();
    _plateCtrl.dispose();
    super.dispose();
  }

  Future<void> _saveChanges() async {
    HapticFeedback.mediumImpact();
    setState(() => _saving = true);
    try {
      await ApiService.saveVehicle(
        make: _makeCtrl.text,
        model: _modelCtrl.text,
        year: int.tryParse(_yearCtrl.text) ?? 0,
        color: _colorCtrl.text,
        plate: _plateCtrl.text,
        vin: _vin,
        vehicleType: _vehicleType,
      );
      if (!mounted) return;
      setState(() {
        _make = _makeCtrl.text;
        _model = _modelCtrl.text;
        _year = _yearCtrl.text;
        _color = _colorCtrl.text;
        _plate = _plateCtrl.text;
        _isEditing = false;
        _saving = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(S.of(context).vehicleInfoUpdated),
          backgroundColor: _gold,
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(S.of(context).failedToSave(e.toString())),
          backgroundColor: Colors.red,
          behavior: SnackBarBehavior.floating,
        ),
      );
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
            actions: [
              Padding(
                padding: const EdgeInsets.only(right: 12),
                child: IconButton(
                  onPressed: () {
                    if (_isEditing) {
                      _saveChanges();
                    } else {
                      setState(() => _isEditing = true);
                    }
                  },
                  icon: Container(
                    width: 38,
                    height: 38,
                    decoration: BoxDecoration(
                      color: _isEditing
                          ? _gold.withValues(alpha: 0.15)
                          : Colors.white.withValues(alpha: 0.06),
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      _isEditing ? Icons.check_rounded : Icons.edit_rounded,
                      color: _isEditing ? _gold : Colors.white,
                      size: 18,
                    ),
                  ),
                ),
              ),
            ],
            flexibleSpace: FlexibleSpaceBar(
              titlePadding: const EdgeInsets.only(left: 56, bottom: 16),
              title: Text(
                s.vehicleTitle,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 20,
                  fontWeight: FontWeight.w900,
                ),
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

                  // ── Inspection status ──
                  Container(
                    padding: const EdgeInsets.all(18),
                    decoration: BoxDecoration(
                      color: _inspectionValid
                          ? const Color(0xFFE8C547).withValues(alpha: 0.08)
                          : Colors.white.withValues(alpha: 0.08),
                      borderRadius: BorderRadius.circular(18),
                      border: Border.all(
                        color: _inspectionValid
                            ? const Color(0xFFE8C547).withValues(alpha: 0.2)
                            : Colors.white.withValues(alpha: 0.2),
                      ),
                    ),
                    child: Row(
                      children: [
                        Icon(
                          _inspectionValid
                              ? Icons.verified_rounded
                              : Icons.warning_rounded,
                          color: _inspectionValid
                              ? const Color(0xFFE8C547)
                              : Colors.white.withValues(alpha: 0.5),
                          size: 24,
                        ),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                _inspectionValid
                                    ? s.vehicleInspectionValid
                                    : s.inspectionExpired,
                                style: TextStyle(
                                  color: _inspectionValid
                                      ? const Color(0xFFE8C547)
                                      : Colors.white.withValues(alpha: 0.5),
                                  fontSize: 15,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                _inspectionValid
                                    ? s.nextInspectionDue
                                    : s.scheduleNewInspection,
                                style: TextStyle(
                                  color: Colors.white.withValues(alpha: 0.4),
                                  fontSize: 12,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 24),

                  // ── Details ──
                  if (!_isEditing) ...[
                    _detailRow(
                      s.makeLabel,
                      _make,
                      Icons.directions_car_filled_rounded,
                    ),
                    _detailRow(s.modelLabel, _model, Icons.local_taxi_rounded),
                    _detailRow(
                      s.yearLabel,
                      _year,
                      Icons.calendar_today_rounded,
                    ),
                    _detailRow(s.colorLabel, _color, Icons.palette_rounded),
                    _detailRow(
                      s.licensePlate,
                      _plate,
                      Icons.confirmation_number_rounded,
                    ),
                    _detailRow(s.vinLabel, _vin, Icons.qr_code_rounded),
                    _detailRow(
                      s.typeLabel,
                      _vehicleType,
                      Icons.category_rounded,
                    ),
                  ] else ...[
                    const SizedBox(height: 8),
                    _editField(
                      s.makeLabel,
                      _makeCtrl,
                      Icons.directions_car_filled_rounded,
                    ),
                    _editField(
                      s.modelLabel,
                      _modelCtrl,
                      Icons.local_taxi_rounded,
                    ),
                    _editField(
                      s.yearLabel,
                      _yearCtrl,
                      Icons.calendar_today_rounded,
                      keyboard: TextInputType.number,
                    ),
                    _editField(s.colorLabel, _colorCtrl, Icons.palette_rounded),
                    _editField(
                      s.licensePlate,
                      _plateCtrl,
                      Icons.confirmation_number_rounded,
                    ),
                    const SizedBox(height: 20),
                    SizedBox(
                      width: double.infinity,
                      height: 56,
                      child: ElevatedButton(
                        onPressed: _saveChanges,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: _gold,
                          foregroundColor: Colors.black,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(16),
                          ),
                        ),
                        child: Text(
                          s.saveChanges,
                          style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 10),
                    TextButton(
                      onPressed: () {
                        _makeCtrl.text = _make;
                        _modelCtrl.text = _model;
                        _yearCtrl.text = _year;
                        _colorCtrl.text = _color;
                        _plateCtrl.text = _plate;
                        setState(() => _isEditing = false);
                      },
                      child: Text(
                        s.cancel,
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.4),
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
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

  Widget _editField(
    String label,
    TextEditingController ctrl,
    IconData icon, {
    TextInputType keyboard = TextInputType.text,
  }) {
    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      child: TextFormField(
        controller: ctrl,
        keyboardType: keyboard,
        style: const TextStyle(
          color: Colors.white,
          fontWeight: FontWeight.w600,
        ),
        decoration: InputDecoration(
          labelText: label,
          labelStyle: TextStyle(color: Colors.white.withValues(alpha: 0.35)),
          prefixIcon: Padding(
            padding: const EdgeInsets.only(left: 14, right: 10),
            child: Icon(icon, color: _gold, size: 20),
          ),
          prefixIconConstraints: const BoxConstraints(minWidth: 48),
          filled: true,
          fillColor: _card,
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 20,
            vertical: 16,
          ),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(16),
            borderSide: BorderSide.none,
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(16),
            borderSide: BorderSide(color: _gold.withValues(alpha: 0.5)),
          ),
        ),
      ),
    );
  }
}
