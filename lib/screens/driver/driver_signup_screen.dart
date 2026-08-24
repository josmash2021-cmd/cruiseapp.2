import 'dart:async';
import 'dart:convert';
import 'dart:io' if (dart.library.html) 'dart:io';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:image_picker/image_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../l10n/app_localizations.dart';

import '../../config/app_theme.dart';
import '../../config/page_transitions.dart';
import '../../services/api_service.dart';
import '../../services/local_data_service.dart';
import '../../services/user_session.dart';
import '../../widgets/neu_style.dart';
import '../face_liveness_screen.dart';
import '../biometric_consent_screen.dart';
import '../privacy_policy_screen.dart';
import 'driver_agreement_screen.dart';
import 'driver_pending_review_screen.dart';
import '../../utils/ssn_validator.dart';
import 'license_guidelines_screen.dart';

final _nonDigitRe = RegExp(r'\D');

/// Multi-step driver sign-up + verification flow.
///
///  Step 0 — Personal information
///  Step 1 — Documents & verification, in two halves
///    About you:      license FRONT, license BACK, SSN (for Checkr), face
///                    biometric liveness check
///    About your car: make/model/year/colour/plate, insurance photo,
///                    registration photo
///  Step 2 — Review & submit
///
/// The car's details used to be a step of their own, sitting between the
/// personal page and the documents page. They are now the opening of the
/// "about your car" half — you describe the car and prove it in one place
/// instead of being asked about it, sent elsewhere, then asked again.
class DriverSignupScreen extends StatefulWidget {
  const DriverSignupScreen({super.key});

  @override
  State<DriverSignupScreen> createState() => _DriverSignupScreenState();
}

