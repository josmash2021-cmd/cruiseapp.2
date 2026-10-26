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
    expect(find.text('I understand'), findsOneWidget);
    expect(find.text('We Are Getting Started'), findsOneWidget);
    expect(find.text('Exclusive Benefits'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.ensureVisible(find.text('I understand'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('I understand'));
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

    await tester.ensureVisible(find.text('I understand'));
    await tester.tap(find.text('I understand'));
    await tester.pumpAndSettle();
    expect(dismissed, isTrue);
    expect(tester.takeException(), isNull);
  });

  test('the general rule is due immediately and again after 6 hours', () {
    final interval = onlineIntroRepeatInterval.inMilliseconds;
    final now = DateTime(2026, 10, 24, 12).millisecondsSinceEpoch;
    expect(interval, const Duration(hours: 6).inMilliseconds);
    expect(onlineIntroDueNow(null, now), isTrue);
    expect(onlineIntroDueNow(now - interval + 1, now), isFalse);
    expect(onlineIntroDueNow(now - interval, now), isTrue,
        reason: 'exactly 6 hours after the last acknowledgement is due');
    expect(onlineIntroDueNow(now + 1000, now), isFalse,
        reason: 'a future timestamp must not show early');
  });
}
