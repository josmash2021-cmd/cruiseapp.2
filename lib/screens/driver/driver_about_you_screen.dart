import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../config/page_transitions.dart';
import '../../l10n/app_localizations.dart';
import '../../services/api_service.dart';
import 'onboarding/onboarding_intro_flow_screen.dart';

/// Driver onboarding — Phase 2, step 2 ("Tell us about yourself").
///
/// Lyft-style survey: 4 blocks (2 checkbox groups + 2 radio groups), all
/// optional — `Save` is always enabled and persists the answers as a single
/// JSON string in `onboarding_survey` via `PATCH /auth/me`, then hands off
/// to the one-time intro sequence ([OnboardingIntroFlowScreen]), which ends
/// at the Phase 2 to-do hub.
class DriverAboutYouScreen extends StatefulWidget {
  const DriverAboutYouScreen({super.key});

  @override
  State<DriverAboutYouScreen> createState() => _DriverAboutYouScreenState();
}

class _DriverAboutYouScreenState extends State<DriverAboutYouScreen> {
  static const _navy = Color(0xFF0A1128);
  static const _gold = Color(0xFFE8C547);

  // ── Survey state (values are stable English keys for the payload) ──
  final Set<String> _reasons = {};
  String? _hoursPerWeek;
  final Set<String> _experience = {};
  String? _incomeRole;
  bool _saving = false;
  String? _errorText;

  static const _hoursOptions = ['lt5', '6-20', '21-35', '35+'];
  static const _incomeOptions = ['only', 'primary', 'supplement', 'not_needed'];

  List<String> _reasonLabels(S s) => [
        s.reasonSupplementIncome,
        s.reasonSavingMoney,
        s.reasonGetOutMeetPeople,
        s.reasonTempUnemployed,
        s.reasonWorksForMyLife,
        s.reasonCantPhysicalWork,
        s.reasonNoOtherJob,
      ];

  static const _reasonKeys = [
        'supplement_income',
        'saving_money',
        'get_out_meet_people',
        'temp_unemployed',
        'works_for_my_life',
        'cant_physical_work',
        'no_other_job',
      ];

  List<String> _experienceLabels(S s) => [
        s.expNoPrior,
        s.expCurrentRideshare,
        s.expPastRideshare,
        s.expDelivery,
        s.expProfessional,
      ];

  static const _experienceKeys = [
        'none',
        'current_rideshare',
        'past_rideshare',
        'delivery',
        'professional',
      ];

  List<String> _hoursLabels(S s) =>
      [s.hoursFewerThan5, '6-20', '21-35', '35+'];

  List<String> _incomeLabels(S s) => [
        s.incomeOnlySource,
        s.incomePrimarySource,
        s.incomeSupplements,
        s.incomeDontNeed,
      ];

