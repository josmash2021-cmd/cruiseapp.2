// A tablet uses the whole screen but scales like the biggest phone
// (lib/utils/responsive.dart, 2026-11-09): scaling by the iPad's own width
// drew text at twice its size and ran cards over each other in landscape.
import 'package:cruise_app/utils/responsive.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> _screen(WidgetTester t, Size size) => t.pumpWidget(MediaQuery(
      data: MediaQueryData(size: size),
      child: Builder(builder: (c) {
        Responsive.init(c);
        return const SizedBox();
      }),
    ));

void main() {
  testWidgets('phones scale exactly as before', (t) async {
    await _screen(t, const Size(390, 844));
    expect(Responsive.sp(16), 16);
    expect(Responsive.h(100), 100);
    await _screen(t, const Size(360, 800));
    expect(Responsive.w(39), closeTo(36, 1e-9));
    await _screen(t, const Size(430, 932));
    expect(Responsive.sp(39), closeTo(43, 1e-9));
    expect(Responsive.h(844), closeTo(932, 1e-9));
  });

  testWidgets('a tablet, either way up, stops at the biggest phone', (t) async {
    for (final s in const [Size(820, 1180), Size(1180, 820), Size(800, 1280)]) {
      await _screen(t, s);
      expect(Responsive.sp(39), closeTo(43, 1e-9), reason: '$s');
      expect(Responsive.h(844), lessThanOrEqualTo(932), reason: '$s');
      expect(Responsive.screenWidth, s.width, reason: 'still the whole screen');
    }
  });
}
