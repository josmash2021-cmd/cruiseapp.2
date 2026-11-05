import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Owner 2026-11-05: "esta página ya no debe de salir cuando cierro y abro
/// la app, páginas viejas no deben salir, elimínala" — the old trip page
/// ("Ride for …", mini map, Arrived slider). Every way into the trip goes
/// straight to navigation, and nothing in navigation uncovers the page.
void main() {
  final trip = File('lib/screens/driver/driver_trip_accept_screen.dart')
      .readAsStringSync()
      .replaceAll('\r\n', '\n');

  test('every way in lands in navigation', () {
    expect(trip, contains('    this.autoNav = true,'));
    // No caller turns it off.
    for (final f in Directory('lib').listSync(recursive: true)) {
      if (f is! File || !f.path.endsWith('.dart')) continue;
      expect(f.readAsStringSync(), isNot(contains('autoNav: false')),
          reason: '${f.path} would open the old trip page');
    }
  });

  test('back inside navigation stays in navigation', () {
    final i = trip.indexOf('return PopScope(');
    final pop = trip.substring(i, i + 500);
    expect(pop, contains('if (_navMode) return;'));
    expect(pop, isNot(contains('_exitNavMode();')));
  });
}
