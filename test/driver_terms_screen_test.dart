import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:cruise_app/screens/driver/driver_terms_screen.dart';

void main() {
  group('DriverTermsScreen', () {
    testWidgets('shows dedicated Driver Terms checkbox label',
        (WidgetTester tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: DriverTermsScreen(),
        ),
      );
      await tester.pumpAndSettle();

      // Dedicated checkbox, separate from the FCRA disclosure and the ICA
      expect(find.byType(Checkbox), findsOneWidget);
      expect(
        find.text(
          'I have read and agree to the Cruiseinride Driver Terms of Service.',
        ),
        findsOneWidget,
      );
      expect(find.textContaining('Cruise in Ride, Inc.'), findsOneWidget);
    });

    testWidgets('accept button is present and disabled until consent',
        (WidgetTester tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: DriverTermsScreen(),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Accept Driver Terms of Service'), findsOneWidget);

      // ElevatedButton.icon builds a _ElevatedButtonWithIcon subtype, which
      // find.byType(ElevatedButton) does not match — use a predicate.
      final buttonFinder = find.ancestor(
        of: find.text('Accept Driver Terms of Service'),
        matching: find.byWidgetPredicate((w) => w is ElevatedButton),
      );

      // Disabled while the checkbox is unchecked.
      ElevatedButton button = tester.widget<ElevatedButton>(buttonFinder);
      expect(button.onPressed, isNull);

      // Checking the consent checkbox enables it.
      await tester.ensureVisible(find.byType(Checkbox));
      await tester.tap(find.byType(Checkbox));
      await tester.pump();

      button = tester.widget<ElevatedButton>(buttonFinder);
      expect(button.onPressed, isNotNull);
    });

    testWidgets('shows acceptance history affordance and document link',
        (WidgetTester tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: DriverTermsScreen(),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Acceptance history'), findsOneWidget);
      expect(
        find.text('View Cruiseinride Driver Terms of Service'),
        findsOneWidget,
      );
    });
  });
}
