import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:cruise_app/widgets/onboarding_image.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('all eight dress and selfie source images decode for the 735 fallbacks',
      () async {
    for (final kind in ['guide_dress', 'guide_selfie']) {
      for (final tier in ['vip', 'std']) {
        for (final gender in ['m', 'f']) {
          final name = '${kind}_${tier}_$gender.png';
          final bytes = await File(
            'assets/images/onboarding/$name',
          ).readAsBytes();
          final codec = await ui.instantiateImageCodec(bytes);
          final frame = await codec.getNextFrame();
          expect(frame.image.width, greaterThan(100), reason: name);
          expect(frame.image.height, greaterThan(100), reason: name);
          frame.image.dispose();
          codec.dispose();
        }
      }
    }
  });

  test('every OTA-replacement illustration has an identical public copy',
      () async {
    const copies = {
      'assets/images/online_intro_hero.png':
          'backend/static/onboarding/online_intro_hero.png',
      'assets/images/contracts_hero.jpg':
          'backend/static/media/contracts_hero.jpg',
      'assets/images/referral_hero.png':
          'backend/static/media/referral_hero.png',
    };
    for (final entry in copies.entries) {
      final bundled = await File(entry.key).readAsBytes();
      final publicCopy = await File(entry.value).readAsBytes();
      expect(publicCopy, bundled, reason: entry.value);
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
