import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final sources = Directory('backend/dispatch_panel/assets')
      .listSync()
      .whereType<File>()
      .where((file) => file.path.endsWith('.js'))
      .map((file) => file.readAsStringSync().replaceAll('\r\n', '\n'))
      .toList();
  final zoneEditor =
      sources.firstWhere((s) => s.contains('ZonasScreen'), orElse: () => '');
  final demand =
      sources.firstWhere((s) => s.contains('liveSectorRows'), orElse: () => '');

  test('zone editor and demand read through the Dispatch session', () {
    expect(zoneEditor, isNotEmpty);
    expect(demand, isNotEmpty);
    expect(zoneEditor,
        contains('async function nt(){return We("/admin/zones/sectors")}'));
    expect(demand, contains('Ie("/admin/zones/sectors")'));
    for (final source in [zoneEditor, demand]) {
      expect(source, isNot(contains('We("/zones/sectors")')),
          reason: 'the public endpoint requires app HMAC, not a panel cookie');
      expect(source, isNot(contains('Ie("/zones/sectors")')),
          reason:
              'the public endpoint returns 422 Field required to the panel');
    }
  });

  test('the app public route and Dispatch admin route stay separate', () {
    final system = File('backend/routers/system.py').readAsStringSync();
    expect(
        system,
        contains(
            '@router.get("/zones/sectors", dependencies=[Depends(_verify_api_key)])'));
    final admin = File('backend/routers/admin.py').readAsStringSync();
    expect(admin, contains('@router.get("/admin/zones/sectors"'));
    expect(admin, contains('_require_dispatch_auth'));
  });
}
