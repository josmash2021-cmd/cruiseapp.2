import 'dart:io' if (dart.library.html) 'dart:io';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import '../../config/page_transitions.dart';
import '../../services/api_service.dart';
import '../../services/user_session.dart';
import 'driver_home_screen.dart';

/// Multi-step driver sign-up flow.
class DriverSignupScreen extends StatefulWidget {
  const DriverSignupScreen({super.key});

  @override
  State<DriverSignupScreen> createState() => _DriverSignupScreenState();
}

class _DriverSignupScreenState extends State<DriverSignupScreen> {
  static const _gold = Color(0xFFE8C547);
  static const _goldLight = Color(0xFFF5D990);

  final _pageCtrl = PageController();
  int _step = 0;
  static const _totalSteps = 4;

  // Step 0 — Personal info
  final _firstNameCtrl = TextEditingController();
  final _lastNameCtrl = TextEditingController();
  final _emailCtrl = TextEditingController();
  final _phoneCtrl = TextEditingController();
  final _passwordCtrl = TextEditingController();
  bool _obscure = true;

  // Step 1 — Vehicle info
  final _makeCtrl = TextEditingController();
  final _modelCtrl = TextEditingController();
  final _yearCtrl = TextEditingController();
  final _colorCtrl = TextEditingController();
  final _plateCtrl = TextEditingController();

  // Step 2 — Documents
  String? _licensePhoto;
  String? _insurancePhoto;
  String? _profilePhoto;

