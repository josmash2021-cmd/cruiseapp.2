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

  test('real recipient search helper calls the signed roster API', () {
    final start = panel.indexOf('async function searchNotificationRecipients');
    final end = panel.indexOf('const Ws=', start);
    expect(start, isNonNegative);
    expect(end, greaterThan(start));
    final helpers = panel.substring(start, end);
    final scenario = '''
const calls = [];
const Ie = async (path, options) => {
  calls.push({path, options});
  return [];
};
$helpers
(async () => {
  await searchNotificationRecipients('rider', 'Ana Maria');
  if (calls.length !== 1) throw new Error('expected one API call');
  const call = calls[0];
  if (call.path !== '/admin/users') throw new Error('wrong endpoint');
  if (call.options.query.role !== 'rider') throw new Error('wrong role');
  if (call.options.query.search !== 'Ana Maria') throw new Error('wrong search');
  if (call.options.query.limit !== 20) throw new Error('wrong limit');
  const name = notificationPersonName({first_name: 'Ana', last_name: 'Maria', id: 7});
  if (name !== 'Ana Maria') throw new Error('wrong display name: ' + name);
  console.log(JSON.stringify(call));
})().catch((error) => { console.error(error); process.exit(1); });
''';
    final result = Process.runSync('node', ['-e', scenario]);
    expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
    expect('${result.stdout}', contains('"/admin/users"'));
  });

  test('edited dispatch bundle parses', () {
    final result = Process.runSync('node', ['--check', panelFile.path]);
    expect(result.exitCode, 0, reason: '${result.stderr}');
  });
}
