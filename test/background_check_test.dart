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

    testWidgets('shows dedicated disclosure checkbox label',
        (WidgetTester tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: BackgroundCheckConsentScreen(),
        ),
      );
      await tester.pumpAndSettle();

      // Dedicated FCRA disclosure checkbox (standalone from ToS/privacy)
      expect(find.byType(Checkbox), findsOneWidget);
      expect(
        find.textContaining(
          'I have received, read, and agree to the Background Check Disclosure and Authorization',
        ),
        findsOneWidget,
      );
      expect(find.textContaining('Cruise in Ride LLC'), findsOneWidget);
    });

    testWidgets('shows document links for disclosure and FCRA summary',
        (WidgetTester tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: BackgroundCheckConsentScreen(),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.text('View Background Check Disclosure and Authorization'),
        findsOneWidget,
      );
      expect(
        find.text('View Summary of Your Rights Under the FCRA'),
        findsOneWidget,
      );
    });

    testWidgets('submit without checking consent shows consent-required snackbar',
        (WidgetTester tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: BackgroundCheckConsentScreen(),
        ),
      );
      await tester.pumpAndSettle();

      // Fill the form so validation passes and the consent check is reached.
      await tester.enterText(
          find.widgetWithText(TextFormField, 'First Name'), 'Jane');
      await tester.enterText(
          find.widgetWithText(TextFormField, 'Last Name'), 'Doe');
      await tester.enterText(
          find.widgetWithText(TextFormField, 'Date of Birth'), '1990-01-01');
      await tester.enterText(
          find.widgetWithText(TextFormField, 'SSN (Last 4 digits)'), '1234');
      await tester.enterText(
          find.widgetWithText(TextFormField, 'License Number'), 'D1234567');
      await tester.enterText(
          find.widgetWithText(TextFormField, 'License State'), 'FL');

      // Tap submit WITHOUT checking the consent checkbox.
      await tester.ensureVisible(find.text('Start Background Check'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Start Background Check'));
      await tester.pump();

      expect(
        find.text('Please accept the consent to proceed'),
        findsOneWidget,
      );
    });

    testWidgets('submit button present', (WidgetTester tester) async {
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
