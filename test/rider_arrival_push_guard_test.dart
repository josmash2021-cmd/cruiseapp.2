import 'dart:io';

import 'package:cruise_app/l10n/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('the guide uses real estimate and near-arrival copy ES/EN',
      (tester) async {
    Future<void> check(
        String code, String estimate, String near, String onWay) async {
      final s = S(Locale(code));
      await tester.pumpWidget(MaterialApp(
        locale: Locale(code),
        localizationsDelegates: const [
          S.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        home: Builder(
          builder: (context) {
            return Column(
              children: [
                Text(s.driverArrivesInEstimate(7)),
                Text(s.driverArrivingCard),
                Text(s.driverOnTheWayCard),
              ],
            );
          },
        ),
      ));
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(s.driverArrivesInEstimate(7), estimate);
      expect(s.driverArrivingCard, near);
      expect(s.driverOnTheWayCard, onWay);
    }

    await check('es', 'Tu conductor llega en un estimado de 7 min',
        'El driver está por llegar', 'Tu conductor ya va en camino');
    await check('en', 'Your driver arrives in about 7 min',
        'Your driver is almost here', 'Your driver is on the way');
    expect(tester.takeException(), isNull);
  });

  test('the 2-minute foreground body and tap are rider-only', () {
    final main = File('lib/main.dart').readAsStringSync();
    expect(main, contains('Tu driver llega en 2 minutos o menos.'));
    expect(main, contains('Your driver arrives in 2 minutes or less.'));
    expect(main,
        contains("type == 'driver_arriving' || type == 'driver_arrived'"));
    expect(main, contains('_navigateToScheduledTracking(tripId)'));
    expect(main, contains("if (mode != 'rider') return;"));
  });

  test('the guide reads the ETA estimate in both presentation paths', () {
    final indicator = File('lib/widgets/tracking/trip_phase_indicator.dart')
        .readAsStringSync();
    expect(
        indicator.split('driverArrivesInEstimate(_etaMinutes)').length - 1, 2);
    final l10n = File('lib/l10n/app_localizations.dart').readAsStringSync();
    expect(l10n, contains('driverArrivesInEstimate(int minutes)'));
    expect(l10n, contains('Tu conductor llega en un estimado de'));
    expect(l10n, contains('Your driver arrives in about'));
  });

  test('ETA uses the authenticated location patch and the real driver', () {
    final api = File('lib/services/api_service.dart').readAsStringSync();
    expect(api, contains('int? etaSeconds'));
    expect(api, contains("if (etaSeconds != null) 'eta_seconds': etaSeconds"));
    final controller = File('lib/screens/driver/driver_online_controller.dart')
        .readAsStringSync();
    expect(
        controller, contains('etaSeconds: _navEta > 0 ? _navEta * 60 : null'));

    final schema = File('backend/models/schemas.py').readAsStringSync();
    expect(schema,
        contains('eta_seconds: int | None = Field(default=None, ge=0)'));
    final service =
        File('backend/services/approach_notifications.py').readAsStringSync();
    expect(service, contains('Trip.driver_id == driver_id'));
    expect(service, contains('Trip.rider_approach_notified_at.is_(None)'));
    expect(service, contains('eta_seconds > 120'));
    expect(service, contains('"type": "driver_arriving"'));
    expect(service, isNot(contains('_send_fcm_push_async(token, title=')),
        reason: 'the copy is localized, not Spanish-only');
  });
}
