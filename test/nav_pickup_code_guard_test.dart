import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Owner-approved drawing 2026-11-03: the pickup code — the ONLY unlock for
/// "Desliza para recoger" — can be typed inside the navigation panel (it
/// could only be typed on the old trip sheet, so a driver in navigation had
/// to leave it to pick the rider up). The rider has it on the trip sheet
/// from the start, and bigger on the arrival screen.
void main() {
  String read(String p) =>
      File(p).readAsStringSync().replaceAll('\r\n', '\n');

  final trip = read('lib/screens/driver/driver_trip_accept_screen.dart');
  final nav = read('lib/screens/driver/driver_nav_view.dart');
  final panel = read('lib/screens/driver/nav_trip_panel.dart');
  final sheet = read('lib/widgets/tracking/driver_info_card.dart');

  test('the nav panel carries the code row above the slider', () {
    expect(trip, contains('Widget _buildNavPickupCode() {'));
    expect(trip, contains('? _buildNavPickupCode()'));
    expect(nav, contains('codeEntry: widget.toPickup ? widget.pickupCodeEntry : null,'));
    expect(panel, contains(
        'if (stage == NavPanelStage.waitingPickup && widget.codeEntry != null)'));
    expect(panel, contains('? s.navWaitingCode'));
  });

  test('one code field at a time: the sheet card steps aside in nav', () {
    final i = trip.indexOf('bool get _showPickupPinCard =>');
    expect(trip.substring(i, i + 260), contains('!_navMode'));
  });

  test('a tap elsewhere closes the keyboard and keeps the letters', () {
    expect('onTapOutside: (_) => _pinFocusNode.unfocus(),'.allMatches(trip).length,
        2, reason: 'the nav row and the sheet card');
  });

  test('confirmed: green boxes, "Código confirmado"', () {
    final i = trip.indexOf('Widget _buildNavPickupCode() {');
    final body = trip.substring(i, i + 4000);
    expect(body, contains('ok ? s.pickupCodeConfirmedShort : s.pickupCodeAskRider'));
    expect(body, contains('const green = Color(0xFF4ADE80);'));
  });

  test("the rider's sheet shows the code from the start", () {
    expect(sheet, contains('Future<void> _loadSheetPickupPin() async {'));
    expect(sheet, contains("key: const ValueKey('sheet-pickup-code'),"));
    expect(sheet, contains('_sheetPinChip(_sheetPickupPin!),'));
  });
}
