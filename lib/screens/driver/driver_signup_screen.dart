import 'dart:convert';
import 'dart:io' if (dart.library.html) 'dart:io';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import '../../l10n/app_localizations.dart';

import '../../config/page_transitions.dart';
import '../../services/api_service.dart';
import '../../services/local_data_service.dart';
import '../../services/user_session.dart';
import '../face_liveness_screen.dart';
import 'driver_pending_review_screen.dart';
import 'license_scanner_screen.dart';

/// Multi-step driver sign-up + verification flow.
///
///  Step 0 — Personal information
///  Step 1 — Vehicle details
///  Step 2 — Documents & biometrics
///    • Driver's license (FRONT)
///    • Driver's license (BACK)
///    • Car insurance photo
///    • SSN (for Checkr background check)
///    • Face biometric liveness check
///  Step 3 — Review & submit
class DriverSignupScreen extends StatefulWidget {
  const DriverSignupScreen({super.key});

  @override
  State<DriverSignupScreen> createState() => _DriverSignupScreenState();
}

class _DriverSignupScreenState extends State<DriverSignupScreen>
    with TickerProviderStateMixin {
  static const _gold = Color(0xFFE8C547);
  static const _goldLight = Color(0xFFF5D990);

  // ── Vehicle autocomplete data ─────────────────────────────────────────────
  static const _carMakes = [
    'Acura',
    'Alfa Romeo',
    'Audi',
    'BMW',
    'Buick',
    'Cadillac',
    'Chevrolet',
    'Chrysler',
    'Dodge',
    'Fiat',
    'Ford',
    'Genesis',
    'GMC',
    'Honda',
    'Hyundai',
    'Infiniti',
    'Jaguar',
    'Jeep',
    'Kia',
    'Land Rover',
    'Lexus',
    'Lincoln',
    'Maserati',
    'Mazda',
    'Mercedes-Benz',
    'Mini',
    'Mitsubishi',
    'Nissan',
    'Porsche',
    'Ram',
    'Subaru',
    'Tesla',
    'Toyota',
    'Volkswagen',
    'Volvo',
  ];
  static const _carModelsMap = <String, List<String>>{
    'Acura': ['ILX', 'Integra', 'MDX', 'RDX', 'TLX'],
    'Alfa Romeo': ['Giulia', 'Stelvio', 'Tonale'],
    'Audi': ['A3', 'A4', 'A5', 'A6', 'Q3', 'Q5', 'Q7', 'Q8', 'e-tron'],
    'BMW': [
      '2 Series',
      '3 Series',
      '4 Series',
      '5 Series',
      'X1',
      'X3',
      'X5',
      'X7',
      'iX',
    ],
    'Buick': ['Enclave', 'Encore', 'Envision', 'Envista'],
    'Cadillac': ['CT4', 'CT5', 'Escalade', 'Lyriq', 'XT4', 'XT5', 'XT6'],
    'Chevrolet': [
      'Blazer',
      'Camaro',
      'Colorado',
      'Corvette',
      'Equinox',
      'Malibu',
      'Silverado',
      'Suburban',
      'Tahoe',
      'Trax',
    ],
    'Chrysler': ['300', 'Pacifica'],
    'Dodge': ['Challenger', 'Charger', 'Durango', 'Hornet'],
    'Fiat': ['500', '500X'],
    'Ford': [
      'Bronco',
      'Edge',
      'Escape',
      'Explorer',
      'F-150',
      'Maverick',
      'Mustang',
      'Ranger',
    ],
    'Genesis': ['G70', 'G80', 'G90', 'GV70', 'GV80'],
    'GMC': ['Acadia', 'Canyon', 'Sierra', 'Terrain', 'Yukon'],
    'Honda': [
      'Accord',
      'Civic',
      'CR-V',
      'HR-V',
      'Odyssey',
      'Passport',
      'Pilot',
      'Ridgeline',
    ],
    'Hyundai': [
      'Elantra',
      'Ioniq',
      'Kona',
      'Palisade',
      'Santa Fe',
      'Sonata',
      'Tucson',
      'Venue',
    ],
    'Infiniti': ['Q50', 'Q60', 'QX50', 'QX55', 'QX60', 'QX80'],
    'Jaguar': ['E-PACE', 'F-PACE', 'F-TYPE', 'XF'],
    'Jeep': [
      'Cherokee',
      'Compass',
      'Gladiator',
      'Grand Cherokee',
      'Renegade',
      'Wagoneer',
      'Wrangler',
    ],
    'Kia': [
      'EV6',
      'Forte',
      'K5',
      'Niro',
      'Seltos',
      'Sorento',
      'Soul',
      'Sportage',
      'Telluride',
    ],
    'Land Rover': [
      'Defender',
      'Discovery',
      'Range Rover',
      'Range Rover Evoque',
      'Range Rover Sport',
    ],
    'Lexus': ['ES', 'GX', 'IS', 'LX', 'NX', 'RX', 'TX', 'UX'],
    'Lincoln': ['Aviator', 'Corsair', 'Navigator'],
    'Maserati': ['Ghibli', 'GranTurismo', 'Grecale', 'Levante', 'Quattroporte'],
    'Mazda': ['CX-30', 'CX-5', 'CX-50', 'CX-90', 'Mazda3', 'MX-5 Miata'],
    'Mercedes-Benz': [
      'A-Class',
      'C-Class',
      'CLA',
      'E-Class',
      'GLA',
      'GLB',
      'GLC',
      'GLE',
      'GLS',
      'S-Class',
    ],
    'Mini': ['Clubman', 'Countryman', 'Hardtop'],
    'Mitsubishi': ['Eclipse Cross', 'Mirage', 'Outlander', 'Outlander Sport'],
    'Nissan': [
      'Altima',
      'Ariya',
      'Frontier',
      'Kicks',
      'Maxima',
      'Murano',
      'Pathfinder',
      'Rogue',
      'Sentra',
      'Titan',
      'Versa',
      'Z',
    ],
    'Porsche': ['718', '911', 'Cayenne', 'Macan', 'Panamera', 'Taycan'],
    'Ram': ['1500', '2500', '3500', 'ProMaster'],
    'Subaru': [
      'Ascent',
      'BRZ',
      'Crosstrek',
      'Forester',
      'Impreza',
      'Legacy',
      'Outback',
      'Solterra',
      'WRX',
    ],
    'Tesla': ['Model 3', 'Model S', 'Model X', 'Model Y', 'Cybertruck'],
    'Toyota': [
      '4Runner',
      'Camry',
      'Corolla',
      'GR86',
      'Highlander',
      'Prius',
      'RAV4',
      'Sequoia',
      'Supra',
      'Tacoma',
      'Tundra',
      'Venza',
    ],
    'Volkswagen': ['Atlas', 'Golf', 'ID.4', 'Jetta', 'Taos', 'Tiguan'],
    'Volvo': ['C40', 'S60', 'S90', 'V60', 'XC40', 'XC60', 'XC90'],
  };
  static const _carColors = [
    'Black',
    'White',
    'Silver',
    'Gray',
    'Red',
    'Blue',
    'Navy',
    'Green',
    'Brown',
    'Beige',
    'Gold',
    'Orange',
    'Yellow',
    'Purple',
    'Burgundy',
    'Champagne',
  ];

  final _pageCtrl = PageController();
  int _step = 0;
  static const _totalSteps = 4;

  // ── Step 0: Personal info ──────────────────────────────────────────────────
  final _firstNameCtrl = TextEditingController();
  final _lastNameCtrl = TextEditingController();
  final _emailCtrl = TextEditingController();
  final _phoneCtrl = TextEditingController();
  final _passwordCtrl = TextEditingController();
  bool _obscurePass = true;

  // ── Step 1: Vehicle ────────────────────────────────────────────────────────
  final _makeCtrl = TextEditingController();
  final _modelCtrl = TextEditingController();
  final _yearCtrl = TextEditingController();
  final _colorCtrl = TextEditingController();
  final _plateCtrl = TextEditingController();

  // ── Step 2: Documents & biometrics ────────────────────────────────────────
  String? _licenseFrontPath;
  String? _licenseBackPath;
  String? _insurancePath;
  bool _biometricDone = false;
  String? _selfiePath;
  String? _verificationVideoPath;

  // SSN
  final _ssnCtrl = TextEditingController();
  bool _obscureSsn = true;

  // ── Step 3: Review ─────────────────────────────────────────────────────────
  bool _agreedTerms = false;
  bool _submitting = false;

  @override
  void dispose() {
    _pageCtrl.dispose();
    _firstNameCtrl.dispose();
    _lastNameCtrl.dispose();
    _emailCtrl.dispose();
    _phoneCtrl.dispose();
    _passwordCtrl.dispose();
    _makeCtrl.dispose();
    _modelCtrl.dispose();
    _yearCtrl.dispose();
    _colorCtrl.dispose();
    _plateCtrl.dispose();
    _ssnCtrl.dispose();
    super.dispose();
  }

  bool get _canProceed {
    switch (_step) {
      case 0:
        return _firstNameCtrl.text.trim().length >= 2 &&
            _lastNameCtrl.text.trim().length >= 2 &&
            RegExp(
              r'^[^@\s]+@[^@\s]+\.[^@\s]{2,}$',
            ).hasMatch(_emailCtrl.text.trim()) &&
            _phoneCtrl.text.replaceAll(RegExp(r'\D'), '').length >= 10 &&
            _passwordCtrl.text.length >= 8 &&
            _passwordCtrl.text.contains(RegExp(r'[0-9]')) &&
            _passwordCtrl.text.contains(RegExp(r'[A-Z]')) &&
            _passwordCtrl.text.contains(
              RegExp(r'[!@#\$%^&*(),.?":{}|<>_\-+=\[\]\\/~`]'),
            );
      case 1:
        final year = int.tryParse(_yearCtrl.text.trim()) ?? 0;
        return _makeCtrl.text.trim().isNotEmpty &&
            _modelCtrl.text.trim().isNotEmpty &&
            year >= 2000 &&
            year <= DateTime.now().year + 1 &&
            _colorCtrl.text.trim().isNotEmpty &&
            _plateCtrl.text.trim().isNotEmpty;
      case 2:
        return _licenseFrontPath != null &&
            _licenseBackPath != null &&
            _insurancePath != null &&
            _biometricDone &&
            _ssnCtrl.text.replaceAll(RegExp(r'\D'), '').length == 9;
      case 3:
        return _agreedTerms;
      default:
        return false;
    }
  }

  void _next() {
    if (_step < _totalSteps - 1) {
      setState(() => _step++);
      _pageCtrl.animateToPage(
        _step,
        duration: const Duration(milliseconds: 350),
        curve: Curves.easeInOut,
      );
    } else {
      _submit();
    }
  }

  void _back() {
    if (_step > 0) {
      setState(() => _step--);
      _pageCtrl.animateToPage(
        _step,
        duration: const Duration(milliseconds: 350),
        curve: Curves.easeInOut,
      );
    } else {
      Navigator.of(context).pop();
    }
  }

  // ── Image helpers ──────────────────────────────────────────────────────────

  Future<String?> _pickCamera() async {
    final picker = ImagePicker();
    final xFile = await picker.pickImage(
      source: ImageSource.camera,
      maxWidth: 1920,
      imageQuality: 92,
      preferredCameraDevice: CameraDevice.rear,
    );
    if (xFile == null) return null;
    final file = File(xFile.path);
    final bytes = await file.length();
    final decoded = await decodeImageFromList(await file.readAsBytes());
    if (decoded.width < 640 || decoded.height < 400 || bytes < 40000) {
      if (mounted) _showQualityDialog();
      return null;
    }
    return xFile.path;
  }

  Future<String?> _pickGallery() async {
    final picker = ImagePicker();
    final xFile = await picker.pickImage(
      source: ImageSource.gallery,
      imageQuality: 92,
    );
    if (xFile == null) return null;
    final file = File(xFile.path);
    final bytes = await file.length();
    final decoded = await decodeImageFromList(await file.readAsBytes());
    if (decoded.width < 640 || decoded.height < 400 || bytes < 40000) {
      if (mounted) _showQualityDialog();
      return null;
    }
    return xFile.path;
  }

  void _showQualityDialog() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1C1C1C),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Row(
          children: [
            const Icon(
              Icons.warning_amber_rounded,
              color: Colors.orange,
              size: 26,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                S.of(context).photoNotClear,
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ],
        ),
        content: Text(
          S.of(context).imageQualityTooLow,
          style: TextStyle(
            color: Colors.white.withValues(alpha: 0.7),
            fontSize: 14,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(
              S.of(context).tryAgain,
              style: const TextStyle(color: _gold, fontWeight: FontWeight.w700),
            ),
          ),
        ],
      ),
    );
  }

  void _showPickOptions(String title, void Function(String) onPicked) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) => Container(
        decoration: const BoxDecoration(
          color: Color(0xFF1C1C1E),
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        ),
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
        child: SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 38,
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.white24,
                  borderRadius: BorderRadius.circular(4),
                ),
              ),
              const SizedBox(height: 16),
              Text(
                title,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 20),
              _sheetOption(
                icon: Icons.camera_alt_rounded,
                label: S.of(context).useCamera,
                onTap: () async {
                  Navigator.pop(ctx);
                  final path = await _pickCamera();
                  if (path != null) onPicked(path);
                },
              ),
              const SizedBox(height: 10),
              _sheetOption(
                icon: Icons.photo_library_rounded,
                label: S.of(context).chooseFromGallery,
                onTap: () async {
                  Navigator.pop(ctx);
                  final path = await _pickGallery();
                  if (path != null) onPicked(path);
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _sheetOption({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 16),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.06),
          borderRadius: BorderRadius.circular(14),
        ),
        child: Row(
          children: [
            Icon(icon, color: _gold, size: 22),
            const SizedBox(width: 14),
            Text(
              label,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 15,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ── Biometric liveness ─────────────────────────────────────────────────────

  Future<void> _runBiometricCheck() async {
    final result = await Navigator.of(context).push<Map<String, String?>?>(
      slideFromRightRoute(const FaceLivenessScreen()),
    );
    if (!mounted || result == null) return;
    setState(() {
      _selfiePath = result['photo'];
      _verificationVideoPath = result['video'];
      _biometricDone = true;
    });
  }

  // ── Submit ─────────────────────────────────────────────────────────────────

  Future<void> _submit() async {
    setState(() => _submitting = true);

    try {
      var phone = _phoneCtrl.text.trim();
      final cleaned = phone.replaceAll(RegExp(r'[\s\-\(\)]'), '');
      phone = cleaned.startsWith('+') ? cleaned : '+1$cleaned';

      final result = await ApiService.register(
        firstName: _firstNameCtrl.text.trim(),
        lastName: _lastNameCtrl.text.trim(),
        email: _emailCtrl.text.trim().isNotEmpty
            ? _emailCtrl.text.trim()
            : null,
        phone: phone.isNotEmpty ? phone : null,
        password: _passwordCtrl.text,
        role: 'driver',
      );

      final user = result['user'] as Map<String, dynamic>;
      final userId = user['id'] as int?;

      await UserSession.saveUser(
        firstName: _firstNameCtrl.text.trim(),
        lastName: _lastNameCtrl.text.trim(),
        email: _emailCtrl.text.trim(),
        phone: phone,
        password: _passwordCtrl.text,
        userId: userId,
        paymentMethod: 'none',
        role: 'driver',
      );
      await UserSession.saveMode('driver');

      try {
        await ApiService.saveVehicle(
          make: _makeCtrl.text.trim(),
          model: _modelCtrl.text.trim(),
          year: int.tryParse(_yearCtrl.text.trim()) ?? 0,
          color: _colorCtrl.text.trim().isNotEmpty
              ? _colorCtrl.text.trim()
              : null,
          plate: _plateCtrl.text.trim(),
        );
      } catch (e) {
        debugPrint('⚠️ Vehicle save failed: $e');
        // Non-blocking — vehicle can be added later via dispatch
      }

      try {
        await _uploadDocuments();
      } catch (e) {
        debugPrint('⚠️ Document upload failed: $e');
        // Non-blocking — documents can be re-submitted
      }
      await LocalDataService.setDriverApprovalStatus('pending');
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _submitting = false);
      _showError(e.message);
      return;
    } catch (e) {
      if (!mounted) return;
      setState(() => _submitting = false);
      _showError('Registration failed: $e');
      return;
    }

    if (!mounted) return;
    setState(() => _submitting = false);

    Navigator.of(context).pushAndRemoveUntil(
      slideFromRightRoute(const DriverPendingReviewScreen()),
      (_) => false,
    );
  }

  Future<void> _uploadDocuments() async {
    final body = <String, dynamic>{'id_document_type': 'driver_license'};

    // Include SSN
    final ssnDigits = _ssnCtrl.text.replaceAll(RegExp(r'\D'), '');
    if (ssnDigits.length == 9) body['ssn'] = ssnDigits;

    Future<void> enc(String key, String? p) async {
      if (p == null) return;
      try {
        body[key] = base64Encode(await File(p).readAsBytes());
      } catch (e) {
        debugPrint('⚠️ Failed to read $key from $p: $e');
      }
    }

    await enc('license_front', _licenseFrontPath);
    await enc('license_back', _licenseBackPath);
    await enc('insurance_photo', _insurancePath);
    await enc('selfie_photo', _selfiePath);
    await enc('verification_video', _verificationVideoPath);
    await ApiService.submitVerification(body);
  }

  void _showError(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        backgroundColor: Colors.redAccent,
        content: Text(msg, style: const TextStyle(fontWeight: FontWeight.w600)),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        duration: const Duration(seconds: 5),
      ),
    );
  }

  // ═══════════════════════════════════════════════════════════════════════════
  //  BUILD
  // ═══════════════════════════════════════════════════════════════════════════

  @override
  Widget build(BuildContext context) {
    final pad = MediaQuery.of(context).padding;
    return Scaffold(
      backgroundColor: Colors.black,
      resizeToAvoidBottomInset: true,
      body: GestureDetector(
        onTap: () => FocusScope.of(context).unfocus(),
        child: Column(
          children: [
            Container(
              padding: EdgeInsets.only(top: pad.top + 6, left: 4, right: 16),
              child: Row(
                children: [
                  IconButton(
                    icon: const Icon(Icons.arrow_back, color: Colors.white),
                    onPressed: _back,
                  ),
                  const Spacer(),
                  Text(
                    S.of(context).stepOf(_step + 1, _totalSteps),
                    style: const TextStyle(
                      color: Colors.white54,
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 4),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: LinearProgressIndicator(
                  value: (_step + 1) / _totalSteps,
                  backgroundColor: Colors.white10,
                  valueColor: const AlwaysStoppedAnimation(_gold),
                  minHeight: 4,
                ),
              ),
            ),
            Expanded(
              child: PageView(
                controller: _pageCtrl,
                physics: const NeverScrollableScrollPhysics(),
                children: [
                  _buildPersonalInfo(),
                  _buildVehicleInfo(),
                  _buildDocuments(),
                  _buildReview(),
                ],
              ),
            ),
            Container(
              padding: EdgeInsets.only(
                left: 28,
                right: 28,
                top: 12,
                bottom: MediaQuery.of(context).viewInsets.bottom > 0 
                    ? 12 
                    : MediaQuery.of(context).padding.bottom + 12,
              ),
              child: SizedBox(
                width: double.infinity,
                height: 54,
                child: ElevatedButton(
                  onPressed: _canProceed && !_submitting ? _next : null,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _canProceed ? _gold : Colors.white12,
                    foregroundColor: Colors.black,
                    disabledBackgroundColor: Colors.white12,
                    disabledForegroundColor: Colors.white24,
                    elevation: _canProceed ? 4 : 0,
                    shadowColor: _gold.withValues(alpha: 0.4),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(30),
                    ),
                  ),
                  child: _submitting
                      ? const SizedBox(
                          width: 22,
                          height: 22,
                          child: CircularProgressIndicator(
                            strokeWidth: 2.5,
                            color: Colors.black,
                          ),
                        )
                      : FittedBox(
                          fit: BoxFit.scaleDown,
                          child: Text(
                            _step == _totalSteps - 1
                                ? S.of(context).submitApplication
                                : S.of(context).continueButton,
                            style: const TextStyle(
                              fontSize: 17,
                              fontWeight: FontWeight.w700,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ═══════════════════════════════════════════════════════════════════════════
  //  STEP 0 — Personal Info
  // ═══════════════════════════════════════════════════════════════════════════

  Widget _buildPersonalInfo() {
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 28),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 20),
          _pageTitle(
            S.of(context).personalInformation,
            S.of(context).personalInfoSubtitle,
          ),
          const SizedBox(height: 28),
          Row(
            children: [
              Expanded(
                child: _field(
                  ctrl: _firstNameCtrl,
                  label: S.of(context).firstNameLabel,
                  icon: Icons.person_outline,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _field(
                  ctrl: _lastNameCtrl,
                  label: S.of(context).lastNameLabel,
                  icon: Icons.person_outline,
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          _field(
            ctrl: _emailCtrl,
            label: S.of(context).emailAddressLabel,
            icon: Icons.email_outlined,
            keyboard: TextInputType.emailAddress,
          ),
          const SizedBox(height: 16),
          _field(
            ctrl: _phoneCtrl,
            label: S.of(context).phoneNumberLabel,
            icon: Icons.phone_outlined,
            keyboard: TextInputType.phone,
          ),
          const SizedBox(height: 16),
          _field(
            ctrl: _passwordCtrl,
            label: S.of(context).passwordRequirements,
            icon: Icons.lock_outline_rounded,
            obscure: _obscurePass,
            suffix: IconButton(
              icon: Icon(
                _obscurePass
                    ? Icons.visibility_off_outlined
                    : Icons.visibility_outlined,
                color: Colors.white38,
                size: 20,
              ),
              onPressed: () => setState(() => _obscurePass = !_obscurePass),
            ),
          ),
          const SizedBox(height: 40),
        ],
      ),
    );
  }

  // ═══════════════════════════════════════════════════════════════════════════
  //  STEP 1 — Vehicle Info
  // ═══════════════════════════════════════════════════════════════════════════

  Widget _buildVehicleInfo() {
    final models = _carModelsMap[_makeCtrl.text.trim()] ?? [];
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 28),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 20),
          _pageTitle(
            S.of(context).vehicleDetails,
            S.of(context).vehicleInfoSubtitle,
          ),
          const SizedBox(height: 28),
          Row(
            children: [
              Expanded(
                child: _autocompleteField(
                  ctrl: _makeCtrl,
                  label: S.of(context).vehicleMake,
                  icon: Icons.directions_car_outlined,
                  options: _carMakes,
                  onSelected: (_) {
                    _modelCtrl.clear();
                    setState(() {});
                  },
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _autocompleteField(
                  ctrl: _modelCtrl,
                  label: S.of(context).vehicleModel,
                  icon: Icons.directions_car_outlined,
                  options: models,
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: _field(
                  ctrl: _yearCtrl,
                  label: S.of(context).vehicleYear,
                  icon: Icons.calendar_today_outlined,
                  keyboard: TextInputType.number,
                  maxLength: 4,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _autocompleteField(
                  ctrl: _colorCtrl,
                  label: S.of(context).vehicleColor,
                  icon: Icons.palette_outlined,
                  options: _carColors,
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          _field(
            ctrl: _plateCtrl,
            label: S.of(context).licensePlateLabel,
            icon: Icons.confirmation_number_outlined,
            capitalize: true,
          ),
          const SizedBox(height: 20),
          _infoBox(S.of(context).vehicleRequirements),
          const SizedBox(height: 40),
        ],
      ),
    );
  }

  // ═══════════════════════════════════════════════════════════════════════════
  //  STEP 2 — Documents & Biometrics
  // ═══════════════════════════════════════════════════════════════════════════

  Widget _buildDocuments() {
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 28),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 20),
          _pageTitle(
            S.of(context).documentsVerification,
            S.of(context).completeAllItems,
          ),
          const SizedBox(height: 22),

          _docTile(
            title: S.of(context).driverLicenseFront,
            subtitle: S.of(context).tapToScanFront,
            icon: Icons.credit_card_rounded,
            filePath: _licenseFrontPath,
            required_: true,
            onTap: () async {
              final path = await Navigator.of(context).push<String?>(
                slideFromRightRoute(const LicenseScannerScreen(side: 'Front')),
              );
              if (path != null && mounted) {
                setState(() => _licenseFrontPath = path);
              }
            },
          ),
          const SizedBox(height: 10),

          _docTile(
            title: S.of(context).driverLicenseBack,
            subtitle: S.of(context).tapToScanBack,
            icon: Icons.credit_card_outlined,
            filePath: _licenseBackPath,
            required_: true,
            onTap: () async {
              final path = await Navigator.of(context).push<String?>(
                slideFromRightRoute(const LicenseScannerScreen(side: 'Back')),
              );
              if (path != null && mounted) {
                setState(() => _licenseBackPath = path);
              }
            },
          ),
          const SizedBox(height: 10),

          _docTile(
            title: S.of(context).carInsurance,
            subtitle: S.of(context).carInsuranceDesc,
            icon: Icons.shield_outlined,
            filePath: _insurancePath,
            required_: true,
            onTap: () => _showPickOptions(
              'Car Insurance',
              (p) => setState(() => _insurancePath = p),
            ),
          ),
          const SizedBox(height: 10),

          _buildSsnSection(),
          const SizedBox(height: 10),

          _buildBiometricTile(),
          const SizedBox(height: 22),

          _buildDocProgress(),
          const SizedBox(height: 40),
        ],
      ),
    );
  }

  Widget _buildSsnSection() {
    final ssnFilled = _ssnCtrl.text.replaceAll(RegExp(r'\D'), '').length == 9;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: ssnFilled
            ? _gold.withValues(alpha: 0.08)
            : Colors.white.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: ssnFilled ? _gold.withValues(alpha: 0.4) : Colors.white12,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: ssnFilled
                      ? _gold.withValues(alpha: 0.2)
                      : Colors.white.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(
                  Icons.security_rounded,
                  color: ssnFilled ? _gold : Colors.white38,
                  size: 20,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Text(
                          S.of(context).ssnLabel,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 14,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(width: 6),
                        _badge(S.of(context).requiredBadge),
                      ],
                    ),
                    Text(
                      ssnFilled
                          ? S.of(context).ssnEntered
                          : S.of(context).enterSsn,
                      style: TextStyle(
                        color: ssnFilled ? _gold : Colors.white38,
                        fontSize: 11,
                      ),
                    ),
                  ],
                ),
              ),
              if (ssnFilled)
                GestureDetector(
                  onTap: () => setState(() {
                    _ssnCtrl.clear();
                  }),
                  child: const Icon(Icons.edit_rounded, color: _gold, size: 18),
                ),
              if (ssnFilled) const SizedBox(width: 6),
              if (ssnFilled)
                const Icon(Icons.check_circle_rounded, color: _gold, size: 22),
            ],
          ),
          if (!ssnFilled) ...[
            const SizedBox(height: 14),
            TextField(
              controller: _ssnCtrl,
              obscureText: _obscureSsn,
              keyboardType: TextInputType.number,
              inputFormatters: [
                FilteringTextInputFormatter.digitsOnly,
                _SsnFormatter(),
              ],
              style: const TextStyle(
                color: Colors.white,
                fontSize: 18,
                letterSpacing: 2,
              ),
              cursorColor: _gold,
              // Auto-trigger Checkr as soon as 9 digits are complete
              onChanged: (val) => setState(() {}),
              decoration: InputDecoration(
                hintText: 'XXX-XX-XXXX',
                hintStyle: const TextStyle(
                  color: Colors.white24,
                  letterSpacing: 1,
                ),
                filled: true,
                fillColor: Colors.white.withValues(alpha: 0.06),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: const BorderSide(color: Colors.white12),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: const BorderSide(color: _gold, width: 1.5),
                ),
                suffixIcon: IconButton(
                  icon: Icon(
                    _obscureSsn
                        ? Icons.visibility_off_outlined
                        : Icons.visibility_outlined,
                    color: Colors.white38,
                    size: 20,
                  ),
                  onPressed: () => setState(() => _obscureSsn = !_obscureSsn),
                ),
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 14,
                ),
              ),
            ),
            const SizedBox(height: 10),
            Text(
              S.of(context).ssnEncryptedNote,
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.3),
                fontSize: 11,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildBiometricTile() {
    return GestureDetector(
      onTap: _runBiometricCheck,
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: _biometricDone
              ? _gold.withValues(alpha: 0.08)
              : Colors.white.withValues(alpha: 0.05),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: _biometricDone
                ? _gold.withValues(alpha: 0.4)
                : Colors.white12,
          ),
        ),
        child: Row(
          children: [
            Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(
                color: _biometricDone
                    ? _gold.withValues(alpha: 0.2)
                    : Colors.white.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(
                _biometricDone
                    ? Icons.face_retouching_natural_rounded
                    : Icons.face_rounded,
                color: _biometricDone ? _gold : Colors.white38,
                size: 26,
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(
                        S.of(context).biometricFaceCheck,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(width: 6),
                      _badge(S.of(context).requiredBadge),
                    ],
                  ),
                  const SizedBox(height: 3),
                  Text(
                    _biometricDone
                        ? S.of(context).faceLivenessVerified
                        : S.of(context).biometricInstructions,
                    style: TextStyle(
                      color: _biometricDone ? _gold : Colors.white38,
                      fontSize: 11,
                    ),
                  ),
                ],
              ),
            ),
            if (_biometricDone)
              const Icon(Icons.check_circle_rounded, color: _gold, size: 22)
            else
              const Icon(
                Icons.play_circle_outline_rounded,
                color: Colors.white24,
                size: 24,
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildDocProgress() {
    final items = [
      (S.of(context).licenseFrontLabel, _licenseFrontPath != null),
      (S.of(context).licenseBackLabel, _licenseBackPath != null),
      (S.of(context).insuranceLabel, _insurancePath != null),
      (
        S.of(context).ssnShortLabel,
        _ssnCtrl.text.replaceAll(RegExp(r'\D'), '').length == 9,
      ),
      (S.of(context).faceCheckLabel, _biometricDone),
    ];
    final done = items.where((i) => i.$2).length;
    return Column(
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              S.of(context).documentsComplete,
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.5),
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
            Text(
              '$done / ${items.length}',
              style: const TextStyle(
                color: _gold,
                fontSize: 12,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: LinearProgressIndicator(
            value: done / items.length,
            backgroundColor: Colors.white10,
            valueColor: const AlwaysStoppedAnimation(_gold),
            minHeight: 5,
          ),
        ),
      ],
    );
  }

  // ═══════════════════════════════════════════════════════════════════════════
  //  STEP 3 — Review & Submit
  // ═══════════════════════════════════════════════════════════════════════════

  Widget _buildReview() {
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 28),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 20),
          _pageTitle(
            S.of(context).reviewAndSubmit,
            S.of(context).confirmBeforeSubmit,
          ),
          const SizedBox(height: 28),

          _reviewItem(
            S.of(context).nameLabel,
            '${_firstNameCtrl.text.trim()} ${_lastNameCtrl.text.trim()}',
          ),
          _reviewItem(S.of(context).emailLabel, _emailCtrl.text.trim()),
          _reviewItem(S.of(context).phoneLabel, _phoneCtrl.text.trim()),
          _reviewItem(
            S.of(context).vehicleLabel,
            '${_yearCtrl.text.trim()} ${_makeCtrl.text.trim()} ${_modelCtrl.text.trim()}'
                .trim(),
          ),
          _reviewItem(S.of(context).plateLabel, _plateCtrl.text.trim()),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Divider(color: Colors.white.withValues(alpha: 0.08)),
          ),
          _reviewItem(
            S.of(context).licenseFrontLabel,
            _licenseFrontPath != null
                ? S.of(context).uploadedStatus
                : S.of(context).missingStatus,
          ),
          _reviewItem(
            S.of(context).licenseBackLabel,
            _licenseBackPath != null
                ? S.of(context).uploadedStatus
                : S.of(context).missingStatus,
          ),
          _reviewItem(
            S.of(context).insuranceLabel,
            _insurancePath != null
                ? S.of(context).uploadedStatus
                : S.of(context).missingStatus,
          ),
          _reviewItem(
            S.of(context).ssnShortLabel,
            _ssnCtrl.text.replaceAll(RegExp(r'\D'), '').length == 9
                ? S.of(context).providedStatus
                : S.of(context).missingStatus,
          ),
          _reviewItem(
            S.of(context).faceCheckLabel,
            _biometricDone
                ? S.of(context).providedStatus
                : S.of(context).notCompletedStatus,
          ),
          const SizedBox(height: 24),

          GestureDetector(
            onTap: () => setState(() => _agreedTerms = !_agreedTerms),
            behavior: HitTestBehavior.opaque,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  width: 22,
                  height: 22,
                  decoration: BoxDecoration(
                    color: _agreedTerms ? _gold : Colors.transparent,
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(
                      color: _agreedTerms ? _gold : Colors.white24,
                      width: 2,
                    ),
                  ),
                  child: _agreedTerms
                      ? const Icon(Icons.check, size: 16, color: Colors.black)
                      : null,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    S.of(context).agreeTermsText,
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.6),
                      fontSize: 13,
                      height: 1.45,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 20),
          _infoBox(S.of(context).applicationReviewNote),
          const SizedBox(height: 40),
        ],
      ),
    );
  }

  // ═══════════════════════════════════════════════════════════════════════════
  //  SHARED WIDGETS
  // ═══════════════════════════════════════════════════════════════════════════

  Widget _pageTitle(String title, String subtitle) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ShaderMask(
          shaderCallback: (r) =>
              const LinearGradient(colors: [_goldLight, _gold]).createShader(r),
          child: Text(
            title,
            style: const TextStyle(
              fontSize: 26,
              fontWeight: FontWeight.w900,
              color: Colors.white,
            ),
          ),
        ),
        const SizedBox(height: 6),
        Text(
          subtitle,
          style: TextStyle(
            fontSize: 14,
            color: Colors.white.withValues(alpha: 0.5),
          ),
        ),
      ],
    );
  }

  Widget _docTile({
    required String title,
    required String subtitle,
    required IconData icon,
    required String? filePath,
    required bool required_,
    required VoidCallback onTap,
  }) {
    final done = filePath != null;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: done
              ? _gold.withValues(alpha: 0.08)
              : Colors.white.withValues(alpha: 0.05),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: done ? _gold.withValues(alpha: 0.4) : Colors.white12,
          ),
        ),
        child: Row(
          children: [
            Container(
              width: 50,
              height: 50,
              decoration: BoxDecoration(
                color: done
                    ? _gold.withValues(alpha: 0.18)
                    : Colors.white.withValues(alpha: 0.07),
                borderRadius: BorderRadius.circular(12),
              ),
              clipBehavior: Clip.antiAlias,
              child: done
                  ? (kIsWeb
                        ? Image.network(filePath, fit: BoxFit.cover)
                        : Image.file(File(filePath), fit: BoxFit.cover))
                  : Icon(icon, color: done ? _gold : Colors.white38, size: 22),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          title,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 14,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      if (required_) ...[
                        const SizedBox(width: 6),
                        _badge('Required'),
                      ],
                    ],
                  ),
                  const SizedBox(height: 3),
                  Text(
                    subtitle,
                    style: const TextStyle(color: Colors.white38, fontSize: 11),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Icon(
              done ? Icons.check_circle_rounded : Icons.cloud_upload_outlined,
              color: done ? _gold : Colors.white24,
              size: 22,
            ),
          ],
        ),
      ),
    );
  }

  Widget _badge(String text) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
    decoration: BoxDecoration(
      color: Colors.white.withValues(alpha: 0.12),
      borderRadius: BorderRadius.circular(4),
    ),
    child: Text(
      text,
      style: const TextStyle(color: Colors.white70, fontSize: 10),
    ),
  );

  Widget _infoBox(String text) => Container(
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(
      color: _gold.withValues(alpha: 0.07),
      borderRadius: BorderRadius.circular(16),
      border: Border.all(color: _gold.withValues(alpha: 0.2)),
    ),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Icon(Icons.info_outline_rounded, color: _gold, size: 20),
        const SizedBox(width: 12),
        Expanded(
          child: Text(
            text,
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.6),
              fontSize: 13,
              height: 1.4,
            ),
          ),
        ),
      ],
    ),
  );

  Widget _reviewItem(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 100,
            child: Text(
              label,
              style: const TextStyle(
                color: Colors.white38,
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value.isEmpty ? '\u2014' : value,
              style: const TextStyle(color: Colors.white, fontSize: 14),
            ),
          ),
        ],
      ),
    );
  }

  Widget _autocompleteField({
    required TextEditingController ctrl,
    required String label,
    required IconData icon,
    required List<String> options,
    ValueChanged<String>? onSelected,
  }) {
    return Autocomplete<String>(
      optionsBuilder: (v) {
        if (v.text.isEmpty) return options;
        final q = v.text.toLowerCase();
        return options.where((o) => o.toLowerCase().contains(q));
      },
      onSelected: (val) {
        ctrl.text = val;
        setState(() {});
        onSelected?.call(val);
      },
      fieldViewBuilder: (ctx, textCtrl, focusNode, onSubmit) {
        // Sync initial value from our controller
        if (textCtrl.text != ctrl.text) textCtrl.text = ctrl.text;
        textCtrl.addListener(() {
          if (ctrl.text != textCtrl.text) {
            ctrl.text = textCtrl.text;
            setState(() {});
          }
        });
        return TextField(
          controller: textCtrl,
          focusNode: focusNode,
          style: const TextStyle(color: Colors.white, fontSize: 16),
          cursorColor: _gold,
          decoration: InputDecoration(
            labelText: label,
            labelStyle: const TextStyle(color: Colors.white38, fontSize: 14),
            prefixIcon: Icon(icon, color: _gold, size: 20),
            counterText: '',
            filled: true,
            fillColor: Colors.white.withValues(alpha: 0.06),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(16),
              borderSide: const BorderSide(color: Colors.white12),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(16),
              borderSide: const BorderSide(color: _gold, width: 1.5),
            ),
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 16,
              vertical: 18,
            ),
          ),
        );
      },
      optionsViewBuilder: (ctx, onSel, opts) {
        return Align(
          alignment: Alignment.topLeft,
          child: Material(
            color: const Color(0xFF1E1E2C),
            borderRadius: BorderRadius.circular(12),
            elevation: 8,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 200),
              child: ListView.builder(
                padding: EdgeInsets.zero,
                shrinkWrap: true,
                itemCount: opts.length,
                itemBuilder: (_, i) {
                  final o = opts.elementAt(i);
                  return ListTile(
                    dense: true,
                    title: Text(
                      o,
                      style: const TextStyle(color: Colors.white, fontSize: 14),
                    ),
                    onTap: () => onSel(o),
                  );
                },
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _field({
    required TextEditingController ctrl,
    required String label,
    required IconData icon,
    TextInputType keyboard = TextInputType.text,
    bool obscure = false,
    Widget? suffix,
    int? maxLength,
    bool capitalize = false,
  }) {
    return TextField(
      controller: ctrl,
      obscureText: obscure,
      keyboardType: keyboard,
      textCapitalization: capitalize
          ? TextCapitalization.characters
          : TextCapitalization.none,
      maxLength: maxLength,
      onChanged: (_) => setState(() {}),
      style: const TextStyle(color: Colors.white, fontSize: 16),
      cursorColor: _gold,
      decoration: InputDecoration(
        labelText: label,
        labelStyle: TextStyle(color: Colors.white38, fontSize: 14),
        prefixIcon: Icon(icon, color: _gold, size: 20),
        suffixIcon: suffix,
        counterText: '',
        filled: true,
        fillColor: Colors.white.withValues(alpha: 0.06),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: const BorderSide(color: Colors.white12),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: const BorderSide(color: _gold, width: 1.5),
        ),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 16,
          vertical: 18,
        ),
      ),
    );
  }
}

// ── SSN formatter: XXX-XX-XXXX ────────────────────────────────────────────────

class _SsnFormatter extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    final digits = newValue.text.replaceAll(RegExp(r'\D'), '');
    final buf = StringBuffer();
    for (var i = 0; i < digits.length && i < 9; i++) {
      if (i == 3 || i == 5) buf.write('-');
      buf.write(digits[i]);
    }
    final str = buf.toString();
    return TextEditingValue(
      text: str,
      selection: TextSelection.collapsed(offset: str.length),
    );
  }
}
