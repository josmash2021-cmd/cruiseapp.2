import 'package:flutter_test/flutter_test.dart';

/// The rider picks a tier by looking at a car on "Choose a ride", then the
/// tracking card tells them that car has arrived. If the two screens draw
/// different renders, the rider is watching for the wrong vehicle.
///
/// Both mappings are duplicated here rather than imported: the originals
/// live inside private extensions on State classes and are not reachable
/// from a test. Copies drift, so this test exists to fail loudly when they
/// do — if you change either function, change it here too and the
/// equivalence assertions below will tell you whether they still agree.

/// _carAssetForOption in lib/screens/ride_request_widgets.dart
String pickerAsset(String name) {
  final key = name.trim().toLowerCase();
  if (key.contains('vip') || key.contains('suburban')) {
    return 'assets/images/cruisert1.png';
  }
  if (key.contains('sedan') || key.contains('camry')) {
    return 'assets/images/cruisert2.png';
  }
  return 'assets/images/cruisert3.png';
}

/// _vehicleAsset in lib/widgets/tracking/driver_info_card.dart
String trackingAsset({required String rideName, required String model}) {
  final rn = rideName.toLowerCase();
  final m = model.toLowerCase();
  if (rn.contains('vip') || rn.contains('black') ||
      rn.contains('suv') || rn.contains('suburban') ||
      m.contains('suburban')) {
    return 'assets/images/cruisert1.png';
  }
  if (rn.contains('sedan') || rn.contains('premium') ||
      rn.contains('camry') || m.contains('camry')) {
    return 'assets/images/cruisert2.png';
  }
  return 'assets/images/cruisert3.png';
}

void main() {
  group('picker and tracking card agree on the car render', () {
    // rideName on the tracking screen comes from the trip's vehicle_type
    // (main.dart passes fresh['vehicle_type']), so these are the canonical
    // backend values, paired with the model dispatch actually assigned.
    const cases = <String, List<String>>{
      // vehicle_type : [model sent by dispatch, tier name in the picker]
      'vip': ['Chevrolet Suburban', 'Suburban'],
      'sedan': ['Toyota Camry', 'Camry'],
      'premium': ['Toyota Camry', 'Camry'],
      'comfort': ['Ford Fusion', 'Fusion'],
    };

    cases.forEach((vehicleType, pair) {
      final model = pair[0];
      final pickerName = pair[1];
      test('$vehicleType → same render on both screens', () {
        expect(
          trackingAsset(rideName: vehicleType, model: model),
          pickerAsset(pickerName),
          reason: 'a rider who chose $vehicleType must see the same car '
              'again on the tracking card',
        );
      });
    });

    test('the Fusion resolves to cruisert3 on both, not cruisert2', () {
      // Regression: an earlier tracking mapping matched "fusion" into the
      // sedan bucket, so the exact vehicle in production showed a
      // different car than the one picked.
      expect(pickerAsset('Fusion'), 'assets/images/cruisert3.png');
      expect(
        trackingAsset(rideName: 'comfort', model: 'Black Ford Fusion'),
        'assets/images/cruisert3.png',
      );
    });

    test('tier wins over model when dispatch sends a different vehicle', () {
      // A VIP booking stays a VIP render even if the assigned car is a
      // Camry — the rider paid for the tier they saw.
      expect(
        trackingAsset(rideName: 'vip', model: 'Toyota Camry'),
        'assets/images/cruisert1.png',
      );
    });

    test('unknown tier falls back instead of throwing', () {
      expect(
        trackingAsset(rideName: '', model: ''),
        'assets/images/cruisert3.png',
      );
    });
  });
}
