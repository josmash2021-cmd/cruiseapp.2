import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:cruise_app/map/map_surface_coordinator.dart';

/// Two live Mapbox surfaces crash iOS, so the property under test is not
/// "the handoff is quick" but "the incoming screen never mounts before the
/// outgoing one is gone". Every test here is that property under a
/// different kind of misbehaving holder.
void main() {
  test('first acquire is granted immediately', () async {
    final c = MapSurfaceCoordinator.forTest();
    var revoked = false;
    await c.acquire(owner: 'home', onRevoke: () async => revoked = true);
    expect(c.currentOwner, 'home');
    expect(revoked, isFalse, reason: 'nobody to revoke');
  });

  test('the incoming screen waits for the holder to actually let go', () async {
    final c = MapSurfaceCoordinator.forTest();
    final live = <String>{};

    await c.acquire(
      owner: 'online',
      onRevoke: () async {
        // Simulate a teardown that takes real time, the way a PlatformView
        // disposal does.
        await Future<void>.delayed(const Duration(milliseconds: 40));
        live.remove('online');
      },
    );
    live.add('online');

    await c.acquire(
      owner: 'trip',
      onRevoke: () async => live.remove('trip'),
    );
    // The whole point: by the time 'trip' is allowed to mount, 'online' is
    // already down. Never two at once.
    expect(live, isEmpty);
    live.add('trip');
    expect(live, {'trip'});
    expect(c.currentOwner, 'trip');
  });

  test('a holder that never lets go does not block forever', () async {
    final c = MapSurfaceCoordinator.forTest();
    await c.acquire(
      owner: 'stuck',
      onRevoke: () => Completer<void>().future, // never completes
    );

    final sw = Stopwatch()..start();
    await c.acquire(owner: 'next', onRevoke: () async {});
    sw.stop();

    expect(c.currentOwner, 'next', reason: 'must not deadlock the UI');
    expect(sw.elapsed, greaterThanOrEqualTo(MapSurfaceCoordinator.revokeTimeout));
  });

  test('a holder that throws while releasing still hands over', () async {
    final c = MapSurfaceCoordinator.forTest();
    await c.acquire(
      owner: 'angry',
      onRevoke: () async => throw StateError('disposed mid-revoke'),
    );
    await c.acquire(owner: 'next', onRevoke: () async {});
    expect(c.currentOwner, 'next');
  });

  test('simultaneous acquires hand off in order, never in parallel', () async {
    final c = MapSurfaceCoordinator.forTest();
    final order = <String>[];
    var concurrent = 0;
    var maxConcurrent = 0;

    Future<void> Function() revoke(String name) => () async {
          concurrent++;
          maxConcurrent = maxConcurrent > concurrent ? maxConcurrent : concurrent;
          await Future<void>.delayed(const Duration(milliseconds: 10));
          order.add('revoked:$name');
          concurrent--;
        };

    await c.acquire(owner: 'a', onRevoke: revoke('a'));
    // Fired in the same tick, as two screens mounting in one frame would.
    final b = c.acquire(owner: 'b', onRevoke: revoke('b'));
    final d = c.acquire(owner: 'c', onRevoke: revoke('c'));
    await Future.wait([b, d]);

    expect(order, ['revoked:a', 'revoked:b']);
    expect(maxConcurrent, 1, reason: 'handoffs must not overlap');
    expect(c.currentOwner, 'c');
  });

  test('re-acquiring as the current owner does not revoke yourself', () async {
    final c = MapSurfaceCoordinator.forTest();
    var revokes = 0;
    Future<void> onRevoke() async => revokes++;

    await c.acquire(owner: 'home', onRevoke: onRevoke);
    await c.acquire(owner: 'home', onRevoke: onRevoke);
    expect(revokes, 0);
    expect(c.currentOwner, 'home');
  });

  test('an evicted screen cannot release its successor on the way out', () async {
    final c = MapSurfaceCoordinator.forTest();
    await c.acquire(owner: 'online', onRevoke: () async {});
    await c.acquire(owner: 'trip', onRevoke: () async {});

    // The online screen's dispose() runs late, after it was already evicted.
    c.release('online');

    expect(c.currentOwner, 'trip',
        reason: 'a late dispose must not blank the live screen');
  });

  test('release clears the holder so the next acquire is instant', () async {
    final c = MapSurfaceCoordinator.forTest();
    var revoked = false;
    await c.acquire(owner: 'trip', onRevoke: () async => revoked = true);
    c.release('trip');
    expect(c.currentOwner, isNull);

    await c.acquire(owner: 'home', onRevoke: () async {});
    expect(revoked, isFalse, reason: 'nothing was holding it');
    expect(c.currentOwner, 'home');
  });
}
