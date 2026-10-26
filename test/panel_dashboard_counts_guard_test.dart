import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _bundlePath() {
  final html = File('backend/dispatch_panel/index.html').readAsStringSync();
  final match =
      RegExp(r'src="/panel/assets/(index-[^"]+\.js)"').firstMatch(html);
  if (match == null) throw StateError('Entry bundle not found in index.html');
  return 'backend/dispatch_panel/assets/${match.group(1)}';
}

void main() {
  final bundle = File(_bundlePath()).readAsStringSync();

  test('pending and waitlist counts stay with their own role', () {
    for (final needle in [
      'ridersPending:o.rows.filter(h=>h.role==="rider"&&h.status==="pending").length',
      'driversPending:o.rows.filter(h=>h.role==="driver"&&h.status==="pending").length',
      'driversWaitlist:o.rows.filter(h=>h.role==="driver"&&h.status==="waitlist").length',
      'case"riders":return t.ridersPending;case"drivers":return t.driversPending+t.driversWaitlist;',
      'guard-pin panel_dashboard_counts_guard_test',
    ]) {
      expect(bundle, contains(needle));
    }
    expect(bundle, isNot(contains('case"riders":return t.verifPending')),
        reason: 'the Riders badge must not use the shared verification total');
    expect(bundle,
        contains('verifPending:o.rows.filter(h=>h.status==="pending").length'),
        reason: 'the Verification card keeps its own pending total');
  });

  test('real bundle logic renders role-specific labels and badges', () {
    final functionsStart = bundle.indexOf('function wn');
    final functionsEnd = bundle.indexOf('function In', functionsStart);
    final homeStart = bundle.indexOf('function En(');
    final countsStart = bundle.indexOf('const v=s.trips', homeStart);
    final countsEnd = bundle.indexOf('},_=', countsStart);
    expect(functionsStart, isNonNegative);
    expect(functionsEnd, greaterThan(functionsStart));
    expect(countsStart, isNonNegative);
    expect(countsEnd, greaterThan(countsStart));
    final cardFunctions = bundle.substring(functionsStart, functionsEnd);
    final countLogic = bundle.substring(countsStart, countsEnd + 1);
    final scenario = '''
$cardFunctions
const rows = [
  {role: 'rider', status: 'pending'},
  {role: 'rider', status: 'waitlist'},
  {role: 'rider', status: 'approved'},
  {role: 'driver', status: 'pending'},
  {role: 'driver', status: 'pending'},
  {role: 'driver', status: 'waitlist'},
  {role: 'driver', status: 'approved'},
];
const x = (() => {
  const K = () => false, be = () => false;
  const s = {trips: []}, l = {pending: []}, p = {chats: []};
  const u = {unreadCount: 0};
  const i = {people: Array(49)}, a = {people: Array(289)};
  const o = {rows};
  $countLogic;
  return x;
})();
const actual = {
  ridersBadge: Pn({id: 'riders'}, x),
  driversBadge: Pn({id: 'drivers'}, x),
  verificationBadge: Pn({id: 'verificacion'}, x),
  ridersLabel: wn({id: 'riders'}, x),
  driversLabel: wn({id: 'drivers'}, x),
};
const expected = {
  ridersBadge: 1,
  driversBadge: 3,
  verificationBadge: 3,
  ridersLabel: '49 usuarios · 1 pendiente',
  driversLabel: '289 conductores · 2 pendientes · 1 en espera',
};
if (JSON.stringify(actual) !== JSON.stringify(expected)) {
  console.error(JSON.stringify(actual));
  process.exit(1);
}
console.log(JSON.stringify(actual));
''';
    final result = Process.runSync('node', ['-e', scenario]);
    expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
    expect('${result.stdout}', contains('"driversBadge":3'));
  });

  test('the edited entry bundle parses', () {
    final result = Process.runSync('node', ['--check', _bundlePath()]);
    expect(result.exitCode, 0, reason: '${result.stderr}');
  });
}
