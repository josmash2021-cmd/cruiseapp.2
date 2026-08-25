import 'package:flutter/material.dart';
import 'package:geocoding/geocoding.dart' as geo;
import 'package:geolocator/geolocator.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../config/page_transitions.dart';
import '../../data/us_cities.dart';
import '../../l10n/app_localizations.dart';
import '../../services/api_service.dart';
import 'driver_about_you_screen.dart';

/// Driver onboarding — Phase 2, step 1 ("Where do you plan to drive?").
///
/// The city card is pre-filled from the GPS fix (reverse geocode → "Pelham,
/// AL") when location permission is already granted — nothing new is
/// requested here. Tapping the card opens a curated picker of major US
/// cities grouped by state. `Next` persists `{drive_city, drive_state}` via
/// `PATCH /auth/me` and continues to [DriverAboutYouScreen].
class DriverDriveCityScreen extends StatefulWidget {
  const DriverDriveCityScreen({super.key});

  @override
  State<DriverDriveCityScreen> createState() => _DriverDriveCityScreenState();
}

class _DriverDriveCityScreenState extends State<DriverDriveCityScreen> {
  static const _navy = Color(0xFF14141A);
  static const _gold = Color(0xFFE8C547);

  UsCity? _city;
  bool _saving = false;
  String? _errorText;

  @override
  void initState() {
    super.initState();
    _prefillFromGps();
  }

