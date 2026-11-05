import 'dart:io';

import 'package:cruise_app/screens/driver/zone_nav_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

/// Heat zones (owner 2026-11-05): "Navegar a la zona" opens the app's OWN
/// navigation to a point — DriverNavView in a destination-only mode.
///
/// The navigation itself needs GPS and a native map, so what is pinned here
/// is the wiring (source guards, same style as driver_nav_guard_test.dart):
///   1. The zone mode exists and only its own constructor can turn it on —
///      every trip keeps the trip paths untouched.
///   2. In zone mode: no rider pin / socket listener, no chat stream, no
///      trip panel (no code, wait, sliders, no-show, cancel); the
///      destination is the stop ring; the arrival latch renames the panel.
///   3. ZoneNavScreen pops itself on Terminar (once, only as the top route)
///      and the one native surface is claimed / released through
///      MapSurfaceCoordinator (two live MapWidgets crash iOS).
/// Plus the panel itself, laid out on a phone.
void main() {
  String read(String path) =>
      File(path).readAsStringSync().replaceAll('\r\n', '\n');

  final nav = read('lib/screens/driver/driver_nav_view.dart');
  final screen = read('lib/screens/driver/zone_nav_screen.dart');
  final panel = read('lib/screens/driver/zone_nav_panel.dart');
  final accept = read('lib/screens/driver/driver_trip_accept_screen.dart');
  final l10n = read('lib/l10n/app_localizations.dart');

  /// [maxLen] chars of [src] from [signature].
  String bodyOf(String src, String signature, {int maxLen = 1600}) {
    final start = src.indexOf(signature);
    expect(start, isNonNegative, reason: '$signature not found');
    return src.substring(start, (start + maxLen).clamp(0, src.length));
  }

  group('zone mode exists, trips untouched', () {
    test('a named constructor turns it on; the trip one cannot', () {
      expect(nav, contains('const DriverNavView.zone({'));
      expect(nav, contains('required String this.zoneName,'));
      expect(nav, contains('final String? zoneName;'));
      // The trip constructor pins it to null — a trip is never a zone.
      final tripCtor = bodyOf(nav, 'const DriverNavView({', maxLen: 2000);
      expect(tripCtor, contains('}) : zoneName = null;'));
      expect(nav, contains('bool get _zone => widget.zoneName != null;'));
    });

    test('the zone is a plain destination leg: no pickup, no stop', () {
      final ctor = bodyOf(nav, 'const DriverNavView.zone({', maxLen: 2200);
      expect(ctor, contains('toPickup = false,'));
      expect(ctor, contains('dropoffLatLng = destination,'));
      expect(ctor, contains('dropoffAddress = zoneName,'));
      expect(ctor, contains('stopLatLng = null,'));
      expect(ctor, contains("stage = '',"),
          reason: 'no stage = no wait ticker, no End Route from the parent');
      expect(ctor, contains('pickupCodeEntry = null,'));
      expect(ctor, contains('onSafety = null;'));
    });

    test('the trip screen still mounts the trip constructor', () {
      expect(accept, contains('child: DriverNavView('));
      expect(accept, isNot(contains('DriverNavView.zone(')));
    });

    test('the trip panel is still the trip panel, with all of its wiring',
        () {
      final i = nav.indexOf('        if (_zone)\n'
          '          Positioned.fill(child: _buildZonePanel(s))\n'
          '        else\n'
          '          Positioned.fill(\n'
          '            child: NavTripPanel(\n');
      expect(i, isNonNegative,
          reason: 'zone mode swaps the panel; else the trip panel as before');
      final trip = nav.substring(i, i + 4200);
      for (final wire in const [
        'hintTripId: widget.tripId,',
        'chatUnread: _chatUnread,',
        'codeEntry: widget.toPickup ? widget.pickupCodeEntry : null,',
        'onNoShow: widget.onNoShow,',
        'onCancelTrip: widget.onCancelTrip ?? widget.onExit,',
        'onSlidePickUp: widget.onSlidePickUp,',
        'onSlideFinish: widget.onSlideFinish,',
        'waitProgress: (1 - _waitRemainFrac).clamp(0.0, 1.0),',
      ]) {
        expect(trip, contains(wire), reason: wire);
      }
    });
  });

  group('zone mode drops the trip', () {
    test('no rider pin ticker and no socket listener', () {
      final init = bodyOf(nav, 'void initState() {', maxLen: 2600);
      expect(
          init,
          contains('if (!_zone) {\n'
              '      _riderTicker = createTicker(_onRiderTick)..start();\n'
              '      _listenRiderLocation();\n'
              '    }'));
      // The rider pin draws on the pickup leg only — a zone is never one.
      expect(bodyOf(nav, 'Future<void> _updateRiderAnnotation() async {',
              maxLen: 300),
          contains('if (!widget.toPickup) return;'));
    });

    test('the chat stream is lazy and only the trip panel reads it', () {
      expect(nav, contains('late final Stream<int> _chatUnread'));
      expect('_chatUnread'.allMatches(nav).length, 2,
          reason: 'declared once, read once (inside the trip panel)');
    });

    test('the destination is the stop ring, and no building outline', () {
      final pin =
          bodyOf(nav, 'Future<void> _drawDestPin() async {', maxLen: 2200);
      expect(pin, contains('if (widget.toPickup || _zone) {'));
      expect(pin, contains(': await stopRingMarker(unit, pin);'));
      expect(pin, contains('badge != null'),
          reason: 'a zone carries no badge: the ring alone');
      final bldg =
          bodyOf(nav, 'Future<void> _findDestBuilding() async {', maxLen: 200);
      expect(bldg, contains('if (_zone) return;'));
    });

    test('the zone panel: live ETA, arrival title, height fed to the camera',
        () {
      final zp = bodyOf(nav, 'Widget _buildZonePanel(S s) {', maxLen: 1100);
      expect(zp, contains('final arrived = _endRouteVisible;'),
          reason: 'the nav view\'s own arrival latch (stage is empty)');
      expect(zp, contains('eta: eta,'));
      expect(zp, contains('_panelEtaLabel(s)'),
          reason: 'the same live "7 min · 2.9 mi" as the trip panel');
      expect(zp, contains('arrived ? s.heatZoneArrived : s.heatZoneTitle'));
      expect(zp, contains('endLabel: s.heatZoneEnd,'));
      expect(zp, contains('onEnd: widget.onExit,'));
      expect(zp, contains('mapControls: _panelControls(s),'));
      expect(zp, contains('_panelH = h;\n        _onLiftChanged();'),
          reason: 'the chase camera lifts over the panel like the trip one');
      expect(zp, contains('setState(() => _panelRestH = h);'),
          reason: 'mph, map buttons and the overview inset ride on it');
    });

    test('the turn box and the guide name the zone on arrival', () {
      final bar = bodyOf(nav, 'Widget _buildManeuverBar(S s', maxLen: 1700);
      expect(bar, contains('? s.heatZoneArrived'));
      final guide = bodyOf(nav, 'Widget _buildGuide(S s, double t) {',
          maxLen: 1400);
      expect(guide, contains('? widget.dropoffAddress // the zone\'s name'));
    });
  });

  group('ZoneNavScreen', () {
    test('the contract: destination, zoneName, initialDriverPos', () {
      expect(screen, contains('class ZoneNavScreen extends StatefulWidget'));
      expect(screen, contains('required this.destination,'));
      expect(screen, contains('required this.zoneName,'));
      expect(screen, contains('required this.initialDriverPos,'));
      expect(screen, contains('final LatLng destination;'));
      expect(screen, contains('final String zoneName;'));
      expect(screen, contains('final LatLng initialDriverPos;'));
      expect(screen, contains('body: DriverNavView.zone('));
    });

    test('Terminar pops this screen once, only as the top route', () {
      final end = bodyOf(screen, 'void _end() {', maxLen: 420);
      expect(end, contains('if (_leaving || !mounted) return;'));
      expect(end, contains('if (route == null || !route.isCurrent) return;'),
          reason: 'a second tap mid-pop must not pop the driver home');
      expect(end, contains('Navigator.maybeOf(context)'),
          reason: 'rule #26: maybeOf outside build');
      expect(end, contains('nav.pop();'));
      expect(screen, contains('onExit: _end,'));
      expect(screen, isNot(contains('PopScope')),
          reason: 'the system back pops it too');
    });

    test('the push route has no iOS edge swipe-back', () {
      expect(screen, contains('slideFromRightRoute<void>(ZoneNavScreen('));
    });

    test('the one native surface is claimed and released by the nav view',
        () {
      // ZoneNavScreen mounts no map of its own: DriverNavView is the only
      // MapWidget on it, and it goes through the coordinator.
      expect(screen, isNot(contains('mapbox_maps_flutter')));
      expect(nav, contains('Future<void> _acquireMapSurface() async {'));
      expect(bodyOf(nav, 'void initState() {', maxLen: 200),
          contains('_acquireMapSurface();'));
      expect(bodyOf(nav, 'void dispose() {', maxLen: 300),
          contains('MapSurfaceCoordinator.instance.release(_mapSurfaceOwner);'));
      expect(
          nav,
          contains("late final String _mapSurfaceOwner = "
              "'DriverTripNav-\${++_nextMapSurfaceId}';"),
          reason: 'unique per instance: a shared id skips the revoke');
      // The online screen takes it back when the route above it pops.
      final online = read('lib/screens/driver/driver_online_screen.dart');
      expect(online, contains('void didPopNext() {'));
      expect(online, contains('mapRouteObserver.subscribe(this, route);'));
    });
  });

  test('strings exist in Spanish and English', () {
    for (final key in const [
      'heatZoneTitle',
      'heatZoneArrived',
      'heatZoneEnd',
    ]) {
      expect(l10n, contains('String get $key =>'), reason: key);
    }
    expect(panel, contains("import '../../widgets/map/heat_flame.dart';"));
    expect(panel, contains('const Color kZoneFlameWell = Color(0xFF0B0B0F);'));
    expect(panel, contains('roundFrostOnIOS: true,'),
        reason: 'no blurred square corners over the iOS map (rule #43)');
    expect(panel, contains('tint: glassNavRestTint,'),
        reason: 'the nav panel\'s closed glass');
  });

  group('ZoneNavPanel on a phone', () {
    Widget host({
      required String title,
      String zoneName = 'Hoover',
      VoidCallback? onEnd,
      ValueChanged<double>? onHeight,
      ValueChanged<double>? onRest,
    }) {
      return MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(
            size: Size(390, 844),
            padding: EdgeInsets.only(top: 47, bottom: 34),
          ),
          child: Scaffold(
            backgroundColor: const Color(0xFF0A1430),
            body: ZoneNavPanel(
              title: title,
              zoneName: zoneName,
              eta: '7 min · 2.9 mi',
              endLabel: 'Terminar',
              onEnd: onEnd ?? () {},
              onHeightChanged: onHeight,
              onRestHeightChanged: onRest,
            ),
          ),
        ),
      );
    }

    testWidgets('lays out with the flame, both lines and Terminar',
        (tester) async {
      await tester.pumpWidget(host(title: 'Zona con pasajeros'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('Zona con pasajeros'), findsOneWidget);
      expect(find.text('Hoover'), findsOneWidget);
      expect(find.text(' · 7 min · 2.9 mi'), findsOneWidget);
      expect(find.text('Terminar'), findsOneWidget);
      expect(find.byType(HeatFlameIcon), findsOneWidget);
      // The 42 px dark well.
      final well = tester.getSize(find
          .ancestor(
              of: find.byType(HeatFlameIcon), matching: find.byType(Container))
          .first);
      expect(well, const Size(42, 42));
    });

    testWidgets('a long zone name is cut, never the live ETA and miles',
        (tester) async {
      await tester.pumpWidget(host(
          title: 'Zona con pasajeros',
          zoneName: 'Downtown Birmingham Civil Rights District North'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      // The ETA is laid out whole; the name takes what is left and is cut.
      final eta =
          tester.renderObject<RenderParagraph>(find.text(' · 7 min · 2.9 mi'));
      expect(eta.didExceedMaxLines, isFalse);
      final name = tester.renderObject<RenderParagraph>(
          find.text('Downtown Birmingham Civil Rights District North'));
      expect(name.didExceedMaxLines, isTrue);
    });

    testWidgets('Terminar calls onEnd', (tester) async {
      var ended = 0;
      await tester.pumpWidget(
          host(title: 'Zona con pasajeros', onEnd: () => ended++));
      await tester.tap(find.byKey(const ValueKey('zone-nav-end')));
      await tester.pump();
      expect(ended, 1);
    });

    testWidgets('reports one height, at rest and on screen', (tester) async {
      double? h;
      double? rest;
      await tester.pumpWidget(host(
        title: 'Zona con pasajeros',
        onHeight: (v) => h = v,
        onRest: (v) => rest = v,
      ));
      await tester.pump();
      expect(h, isNotNull);
      expect(rest, h);
      // Glass + the floating bottom margin (8 + half the 34 pt inset).
      final glass = tester.getSize(find
          .descendant(
              of: find.byKey(const ValueKey('zone-nav-panel')),
              matching: find.byType(ClipRRect))
          .first);
      expect(h, closeTo(glass.height + 8 + 17, 0.5));
    });

    testWidgets('arrival swaps the title softly', (tester) async {
      await tester.pumpWidget(host(title: 'Zona con pasajeros'));
      await tester.pumpAndSettle();
      await tester.pumpWidget(host(title: 'Llegaste a la zona'));
      await tester.pump(const Duration(milliseconds: 100));
      // Mid-swap: both titles on screen, crossfading — never one frame.
      expect(find.text('Zona con pasajeros'), findsOneWidget);
      expect(find.text('Llegaste a la zona'), findsOneWidget);
      await tester.pumpAndSettle();
      expect(find.text('Zona con pasajeros'), findsNothing);
      expect(find.text('Llegaste a la zona'), findsOneWidget);
    });
  });
}
