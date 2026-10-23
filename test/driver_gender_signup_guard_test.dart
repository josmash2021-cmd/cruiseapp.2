import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Guardian for the driver gender selector at registration (user spec
/// 2026-10-23): both driver signup surfaces collect gender next to the DOB,
/// gate Continue on it, and send `male`/`female` — the backend normalizes
/// (RegisterIn.gender + PATCH /auth/me `_SAFE_SELF_UPDATE_FIELDS`) and the
/// first-trip guide picks the dress photo by tier×gender.
void main() {
  final nameScreen =
      File('lib/screens/driver/driver_name_screen.dart').readAsStringSync();
  final signupScreen = File('lib/screens/driver/driver_signup_screen.dart')
      .readAsStringSync()
      .replaceAll('\r\n', '\n');
  final api = File('lib/services/api_service.dart').readAsStringSync();
  final l10n = File('lib/l10n/app_localizations.dart').readAsStringSync();
  final auth = File('backend/routers/auth.py').readAsStringSync();

  test('driver name screen (phone flow): selector, gate, PATCH payload', () {
    expect(nameScreen, contains('String? _gender;'));
    expect(nameScreen, contains('_genderChip('),
        reason: 'the two-option selector sits next to the DOB tile');
    expect(nameScreen, contains("_genderChip('male', S.of(context).genderMale)"));
    expect(nameScreen, contains("_genderChip(\n"),
        reason: 'chips for both options');
    expect(nameScreen, contains("'female', S.of(context).genderFemale)"));
    expect(nameScreen, contains('_dob != null &&\n        _gender != null;'),
        reason: 'Continue stays disabled until a gender is picked — same '
            'gate style as the DOB');
    expect(nameScreen, contains("'gender': _gender,"),
        reason: 'the PATCH /auth/me payload carries it');
  });

  test('legacy driver signup (3 steps): selector, step-0 gate, register '
      'payload', () {
    expect(signupScreen, contains('String? _gender;'));
    expect(signupScreen, contains('Widget _buildGenderPicker()'),
        reason: 'the selector lives right after _buildDobPicker()');
    expect(signupScreen, contains('_dob != null &&\n            _gender != null &&'),
        reason: 'step-0 Continue requires gender just like the DOB');
    expect(signupScreen, contains('dateOfBirth: _dobIso,\n        gender: _gender,'),
        reason: 'the register payload sends it (backend normalizes)');
    expect(signupScreen, contains('fieldHintGender'),
        reason: 'the red missing-field hint matches the other step-0 tiles');
  });

  test('ApiService.register accepts and forwards gender', () {
    expect(api, contains('String? gender,'));
    expect(api, contains("'gender': gender,"),
        reason: 'without the body entry the register call drops it');
  });

  test('l10n strings exist in ES and EN', () {
    // genderMale/genderFemale/genderSectionLabel are SHARED with the rider
    // photo+gender screen (they predated this spec) — the driver spec
    // retexted them to Hombre/Mujer; only fieldHintGender is new.
    for (final getter in [
      "String get genderSectionLabel => _es ? 'Género' : 'Gender';",
      "String get genderMale => _es ? 'Hombre' : 'Male';",
      "String get genderFemale => _es ? 'Mujer' : 'Female';",
      "String get fieldHintGender =>",
    ]) {
      expect(l10n, contains(getter));
    }
  });

  test('the backend already takes gender (register + PATCH)', () {
    expect(auth, contains('body.gender'),
        reason: 'RegisterIn.gender — normalized server-side');
    expect(auth, contains('"gender"'),
        reason: 'PATCH /auth/me safe self-update field');
  });
}
