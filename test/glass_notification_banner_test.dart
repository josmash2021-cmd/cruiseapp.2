import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:cruise_app/widgets/glass_notification_banner.dart';

/// The one in-app notification (owner spec 2026-11-01): glass at the top,
/// 7 s, slide up + fade out, swipe up to dismiss, tap runs the action.
void main() {
  late BuildContext ctx;

  Future<void> pumpHost(WidgetTester tester) async {
    // An iPhone 14-size screen with a 47 pt status bar.
    tester.view.physicalSize = const Size(390 * 3, 844 * 3);
    tester.view.devicePixelRatio = 3;
    tester.view.padding = const FakeViewPadding(top: 47 * 3);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      home: Builder(builder: (c) {
        ctx = c;
        return const Scaffold(body: SizedBox.expand());
      }),
    ));
  }

  final banner = find.byKey(const ValueKey('glass-notification-banner'));

  /// Entrance done.
  Future<void> settleIn(WidgetTester tester) async {
    await tester.pump(); // builds the overlay entry
    await tester.pump(kGlassBannerInDuration);
  }

  /// Lets whatever is still up run out its 7 s + exit.
  Future<void> drain(WidgetTester tester) async {
    await tester.pump(kGlassBannerDuration);
    await tester.pump(kGlassBannerOutDuration);
    await tester.pump(kGlassBannerOutDuration);
  }

  setUp(() {
    GlassNotificationBanner.navigatorKey = null;
    GlassNotificationBanner.debugReset();
  });

  testWidgets('shows title + body at the top, leaves on its own at 7 s',
      (tester) async {
    await pumpHost(tester);
    GlassNotificationBanner.show(
      context: ctx,
      title: 'Glenn tipped \$2.39',
      body: 'View ride and send a "thank you"?',
      icon: Icons.attach_money_rounded,
    );
    await settleIn(tester);

    expect(find.text('Glenn tipped \$2.39'), findsOneWidget);
    expect(find.text('View ride and send a "thank you"?'), findsOneWidget);
    expect(find.byIcon(Icons.attach_money_rounded), findsOneWidget);
    expect(GlassNotificationBanner.isShowing, isTrue);

    // Under the status bar, 16 px from each side, at the top.
    final rect = tester.getRect(banner);
    expect(rect.left, kGlassBannerSideMargin);
    expect(rect.right, 390 - kGlassBannerSideMargin);
    expect(rect.top, 47 + kGlassBannerTopGap, reason: 'just under the status bar');
    expect(rect.height, inInclusiveRange(64, 90));

    // Still there just before the 7 s mark…
    await tester.pump(kGlassBannerDuration -
        kGlassBannerInDuration -
        const Duration(milliseconds: 50));
    expect(find.text('Glenn tipped \$2.39'), findsOneWidget);

    // …leaving after it: slides UP while it fades.
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump(kGlassBannerOutDuration ~/ 2);
    final mid = tester.getRect(banner);
    expect(mid.top, lessThan(rect.top), reason: 'exit slides up');
    final opacity = tester.widget<Opacity>(find.ancestor(
        of: banner, matching: find.byType(Opacity)).first);
    expect(opacity.opacity, lessThan(1.0), reason: 'exit fades');

    await tester.pump(kGlassBannerOutDuration);
    expect(find.text('Glenn tipped \$2.39'), findsNothing);
    expect(GlassNotificationBanner.isShowing, isFalse);
  });

  testWidgets('swipe up dismisses', (tester) async {
    await pumpHost(tester);
    GlassNotificationBanner.show(context: ctx, title: 'Swipe me', body: 'up');
    await settleIn(tester);
    expect(find.text('Swipe me'), findsOneWidget);

    await tester.drag(banner, const Offset(0, -120));
    await tester.pump();
    await tester.pump(kGlassBannerOutDuration);
    await tester.pump(kGlassBannerOutDuration);
    expect(find.text('Swipe me'), findsNothing);
    expect(GlassNotificationBanner.isShowing, isFalse);
  });

  testWidgets('a short slow swipe springs back and the banner stays',
      (tester) async {
    await pumpHost(tester);
    GlassNotificationBanner.show(context: ctx, title: 'Stay', body: 'please');
    await settleIn(tester);
    final rest = tester.getRect(banner);

    // Past the touch slop, then only ~12 px of real travel, slowly.
    await tester.timedDrag(
        banner, const Offset(0, -30), const Duration(milliseconds: 600));
    await tester.pump();
    for (var i = 0; i < 30; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(find.text('Stay'), findsOneWidget);
    expect(tester.getRect(banner).top, moreOrLessEquals(rest.top, epsilon: 0.5));

    await drain(tester);
    expect(find.text('Stay'), findsNothing);
  });

  testWidgets('tap runs onTap, then the banner leaves', (tester) async {
    await pumpHost(tester);
    var taps = 0;
    GlassNotificationBanner.show(
      context: ctx,
      title: 'New message',
      body: 'Open the chat',
      onTap: () => taps++,
    );
    await settleIn(tester);
    // A tappable banner carries the chevron.
    expect(find.byIcon(Icons.chevron_right_rounded), findsOneWidget);

    await tester.tap(banner);
    await tester.pump();
    expect(taps, 1);
    await tester.pump(kGlassBannerOutDuration);
    await tester.pump(kGlassBannerOutDuration);
    expect(find.text('New message'), findsNothing);
  });

  testWidgets('a new banner replaces the current one; a repeat only re-arms',
      (tester) async {
    await pumpHost(tester);
    GlassNotificationBanner.show(context: ctx, title: 'First');
    await settleIn(tester);

    GlassNotificationBanner.show(context: ctx, title: 'Second');
    await settleIn(tester);
    await tester.pump(kGlassBannerOutDuration);
    expect(find.text('First'), findsNothing);
    expect(find.text('Second'), findsOneWidget);

    // Same copy again at ~5 s: the 7 s restart, no second card.
    await tester.pump(const Duration(seconds: 5));
    GlassNotificationBanner.show(context: ctx, title: 'Second');
    await tester.pump();
    expect(find.text('Second'), findsOneWidget);
    await tester.pump(const Duration(seconds: 6));
    expect(find.text('Second'), findsOneWidget,
        reason: 'the repeat restarted the 7 s');

    await drain(tester);
    expect(find.text('Second'), findsNothing);
  });

  test('push types map to their icons', () {
    expect(glassBannerIconForType('tip'), Icons.attach_money_rounded);
    expect(glassBannerIconForType('chat_message'), Icons.chat_bubble_rounded);
    expect(glassBannerIconForType('whatever'), Icons.notifications_rounded);
  });
}
