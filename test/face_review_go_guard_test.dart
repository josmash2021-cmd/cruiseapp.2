import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Guardian for the dress-code face-review GO states (owner spec
/// 2026-10-23): a driver rejected for attire gets a GREY static
/// "Verificar" GO (the owner killed the red the same day — "en vez de rojo
/// gris, sin animación; la animación es solo del GO ONLINE") that re-runs
/// the selfie flow; while the selfie sits in manual dispatch review the GO
/// is a disabled grey "Selfie en revisión" with a 30 s canGoOnline poll;
/// and the collapsed GO circle does not render in either state (the circle
/// rule). The selfie screen HOLDS a verifying loader after the shot and
/// closes already-connecting on approve. Plus: the "You're now online!"
/// intro trigger moved to a 10 s timer inside _enterOnlineMode, and both
/// face-check pushes route in main.dart.
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
  final socket = File('lib/services/socket_service.dart')
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
    expect(
        api, contains('static Future<Map<String, dynamic>?> submitFaceCheck('));
    expect(api, isNot(contains("resp['pending_review']")),
        reason: 'the API layer itself does not read the flag');
    expect(api, contains('jsonDecode(res.body)'));
    expect(api, isNot(contains('static Future<bool> submitFaceCheck')),
        reason: 'the bool signature is gone');
  });

  test('GO state machine: grey static Verificar / grey disabled pending', () {
    expect(offline, contains('int get _faceGateState =>'),
        reason: '0 normal · 1 verify · 2 pending');
    expect(offline, contains('S.of(context).goVerify'),
        reason: 'the verify state says Verificar/Verify');
    expect(offline, contains('S.of(context).faceReviewPending'),
        reason: 'the pending state says Selfie en revisión');
    expect(offline, contains(': faceState == 2\n              ? null'),
        reason: 'pending review = dead button (onTap null) — the dispatch '
            'GO gate outranks it but never resurrects the flip');
    expect(offline, isNot(contains("const Color(0xFFD32F2F)")),
        reason: 'the RED verify died by owner spec 2026-10-23');
    expect(offline, isNot(contains("const Color(0xFF9A1B1B)")),
        reason: 'the red gradient bottom died with it');
    final compactOffline = offline.replaceAll(RegExp(r'\s+'), ' ');
    expect(compactOffline,
        contains('faceState != 0 ? const Color(0xFF6B6B70)'),
        reason: 'verify AND pending paint the same dead grey');
    expect(compactOffline,
        contains('faceState != 0 ? const Color(0xFF4A4A4F)'),
        reason: 'grey gradient bottom too');
    expect(offline, contains('? _onFaceVerifyTap'),
        reason: 'verify routes to the selfie flow, never the flip');
  });

  test('animation belongs to GO ONLINE only (owner spec 2026-10-23)', () {
    final compactOffline = offline.replaceAll(RegExp(r'\s+'), ' ');
    expect(
        compactOffline,
        contains('final igniteScale = faceState == 0 && !_goOnlineDisabled '
            '? (_goIgniteAnim?.value ?? 1.0) : 1.0;'),
        reason: 'no ignite pop in verify/pending/paused');
    expect(
        compactOffline,
        contains(
            'morph > 0.5 && faceState == 0 && !resting && !_goOnlineDisabled'),
        reason: 'no gloss sweep on a grey face-gated GO');
    expect(
        compactOffline,
        contains(
            'morph <= 0.5 && faceState == 0 && !resting && !_goOnlineDisabled'),
        reason: 'no radar sweep on a grey face-gated GO');
    expect(offline, contains('(faceState != 0 ? 0.25 : 1.0)'),
        reason: 'the glow dims in BOTH non-normal face states');
  });

  test('the verify tap connects the moment the screen says approved', () {
    expect(offline, contains('Future<void> _onFaceVerifyTap() async {'));
    expect(offline, contains('const SelfieCheckScreen()'),
        reason: 'the SAME selfie check as the daily GO gate — one front-photo '
            'screen, never the 4-step biometric page (2026-10-23 spec)');
    expect(offline, isNot(contains('FaceLivenessScreen')),
        reason: 'the biometric 4-step page is signup-only now');
    expect(offline.split('const SelfieCheckScreen()').length, 3,
        reason: 'BOTH call sites (the daily GO gate and _onFaceVerifyTap) '
            'use it');
    // Owner spec 2026-10-23: the page HOLDS its verifying loader until the
    // decision — approve closes already-connecting, pending falls back to
    // the grey review GO, rejected-again re-arms verify with the dialog.
    expect(offline, isNot(contains('ApiService.submitFaceCheck')),
        reason: 'the upload moved INSIDE the selfie screen');
    expect(offline, contains("res!['pending'] == true"),
        reason: 'dispatch undecided (ceiling/escape) = do NOT connect');
    expect(offline, contains("res['approved'] == false"));
    expect(offline, contains("res['approved'] == true"));
    expect(offline, contains('_faceCheckPending = true;'));
    final verifyFn = offline.split('Future<void> _onFaceVerifyTap()').last;
    final approvedIdx = verifyFn.indexOf("res['approved'] == true");
    final goIdx = verifyFn.indexOf('_onGoTap();', approvedIdx);
    expect(goIdx, greaterThan(approvedIdx),
        reason: 'approved → _onGoTap in the same breath (chime + flip ride '
            'with the page closing — zero home detour)');
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
    expect(
        offline, isNot(contains('final ok = await ApiService.submitFaceCheck')),
        reason: 'the old bool call is gone');
  });

  test('the online intro fires 10 s into the shift, not on the GO tap', () {
    expect(controller, contains('Timer.periodic(const Duration(seconds: 1)'));
    expect(controller, contains('timer.tick < 10'));
    final enterFn = controller.indexOf('Future<void> _enterOnlineMode');
    final timerIdx =
        controller.indexOf('Timer.periodic(const Duration(seconds: 1)');
    expect(timerIdx, greaterThan(enterFn),
        reason: 'armed at the END of _enterOnlineMode');
    expect(offline, isNot(contains('unawaited(_maybeShowOnlineIntro())')),
        reason: 'the tap trigger is dead');
    expect(controller, contains('_introTimer?.cancel();'),
        reason: 'cancelled on exit and dispose');
    expect(controller, contains("getInt('online_intro_last_seen_at')"),
        reason: 'a 24 h timestamp, not a one-time seen flag');
    expect(controller, contains('onlineIntroDueNow(lastSeenMs, nowMs)'));
    expect(controller, isNot(contains('onlineIntroAlwaysAccount')));
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
    expect(
        screen, contains('faceReviewNotifier.addListener(_onFaceReviewPush)'));
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

  test('the reject reaches the live app: socket channel + exit online', () {
    // Owner report 2026-10-23: "le doy rechazar y no desconecta al driver
    // si esta conectado y el GO no se pone rojo". The kick used to live
    // only in the DB + an FCM that acted on banner TAP — the connected
    // app's heartbeats re-onlined the driver within seconds.
    expect(socket, contains('_faceCheckReviewController'),
        reason: 'the broadcast controller exists');
    expect(socket, contains("on('face_check_reviewed'"),
        reason: 'the socket listener is registered');
    expect(socket, contains('faceCheckReviewStream'),
        reason: 'the public stream exists');
    expect(socket.split('_faceCheckReviewController.close()').length, 2,
        reason: 'dispose() closes it (recreated on reconnect)');
    expect(
        screen,
        contains(
            'SocketService.faceCheckReviewStream.listen(_onFaceCheckReviewed)'),
        reason: 'DriverOnlineScreen subscribes in initState');
    expect(screen, contains('_faceCheckReviewSub?.cancel();'),
        reason: 'the subscription dies in dispose');
    expect(offline,
        contains('void _onFaceCheckReviewed(Map<String, dynamic> data)'));
    expect(offline, contains('void _showFaceRejectedDialog()'),
        reason: 'the live path explains the cut (no banner tap involved)');
    final handler = offline.split('void _onFaceCheckReviewed').last;
    expect(handler, contains('unawaited(_exitOnlineMode())'),
        reason: 'rejected && !deferred && online → the shift ends NOW');
    expect(handler, contains('if (approved || deferred) return;'),
        reason: 'approve = silent unlock; deferred = rider aboard wins, '
            'the cut lands at trip close');
  });

  test('the heartbeats can never undo the kick (terminal 403)', () {
    expect(controller, contains('void _onFaceReviewKick()'),
        reason: 'rollback helper: exit online + re-read gate flags');
    expect(
        controller.split("e.message == 'face_review_required'").length - 1, 4,
        reason: 'GO tap + background heartbeat + 5 s GPS stream + offers '
            'poll heartbeat — EVERY is_online:true writer treats the 403 as '
            'terminal (same class as go_online_disabled)');
    final kickFn = controller.split('void _onFaceReviewKick()').last;
    expect(kickFn, contains('unawaited(_exitOnlineMode())'));
    expect(kickFn, contains('unawaited(_checkVehicleDocStatus())'),
        reason: 'the fresh read sets _faceReviewRequired → GO red Verificar');
  });
}
