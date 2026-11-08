import 'dart:io';
import 'dart:typed_data';

import 'package:cruise_app/data/airport_airlines.dart';
import 'package:cruise_app/widgets/airline_logo.dart';
import 'package:cruise_app/widgets/place_glyph.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

// Owner 2026-11-08: the airline page shows "los íconos de las aerolíneas
// reales" — each airline's square logo from /static/airlines/{IATA}.png.

/// Every airline name the app can show, read from its data files.
Set<String> allListedAirlines() {
  final names = <String>{};
  for (final path in [
    'lib/data/airport_data.dart',
    'lib/data/airport_airlines.dart',
  ]) {
    final src = File(path).readAsStringSync();
    final lists = [
      ...RegExp(r'(?:allAirlines|airlines)\s*:\s*(?:const\s*)?\[(.*?)\]',
              dotAll: true)
          .allMatches(src),
      ...RegExp(r'kGenericUsAirlines\s*=\s*\[(.*?)\]', dotAll: true)
          .allMatches(src),
      ...RegExp(r"'[A-Z]{3}'\s*:\s*\[(.*?)\]", dotAll: true).allMatches(src),
    ];
    for (final m in lists) {
      names.addAll(RegExp(r"'([^']+)'").allMatches(m.group(1)!).map((x) => x.group(1)!));
    }
  }
  return names;
}

// A 1×1 transparent PNG.
final Uint8List _png = Uint8List.fromList(const [
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D,
  0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
  0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4, 0x89, 0x00, 0x00, 0x00,
  0x0D, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
  0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00, 0x00, 0x00, 0x00, 0x49,
  0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
]);

void main() {
  test('every listed airline has its code and its logo on the server', () {
    final names = allListedAirlines();
    expect(names.length, greaterThan(50), reason: 'the parse found the lists');
    final missing = <String>[];
    for (final n in names) {
      if (n.startsWith('Charter')) continue; // no airline, the plane mark
      final code = airlineIataFor(n);
      if (code == null) {
        missing.add('$n (no code)');
      } else if (!File('backend/static/airlines/$code.png').existsSync()) {
        missing.add('$n ($code.png missing)');
      }
    }
    expect(missing, isEmpty);
  });

  test('a variant of a name finds its parent mark', () {
    expect(airlineIataFor('United Airlines (intl)'), 'UA');
    expect(airlineIataFor('Delta Air Lines (regional)'), 'DL');
    expect(airlineIataFor('JetBlue (some)'), 'B6');
    expect(airlineIataFor('American Eagle'), 'AA');
    expect(airlineIataFor('Charter / Private'), isNull);
  });

  testWidgets('the row shows the logo from the server; a charter the plane',
      (t) async {
    final asked = <String>[];
    AirlineLogo.providerFor = (url) {
      asked.add(url);
      return MemoryImage(_png);
    };
    addTearDown(() => AirlineLogo.providerFor = (url) => NetworkImage(url));

    await t.pumpWidget(const Directionality(
      textDirection: TextDirection.ltr,
      child: Column(children: [
        AirlineLogo('Delta Air Lines'),
        AirlineLogo('Charter / Private'),
      ]),
    ));
    await t.pump();
    expect(asked.single, endsWith('/static/airlines/DL.png'));
    expect(t.widget<Image>(find.byType(Image)).semanticLabel,
        'Delta Air Lines');
    expect(find.byType(PlaceGlyph), findsWidgets); // the charter's plane
  });

  test('the airline page uses the logos', () {
    final page = File('lib/screens/airline_select_screen.dart').readAsStringSync();
    expect(page, contains('AirlineLogo(name)'));
    expect(page, isNot(contains('Icons.flight_rounded')));
  });
}
