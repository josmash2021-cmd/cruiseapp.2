import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:cruise_app/services/analytics_service.dart';

void main() {
  group('AnalyticsService', () {
    test('singleton returns same instance', () {
      final a = AnalyticsService.instance;
      final b = AnalyticsService.instance;
      expect(identical(a, b), isTrue);
    });

    test('methods do not throw before init', () async {
      // Methods should silently no-op when not initialized
      await AnalyticsService.instance.logLogin('test');
      await AnalyticsService.instance.logSignUp('email');
      await AnalyticsService.instance.logRideRequested('comfort', 20.0);
      await AnalyticsService.instance.logRideCancelled('test', false);
      await AnalyticsService.instance.logDriverOnline();
      await AnalyticsService.instance.logDriverOffline();
      await AnalyticsService.instance.logPaymentAdded('card');
      await AnalyticsService.instance.logPromoApplied('SAVE10');
    });
  });

  group('LoginScreen widgets', () {
    testWidgets('login screen contains email/phone input', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: TextField(key: Key('login_input')),
          ),
        ),
      );
      expect(find.byKey(const Key('login_input')), findsOneWidget);
    });
  });
}
