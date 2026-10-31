import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Owner rule 2026-10-31: nothing a rider or driver sees may say that
/// dispatch, an operator or admin did it.
void main() {
  String read(String p) => File(p).readAsStringSync();
  final banned = RegExp(r'dispatch|despacho|operador|operator',
      caseSensitive: false);

  test('no translated string names dispatch or an operator', () {
    // Every line holding a quoted phrase (identifiers like
    // `dispatchPresenceOffline` are not user text: they carry no space).
    final hits = <String>[];
    for (final line in read('lib/l10n/app_localizations.dart').split('\n')) {
      final t = line.trim();
      if (t.startsWith('//')) continue;
      for (final quote in ["'", '"']) {
        final parts = t.split(quote);
        for (var i = 1; i < parts.length; i += 2) {
          final text = parts[i];
          if (text.contains(' ') && banned.hasMatch(text)) hits.add(text);
        }
      }
    }
    expect(hits, isEmpty);
  });

  test('push fallbacks never say "by dispatch"', () {
    final main = read('lib/main.dart');
    for (final bad in ['por Dispatch', 'by Dispatch', 'por dispatch', 'by dispatch']) {
      expect(main, isNot(contains(bad)));
    }
  });

  test('an operator-written cancel reason never reaches the rider', () {
    final ctrl = read('lib/state/rider_trip_controller.dart');
    expect(ctrl, contains('dispatch|despacho|operador|operator|admin'));
    expect(ctrl, contains("return 'Your trip was cancelled.';"));
  });
}
