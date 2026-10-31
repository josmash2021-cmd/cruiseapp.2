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
    testWidgets('the sheet glass is clipped and blurs what is behind it',
        (tester) async {
      await tester.pumpWidget(const Directionality(
        textDirection: TextDirection.ltr,
        child: Center(
          child: GlassSurface(
            borderRadius: BorderRadius.vertical(top: Radius.circular(26)),
            width: 200,
            height: 120,
            child: SizedBox(),
          ),
        ),
      ));
      expect(find.byType(ClipRRect), findsOneWidget);
      final f = tester.widget<BackdropFilter>(find.byType(BackdropFilter));
      expect(f.filter,
          ui.ImageFilter.blur(sigmaX: kGlassSheetBlur, sigmaY: kGlassSheetBlur));
    });

    testWidgets('a map control is the button alone: no blur, soft shadow',
        (tester) async {
      // Owner 2026-10-31: on iOS the blur behind a round control showed as
      // a blurred SQUARE around it. Controls never blur.
      await tester.pumpWidget(const Directionality(
        textDirection: TextDirection.ltr,
        child: Center(
          child: MapChipSurface(
            circle: true,
            width: 48,
            height: 48,
            child: SizedBox(),
          ),
        ),
      ));
      expect(find.byType(BackdropFilter), findsNothing);
      final box = tester.widget<Container>(find.byType(Container));
      final deco = box.decoration! as BoxDecoration;
      expect(deco.shape, BoxShape.circle);
      expect(deco.boxShadow, isNotEmpty);
      expect(mapChipTint.a, lessThan(0.8));
    });

    test('tints are translucent grey, inner cards barely there', () {
      expect(glassTint.a, lessThan(0.7));
      expect(glassSheetTint.a, lessThan(0.75));
      final inner = glassInnerBox(radius: 18);
      expect((inner.color!).a, lessThan(0.2));
    });

    test('the sheet is glass with the heavy blur, no neu slab', () {
      expect(widgets, contains('blur: kGlassSheetBlur +'));
      expect(widgets, isNot(contains('// Raised neumorphic sheet.')));
      expect(widgets, contains('? glassInnerBox(radius: 18)'));
      // The sheet is the ONLY glass on the map screen.
      expect(RegExp(r'GlassSurface\(').allMatches(widgets).length, 1);
      expect(RegExp(r'GlassSurface\(').allMatches(screen).length, 0);
    });

    test('map buttons, pill, bell and GO-side calendar are shadowed chips', () {
      // _fab (menu, zone compass, help), recentre, earnings pill.
      expect(RegExp(r'MapChipSurface\(').allMatches(widgets).length, 3);
      // Bell + scheduled toast.
      expect(RegExp(r'MapChipSurface\(').allMatches(screen).length, 2);
      expect(offline, contains('class _GoScheduleButton'));
      expect(offline, contains('MapChipSurface('));
      expect(offline, isNot(contains('GlassSurface(')));
      expect(offline, isNot(contains('color: const Color(0xFF141420)')));
      // The recentre's entrance blur is OFF at rest — an ImageFiltered
      // layer would hand the glass an empty backdrop instead of the map.
      expect(widgets, contains('enabled: t < 1.0,'));
    });

    test('the menu keeps its solid page (owner 2026-10-31)', () {
      // "el menú déjalo con el fondo que tenía antes … no lo coloques
      // transparente": the menu is a full page, not map chrome.
      expect(menu, contains('backgroundColor: neuBase,'));
      expect(menu, contains('child: NeuDotsBackdrop()'));
      expect(offline,
          contains('slideFromLeftRoute(const DriverMenuScreen())'));
    });

    test('the open sheet stays glass but hides what is behind it', () {
      // Owner 2026-10-31: "estilo vidrio borroso, pero que no se vea los
      // botones del mapa ni la flecha detrás" — NOT a flat grey. Denser
      // tint and a much heavier blur as it opens, still translucent…
      expect(glassSheetOpenTint.a, lessThan(1.0));
      expect(glassSheetOpenTint.a, greaterThan(glassSheetTint.a));
      expect(kGlassSheetBlurOpen, greaterThan(kGlassSheetBlur * 1.5));
      expect(widgets,
          contains('Color.lerp(glassSheetTint, glassSheetOpenTint, openT)!'));
      expect(widgets,
          contains('((t - _kSheetRestFrac) / 0.33).clamp(0.0, 1.0)'));
      // …and the side buttons parked above the collapsed sheet step away.
      expect(
          RegExp(r'child: _hideUnderOpenSheet\(Column\(')
              .allMatches(screen)
              .length,
          2);
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

  group('scheduled rides page (owner 2026-10-31)', () {
    final sched = File('lib/screens/driver/scheduled_rides_map_screen.dart')
        .readAsStringSync()
        .replaceAll('\r\n', '\n');

    test('the sheet is glass, frosting harder as it rises', () {
      expect(sched, contains('builder: (ctx, child) => GlassSurface('));
      expect(sched, contains('animation: _sheetCtrl,'),
          reason: 'the sheet builder runs once — the frost listens to the '
              'controller so it follows the drag');
      expect(sched,
          contains('glassSheetTint, glassSheetOpenTint, _sheetOpenT())!'));
      expect(sched, isNot(contains('color: neuBase,\n                borderRadius:')));
      expect(sched, contains('decoration: glassInnerBox(\n        radius: 20,'));
    });

    test('a drag rests closed or fully open — never half way', () {
      expect(sched, contains('static const _sheetInitial = _sheetMin;'));
      expect(sched, isNot(contains('snapSizes:')),
          reason: 'snap with no snapSizes = min and max only');
    });

    test('Search this area + recentre: shadowed chips, no blur', () {
      final pill = sched.substring(sched.indexOf('Widget _buildSearchAreaPill'),
          sched.indexOf('Widget _buildRecenterFab'));
      expect(pill, contains('MapChipSurface('));
      expect(pill, isNot(contains('BackdropFilter')));
      final fab = sched.substring(sched.indexOf('Widget _buildRecenterFab'),
          sched.indexOf('Widget _buildReserveButton'));
      expect(fab, contains('MapChipSurface('));
    });

    test('the ride marker: bigger cube and the 3D gold pin', () {
      final m = sched.substring(sched.indexOf('Future<Uint8List?> _bubbleBytes'),
          sched.indexOf('final side = shadowPad * 2;'));
      expect(m, contains('fontSize: 18, // was 15'));
      expect(m, contains('const discD = 34.0;'));
      expect(m, contains('ui.Gradient.radial('));
      expect(m, contains('const groundH = 7.0;'));
      expect(m, isNot(contains('emoji_people_rounded')),
          reason: 'the flat hailing glyph is gone');
    });
  });
}
