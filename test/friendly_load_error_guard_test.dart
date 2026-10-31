import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Guardian for the owner report of 2026-10-31: with no signal the
/// scheduled-rides sheet printed "ClientException with SocketException: HTTP
/// connection timed out after 0:00:03…" — and kept printing it after the
/// signal came back, because a successful reload never cleared the error.
void main() {
  String read(String p) =>
      File(p).readAsStringSync().replaceAll('\r\n', '\n');
  final map = read('lib/screens/driver/scheduled_rides_map_screen.dart');
  final list = read('lib/screens/driver/scheduled_rides_screen.dart');
  final mine = read('lib/screens/driver/driver_scheduled_trips_screen.dart');
  final helper = read('lib/utils/friendly_load_error.dart');
  final l10n = read('lib/l10n/app_localizations.dart');

  test('no ride list ever shows the raw exception text', () {
    for (final src in [map, list, mine]) {
      expect(src, contains('friendlyLoadError(context, e'));
    }
    expect(map, isNot(contains(': e.toString();')));
    expect(list, isNot(contains('_errorAvail = e.toString();')));
    expect(list, isNot(contains('_errorMine = e.toString();')));
    expect(mine, isNot(contains('_error = e.toString();')));
    expect(helper, contains('return s.loadRidesFailed;'));
    expect(l10n, contains("'No pudimos cargar los viajes. Revisa tu señal e intenta de nuevo.'"));
  });

  test('data arriving clears an earlier failure', () {
    expect(map, contains('if (_errorAvail != null) setState(() => _errorAvail = null);'),
        reason: 'the 15 s poll often brings back the SAME list');
    expect(map, contains('_freshLoaded = true;\n        // Data arrived'));
    expect(list, contains('_errorAvail = null; // data arrived'));
    expect(list, contains('_errorMine = null; // data arrived'));
  });
}
