import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

/// A single turn-by-turn navigation step parsed from Google Directions API.
class NavStep {
  final String instruction; // HTML-stripped instruction text
  final String
  maneuver; // e.g. 'turn-left', 'turn-right', 'straight', 'merge', etc.
  final double distanceMeters; // distance for this step in meters
  final int durationSeconds; // duration for this step in seconds
  final String streetName; // name of the street for this step
  final LatLng startLocation;
  final LatLng endLocation;
  final List<LatLng> polyline; // detailed polyline for this step

  const NavStep({
    required this.instruction,
    required this.maneuver,
    required this.distanceMeters,
    required this.durationSeconds,
    required this.streetName,
    required this.startLocation,
    required this.endLocation,
    required this.polyline,
  });

  /// Distance as a human-readable string (ft under 0.1 mi, else mi).
  String get distanceText {
    final mi = distanceMeters / 1609.34;
    if (mi < 0.1) {
      return '${(distanceMeters * 3.28084).round()} ft';
    }
    return '${mi.toStringAsFixed(1)} mi';
  }
}

/// Result from DirectionsService enhanced with step-by-step navigation info.
class NavRoute {
  final List<LatLng> overviewPolyline;
  final List<NavStep> steps;
  final double totalDistanceMeters;
  final int totalDurationSeconds;
  final String startAddress;
  final String endAddress;

  const NavRoute({
    required this.overviewPolyline,
    required this.steps,
    required this.totalDistanceMeters,
    required this.totalDurationSeconds,
    required this.startAddress,
    required this.endAddress,
  });

  double get totalDistanceMiles => totalDistanceMeters / 1609.34;
  int get totalDurationMinutes => (totalDurationSeconds / 60).ceil();
}

/// Live navigation state tracked as the driver moves along the route.
class NavigationState {
  final int currentStepIndex;
  final NavStep? currentStep;
  final NavStep? nextStep;
  final double distanceToNextTurnMeters;
  final double distanceRemainingMeters;
  final int etaRemainingSeconds;
  final double progress; // 0.0 to 1.0
  final bool isOffRoute;
  final String currentInstruction;
  final String currentManeuver;

  const NavigationState({
    required this.currentStepIndex,
    this.currentStep,
    this.nextStep,
    required this.distanceToNextTurnMeters,
    required this.distanceRemainingMeters,
    required this.etaRemainingSeconds,
    required this.progress,
    required this.isOffRoute,
    required this.currentInstruction,
    required this.currentManeuver,
  });

  String get distanceToTurnText {
    final mi = distanceToNextTurnMeters / 1609.34;
    if (mi < 0.1) {
      return '${(distanceToNextTurnMeters * 3.28084).round()} ft';
    }
    return '${mi.toStringAsFixed(1)} mi';
  }

  int get etaMinutes => (etaRemainingSeconds / 60).ceil().clamp(0, 999);
  double get distanceRemainingMiles => distanceRemainingMeters / 1609.34;
}

/// Service that manages real-time navigation state as the driver drives along
/// a route. Call [startNavigation] with a [NavRoute], then [updatePosition]
/// on each GPS tick.
class NavigationService {
  NavRoute? _route;
  int _currentStepIdx = 0;
  double _totalRouteMeters = 0;
  List<double> _stepCumulativeDistances = [];

  /// Off-route threshold in meters. If driver is farther than this from the
  /// nearest point on the route, we consider them off-route.
  static const double offRouteThresholdMeters = 50.0;

  /// How close to the end of a step (in meters) before advancing to the next.
  static const double stepAdvanceThresholdMeters = 30.0;

  /// Start navigation with a route.
  void startNavigation(NavRoute route) {
    _route = route;
    _currentStepIdx = 0;
    _totalRouteMeters = route.totalDistanceMeters;

    // Precompute cumulative distances at each step start
    _stepCumulativeDistances = [0.0];
    double cum = 0;
    for (final step in route.steps) {
      cum += step.distanceMeters;
      _stepCumulativeDistances.add(cum);
    }
  }

  /// Stop navigation.
  void stopNavigation() {
    _route = null;
    _currentStepIdx = 0;
  }

  bool get isNavigating => _route != null;

