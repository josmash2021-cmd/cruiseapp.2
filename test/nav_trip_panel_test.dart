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
    bool stopLeg = false,
    bool queuedCanceled = false,
    double screenH = 844,
    Widget? mapControls,
    ValueChanged<double>? onRest,
    int? hintTripId,
    DateTime? waitStartsAt,
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
        data: MediaQueryData(
          size: Size(390, screenH),
          padding: EdgeInsets.only(top: 47, bottom: 34),
        ),
        child: Scaffold(
          backgroundColor: const Color(0xFF0A1430),
          body: Stack(
            children: [
              Positioned.fill(
                child: NavTripPanel(
                  hintTripId: hintTripId,
                  mapControls: mapControls,
                  onRestHeightChanged: onRest,
                  etaLabel: '7 min · 2.9 mi',
                  riderName: 'William Smith',
                  riderPhotoUrl: '',
                  riderId: null,
                  riderRating: 4.9,
                  riderTrips: 34,
                  riderDays: 25,
                  riderVerified: true,
                  toPickup: stage != NavPanelStage.arrivedDropoff &&
                      stage != NavPanelStage.waitingStop &&
                      !stopLeg,
                  stopLeg: stopLeg || stage == NavPanelStage.waitingStop,
                  onSlideFromStop: () => calls.add('fromStop'),
                  pickupAddress: '1102 Garden Woods Dr',
                  dropoffAddress: 'Pelham Civic Complex',
                  pickupNote: 'Portón azul, código 1234',
                  stopLabel: 'AutoZone · 2180 Pelham Pkwy',
                  hasStop: true,
                  fare: 17.02,
                  moving: moving,
                  stage: stage,
                  canPickUp: canPickUp,
                  waitClock: '2:27',
                  waitProgress: waitProgress,
                  waitStartsAt: waitStartsAt,
                  receivingRides: receiving,
                  lastTrip: lastTrip,
                  supportUnread: 2,
                  queuedCanceled: queuedCanceled,
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
  void phone(WidgetTester t, {double h = 844}) {
    t.view.physicalSize = Size(390 * 3, h * 3);
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

  // Owner 2026-11-04 (Lyft): the title at the point is centred over a thin
  // line and changes in steps — "Pasajero notificado" as the driver
  // arrives, then the wait.
  testWidgets('arriving: "Pasajero notificado", then the wait', (t) async {
    phone(t);
    await t.pumpWidget(host(stage: NavPanelStage.approaching, moving: false));
    await settle(t);
    await t.pumpWidget(host(
        stage: NavPanelStage.waitingPickup, moving: false, waitProgress: 0.1));
    await t.pump();
    await t.pump(const Duration(milliseconds: 600));
    expect(find.text('Pasajero notificado'), findsOneWidget);
    expect(find.text('Espera 2:27'), findsNothing);
    await t.pump(const Duration(seconds: 4));
    await t.pump(const Duration(milliseconds: 600));
    expect(find.text('Pasajero notificado'), findsNothing);
    expect(find.text('Espera 2:27'), findsOneWidget);
    final title = t.widget<Text>(find.text('Espera 2:27'));
    expect(title.textAlign, TextAlign.center);
    expect(t.takeException(), isNull);
  });

  testWidgets('a reservation reached early: its time, before the wait',
      (t) async {
    phone(t);
    final at = DateTime.now().add(const Duration(minutes: 20));
    await t.pumpWidget(host(
        stage: NavPanelStage.waitingPickup,
        moving: false,
        waitStartsAt: at));
    await settle(t);
    expect(find.textContaining('Recogida reservada a las'), findsOneWidget);
    expect(find.text('Espera 2:27'), findsNothing);
    expect(t.takeException(), isNull);
  });

  testWidgets('driving to the stop: "Parada de William"', (t) async {
    phone(t);
    await t.pumpWidget(host(stopLeg: true));
    await settle(t);
    expect(find.text('Parada de William'), findsOneWidget);
    expect(t.takeException(), isNull);
  });

  testWidgets('at the stop: the wait, and the slider heads to the destination',
      (t) async {
    phone(t);
    calls.clear();
    await t.pumpWidget(host(
        stage: NavPanelStage.waitingStop, moving: false, waitProgress: 0.5));
    await settle(t);
    expect(find.text('Espera 2:27'), findsOneWidget);
    expect(find.text('Desliza para ir al destino'), findsOneWidget);
    // The knob is what slides.
    await t.drag(
        find.byKey(const ValueKey('nav-slide-knob')), const Offset(320, 0));
    await settle(t);
    expect(calls, contains('fromStop'));
    expect(t.takeException(), isNull);
  });

  testWidgets('stop wait over: a swipe up shows "Pasajero no regresó"',
      (t) async {
    phone(t);
    await t.pumpWidget(
        host(stage: NavPanelStage.waitingStop, moving: false, waitProgress: 1));
    await settle(t);
    expect(find.text('Puedes cancelar el viaje o seguir esperando'),
        findsOneWidget);
    await t.drag(find.text('William'), const Offset(0, -120));
    await settle(t);
    expect(find.text('Pasajero no regresó'), findsOneWidget);
    expect(find.text('Desliza para ir al destino'), findsOneWidget);
    expect(t.takeException(), isNull);
  });

  testWidgets('a cancelled queued ride: the gold line at the top', (t) async {
    phone(t);
    await t
        .pumpWidget(host(stage: NavPanelStage.driving, queuedCanceled: true));
    await settle(t);
    expect(find.text('Viaje en cola cancelado'), findsOneWidget);
    await t.pumpWidget(host(stage: NavPanelStage.driving));
    await settle(t);
    expect(find.text('Viaje en cola cancelado'), findsNothing);
    expect(t.takeException(), isNull);
  });

  testWidgets("the whole trip shows the rider's pickup note", (t) async {
    phone(t);
    await t.pumpWidget(host(stage: NavPanelStage.approaching, moving: false));
    await settle(t);
    await t.drag(find.text('William'), const Offset(0, -200));
    await settle(t);
    expect(find.text('Portón azul, código 1234'), findsOneWidget);
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

  testWidgets('the swipe hint shows and goes by itself after 5 s', (t) async {
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
    // settle() already ran 1 s of the clock.
    await t.pump(const Duration(seconds: 3));
    expect(opacity(), 1, reason: 'still up at 4 s');
    await t.pump(const Duration(seconds: 1));
    await t.pump(const Duration(milliseconds: 300));
    await t.pump(const Duration(milliseconds: 300));
    expect(hint, findsNothing,
        reason: 'faded out, and out of the layout for good');
  });

  // Owner report 2026-11-02: "no se quita a los 5 segundos y cuando abro el
  // sheet y lo cierro vuelve a aparecer… y ya no debe aparecer más a menos
  // que tenga otro nuevo viaje".
  testWidgets('the swipe hint is once per trip: not back after the panel '
      'closes, nor when the navigation opens again', (t) async {
    phone(t);
    const hintText = 'Desliza hacia arriba para ver las opciones del viaje';
    await t.pumpWidget(host(hintTripId: 901));
    await settle(t);
    expect(find.text(hintText), findsOneWidget);
    // Open before the 5 s are up, then close.
    await t.tap(find.byIcon(Icons.more_vert_rounded));
    await settle(t);
    expect(find.text(hintText), findsNothing);
    await t.tapAt(const Offset(195, 200));
    await settle(t);
    await t.pump(const Duration(seconds: 6));
    expect(find.text(hintText), findsNothing,
        reason: 'closing the panel does not bring it back');
    // The navigation opens again for the same trip: still gone.
    await t.pumpWidget(const SizedBox());
    await t.pumpWidget(host(hintTripId: 901));
    await settle(t);
    expect(find.text(hintText), findsNothing);
    // A new trip shows it once more.
    await t.pumpWidget(const SizedBox());
    await t.pumpWidget(host(hintTripId: 902));
    await settle(t);
    expect(find.text(hintText), findsOneWidget);
    await t.pump(const Duration(seconds: 6));
  });

  // Owner report 2026-11-02: "cuando se guarda no se guarda fluido y smooth,
  // se guarda así de golpe; cuando se abre el sheet se abre de golpe y lo
  // intento deslizar y no se desliza y tampoco se guarda y el contenido del
  // mapa no se pone borroso" — and photo 3, the whole trip bouncing down
  // inside its glass instead of closing.
  group('the sheet', () {
    // One surface: the floating panel itself grows into the open body
    // (owner 2026-11-02: "este mismo sheet es el que se debe transformar").
    double h(WidgetTester t) =>
        t.getSize(find.byKey(const ValueKey('nav-panel-morph'))).height;

    testWidgets('a swipe up grows the panel itself under the finger',
        (t) async {
      phone(t);
      await t.pumpWidget(host(moving: false));
      await settle(t);
      final closed = h(t);
      final g = await t.startGesture(t.getCenter(find.text('7 min · 2.9 mi')));
      await g.moveBy(const Offset(0, -30));
      await g.moveBy(const Offset(0, -120));
      await t.pump();
      final mid = h(t);
      await g.up();
      await settle(t);
      final open = h(t);
      expect(mid, greaterThan(closed + 40),
          reason: 'part way up, with the finger — not snapped');
      expect(mid, lessThan(open - 40));
      expect(find.text('Viaje actual'), findsOneWidget);
      expect(find.byKey(const ValueKey('nav-panel-morph')), findsOneWidget,
          reason: 'the same panel, no second sheet over it');
    });

    testWidgets('a short swipe springs back down', (t) async {
      phone(t);
      await t.pumpWidget(host(moving: false));
      await settle(t);
      final closed = h(t);
      final g = await t.startGesture(t.getCenter(find.text('7 min · 2.9 mi')));
      await g.moveBy(const Offset(0, -20));
      await g.moveBy(const Offset(0, -15));
      await g.up();
      await settle(t);
      expect(find.text('Viaje actual'), findsNothing);
      expect(h(t), closeTo(closed, 0.5));
    });

    testWidgets('it glides open and closed — never in one frame', (t) async {
      phone(t);
      await t.pumpWidget(host());
      await settle(t);
      final closed = h(t);
      await t.tap(find.byIcon(Icons.more_vert_rounded));
      await t.pump();
      await t.pump(const Duration(milliseconds: 60));
      final opening = h(t);
      await settle(t);
      final open = h(t);
      expect(opening, greaterThan(closed + 2));
      expect(opening, lessThan(open - 2));
      await t.tap(find.byIcon(Icons.close_rounded));
      await t.pump();
      await t.pump(const Duration(milliseconds: 60));
      final closing = h(t);
      expect(closing, greaterThan(closed + 2));
      expect(closing, lessThan(open - 2));
      await settle(t);
      expect(find.text('Opciones del viaje'), findsNothing);
      expect(h(t), closeTo(closed, 0.5));
    });

    testWidgets('a swipe down on the open sheet puts it away', (t) async {
      phone(t);
      await t.pumpWidget(host(moving: false));
      await settle(t);
      await t.drag(find.text('7 min · 2.9 mi'), const Offset(0, -160));
      await settle(t);
      expect(find.text('Viaje actual'), findsOneWidget);
      await t.drag(find.text('Viaje actual'), const Offset(0, 220));
      await settle(t);
      expect(find.text('Viaje actual'), findsNothing);
      expect(find.text('7 min · 2.9 mi').hitTestable(), findsOneWidget);
    });

    testWidgets('taller than the screen: no bounce, a pull down closes it',
        (t) async {
      phone(t, h: 560);
      await t.pumpWidget(host(moving: false, screenH: 560));
      await settle(t);
      await t.drag(find.text('7 min · 2.9 mi'), const Offset(0, -160));
      await settle(t);
      final pos = t.state<ScrollableState>(find.byType(Scrollable)).position;
      expect(pos.maxScrollExtent, greaterThan(0),
          reason: 'the whole trip really scrolls here');
      expect(pos.physics, isA<ClampingScrollPhysics>());
      await t.drag(find.text('Viaje actual'), const Offset(0, 220));
      await settle(t);
      expect(find.text('Viaje actual'), findsNothing);
    });

    testWidgets('the whole trip blurs the map; the options do not', (t) async {
      phone(t);
      await t.pumpWidget(host(moving: false));
      await settle(t);
      await t.drag(find.text('7 min · 2.9 mi'), const Offset(0, -160));
      await settle(t);
      expect(find.byKey(const ValueKey('nav-panel-scrim')), findsOneWidget);
      // A tap on the blurred map puts the sheet away.
      await t.tapAt(const Offset(195, 24));
      await settle(t);
      expect(find.text('Viaje actual'), findsNothing);

      await t.pumpWidget(host());
      await settle(t);
      await t.tap(find.byIcon(Icons.more_vert_rounded));
      await settle(t);
      expect(find.text('Opciones del viaje'), findsOneWidget);
      expect(find.byKey(const ValueKey('nav-panel-scrim')), findsNothing,
          reason: 'driving: the map stays sharp so the arrow can be followed');
    });

    testWidgets('the map buttons stay sharp and tappable above the blur',
        (t) async {
      phone(t);
      await t.pumpWidget(host(
        moving: false,
        mapControls: Stack(children: [
          Positioned(
            right: 14,
            top: 8,
            child: GestureDetector(
              key: const ValueKey('map-btn'),
              behavior: HitTestBehavior.opaque,
              onTap: () => calls.add('safety'),
              child: const SizedBox(width: 52, height: 52),
            ),
          ),
        ]),
      ));
      await settle(t);
      // The rider's info: a short sheet, the blurred map all around it.
      await t.tap(find.byKey(const ValueKey('nav-panel-photo')));
      await settle(t);
      expect(find.byKey(const ValueKey('nav-panel-scrim')), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('map-btn')));
      await settle(t);
      expect(calls, contains('safety'),
          reason: 'the button sits above the scrim, not under it');
      expect(find.text('Calificación'), findsOneWidget,
          reason: 'tapping a map button does not put the sheet away');
    });

    // Owner 2026-11-02: "los botones del mapa y velocímetro deben de
    // quedarse donde están cuando el sheet se abra".
    testWidgets('the resting height holds while the panel opens over it',
        (t) async {
      phone(t);
      final rests = <double>[];
      await t.pumpWidget(host(moving: false, onRest: rests.add));
      await settle(t);
      expect(rests, isNotEmpty);
      final rest = rests.last;
      expect(rest, greaterThan(60));
      await t.drag(find.text('7 min · 2.9 mi'), const Offset(0, -160));
      await t.pump();
      await t.pump(const Duration(milliseconds: 120));
      await settle(t);
      expect(find.text('Viaje actual'), findsOneWidget);
      expect(rests.last, closeTo(rest, 0.5),
          reason: 'the buttons and the mph stay put; the panel opens over '
              'them');
    });
  });
}
