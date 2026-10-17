import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Guardian for the driver city + date-of-birth surfacing in the dispatch
/// panel (user spec 2026-10-17: "quiero ver qué ciudad seleccionó cada
/// driver para trabajar, categorizarlos por ciudad para ver cuántos hay en
/// cada una, y ver su fecha de nacimiento").
///
/// The backend already carried `drive_city` / `drive_state` /
/// `date_of_birth` in _user_dict (roster /admin/users and person detail);
/// /admin/verifications got them the same day. The panel bundle (built
/// React, source outside this repo — manual edits with guard-pins) maps
/// them onto the person rows (jt Firestore / zs inherited / Ws backend
/// roster / en queue row / Gs fillFrom / Se+Zs+w of the verification
/// queue), shows them as person-page tiles, and the Drivers page gets a
/// "Ciudades" chip section that filters the list per city with counts.
void main() {
  final html = File('backend/dispatch_panel/index.html')
      .readAsStringSync()
      .replaceAll('\r\n', '\n');
  final match =
      RegExp(r'src="/panel/assets/(index-[^"]+\.js)"').firstMatch(html);
  final bundle = match == null
      ? ''
      : File('backend/dispatch_panel/assets/${match.group(1)}')
          .readAsStringSync();
  final driversPage =
      File('backend/dispatch_panel/assets/index-azyIyM-i.js')
          .readAsStringSync();
  final verificationPage =
      File('backend/dispatch_panel/assets/index-jhlVlbS1.js')
          .readAsStringSync();
  final adminPy =
      File('backend/routers/admin.py').readAsStringSync();

  test('the entry bundle maps driveCity/driveState/dateOfBirth everywhere',
      () {
    expect(bundle, contains('panel_driver_city_dob_guard_test'),
        reason: 'the guard-pin comment must survive — a panel rebuild must '
            're-apply these edits (source lives outside this repo)');
    // jt (Firestore drivers) + Ws (backend roster) + Gs (fillFrom)
    expect(bundle, contains('driveCity:c(t.driveCity??t.drive_city)'));
    expect(bundle, contains('driveCity:c(e.drive_city)'));
    expect(bundle, contains('driveCity:e.driveCity??t.driveCity??null'));
    // the verification queue: en (backend row) + Zs (Firestore doc) + Se
    // (merge) + w (roster fill)
    expect(bundle, contains('dateOfBirth:c(e.date_of_birth)'));
    expect(bundle, contains('driveCity:c(t.driveCity)'));
    expect(bundle, contains('driveCity:t.driveCity??e.driveCity'));
    expect(bundle, contains('driveCity:N(h.driveCity,m.drive_city)'));
  });

  test('both person pages show the city and the date of birth', () {
    for (final page in [driversPage, verificationPage]) {
      expect(page, contains('Ciudad de trabajo'),
          reason: 'the work-city tile exists');
      expect(page, contains('Fecha de nacimiento'),
          reason: 'the DOB tile exists');
      expect(page, contains('IconMapPin'));
      expect(page, contains('IconCalendar'));
    }
  });

  test('the Drivers page categorizes by city with counts', () {
    expect(driversPage, contains('"Ciudades"'),
        reason: 'the chips section header exists');
    expect(driversPage, contains('const cityOf='),
        reason: 'city resolver: driveCity → driveState → "Sin ciudad"');
    expect(driversPage, contains('Sin ciudad'));
    expect(driversPage, contains('cityCounts'),
        reason: 'per-city counts feed the chips');
    expect(driversPage, contains('cityF===null?base:base.filter'),
        reason: 'the city chip filters the visible list');
  });

  test('the backend payloads carry the three fields', () {
    expect(adminPy, contains('"drive_city": getattr(u, \'drive_city\', None),'),
        reason: '/admin/verifications rows carry drive_city');
    expect(adminPy, contains('"drive_state": getattr(u, \'drive_state\', None),'));
    expect(adminPy, contains('"date_of_birth": u.date_of_birth.isoformat()'),
        reason: 'both /admin/verifications and _user_dict ship the DOB');
  });
}
