import 'package:cruise_app/screens/driver/online_intro_overlay.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('the intro renders over the map and Entendido dismisses it',
      (tester) async {
    var dismissed = false;
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
        SystemChannels.platform, (_) async => null);
    addTearDown(() {
      messenger.setMockMethodCallHandler(SystemChannels.platform, null);
    });

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Stack(
            children: [
              const ColoredBox(color: Colors.black),
              OnlineIntroOverlay(onUnderstood: () => dismissed = true),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text("You're now online!"), findsOneWidget);
    expect(find.text('Got it'), findsOneWidget);
    expect(find.text('We Are Getting Started'), findsOneWidget);
    expect(find.text('Exclusive Benefits'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.ensureVisible(find.text('Got it'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Got it'));
    await tester.pumpAndSettle();

    expect(dismissed, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the gold intro scrolls and dismisses on a small phone',
      (tester) async {
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    var dismissed = false;
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
        SystemChannels.platform, (_) async => null);
    addTearDown(() {
      messenger.setMockMethodCallHandler(SystemChannels.platform, null);
    });

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: OnlineIntroOverlay(onUnderstood: () => dismissed = true),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    await tester.ensureVisible(find.text('Got it'));
    await tester.tap(find.text('Got it'));
    await tester.pumpAndSettle();
    expect(dismissed, isTrue);
    expect(tester.takeException(), isNull);
  });

  test('the demo account rule resolves locally by email or phone', () {
    expect(
      onlineIntroAlwaysAccount(cached: {'email': ' JOSMASH33@GMAIL.COM '}),
      isTrue,
    );
    expect(
      onlineIntroAlwaysAccount(cached: {'phone': '+1 (385) 461-2042'}),
      isTrue,
      reason: 'country code and formatting must not hide the demo rule',
    );
    expect(
      onlineIntroAlwaysAccount(
        live: {'phone': '+13854612042'},
        cached: {'phone': '+15550000000'},
      ),
      isTrue,
    );
    expect(
      onlineIntroAlwaysAccount(
        cached: {'email': 'driver@example.test', 'phone': '+15550000000'},
      ),
      isFalse,
    );
  });
}
