import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../services/api_service.dart';
import '../../widgets/neu_style.dart';

/// "Add Personal Vehicle" — 2026-08-29 multi-vehicle flow.
///
/// Dropdowns for year / make / model / color / doors / seatbelts. The
/// Continue button stays disabled until every field is filled, then saves
/// via POST /drivers/vehicles. The tier is classified on the backend from
/// make+model+year — the driver never picks it here.
class AddVehicleScreen extends StatefulWidget {
  const AddVehicleScreen({super.key});

  @override
  State<AddVehicleScreen> createState() => _AddVehicleScreenState();
}

class _AddVehicleScreenState extends State<AddVehicleScreen> {
  static const _gold = Color(0xFFE8C547);

  String? _year;
  String? _make;
  String? _model;
  String? _color;
  int? _doors;
  int? _seatbelts;

  bool _saving = false;

  // Same car data as the signup step — kept local so this screen does not
  // depend on the signup widget file.
  static const List<String> _makes = [
    'Acura', 'Alfa Romeo', 'Audi', 'BMW', 'Buick', 'Cadillac', 'Chevrolet',
    'Chrysler', 'Dodge', 'Fiat', 'Ford', 'Genesis', 'GMC', 'Honda',
    'Hyundai', 'Infiniti', 'Jaguar', 'Jeep', 'Kia', 'Land Rover', 'Lexus',
    'Lincoln', 'Maserati', 'Mazda', 'Mercedes-Benz', 'Mini', 'Mitsubishi',
    'Nissan', 'Porsche', 'Ram', 'Subaru', 'Tesla', 'Toyota', 'Volkswagen',
    'Volvo',
  ];

