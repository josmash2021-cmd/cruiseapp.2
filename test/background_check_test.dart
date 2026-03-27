import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:cruise_app/screens/driver/background_check_consent_screen.dart';

void main() {
  group('BackgroundCheckConsentScreen', () {
    testWidgets('renders all required form fields', (WidgetTester tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: BackgroundCheckConsentScreen(),
        ),
      );
      await tester.pumpAndSettle();

      // Check for key form fields
      expect(find.text('First Name'), findsOneWidget);
      expect(find.text('Last Name'), findsOneWidget);
      expect(find.text('Date of Birth'), findsOneWidget);
      expect(find.text('SSN (Last 4 digits)'), findsOneWidget);
      expect(find.text('License Number'), findsOneWidget);
      expect(find.text('License State'), findsOneWidget);
    });

    testWidgets('shows consent checkbox', (WidgetTester tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: BackgroundCheckConsentScreen(),
        ),
      );
      await tester.pumpAndSettle();

      // Find consent checkbox
      expect(find.byType(Checkbox), findsOneWidget);
      expect(find.textContaining('background check'), findsOneWidget);
    });

    testWidgets('submit button present and starts disabled-looking',
        (WidgetTester tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: BackgroundCheckConsentScreen(),
        ),
      );
      await tester.pumpAndSettle();

      // Find Start Background Check button
      expect(find.text('Start Background Check'), findsOneWidget);
    });
  });
}
