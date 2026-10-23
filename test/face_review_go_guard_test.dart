import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Guardian for the dress-code face-review GO states (owner spec
/// 2026-10-23): a driver rejected for attire gets a red "Verificar" GO that
/// re-runs liveness; while the selfie sits in manual dispatch review the GO
/// is a disabled grey "Selfie en revisión" with a 30 s canGoOnline poll;
/// and the collapsed GO circle does not render in either state (the circle
/// rule). Plus: the "You're now online!" intro trigger moved to a 10 s
/// timer inside _enterOnlineMode, and both face-check pushes route in
/// main.dart.
void main() {
  final offline = File('lib/screens/driver/driver_online_offline.dart')
      .readAsStringSync()
      .replaceAll('\r\n', '\n');
  final screen = File('lib/screens/driver/driver_online_screen.dart')
      .readAsStringSync()
      .replaceAll('\r\n', '\n');
  final controller = File('lib/screens/driver/driver_online_controller.dart')
      .readAsStringSync()
      .replaceAll('\r\n', '\n');
  final api = File('lib/services/api_service.dart')
      .readAsStringSync()
      .replaceAll('\r\n', '\n');
  final main = File('lib/main.dart').readAsStringSync();
  final l10n = File('lib/l10n/app_localizations.dart').readAsStringSync();

  test('the two flags live on the screen and are read from canGoOnline', () {
    expect(screen, contains('bool _faceReviewRequired = false;'));
    expect(screen, contains('bool _faceCheckPending = false;'));
    expect(offline, contains("result['face_review_required'] == true"));
    expect(offline, contains("result['face_check_pending'] == true"),
        reason: '_checkVehicleDocStatus reads both from the same payload');
    expect(offline, contains('_faceReviewRequired = faceReview;'));
    expect(offline, contains('_faceCheckPending = facePending;'));
  });

  test('submitFaceCheck returns the parsed map with pending_review', () {
    expect(api, contains('static Future<Map<String, dynamic>?> submitFaceCheck('));
    expect(api, isNot(contains("resp['pending_review']")),
        reason: 'the API layer itself does not read the flag');
    expect(api, contains('jsonDecode(res.body)'));
    expect(api, isNot(contains('static Future<bool> submitFaceCheck')),
        reason: 'the bool signature is gone');
  });

  test('GO state machine: red Verificar / grey disabled pending', () {
    expect(offline, contains('int get _faceGateState =>'),
        reason: '0 normal · 1 verify · 2 pending');
    expect(offline, contains('S.of(context).goVerify'),
        reason: 'the verify state says Verificar/Verify');
    expect(offline, contains('S.of(context).faceReviewPending'),
        reason: 'the pending state says Selfie en revisión');
    expect(offline, contains(': faceState == 2\n              ? null'),
        reason: 'pending review = dead button (onTap null) — the dispatch '
            'GO gate outranks it but never resurrects the flip');
    expect(offline, contains("const Color(0xFFD32F2F)"),
        reason: 'the verify state paints RED');
    expect(offline, contains('? _onFaceVerifyTap'),
        reason: 'verify routes to the liveness flow, never the flip');
  });

  test('the verify tap runs liveness and locks GO on pending_review', () {
    expect(offline, contains('Future<void> _onFaceVerifyTap() async {'));
    expect(offline, contains('const SelfieCheckScreen()'),
        reason: 'the SAME selfie check as the daily gate — one front-photo '
            'screen, never the 4-step biometric page (2026-10-23 spec)');
    expect(offline, isNot(contains('FaceLivenessScreen')),
        reason: 'the biometric 4-step page is signup-only now');
    expect(
        offline
            .split('const SelfieCheckScreen()')
            .length,
        3,
        reason: 'BOTH call sites (the daily GO gate and _onFaceVerifyTap) '
            'use it');
    expect(offline, contains("resp['pending_review'] == true"),
        reason: 'manual review = do NOT connect');
    expect(offline, contains('_faceCheckPending = true;'));
    expect(offline, contains('Timer.periodic(const Duration(seconds: 30)'),
        reason: 'the 30 s poll auto-clears when dispatch approves');
    expect(offline, contains('_faceReviewTimer?.cancel();'),
        reason: 'the poll dies with the state');
  });

  test('the circle rule: no collapsed GO in a non-normal face state', () {
    expect(offline, contains('final faceGateHidden = _faceGateState != 0'),
        reason: 'owner spec, literal: the collapsed circle/pill does not '
            'render with the sheet closed in verify/review');
    expect(offline, contains('ignoring: hidden || faceGateHidden'));
  });

  test('the existing daily face-check gate runs first, now Map-aware', () {
    expect(offline, contains('if (_docStatusLoaded && _faceCheckDue)'),
        reason: 'the auto-approved daily gate is intact and runs earlier '
            'in the same tap');
    expect(offline, isNot(contains('final ok = await ApiService.submitFaceCheck')),
        reason: 'the old bool call is gone');
  });

  test('the online intro fires 10 s into the shift, not on the GO tap', () {
    expect(
        controller,
        contains('Timer(const Duration(seconds: 10), _maybeShowOnlineIntro)'));
    final enterFn = controller.indexOf('Future<void> _enterOnlineMode');
    final timerIdx =
        controller.indexOf('Timer(const Duration(seconds: 10)');
    expect(timerIdx, greaterThan(enterFn),
        reason: 'armed at the END of _enterOnlineMode');
    expect(offline, isNot(contains('unawaited(_maybeShowOnlineIntro())')),
        reason: 'the tap trigger is dead');
    expect(controller, contains('_introTimer?.cancel();'),
        reason: 'cancelled on exit and dispose');
    expect(controller, contains("getBool('online_intro_seen_v1')"),
        reason: 'once per phone flag intact');
    expect(controller, contains('kOnlineIntroAlwaysEmails.contains(email)'),
        reason: 'the owner demo account still sees it on every activation');
  });

  test('both face-check pushes route in main.dart, role-gated driver', () {
    expect(main, contains("type == 'face_check_rejected'"));
    expect(main, contains("type == 'face_check_approved'"));
    expect(main, contains('_handleFaceCheckResult('));
    expect(main, contains("if (mode != 'driver') return;"),
        reason: 'role-gated like every driver push');
    expect(main, contains('DriverOnlineScreen.faceReviewNotifier.value++'),
        reason: 'the live screen re-reads the gate (shiftEndedNotifier '
            'pattern)');
    expect(main, contains('faceRejectedTitle'));
    expect(main, contains('faceApprovedTitle'));
    expect(screen, contains('faceReviewNotifier.addListener(_onFaceReviewPush)'));
  });

  test('the six l10n strings exist ES/EN', () {
    for (final g in [
      "String get goVerify => _es ? 'Verificar' : 'Verify';",
      "'Selfie en revisión'",
      "'Selfie under review'",
      "'Selfie rechazada'",
      "'Selfie rejected'",
      'normas de vestimenta',
      'dress code rules',
      "'✅ Selfie aprobada'",
      "'✅ Selfie approved'",
      "'Ya puedes conectarte y recibir viajes'",
      "'You can go online and receive rides now'",
    ]) {
      expect(l10n, contains(g), reason: 'missing: $g');
    }
  });
}
