import 'package:flutter/material.dart';

import '../../../data/vehicle_catalog.dart';
import '../../../l10n/app_localizations.dart';
import '../../../services/api_service.dart';
import 'onboarding_widgets.dart';

/// "Add your vehicle" capture — year/make/model/color from the curated
/// catalogs in `lib/data/vehicle_catalog.dart`. Model is a dropdown when
/// the make has a curated list, free text otherwise. Save posts to
/// `/auth/onboarding-items/vehicle`.
class VehicleCaptureScreen extends StatefulWidget {
  const VehicleCaptureScreen({super.key});

  @override
  State<VehicleCaptureScreen> createState() => _VehicleCaptureScreenState();
}

class _VehicleCaptureScreenState extends State<VehicleCaptureScreen> {
  final _modelCtrl = TextEditingController();
  int? _year;
  String? _make;
  String? _model;
  String? _color;
  bool _saving = false;

  @override
  void dispose() {
    _modelCtrl.dispose();
    super.dispose();
  }

  List<String>? get _modelsForMake =>
      _make == null ? null : vehicleModels[_make!];

  String? get _effectiveModel {
    final models = _modelsForMake;
    if (models != null) return _model;
    final free = _modelCtrl.text.trim();
    return free.isEmpty ? null : free;
  }

  bool get _valid =>
      _year != null &&
      _make != null &&
      _effectiveModel != null &&
      _color != null;

  Future<void> _save() async {
    if (!_valid || _saving) return;
    final s = S.of(context);
    setState(() => _saving = true);
    try {
      await ApiService.submitOnboardingVehicle(
        year: _year!,
        make: _make!,
        model: _effectiveModel!,
        color: _color!,
      );
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      showOnboardingError(context, e.message);
    } catch (_) {
      if (!mounted) return;
      setState(() => _saving = false);
      showOnboardingError(context, s.connectionError);
    }
  }

  @override
  Widget build(BuildContext context) {
    final pad = MediaQuery.of(context).padding;
    final s = S.of(context);
    final models = _modelsForMake;

    return Scaffold(
      backgroundColor: kOnboardingNavy,
      appBar: AppBar(
        backgroundColor: kOnboardingNavy,
        elevation: 0,
        leading: IconButton(
          onPressed: () => Navigator.of(context).pop(),
          icon: const Icon(Icons.close_rounded, color: Colors.white),
        ),
        title: Text(
          s.obVehicleScreenTitle,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 18,
            fontWeight: FontWeight.w700,
          ),
        ),
        centerTitle: true,
      ),
      body: Column(
        children: [
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(24, 16, 24, 16),
              child: Column(
                children: [
                  OnboardingDropdown<int>(
                    label: s.obVehicleYear,
                    value: _year,
                    items: vehicleYears(),
                    onChanged: (v) => setState(() => _year = v),
                  ),
                  const SizedBox(height: 16),
                  OnboardingDropdown<String>(
                    label: s.obVehicleMake,
                    value: _make,
                    items: vehicleMakes,
                    onChanged: (v) => setState(() {
                      _make = v;
                      _model = null;
                      _modelCtrl.clear();
                    }),
                  ),
                  const SizedBox(height: 16),
                  if (models != null)
                    OnboardingDropdown<String>(
                      label: s.obVehicleModel,
                      value: _model,
                      items: models,
                      onChanged: (v) => setState(() => _model = v),
                    )
                  else
                    OnboardingField(
                      controller: _modelCtrl,
                      label: s.obVehicleModel,
                      textCapitalization: TextCapitalization.words,
                      onChanged: (_) => setState(() {}),
                    ),
                  const SizedBox(height: 16),
                  OnboardingDropdown<String>(
                    label: s.obVehicleColor,
                    value: _color,
                    items: vehicleColors,
                    onChanged: (v) => setState(() => _color = v),
                  ),
                ],
              ),
            ),
          ),
          Padding(
            padding: EdgeInsets.fromLTRB(24, 8, 24, pad.bottom + 16),
            child: OnboardingGoldButton(
              label: s.save,
              loading: _saving,
              onTap: _valid ? _save : null,
            ),
          ),
        ],
      ),
    );
  }
}
