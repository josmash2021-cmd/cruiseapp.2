import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../data/us_states.dart';
import '../../../l10n/app_localizations.dart';
import '../../../services/api_service.dart';
import 'onboarding_widgets.dart';

/// "License Plate Number" capture — plate + confirm plate (must match,
/// inline error) + state dropdown (50 states). Save posts to
/// `/auth/onboarding-items/plate` and pops `true` on success.
class PlateCaptureScreen extends StatefulWidget {
  const PlateCaptureScreen({super.key});

  @override
  State<PlateCaptureScreen> createState() => _PlateCaptureScreenState();
}

class _PlateCaptureScreenState extends State<PlateCaptureScreen> {
  final _plateCtrl = TextEditingController();
  final _confirmCtrl = TextEditingController();
  String? _state;
  String? _matchError;
  bool _saving = false;

  @override
  void dispose() {
    _plateCtrl.dispose();
    _confirmCtrl.dispose();
    super.dispose();
  }

  bool get _valid =>
      _plateCtrl.text.trim().isNotEmpty &&
      _confirmCtrl.text.trim().isNotEmpty &&
      _state != null;

  void _revalidate() {
    final mismatch =
        _confirmCtrl.text.isNotEmpty &&
        _plateCtrl.text.trim().toUpperCase() !=
            _confirmCtrl.text.trim().toUpperCase();
    final err = mismatch ? S.of(context).obPlatesDontMatch : null;
    if (err != _matchError) setState(() => _matchError = err);
  }

  Future<void> _save() async {
    if (!_valid || _saving) return;
    final s = S.of(context);
    if (_plateCtrl.text.trim().toUpperCase() !=
        _confirmCtrl.text.trim().toUpperCase()) {
      setState(() => _matchError = s.obPlatesDontMatch);
      return;
    }
    setState(() => _saving = true);
    try {
      await ApiService.submitOnboardingPlate(
        plate: _plateCtrl.text.trim().toUpperCase(),
        state: _state!,
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
          s.obPlateScreenTitle,
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
                  OnboardingField(
                    controller: _plateCtrl,
                    label: s.obPlateFieldLabel,
                    textCapitalization: TextCapitalization.characters,
                    maxLength: 8,
                    inputFormatters: [
                      FilteringTextInputFormatter.allow(RegExp('[A-Za-z0-9 ]')),
                    ],
                    onChanged: (_) {
                      _revalidate();
                      setState(() {});
                    },
                  ),
                  const SizedBox(height: 16),
                  OnboardingField(
                    controller: _confirmCtrl,
                    label: s.obPlateConfirmLabel,
                    textCapitalization: TextCapitalization.characters,
                    maxLength: 8,
                    errorText: _matchError,
                    inputFormatters: [
                      FilteringTextInputFormatter.allow(RegExp('[A-Za-z0-9 ]')),
                    ],
                    onChanged: (_) {
                      _revalidate();
                      setState(() {});
                    },
                  ),
                  const SizedBox(height: 16),
                  OnboardingDropdown<String>(
                    label: s.obStateLabel,
                    value: _state,
                    items: usStates,
                    onChanged: (v) => setState(() => _state = v),
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
