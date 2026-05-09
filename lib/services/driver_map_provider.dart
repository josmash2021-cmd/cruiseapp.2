import 'package:flutter/material.dart';
import 'package:mapbox_maps_flutter/mapbox_maps_flutter.dart' as mapbox;

/// ═══════════════════════════════════════════════════════════════════
///  DriverMapProvider — Shared map controller for driver flow
/// ═══════════════════════════════════════════════════════════════════
///
/// Provides access to the persistent MapboxMap controller created by
/// [DriverMapShellScreen]. Any widget in the driver flow can access
/// the controller via [DriverMapProvider.of(context)].
///
/// This eliminates the need for each driver screen to create its own
/// MapWidget and manage map lifecycle independently.

class DriverMapProvider extends InheritedWidget {
  const DriverMapProvider({
    super.key,
    required this.mapController,
    required this.pointAnnotMgr,
    required this.polylineAnnotMgr,
    required this.pinAnnotMgr,
    required super.child,
  });

  /// The persistent MapboxMap controller.
  final mapbox.MapboxMap? mapController;

  /// Point annotation manager for driver dot / car icon.
  final mapbox.PointAnnotationManager? pointAnnotMgr;

  /// Polyline annotation manager for route lines.
  final mapbox.PolylineAnnotationManager? polylineAnnotMgr;

  /// Point annotation manager for pickup/dropoff pins.
  final mapbox.PointAnnotationManager? pinAnnotMgr;

  static DriverMapProvider? maybeOf(BuildContext context) {
    return context.dependOnInheritedWidgetOfExactType<DriverMapProvider>();
  }

  static DriverMapProvider of(BuildContext context) {
    final provider = maybeOf(context);
    assert(provider != null, 'DriverMapProvider not found in context');
    return provider!;
  }

  @override
  bool updateShouldNotify(DriverMapProvider oldWidget) {
    return mapController != oldWidget.mapController ||
        pointAnnotMgr != oldWidget.pointAnnotMgr ||
        polylineAnnotMgr != oldWidget.polylineAnnotMgr ||
        pinAnnotMgr != oldWidget.pinAnnotMgr;
  }
}

/// Notifier for the current driver screen state within the shell.
enum DriverShellState {
  home,           // Offline home (not in shell — this is DriverHomeScreen)
  online,         // Online searching for trips
  tripAccept,     // Trip accepted, navigating to pickup
  tripAccepted,   // Alternative trip accepted state
  scheduledRides, // Scheduled rides list
  scheduledDetails, // Scheduled ride details
  rateRider,      // Rating screen after trip
}

class DriverShellController extends ChangeNotifier {
  DriverShellState _state = DriverShellState.online;
  DriverShellState get state => _state;

  void navigateTo(DriverShellState newState) {
    if (_state == newState) return;
    _state = newState;
    notifyListeners();
  }

  /// Go back to online state (used after trip completion/cancellation).
  void goOnline() => navigateTo(DriverShellState.online);
}
