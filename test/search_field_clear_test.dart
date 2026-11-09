import 'dart:io';

import 'package:cruise_app/l10n/app_localizations.dart';
import 'package:cruise_app/screens/pickup_dropoff_search_screen.dart';
import 'package:cruise_app/services/local_data_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

// Owner 2026-11-08: "si selecciono el pickup debe tener una x para borrar
// todo más fácil o si selecciono seleccionar en el mapa y marco debe
// colocarse en el pickup donde se escribe".

Future<void> pumpSearch(WidgetTester t) async {
  SharedPreferences.setMockInitialValues({});
  await LocalDataService.init();
  // Wide: the test font draws every letter as a full block.
  t.view.physicalSize = const Size(900 * 3, 1200 * 3);
  t.view.devicePixelRatio = 3;
  addTearDown(t.view.reset);
  await t.pumpWidget(const MaterialApp(
    locale: Locale('es'),
    localizationsDelegates: [
      S.delegate,
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
    ],
    supportedLocales: [Locale('es'), Locale('en')],
    home: PickupDropoffSearchScreen(
      initialPickupLat: 33.4054,
      initialPickupLng: -86.8114,
    ),
  ));
  await t.pump(const Duration(milliseconds: 100));
}

Future<void> unmount(WidgetTester t) async {
  await t.pumpWidget(const SizedBox());
  // The GPS lookup's 5 s timeouts (no location plugin in tests).
  await t.pump(const Duration(seconds: 11));
}

void main() {
  testWidgets('the destination field gets a ✕ that empties it', (t) async {
    await pumpSearch(t);
    final dropoff = find.byType(TextField).last;
    expect(find.byKey(const ValueKey('clear-dropoff')), findsNothing);

    await t.enterText(dropoff, 'walmart');
    await t.pump();
    expect(find.byKey(const ValueKey('clear-dropoff')), findsOneWidget);

    await t.tap(find.byKey(const ValueKey('clear-dropoff')));
    await t.pump(const Duration(milliseconds: 400));
    expect(t.widget<TextField>(dropoff).controller!.text, isEmpty);
    expect(find.byKey(const ValueKey('clear-dropoff')), findsNothing);
    await unmount(t);
  });

  testWidgets("the pickup placeholder speaks the rider's language", (t) async {
    // The constructor default is English: a Spanish app read "Current
    // location" until the GPS address came back (owner capture 2026-11-08).
    await pumpSearch(t);
    final pickup = find.byType(TextField).first;
    expect(t.widget<TextField>(pickup).controller!.text, 'Ubicación actual');
    await unmount(t);
  });

  test('place details: the server signs and serves them in the browser', () {
    final service = File('lib/services/places_service.dart').readAsStringSync();
    expect(service, contains('if (!isKeyValid || kIsWeb) {'));
    final i = service.indexOf('Future<PlaceDetails?> _backendDetails(');
    expect(service.indexOf('...ApiService.jsonHeaders(),', i), greaterThan(i),
        reason: '/places/details is behind the API-key check');
  });

  testWidgets('the pickup field, once selected, gets its ✕ too', (t) async {
    await pumpSearch(t);
    final pickup = find.byType(TextField).first;
    await t.tap(pickup);
    await t.pump(const Duration(milliseconds: 100));
    // Its "Current location" text can be cleared in one tap.
    expect(find.byKey(const ValueKey('clear-pickup')), findsOneWidget);

    await t.tap(find.byKey(const ValueKey('clear-pickup')));
    await t.pump(const Duration(milliseconds: 400));
    expect(t.widget<TextField>(pickup).controller!.text, isEmpty);

    // Tapping the emptied field doesn't put the GPS address back.
    await t.tap(pickup);
    await t.pump(const Duration(seconds: 1));
    expect(t.widget<TextField>(pickup).controller!.text, isEmpty);
    await unmount(t);
  });

  testWidgets('"Ahora ▾" switches to "Programado ▾" and back (owner pick B)',
      (t) async {
    await pumpSearch(t);
    Future<void> frames() async {
      for (var i = 0; i < 14; i++) {
        await t.pump(const Duration(milliseconds: 50));
      }
    }

    final chip = find.byKey(const ValueKey('when-chip'));
    expect(find.descendant(of: chip, matching: find.text('Ahora')),
        findsOneWidget);

    await t.tap(chip);
    await frames();
    expect(find.text('Recoger ahora'), findsOneWidget);
    await t.tap(find.text('Programar con tiempo'));
    await frames();
    expect(find.descendant(of: chip, matching: find.text('Programado')),
        findsOneWidget);
    expect(find.text('Programar un viaje'), findsOneWidget);

    // A mistaken tap has a way back now.
    await t.tap(chip);
    await frames();
    await t.tap(find.text('Recoger ahora'));
    await frames();
    expect(find.descendant(of: chip, matching: find.text('Ahora')),
        findsOneWidget);
    expect(find.text('Programar un viaje'), findsNothing);
    await unmount(t);
  });

  test('"Elegir en mapa" wears the line map mark', () {
    final search =
        File('lib/screens/pickup_dropoff_search_screen.dart').readAsStringSync();
    expect(search, contains('icon: const MapPickGlyph(),'));
    expect(search, isNot(contains('Icons.map_rounded')));
  });

  group('"Choose on map" fills the field being edited', () {
    final search =
        File('lib/screens/pickup_dropoff_search_screen.dart').readAsStringSync();
    final screen = File('lib/screens/ride_request_screen.dart').readAsStringSync();
    final map = File('lib/screens/ride_request_map.dart').readAsStringSync();

    test('pickup without a destination, and the stop, come back', () {
      expect(search, contains("field == 'stop' || (field == 'pickup' && "
          '_dropoffDetails == null)'));
      expect(search, contains('pickerReturnsPlace: returnsPlace,'));
      expect(search, contains("pickerIsStop: field == 'stop',"));
      expect(search, contains('if (returnsPlace && raw is Map) '
          '_applyMapPick(field, raw);'));
    });

    test('a GPS lookup still in flight never refills a cleared pickup', () {
      final i = search.indexOf('Future<void> _resolveGpsPickup()');
      final guard = search.indexOf('if (_pickupCleared) return;', i);
      expect(guard, greaterThan(i));
      expect(guard, lessThan(search.indexOf('_pickupCtrl.text = address;', i)));
    });

    test('the picker hands the spot back instead of committing a lone leg',
        () {
      final i = map.indexOf('if (widget.pickerReturnsPlace) {');
      expect(i, greaterThan(0));
      // Before setPickup/setDropoff, or the lone pickup is lost again.
      expect(i, lessThan(map.indexOf('_ctrl.setPickup(place, _pickerAddress);')));
      expect(map, contains("'address': place.address,"));
      expect(screen, contains('final bool pickerReturnsPlace;'));
      expect(screen, contains('s.setYourStop'));
    });
  });
}
