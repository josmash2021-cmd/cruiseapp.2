import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Guardian for the scheduled-ride details page + the offer lockout window
/// (user spec 2026-09-30):
///   1. The countdown coin keeps its numbers INSIDE, on one centred line.
///   2. The pickup/dropoff rail is the booking one: gold dot → line → white
///      dot, never the generic green/red bullets.
///   3. Start opens at T-30 min; no new offers from T-60 min until ~1 min
///      from the dropoff (the chained unlock every trip already had).
void main() {
  final screen = File('lib/screens/driver/scheduled_ride_details_screen.dart')
      .readAsStringSync();
  final dispatch = File('backend/routers/dispatch.py').readAsStringSync();
  final scheduled = File('backend/routers/scheduled.py').readAsStringSync();

  group('countdown coin (numbers never escape)', () {
    test('the countdown is one fitted line inside padded bounds', () {
      expect(screen, contains('FittedBox('));
      expect(screen, contains('fit: BoxFit.scaleDown'));
      expect(screen, contains('maxLines: 1'));
      expect(screen,
          contains('padding: const EdgeInsets.symmetric(horizontal: 22)'),
          reason: 'without the inset the text can still reach the edge');
    });
  });

  group('address rail is the booking rail', () {
    test('gold pickup dot, white dropoff dot, thin connector', () {
      expect(screen, contains('_addressRow(\n                        color: _gold,'));
      expect(screen,
          contains('_addressRow(\n                        color: Colors.white,'));
      expect(screen, contains('width: 1.5, height: 20, color: Colors.white12'),
          reason: 'same connector geometry as the booking rail');
      final rowStart = screen.indexOf('Widget _addressRow({');
      final row = screen.substring(rowStart, rowStart + 900);
      expect(row.contains('shape: BoxShape.circle'), isTrue);
      expect(row.contains('Icon(icon'), isFalse,
          reason: 'the generic icon bullet is gone');
    });
  });

  group('start window + offer lockout', () {
    test('start opens 30 min before pickup', () {
      expect(screen, contains('_secondsRemaining <= 1800'));
      expect(screen, contains('- 30)}'),
          reason: 'the "available in" label counts to the 30-min window');
    });

    test('candidates are excluded from T-60 min before the claimed pickup', () {
      expect(dispatch, contains('upcoming_scheduled = ('));
      expect(dispatch,
          contains('_sched_lock_until = utc_now() + timedelta(minutes=60)'));
      expect(dispatch, contains('~upcoming_scheduled'),
          reason: 'the filter must live in the one candidate choke point, '
              'not only in the poll (the old cosmetic lock)');
      expect(scheduled, contains('LOCKOUT_MINUTES = 60'));
    });

    test('the ~1 min dropoff unlock is the existing chained window, untouched',
        () {
      expect(dispatch, contains('_CHAIN_MAX_REMAINING_KM = 1.6'),
          reason: 'the chained unlock every trip already had — do not '
              're-tune it for this spec');
    });
  });
}
