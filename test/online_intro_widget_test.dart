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
    messenger.setMockMethodCallHandler(SystemChannels.platform, (_) async => null);
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
}