  // Step 3 — Review & submit
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
        return _licensePhoto != null && _profilePhoto != null;
      case 3:
        return _agreedTerms;
      default:
        return false;
    }
  }

  void _next() {
    if (_step < _totalSteps - 1) {
      setState(() => _step++);
      _pageCtrl.animateToPage(_step,
          duration: const Duration(milliseconds: 350),
          curve: Curves.easeInOut);
    } else {
      _submit();
    }
  }

  void _back() {
    if (_step > 0) {
      setState(() => _step--);
      _pageCtrl.animateToPage(_step,
          duration: const Duration(milliseconds: 350),
          curve: Curves.easeInOut);
    } else {
      Navigator.of(context).pop();
    }
  }

  Future<void> _submit() async {
    setState(() => _submitting = true);

    try {
      // Normalize phone to E.164
      var phone = _phoneCtrl.text.trim();
      final cleaned = phone.replaceAll(RegExp(r'[\s\-\(\)]'), '');
      if (!cleaned.startsWith('+')) {
        phone = '+1$cleaned';
      } else {
        phone = cleaned;
      }

      final result = await ApiService.register(
        firstName: _firstNameCtrl.text.trim(),
        lastName: _lastNameCtrl.text.trim(),
        email: _emailCtrl.text.trim().isNotEmpty ? _emailCtrl.text.trim() : null,
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
      );
      await UserSession.saveMode('driver');
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _submitting = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: Colors.redAccent,
          content: Text(e.message,
              style: const TextStyle(fontWeight: FontWeight.w600)),
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          duration: const Duration(seconds: 5),
        ),
      );
      return;
    } catch (e) {
      if (!mounted) return;
      setState(() => _submitting = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: Colors.redAccent,
          content: Text('Registration failed: $e',
              style: const TextStyle(fontWeight: FontWeight.w600)),
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          duration: const Duration(seconds: 5),
        ),
      );
      return;
    }

    if (!mounted) return;
    setState(() => _submitting = false);

    // Go to driver home
    Navigator.of(context).pushAndRemoveUntil(
      slideFromRightRoute(const DriverHomeScreen()),
      (_) => false,
    );
  }

  Future<String?> _pickImage() async {
    final picker = ImagePicker();
    final picked = await picker.pickImage(
        source: ImageSource.gallery, imageQuality: 85);
    if (picked != null) return picked.path;
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final pad = MediaQuery.of(context).padding;

    return Scaffold(
      backgroundColor: Colors.black,
      body: GestureDetector(
        onTap: () => FocusScope.of(context).unfocus(),
        child: Column(
          children: [
            // ── Top bar ──
            Container(
              padding: EdgeInsets.only(top: pad.top + 8, left: 4, right: 16),
              child: Row(
                children: [
                  IconButton(
                    icon: const Icon(Icons.arrow_back, color: Colors.white),
                    onPressed: _back,
                  ),
                  const Spacer(),
                  // Step indicator
                  Text(
                    'Step ${_step + 1} of $_totalSteps',
                    style: const TextStyle(
                        color: Colors.white54,
                        fontSize: 13,
                        fontWeight: FontWeight.w600),
                  ),
                ],
              ),
            ),

            // ── Progress bar ──
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 4),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: LinearProgressIndicator(
                  value: (_step + 1) / _totalSteps,
                  backgroundColor: Colors.white10,
                  valueColor: const AlwaysStoppedAnimation<Color>(_gold),
                  minHeight: 4,
                ),
              ),
            ),

            // ── Pages ──
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

            // ── Bottom button ──
            SafeArea(
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 28, vertical: 16),
                child: SizedBox(
                  width: double.infinity,
                  height: 54,
                  child: ElevatedButton(
                    onPressed:
                        _canProceed && !_submitting ? _next : null,
                    style: ElevatedButton.styleFrom(
                      backgroundColor:
                          _canProceed ? _gold : Colors.white12,
                      foregroundColor: Colors.black,
                      disabledBackgroundColor: Colors.white12,
                      disabledForegroundColor: Colors.white24,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(30),
                      ),
                      elevation: _canProceed ? 4 : 0,
                      shadowColor: _gold.withValues(alpha: 0.4),
                    ),
                    child: _submitting
                        ? const SizedBox(
                            width: 22,
                            height: 22,
                            child: CircularProgressIndicator(
                                strokeWidth: 2.5, color: Colors.black))
                        : Text(
                            _step == _totalSteps - 1
                                ? 'Submit application'
                                : 'Continue',
                            style: const TextStyle(
                                fontSize: 17,
                                fontWeight: FontWeight.w700),
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

  // ═══════════════════════════════════════════════
  // STEP 0 — Personal Info
  // ═══════════════════════════════════════════════
  Widget _buildPersonalInfo() {
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 28),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 20),
          ShaderMask(
            shaderCallback: (r) => const LinearGradient(
              colors: [_goldLight, _gold],
            ).createShader(r),
            child: const Text(
              'Personal information',
              style: TextStyle(
                fontSize: 26,
                fontWeight: FontWeight.w900,
                color: Colors.white,
              ),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Tell us a bit about yourself',
            style: TextStyle(
                fontSize: 14, color: Colors.white.withValues(alpha: 0.5)),
          ),
          const SizedBox(height: 28),
          Row(
            children: [
              Expanded(
                  child: _field(
                      ctrl: _firstNameCtrl,
                      label: 'First name',
                      icon: Icons.person_outline)),
              const SizedBox(width: 12),
              Expanded(
                  child: _field(
                      ctrl: _lastNameCtrl,
                      label: 'Last name',
                      icon: Icons.person_outline)),
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
            label: 'Create password (min 6 chars)',
            icon: Icons.lock_outline_rounded,
            obscure: _obscure,
            suffix: IconButton(
              icon: Icon(
                _obscure
                    ? Icons.visibility_off_outlined
                    : Icons.visibility_outlined,
                color: Colors.white38,
                size: 20,
              ),
              onPressed: () => setState(() => _obscure = !_obscure),
            ),
          ),
          const SizedBox(height: 40),
        ],
      ),
    );
  }

  // ═══════════════════════════════════════════════
  // STEP 1 — Vehicle Info
  // ═══════════════════════════════════════════════
  Widget _buildVehicleInfo() {
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 28),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 20),
          ShaderMask(
            shaderCallback: (r) => const LinearGradient(
              colors: [_goldLight, _gold],
            ).createShader(r),
            child: const Text(
              'Vehicle details',
              style: TextStyle(
                fontSize: 26,
                fontWeight: FontWeight.w900,
                color: Colors.white,
              ),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Add info about your vehicle',
            style: TextStyle(
                fontSize: 14, color: Colors.white.withValues(alpha: 0.5)),
          ),
          const SizedBox(height: 28),
          Row(
            children: [
              Expanded(
                  child:
                      _field(ctrl: _makeCtrl, label: 'Make', icon: Icons.directions_car_outlined)),
              const SizedBox(width: 12),
              Expanded(
                  child: _field(
                      ctrl: _modelCtrl,
                      label: 'Model',
                      icon: Icons.directions_car_outlined)),
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
              )),
              const SizedBox(width: 12),
              Expanded(
                  child: _field(
                      ctrl: _colorCtrl,
                      label: 'Color',
                      icon: Icons.palette_outlined)),
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

          // ── Vehicle requirements info ──
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: _gold.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: _gold.withValues(alpha: 0.2)),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(Icons.info_outline_rounded,
                    color: _gold, size: 20),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    'Vehicle must be 2010 or newer, 4-door, and pass a vehicle inspection.',
                    style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.6),
                        fontSize: 13,
                        height: 1.4),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 40),
        ],
      ),
    );
  }

  // ═══════════════════════════════════════════════
  // STEP 2 — Documents
  // ═══════════════════════════════════════════════
  Widget _buildDocuments() {
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 28),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 20),
          ShaderMask(
            shaderCallback: (r) => const LinearGradient(
              colors: [_goldLight, _gold],
            ).createShader(r),
            child: const Text(
              'Documents',
              style: TextStyle(
                fontSize: 26,
                fontWeight: FontWeight.w900,
                color: Colors.white,
              ),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Upload required documents to get verified',
            style: TextStyle(
                fontSize: 14, color: Colors.white.withValues(alpha: 0.5)),
          ),
          const SizedBox(height: 28),

          _buildDocTile(
            title: "Driver's license",
            subtitle: 'Front of your valid driver\'s license',
            icon: Icons.badge_outlined,
            file: _licensePhoto,
            required_: true,
            onTap: () async {
              final f = await _pickImage();
              if (f != null) setState(() => _licensePhoto = f);
            },
          ),
          const SizedBox(height: 16),
          _buildDocTile(
            title: 'Insurance',
            subtitle: 'Proof of vehicle insurance',
            icon: Icons.shield_outlined,
            file: _insurancePhoto,
            required_: false,
            onTap: () async {
              final f = await _pickImage();
              if (f != null) setState(() => _insurancePhoto = f);
            },
          ),
          const SizedBox(height: 16),
          _buildDocTile(
            title: 'Profile photo',
            subtitle: 'A clear photo of your face',
            icon: Icons.camera_alt_outlined,
            file: _profilePhoto,
            required_: true,
            onTap: () async {
              final f = await _pickImage();
              if (f != null) setState(() => _profilePhoto = f);
            },
          ),
          const SizedBox(height: 40),
        ],
      ),
    );
  }

  Widget _buildDocTile({
    required String title,
    required String subtitle,
    required IconData icon,
    required String? file,
    required bool required_,
    required VoidCallback onTap,
  }) {
    final uploaded = file != null;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: uploaded
              ? _gold.withValues(alpha: 0.1)
              : Colors.white.withValues(alpha: 0.05),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: uploaded ? _gold.withValues(alpha: 0.4) : Colors.white12,
          ),
        ),
        child: Row(
          children: [
            Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(
                color: uploaded
                    ? _gold.withValues(alpha: 0.2)
                    : Colors.white.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(12),
              ),
              child: uploaded
                  ? ClipRRect(
                      borderRadius: BorderRadius.circular(12),
                      child: kIsWeb
                          ? Image.network(
                              file,
                              fit: BoxFit.cover,
                              width: 48,
                              height: 48,
                            )
                          : Image.file(
                              File(file),
                              fit: BoxFit.cover,
                              width: 48,
                              height: 48,
                              gaplessPlayback: true,
                          frameBuilder: (context, child, frame, wasSynchronouslyLoaded) {
                            if (wasSynchronouslyLoaded) return child;
                            return AnimatedOpacity(
                              opacity: frame == null ? 0.0 : 1.0,
                              duration: const Duration(milliseconds: 250),
                              curve: Curves.easeOutCubic,
                              child: child,
                            );
                          },
                        ),
                    )
                  : Icon(icon,
                      color: uploaded ? _gold : Colors.white38, size: 24),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(title,
                          style: const TextStyle(
                              color: Colors.white,
                              fontSize: 15,
                              fontWeight: FontWeight.w700)),
                      if (required_) ...[
                        const SizedBox(width: 6),
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha: 0.15),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: const Text('Required',
                              style: TextStyle(
                                  color: Colors.white, fontSize: 10)),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(subtitle,
                      style:
                          TextStyle(color: Colors.white38, fontSize: 12)),
                ],
              ),
            ),
            Icon(
              uploaded
                  ? Icons.check_circle_rounded
                  : Icons.cloud_upload_outlined,
              color: uploaded ? _gold : Colors.white24,
              size: 22,
            ),
          ],
        ),
      ),
    );
  }

  // ═══════════════════════════════════════════════
  // STEP 3 — Review
  // ═══════════════════════════════════════════════
  Widget _buildReview() {
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 28),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 20),
          ShaderMask(
            shaderCallback: (r) => const LinearGradient(
              colors: [_goldLight, _gold],
            ).createShader(r),
            child: const Text(
              'Review & submit',
              style: TextStyle(
                fontSize: 26,
                fontWeight: FontWeight.w900,
                color: Colors.white,
              ),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Confirm your details before submitting',
            style: TextStyle(
                fontSize: 14, color: Colors.white.withValues(alpha: 0.5)),
          ),
          const SizedBox(height: 28),

          _reviewItem('Name',
              '${_firstNameCtrl.text.trim()} ${_lastNameCtrl.text.trim()}'),
          _reviewItem('Email', _emailCtrl.text.trim()),
          _reviewItem('Phone', _phoneCtrl.text.trim()),
          _reviewItem(
              'Vehicle',
              '${_yearCtrl.text.trim()} ${_makeCtrl.text.trim()} ${_modelCtrl.text.trim()}'
                  .trim()),
          _reviewItem('Plate', _plateCtrl.text.trim()),
          _reviewItem(
              'License', _licensePhoto != null ? 'Uploaded ✓' : 'Missing'),
          _reviewItem(
              'Insurance',
              _insurancePhoto != null ? 'Uploaded ✓' : 'Not uploaded'),
          _reviewItem(
              'Photo', _profilePhoto != null ? 'Uploaded ✓' : 'Missing'),

          const SizedBox(height: 24),

          // ── Terms checkbox ──
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
                    'I agree to Cruise\'s Driver Terms of Service and acknowledge the Privacy Policy.',
                    style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.6),
                        fontSize: 13,
                        height: 1.45),
                  ),
                ),
              ],
            ),
          ),

          const SizedBox(height: 20),

          // ── Info box ──
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: _gold.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: _gold.withValues(alpha: 0.2)),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(Icons.schedule_rounded,
                    color: _gold, size: 20),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    'Your application will be reviewed within 24-48 hours. We\'ll notify you by email once approved.',
                    style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.6),
                        fontSize: 13,
                        height: 1.4),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 40),
        ],
      ),
    );
  }

  Widget _reviewItem(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 90,
            child: Text(label,
                style: const TextStyle(
                    color: Colors.white38,
                    fontSize: 13,
                    fontWeight: FontWeight.w600)),
          ),
          Expanded(
            child: Text(value.isEmpty ? '—' : value,
                style: const TextStyle(
                    color: Colors.white, fontSize: 14)),
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
      textCapitalization:
          capitalize ? TextCapitalization.characters : TextCapitalization.none,
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
          borderSide: BorderSide(color: Colors.white12),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide(color: _gold, width: 1.5),
        ),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 16, vertical: 18),
      ),
    );
  }
}
