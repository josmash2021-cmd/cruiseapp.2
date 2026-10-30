import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Guardian for the 12h-cap → 6h rest flow (2026-10-27 owner spec): after the
/// cap the GO button must show a rest countdown, then animate to "ya puedes
/// conectarte" before returning to the normal GO ONLINE button. Pins the
/// state, both cap triggers, the boot restore, the label states and the
/// AnimatedSwitcher that carries the after-rest transition.
void main() {
  final screen = File('lib/screens/driver/driver_online_screen.dart')
      .readAsStringSync()
      .replaceAll('\r\n', '\n');
  final offline = File('lib/screens/driver/driver_online_offline.dart')
      .readAsStringSync()
      .replaceAll('\r\n', '\n');
  final controller = File('lib/screens/driver/driver_online_controller.dart')
      .readAsStringSync()
      .replaceAll('\r\n', '\n');
  final l10n = File('lib/l10n/app_localizations.dart')
      .readAsStringSync()
      .replaceAll('\r\n', '\n');
  final compactOffline = offline.replaceAll(RegExp(r'\s+'), ' ');
  final compactController = controller.replaceAll(RegExp(r'\s+'), ' ');

  test('both 12h cap paths start a persisted 6h rest', () {
    const trigger =
        '_setRestUntil(DateTime.now().add(const Duration(hours: 6)))';
    expect(compactController.split(trigger).length - 1, 2);
    expect(offline, contains("p.setInt('driver_rest_until'"));
    expect(screen, contains('DateTime? _restUntil;'));
    expect(screen, contains('DateTime? _restJustFinishedAt;'));
    expect(screen, contains('Timer? _restTickTimer;'));
    expect(screen, contains('_restoreRestUntil();'));
    expect(screen, contains('_restTickTimer?.cancel();'));
  });

  test('rest timer ticks countdown, holds ready, then restores normal', () {
    expect(offline, contains('void _onRestTick()'));
    expect(offline, contains('static String _fmtRest(Duration d)'));
    expect(offline, contains('final finishedAt = _restJustFinishedAt;'));
    expect(offline, contains('const Duration(milliseconds: 2500)'));
    expect(offline, contains('_restJustFinishedAt = null;'));
  });

  test('the GO tap and the direct handler both enforce the rest', () {
    expect(
      compactOffline,
      contains(
        'final restRemaining = _restUntil?.difference(DateTime.now()); '
        'if (restRemaining != null && restRemaining > Duration.zero) '
        '{ _showRestRemaining(restRemaining); return; }',
      ),
    );
    // The GO button routes every tap through _goTapAction() (2026-10-29);
    // the rest check is its FIRST branch.
    expect(compactOffline, contains('onTap: _goTapAction(),'));
    expect(
      compactOffline,
      contains('return () => _showRestRemaining(restRemaining);'),
    );
  });

  test('only phase changes animate, not every countdown tick', () {
    expect(offline, contains('final resting ='));
    expect(offline, contains('final readyRecently ='));
    expect(offline, contains('restTitle'));
    expect(offline, contains('restReady'));
    expect(offline, contains('AnimatedSwitcher('));
    expect(
      compactOffline,
      contains(
        "key: ValueKey<String>(resting ? 'resting' : readyRecently "
        "? 'ready' : pillLabel)",
      ),
    );
  });

  test('rest strings exist ES/EN', () {
    expect(l10n, contains("String get restTitle => _es ? 'Descanso' : 'Rest'"));
    expect(
      l10n,
      contains(
        "String get restReady => _es ? 'Ya puedes conectarte' : 'You can go online'",
      ),
    );
    expect(l10n, contains('String restRemainingLabel(String time)'));
    expect(l10n, contains("'Rest remaining: \$time'"));
  });

  test('server rest synchronizes the countdown and expires stale local rest',
      () {
    expect(offline, contains("result.containsKey('rest_until')"));
    expect(offline, contains('DateTime.tryParse(serverRestRaw)'));
    expect(offline, contains('serverRest.isAfter(DateTime.now())'));
    expect(offline, contains("p.setInt('driver_rest_until', 0)"));
    expect(offline, contains("r == 'shift_rest_required'"));
  });

  test('rest clears live when the server removes or expires the deadline', () {
    expect(offline, contains('_restSyncTicks >= 15'));
    expect(offline, contains('unawaited(_checkVehicleDocStatus())'));
    expect(offline,
        contains('else if (_serverRestResponseKnown && _restUntil != null)'));
  });

  test('every online writer treats the rest 403 as terminal', () {
    expect(
        compactController.split("e.message == 'shift_rest_required'").length -
            1,
        4);
    expect(controller, contains('void _onShiftRestKick()'));
    expect(controller, contains('_onShiftRestKick();'));
    expect(controller, contains('await _checkVehicleDocStatus();'));
  });
}
