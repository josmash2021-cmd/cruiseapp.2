import 'package:cruise_app/widgets/tracking/vehicle_identity.dart';
import 'package:flutter_test/flutter_test.dart';

/// "Toyota Camry gris" / "Gray Toyota Camry" — the car line of the
/// Lyft-style lock-screen card (owner 2026-11-09). The server writes the
/// same line (vehicle_car_line in backend/utils/helpers.py, same cases in
/// backend/tests/test_ride_live_activity.py) when it repaints the card.
void main() {
  String line(String make, String model, String color, bool es) =>
      vehicleCarLine(make: make, model: model, color: color, es: es);

  test('the color in the rider\'s language, in each language\'s order', () {
    expect(line('Toyota', 'Camry', 'Gray', true), 'Toyota Camry gris');
    expect(line('Toyota', 'Camry', 'gris', false), 'Gray Toyota Camry');
    expect(line('Chevrolet', 'Suburban', 'Negro', true),
        'Chevrolet Suburban negro');
    expect(line('Chevrolet', 'Suburban', 'Negro', false),
        'Black Chevrolet Suburban');
  });

  test('an unknown color stays as typed; empty parts drop out', () {
    expect(line('Honda', 'Civic', 'Pearl', true), 'Honda Civic Pearl');
    expect(line('Honda', 'Civic', '', false), 'Honda Civic');
    expect(line('', '', '', true), '');
  });
}
