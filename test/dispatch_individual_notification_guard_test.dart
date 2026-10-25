import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:cruise_app/services/local_data_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final mainDart = File('lib/main.dart').readAsStringSync();
  final riderInbox = File('lib/screens/inbox_screen.dart').readAsStringSync();
  final driverInbox = File('lib/screens/driver/driver_inbox_screen.dart')
      .readAsStringSync();

  test('push tap opens the inbox for the actual session role', () {
    expect(mainDart, contains("if (type == 'dispatch_notification')"));
    expect(mainDart, contains('DriverInboxScreen()'));
    expect(mainDart, contains('InboxScreen()'));
    expect(mainDart, contains('UserSession.getMode().then((mode)'));
    expect(mainDart, contains(": 'server_\$notificationId'"));
  });

  test('rider merges fresh dispatch rows with local history without duplicates', () {
    expect(riderInbox, contains('ApiService.getNotifications(useCache: false)'));
    expect(riderInbox, contains(".where((n) => n['type'] == 'dispatch_notification')"));
    expect(riderInbox, contains("id: 'server_\${n['id']}'"));
    expect(riderInbox, contains('for (final item in localItems) item.id: item'));
    expect(riderInbox, contains('for (final item in serverItems) item.id: item'));
    expect(riderInbox, contains('ApiService.markAllNotificationsRead()'));
    expect(riderInbox, contains('ApiService.deleteNotification(serverId)'));
    expect(riderInbox, contains('LocalDataService.removeNotification(item.id)'));
    expect(riderInbox, contains('S.of(context).failedToDelete'));
  });

  test('driver renders dispatch notices as gold bell alerts', () {
    expect(driverInbox,
        contains("if (raw == 'dispatch_notification') return Icons.notifications_rounded"));
    expect(driverInbox,
        contains("if (raw == 'dispatch_notification') return _gold"));
  });

  group('local notification identity', () {
    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      await prefs.clear();
      await LocalDataService.init();
    });

    test('stable server ids dedupe and remove only the intended item', () async {
      await LocalDataService.addNotification(
        id: 'server_42',
        title: 'Dispatch',
        message: 'Original',
        type: 'dispatch_notification',
      );
      await LocalDataService.addNotification(
        id: 'server_42',
        title: 'Duplicate',
        message: 'Must not appear',
        type: 'dispatch_notification',
      );
      await LocalDataService.addNotification(
        title: 'Local',
        message: 'Keep me',
      );

      var items = await LocalDataService.getNotifications();
      expect(items, hasLength(2));
      expect(items.where((item) => item.id == 'server_42'), hasLength(1));
      expect(items.firstWhere((item) => item.id == 'server_42').title,
          'Dispatch');

      await LocalDataService.removeNotification('server_42');
      items = await LocalDataService.getNotifications();
      expect(items, hasLength(1));
      expect(items.single.title, 'Local');
    });
  });
}
