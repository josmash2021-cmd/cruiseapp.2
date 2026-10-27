import 'package:cruise_app/services/driver_rest_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('rest restores the persisted deadline and formats its countdown',
      () async {
    final until = DateTime.now().add(const Duration(hours: 6));
    SharedPreferences.setMockInitialValues({
      'driver_rest_until': until.millisecondsSinceEpoch,
    });
    DriverRestService.restUntil.value = null;

    await DriverRestService.restore();

    expect(DriverRestService.restUntil.value?.millisecondsSinceEpoch,
        until.millisecondsSinceEpoch);
    expect(DriverRestService.remaining.inHours, greaterThanOrEqualTo(5));
    expect(
        DriverRestService.format(
            const Duration(hours: 5, minutes: 4, seconds: 3)),
        '05:04:03');
  });

  test('server expiry clears the shared rest and its persistence', () async {
    final until = DateTime.now().add(const Duration(hours: 6));
    SharedPreferences.setMockInitialValues({
      'driver_rest_until': until.millisecondsSinceEpoch,
    });
    await DriverRestService.set(until);

    await DriverRestService.syncFromServer({
      'rest_until':
          DateTime.now().subtract(const Duration(seconds: 1)).toIso8601String(),
    });

    expect(DriverRestService.isResting, isFalse);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getInt('driver_rest_until'), 0);
  });
}
