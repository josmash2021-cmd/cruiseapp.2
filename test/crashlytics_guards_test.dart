// Crashlytics guards — source-grep tests that pin the fixes for
// production crashes (RangeError in suggestion lists, socket_io parseqs
// RangeError, uncaught 10s TimeoutException in the server-URL screen).
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _read(String path) => File(path).readAsStringSync();

void main() {
  group('FIX 1 — suggestion list RangeError guards', () {
    test('home_screen itemBuilder guards _suggestions before indexing', () {
      final src = _read('lib/screens/home_screen.dart');
      final builderIdx = src.indexOf('itemBuilder: (context, index) {');
      final indexIdx = src.indexOf('final s = _suggestions[index];');
      expect(builderIdx, isNonNegative);
      expect(indexIdx, greaterThan(builderIdx));
      final region = src.substring(builderIdx, indexIdx);
      expect(region, contains('index >= _suggestions.length'));
      expect(region, contains('SizedBox.shrink()'));
    });

    test('pickup_dropoff_search keeps its original guard (regression)', () {
      final src = _read('lib/screens/pickup_dropoff_search_screen.dart');
      expect(src, contains('i < 0 || i >= _suggestions.length'));
      expect(src, contains('final s = _suggestions[i];'));
    });
  });

  group('FIX 2 — socket.io URL sanitize before parseqs', () {
    test('socket_service strips query/fragment before io.io(', () {
      final src = _read('lib/services/socket_service.dart');
      final sanitizeIdx = src.indexOf("replace(query: ''");
      // The REAL socket build, not the string "io.io(" — that appears in a
      // doc comment ("two concurrent io.io() builds…") way before the
      // sanitize and inverted this pin while the source was correct.
      final ioIdx = src.indexOf('_socket = io.io(');
      expect(sanitizeIdx, isNonNegative);
      expect(ioIdx, isNonNegative);
      expect(sanitizeIdx, lessThan(ioIdx));
    });
  });

  group('FIX 3 — account_screen timeouts are caught', () {
    test('_save / _probe / _autoDetect wrap the 10s timeout in try/catch',
        () {
      final src = _read('lib/screens/account_screen.dart');
      for (final method in ['_save()', '_probe()', '_autoDetect()']) {
        final start = src.indexOf('Future<void> $method async {');
        expect(start, isNonNegative, reason: method);
        final end = src.indexOf('\n  }', start);
        final region = src.substring(start, end);
        expect(region, contains('timeout(const Duration(seconds: 10))'),
            reason: method);
        expect(
          region.contains('try {') || region.contains('onTimeout'),
          isTrue,
          reason: '$method must catch the TimeoutException',
        );
        expect(region, contains('if (!mounted) return;'), reason: method);
      }
      // The probe methods must reset the spinner in the catch path.
      for (final method in ['_probe()', '_autoDetect()']) {
        final start = src.indexOf('Future<void> $method async {');
        final end = src.indexOf('\n  }', start);
        final region = src.substring(start, end);
        final catchIdx = region.indexOf('catch');
        expect(catchIdx, isNonNegative, reason: method);
        expect(region.substring(catchIdx), contains('_probing = false'),
            reason: '$method must reset _probing on error');
      }
    });
  });
}
