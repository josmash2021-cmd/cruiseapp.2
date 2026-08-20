import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:cruise_app/screens/terms_of_service_screen.dart';
import 'package:cruise_app/screens/privacy_policy_screen.dart';
import 'package:cruise_app/screens/driver/driver_agreement_screen.dart';

/// Collects the plain text of every Text widget currently in the tree.
/// Bodies are rendered with Text.rich, so read textSpan as well as data.
Set<String> _visibleText(WidgetTester tester) {
  final texts = <String>{};
  for (final widget in tester.widgetList<Text>(find.byType(Text))) {
    if (widget.data != null) texts.add(widget.data!);
    final span = widget.textSpan;
    if (span != null) texts.add(span.toPlainText());
  }
  return texts;
}

/// Scrolls the document ListView to the bottom, harvesting text at each
/// step, and returns the full rendered content of the screen.
Future<String> _renderAllText(WidgetTester tester) async {
  final texts = _visibleText(tester);
  final scrollableFinder = find.byType(Scrollable).first;
  final listFinder = find.byType(ListView).first;
  for (var i = 0; i < 100; i++) {
    final state = tester.state<ScrollableState>(scrollableFinder);
    final position = state.position;
    if (position.pixels >= position.maxScrollExtent) break;
    await tester.drag(listFinder, const Offset(0, -800));
    await tester.pump();
    texts.addAll(_visibleText(tester));
  }
  return texts.join('\n');
}

void main() {
  const banned = ['Alabama', 'Cruiseinride LLC', 'APSC', 'Ala. Code'];

  final screens = <String, Widget>{
    'TermsOfServiceScreen': const TermsOfServiceScreen(),
    'PrivacyPolicyScreen': const PrivacyPolicyScreen(),
    'DriverAgreementScreen': const DriverAgreementScreen(),
  };

  for (final entry in screens.entries) {
    group(entry.key, () {
      testWidgets('renders Florida / Cruise in Ride LLC content, no Alabama-era text',
          (WidgetTester tester) async {
        await tester.pumpWidget(MaterialApp(home: entry.value));
        await tester.pumpAndSettle();

        final content = await _renderAllText(tester);

        for (final term in banned) {
          expect(content.contains(term), isFalse,
              reason: '${entry.key} still renders banned term "$term"');
        }
        expect(content.contains('Cruise in Ride LLC'), isTrue,
            reason: '${entry.key} must reference Cruise in Ride LLC');
        expect(content.contains('Florida'), isTrue,
            reason: '${entry.key} must reference Florida');
      });
    });
  }
}
