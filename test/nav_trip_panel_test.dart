import 'package:cruise_app/l10n/app_localizations.dart';
import 'package:cruise_app/screens/driver/nav_trip_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

/// The navigation's bottom panel, owner design 2026-11-02
/// (https://claude.ai/artifact/HJUuivr8N4vih8WmmqGnTX). Every stage must lay
/// out on a phone without overflow, and every way of opening it must land
/// where the design says.
void main() {
  final calls = <String>[];

  Widget host({
    NavPanelStage stage = NavPanelStage.driving,
    bool moving = true,
    double waitProgress = 0,
    bool canPickUp = true,
    bool lastTrip = false,
    bool receiving = true,
  }) {
    return MaterialApp(
      locale: const Locale('es'),
      localizationsDelegates: const [
        S.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: const [Locale('es'), Locale('en')],
      home: MediaQuery(
        data: const MediaQueryData(
          size: Size(390, 844),
          padding: EdgeInsets.only(top: 47, bottom: 34),
        ),
        child: Scaffold(
          backgroundColor: const Color(0xFF0A1430),
          body: Stack(
            children: [
              Positioned.fill(
                child: NavTripPanel(
                  etaLabel: '7 min · 2.9 mi',
                  riderName: 'William Smith',
                  riderPhotoUrl: '',
                  riderId: null,
                  riderRating: 4.9,
                  riderTrips: 34,
                  riderDays: 25,
                  riderVerified: true,
                  toPickup: stage != NavPanelStage.arrivedDropoff,
                  pickupAddress: '1102 Garden Woods Dr',
                  dropoffAddress: 'Pelham Civic Complex',
                  stopLabel: 'AutoZone · 2180 Pelham Pkwy',
                  hasStop: true,
                  fare: 17.02,
                  moving: moving,
                  stage: stage,
                  canPickUp: canPickUp,
                  waitClock: '2:27',
                  waitProgress: waitProgress,
                  receivingRides: receiving,
                  lastTrip: lastTrip,
                  supportUnread: 2,
                  onOpenChat: () => calls.add('chat'),
                  onSupport: () => calls.add('support'),
                  onCancelTrip: () => calls.add('cancel'),
                  onArrived: () => calls.add('arrived'),
                  onSlidePickUp: () => calls.add('pickup'),
                  onSlideFinish: () => calls.add('finish'),
                  onToggleReceiving: () => calls.add('receiving'),
                  onToggleLastTrip: () => calls.add('lastTrip'),
                  onNoShow: () => calls.add('noShow'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> settle(WidgetTester t) async {
    await t.pump();
    await t.pump(const Duration(seconds: 1));
  }

  setUp(calls.clear);

  // An iPhone 14/15 screen (390 x 844 pt), not the test's default 800 x 600.
  void phone(WidgetTester t) {
    t.view.physicalSize = const Size(390 * 3, 844 * 3);
    t.view.devicePixelRatio = 3;
    addTearDown(t.view.reset);
  }

  testWidgets('driving: the face, and ⋮ opens only the trip options',
      (t) async {
    phone(t);
    await t.pumpWidget(host());
    await settle(t);
    expect(find.text('7 min · 2.9 mi'), findsOneWidget);
    expect(find.text('Recoger a William'), findsOneWidget);
    await t.tap(find.byIcon(Icons.more_vert_rounded));
    await settle(t);
    expect(find.text('Opciones del viaje'), findsOneWidget);
    expect(find.text('Cancelar viaje actual'), findsOneWidget);
    expect(find.text('Último viaje'), findsOneWidget);
    expect(find.text('Online'), findsOneWidget);
    expect(find.text('Viaje actual'), findsNothing,
        reason: 'driving, the whole trip never opens');
    await t.tap(find.text('Último viaje'));
    expect(calls, contains('lastTrip'));
    expect(t.takeException(), isNull);
  });

  testWidgets('"Último viaje" reads Offline when it is on', (t) async {
    phone(t);
    await t.pumpWidget(host(lastTrip: true));
    await settle(t);
    await t.tap(find.byIcon(Icons.more_vert_rounded));
    await settle(t);
    expect(find.text('Offline'), findsOneWidget);
  });

  testWidgets('driving: a swipe up also gives the options', (t) async {
    phone(t);
    await t.pumpWidget(host());
    await settle(t);
    await t.drag(find.text('7 min · 2.9 mi'), const Offset(0, -120));
    await settle(t);
    expect(find.text('Opciones del viaje'), findsOneWidget);
  });

  testWidgets('parked: the photo replaces ⋮, a swipe raises the whole trip',
      (t) async {
    phone(t);
    await t.pumpWidget(host(moving: false));
    await settle(t);
    expect(find.byIcon(Icons.more_vert_rounded), findsNothing);
    await t.drag(find.text('7 min · 2.9 mi'), const Offset(0, -120));
    await settle(t);
    expect(find.text('Viaje actual'), findsOneWidget);
    expect(find.textContaining('+ Tips', findRichText: true), findsOneWidget);
    expect(find.text('Recibiendo viajes'), findsOneWidget);
    expect(find.text('Cancelar viaje'), findsOneWidget);
    expect(find.text('Parada de William'), findsOneWidget);
    expect(find.text('Último viaje'), findsNothing,
        reason: 'owner 2026-11-02: only in the trip options');
    expect(t.takeException(), isNull);
  });

  testWidgets('parked: "Te has desconectado" when rides are off', (t) async {
    phone(t);
    await t.pumpWidget(host(moving: false, receiving: false));
    await settle(t);
    await t.drag(find.text('7 min · 2.9 mi'), const Offset(0, -120));
    await settle(t);
    expect(find.text('Te has desconectado'), findsOneWidget);
    expect(find.text('Toca para encender'), findsOneWidget);
  });

  testWidgets('approaching the pickup: photo, name, Contactar and "Llegué"',
      (t) async {
    phone(t);
    await t.pumpWidget(host(stage: NavPanelStage.approaching, moving: false));
    await settle(t);
    expect(find.text('William'), findsOneWidget);
    await t.tap(find.text('Llegué'));
    expect(calls, contains('arrived'));
    expect(t.takeException(), isNull);
  });

  testWidgets(
      'waiting: the wait line, the locked slider until the rider '
      'confirms', (t) async {
    phone(t);
    await t.pumpWidget(host(
        stage: NavPanelStage.waitingPickup, moving: false, canPickUp: false));
    await settle(t);
    expect(find.text('Espera 2:27'), findsOneWidget);
    expect(find.text('Esperando a tu pasajero…'), findsOneWidget);
    expect(find.byIcon(Icons.lock_rounded), findsOneWidget);
    expect(t.takeException(), isNull);
  });

  testWidgets(
      'wait over: the message, and a swipe up shows the no-show '
      'slider', (t) async {
    await t.pumpWidget(host(
        stage: NavPanelStage.waitingPickup, moving: false, waitProgress: 1));
    await settle(t);
    expect(find.text('Puedes cancelar el viaje o seguir esperando'),
        findsOneWidget);
    expect(find.text('Desliza para recoger'), findsOneWidget);
    await t.drag(find.text('William'), const Offset(0, -120));
    await settle(t);
    expect(find.text('Pasajero no llegó'), findsOneWidget);
    expect(find.text('Desliza para cancelar el viaje'), findsOneWidget);
    expect(t.takeException(), isNull);
  });

  testWidgets('at the destination: the finish slider', (t) async {
    phone(t);
    await t
        .pumpWidget(host(stage: NavPanelStage.arrivedDropoff, moving: false));
    await settle(t);
    expect(find.text('Desliza para terminar'), findsOneWidget);
    expect(t.takeException(), isNull);
  });

  testWidgets('parked: tapping the photo opens the rider info', (t) async {
    phone(t);
    await t.pumpWidget(host(stage: NavPanelStage.approaching, moving: false));
    await settle(t);
    await t.tap(find.byKey(const ValueKey('nav-panel-photo')));
    await settle(t);
    expect(find.text('Calificación'), findsOneWidget);
    expect(find.text('★4.9'), findsOneWidget);
    expect(find.text('34'), findsOneWidget);
    expect(find.text('Días'), findsOneWidget);
    expect(find.text('Verificado'), findsOneWidget);
    expect(t.takeException(), isNull);
  });

  testWidgets('the swipe hint goes the moment the panel opens', (t) async {
    phone(t);
    await t.pumpWidget(host());
    await settle(t);
    expect(find.text('Desliza hacia arriba para ver las opciones del viaje'),
        findsOneWidget);
    await t.tap(find.byIcon(Icons.more_vert_rounded));
    await t.pump();
    expect(find.text('Desliza hacia arriba para ver las opciones del viaje'),
        findsNothing);
  });

  testWidgets('the swipe hint shows and goes by itself after 7 s', (t) async {
    phone(t);
    await t.pumpWidget(host());
    await settle(t);
    final hint =
        find.text('Desliza hacia arriba para ver las opciones del viaje');
    expect(hint, findsOneWidget);
    double opacity() => t
        .widget<AnimatedOpacity>(
            find.ancestor(of: hint, matching: find.byType(AnimatedOpacity)))
        .opacity;
    expect(opacity(), 1);
    await t.pump(const Duration(seconds: 7));
    await t.pump(const Duration(milliseconds: 300));
    await t.pump(const Duration(milliseconds: 300));
    expect(hint, findsNothing,
        reason: 'faded out, and out of the layout for good');
  });
}