  Future<void> _save() async {
    if (_saving) return;
    setState(() {
      _saving = true;
      _errorText = null;
    });
    try {
      await ApiService.updateMe({
        'onboarding_survey': jsonEncode({
          'reasons': _reasons.toList(),
          'hours_per_week': _hoursPerWeek,
          'experience': _experience.toList(),
          'income_role': _incomeRole,
        }),
      });
      if (!mounted) return;
      // First time: the per-item intro sequence runs before the hub; the
      // flow screen self-redirects to the hub when already seen.
      Navigator.of(context).pushAndRemoveUntil(
        onboardingFadeSlideRoute(const OnboardingIntroFlowScreen()),
        (_) => false,
      );
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _errorText = e.message;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _errorText = S.of(context).connectionError;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final pad = MediaQuery.of(context).padding;
    final s = S.of(context);

    return Scaffold(
      backgroundColor: _navy,
      body: Column(
        children: [
          // ── Top bar — close X only (no support icon) ──
          Padding(
            padding: EdgeInsets.only(top: pad.top + 8, left: 8, right: 16),
            child: Row(
              children: [
                IconButton(
                  onPressed: () => Navigator.of(context).pop(),
                  icon: const Icon(
                    Icons.close_rounded,
                    color: Colors.white,
                    size: 26,
                  ),
                ),
              ],
            ),
          ),

          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 28),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const SizedBox(height: 8),
                  Text(
                    s.tellUsAboutYourself,
                    style: GoogleFonts.poppins(
                      fontSize: 30,
                      fontWeight: FontWeight.w700,
                      letterSpacing: -0.5,
                      color: Colors.white,
                      height: 1.15,
                    ),
                  ),
                  const SizedBox(height: 32),

                  // a) Why drive with Cruise — checkboxes
                  _sectionTitle(s.whyDriveWithCruise),
                  const SizedBox(height: 12),
                  for (var i = 0; i < _reasonKeys.length; i++)
                    _checkTile(
                      label: _reasonLabels(s)[i],
                      checked: _reasons.contains(_reasonKeys[i]),
                      onTap: () => setState(() {
                        final k = _reasonKeys[i];
                        _reasons.contains(k)
                            ? _reasons.remove(k)
                            : _reasons.add(k);
                      }),
                    ),

                  const SizedBox(height: 28),

                  // b) Hours per week — radio
                  _sectionTitle(s.hoursPerWeekQuestion),
                  const SizedBox(height: 12),
                  for (var i = 0; i < _hoursOptions.length; i++)
                    _radioTile(
                      label: _hoursLabels(s)[i],
                      selected: _hoursPerWeek == _hoursOptions[i],
                      onTap: () =>
                          setState(() => _hoursPerWeek = _hoursOptions[i]),
                    ),

                  const SizedBox(height: 28),

                  // c) Prior experience — checkboxes
                  _sectionTitle(s.priorExperienceQuestion),
                  const SizedBox(height: 12),
                  for (var i = 0; i < _experienceKeys.length; i++)
                    _checkTile(
                      label: _experienceLabels(s)[i],
                      checked: _experience.contains(_experienceKeys[i]),
                      onTap: () => setState(() {
                        final k = _experienceKeys[i];
                        _experience.contains(k)
                            ? _experience.remove(k)
                            : _experience.add(k);
                      }),
                    ),

                  const SizedBox(height: 28),

                  // d) Income role — radio
                  _sectionTitle(s.incomeRoleQuestion),
                  const SizedBox(height: 12),
                  for (var i = 0; i < _incomeOptions.length; i++)
                    _radioTile(
                      label: _incomeLabels(s)[i],
                      selected: _incomeRole == _incomeOptions[i],
                      onTap: () =>
                          setState(() => _incomeRole = _incomeOptions[i]),
                    ),

                  if (_errorText != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 16, left: 4),
                      child: Text(
                        _errorText!,
                        style: const TextStyle(
                          color: Color(0xFFE57373),
                          fontSize: 13,
                        ),
                      ),
                    ),
                  const SizedBox(height: 24),
                ],
              ),
            ),
          ),

          // ── Save — big gold, always enabled (all optional) ──
          Padding(
            padding: EdgeInsets.fromLTRB(28, 8, 28, pad.bottom + 16),
            child: GestureDetector(
              onTap: _saving ? null : _save,
              child: Container(
                width: double.infinity,
                height: 58,
                decoration: BoxDecoration(
                  color: _gold,
                  borderRadius: BorderRadius.circular(18),
                ),
                alignment: Alignment.center,
                child: _saving
                    ? const SizedBox(
                        width: 24,
                        height: 24,
                        child: CircularProgressIndicator(
                          strokeWidth: 2.5,
                          color: Colors.black,
                        ),
                      )
                    : Text(
                        s.save,
                        style: const TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w700,
                          color: Colors.black,
                        ),
                      ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _sectionTitle(String text) => Text(
        text,
        style: GoogleFonts.inter(
          fontSize: 16,
          fontWeight: FontWeight.w700,
          color: Colors.white,
          height: 1.3,
        ),
      );

  /// Square checkbox row — gold border + fill when checked.
  Widget _checkTile({
    required String label,
    required bool checked,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 9),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            AnimatedContainer(
              duration: const Duration(milliseconds: 150),
              width: 24,
              height: 24,
              margin: const EdgeInsets.only(top: 1),
              decoration: BoxDecoration(
                color: checked ? _gold : Colors.transparent,
                borderRadius: BorderRadius.circular(6),
                border: Border.all(
                  color: checked ? _gold : Colors.white.withValues(alpha: 0.35),
                  width: 1.6,
                ),
              ),
              child: checked
                  ? const Icon(Icons.check_rounded,
                      size: 17, color: Colors.black)
                  : null,
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Text(
                label,
                style: GoogleFonts.inter(
                  fontSize: 15,
                  color: Colors.white.withValues(alpha: 0.85),
                  height: 1.35,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Round radio row — gold ring + dot when selected.
  Widget _radioTile({
    required String label,
    required bool selected,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 9),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            AnimatedContainer(
              duration: const Duration(milliseconds: 150),
              width: 24,
              height: 24,
              margin: const EdgeInsets.only(top: 1),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(
                  color:
                      selected ? _gold : Colors.white.withValues(alpha: 0.35),
                  width: 1.6,
                ),
              ),
              child: selected
                  ? Center(
                      child: Container(
                        width: 12,
                        height: 12,
                        decoration: const BoxDecoration(
                          shape: BoxShape.circle,
                          color: _gold,
                        ),
                      ),
                    )
                  : null,
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Text(
                label,
                style: GoogleFonts.inter(
                  fontSize: 15,
                  color: Colors.white.withValues(alpha: 0.85),
                  height: 1.35,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
