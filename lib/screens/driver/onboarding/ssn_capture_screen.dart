import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../l10n/app_localizations.dart';
import '../../../services/api_service.dart';
import 'onboarding_widgets.dart';

/// Formats an SSN as XXX-XX-XXXX while typing (digits only, max 9).
class SsnInputFormatter extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    final digits = newValue.text.replaceAll(RegExp(r'\D'), '');
    final clamped = digits.length > 9 ? digits.substring(0, 9) : digits;
    final buf = StringBuffer();
    for (var i = 0; i < clamped.length; i++) {
      if (i == 3 || i == 5) buf.write('-');
      buf.write(clamped[i]);
    }
    final text = buf.toString();
    return TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
  }
}

/// "Social Security Number" capture — masked XXX-XX-XXXX field with a
/// security note. Save posts to `/auth/onboarding-items/ssn`.
class SsnCaptureScreen extends StatefulWidget {
  const SsnCaptureScreen({super.key});

  @override
  State<SsnCaptureScreen> createState() => _SsnCaptureScreenState();
}

class _SsnCaptureScreenState extends State<SsnCaptureScreen> {
  final _ssnCtrl = TextEditingController();
  bool _saving = false;

  @override
  void dispose() {
    _ssnCtrl.dispose();
    super.dispose();
  }

  String get _digits => _ssnCtrl.text.replaceAll(RegExp(r'\D'), '');
  bool get _valid => _digits.length == 9;

  Future<void> _save() async {
    if (!_valid || _saving) return;
    final s = S.of(context);
    setState(() => _saving = true);
    try {
      await ApiService.submitOnboardingSsn(ssn: _digits);
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

    return Scaffold(
      backgroundColor: kOnboardingNavy,
      // Field stays put; only the Save button floats above the keyboard
      // via the viewInsets padding below.
      resizeToAvoidBottomInset: false,
      appBar: AppBar(
        backgroundColor: kOnboardingNavy,
        elevation: 0,
        leading: IconButton(
          onPressed: () => Navigator.of(context).pop(),
          icon: const Icon(Icons.close_rounded, color: Colors.white),
        ),
        title: Text(
          s.obSsnScreenTitle,
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
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  OnboardingField(
                    controller: _ssnCtrl,
                    label: s.obSsnFieldLabel,
                    keyboardType: TextInputType.number,
                    inputFormatters: [
                      FilteringTextInputFormatter.digitsOnly,
                      SsnInputFormatter(),
                    ],
                    maxLength: 11,
                    onChanged: (_) => setState(() {}),
                  ),
                  const SizedBox(height: 16),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.05),
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Icon(
                          Icons.lock_outline_rounded,
                          color: kOnboardingGold,
                          size: 20,
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            s.obSsnSecurityNote,
                            style: TextStyle(
                              fontSize: 13,
                              height: 1.45,
                              color: Colors.white.withValues(alpha: 0.7),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          Padding(
            padding: EdgeInsets.fromLTRB(
              24,
              8,
              24,
              pad.bottom + MediaQuery.of(context).viewInsets.bottom + 16,
            ),
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
