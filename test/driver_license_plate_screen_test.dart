import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:cruise_app/data/us_cities.dart';
import 'package:cruise_app/screens/driver/driver_license_plate_screen.dart';

void main() {
  testWidgets('plate state dropdown includes every state and territory',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: DriverLicensePlateScreen(
        currentPlate: 'ABC123',
        currentState: 'FL',
      ),
    ));

    await tester.tap(find.byType(DropdownButton<String>));
    await tester.pumpAndSettle();

    final items = tester
        .widget<DropdownButton<String>>(find.byType(DropdownButton<String>))
        .items!;
    final codes = items.map((item) => item.value).toSet();
    expect(codes.length, kUsStateNameToCode.length);
    expect(codes, kUsStateNameToCode.values.toSet());
    expect(codes, containsAll(<String>['AL', 'FL', 'CA', 'TX', 'NY', 'DC', 'PR']));

    await tester.tap(find.text('California').last);
    await tester.pumpAndSettle();
    expect(find.text('California'), findsWidgets);
  });
}