  static const Map<String, List<String>> _models = {
    'Acura': ['ILX', 'Integra', 'MDX', 'RDX', 'TLX'],
    'Alfa Romeo': ['Giulia', 'Stelvio', 'Tonale'],
    'Audi': ['A3', 'A4', 'A5', 'A6', 'A7', 'A8', 'Q3', 'Q5', 'Q7', 'Q8', 'e-tron', 'TT'],
    'BMW': ['2 Series', '3 Series', '4 Series', '5 Series', '7 Series', 'X1', 'X2', 'X3', 'X4', 'X5', 'X6', 'X7', 'iX', 'Z4'],
    'Buick': ['Enclave', 'Encore', 'Envision', 'Envista'],
    'Cadillac': ['CT4', 'CT5', 'Escalade', 'Lyriq', 'XT4', 'XT5', 'XT6'],
    'Chevrolet': ['Blazer', 'Camaro', 'Colorado', 'Corvette', 'Equinox', 'Impala', 'Malibu', 'Silverado', 'Suburban', 'Tahoe', 'Trailblazer', 'Traverse', 'Trax'],
    'Chrysler': ['300', 'Pacifica', 'Voyager'],
    'Dodge': ['Challenger', 'Charger', 'Durango', 'Hornet'],
    'Fiat': ['500', '500X'],
    'Ford': ['Bronco', 'EcoSport', 'Edge', 'Escape', 'Expedition', 'Explorer', 'F-150', 'F-250', 'F-350', 'Fusion', 'Maverick', 'Mustang', 'Ranger', 'Transit'],
    'Genesis': ['G70', 'G80', 'G90', 'GV70', 'GV80'],
    'GMC': ['Acadia', 'Canyon', 'Sierra', 'Terrain', 'Yukon'],
    'Honda': ['Accord', 'Civic', 'CR-V', 'HR-V', 'Odyssey', 'Passport', 'Pilot', 'Ridgeline'],
    'Hyundai': ['Elantra', 'Ioniq', 'Kona', 'Palisade', 'Santa Fe', 'Santa Cruz', 'Sonata', 'Tucson'],
    'Infiniti': ['Q50', 'Q60', 'QX50', 'QX55', 'QX60', 'QX80'],
    'Jaguar': ['E-Pace', 'F-Pace', 'I-Pace', 'XF'],
    'Jeep': ['Cherokee', 'Compass', 'Gladiator', 'Grand Cherokee', 'Renegade', 'Wrangler'],
    'Kia': ['EV6', 'Forte', 'K5', 'Niro', 'Seltos', 'Sorento', 'Sportage', 'Telluride'],
    'Land Rover': ['Defender', 'Discovery', 'Discovery Sport', 'Range Rover', 'Range Rover Evoque', 'Range Rover Sport', 'Range Rover Velar'],
    'Lexus': ['ES', 'GX', 'IS', 'LX', 'NX', 'RX', 'UX'],
    'Lincoln': ['Aviator', 'Corsair', 'Nautilus', 'Navigator'],
    'Maserati': ['Ghibli', 'Grecale', 'Levante', 'Quattroporte'],
    'Mazda': ['CX-30', 'CX-5', 'CX-50', 'CX-9', 'Mazda3', 'Mazda6', 'MX-5 Miata'],
    'Mercedes-Benz': ['A-Class', 'C-Class', 'E-Class', 'GLA', 'GLB', 'GLC', 'GLE', 'GLS', 'S-Class'],
    'Mini': ['Clubman', 'Cooper', 'Countryman'],
    'Mitsubishi': ['Eclipse Cross', 'Outlander', 'Outlander Sport'],
    'Nissan': ['Altima', 'Armada', 'Frontier', 'Kicks', 'Leaf', 'Maxima', 'Murano', 'Pathfinder', 'Rogue', 'Sentra', 'Titan', 'Versa'],
    'Porsche': ['911', 'Cayenne', 'Macan', 'Panamera', 'Taycan'],
    'Ram': ['1500', '2500', '3500', 'ProMaster'],
    'Subaru': ['Ascent', 'Crosstrek', 'Forester', 'Impreza', 'Legacy', 'Outback'],
    'Tesla': ['Model 3', 'Model S', 'Model X', 'Model Y'],
    'Toyota': ['4Runner', 'Avalon', 'Camry', 'Corolla', 'Highlander', 'Prius', 'RAV4', 'Sienna', 'Tacoma', 'Tundra', 'Venza'],
    'Volkswagen': ['Atlas', 'Golf', 'ID.4', 'Jetta', 'Passat', 'Tiguan'],
    'Volvo': ['S60', 'S90', 'XC40', 'XC60', 'XC90'],
  };

  static const List<String> _colors = [
    'Black', 'White', 'Silver', 'Gray', 'Blue', 'Red', 'Green',
    'Brown', 'Beige', 'Gold', 'Orange', 'Yellow', 'Purple', 'Pink',
  ];

  static List<String> get _years {
    final current = DateTime.now().year;
    return List.generate(current - 2011, (i) => (current - i).toString());
  }

  static const List<int> _doorsOptions = [2, 3, 4, 5];
  static const List<int> _seatbeltsOptions = [2, 4, 5, 6, 7, 8];

  bool get _formComplete =>
      _year != null &&
      _make != null &&
      _model != null &&
      _color != null &&
      _doors != null &&
      _seatbelts != null;

