import 'package:flutter/material.dart';
import '../../services/api_service.dart';
import '../../services/analytics_service.dart';
import '../../l10n/app_localizations.dart';

/// Consent screen for Checkr background check — collects DOB, SSN last 4,
/// license number/state, and explicit consent before initiating the check.
class BackgroundCheckConsentScreen extends StatefulWidget {
  const BackgroundCheckConsentScreen({super.key});

  @override
  State<BackgroundCheckConsentScreen> createState() =>
      _BackgroundCheckConsentScreenState();
}

class _BackgroundCheckConsentScreenState
    extends State<BackgroundCheckConsentScreen> {
  static final _yearRe = RegExp(r'^\d{4}$');
  static const _gold = Color(0xFFE8C547);
  static const _card = Color(0xFF1C1C1E);
  static const _surface = Color(0xFF141414);

  final _formKey = GlobalKey<FormState>();
  final _firstNameCtrl = TextEditingController();
  final _lastNameCtrl = TextEditingController();
  final _dobCtrl = TextEditingController();
  final _ssnLast4Ctrl = TextEditingController();
  final _licenseNumberCtrl = TextEditingController();
  final _licenseStateCtrl = TextEditingController();

  bool _consentChecked = false;
  bool _submitting = false;

  @override
  void dispose() {
    _firstNameCtrl.dispose();
    _lastNameCtrl.dispose();
    _dobCtrl.dispose();
    _ssnLast4Ctrl.dispose();
    _licenseNumberCtrl.dispose();
    _licenseStateCtrl.dispose();
    super.dispose();
  }

  Future<void> _pickDate() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: DateTime(now.year - 25),
      firstDate: DateTime(1940),
      lastDate: DateTime(now.year - 18),
      builder: (ctx, child) {
        return Theme(
          data: ThemeData.dark().copyWith(
            colorScheme: const ColorScheme.dark(
              primary: _gold,
              onPrimary: Colors.black,
              surface: _card,
            ),
          ),
          child: child!,
        );
      },
    );
    if (picked != null) {
      _dobCtrl.text =
          '${picked.year}-${picked.month.toString().padLeft(2, '0')}-${picked.day.toString().padLeft(2, '0')}';
    }
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    if (!_consentChecked) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(S.of(context).consentRequired),
          backgroundColor: Colors.red.shade400,
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }

    setState(() => _submitting = true);
    try {
      final result = await ApiService.initiateBackgroundCheck(
        firstName: _firstNameCtrl.text.trim(),
        lastName: _lastNameCtrl.text.trim(),
        dob: _dobCtrl.text.trim(),
        ssnLast4: _ssnLast4Ctrl.text.trim(),
        licenseNumber: _licenseNumberCtrl.text.trim(),
        licenseState: _licenseStateCtrl.text.trim(),
      ).timeout(const Duration(seconds: 30));
      AnalyticsService.instance.logEvent('background_check_initiated');
      if (!mounted) return;
      Navigator.pop(context, result);
    } catch (e) {
      if (!mounted) return;
      setState(() => _submitting = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(S.of(context).errorWithMessage(e.toString())),
          backgroundColor: Colors.red.shade400,
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    return Scaffold(
      backgroundColor: _surface,
      appBar: AppBar(
        backgroundColor: _surface,
        foregroundColor: Colors.white,
        title: Text(s.backgroundCheckTitle),
        elevation: 0,
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: Form(
            key: _formKey,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Info card
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: _gold.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: _gold.withValues(alpha: 0.2)),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.verified_user_rounded,
                          color: _gold, size: 24),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          'Powered by Checkr. Your data is encrypted and securely transmitted.',
                          style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.8),
                            fontSize: 13,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 24),

                // Name fields
                Row(
                  children: [
                    Expanded(child: _buildField('First Name', _firstNameCtrl)),
                    const SizedBox(width: 12),
                    Expanded(child: _buildField('Last Name', _lastNameCtrl)),
                  ],
                ),
                const SizedBox(height: 16),

                // DOB
                GestureDetector(
                  onTap: _pickDate,
                  child: AbsorbPointer(
                    child: _buildField(
                      'Date of Birth',
                      _dobCtrl,
                      hint: 'YYYY-MM-DD',
                      suffixIcon: Icons.calendar_today_rounded,
                    ),
                  ),
                ),
                const SizedBox(height: 16),

                // SSN last 4
                _buildField(
                  'SSN (Last 4 digits)',
                  _ssnLast4Ctrl,
                  hint: '••••',
                  maxLength: 4,
                  keyboardType: TextInputType.number,
                  obscure: true,
                  validator: (v) {
                    if (v == null || v.length != 4) {
                      return 'Enter exactly 4 digits';
                    }
                    if (!_yearRe.hasMatch(v)) {
                      return 'Digits only';
                    }
                    return null;
                  },
                ),
                const SizedBox(height: 16),

                // License number
                _buildField('License Number', _licenseNumberCtrl),
                const SizedBox(height: 16),

                // License state
                _buildField(
                  'License State',
                  _licenseStateCtrl,
                  hint: 'e.g. CA',
                  maxLength: 2,
                  validator: (v) {
                    if (v == null || v.isEmpty) return 'Required';
                    if (v.length != 2) return 'Use 2-letter state code';
                    return null;
                  },
                ),
                const SizedBox(height: 24),

                // Consent checkbox
                Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: _card,
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(
                      color: _consentChecked
                          ? _gold.withValues(alpha: 0.4)
                          : Colors.white12,
                    ),
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Checkbox(
                        value: _consentChecked,
                        onChanged: (v) =>
                            setState(() => _consentChecked = v ?? false),
                        activeColor: _gold,
                        checkColor: Colors.black,
                        side: BorderSide(
                            color: Colors.white.withValues(alpha: 0.4)),
                      ),
                      Expanded(
                        child: Padding(
                          padding: const EdgeInsets.only(top: 10),
                          child: Text(
                            'I authorize Cruise to obtain a consumer report (background check) through Checkr, Inc. I understand this may include criminal records, driving records, and identity verification.',
                            style: TextStyle(
                              color: Colors.white.withValues(alpha: 0.7),
                              fontSize: 13,
                              height: 1.4,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 28),

                // Submit button
                SizedBox(
                  width: double.infinity,
                  height: 54,
                  child: ElevatedButton.icon(
                    onPressed: _submitting ? null : _submit,
                    icon: _submitting
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(
                              color: Colors.black,
                              strokeWidth: 2,
                            ),
                          )
                        : const Icon(Icons.play_arrow_rounded, size: 22),
                    label: Text(
                      _submitting
                          ? 'Submitting...'
                          : 'Start Background Check',
                      style: const TextStyle(
                        fontWeight: FontWeight.w800,
                        fontSize: 16,
                      ),
                    ),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: _gold,
                      foregroundColor: Colors.black,
                      disabledBackgroundColor: _gold.withValues(alpha: 0.4),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildField(
    String label,
    TextEditingController controller, {
    String? hint,
    int? maxLength,
    TextInputType? keyboardType,
    bool obscure = false,
    IconData? suffixIcon,
    String? Function(String?)? validator,
  }) {
    return TextFormField(
      controller: controller,
      maxLength: maxLength,
      keyboardType: keyboardType,
      obscureText: obscure,
      style: const TextStyle(color: Colors.white, fontSize: 15),
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        labelStyle: TextStyle(color: Colors.white.withValues(alpha: 0.5)),
        hintStyle: TextStyle(color: Colors.white.withValues(alpha: 0.25)),
        counterText: '',
        filled: true,
        fillColor: _card,
        suffixIcon: suffixIcon != null
            ? Icon(suffixIcon, color: Colors.white38, size: 20)
            : null,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: _gold, width: 1.5),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: Colors.red.shade400),
        ),
      ),
      validator: validator ??
          (v) => (v == null || v.isEmpty) ? 'Required' : null,
    );
  }
}