  /// Update driver position and get the current navigation state.
  NavigationState? updatePosition(LatLng driverPos) {
    final route = _route;
    if (route == null || route.steps.isEmpty) return null;

    // Find closest point on the overall polyline
    final closestResult = _findClosestPointOnPolyline(
      driverPos,
      route.overviewPolyline,
    );
    final isOffRoute = closestResult.distanceMeters > offRouteThresholdMeters;

    // Find which step we're on based on proximity to step end locations
    _advanceStep(driverPos, route);

    final currentStep = _currentStepIdx < route.steps.length
        ? route.steps[_currentStepIdx]
        : route.steps.last;
    final nextStep = _currentStepIdx + 1 < route.steps.length
        ? route.steps[_currentStepIdx + 1]
        : null;

    // Distance to the end of the current step (next turn)
    final distToStepEnd = _haversineMeters(driverPos, currentStep.endLocation);

    // Remaining distance = distance to end of current step + all subsequent steps
    double remainDist = distToStepEnd;
    for (int i = _currentStepIdx + 1; i < route.steps.length; i++) {
      remainDist += route.steps[i].distanceMeters;
    }

    // Remaining ETA proportional
    final remainEta = _totalRouteMeters > 0
        ? (route.totalDurationSeconds * remainDist / _totalRouteMeters).round()
        : 0;

    // Progress
    final covered = _totalRouteMeters - remainDist;
    final progress = _totalRouteMeters > 0
        ? (covered / _totalRouteMeters).clamp(0.0, 1.0)
        : 0.0;

    // Instruction: use current step, but if very close to next turn, show next
    String instruction = currentStep.instruction;
    String maneuver = currentStep.maneuver;
    if (distToStepEnd < 50 && nextStep != null) {
      // When very close, preview next maneuver
      instruction = nextStep.instruction;
      maneuver = nextStep.maneuver;
    }

    return NavigationState(
      currentStepIndex: _currentStepIdx,
      currentStep: currentStep,
      nextStep: nextStep,
      distanceToNextTurnMeters: distToStepEnd,
      distanceRemainingMeters: remainDist,
      etaRemainingSeconds: remainEta,
      progress: progress,
      isOffRoute: isOffRoute,
      currentInstruction: instruction,
      currentManeuver: maneuver,
    );
  }

  void _advanceStep(LatLng driverPos, NavRoute route) {
    while (_currentStepIdx < route.steps.length - 1) {
      final step = route.steps[_currentStepIdx];
      final distToEnd = _haversineMeters(driverPos, step.endLocation);
      if (distToEnd < stepAdvanceThresholdMeters) {
        _currentStepIdx++;
      } else {
        break;
      }
    }
  }

  // ─── Utility ───

  static double _haversineMeters(LatLng a, LatLng b) {
    const R = 6371000.0; // Earth radius in meters
    final dLat = _toRad(b.latitude - a.latitude);
    final dLng = _toRad(b.longitude - a.longitude);
    final x =
        math.sin(dLat / 2) * math.sin(dLat / 2) +
        math.cos(_toRad(a.latitude)) *
            math.cos(_toRad(b.latitude)) *
            math.sin(dLng / 2) *
            math.sin(dLng / 2);
    return R * 2 * math.atan2(math.sqrt(x), math.sqrt(1 - x));
  }

  static double _toRad(double deg) => deg * math.pi / 180;

  static _ClosestPointResult _findClosestPointOnPolyline(
    LatLng point,
    List<LatLng> polyline,
  ) {
    double minDist = double.infinity;
    int closestIdx = 0;
    for (int i = 0; i < polyline.length; i++) {
      final d = _haversineMeters(point, polyline[i]);
      if (d < minDist) {
        minDist = d;
        closestIdx = i;
      }
    }
    return _ClosestPointResult(
      index: closestIdx,
      distanceMeters: minDist,
      point: polyline[closestIdx],
    );
  }

  /// Parse steps from a Google Directions API leg JSON.
  static List<NavStep> parseSteps(Map<String, dynamic> leg) {
    final steps = <NavStep>[];
    final rawSteps = leg['steps'] as List? ?? [];
    for (final s in rawSteps) {
      final html = (s['html_instructions'] as String?) ?? '';
      final instruction = html.replaceAll(RegExp(r'<[^>]*>'), '');
      final maneuver = (s['maneuver'] as String?) ?? 'straight';
      final distM = (s['distance']?['value'] as num?)?.toDouble() ?? 0;
      final durS = (s['duration']?['value'] as num?)?.toInt() ?? 0;

      // Street name: try to extract from instruction or use empty
      String streetName = '';
      // Try "onto X" or "on X" pattern
      final ontoMatch = RegExp(
        r'(?:onto|on)\s+(.+?)(?:\s*$)',
        caseSensitive: false,
      ).firstMatch(instruction);
      if (ontoMatch != null) {
        streetName = ontoMatch.group(1) ?? '';
      }

      final startLat = (s['start_location']?['lat'] as num?)?.toDouble() ?? 0;
      final startLng = (s['start_location']?['lng'] as num?)?.toDouble() ?? 0;
      final endLat = (s['end_location']?['lat'] as num?)?.toDouble() ?? 0;
      final endLng = (s['end_location']?['lng'] as num?)?.toDouble() ?? 0;

      // Decode step polyline
      List<LatLng> stepPoly = [];
      final polyEnc = s['polyline']?['points'] as String?;
      if (polyEnc != null && polyEnc.isNotEmpty) {
        stepPoly = _decodePolyline(polyEnc);
      }

      steps.add(
        NavStep(
          instruction: instruction,
          maneuver: maneuver,
          distanceMeters: distM,
          durationSeconds: durS,
          streetName: streetName,
          startLocation: LatLng(startLat, startLng),
          endLocation: LatLng(endLat, endLng),
          polyline: stepPoly,
        ),
      );
    }
    return steps;
  }

