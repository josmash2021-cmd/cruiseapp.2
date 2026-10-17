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

  group('FIX 4 — Crashlytics noise filter (clusters 2026-10-17, build 733)', () {
    test('ambient network failures are never recorded as crashes', () {
      final src = _read('lib/main.dart');
      expect(src, contains('bool _isExpectedNetworkError(Object error)'));
      expect(src, contains("s.contains('HandshakeException')"));
      expect(src, contains("s.contains('SocketException')"));
      expect(src, contains("s.contains('HTTP request failed')"));
      // Los 3 handlers globales pasan por el filtro (FlutterError,
      // platformDispatcher y el zone de runZonedGuarded).
      expect(
          src,
          contains(
              'if (kReleaseMode && !_isExpectedNetworkError(details.exception)) {'));
      expect(
          src,
          contains('if (kReleaseMode && !_isExpectedNetworkError(error)) {'));
      // El build-error logger tampoco graba la carrera del teardown de
      // cámara.
      expect(
          src,
          contains(
              "!'\${details.exception}'.contains('Disposed CameraController')"));
    });

    test('every camera screen null-swaps its controller on dispose', () {
      // La animación de salida de la ruta rebuilda el widget DESPUÉS de
      // dispose() — sin null-swap el build llama buildPreview sobre un
      // controller dispuesto (26 fallas / 18 usuarios, build 733).
      const fields = {
        'lib/screens/face_liveness_screen.dart': '_cam',
        'lib/screens/identity_verification_screen.dart': '_ctrl',
        'lib/screens/card_scan_screen.dart': '_ctrl',
        'lib/screens/driver/license_scanner_screen.dart': '_ctrl',
        'lib/screens/driver/onboarding/license_capture_screen.dart': '_ctrl',
        'lib/screens/driver/onboarding/profile_photo_capture_screen.dart':
            '_ctrl',
      };
      fields.forEach((path, field) {
        final src = _read(path);
        expect(
            src,
            contains(
                'final c = $field;\n    $field = null;\n    c?.dispose();'),
            reason: '$path must null-swap $field in dispose()');
      });
    });
  });
}
