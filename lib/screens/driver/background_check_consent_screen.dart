import 'dart:io';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../services/api_service.dart';
import '../../services/analytics_service.dart';
import '../../l10n/app_localizations.dart';

/// Consent screen for Checkr background check — collects DOB, SSN last 4,
/// license number/state, and explicit consent before initiating the check.
///
/// FCRA: the standalone "Background Check Disclosure and Authorization"
/// document (Cruise in Ride LLC) must be accepted via its own dedicated
/// checkbox, separate from every other consent (terms, privacy, ICA).
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
  bool _loadingDoc = false;

  /// Cached disclosure document ({document_id, version, content_hash,
  /// content_markdown}) — fetched lazily on first view or on submit.
  Map<String, dynamic>? _disclosure;

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

  String _deviceInfo() {
    try {
      return '${Platform.operatingSystem} ${Platform.operatingSystemVersion}';
    } catch (_) {
      return 'unknown';
    }
  }

  void _showError(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: Colors.red.shade400,
        behavior: SnackBarBehavior.floating,
      ),
    );
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

  /// Fetch and display the disclosure document in a scrollable dialog.
  Future<void> _showDisclosure() async {
    setState(() => _loadingDoc = true);
    try {
      _disclosure ??= await ApiService.fetchBackgroundCheckDisclosure();
      if (!mounted) return;
      final content = _disclosure?['content_markdown']?.toString() ?? '';
      final version = _disclosure?['version']?.toString() ?? '';
      await showDialog<void>(
        context: context,
        builder: (ctx) => Dialog(
          backgroundColor: _card,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Expanded(
                      child: Text(
                        'Background Check Disclosure and Authorization',
                        style: TextStyle(
                          color: _gold,
                          fontWeight: FontWeight.w800,
                          fontSize: 16,
                        ),
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.close_rounded,
                          color: Colors.white54),
                      onPressed: () => Navigator.pop(ctx),
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
    } catch (e) {
      _showError(S.of(context).errorWithMessage(e.toString()));
    } finally {
      if (mounted) setState(() => _loadingDoc = false);
    }
  }

  /// Open the CFPB "Summary of Your Rights Under the FCRA" PDF.
  /// Uses the Spanish model form when the app language is Spanish.
  Future<void> _openSummaryOfRights() async {
    final isEs = Localizations.localeOf(context).languageCode == 'es';
    final uri = Uri.parse(
      isEs
          ? ApiService.backgroundCheckSummaryOfRightsUrlEs
          : ApiService.backgroundCheckSummaryOfRightsUrlEn,
    );
    try {
      if (await canLaunchUrl(uri)) {
        await launchUrl(uri, mode: LaunchMode.externalApplication);
      } else {
        _showError('Could not open the document');
      }
    } catch (e) {
      _showError(S.of(context).errorWithMessage(e.toString()));
    }
  }

  /// Show past acceptances of the background check disclosure.
  Future<void> _showConsentHistory() async {
    try {
      final items = await ApiService.fetchConsentHistory();
      final history = items
          .where((i) => i['consent_type'] == 'background_check_disclosure')
          .toList();
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: _card,
          title: const Text(
            'Acceptance history',
            style: TextStyle(
              color: _gold,
              fontSize: 16,
              fontWeight: FontWeight.w800,
            ),
          ),
          content: history.isEmpty
              ? Text(
                  'No records yet.',
                  style:
                      TextStyle(color: Colors.white.withValues(alpha: 0.6)),
                )
              : SizedBox(
                  width: double.maxFinite,
                  child: ListView.builder(
                    shrinkWrap: true,
                    itemCount: history.length,
                    itemBuilder: (_, i) {
                      final item = history[i];
                      return ListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        leading: const Icon(Icons.check_circle_rounded,
                            color: _gold, size: 18),
                        title: Text(
                          '${item['action'] ?? ''} · v${item['version'] ?? ''}',
                          style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.85),
                            fontSize: 13,
                          ),
                        ),
                        subtitle: Text(
                          item['created_at']?.toString() ?? '',
                          style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.4),
                            fontSize: 11,
                          ),
                        ),
                      );
                    },
                  ),
                ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Close', style: TextStyle(color: _gold)),
            ),
          ],
        ),
      );
    } catch (e) {
      _showError(S.of(context).errorWithMessage(e.toString()));
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
      // FCRA: log acceptance of the standalone disclosure BEFORE initiating
      // the background check. If consent logging fails, do NOT proceed.
      _disclosure ??= await ApiService.fetchBackgroundCheckDisclosure();
      final doc = _disclosure!;
      await ApiService.recordBackgroundCheckConsent(
        version: doc['version']?.toString() ?? '',
        contentHash: doc['content_hash']?.toString() ?? '',
        deviceInfo: _deviceInfo(),
      );
      AnalyticsService.instance.logEvent('background_check_consent_accepted');

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
      _showError(S.of(context).errorWithMessage(e.toString()));
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

                // FCRA required documents — must be reviewable before consent.
                Container(
                  decoration: BoxDecoration(
                    color: _card,
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Column(
                    children: [
                      _docRow(
                        icon: Icons.description_rounded,
                        label:
                            'View Background Check Disclosure and Authorization',
                        loading: _loadingDoc,
                        onTap: _showDisclosure,
                      ),
                      Divider(
                        height: 1,
                        color: Colors.white.withValues(alpha: 0.08),
                      ),
                      _docRow(
                        icon: Icons.picture_as_pdf_rounded,
                        label: 'View Summary of Your Rights Under the FCRA',
                        onTap: _openSummaryOfRights,
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),

                // Consent checkbox — dedicated solely to the Background Check
                // Disclosure and Authorization document (FCRA standalone
                // disclosure; must not be bundled with ToS/privacy/ICA).
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
                            'I have received, read, and agree to the Background Check Disclosure and Authorization. I authorize Cruise in Ride LLC to obtain consumer reports about me as described in that document.',
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

                // Consent history affordance
                Center(
                  child: TextButton.icon(
                    onPressed: _showConsentHistory,
                    icon: const Icon(Icons.history_rounded,
                        size: 16, color: Colors.white38),
                    label: Text(
                      'Acceptance history',
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.45),
                        fontSize: 12,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _docRow({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
    bool loading = false,
  }) {
    return InkWell(
      onTap: loading ? null : onTap,
      borderRadius: BorderRadius.circular(14),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
        child: Row(
          children: [
            Icon(icon, color: _gold, size: 20),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                label,
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.85),
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            if (loading)
              const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(
                  color: _gold,
                  strokeWidth: 2,
                ),
              )
            else
              Icon(
                Icons.chevron_right_rounded,
                color: Colors.white.withValues(alpha: 0.3),
              ),
          ],
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
