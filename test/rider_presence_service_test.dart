import 'dart:async';
import 'dart:io';

import 'package:cruise_app/services/rider_presence_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';

Position _fix(
  double lat,
  double lng, {
  DateTime? timestamp,
}) =>
    Position(
      latitude: lat,
      longitude: lng,
      timestamp: timestamp ?? DateTime.now(),
      accuracy: 100,
      altitude: 0,
      altitudeAccuracy: 0,
      heading: 0,
      headingAccuracy: 0,
      speed: 0,
      speedAccuracy: 0,
    );

RiderPresenceService _service({
  required RiderPresenceSender sender,
  RiderPresenceLocationReader? locationReader,
  RiderPresenceRoleReader? roleReader,
  bool consent = true,
  bool privacy = true,
  Duration interval = const Duration(milliseconds: 20),
}) =>
    RiderPresenceService(
      sender: sender,
      locationReader: locationReader ?? () async => _fix(25.761234, -80.191234),
      roleReader: roleReader ?? () async => 'rider',
      consentReader: () async => consent,
      privacyReader: () async => privacy,
      interval: interval,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('start is idempotent and subsequent sends use the periodic timer',
      () async {
    var activeCalls = 0;
    final secondCall = Completer<void>();
    final service = _service(
      sender: ({required active, lat, lng}) async {
        if (!active) return true;
        activeCalls++;
        if (activeCalls == 2 && !secondCall.isCompleted) {
          secondCall.complete();
        }
        return true;
      },
    );
    addTearDown(service.stop);

    await Future.wait([service.start(), service.start(), service.start()]);
    expect(activeCalls, 1);
    expect(service.isRunning, isTrue);

    await secondCall.future.timeout(const Duration(seconds: 1));
    expect(activeCalls, 2);
  });

  test('periodic ticks never overlap an in-flight send', () async {
    final started = Completer<void>();
    final release = Completer<void>();
    final events = <String>[];
    var concurrent = 0;
    var maxConcurrent = 0;
    final service = _service(
      interval: const Duration(milliseconds: 5),
      sender: ({required active, lat, lng}) async {
        concurrent++;
        if (concurrent > maxConcurrent) maxConcurrent = concurrent;
        if (active) {
          events.add('active:start');
          started.complete();
          await release.future;
          events.add('active:end');
        } else {
          events.add('offline');
        }
        concurrent--;
        return true;
      },
    );
    addTearDown(service.stop);

    final starting = service.start();
    await started.future.timeout(const Duration(seconds: 1));
    await Future<void>.delayed(const Duration(milliseconds: 35));
    expect(events, ['active:start']);

    final stopping = service.stop();
    release.complete();
    await Future.wait([starting, stopping]);

    expect(events, ['active:start', 'active:end', 'offline']);
    expect(maxConcurrent, 1);
  });

  test('every send reads a fresh fix and rounds coordinates to two decimals',
      () async {
    final positions = [
      _fix(25.761234, -80.191234),
      _fix(25.768, -80.198),
    ];
    final calls = <Map<String, double?>>[];
    final secondCall = Completer<void>();
    var reads = 0;
    final service = _service(
      locationReader: () async => positions[reads++],
      sender: ({required active, lat, lng}) async {
        if (active) {
          calls.add({'lat': lat, 'lng': lng});
          if (calls.length == 2 && !secondCall.isCompleted) {
            secondCall.complete();
          }
        }
        return true;
      },
    );
    addTearDown(service.stop);

    await service.start();
    await secondCall.future.timeout(const Duration(seconds: 1));

    expect(reads, 2);
    expect(calls, [
      {'lat': 25.76, 'lng': -80.19},
      {'lat': 25.77, 'lng': -80.2},
    ]);
  });

  test('stale or unavailable fixes are never replaced with cached coordinates',
      () async {
    final calls = <bool>[];
    for (final position in <Position?>[
      _fix(25.76, -80.19,
          timestamp: DateTime.now().subtract(const Duration(minutes: 2))),
      null,
    ]) {
      final service = _service(
        locationReader: () async => position,
        sender: ({required active, lat, lng}) async {
          calls.add(active);
          return true;
        },
      );
      await service.start();
      await service.stop();
    }
    expect(calls, isEmpty);
  });

  test('consent, privacy, and rider role are mandatory before reading GPS',
      () async {
    final cases = <({bool consent, bool privacy, String role})>[
      (consent: false, privacy: true, role: 'rider'),
      (consent: true, privacy: false, role: 'rider'),
      (consent: true, privacy: true, role: 'driver'),
    ];
    for (final item in cases) {
      var locationReads = 0;
      final calls = <bool>[];
      final service = _service(
        consent: item.consent,
        privacy: item.privacy,
        roleReader: () async => item.role,
        locationReader: () async {
          locationReads++;
          return _fix(25.76, -80.19);
        },
        sender: ({required active, lat, lng}) async {
          calls.add(active);
          return true;
        },
      );

      await service.start();
      await service.stop();
      expect(locationReads, 0);
      expect(calls, isEmpty);
    }
  });

  test('an old active response cannot restart sends after stop', () async {
    final started = Completer<void>();
    final release = Completer<void>();
    final calls = <bool>[];
    final service = _service(
      interval: const Duration(milliseconds: 5),
      sender: ({required active, lat, lng}) async {
        calls.add(active);
        if (active) {
          started.complete();
          await release.future;
        }
        return true;
      },
    );

    unawaited(service.start());
    await started.future.timeout(const Duration(seconds: 1));
    final stopping = service.stop();
    release.complete();
    await stopping;
    await Future<void>.delayed(const Duration(milliseconds: 30));

    expect(calls, [true, false]);
    expect(service.isRunning, isFalse);
  });

  test('shutdown awaits active work and sends offline before token cleanup',
      () async {
    final started = Completer<void>();
    final release = Completer<void>();
    final events = <String>[];
    final service = _service(
      sender: ({required active, lat, lng}) async {
        if (active) {
          events.add('active:start');
          started.complete();
          await release.future;
          events.add('active:end');
        } else {
          expect(lat, isNull);
          expect(lng, isNull);
          events.add('presence:offline');
        }
        return true;
      },
    );

    unawaited(service.start());
    await started.future.timeout(const Duration(seconds: 1));
    var stopped = false;
    final stopping = service.stop().then((_) {
      stopped = true;
      events.add('presence:stopped');
    });
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(stopped, isFalse);
    expect(events, ['active:start']);

    release.complete();
    await stopping;
    events.add('token:cleared');
    events.add('auth:offline');

    expect(events, [
      'active:start',
      'active:end',
      'presence:offline',
      'presence:stopped',
      'token:cleared',
      'auth:offline',
    ]);
  });

  test('a rejected offline result does not escape stop', () async {
    final calls = <bool>[];
    final service = _service(
      sender: ({required active, lat, lng}) async {
        calls.add(active);
        return active;
      },
    );

    await service.start();
    await service.stop();

    expect(calls, [true, false]);
  });

  test('main stops presence on dispose and non-rider sync', () {
    final source = File('lib/main.dart')
        .readAsStringSync()
        .replaceAll('\r\n', '\n');
    final syncStart =
        source.indexOf('Future<void> _syncRiderPresence() async {');
    final syncEnd = source.indexOf(
      'Future<void> _stopRiderPresenceThenGoOffline()',
      syncStart,
    );
    expect(syncStart, isNonNegative);
    expect(syncEnd, greaterThan(syncStart));
    final sync = source.substring(syncStart, syncEnd);
    final compactSync = sync.replaceAll(RegExp(r'\s+'), ' ');
    expect(
      compactSync,
      contains(
        "if (me?['role']?.toString().toLowerCase() != 'rider') { "
        'await RiderPresenceService.instance.stop(); return; }',
      ),
    );

    final appStart = source.indexOf('class _UberCloneAppState');
    final disposeStart = source.indexOf('  void dispose() {', appStart);
    final disposeEnd = source.indexOf(
      '  void didChangeAppLifecycleState',
      disposeStart,
    );
    expect(disposeStart, isNonNegative);
    expect(disposeEnd, greaterThan(disposeStart));
    final dispose = source.substring(disposeStart, disposeEnd);
    expect(
      dispose,
      contains('unawaited(RiderPresenceService.instance.stop());'),
    );
  });
}