class _DriverSignupScreenState extends State<DriverSignupScreen>
    with TickerProviderStateMixin {
  static const _gold = Color(0xFFE8C547);

  static final _emailRe = RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]{2,}$');
  static final _digitRe = RegExp(r'[0-9]');
  static final _upperRe = RegExp(r'[A-Z]');
  static final _specialRe = RegExp(r'[!@#\$%^&*(),.?":{}|<>_\-+=\[\]\\/~`]');
  static final _nonDigitRe = RegExp(r'\D');
  static final _phoneCleanRe = RegExp(r'[\s\-\(\)]');

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
  static const _totalSteps = 3;

  // ── Step 0: Personal info ──────────────────────────────────────────────────
  final _firstNameCtrl = TextEditingController();
  final _lastNameCtrl = TextEditingController();
  final _emailCtrl = TextEditingController();
  final _phoneCtrl = TextEditingController();
  final _passwordCtrl = TextEditingController();
  bool _obscurePass = true;
  final _confirmPassCtrl = TextEditingController();
  bool _obscureConfirm = true;

  // Optional referral code — a driver who signs up with someone's code
  // earns $25 after their first 2 rides (redeemed right after register).
  final _refCodeCtrl = TextEditingController();

  // Date of birth — drivers must be at least 21 (server re-validates).
  DateTime? _dob;
  static const int _minDriverAge = 21;

  // ── Inline duplicate-check state ───────────────────────────────────────────
  String? _emailError;
  String? _phoneError;
  bool _checkingEmail = false;
  bool _checkingPhone = false;
  Timer? _emailDebounce;
  Timer? _phoneDebounce;

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
  String? _registrationPath;
  bool _biometricDone = false;
  String? _selfiePath;
  String? _verificationVideoPath;

  // SSN
  final _ssnCtrl = TextEditingController();
  bool _obscureSsn = true;

  // ── Step 3: Review ─────────────────────────────────────────────────────────
  // Single consolidated legal consent, shown right above the Continue
  // button on step 0.
  bool _agreedAll = false;
  bool _verifyingConsent = false;
  bool _submitting = false;

  @override
  void initState() {
    super.initState();
    _emailCtrl.addListener(_onEmailChanged);
    _phoneCtrl.addListener(_onPhoneChanged);
    _passwordCtrl.addListener(_onPasswordChanged);
  }

  void _onPasswordChanged() => setState(() {});

  /// Age in full years from the selected date of birth (null if not set).
  int? get _driverAge {
    final dob = _dob;
    if (dob == null) return null;
    final now = DateTime.now();
    var age = now.year - dob.year;
    if (now.month < dob.month ||
        (now.month == dob.month && now.day < dob.day)) {
      age--;
    }
    return age;
  }

  /// Date of birth formatted as YYYY-MM-DD for the backend.
  String get _dobIso {
    final dob = _dob;
    if (dob == null) return '';
    final mm = dob.month.toString().padLeft(2, '0');
    final dd = dob.day.toString().padLeft(2, '0');
    return '${dob.year}-$mm-$dd';
  }

  Future<void> _pickDob() async {
    final now = DateTime.now();
    // Neumorphic three-step picker: year (capped at 21+), month grid,
    // then the day calendar of that month — each step slides in.
    final picked = await showDialog<DateTime>(
      context: context,
      builder: (_) => _DobNeuPicker(
        initial: _dob,
        minYear: 1900,
        maxYear: now.year - _minDriverAge,
      ),
    );
    if (picked != null && mounted) {
      setState(() => _dob = picked);
    }
  }

  @override
  void dispose() {
    _emailDebounce?.cancel();
    _phoneDebounce?.cancel();
    _emailCtrl.removeListener(_onEmailChanged);
    _phoneCtrl.removeListener(_onPhoneChanged);
    _pageCtrl.dispose();
    _firstNameCtrl.dispose();
    _lastNameCtrl.dispose();
    _emailCtrl.dispose();
    _phoneCtrl.dispose();
    _passwordCtrl.removeListener(_onPasswordChanged);
    _passwordCtrl.dispose();
    _confirmPassCtrl.dispose();
    _refCodeCtrl.dispose();
    _makeCtrl.dispose();
    _modelCtrl.dispose();
    _yearCtrl.dispose();
    _colorCtrl.dispose();
    _plateCtrl.dispose();
    _ssnCtrl.dispose();
    super.dispose();
  }

  /// Whether every field about the car itself is filled in and sane.
  ///
  /// Read by BOTH the Continue gate and the checklist counter. They used to
  /// be written out separately, which is how a page ends up showing a full
  /// progress bar over a grey Continue button and no way to tell why.
  bool get _vehicleDetailsComplete {
    final year = int.tryParse(_yearCtrl.text.trim()) ?? 0;
    return _makeCtrl.text.trim().isNotEmpty &&
        _modelCtrl.text.trim().isNotEmpty &&
        year >= 2000 &&
        year <= DateTime.now().year + 1 &&
        _colorCtrl.text.trim().isNotEmpty &&
        _plateCtrl.text.trim().isNotEmpty;
  }

  bool get _canProceed {
    switch (_step) {
      case 0:
        return _firstNameCtrl.text.trim().length >= 2 &&
            _lastNameCtrl.text.trim().length >= 2 &&
            _dob != null &&
            (_driverAge ?? 0) >= _minDriverAge &&
            _emailRe.hasMatch(_emailCtrl.text.trim()) &&
            _phoneCtrl.text.replaceAll(_nonDigitRe, '').length >= 10 &&
            _passwordCtrl.text.length >= 8 &&
            _passwordCtrl.text.contains(_digitRe) &&
            _passwordCtrl.text.contains(_upperRe) &&
            _passwordCtrl.text.contains(_specialRe) &&
            _confirmPassCtrl.text == _passwordCtrl.text &&
            _agreedAll &&
            _emailError == null &&
            _phoneError == null &&
            !_checkingEmail &&
            !_checkingPhone;
      case 1:
        // One page now, so one gate: everything about you AND everything
        // about the car.
        return _licenseFrontPath != null &&
            _licenseBackPath != null &&
            _biometricDone &&
            isPlausibleSsn(_ssnCtrl.text) &&
            _vehicleDetailsComplete &&
            _insurancePath != null &&
            _registrationPath != null;
      case 2:
        // Legal consents were collected on step 0 (below the password).
        return true;
      default:
        return false;
    }
  }

  /// Step-0 Continue: hold a 2-second "verifying terms" state while we
  /// confirm the legal consent is accepted, then advance.
  Future<void> _continueFromStep0() async {
    if (_verifyingConsent) return;
    setState(() => _verifyingConsent = true);
    await Future.delayed(const Duration(seconds: 2));
    if (!mounted) return;
    setState(() => _verifyingConsent = false);
    if (_agreedAll) _next();
  }

  void _next() {
    // On Step 0: force-validate email & phone if debounce hasn't fired yet
    if (_step == 0) {
      final email = _emailCtrl.text.trim();
      final phone = _phoneCtrl.text.replaceAll(_nonDigitRe, '');
      if (email.isNotEmpty &&
          _emailRe.hasMatch(email) &&
          !_checkingEmail &&
          _emailError == null) {
        // Trigger immediate check if not yet validated
        _emailDebounce?.cancel();
        _validateEmailNow(email);
      }
      if (phone.length >= 10 &&
          !_checkingPhone &&
          _phoneError == null) {
        _phoneDebounce?.cancel();
        _validatePhoneNow('+1$phone');
      }
    }

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

  /// Immediately validate email (no debounce).
  Future<void> _validateEmailNow(String email) async {
    setState(() {
      _checkingEmail = true;
      _emailError = null;
    });
    final exists = await ApiService.checkExists(email, role: 'driver');
    if (!mounted) return;
    setState(() {
      _checkingEmail = false;
      _emailError =
          exists ? 'This email is already registered as a driver' : null;
    });
  }

  /// Immediately validate phone (no debounce).
  Future<void> _validatePhoneNow(String phone) async {
    setState(() {
      _checkingPhone = true;
      _phoneError = null;
    });
    final exists = await ApiService.checkExists(phone, role: 'driver');
    if (!mounted) return;
    setState(() {
      _checkingPhone = false;
      _phoneError =
          exists ? 'This phone number is already registered as a driver' : null;
    });
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

  // ── Inline duplicate-check helpers ─────────────────────────────────────────

  void _onEmailChanged() {
    _emailDebounce?.cancel();
    final email = _emailCtrl.text.trim();
    if (email.isEmpty ||
        !_emailRe.hasMatch(email)) {
      if (_emailError != null || _checkingEmail) {
        setState(() {
          _emailError = null;
          _checkingEmail = false;
        });
      }
      return;
    }
    setState(() {
      _checkingEmail = true;
      _emailError = null;
    });
    _emailDebounce = Timer(const Duration(milliseconds: 600), () async {
      final exists = await ApiService.checkExists(email, role: 'driver');
      if (!mounted) return;
      setState(() {
        _checkingEmail = false;
        _emailError =
            exists ? 'This email is already registered as a driver' : null;
      });
    });
  }

  void _onPhoneChanged() {
    _phoneDebounce?.cancel();
    final raw = _phoneCtrl.text.replaceAll(_nonDigitRe, '');
    if (raw.length < 10) {
      if (_phoneError != null || _checkingPhone) {
        setState(() {
          _phoneError = null;
          _checkingPhone = false;
        });
      }
      return;
    }
    final phone = '+1$raw';
    setState(() {
      _checkingPhone = true;
      _phoneError = null;
    });
    _phoneDebounce = Timer(const Duration(milliseconds: 600), () async {
      final exists = await ApiService.checkExists(phone, role: 'driver');
      if (!mounted) return;
      setState(() {
        _checkingPhone = false;
        _phoneError =
            exists ? 'This phone number is already registered as a driver' : null;
      });
    });
  }

  Widget _inlineFieldStatus(String? error, bool checking) {
    final c = AppColors.of(context);
    if (!checking && error == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 6, left: 4),
      child: Row(
        children: [
          if (checking)
            SizedBox(
              width: 12,
              height: 12,
              child: CircularProgressIndicator(
                  strokeWidth: 1.5, color: c.textTertiary),
            )
          else
            const Icon(Icons.error_outline_rounded,
                size: 14, color: Colors.redAccent),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              checking ? 'Checking...' : error!,
              style: TextStyle(
                color: checking ? c.textTertiary : Colors.redAccent,
                fontSize: 12,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _driverStrengthRow(String label, bool met) {
    final c = AppColors.of(context);
    return Row(
      children: [
        AnimatedSwitcher(
          duration: const Duration(milliseconds: 280),
          transitionBuilder: (child, anim) => FadeTransition(
            opacity: CurvedAnimation(parent: anim, curve: Curves.easeInOut),
            child: child,
          ),
          child: Icon(
            met ? Icons.check_circle_rounded : Icons.circle_outlined,
            key: ValueKey(met),
            size: 16,
            color: met ? _gold : c.textTertiary,
          ),
        ),
        const SizedBox(width: 8),
        AnimatedDefaultTextStyle(
          duration: const Duration(milliseconds: 250),
          style: TextStyle(
            fontSize: 13,
            color: met ? _gold : c.textTertiary,
            fontWeight: met ? FontWeight.w600 : FontWeight.w400,
          ),
          child: Text(label),
        ),
      ],
    );
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
        backgroundColor: neuSurface,
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
                style: TextStyle(
                  color: AppColors.of(ctx).textPrimary,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ],
        ),
        content: Text(
          S.of(context).imageQualityTooLow,
          style: TextStyle(
            color: AppColors.of(ctx).textSecondary,
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
      builder: (ctx) {
        final c = AppColors.of(ctx);
        return Container(
        decoration: const BoxDecoration(
          color: neuBase,
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
                style: TextStyle(
                  color: c.textPrimary,
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
      );
      },
    );
  }

  Widget _sheetOption({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
  }) {
    final c = AppColors.of(context);
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 16),
        decoration: neuBox(radius: 14, pressed: true),
        child: Row(
          children: [
            Icon(icon, color: _gold, size: 22),
            const SizedBox(width: 14),
            Text(
              label,
              style: TextStyle(
                color: c.textPrimary,
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
    // Biometric consent gate (BIPA-style informed consent): show the
    // dedicated consent screen ONCE before any liveness capture.
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    if (prefs.getBool('biometric_consent_v1') != true) {
      final consented = await Navigator.of(context).push<bool>(
        slideFromRightRoute(const BiometricConsentScreen()),
      );
      if (consented != true || !mounted) return;
    }
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
      final cleaned = phone.replaceAll(_phoneCleanRe, '');
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
        dateOfBirth: _dobIso,
      );

      final user = result['user'] as Map<String, dynamic>;
      final userId = (user['id'] is num) ? (user['id'] as num).toInt() : int.tryParse(user['id']?.toString() ?? '');

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

      // Record written acceptances (timestamp + version + IP server-side).
      // The contractor agreement acceptance is the § 627.748(9)(d) evidence.
      // Non-blocking: a logging failure must not abort registration.
      try {
        await ApiService.recordConsent(
          consentType: 'independent_contractor_agreement',
          action: 'accepted',
          version: kDriverAgreementVersion,
        );
        await ApiService.recordConsent(
          consentType: 'terms',
          action: 'accepted',
          version: '2026-07-26',
        );
        await ApiService.recordConsent(
          consentType: 'privacy',
          action: 'accepted',
          version: '2026-07-26',
        );
      } catch (e) {
        debugPrint('⚠️ Consent log failed (non-blocking): $e');
      }

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

      // Referral code (optional field on step 0). Non-blocking: a bad or
      // late code must never abort registration — the driver can redeem it
      // later from the Refer Friends screen.
      final refCode = _refCodeCtrl.text.trim();
      if (refCode.isNotEmpty) {
        try {
          await ApiService.redeemDriverReferralCode(refCode);
          debugPrint('✅ Driver referral code redeemed at signup');
        } catch (e) {
          debugPrint('⚠️ Referral code redeem failed (non-blocking): $e');
        }
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
    final body = <String, dynamic>{
      'id_document_type': 'driver_license',
      'dob': _dobIso,
    };

    // Include SSN
    final ssnDigits = _ssnCtrl.text.replaceAll(_nonDigitRe, '');
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
    await enc('registration_photo', _registrationPath);
    await enc('selfie_photo', _selfiePath);
    await enc('verification_video', _verificationVideoPath);
    await ApiService.submitVerification(body);

    // Initiate background check after document submission
    try {
      await ApiService.initiateBackgroundCheck(dob: _dobIso);
    } catch (_) {
      // Background check is non-blocking — driver can proceed
    }
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
    final c = AppColors.of(context);
    return Scaffold(
      backgroundColor: const Color(0xFF0A1128),
      resizeToAvoidBottomInset: true,
      body: GestureDetector(
        onTap: () => FocusScope.of(context).unfocus(),
        child: Column(
          children: [
            Container(
              padding: EdgeInsets.only(top: pad.top + 8, left: 16, right: 16),
              child: Row(
                children: [
                  GestureDetector(
                    onTap: _back,
                    child: Container(
                      width: 40,
                      height: 40,
                      decoration: neuBox(radius: 14, pressed: true),
                      child: Icon(
                        Icons.arrow_back_rounded,
                        color: c.textPrimary,
                        size: 22,
                      ),
                    ),
                  ),
                  const Spacer(),
                  Text(
                    S.of(context).stepOf(_step + 1, _totalSteps),
                    style: TextStyle(
                      color: c.textTertiary,
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 8),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: LinearProgressIndicator(
                  value: (_step + 1) / _totalSteps,
                  backgroundColor: neuPressed,
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
                  _buildDocuments(),
                  _buildReview(),
                ],
              ),
            ),
            // ── Single legal consent above the Continue button ──
            if (_step == 0 &&
                MediaQuery.of(context).viewInsets.bottom == 0)
              Padding(
                padding: const EdgeInsets.fromLTRB(28, 8, 28, 0),
                child: GestureDetector(
                  onTap: () => setState(() => _agreedAll = !_agreedAll),
                  behavior: HitTestBehavior.opaque,
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      AnimatedContainer(
                        duration: const Duration(milliseconds: 200),
                        width: 22,
                        height: 22,
                        margin: const EdgeInsets.only(top: 1),
                        decoration: BoxDecoration(
                          color: _agreedAll ? _gold : Colors.transparent,
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(
                            color: _agreedAll ? _gold : c.textTertiary,
                            width: 2,
                          ),
                        ),
                        child: _agreedAll
                            ? const Icon(Icons.check, size: 16, color: Colors.black)
                            : null,
                      ),
                      const SizedBox(width: 12),
                      // Consent sentence with the doc links INLINE right
                      // after "…policies." — same color as the body text.
                      Expanded(
                        child: Text.rich(
                          TextSpan(
                            style: TextStyle(
                              color: c.textSecondary,
                              fontSize: 13,
                              height: 1.55,
                            ),
                            children: [
                              TextSpan(
                                text: '${S.of(context).readAcceptAllDocsText} ',
                              ),
                              ..._docLinkSpans(c),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
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
              child: GestureDetector(
                onTap: _canProceed && !_submitting && !_verifyingConsent
                    ? (_step == 0 ? _continueFromStep0 : _next)
                    : null,
                child: Container(
                  width: double.infinity,
                  height: 56,
                  decoration: _canProceed
                      ? BoxDecoration(
                          color: _gold,
                          borderRadius: BorderRadius.circular(16),
                        )
                      : neuBox(radius: 16, pressed: true),
                  alignment: Alignment.center,
                  child: _submitting
                      ? const SizedBox(
                          width: 22,
                          height: 22,
                          child: CircularProgressIndicator(
                            strokeWidth: 2.5,
                            color: Colors.black,
                          ),
                        )
                      : _verifyingConsent
                          ? Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                const SizedBox(
                                  width: 20,
                                  height: 20,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2.5,
                                    color: Colors.black,
                                  ),
                                ),
                                const SizedBox(width: 10),
                                Text(
                                  S.of(context).verifyingTerms,
                                  style: const TextStyle(
                                    fontSize: 16,
                                    fontWeight: FontWeight.w700,
                                    color: Colors.black,
                                  ),
                                ),
                              ],
                            )
                          : FittedBox(
                              fit: BoxFit.scaleDown,
                              child: Text(
                                _step == _totalSteps - 1
                                    ? S.of(context).submitApplication
                                    : S.of(context).continueButton,
                                style: TextStyle(
                                  fontSize: 17,
                                  fontWeight: FontWeight.w700,
                                  color: _canProceed
                                      ? Colors.black
                                      : c.textTertiary,
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
    final c = AppColors.of(context);
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
                  topHint: _firstNameCtrl.text.trim().isEmpty
                      ? S.of(context).fieldHintFirstName
                      : null,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _field(
                  ctrl: _lastNameCtrl,
                  label: S.of(context).lastNameLabel,
                  icon: Icons.person_outline,
                  topHint: _lastNameCtrl.text.trim().isEmpty
                      ? S.of(context).fieldHintLastName
                      : null,
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          // Same red guide as the text fields, above the DOB tile.
          if (_dob == null)
            Padding(
              padding: const EdgeInsets.only(left: 4, bottom: 6),
              child: Text(
                S.of(context).fieldHintDob,
                style: const TextStyle(
                  color: Colors.redAccent,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          _buildDobPicker(),
          const SizedBox(height: 16),
          _field(
            ctrl: _emailCtrl,
            label: S.of(context).emailAddressLabel,
            icon: Icons.email_outlined,
            keyboard: TextInputType.emailAddress,
            errorText: _emailError,
            topHint: !_emailRe.hasMatch(_emailCtrl.text.trim())
                ? S.of(context).fieldHintEmail
                : null,
            suffix: _checkingEmail
                ? const Padding(
                    padding: EdgeInsets.all(14),
                    child: SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: _gold,
                      ),
                    ),
                  )
                : _emailError != null
                    ? const Icon(Icons.error_outline_rounded,
                        color: Colors.redAccent, size: 20)
                    : _emailCtrl.text.trim().isNotEmpty &&
                            _emailRe
                                .hasMatch(_emailCtrl.text.trim())
                        ? const Icon(Icons.check_circle_rounded,
                            color: Colors.green, size: 20)
                        : null,
          ),
          _inlineFieldStatus(_emailError, _checkingEmail),
          const SizedBox(height: 16),
          _field(
            ctrl: _phoneCtrl,
            label: S.of(context).phoneNumberLabel,
            icon: Icons.phone_outlined,
            keyboard: TextInputType.phone,
            errorText: _phoneError,
            topHint: _phoneCtrl.text.replaceAll(_nonDigitRe, '').length < 10
                ? S.of(context).fieldHintPhone
                : null,
            suffix: _checkingPhone
                ? const Padding(
                    padding: EdgeInsets.all(14),
                    child: SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: _gold,
                      ),
                    ),
                  )
                : _phoneError != null
                    ? const Icon(Icons.error_outline_rounded,
                        color: Colors.redAccent, size: 20)
                    : _phoneCtrl.text
                                .replaceAll(_nonDigitRe, '')
                                .length >=
                            10
                        ? const Icon(Icons.check_circle_rounded,
                            color: Colors.green, size: 20)
                        : null,
          ),
          _inlineFieldStatus(_phoneError, _checkingPhone),
          const SizedBox(height: 16),
          _field(
            ctrl: _passwordCtrl,
            label: S.of(context).passwordLabel,
            icon: Icons.lock_outline_rounded,
            obscure: _obscurePass,
            topHint: !(_passwordCtrl.text.length >= 8 &&
                    _passwordCtrl.text.contains(_digitRe) &&
                    _passwordCtrl.text.contains(_upperRe) &&
                    _passwordCtrl.text.contains(_specialRe))
                ? S.of(context).fieldHintPassword
                : null,
            suffix: IconButton(
              icon: Icon(
                _obscurePass
                    ? Icons.visibility_off_outlined
                    : Icons.visibility_outlined,
                color: c.textTertiary,
                size: 20,
              ),
              onPressed: () => setState(() => _obscurePass = !_obscurePass),
            ),
          ),
          const SizedBox(height: 16),
          _field(
            ctrl: _confirmPassCtrl,
            label: S.of(context).confirmPassword,
            icon: Icons.lock_outline_rounded,
            obscure: _obscureConfirm,
            topHint: _confirmPassCtrl.text.isEmpty ||
                    _confirmPassCtrl.text != _passwordCtrl.text
                ? S.of(context).fieldHintConfirmPassword
                : null,
            suffix: IconButton(
              icon: Icon(
                _obscureConfirm
                    ? Icons.visibility_off_outlined
                    : Icons.visibility_outlined,
                color: c.textTertiary,
                size: 20,
              ),
              onPressed: () =>
                  setState(() => _obscureConfirm = !_obscureConfirm),
            ),
          ),
          const SizedBox(height: 16),
          // Optional: a referrer's code. Any format works — the backend
          // normalizes dashes/case. Worth $25 to THIS driver after their
          // first 2 rides, so it's placed where they can't miss it.
          _field(
            ctrl: _refCodeCtrl,
            label: S.of(context).referralCodeOptional,
            icon: Icons.card_giftcard_outlined,
            capitalize: true,
          ),
          // ── Password requirements checklist — 2 per column ──
          Padding(
            padding: const EdgeInsets.only(top: 14, left: 4),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _driverStrengthRow(
                          'At least 8 characters',
                          _passwordCtrl.text.length >= 8),
                      const SizedBox(height: 6),
                      _driverStrengthRow(
                          'Contains a number',
                          _passwordCtrl.text.contains(_digitRe)),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _driverStrengthRow(
                          'An uppercase letter',
                          _passwordCtrl.text.contains(_upperRe)),
                      const SizedBox(height: 6),
                      _driverStrengthRow(
                          'A special character',
                          _passwordCtrl.text.contains(
                              _specialRe)),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }

  /// Date-of-birth picker tile (Step 0). Shows the 21+ requirement and an
  /// inline error when the selected date makes the driver underage.
  Widget _buildDobPicker() {
    final c = AppColors.of(context);
    final dob = _dob;
    final tooYoung = dob != null && (_driverAge ?? 0) < _minDriverAge;
    final label = dob == null
        ? S.of(context).dateOfBirth
        : '${dob.month.toString().padLeft(2, '0')}/${dob.day.toString().padLeft(2, '0')}/${dob.year}';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        InkWell(
          onTap: _pickDob,
          borderRadius: BorderRadius.circular(16),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 16),
            decoration: neuBox(
              radius: 16,
              pressed: true,
              borderColor: tooYoung ? Colors.redAccent : null,
              borderWidth: tooYoung ? 1.5 : 1,
            ),
            child: Row(
              children: [
                Icon(
                  Icons.cake_outlined,
                  color: tooYoung ? Colors.redAccent : c.textTertiary,
                  size: 20,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    label,
                    style: TextStyle(
                      color: dob == null ? c.textTertiary : c.textPrimary,
                      fontSize: dob == null ? 15 : 16,
                    ),
                  ),
                ),
                Icon(Icons.calendar_today_outlined,
                    color: c.textTertiary, size: 18),
              ],
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.only(top: 8, left: 4),
          child: Text(
            tooYoung
                ? S.of(context).driverAgeTooYoung
                : S.of(context).driverAgeRequirement,
            style: TextStyle(
              color: tooYoung
                  ? Colors.redAccent
                  : c.textTertiary,
              fontSize: 12,
              height: 1.3,
            ),
          ),
        ),
      ],
    );
  }

  // ═══════════════════════════════════════════════════════════════════════════
  //  STEP 1 — Vehicle Info
  // ═══════════════════════════════════════════════════════════════════════════

  /// The car's own details — make, model, year, colour, plate.
  ///
  /// Was a page of its own; now it opens the "about your car" half of the
  /// documents step, directly above the insurance and registration photos
  /// that back it up.
  Widget _vehicleFields() {
    final models = _carModelsMap[_makeCtrl.text.trim()] ?? [];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
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
        const SizedBox(height: 16),
      ],
    );
  }

  // ═══════════════════════════════════════════════════════════════════════════
  //  STEP 1 — Documents & verification (about you + about your car)
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

          // Two groups, because the list mixed two different errands: proving
          // who you are, and proving the car is yours. Five undifferentiated
          // tiles read as one long chore; split, each half is short enough to
          // see the end of.
          _docSectionHeader(S.of(context).docsAboutYou),

          _docTile(
            title: S.of(context).driverLicenseFront,
            subtitle: S.of(context).tapToScanFront,
            icon: Icons.credit_card_rounded,
            filePath: _licenseFrontPath,
            required_: true,
            onTap: () async {
              final path = await Navigator.of(context).push<String?>(
                slideFromRightRoute(const LicenseGuidelinesScreen(side: 'Front')),
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
                slideFromRightRoute(const LicenseGuidelinesScreen(side: 'Back')),
              );
              if (path != null && mounted) {
                setState(() => _licenseBackPath = path);
              }
            },
          ),
          const SizedBox(height: 10),

          _buildSsnSection(),
          const SizedBox(height: 10),

          _buildBiometricTile(),
          const SizedBox(height: 26),

          _docSectionHeader(S.of(context).docsAboutYourCar),

          // Describe the car, then prove it. Same half of the page.
          _vehicleFields(),

          _docTile(
            title: S.of(context).carInsurance,
            subtitle: S.of(context).carInsuranceDesc,
            icon: Icons.shield_outlined,
            filePath: _insurancePath,
            required_: true,
            onTap: () => _showPickOptions(
              S.of(context).carInsurance,
              (p) => setState(() => _insurancePath = p),
            ),
          ),
          const SizedBox(height: 10),

          _docTile(
            title: S.of(context).carRegistration,
            subtitle: S.of(context).carRegistrationSubtitle,
            icon: Icons.description_outlined,
            filePath: _registrationPath,
            required_: true,
            onTap: () => _showPickOptions(
              S.of(context).carRegistration,
              (p) => setState(() => _registrationPath = p),
            ),
          ),
          const SizedBox(height: 22),

          _buildDocProgress(),
          const SizedBox(height: 40),
        ],
      ),
    );
  }

  /// Group heading over the document tiles. Same treatment as the driver
  /// menu's section labels so the two screens read as one app.
  Widget _docSectionHeader(String title) {
    final c = AppColors.of(context);
    return Padding(
      padding: const EdgeInsets.only(left: 6, bottom: 10),
      child: Text(
        title.toUpperCase(),
        style: TextStyle(
          color: c.textTertiary,
          fontSize: 12,
          fontWeight: FontWeight.w700,
          letterSpacing: 1.2,
        ),
      ),
    );
  }

  Widget _buildSsnSection() {
    final c = AppColors.of(context);
    // Three states, not two. "Nine digits are in" is not the same as "this
    // could be somebody's number": 000-00-0000 and 123-45-6789 are nine
    // digits and neither has ever been issued. See utils/ssn_validator.dart —
    // which checks the number is POSSIBLE, not that it belongs to anyone.
    final problem = ssnProblem(_ssnCtrl.text);
    final ssnValid = problem == null;
    final ssnRejected = problem != null && problem != SsnProblem.incomplete;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: neuBox(
        radius: 18,
        borderColor: ssnValid
            ? _gold.withValues(alpha: 0.4)
            : ssnRejected
                ? c.error.withValues(alpha: 0.45)
                : null,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 40,
                height: 40,
                alignment: Alignment.center,
                decoration: ssnValid
                    ? BoxDecoration(
                        color: _gold.withValues(alpha: 0.2),
                        borderRadius: BorderRadius.circular(12),
                      )
                    : neuBox(radius: 12, pressed: true),
                child: Icon(
                  ssnRejected
                      ? Icons.gpp_maybe_rounded
                      : Icons.security_rounded,
                  color: ssnValid
                      ? _gold
                      : ssnRejected
                          ? c.error
                          : c.textTertiary,
                  size: 20,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      S.of(context).ssnLabel,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: c.textPrimary,
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      ssnValid
                          ? S.of(context).ssnEntered
                          : S.of(context).enterSsn,
                      style: TextStyle(
                        color: ssnValid ? _gold : c.textTertiary,
                        fontSize: 11,
                      ),
                    ),
                    if (!ssnValid) ...[
                      const SizedBox(height: 6),
                      _badge(S.of(context).requiredBadge),
                    ],
                  ],
                ),
              ),
              // The tick is the whole point of this screen's ask: it only
              // appears once the number could actually have been issued.
              if (ssnValid)
                GestureDetector(
                  onTap: () => setState(() {
                    _ssnCtrl.clear();
                  }),
                  child: const Icon(Icons.edit_rounded, color: _gold, size: 18),
                ),
              if (ssnValid) const SizedBox(width: 6),
              if (ssnValid)
                const Icon(Icons.check_circle_rounded, color: _gold, size: 22),
            ],
          ),
          if (!ssnValid) ...[
            const SizedBox(height: 14),
            Container(
              decoration: neuBox(radius: 12, pressed: true),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 2),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _ssnCtrl,
                      obscureText: _obscureSsn,
                      keyboardType: TextInputType.number,
                      inputFormatters: [
                        FilteringTextInputFormatter.digitsOnly,
                        _SsnFormatter(),
                      ],
                      style: TextStyle(
                        color: c.textPrimary,
                        fontSize: 18,
                        letterSpacing: 2,
                      ),
                      cursorColor: _gold,
                      // Auto-trigger Checkr as soon as 9 digits are complete
                      onChanged: (val) => setState(() {}),
                      decoration: InputDecoration(
                        border: InputBorder.none,
                        hintText: 'XXX-XX-XXXX',
                        hintStyle: TextStyle(
                          color: c.textTertiary,
                          letterSpacing: 1,
                        ),
                      ),
                    ),
                  ),
                  IconButton(
                    icon: Icon(
                      _obscureSsn
                          ? Icons.visibility_off_outlined
                          : Icons.visibility_outlined,
                      color: c.textTertiary,
                      size: 20,
                    ),
                    onPressed: () => setState(() => _obscureSsn = !_obscureSsn),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 10),
            if (ssnRejected)
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.error_outline_rounded, color: c.error, size: 15),
                  const SizedBox(width: 7),
                  Expanded(
                    child: Text(
                      S.of(context).ssnNotPossible,
                      style: TextStyle(
                        color: c.error,
                        fontSize: 11,
                        height: 1.35,
                      ),
                    ),
                  ),
                ],
              )
            else
              Text(
                S.of(context).ssnEncryptedNote,
                style: TextStyle(
                  color: c.textTertiary,
                  fontSize: 11,
                ),
              ),
          ],
        ],
      ),
    );
  }

  Widget _buildBiometricTile() {
    final c = AppColors.of(context);
    return GestureDetector(
      onTap: _runBiometricCheck,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: neuBox(
          radius: 18,
          borderColor: _biometricDone ? _gold.withValues(alpha: 0.4) : null,
        ),
        child: Row(
          children: [
            Container(
              width: 48,
              height: 48,
              decoration: _biometricDone
                  ? BoxDecoration(
                      color: _gold.withValues(alpha: 0.2),
                      borderRadius: BorderRadius.circular(12),
                    )
                  : neuBox(radius: 12, pressed: true),
              child: Icon(
                _biometricDone
                    ? Icons.face_retouching_natural_rounded
                    : Icons.face_rounded,
                color: _biometricDone ? _gold : c.textTertiary,
                size: 26,
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    S.of(context).biometricFaceCheck,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: c.textPrimary,
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    _biometricDone
                        ? S.of(context).faceLivenessVerified
                        : S.of(context).biometricInstructions,
                    style: TextStyle(
                      color: _biometricDone ? _gold : c.textTertiary,
                      fontSize: 11,
                    ),
                  ),
                  if (!_biometricDone) ...[
                    const SizedBox(height: 6),
                    _badge(S.of(context).requiredBadge),
                  ],
                ],
              ),
            ),
            if (_biometricDone)
              const Icon(Icons.check_circle_rounded, color: _gold, size: 22)
            else
              Icon(
                Icons.play_circle_outline_rounded,
                color: c.textTertiary,
                size: 24,
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildDocProgress() {
    // Same order as the page, and it must list EVERYTHING _canProceed
    // gates on. The vehicle fields were missing, so the bar could read 6/6
    // while Continue stayed grey over an empty plate.
    final items = [
      (S.of(context).licenseFrontLabel, _licenseFrontPath != null),
      (S.of(context).licenseBackLabel, _licenseBackPath != null),
      (S.of(context).ssnShortLabel, isPlausibleSsn(_ssnCtrl.text)),
      (S.of(context).faceCheckLabel, _biometricDone),
      (S.of(context).vehicleDetails, _vehicleDetailsComplete),
      (S.of(context).insuranceLabel, _insurancePath != null),
      (S.of(context).carRegistration, _registrationPath != null),
    ];
    final done = items.where((i) => i.$2).length;
    final c = AppColors.of(context);
    return Column(
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              S.of(context).documentsComplete,
              style: TextStyle(
                color: c.textTertiary,
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
            backgroundColor: neuPressed,
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
            child: Divider(color: Colors.white.withValues(alpha: 0.05)),
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
            S.of(context).carRegistration,
            _registrationPath != null
                ? S.of(context).uploadedStatus
                : S.of(context).missingStatus,
          ),
          _reviewItem(
            S.of(context).ssnShortLabel,
            _ssnCtrl.text.replaceAll(_nonDigitRe, '').length == 9
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
          _infoBox(S.of(context).applicationReviewNote),
          const SizedBox(height: 40),
        ],
      ),
    );
  }

  /// The 4 legal document links, listed under each consent checkbox.
  /// Doc links as INLINE spans appended right after the consent sentence —
  /// rendered in the SAME color as the body text (not gold), keeping only
  /// the underline as the link affordance.
  ///
  /// Only TWO links, straight to the document content (no intermediate
  /// acceptance pages): Terms of Service (direct text) and Privacy Policy
  /// (direct screen). The FCRA disclosure and the Contractor Agreement are
  /// accepted in their own dedicated steps later in the flow.
  List<InlineSpan> _docLinkSpans(AppColors c) {
    final docs = <(String, VoidCallback)>[
      (S.of(context).docLinkDriverTerms, _showDriverTermsDoc),
      (
        S.of(context).docLinkPrivacyPolicy,
        () => Navigator.of(context).push(
              scaleExpandRoute(const PrivacyPolicyScreen(), durationMs: 420),
            ),
      ),
    ];
    final spans = <InlineSpan>[];
    for (var i = 0; i < docs.length; i++) {
      spans.add(TextSpan(
        text: docs[i].$1,
        style: TextStyle(
          color: c.textSecondary,
          fontWeight: FontWeight.w600,
          decoration: TextDecoration.underline,
          decorationColor: c.textSecondary,
        ),
        recognizer: TapGestureRecognizer()..onTap = docs[i].$2,
      ));
      if (i < docs.length - 1) {
        spans.add(TextSpan(
          text: '  ·  ',
          style: TextStyle(color: c.textTertiary),
        ));
      }
    }
    return spans;
  }

  /// Cached driver-terms document (content_markdown) for the direct viewer.
  Map<String, dynamic>? _driverTermsDoc;
  bool _loadingTermsDoc = false;

  /// Show the Driver Terms of Service TEXT directly in a neumorphic dialog
  /// — read-only, no acceptance UI in the middle of the flow.
  Future<void> _showDriverTermsDoc() async {
    if (_loadingTermsDoc) return;
    setState(() => _loadingTermsDoc = true);
    try {
      _driverTermsDoc ??= await ApiService.fetchDriverTermsOfService();
    } catch (_) {}
    if (!mounted) return;
    setState(() => _loadingTermsDoc = false);
    final content = _driverTermsDoc?['content_markdown']?.toString() ?? '';
    final version = _driverTermsDoc?['version']?.toString() ?? '';
    await showDialog<void>(
      context: context,
      builder: (ctx) => Dialog(
        backgroundColor: Colors.transparent,
        insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 40),
        child: Container(
          padding: const EdgeInsets.fromLTRB(20, 18, 12, 20),
          decoration: neuBox(radius: 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Expanded(
                    child: Text(
                      'Cruiseinride Driver Terms of Service',
                      style: TextStyle(
                        color: Color(0xFFE8C547),
                        fontWeight: FontWeight.w800,
                        fontSize: 16,
                      ),
                    ),
                  ),
                  GestureDetector(
                    onTap: () => Navigator.pop(ctx),
                    child: Container(
                      width: 32,
                      height: 32,
                      decoration: neuBox(radius: 10, pressed: true),
                      child: const Icon(
                        Icons.close_rounded,
                        color: Colors.white54,
                        size: 18,
                      ),
                    ),
                  ),
                ],
              ),
              if (version.isNotEmpty)
                Text(
                  'Version $version',
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.4),
                    fontSize: 12,
                  ),
                ),
              const SizedBox(height: 12),
              Flexible(
                child: SingleChildScrollView(
                  child: Text(
                    content.isEmpty ? 'Document unavailable.' : content,
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.8),
                      fontSize: 13,
                      height: 1.5,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ═══════════════════════════════════════════════════════════════════════════
  //  SHARED WIDGETS
  // ═══════════════════════════════════════════════════════════════════════════

  Widget _pageTitle(String title, String subtitle) {
    final c = AppColors.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: GoogleFonts.poppins(
            fontSize: 28,
            fontWeight: FontWeight.w700,
            letterSpacing: -0.5,
            color: c.textPrimary,
            height: 1.15,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          subtitle,
          style: TextStyle(
            fontSize: 14,
            color: c.textSecondary,
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
    final c = AppColors.of(context);
    final done = filePath != null;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: neuBox(
          radius: 18,
          borderColor: done ? _gold.withValues(alpha: 0.4) : null,
        ),
        child: Row(
          children: [
            Container(
              width: 50,
              height: 50,
              decoration: done
                  ? BoxDecoration(
                      color: _gold.withValues(alpha: 0.18),
                      borderRadius: BorderRadius.circular(12),
                    )
                  : neuBox(radius: 12, pressed: true),
              clipBehavior: Clip.antiAlias,
              child: done
                  ? (kIsWeb
                        ? CachedNetworkImage(imageUrl: filePath, fit: BoxFit.cover, fadeInDuration: const Duration(milliseconds: 200))
                        : Image.file(
                            File(filePath),
                            fit: BoxFit.cover,
                            width: 50,
                            height: 50,
                            errorBuilder: (_, __, ___) => Icon(icon, color: _gold, size: 22),
                          ))
                  : Icon(icon, color: c.textTertiary, size: 22),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: c.textPrimary,
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    subtitle,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: done ? _gold : c.textTertiary, fontSize: 11),
                  ),
                  if (required_ && !done) ...[
                    const SizedBox(height: 6),
                    _badge(S.of(context).requiredBadge),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 8),
            Icon(
              done ? Icons.check_circle_rounded : Icons.cloud_upload_outlined,
              color: done ? _gold : c.textTertiary,
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
      color: neuPressed,
      borderRadius: BorderRadius.circular(4),
    ),
    child: Text(
      text,
      style: TextStyle(
          color: AppColors.of(context).textSecondary, fontSize: 10),
    ),
  );

  Widget _infoBox(String text) {
    final c = AppColors.of(context);
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: neuBox(radius: 16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.info_outline_rounded, color: _gold, size: 20),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                color: c.textSecondary,
                fontSize: 13,
                height: 1.4,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _reviewItem(String label, String value) {
    final c = AppColors.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 100,
            child: Text(
              label,
              style: TextStyle(
                color: c.textTertiary,
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value.isEmpty ? '\u2014' : value,
              style: TextStyle(color: c.textPrimary, fontSize: 14),
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
    final c = AppColors.of(context);
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
        return Container(
          decoration: neuBox(radius: 16, pressed: true),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
          child: Row(
            children: [
              Icon(icon, color: c.textTertiary, size: 20),
              const SizedBox(width: 10),
              Expanded(
                child: TextField(
                  controller: textCtrl,
                  focusNode: focusNode,
                  style: TextStyle(color: c.textPrimary, fontSize: 16),
                  cursorColor: _gold,
                  decoration: InputDecoration(
                    border: InputBorder.none,
                    hintText: label,
                    hintStyle: TextStyle(color: c.textTertiary, fontSize: 15),
                    counterText: '',
                  ),
                ),
              ),
            ],
          ),
        );
      },
      optionsViewBuilder: (ctx, onSel, opts) {
        return Align(
          alignment: Alignment.topLeft,
          child: Material(
            color: neuSurface,
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
    String? errorText,
    String? topHint,
  }) {
    final c = AppColors.of(context);
    final hasError = errorText != null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Red guide above the box: what this field still needs. Visible
        // only while the caller says the field is incomplete — it goes
        // away the moment the answer is in.
        if (topHint != null)
          Padding(
            padding: const EdgeInsets.only(left: 4, bottom: 6),
            child: Text(
              topHint,
              style: const TextStyle(
                color: Colors.redAccent,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        Container(
      decoration: neuBox(
        radius: 16,
        pressed: true,
        borderColor: hasError ? Colors.redAccent : null,
        borderWidth: hasError ? 1.5 : 1,
      ),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
      child: Row(
        children: [
          Icon(icon,
              color: hasError ? Colors.redAccent : c.textTertiary, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: TextField(
              controller: ctrl,
              obscureText: obscure,
              keyboardType: keyboard,
              textCapitalization: capitalize
                  ? TextCapitalization.characters
                  : TextCapitalization.none,
              maxLength: maxLength,
              onChanged: (_) => setState(() {}),
              style: TextStyle(color: c.textPrimary, fontSize: 16),
              cursorColor: _gold,
              decoration: InputDecoration(
                border: InputBorder.none,
                hintText: label,
                hintStyle: TextStyle(color: c.textTertiary, fontSize: 15),
                counterText: '',
              ),
            ),
          ),
          if (suffix != null) suffix,
        ],
      ),
        ),
      ],
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
    final digits = newValue.text.replaceAll(_nonDigitRe, '');
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


/// Neumorphic three-step date picker: a year LIST first (already capped
/// at the minimum driving age — younger years simply do not appear),
/// then the month grid, then the day calendar of the chosen month. Each
/// step slides and fades into the next instead of snapping.
class _DobNeuPicker extends StatefulWidget {
  const _DobNeuPicker({
    required this.initial,
    required this.minYear,
    required this.maxYear,
  });

  final DateTime? initial;

  /// Youngest birth year on offer (today minus the minimum age).
  final int minYear;
  final int maxYear;

  @override
  State<_DobNeuPicker> createState() => _DobNeuPickerState();
}

class _DobNeuPickerState extends State<_DobNeuPicker> {
  static const _gold = Color(0xFFE8C547);
  static const _months = [
    'JAN', 'FEB', 'MAR', 'APR', 'MAY', 'JUN',
    'JUL', 'AUG', 'SEP', 'OCT', 'NOV', 'DEC',
  ];

  /// 0 = year, 1 = month, 2 = day. Always opens on the year list.
  int _step = 0;
  int? _year;
  int? _month;

  late final ScrollController _yearScroll;

  @override
  void initState() {
    super.initState();
    _year = widget.initial?.year;
    _month = widget.initial?.month;
    // Land near a plausible pick rather than at the oldest year: rows of
    // ~52 px, the anchor a quarter of the way down the legal range.
    final anchor = widget.initial?.year ?? (widget.maxYear - 4);
    final rows = widget.maxYear - anchor;
    _yearScroll = ScrollController(
      initialScrollOffset: (rows * 52.0).clamp(0.0, double.infinity),
    );
  }

  @override
  void dispose() {
    _yearScroll.dispose();
    super.dispose();
  }

  Widget _block(String text, bool selected, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        height: 44,
        alignment: Alignment.center,
        decoration: selected
            ? BoxDecoration(
                color: _gold,
                borderRadius: BorderRadius.circular(12),
              )
            : neuBox(radius: 12, pressed: true),
        child: Text(
          text,
          style: TextStyle(
            color: selected ? const Color(0xFF1A1400) : Colors.white,
            fontSize: 15,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    const titles = ['Year', 'Month', 'Day'];
    return Dialog(
      backgroundColor: neuBase,
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 40),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                if (_step > 0)
                  GestureDetector(
                    onTap: () => setState(() => _step--),
                    child: const Padding(
                      padding: EdgeInsets.all(4),
                      child: Icon(Icons.arrow_back_ios_new_rounded,
                          color: _gold, size: 16),
                    ),
                  )
                else
                  const SizedBox(width: 24),
                const Spacer(),
                Text(
                  titles[_step],
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 0.5,
                  ),
                ),
                const Spacer(),
                GestureDetector(
                  onTap: () => Navigator.of(context).pop(),
                  child: const Padding(
                    padding: EdgeInsets.all(4),
                    child:
                        Icon(Icons.close_rounded, color: Colors.white54, size: 18),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              [
                if (_year != null) '$_year',
                if (_month != null) _months[_month! - 1],
              ].join(' · '),
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.45),
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 12),
            SizedBox(
              height: 300,
              // The animated hand-off between steps: slide + fade, never
              // a snap.
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 280),
                switchInCurve: Curves.easeOutCubic,
                switchOutCurve: Curves.easeInCubic,
                transitionBuilder: (child, anim) => SlideTransition(
                  position: Tween<Offset>(
                    begin: const Offset(0.08, 0),
                    end: Offset.zero,
                  ).animate(anim),
                  child: FadeTransition(opacity: anim, child: child),
                ),
                child: KeyedSubtree(
                  key: ValueKey(_step),
                  child: _step == 0
                      ? _buildYears()
                      : _step == 1
                          ? _buildMonths()
                          : _buildDays(),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildYears() {
    final years = [
      for (var y = widget.maxYear; y >= widget.minYear; y--) y,
    ];
    return GridView.builder(
      controller: _yearScroll,
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 4,
        mainAxisSpacing: 8,
        crossAxisSpacing: 8,
        childAspectRatio: 2.0,
      ),
      itemCount: years.length,
      itemBuilder: (_, i) => _block('${years[i]}', _year == years[i], () {
        setState(() {
          _year = years[i];
          _step = 1;
        });
      }),
    );
  }

  Widget _buildMonths() {
    return GridView.builder(
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        mainAxisSpacing: 8,
        crossAxisSpacing: 8,
        childAspectRatio: 2.2,
      ),
      itemCount: 12,
      itemBuilder: (_, i) => _block(_months[i], _month == i + 1, () {
        setState(() {
          _month = i + 1;
          _step = 2;
        });
      }),
    );
  }

  Widget _buildDays() {
    final y = _year ?? widget.maxYear;
    final m = _month ?? 1;
    final days = DateUtils.getDaysInMonth(y, m);
    final initialDay = widget.initial != null &&
            widget.initial!.year == y &&
            widget.initial!.month == m
        ? widget.initial!.day
        : null;
    // Calendar-shaped: weekday header plus the blanks the 1st leaves.
    const week = ['S', 'M', 'T', 'W', 'T', 'F', 'S'];
    final lead = DateTime(y, m, 1).weekday % 7; // Sunday-first offset
    return Column(
      children: [
        Row(
          children: [
            for (final w in week)
              Expanded(
                child: Center(
                  child: Text(
                    w,
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.40),
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ),
          ],
        ),
        const SizedBox(height: 6),
        Expanded(
          child: GridView.builder(
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 7,
              mainAxisSpacing: 6,
              crossAxisSpacing: 6,
              childAspectRatio: 1.0,
            ),
            itemCount: lead + days,
            itemBuilder: (_, i) {
              if (i < lead) return const SizedBox.shrink();
              final d = i - lead + 1;
              return _block('$d', initialDay == d, () {
                Navigator.of(context).pop(DateTime(y, m, d));
              });
            },
          ),
        ),
      ],
    );
  }
}