  /// Build a NavRoute from Google Directions API response.
  static NavRoute? fromDirectionsResponse(Map<String, dynamic> data) {
    if (data['status'] != 'OK') return null;
    final routes = data['routes'] as List?;
    if (routes == null || routes.isEmpty) return null;

    final route = routes[0];
    final leg = route['legs'][0];
    final overviewPoly = _decodePolyline(
      route['overview_polyline']['points'] as String,
    );
    final steps = parseSteps(leg);
    final totalDist = (leg['distance']?['value'] as num?)?.toDouble() ?? 0;
    final totalDur = (leg['duration']?['value'] as num?)?.toInt() ?? 0;
    final startAddr = (leg['start_address'] as String?) ?? '';
    final endAddr = (leg['end_address'] as String?) ?? '';

    return NavRoute(
      overviewPolyline: overviewPoly,
      steps: steps,
      totalDistanceMeters: totalDist,
      totalDurationSeconds: totalDur,
      startAddress: startAddr,
      endAddress: endAddr,
    );
  }

  static List<LatLng> _decodePolyline(String enc) {
    final pts = <LatLng>[];
    int i = 0, lat = 0, lng = 0;
    while (i < enc.length) {
      int s = 0, r = 0, b;
      do {
        b = enc.codeUnitAt(i++) - 63;
        r |= (b & 0x1F) << s;
        s += 5;
      } while (b >= 0x20);
      lat += (r & 1) != 0 ? ~(r >> 1) : (r >> 1);
      s = 0;
      r = 0;
      do {
        b = enc.codeUnitAt(i++) - 63;
        r |= (b & 0x1F) << s;
        s += 5;
      } while (b >= 0x20);
      lng += (r & 1) != 0 ? ~(r >> 1) : (r >> 1);
      pts.add(LatLng(lat / 1E5, lng / 1E5));
    }
    return pts;
  }

  /// Get the appropriate maneuver icon data based on maneuver string.
  static ManeuverIcon getManeuverIcon(String maneuver) {
    switch (maneuver) {
      case 'turn-left':
        return ManeuverIcon.turnLeft;
      case 'turn-right':
        return ManeuverIcon.turnRight;
      case 'turn-slight-left':
        return ManeuverIcon.slightLeft;
      case 'turn-slight-right':
        return ManeuverIcon.slightRight;
      case 'turn-sharp-left':
        return ManeuverIcon.sharpLeft;
      case 'turn-sharp-right':
        return ManeuverIcon.sharpRight;
      case 'uturn-left':
      case 'uturn-right':
        return ManeuverIcon.uTurn;
      case 'merge':
        return ManeuverIcon.merge;
      case 'ramp-left':
      case 'fork-left':
        return ManeuverIcon.rampLeft;
      case 'ramp-right':
      case 'fork-right':
        return ManeuverIcon.rampRight;
      case 'roundabout-left':
      case 'roundabout-right':
        return ManeuverIcon.roundabout;
      case 'keep-left':
        return ManeuverIcon.keepLeft;
      case 'keep-right':
        return ManeuverIcon.keepRight;
      case 'ferry':
      case 'ferry-train':
        return ManeuverIcon.ferry;
      case 'straight':
      default:
        return ManeuverIcon.straight;
    }
  }
}

class _ClosestPointResult {
  final int index;
  final double distanceMeters;
  final LatLng point;
  const _ClosestPointResult({
    required this.index,
    required this.distanceMeters,
    required this.point,
  });
}

/// Maneuver icon data with Material icon and label.
class ManeuverIcon {
  final IconData icon;
  final String label;
  const ManeuverIcon(this.icon, this.label);

  static const straight = ManeuverIcon(Icons.straight, 'Continue straight');
  static const turnLeft = ManeuverIcon(Icons.turn_left, 'Turn left');
  static const turnRight = ManeuverIcon(Icons.turn_right, 'Turn right');
  static const slightLeft = ManeuverIcon(Icons.turn_slight_left, 'Slight left');
  static const slightRight = ManeuverIcon(Icons.turn_slight_right, 'Slight right');
  static const sharpLeft = ManeuverIcon(Icons.turn_sharp_left, 'Sharp left');
  static const sharpRight = ManeuverIcon(Icons.turn_sharp_right, 'Sharp right');
  static const uTurn = ManeuverIcon(Icons.u_turn_left, 'U-turn');
  static const merge = ManeuverIcon(Icons.merge, 'Merge');
  static const rampLeft = ManeuverIcon(Icons.ramp_left, 'Take ramp left');
  static const rampRight = ManeuverIcon(Icons.ramp_right, 'Take ramp right');
  static const roundabout = ManeuverIcon(Icons.roundabout_left, 'Roundabout');
  static const keepLeft = ManeuverIcon(Icons.turn_slight_left, 'Keep left');
  static const keepRight = ManeuverIcon(Icons.turn_slight_right, 'Keep right');
  static const ferry = ManeuverIcon(Icons.directions_boat, 'Ferry');
}
