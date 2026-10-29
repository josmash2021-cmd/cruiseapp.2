import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// A phone clock >30 min off makes the backend answer 401 "Timestamp
/// expired" on every signed call (owner decision 2026-10-29). That 401 is
/// NOT a session failure: the app must tell the user to fix the clock and
/// must never clear the token or refresh over it.
void main() {
  final api = File('lib/services/api_service.dart').readAsStringSync();
  final mainSrc = File('lib/main.dart').readAsStringSync();
  final l10n = File('lib/l10n/app_localizations.dart').readAsStringSync();

  test('the clock-skew 401 is intercepted before the generic 401 path', () {
    final skew = api.indexOf("body['detail'] == 'Timestamp expired'");
    // The generic path inside _parse (the periodic-request helper
    // _signal401 elsewhere has its own classification).
    final parseAt = api.indexOf('static Map<String, dynamic> _parse(');
    final generic = api.indexOf('_handleUnauthorized().ignore();', parseAt);
    expect(skew, isNonNegative);
    expect(generic, greaterThan(skew),
        reason: 'the skew branch must throw before refresh/clearToken runs');
    final branch = api.substring(skew, skew + 200);
    expect(branch, contains('onClockSkew?.call();'));
    expect(branch, contains("throw ApiException(401, 'clock_skew');"));
    expect(branch, isNot(contains('clearToken')));
  });

  test('main wires a guarded, rate-limited notice', () {
    expect(mainSrc, contains('ApiService.onClockSkew = () {'));
    expect(mainSrc, contains('if (_clockSkewDialogOpen) return;'));
    expect(mainSrc, contains('const Duration(seconds: 60)'));
    expect(mainSrc, contains('Navigator.of(dialogContext).pop()'));
    expect(mainSrc, contains('clockSkewTitle'));
    expect(mainSrc, contains('clockSkewBody'));
  });

  test('the copy exists in both languages', () {
    expect(l10n, contains('String get clockSkewTitle'));
    expect(l10n, contains('String get clockSkewBody'));
    expect(l10n, contains('hora automática'));
    expect(l10n, contains('automatic date & time'));
  });
}
