import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final assets = Directory('backend/dispatch_panel/assets').listSync().whereType<File>().toList();
  final panelFile = assets.firstWhere(
    (f) => f.path.endsWith('.js') &&
        f.readAsStringSync().contains('guard-pin panel_individual_notification_guard_test'),
  );
  final panel = panelFile.readAsStringSync().replaceAll('\r\n', '\n');
  final auditModule = assets
      .where((f) => f.path.contains('auditLog-') && f.path.endsWith('.js'))
      .map((f) => f.readAsStringSync().replaceAll('\r\n', '\n'))
      .firstWhere((s) => s.contains('/admin/notifications/send'));

  test('modal offers Individual and requires a selected recipient', () {
    expect(panel, contains('{id:"user",label:"Individual"}'));
    expect(panel, contains('r!=="user"||selected!==null'));
    expect(panel, contains('sendIndividualNotification({userId:selected.id'));
    expect(panel, contains('targetName:name'));
    expect(panel, contains('result?.delivery==="inbox_only"'));
    expect(panel, contains('individualRole,query.trim()'));
    expect(panel, contains('},300)'));
    expect(auditModule, contains('targetType:"user"'));
    expect(auditModule, contains('targetName:e.targetName'));
  });

  test('real recipient helper downloads every page and dedupes', () {
    final start = panel.indexOf('async function searchNotificationRecipients');
    final end = panel.indexOf('const Ws=', start);
    expect(start, isNonNegative);
    expect(end, greaterThan(start));
    final helpers = panel.substring(start, end);
    final scenario = '''
const calls = [];
const Ie = async (path, options) => {
  calls.push({path, options});
  if (calls.length === 1) {
    return {items: Array.from({length: 500}, (_, i) => ({id: i + 1})), has_more: true};
  }
  return {items: [{id: 501}, {id: 501}], has_more: false};
};
$helpers
(async () => {
  const people = await searchNotificationRecipients('rider', 'Ana Maria');
  if (people.length !== 501) throw new Error('expected 501 unique people, got ' + people.length);
  if (calls.length !== 2) throw new Error('expected two API calls');
  const [first, second] = calls;
  if (first.path !== '/admin/notification-recipients') throw new Error('wrong endpoint');
  if (first.options.query.role !== 'rider') throw new Error('wrong role');
  if (first.options.query.search !== 'Ana Maria') throw new Error('wrong search');
  if (first.options.query.limit !== 500) throw new Error('wrong page size');
  if (second.options.query.offset !== 500) throw new Error('wrong second offset');
  const name = notificationPersonName({first_name: 'Ana', last_name: 'Maria', id: 7});
  if (name !== 'Ana Maria') throw new Error('wrong display name: ' + name);
  const vehicle = notificationVehicle({vehicle: {year: 2024, make: 'Toyota', model: 'Camry', color: 'White', plate: 'ABC123'}});
  if (vehicle !== '2024 Toyota Camry White · ABC123') throw new Error('wrong vehicle: ' + vehicle);
  const city = notificationCity({drive_city: 'Miami', drive_state: 'FL'});
  if (city !== 'Miami, FL') throw new Error('wrong city: ' + city);
  console.log(JSON.stringify({count: people.length, secondOffset: second.options.query.offset}));
})().catch((error) => { console.error(error); process.exit(1); });
''';
    final result = Process.runSync('node', ['-e', scenario]);
    expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
    expect('${result.stdout}', contains('"count":501'));
    expect('${result.stdout}', contains('"secondOffset":500'));
  });

  test('wide card and result grid use classes present in the active CSS', () {
    for (final needle in [
      'className:"!max-w-4xl max-h-[70vh] overflow-y-auto"',
      'grid max-h-64 grid-cols-1',
      'md:grid-cols-2',
      'lg:grid-cols-3',
      'notificationVehicle(person)',
      'notificationCity(person)',
    ]) {
      expect(panel, contains(needle), reason: '$needle missing');
    }
    expect(panel, isNot(contains('max-h-48')));

    final html = File('backend/dispatch_panel/index.html').readAsStringSync();
    final match = RegExp(r'href="/panel/assets/(index-[^"]+\.css)"').firstMatch(html);
    expect(match, isNotNull);
    final css = File('backend/dispatch_panel/assets/${match!.group(1)}').readAsStringSync();
    for (final needle in ['max-w-4xl', 'max-h-\\[70vh\\]', 'max-h-64', 'md\\:grid-cols-2', 'lg\\:grid-cols-3']) {
      expect(css, contains(needle), reason: '$needle missing from active CSS');
    }
  });

  test('edited dispatch bundle parses', () {
    final result = Process.runSync('node', ['--check', panelFile.path]);
    expect(result.exitCode, 0, reason: '${result.stderr}');
  });
}
