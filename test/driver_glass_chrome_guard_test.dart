import 'dart:io';
import 'dart:ui' as ui;

import 'package:cruise_app/widgets/animated_count_badge.dart';
import 'package:cruise_app/widgets/glass_style.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Guardian for the owner requests of 2026-10-30 on the driver map:
///
///   1. the online/offline sheet, the round map buttons, the earnings pill,
///      the GO-side calendar and the menu are frosted grey GLASS, not opaque
///      grey slabs;
///   2. the reserved-rides badge pops in and shrinks away instead of
///      blinking;
///   3. a booking anywhere refreshes the badge and the scheduled pages at
///      once (Firestore config/scheduled_board, bumped by the backend).
void main() {
  final widgets = File('lib/screens/driver/driver_online_widgets.dart')
      .readAsStringSync();
  final screen =
      File('lib/screens/driver/driver_online_screen.dart').readAsStringSync();
  final offline = File('lib/screens/driver/driver_online_offline.dart')
      .readAsStringSync();
  final menu =
      File('lib/screens/driver/driver_menu_screen.dart').readAsStringSync();

  group('glass surface', () {
    testWidgets('a circle is clipped round and blurs what is behind it',
        (tester) async {
      await tester.pumpWidget(const Directionality(
        textDirection: TextDirection.ltr,
        child: Center(
          child: GlassSurface(
            circle: true,
            width: 48,
            height: 48,
            child: SizedBox(),
          ),
        ),
      ));
      expect(find.byType(ClipOval), findsOneWidget);
      final f = tester.widget<BackdropFilter>(find.byType(BackdropFilter));
      expect(f.filter,
          ui.ImageFilter.blur(sigmaX: kGlassChipBlur, sigmaY: kGlassChipBlur));
    });

    test('tints are translucent grey, inner cards barely there', () {
      expect(glassTint.a, lessThan(0.7));
      expect(glassSheetTint.a, lessThan(0.75));
      final inner = glassInnerBox(radius: 18);
      expect((inner.color!).a, lessThan(0.2));
    });

    test('the sheet is glass with the heavy blur, no neu slab', () {
      expect(widgets, contains('blur: kGlassSheetBlur,'));
      expect(widgets, isNot(contains('// Raised neumorphic sheet.')));
      expect(widgets, contains('? glassInnerBox(radius: 18)'));
    });

    test('map buttons, pill, bell and GO-side calendar are glass', () {
      // _fab (menu, zone compass, help), recentre, earnings pill.
      expect(RegExp(r'GlassSurface\(').allMatches(widgets).length,
          greaterThanOrEqualTo(4));
      // Bell + scheduled toast.
      expect(RegExp(r'GlassSurface\(').allMatches(screen).length,
          greaterThanOrEqualTo(2));
      expect(offline, contains('class _GoScheduleButton'));
      expect(offline, isNot(contains('color: const Color(0xFF141420)')));
      // The recentre's entrance blur is OFF at rest — an ImageFiltered
      // layer would hand the glass an empty backdrop instead of the map.
      expect(widgets, contains('enabled: t < 1.0,'));
    });

    test('the menu is glass over the live map', () {
      expect(menu, contains('backgroundColor: Colors.transparent,'));
      expect(menu, isNot(contains('child: NeuDotsBackdrop()')));
      expect(
          offline,
          contains(
              'slideFromLeftRoute(const DriverMenuScreen(), opaque: false)'));
    });
  });

  group('reserved badge animation', () {
    Widget host(int n) => Directionality(
          textDirection: TextDirection.ltr,
          child: Center(child: AnimatedCountBadge(count: n)),
        );

    testWidgets('pops in, rolls, and leaves still showing its number',
        (tester) async {
      await tester.pumpWidget(host(0));
      expect(find.byType(Text), findsNothing);

      await tester.pumpWidget(host(3));
      await tester.pump(const Duration(milliseconds: 60));
      expect(find.text('3'), findsOneWidget);
      await tester.pumpAndSettle();

      await tester.pumpWidget(host(0));
      await tester.pump(const Duration(milliseconds: 80));
      // Mid-exit: shrinking, but still the last number — not an empty pill.
      expect(find.text('3'), findsOneWidget);
      await tester.pumpAndSettle();
      expect(find.byType(Text), findsNothing);
    });

    test('both reserved badges use it, always mounted', () {
      expect(offline, contains('child: AnimatedCountBadge('));
      expect(widgets, contains('child: AnimatedCountBadge('));
      // No more `if (count > 0)` gate that made it blink on and off.
      final go = offline.substring(offline.indexOf('class _GoScheduleButton'));
      expect(go, isNot(contains('if (count > 0)')));
    });
  });

  group('live scheduled board', () {
    test('every board screen holds the watcher while mounted', () {
      for (final path in [
        'lib/screens/driver/driver_online_screen.dart',
        'lib/screens/driver/scheduled_rides_map_screen.dart',
        'lib/screens/driver/scheduled_rides_screen.dart',
      ]) {
        final src = File(path).readAsStringSync();
        expect(src, contains('ScheduledBoardWatcher.acquire();'), reason: path);
        expect(src, contains('ScheduledBoardWatcher.release();'), reason: path);
      }
    });

    test('the watcher listens to the doc the backend bumps', () {
      final w = File('lib/services/scheduled_board_watcher.dart')
          .readAsStringSync();
      expect(w, contains(".collection('config')"));
      expect(w, contains(".doc('scheduled_board')"));
      expect(w, contains('scheduledRideRefreshNotifier.value++'));
      final backend =
          File('backend/services/scheduled_board.py').readAsStringSync();
      expect(backend, contains('BOARD_DOC = ("config", "scheduled_board")'));
    });
  });
}