  Future<void> _save() async {
    if (!_formComplete || _saving) return;
    setState(() => _saving = true);
    try {
      final year = int.tryParse(_year!);
      if (year == null) throw Exception('Invalid year');
      final res = await ApiService.addVehicle(
        make: _make!,
        model: _model!,
        year: year,
        color: _color!,
        plate: '', // plate is collected on the documents step
        doors: _doors,
        seatbelts: _seatbelts,
      );
      if (!mounted) return;
      Navigator.of(context).pop(res['vehicle'] as Map<String, dynamic>?);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(S.of(context).connectionError),
          behavior: SnackBarBehavior.floating,
        ),
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Widget _dropdown<T>({
    required String label,
    required T? value,
    required List<T> items,
    required void Function(T?) onChanged,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      decoration: neuBox(radius: 14, pressed: true),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<T>(
          value: value,
          hint: Text(
            label,
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.45),
              fontSize: 15,
              fontWeight: FontWeight.w600,
            ),
          ),
          isExpanded: true,
          dropdownColor: const Color(0xFF1A1A1F),
          icon: const Icon(Icons.keyboard_arrow_down_rounded,
              color: Colors.white54),
          style: const TextStyle(color: Colors.white, fontSize: 15),
          onChanged: onChanged,
          menuMaxHeight: 320, // scrollable — no more page-long lists
          items: items
              .map((item) => DropdownMenuItem<T>(
                    value: item,
                    child: Text(item.toString()),
                  ))
              .toList(),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final models = _make != null ? (_models[_make!] ?? const []) : const <String>[];

    return Scaffold(
      backgroundColor: neuBase,
      body: Stack(
        children: [
          const Positioned.fill(child: NeuDotsBackdrop()),
          SafeArea(
            child: Column(
              children: [
                // ── Top row: close / title ──
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
                  child: Row(
                    children: [
                      GestureDetector(
                        onTap: () => Navigator.of(context).pop(),
                        child: Container(
                          width: 38,
                          height: 38,
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha: 0.06),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: const Icon(Icons.close_rounded,
                              color: Colors.white, size: 20),
                        ),
                      ),
                      Expanded(
                        child: Center(
                          child: Text(
                            s.addVehicleTitle,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 17,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 38),
                    ],
                  ),
                ),
                const SizedBox(height: 20),

                // ── Form ──
                Expanded(
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
                    children: [
                      _dropdown<String>(
                        label: s.vehicleYear,
                        value: _year,
                        items: _years,
                        onChanged: (v) => setState(() => _year = v),
                      ),
                      const SizedBox(height: 14),
                      _dropdown<String>(
                        label: s.vehicleMake,
                        value: _make,
                        items: _makes,
                        onChanged: (v) => setState(() {
                          _make = v;
                          _model = null;
                        }),
                      ),
                      const SizedBox(height: 14),
                      _dropdown<String>(
                        label: s.vehicleModel,
                        value: _model,
                        items: models,
                        onChanged: (v) => setState(() => _model = v),
                      ),
                      const SizedBox(height: 14),
                      _dropdown<String>(
                        label: s.vehicleColor,
                        value: _color,
                        items: _colors,
                        onChanged: (v) => setState(() => _color = v),
                      ),
                      const SizedBox(height: 14),
                      _dropdown<int>(
                        label: s.vehicleDoors,
                        value: _doors,
                        items: _doorsOptions,
                        onChanged: (v) => setState(() => _doors = v),
                      ),
                      const SizedBox(height: 14),
                      _dropdown<int>(
                        label: s.vehicleSeatbelts,
                        value: _seatbelts,
                        items: _seatbeltsOptions,
                        onChanged: (v) => setState(() => _seatbelts = v),
                      ),
                    ],
                  ),
                ),

                // ── Continue button ──
                Padding(
                  padding: EdgeInsets.fromLTRB(
                      24, 0, 24, 24 + MediaQuery.viewPaddingOf(context).bottom),
                  child: SizedBox(
                    width: double.infinity,
                    height: 54,
                    child: ElevatedButton(
                      onPressed: _formComplete && !_saving ? _save : null,
                      style: ElevatedButton.styleFrom(
                        backgroundColor:
                            _formComplete ? _gold : Colors.white.withValues(alpha: 0.08),
                        foregroundColor:
                            _formComplete ? Colors.black : Colors.white38,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(16),
                        ),
                        elevation: 0,
                      ),
                      child: _saving
                          ? const SizedBox(
                              width: 22,
                              height: 22,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                valueColor:
                                    AlwaysStoppedAnimation<Color>(Colors.black),
                              ),
                            )
                          : Text(
                              s.continueLabel,
                              style: const TextStyle(
                                  fontSize: 16, fontWeight: FontWeight.w800),
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
}