  /// Pre-fill the card from the current fix. Permission is only *checked*,
  /// never requested — without a granted permission the card simply stays
  /// empty and tappable.
  Future<void> _prefillFromGps() async {
    try {
      final perm = await Geolocator.checkPermission();
      if (perm != LocationPermission.always &&
          perm != LocationPermission.whileInUse) {
        return;
      }
      final pos = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.low,
          timeLimit: Duration(seconds: 8),
        ),
      );
      final marks = await geo
          .placemarkFromCoordinates(pos.latitude, pos.longitude)
          .timeout(const Duration(seconds: 5));
      if (!mounted || marks.isEmpty || _city != null) return;
      final p = marks.first;
      final locality = (p.locality ?? '').trim();
      if (locality.isEmpty) return;
      var code = (p.administrativeArea ?? '').trim();
      if (code.length > 2) code = kUsStateNameToCode[code] ?? '';
      if (code.isEmpty) return;
      setState(() => _city = UsCity(locality, code));
    } catch (_) {
      // No fix / no geocoder — the field just stays empty.
    }
  }

  Future<void> _openCityPicker() async {
    final picked = await showModalBottomSheet<UsCity>(
      context: context,
      backgroundColor: _navy,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (context) => const _CityPickerSheet(),
    );
    if (picked != null && mounted) {
      setState(() => _city = picked);
    }
  }

  Future<void> _next() async {
    final city = _city;
    if (city == null || _saving) return;
    setState(() {
      _saving = true;
      _errorText = null;
    });
    try {
      await ApiService.updateMe({
        'drive_city': city.name,
        'drive_state': city.stateCode,
      });
      if (!mounted) return;
      Navigator.of(context).push(
        onboardingFadeSlideRoute(const DriverAboutYouScreen()),
      );
      setState(() => _saving = false);
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
    final canNext = _city != null;

    return Scaffold(
      backgroundColor: _navy,
      body: Column(
        children: [
          // ── Top bar — back only (no Help link) ──
          Padding(
            padding: EdgeInsets.only(top: pad.top + 8, left: 16, right: 16),
            child: Row(
              children: [
                GestureDetector(
                  onTap: () => Navigator.of(context).pop(),
                  child: const SizedBox(
                    width: 40,
                    height: 40,
                    child: Icon(
                      Icons.arrow_back_rounded,
                      color: Colors.white,
                      size: 24,
                    ),
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
                  const SizedBox(height: 32),
                  Text(
                    S.of(context).whereDoYouPlanToDrive,
                    style: GoogleFonts.poppins(
                      fontSize: 32,
                      fontWeight: FontWeight.w700,
                      letterSpacing: -0.5,
                      color: Colors.white,
                      height: 1.15,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    S.of(context).onboardingBasedOnCity,
                    style: GoogleFonts.inter(
                      fontSize: 15,
                      color: Colors.white.withValues(alpha: 0.65),
                    ),
                  ),
                  const SizedBox(height: 40),

                  // ── City card — pre-filled by GPS, tap to pick ──
                  GestureDetector(
                    onTap: _openCityPicker,
                    child: Container(
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.07),
                        borderRadius: BorderRadius.circular(18),
                        border: Border.all(
                          color: canNext
                              ? _gold
                              : Colors.white.withValues(alpha: 0.14),
                          width: canNext ? 1.6 : 1,
                        ),
                      ),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 18,
                      ),
                      child: Row(
                        children: [
                          Icon(
                            Icons.location_city_rounded,
                            color: canNext
                                ? _gold
                                : Colors.white.withValues(alpha: 0.45),
                            size: 26,
                          ),
                          const SizedBox(width: 14),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  S.of(context).yourCity,
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: Colors.white.withValues(alpha: 0.5),
                                  ),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  _city?.label ?? '—',
                                  style: TextStyle(
                                    fontSize: 18,
                                    fontWeight: FontWeight.w600,
                                    color: canNext
                                        ? Colors.white
                                        : Colors.white.withValues(alpha: 0.3),
                                  ),
                                ),
                              ],
                            ),
                          ),
                          Icon(
                            Icons.keyboard_arrow_down_rounded,
                            color: Colors.white.withValues(alpha: 0.45),
                            size: 26,
                          ),
                        ],
                      ),
                    ),
                  ),
                  if (_errorText != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 12, left: 4),
                      child: Text(
                        _errorText!,
                        style: const TextStyle(
                          color: Color(0xFFE57373),
                          fontSize: 13,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),

          // ── Next — big gold, safe area ──
          Padding(
            padding: EdgeInsets.fromLTRB(28, 8, 28, pad.bottom + 16),
            child: GestureDetector(
              onTap: canNext && !_saving ? _next : null,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                width: double.infinity,
                height: 58,
                decoration: BoxDecoration(
                  color: canNext ? _gold : _gold.withValues(alpha: 0.25),
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
                        S.of(context).next,
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w700,
                          color: canNext
                              ? Colors.black
                              : Colors.black.withValues(alpha: 0.45),
                        ),
                      ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Bottom sheet with the curated US city list, grouped by state.
class _CityPickerSheet extends StatelessWidget {
  const _CityPickerSheet();

  @override
  Widget build(BuildContext context) {
    final pad = MediaQuery.of(context).padding;

    return FractionallySizedBox(
      heightFactor: 0.85,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 12),
          Center(
            child: Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.25),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 18, 24, 8),
            child: Text(
              S.of(context).selectYourCity,
              style: GoogleFonts.poppins(
                fontSize: 20,
                fontWeight: FontWeight.w700,
                color: Colors.white,
              ),
            ),
          ),
          Expanded(
            child: ListView.builder(
              padding: EdgeInsets.only(bottom: pad.bottom + 16),
              itemCount: kUsCitiesByState.length,
              itemBuilder: (context, i) {
                final group = kUsCitiesByState[i];
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(24, 18, 24, 4),
                      child: Text(
                        group.stateName,
                        style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                          color: Color(0xFFE8C547),
                          letterSpacing: 0.4,
                        ),
                      ),
                    ),
                    for (final city in group.cities)
                      InkWell(
                        onTap: () => Navigator.of(context).pop(city),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 24,
                            vertical: 13,
                          ),
                          child: Row(
                            children: [
                              Expanded(
                                child: Text(
                                  city.name,
                                  style: const TextStyle(
                                    fontSize: 16,
                                    color: Colors.white,
                                  ),
                                ),
                              ),
                              Text(
                                city.stateCode,
                                style: TextStyle(
                                  fontSize: 14,
                                  color: Colors.white.withValues(alpha: 0.4),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
