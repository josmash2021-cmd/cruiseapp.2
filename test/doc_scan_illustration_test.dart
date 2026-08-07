import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:cruise_app/widgets/doc_scan_illustration.dart';

/// The document illustration on the guidelines step, pinned.
///
/// It is a CustomPainter whose every coordinate is a fraction of the height
/// the caller passes in, so a small or zero box is the kind of input that
/// turns into a NaN and takes the whole page down with an uncatchable
/// native error. It also has to survive a docType it does not know, because
/// the screen holds `_docType == ''` until the moment the sheet is tapped.
void main() {
  Future<void> pumpIt(
    WidgetTester tester,
    String docType, {
    double height = 190,
    double boxWidth = 342, // 390 phone − 24 padding each side
    bool reduceMotion = false,
  }) async {
    await tester.pumpWidget(
      MediaQuery(
        data: MediaQueryData(disableAnimations: reduceMotion),
        child: Directionality(
          textDirection: TextDirection.ltr,
          child: Center(
            child: SizedBox(
              width: boxWidth,
              child: DocScanIllustration(docType: docType, height: height),
            ),
          ),
        ),
      ),
    );
  }

  group('every document type', () {
    for (final type in ['license', 'government_id', 'passport']) {
      testWidgets('$type paints and animates', (tester) async {
        await pumpIt(tester, type);
        expect(tester.takeException(), isNull);

        // Let the loop run through a full cycle plus change.
        await tester.pump(const Duration(milliseconds: 900));
        await tester.pump(const Duration(milliseconds: 1600));
        await tester.pump(const Duration(seconds: 2));
        expect(tester.takeException(), isNull);
      });
    }
  });

  testWidgets('an unknown type falls back instead of throwing', (tester) async {
    // The real one: the screen starts with an empty string.
    await pumpIt(tester, '');
    expect(tester.takeException(), isNull);

    await pumpIt(tester, 'drivers-licence-typo');
    expect(tester.takeException(), isNull);
  });

  group('degenerate boxes', () {
    testWidgets('a zero height does not produce a NaN', (tester) async {
      await pumpIt(tester, 'license', height: 0);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a box far narrower than the card still paints',
        (tester) async {
      // Natural width at height 190 is ~282; squeeze it to a third.
      await pumpIt(tester, 'license', boxWidth: 90);
      await tester.pump(const Duration(milliseconds: 900));
      expect(tester.takeException(), isNull);
    });

    testWidgets('a tall passport in a narrow box still paints',
        (tester) async {
      await pumpIt(tester, 'passport', height: 320, boxWidth: 70);
      await tester.pump(const Duration(milliseconds: 900));
      expect(tester.takeException(), isNull);
    });
  });

  testWidgets('reduced motion parks it on a static frame', (tester) async {
    await pumpIt(tester, 'license', reduceMotion: true);
    expect(tester.takeException(), isNull);

    // With the ticker stopped there is nothing left to schedule, so pumping
    // must settle. If it ever times out here, the controller is running
    // despite the accessibility setting.
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('disposes cleanly while mid-animation', (tester) async {
    await pumpIt(tester, 'passport');
    await tester.pump(const Duration(milliseconds: 700));
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 1));
    expect(tester.takeException(), isNull);
  });
}
