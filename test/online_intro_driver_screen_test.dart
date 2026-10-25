import 'dart:convert';

// ignore: depend_on_referenced_packages
import 'package:clock/clock.dart';
import 'package:cruise_app/screens/driver/driver_online_screen.dart';
import 'package:cruise_app/screens/driver/online_intro_overlay.dart';
import 'package:firebase_core/firebase_core.dart';
// ignore: depend_on_referenced_packages
import 'package:firebase_core_platform_interface/test.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setupFirebaseCoreMocks();

  testWidgets('online mode presents the intro on the real driver screen',
      (tester) async {
    var fakeNow = DateTime(2026, 10, 24, 12);
    await withClock(Clock(() => fakeNow), () async {
      await Firebase.initializeApp();
      SharedPreferences.setMockInitialValues({
        'online_intro_seen_v1': true,
        'user_session_v1': jsonEncode({
          'userId': '1',
          'email': '',
          'phone': '+15550001111',
          'role': 'driver',
        }),
      });
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(
          SystemChannels.platform, (_) async => null);
      addTearDown(() {
        messenger.setMockMethodCallHandler(SystemChannels.platform, null);
      });

      tester.view.physicalSize = const Size(1080, 1920);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });
      await tester.pumpWidget(
        const MaterialApp(home: DriverOnlineScreen(resuming: true)),
      );
      await tester.pump();
      expect(find.byType(OnlineIntroOverlay), findsNothing);

      for (var second = 0; second < 20; second++) {
        await tester.pump(const Duration(seconds: 1));
        await tester.pump();
        if (find.byType(OnlineIntroOverlay).evaluate().isNotEmpty) break;
      }
      await tester.pump();

      expect(find.byType(OnlineIntroOverlay), findsOneWidget);
      expect(find.text("You're now online!"), findsOneWidget);
      expect(tester.takeException(), isNull);

      await tester.pump(const Duration(milliseconds: 1400));
      await tester.ensureVisible(find.text('I understand'));
      await tester.pump();
      await tester.tap(find.text('I understand'));
      for (var frame = 0; frame < 8; frame++) {
        if (find.byType(OnlineIntroOverlay).evaluate().isEmpty) break;
        await tester.pump(const Duration(milliseconds: 100));
      }
      await tester.pump();
      expect(find.byType(OnlineIntroOverlay), findsNothing);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getInt('online_intro_last_seen_at'),
          fakeNow.millisecondsSinceEpoch);

      fakeNow = fakeNow.add(const Duration(hours: 7));
      await tester.pump(const Duration(seconds: 2));
      await tester.pump();

      expect(find.byType(OnlineIntroOverlay), findsOneWidget);
      expect(find.text("You're now online!"), findsOneWidget);
      expect(tester.takeException(), isNull);

      await tester.pump(const Duration(seconds: 15));
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    });
  });
}
