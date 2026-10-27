import 'package:cruise_app/l10n/app_localizations.dart';
import 'package:cruise_app/screens/driver/driver_rest_gate_mixin.dart';
import 'package:cruise_app/services/driver_rest_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _RestHarness extends StatefulWidget {
  const _RestHarness();

  @override
  State<_RestHarness> createState() => _RestHarnessState();
}

class _RestHarnessState extends State<_RestHarness> with DriverRestGate {
  @override
  void initState() {
    super.initState();
    initDriverRestGate();
  }

  @override
  void dispose() {
    disposeDriverRestGate();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Text(driverIsResting ? driverRestLabel : 'Aceptar'),
    );
  }
}

void main() {
  testWidgets('scheduled CTA returns to accept when the shared rest clears',
      (tester) async {
    final until = DateTime.now().add(const Duration(hours: 6));
    SharedPreferences.setMockInitialValues({
      'driver_rest_until': until.millisecondsSinceEpoch,
    });
    DriverRestService.restUntil.value = until;

    await tester.pumpWidget(const MaterialApp(
      locale: Locale('es'),
      localizationsDelegates: [
        S.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: [Locale('es'), Locale('en')],
      home: _RestHarness(),
    ));
    await tester.pump();

    expect(find.textContaining('Descanso 05:'), findsOneWidget);

    await DriverRestService.set(null);
    await tester.pump();
    expect(find.text('Aceptar'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    expect(tester.takeException(), isNull);
  });
}
