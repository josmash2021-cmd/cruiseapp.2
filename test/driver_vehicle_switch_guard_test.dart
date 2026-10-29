import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Guard for the multi-vehicle switch (owner spec 2026-10-29).
///
/// The documents page groups rows into "Action needed" (missing, rejected,
/// expiring, or uploaded and still under review) and "Completed" (approved
/// only, and the count says exactly that); the selected non-active car
/// carries a "Use vehicle" action enabled only once the vehicle AND its own
/// documents are approved; the backend refuses a swap mid-trip because the
/// rider's screen re-reads the active car on every poll.
void main() {
  final docs = File('lib/screens/driver/driver_documents_screen.dart')
      .readAsStringSync();
  final list =
      File('lib/screens/driver/driver_vehicle_screen.dart').readAsStringSync();
  final detail = File('lib/screens/driver/driver_vehicle_detail_screen.dart')
      .readAsStringSync();
  final copy = File('lib/screens/driver/vehicle_switch_copy.dart')
      .readAsStringSync();
  final l10n = File('lib/l10n/app_localizations.dart').readAsStringSync();
  final drivers = File('backend/routers/drivers.py').readAsStringSync();

  test('documents page splits open work from approved rows', () {
    expect(docs, contains('bool _isCompleted(Map<String, dynamic> doc) =>'));
    expect(docs, contains("== 'approved' && !_needsAction(doc)"));
    expect(docs, contains('title: s.docsActionNeeded,'));
    expect(docs, contains('title: s.docsSubmitted,'));
    expect(docs, contains('children: todo.map(_documentCard).toList()'));
    expect(docs, contains('children: done.map(_documentCard).toList()'));
    expect(docs.contains('approvedCount'), isFalse,
        reason: 'the Completed count must be the approved rows it holds');
    // Both counts read the bucket they sit on, nothing else.
    final completedChip = docs.indexOf('done.length,');
    final todoChip = docs.indexOf('todo.length,');
    expect(completedChip, greaterThan(0));
    expect(todoChip, greaterThan(0));
    expect(todoChip, lessThan(completedChip),
        reason: 'Action needed lists before Completed');
  });

  test('pending rows say "Pending approval", never an upload date', () {
    final card = docs.substring(docs.indexOf('Widget _documentCard('));
    final pendingBranch = card.indexOf('} else if (isPending) {');
    final expiryBranch = card.indexOf('} else if (expiry.isNotEmpty) {');
    expect(pendingBranch, greaterThan(0));
    expect(pendingBranch, lessThan(expiryBranch));
    expect(card, contains('subtitle = s.pendingApproval;'));
    expect(card.contains('subtitle = s.pending;'), isFalse);
    // A new car's plate is not a "plate change".
    expect(docs, contains("'plate_change': plateChange,"));
    expect(card, contains("doc['plate_change'] == true"));
  });

  test('hero distinguishes done / under review / action needed', () {
    expect(docs,
        contains('Widget _hero(S s, {required bool allSet, required bool underReview})'));
    expect(docs, contains('s.docsPendingReviewTitle'));
    expect(docs, contains('s.docsPendingReviewSubtitle'));
    expect(docs, contains('final underReview = !allSet && !_documents.any(_needsAction);'));
  });

  test('documents page offers Use vehicle only for an approved, documented car',
      () {
    expect(docs, contains('Widget _useVehicleRow(S s, Map<String, dynamic> vehicle)'));
    final row = docs.substring(docs.indexOf('Widget _useVehicleRow('));
    expect(row, contains("(vehicle['approval_status'] ?? 'pending') == 'approved'"));
    expect(row, contains("vehicle['documents_approved'] == true"));
    expect(row, contains('if (approved && docsApproved) {'));
    expect(row, contains('s.useVehicleAction'));
    expect(row, contains('s.vehicleAwaitingApprovalHint'));
    expect(docs, contains('if (selected.isNotEmpty && !selectedIsActive) ...['));
    expect(docs, contains('selectedIsActive ? s.primaryVehicle : s.selectedVehicle'));
    final fn = docs.substring(
        docs.indexOf('Future<void> _useSelectedVehicle() async {'),
        docs.indexOf('/// One document.'));
    expect(fn, contains('await ApiService.useVehicle(id);'));
    expect(fn, contains('await _refreshAll();'));
    expect(fn, contains('vehicleSwitchErrorCopy(e, S.of(context))'));
    expect(fn, contains('ScaffoldMessenger.maybeOf(context)'));
    expect(fn.contains('ScaffoldMessenger.of(context)'), isFalse,
        reason: 'post-await lookups use maybeOf (release-only null crash)');
    expect(fn.contains('connectionError'), isFalse,
        reason: 'a 400/409 from /use is not a connection error');
  });

  test('vehicle list and detail gate Use on approved documents too', () {
    expect(list, contains('if (!isActive && isApproved && documentsApproved)'));
    expect(list, contains('final readyToUse = isApproved && documentsApproved;'));
    expect(list, contains('vehicleSwitchErrorCopy(e, S.of(context))'));
    expect(list, contains('S.of(context).vehicleNowInUse'));
    expect(detail, contains('documentsApproved &&'));
    expect(detail, contains('vehicleSwitchErrorCopy(e, S.of(context))'));
    String useFn(String raw, String head) {
      final src = raw.replaceAll('\r\n', '\n');
      final start = src.indexOf(head);
      expect(start, greaterThanOrEqualTo(0), reason: head);
      final end = src.indexOf('\n  }\n', start);
      return src.substring(start, end);
    }

    for (final fn in [
      useFn(list, 'Future<void> _useVehicle(int vehicleId) async {'),
      useFn(detail,
          'Future<void> _useVehicle(BuildContext context, int vehicleId) async {'),
    ]) {
      expect(fn.contains('connectionError'), isFalse,
          reason: 'a 400/409 from /use is not a connection error');
      expect(fn.contains('ScaffoldMessenger.of(context)'), isFalse);
    }
  });

  test('one error copy for the switch, mapped from the backend status', () {
    expect(copy, contains('if (error.statusCode == 409) return s.vehicleSwitchBlockedOnTrip;'));
    expect(copy, contains('if (error.statusCode == 400) return s.vehicleNotReadyToUse;'));
    expect(copy, contains('return s.connectionError;'));
    for (final key in [
      'useVehicleAction',
      'selectedVehicle',
      'vehicleSwitchBlockedOnTrip',
      'vehicleNotReadyToUse',
      'vehicleAwaitingApprovalHint',
      'docsPendingReviewTitle',
      'docsPendingReviewSubtitle',
    ]) {
      expect(l10n, contains('String get $key =>'), reason: '$key missing');
    }
  });

  test('backend switch is exclusive, idempotent and frozen mid-trip', () {
    final use = drivers.substring(
        drivers.indexOf('async def use_vehicle('),
        drivers.indexOf('@router.delete("/drivers/vehicles/{vehicle_id}"'));
    expect(use, contains('if vehicle.is_active:'));
    expect(use, contains('Trip.status.in_(_VEHICLE_SWITCH_BUSY_STATUSES)'));
    expect(use, contains('raise HTTPException(409, "vehicle_switch_blocked_on_trip")'));
    expect(use, contains('.values(is_active=False)'));
    expect(use, contains('vehicle.is_active = True'));
    expect(use, contains('vehicle_is_selectable('));
    expect(drivers, contains('_VEHICLE_SWITCH_BUSY_STATUSES = ('));
    expect(drivers.contains('"requested",\n    "scheduled_accepted"'), isFalse);
  });
}
