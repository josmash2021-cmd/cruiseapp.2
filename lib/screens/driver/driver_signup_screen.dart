import 'dart:convert';
import 'dart:io' if (dart.library.html) 'dart:io';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';

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
        return _firstNameCtrl.text.trim().isNotEmpty &&
            _lastNameCtrl.text.trim().isNotEmpty &&
            _emailCtrl.text.trim().isNotEmpty &&
            _phoneCtrl.text.trim().isNotEmpty &&
            _passwordCtrl.text.length >= 6;
      case 1:
        return _makeCtrl.text.trim().isNotEmpty &&
            _modelCtrl.text.trim().isNotEmpty &&
            _yearCtrl.text.trim().length == 4 &&
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
        title: const Row(
          children: [
            Icon(Icons.warning_amber_rounded, color: Colors.orange, size: 26),
            SizedBox(width: 10),
            Text(
              'Photo Not Clear',
              style: TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
        content: Text(
          'Image quality is too low. Please take a clear, well-lit photo.',
          style: TextStyle(
            color: Colors.white.withValues(alpha: 0.7),
            fontSize: 14,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text(
              'Try Again',
              style: TextStyle(color: _gold, fontWeight: FontWeight.w700),
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
                label: 'Use Camera',
                onTap: () async {
                  Navigator.pop(ctx);
                  final path = await _pickCamera();
                  if (path != null) onPicked(path);
                },
              ),
              const SizedBox(height: 10),
              _sheetOption(
                icon: Icons.photo_library_rounded,
                label: 'Choose from Gallery',
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
    final selfiePath = await Navigator.of(context).push<String?>(
      MaterialPageRoute(builder: (_) => const FaceLivenessScreen()),
    );
    if (!mounted || selfiePath == null) return;
    setState(() {
      _selfiePath = selfiePath;
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
      } catch (_) {}

      await _uploadDocuments();
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
      } catch (_) {}
    }

    await enc('license_front', _licenseFrontPath);
    await enc('license_back', _licenseBackPath);
    await enc('insurance_photo', _insurancePath);
    await enc('selfie_photo', _selfiePath);
    try {
      await ApiService.submitVerification(body);
    } catch (_) {}
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
                    'Step ${_step + 1} of $_totalSteps',
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
            SafeArea(
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 28,
                  vertical: 14,
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
                        : Text(
                            _step == _totalSteps - 1
                                ? 'Submit application'
                                : 'Continue',
                            style: const TextStyle(
                              fontSize: 17,
                              fontWeight: FontWeight.w700,
                            ),
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
          _pageTitle('Personal information', 'Tell us a bit about yourself'),
          const SizedBox(height: 28),
          Row(
            children: [
              Expanded(
                child: _field(
                  ctrl: _firstNameCtrl,
                  label: 'First name',
                  icon: Icons.person_outline,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _field(
                  ctrl: _lastNameCtrl,
                  label: 'Last name',
                  icon: Icons.person_outline,
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          _field(
            ctrl: _emailCtrl,
            label: 'Email address',
            icon: Icons.email_outlined,
            keyboard: TextInputType.emailAddress,
          ),
          const SizedBox(height: 16),
          _field(
            ctrl: _phoneCtrl,
            label: 'Phone number',
            icon: Icons.phone_outlined,
            keyboard: TextInputType.phone,
          ),
          const SizedBox(height: 16),
          _field(
            ctrl: _passwordCtrl,
            label: 'Password (min 6 characters)',
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
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 28),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 20),
          _pageTitle('Vehicle details', 'Add info about your vehicle'),
          const SizedBox(height: 28),
          Row(
            children: [
              Expanded(
                child: _field(
                  ctrl: _makeCtrl,
                  label: 'Make',
                  icon: Icons.directions_car_outlined,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _field(
                  ctrl: _modelCtrl,
                  label: 'Model',
                  icon: Icons.directions_car_outlined,
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
                  label: 'Year',
                  icon: Icons.calendar_today_outlined,
                  keyboard: TextInputType.number,
                  maxLength: 4,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _field(
                  ctrl: _colorCtrl,
                  label: 'Color',
                  icon: Icons.palette_outlined,
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          _field(
            ctrl: _plateCtrl,
            label: 'License plate number',
            icon: Icons.confirmation_number_outlined,
            capitalize: true,
          ),
          const SizedBox(height: 20),
          _infoBox(
            'Vehicle must be 2010 or newer, 4-door, and pass a vehicle inspection.',
          ),
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
            'Documents & Verification',
            'Complete all items to continue',
          ),
          const SizedBox(height: 22),

          _docTile(
            title: "Driver's License — FRONT",
            subtitle: 'Tap to scan the front of your license',
            icon: Icons.credit_card_rounded,
            filePath: _licenseFrontPath,
            required_: true,
            onTap: () async {
              final path = await Navigator.of(context).push<String?>(
                MaterialPageRoute(
                  builder: (_) => const LicenseScannerScreen(side: 'Front'),
                ),
              );
              if (path != null && mounted) {
                setState(() => _licenseFrontPath = path);
              }
            },
          ),
          const SizedBox(height: 10),

          _docTile(
            title: "Driver's License — BACK",
            subtitle: 'Tap to scan the back of your license',
            icon: Icons.credit_card_outlined,
            filePath: _licenseBackPath,
            required_: true,
            onTap: () async {
              final path = await Navigator.of(context).push<String?>(
                MaterialPageRoute(
                  builder: (_) => const LicenseScannerScreen(side: 'Back'),
                ),
              );
              if (path != null && mounted) {
                setState(() => _licenseBackPath = path);
              }
            },
          ),
          const SizedBox(height: 10),

          _docTile(
            title: 'Car Insurance',
            subtitle: 'Current insurance card or policy page',
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
                        const Text(
                          'Social Security Number',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 14,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(width: 6),
                        _badge('Required'),
                      ],
                    ),
                    Text(
                      ssnFilled
                          ? 'SSN entered \u2713'
                          : 'Enter your Social Security Number',
                      style: TextStyle(
                        color: ssnFilled ? _gold : Colors.white38,
                        fontSize: 11,
                      ),
                    ),
                  ],
                ),
              ),
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
              'Your SSN is encrypted and only used for identity verification.',
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
      onTap: _biometricDone ? null : _runBiometricCheck,
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
                      const Text(
                        'Biometric Face Check',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(width: 6),
                      _badge('Required'),
                    ],
                  ),
                  const SizedBox(height: 3),
                  Text(
                    _biometricDone
                        ? 'Face liveness verified \u2713'
                        : 'Look, turn, blink \u2014 takes ~15 seconds',
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
      ('License Front', _licenseFrontPath != null),
      ('License Back', _licenseBackPath != null),
      ('Insurance', _insurancePath != null),
      ('SSN', _ssnCtrl.text.replaceAll(RegExp(r'\D'), '').length == 9),
      ('Face Check', _biometricDone),
    ];
    final done = items.where((i) => i.$2).length;
    return Column(
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              'Documents complete',
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
            'Review & Submit',
            'Confirm your details before submitting',
          ),
          const SizedBox(height: 28),

          _reviewItem(
            'Name',
            '${_firstNameCtrl.text.trim()} ${_lastNameCtrl.text.trim()}',
          ),
          _reviewItem('Email', _emailCtrl.text.trim()),
          _reviewItem('Phone', _phoneCtrl.text.trim()),
          _reviewItem(
            'Vehicle',
            '${_yearCtrl.text.trim()} ${_makeCtrl.text.trim()} ${_modelCtrl.text.trim()}'
                .trim(),
          ),
          _reviewItem('Plate', _plateCtrl.text.trim()),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Divider(color: Colors.white.withValues(alpha: 0.08)),
          ),
          _reviewItem(
            'License Front',
            _licenseFrontPath != null ? 'Uploaded \u2713' : 'Missing',
          ),
          _reviewItem(
            'License Back',
            _licenseBackPath != null ? 'Uploaded \u2713' : 'Missing',
          ),
          _reviewItem(
            'Insurance',
            _insurancePath != null ? 'Uploaded \u2713' : 'Missing',
          ),
          _reviewItem(
            'SSN',
            _ssnCtrl.text.replaceAll(RegExp(r'\D'), '').length == 9
                ? 'Provided \u2713'
                : 'Missing',
          ),
          _reviewItem(
            'Face Check',
            _biometricDone ? 'Passed \u2713' : 'Not completed',
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
                    "I agree to Cruise's Driver Terms of Service, acknowledge the Privacy Policy, and consent to a background check.",
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
          _infoBox(
            'Your application and background check will be reviewed within 24-48 hours. You will be notified by email once approved.',
          ),
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
