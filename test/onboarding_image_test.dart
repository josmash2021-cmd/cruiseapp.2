import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:cruise_app/widgets/onboarding_image.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('all eight dress and selfie variants decode from local assets', () async {
    for (final kind in ['guide_dress', 'guide_selfie']) {
      for (final tier in ['vip', 'std']) {
        for (final gender in ['m', 'f']) {
          final name = '${kind}_${tier}_$gender.png';
          final bytes = await rootBundle.load(
            'assets/images/onboarding/$name',
          );
          final codec = await ui.instantiateImageCodec(
            bytes.buffer.asUint8List(),
          );
          final frame = await codec.getNextFrame();
          expect(frame.image.width, greaterThan(100), reason: name);
          expect(frame.image.height, greaterThan(100), reason: name);
          frame.image.dispose();
          codec.dispose();
        }
      }
    }
  });

  testWidgets('the first image is local, not a network placeholder',
      (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: OnboardingImage(filename: 'guide_dress_std_m.png'),
      ),
    );

    final image = tester.widget<Image>(find.byType(Image));
    expect(image.image, isA<AssetImage>());
    expect(
      (image.image as AssetImage).assetName,
      'assets/images/onboarding/guide_dress_std_m.png',
    );
    expect(tester.takeException(), isNull);

    await tester.pump();
    expect(find.byType(Image), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
