import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:cruise_app/map/map_callout.dart';
import 'package:cruise_app/widgets/map/map_callout_bubble.dart';

/// Geometry of the Lyft-style map callouts and their 380 ms morph (owner
/// spec 2026-11-01): the box is centred on the map point with the tail tip
/// ON it; collapsing, the box grows left by the icon's growth, line 2 and
/// the product run fade and are clipped, and the price keeps its left edge
/// while it slides down to the icon's centre line and grows 17 → 20 px.
void main() {
  // ── Pure numbers (synthetic text widths, real line heights) ────────────
  const titleH = kCalloutTitleSize * kCalloutLineHeight; // 19.55
  const subH = kCalloutSubtitleSize * kCalloutLineHeight; // 17.25

  group('trip layout', () {
    final layout = CalloutLayout.of(
      CalloutVariant.trip,
      const CalloutText(
        keepWidth: 30, // "$10"
        tailWidth: 70, // " CRUISE"
        titleHeight: titleH,
        subtitleWidth: 80, // "9 min away"
        subtitleHeight: subH,
      ),
    );

    test('expanded: centred on the point, tail tip on it', () {
      final e = layout.expandedBox;
      // 10 + 36 + 10 + max(100, 80) + 14 = 170; 10 + max(36, 36.8) + 10.
      expect(e.width, closeTo(170, 1e-9));
      expect(e.height, closeTo(56.8, 1e-9));
      expect(e.center.dx, closeTo(0, 1e-9));
      expect(e.bottom, closeTo(-kCalloutTailHeight, 1e-9),
          reason: 'the 8 px tail ends exactly on the point (0, 0)');
      expect(layout.titleX, closeTo(e.left + 10 + 36 + 10, 1e-9));
      expect(layout.titleYExpanded, closeTo(e.top + 10, 1e-9));
    });

    test('compact: same top, grown left, hugs icon 44 + price at 20 px', () {
      final c = layout.compactBox;
      final e = layout.expandedBox;
      expect(c.top, e.top);
      expect(c.left, closeTo(e.left - (44 - 36), 1e-9));
      expect(c.width, closeTo(10 + 44 + 10 + 30 * 20 / 17 + 14, 1e-9));
      expect(c.height, closeTo(10 + 44 + 10, 1e-9), reason: '64 tall');
      // The price centred on the icon: (44 − 20×1.15) / 2 = 10.5 down.
      expect(layout.titleYCompact - layout.titleYExpanded,
          closeTo((44 - titleH * 20 / 17) / 2, 1e-9));
    });

    test('every frame: price x fixed, y / icon monotonic, box shrinks', () {
      double? lastY, lastIcon, lastW;
      for (var i = 10; i >= 0; i--) {
        final f = layout.frameAt(i / 10); // collapsing: v 1 → 0
        expect(f.titleAt.dx, layout.titleX, reason: 'v=${i / 10}');
        expect(f.icon.left, closeTo(f.box.left + 10, 1e-9));
        expect(f.icon.right + kCalloutGap, closeTo(layout.titleX, 1e-9),
            reason: 'icon–price gap stays 10');
        if (lastY != null) {
          expect(f.titleAt.dy, greaterThanOrEqualTo(lastY));
          expect(f.icon.width, greaterThanOrEqualTo(lastIcon!));
          expect(f.box.width, lessThanOrEqualTo(lastW!));
        }
        lastY = f.titleAt.dy;
        lastIcon = f.icon.width;
        lastW = f.box.width;
      }
      final c = layout.frameAt(0);
      expect(c.titleScale, closeTo(20 / 17, 1e-12));
      expect(c.titleAt.dy + titleH * c.titleScale / 2,
          closeTo(c.icon.center.dy, 1e-9),
          reason: 'compact price centred on the icon');
      expect(c.showFading, isFalse, reason: 'line 2 out of the tree');
      expect(c.tailOpacity, 0);
      expect(c.tileRadius, closeTo(11, 1e-9));
      expect(c.glyph, closeTo(44 * 24 / 36, 1e-9));
      final e = layout.frameAt(1);
      expect(e.tileRadius, closeTo(9, 1e-9));
      expect(e.glyph, closeTo(24, 1e-9));
      expect(e.tailOpacity, 1);
      expect(e.box, layout.expandedBox);
    });

    test('bounds cover both states and the tail tip', () {
      final u = layout.bounds;
      expect(u.left, layout.compactBox.left);
      expect(u.right, layout.expandedBox.right);
      expect(u.top, layout.expandedBox.top);
      expect(u.bottom, 0);
    });
  });

  test('airport layout: plane 26 → 34, padding 12 / 14', () {
    final layout = CalloutLayout.of(
      CalloutVariant.airport,
      const CalloutText(
        keepWidth: 40, // "BHM"
        titleHeight: titleH,
        subtitleWidth: 80, // "5-15 Drivers"
        subtitleHeight: subH,
      ),
    );
    expect(layout.expandedBox.width, closeTo(12 + 26 + 10 + 80 + 14, 1e-9));
    expect(layout.compactBox.width,
        closeTo(12 + 34 + 10 + 40 * 20 / 17 + 14, 1e-9));
    expect(layout.compactBox.height, closeTo(10 + 34 + 10, 1e-9));
    expect(layout.frameAt(0).tileRadius, 0, reason: 'no tile behind it');
    expect(layout.frameAt(0).glyph, closeTo(34, 1e-9));
  });

  // ── The widget ─────────────────────────────────────────────────────────
  // A plain style: google_fonts would try the network in tests.
  TextStyle font(FontWeight w) => TextStyle(fontWeight: w);
  const anchor = Offset(200, 300);

  Widget host({
    required CalloutVariant variant,
    required bool expanded,
    required String title,
    String? titleFade,
    String? subtitle,
    VoidCallback? onTap,
  }) =>
      Directionality(
        textDirection: TextDirection.ltr,
        child: Stack(children: [
          Positioned(
            left: anchor.dx,
            top: anchor.dy,
            child: MapCalloutBubble(
              variant: variant,
              title: title,
              titleFade: titleFade,
              subtitle: subtitle,
              expanded: expanded,
              onTap: onTap,
              font: font,
            ),
          ),
        ]),
      );

  // Measured like the bubble measures (the test font rounds line boxes, so
  // heights come from the painter, not from 17 × 1.15).
  Size textSize(String s, double size, FontWeight w) {
    final tp = TextPainter(
      text: TextSpan(
          text: s,
          style: calloutLineStyle(font, size: size, weight: w)),
      textDirection: TextDirection.ltr,
      textHeightBehavior: const TextHeightBehavior(),
      maxLines: 1,
    )..layout();
    final out = tp.size;
    tp.dispose();
    return out;
  }

  double textWidth(String s, double size, FontWeight w) =>
      textSize(s, size, w).width;

  Rect rectOf(WidgetTester t, Key k) => t.getRect(find.byKey(k));

  testWidgets('expanded trip: the tail tip sits on the point', (t) async {
    await t.pumpWidget(host(
      variant: CalloutVariant.trip,
      expanded: true,
      title: r'$10',
      titleFade: ' CRUISE',
      subtitle: '9 min away',
    ));
    final box = rectOf(t, MapCalloutBubble.boxKey);
    expect(box.center.dx, closeTo(anchor.dx, 1e-6));
    expect(box.bottom + kCalloutTailHeight, closeTo(anchor.dy, 1e-6));
    final lines = textSize(r'$10', 17, FontWeight.w700).height +
        textSize('9 min away', 15, FontWeight.w400).height;
    expect(box.height, closeTo(10 + (lines > 36 ? lines : 36) + 10, 1e-6));
    expect(find.text(' CRUISE'), findsOneWidget);
    expect(find.text('9 min away'), findsOneWidget);
  });

  testWidgets('trip collapse: price fixed in x, slides down, grows; box '
      'shrinks smoothly; only "\$10" left', (t) async {
    final w = <String, Object?>{};
    Widget build(bool e) => host(
          variant: CalloutVariant.trip,
          expanded: e,
          title: r'$10',
          titleFade: ' CRUISE',
          subtitle: '9 min away',
          onTap: () => w['tapped'] = true,
        );
    await t.pumpWidget(build(true));
    final title0 = rectOf(t, MapCalloutBubble.titleKey);
    final box0 = rectOf(t, MapCalloutBubble.boxKey);
    final icon0 = rectOf(t, MapCalloutBubble.iconKey);

    await t.pumpWidget(build(false));
    await t.pump(); // the run starts: elapsed 0
    final titles = <Rect>[rectOf(t, MapCalloutBubble.titleKey)];
    final boxes = <Rect>[rectOf(t, MapCalloutBubble.boxKey)];
    final icons = <Rect>[rectOf(t, MapCalloutBubble.iconKey)];
    for (var i = 0; i < 4; i++) {
      await t.pump(const Duration(milliseconds: 95)); // 25 / 50 / 75 / 100 %
      titles.add(rectOf(t, MapCalloutBubble.titleKey));
      boxes.add(rectOf(t, MapCalloutBubble.boxKey));
      icons.add(rectOf(t, MapCalloutBubble.iconKey));
    }
    expect(titles.first, title0, reason: 'no snap at the start');
    expect(boxes.first, box0);
    expect(icons.first, icon0);
    final compact = boxes.last;
    for (var i = 0; i < titles.length; i++) {
      expect(titles[i].left, closeTo(title0.left, 1e-6),
          reason: 'the price never moves sideways (sample $i)');
    }
    for (var i = 1; i < titles.length; i++) {
      expect(titles[i].top, greaterThan(titles[i - 1].top));
      expect(icons[i].width, greaterThan(icons[i - 1].width));
      expect(boxes[i].width, lessThan(boxes[i - 1].width));
    }
    for (final mid in boxes.sublist(1, 4)) {
      expect(mid.width, lessThan(box0.width));
      expect(mid.width, greaterThan(compact.width));
      expect(mid.height, greaterThan(box0.height));
      expect(mid.height, lessThan(compact.height));
    }
    expect(boxes.first.top, closeTo(compact.top, 1e-6), reason: 'same top');

    // At rest compact: icon 44, price at 20 px centred on it, only "$10".
    expect(icons.last.width, closeTo(44, 1e-6));
    final price = titles.last;
    final priceW = textWidth(r'$10', 17, FontWeight.w700);
    expect(price.width, closeTo(priceW * 20 / 17, 1e-6));
    expect(price.height,
        closeTo(textSize(r'$10', 17, FontWeight.w700).height * 20 / 17, 1e-6));
    expect((price.center.dy - icons.last.center.dy).abs(),
        lessThanOrEqualTo(0.5));
    expect(compact.width, closeTo(10 + 44 + 10 + priceW * 20 / 17 + 14, 1));
    expect(compact.height, closeTo(64, 1e-6));
    expect(find.text(r'$10'), findsOneWidget);
    expect(find.text(' CRUISE'), findsNothing);
    expect(find.text('9 min away'), findsNothing);

    // Tappable: the box takes the tap.
    await t.tap(find.byKey(MapCalloutBubble.boxKey));
    expect(w['tapped'], isTrue);

    // Expanding reverses it exactly.
    await t.pumpWidget(build(true));
    await t.pump();
    await t.pump(kCalloutMorphDuration);
    expect(rectOf(t, MapCalloutBubble.boxKey), box0);
    expect(rectOf(t, MapCalloutBubble.titleKey), title0);
    expect(find.text('9 min away'), findsOneWidget);
  });

  testWidgets('airport: compact hugs plane + BHM, narrower than expanded',
      (t) async {
    Widget build(bool e) => host(
          variant: CalloutVariant.airport,
          expanded: e,
          title: 'BHM',
          subtitle: '5-15 Drivers',
        );
    await t.pumpWidget(build(true));
    final expanded = rectOf(t, MapCalloutBubble.boxKey);
    final code0 = rectOf(t, MapCalloutBubble.titleKey);
    expect(expanded.center.dx, closeTo(anchor.dx, 1e-6));
    expect(expanded.bottom + kCalloutTailHeight, closeTo(anchor.dy, 1e-6));
    expect(rectOf(t, MapCalloutBubble.iconKey).width, closeTo(26, 1e-6));
    expect(find.byType(GestureDetector), findsNothing,
        reason: 'visual only — no tap');

    await t.pumpWidget(build(false));
    await t.pump();
    await t.pump(kCalloutMorphDuration);
    final compact = rectOf(t, MapCalloutBubble.boxKey);
    final codeW = textWidth('BHM', 17, FontWeight.w700);
    expect(compact.width, closeTo(12 + 34 + 10 + codeW * 20 / 17 + 14, 1));
    expect(compact.width, lessThan(expanded.width));
    expect(compact.height, closeTo(54, 1e-6));
    expect(rectOf(t, MapCalloutBubble.iconKey).width, closeTo(34, 1e-6));
    expect(rectOf(t, MapCalloutBubble.titleKey).left,
        closeTo(code0.left, 1e-6), reason: 'the code never moves sideways');
    expect(find.text('5-15 Drivers'), findsNothing);
  });

  testWidgets('airport before the count arrives: no second line', (t) async {
    await t.pumpWidget(host(
        variant: CalloutVariant.airport, expanded: true, title: 'BHM'));
    expect(find.byKey(MapCalloutBubble.subtitleKey), findsNothing);
    final box = rectOf(t, MapCalloutBubble.boxKey);
    expect(box.height, closeTo(10 + 26 + 10, 1e-6),
        reason: 'one line: max(plane 26, 19.55) + padding');
  });
}
