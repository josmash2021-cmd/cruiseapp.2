import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Guardian for the full-US city picker (owner spec 2026-10-18: "puedes
/// colocar para todos las ciudades y estados de estados unidos" — the
/// driver onboarding "Where do you plan to drive?" must offer EVERY US
/// state and every inhabited city, with search).
void main() {
  final data = File('lib/data/us_cities.dart').readAsStringSync();
  final picker = File('lib/screens/driver/driver_drive_city_screen.dart')
      .readAsStringSync();
  final l10n = File('lib/l10n/app_localizations.dart').readAsStringSync();

  test('the dataset covers the whole US with real cities, attributed', () {
    final groups = RegExp(r"UsStateGroup\('").allMatches(data).length;
    expect(groups, greaterThanOrEqualTo(50),
        reason: 'all 50 states + DC (and territories with population)');
    final cities = RegExp(r"UsCity\('").allMatches(data).length;
    expect(cities, greaterThan(10000),
        reason: 'every inhabited US place — not the old 15-city curated list');
    expect(data, contains('GeoNames'),
        reason: 'CC-BY attribution is required by the data license');
    expect(data, contains('population > 0'));
  });

  test('the picker searches the full list (unusable without it at 31k)', () {
    expect(picker, contains('class _CityPickerSheetState'),
        reason: 'stateful now — it owns a search field');
    expect(picker, contains('TextField('));
    expect(picker, contains('searchCityHint'));
    expect(picker, contains('toLowerCase().contains(q)'),
        reason: 'case-insensitive contains match over every state group');
    expect(picker, contains('out.length >= 100'),
        reason: 'results capped so a broad term never floods the sheet');
    expect(l10n, contains('searchCityHint'));
    expect(l10n, contains('noCitiesFound'));
  });
}
