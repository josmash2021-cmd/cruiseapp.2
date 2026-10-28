import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'api_service.dart';

typedef RiderPresenceSender = Future<bool> Function({
  required bool active,
  double? lat,
  double? lng,
});
typedef RiderPresenceLocationReader = Future<Position?> Function();
typedef RiderPresenceRoleReader = Future<String?> Function();
typedef RiderPresenceFlagReader = Future<bool> Function();

class RiderPresenceService {
  static const consentPreferenceKey = 'rider_presence_consent_v1';
  static const privacyPreferenceKey = 'privacy_location';

  static final RiderPresenceService instance = RiderPresenceService();

  RiderPresenceService({
    RiderPresenceSender? sender,
    RiderPresenceLocationReader? locationReader,
    RiderPresenceRoleReader? roleReader,
    RiderPresenceFlagReader? consentReader,
    RiderPresenceFlagReader? privacyReader,
    this.interval = const Duration(seconds: 60),
    this.maxFixAge = const Duration(seconds: 15),
  })  : _sender = sender ?? ApiService.updateRiderPresence,
        _locationReader = locationReader ?? _readFreshLocation,
        _roleReader = roleReader ?? _readRole,
        _consentReader = consentReader ?? _readConsent,
        _privacyReader = privacyReader ?? _readPrivacy;

  final RiderPresenceSender _sender;
  final RiderPresenceLocationReader _locationReader;
  final RiderPresenceRoleReader _roleReader;
  final RiderPresenceFlagReader _consentReader;
  final RiderPresenceFlagReader _privacyReader;
  final Duration interval;
  final Duration maxFixAge;

  Timer? _timer;
  int _generation = 0;
  bool _running = false;
  bool _sendBusy = false;
  bool _tickPending = false;
  bool _activeAttempted = false;
  Future<void> _inFlight = Future<void>.value();
  Future<void>? _stopInFlight;

  bool get isRunning => _running;

  Future<void> start() {
    if (_running) return _inFlight;
    _stopInFlight = null;
    _running = true;
    final generation = ++_generation;
    _timer?.cancel();
    _timer = Timer.periodic(interval, (_) {
      unawaited(_requestActive(generation));
    });
    return _requestActive(generation);
  }

  Future<void> stop() {
    final existing = _stopInFlight;
    if (existing != null) return existing;
    if (!_running && !_sendBusy && _timer == null) {
      return Future<void>.value();
    }

    _running = false;
    _timer?.cancel();
    _timer = null;
    _tickPending = false;
    final generation = ++_generation;
    final operation = _stopAfterInFlight(generation);
    _stopInFlight = operation;
    return operation.whenComplete(() {
      if (identical(_stopInFlight, operation)) _stopInFlight = null;
    });
  }

  Future<void> _stopAfterInFlight(int generation) async {
    while (_sendBusy) {
      await _inFlight;
    }
    if (_running || generation != _generation || !_activeAttempted) return;
    await _sendOffline(generation);
  }

  Future<void> _requestActive(int generation) {
    if (!_running || generation != _generation) return _inFlight;
    if (_sendBusy) {
      _tickPending = true;
      return _inFlight;
    }
    return _sendActive(generation);
  }

  Future<void> _sendActive(int generation) {
    final completer = Completer<void>();
    _sendBusy = true;
    _inFlight = completer.future;
    () async {
      try {
        if (!_isCurrent(generation)) return;
        if (!await _consentReader()) return;
        if (!await _privacyReader()) return;
        if (!_isCurrent(generation)) return;
        if ((await _roleReader())?.toLowerCase() != 'rider') return;
        if (!_isCurrent(generation)) return;

        final position = await _locationReader();
        if (position == null || !_isCurrent(generation)) return;
        final age = DateTime.now().difference(position.timestamp);
        if (age > maxFixAge || age < -maxFixAge) return;
        final lat = position.latitude;
        final lng = position.longitude;
        if (!lat.isFinite || !lng.isFinite) return;

        _activeAttempted = true;
        await _sender(
          active: true,
          lat: _roundCoordinate(lat),
          lng: _roundCoordinate(lng),
        );
      } catch (error) {
        debugPrint(
            '[RiderPresence] active update skipped: ${error.runtimeType}');
      } finally {
        _finishSend(completer);
      }
    }();
    return completer.future;
  }

  Future<void> _sendOffline(int generation) {
    final completer = Completer<void>();
    _sendBusy = true;
    _inFlight = completer.future;
    () async {
      try {
        if (_running || generation != _generation) return;
        await _sender(active: false);
        _activeAttempted = false;
      } catch (error) {
        debugPrint(
            '[RiderPresence] offline update failed: ${error.runtimeType}');
      } finally {
        _finishSend(completer);
      }
    }();
    return completer.future;
  }

  void _finishSend(Completer<void> completer) {
    _sendBusy = false;
    if (!completer.isCompleted) completer.complete();
    if (!_tickPending || !_running) return;
    _tickPending = false;
    final generation = _generation;
    scheduleMicrotask(() {
      unawaited(_requestActive(generation));
    });
  }

  bool _isCurrent(int generation) => _running && generation == _generation;

  static double _roundCoordinate(double value) =>
      double.parse(value.toStringAsFixed(2));

  static Future<String?> _readRole() async {
    final me = await ApiService.getMe();
    return me?['role']?.toString();
  }

  static Future<bool> _readConsent() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(consentPreferenceKey) ?? false;
  }

  static Future<bool> _readPrivacy() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(privacyPreferenceKey) ?? true;
  }

  static Future<Position?> _readFreshLocation() async {
    if (!await Geolocator.isLocationServiceEnabled()) return null;
    final permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied ||
        permission == LocationPermission.deniedForever) {
      return null;
    }
    return Geolocator.getCurrentPosition(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.low,
        timeLimit: Duration(seconds: 5),
      ),
    ).timeout(const Duration(seconds: 6));
  }
}
