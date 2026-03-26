import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../models/lat_lng.dart';

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

  /// Remaining steps from current position onwards.
  List<NavStep> get remainingSteps {
    final route = _route;
    if (route == null) return [];
    if (_currentStepIdx >= route.steps.length) return [];
    return route.steps.sublist(_currentStepIdx);
  }

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

  /// Find the closest point on the polyline to [point] using segment
  /// projection (not just vertex search). This correctly handles the case
  /// where the vehicle is in the middle of a long segment — a vertex-only
  /// search would overestimate the off-route distance and trigger false alerts.
  static _ClosestPointResult _findClosestPointOnPolyline(
    LatLng point,
    List<LatLng> polyline,
  ) {
    if (polyline.isEmpty) {
      return _ClosestPointResult(index: 0, distanceMeters: 0, point: point);
    }
    if (polyline.length == 1) {
      return _ClosestPointResult(
        index: 0,
        distanceMeters: _haversineMeters(point, polyline[0]),
        point: polyline[0],
      );
    }

    double minDist = double.infinity;
    int closestIdx = 0;
    LatLng closestPt = polyline[0];

    for (int i = 0; i < polyline.length - 1; i++) {
      final proj = _projectOnSegment(point, polyline[i], polyline[i + 1]);
      final d = _haversineMeters(point, proj);
      if (d < minDist) {
        minDist = d;
        closestIdx = i;
        closestPt = proj;
      }
    }
    return _ClosestPointResult(
      index: closestIdx,
      distanceMeters: minDist,
      point: closestPt,
    );
  }

  /// Project [p] onto segment [a]-[b] with cosine-latitude correction.
  static LatLng _projectOnSegment(LatLng p, LatLng a, LatLng b) {
    final cosLat = math.cos(_toRad((a.latitude + b.latitude) / 2.0));
    final dLat = b.latitude - a.latitude;
    final dLng = (b.longitude - a.longitude) * cosLat;
    if (dLat.abs() < 1e-10 && dLng.abs() < 1e-10) return a;
    final pLat = p.latitude - a.latitude;
    final pLng = (p.longitude - a.longitude) * cosLat;
    final t = (pLat * dLat + pLng * dLng) / (dLat * dLat + dLng * dLng);
    final clamped = t.clamp(0.0, 1.0);
    return LatLng(
      a.latitude + clamped * (b.latitude - a.latitude),
      a.longitude + clamped * (b.longitude - a.longitude),
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

  /// Build a NavRoute from an OSRM API response.
  static NavRoute? fromOsrmResponse(Map<String, dynamic> data) {
    final routes = data['routes'] as List?;
    if (routes == null || routes.isEmpty) return null;

    final route = routes[0] as Map<String, dynamic>;
    final legs = route['legs'] as List?;
    if (legs == null || legs.isEmpty) return null;

    final totalDist = (route['distance'] as num?)?.toDouble() ?? 0;
    final totalDur = (route['duration'] as num?)?.toInt() ?? 0;

    // Decode overview polyline
    final geometry = route['geometry']?.toString();
    final overviewPoly = (geometry != null && geometry.isNotEmpty)
        ? _decodePolyline(geometry)
        : <LatLng>[];

    // Parse steps from all legs
    final steps = <NavStep>[];
    for (final leg in legs) {
      final rawSteps = (leg as Map<String, dynamic>)['steps'] as List? ?? [];
      for (final s in rawSteps) {
        final m = s as Map<String, dynamic>;
        final maneuverData = m['maneuver'] as Map<String, dynamic>? ?? {};
        final name = (m['name'] as String?) ?? '';
        final distM = (m['distance'] as num?)?.toDouble() ?? 0;
        final durS = (m['duration'] as num?)?.toInt() ?? 0;

        // OSRM maneuver types → Google-compatible maneuver strings
        final type = (maneuverData['type'] as String?) ?? 'new name';
        final modifier = (maneuverData['modifier'] as String?) ?? '';
        final maneuver = _osrmManeuverToGoogle(type, modifier);

        // Build instruction text
        final instruction = _osrmInstruction(type, modifier, name);

        // Start/end location from maneuver
        final loc = maneuverData['location'] as List?;
        final startLat = loc != null && loc.length >= 2
            ? (loc[1] as num).toDouble() : 0.0;
        final startLng = loc != null && loc.length >= 2
            ? (loc[0] as num).toDouble() : 0.0;

        // Per-step polyline
        final stepGeom = m['geometry']?.toString();
        final stepPoly = (stepGeom != null && stepGeom.isNotEmpty)
            ? _decodePolyline(stepGeom)
            : <LatLng>[];

        final endLoc = stepPoly.isNotEmpty ? stepPoly.last : LatLng(startLat, startLng);

        steps.add(NavStep(
          instruction: instruction,
          maneuver: maneuver,
          distanceMeters: distM,
          durationSeconds: durS,
          streetName: name,
          startLocation: LatLng(startLat, startLng),
          endLocation: endLoc,
          polyline: stepPoly,
        ));
      }
    }

    if (overviewPoly.isEmpty && steps.isNotEmpty) {
      // Build overview from step polylines
      for (final step in steps) {
        overviewPoly.addAll(step.polyline);
      }
    }

    return NavRoute(
      overviewPolyline: overviewPoly,
      steps: steps,
      totalDistanceMeters: totalDist,
      totalDurationSeconds: totalDur,
      startAddress: '',
      endAddress: '',
    );
  }

  /// Build a NavRoute from a Mapbox Directions API response.
  static NavRoute? fromMapboxResponse(Map<String, dynamic> data) {
    final routes = data['routes'] as List?;
    if (routes == null || routes.isEmpty) return null;

    final route = routes[0] as Map<String, dynamic>;
    final legs = route['legs'] as List?;
    if (legs == null || legs.isEmpty) return null;

    final totalDist = (route['distance'] as num?)?.toDouble() ?? 0;
    final totalDur = (route['duration'] as num?)?.toInt() ?? 0;

    // Decode overview polyline (Mapbox uses GeoJSON)
    final overviewPoly = <LatLng>[];
    final geom = route['geometry'];
    if (geom is Map<String, dynamic>) {
      final coords = geom['coordinates'] as List?;
      if (coords != null) {
        for (final c in coords) {
          overviewPoly.add(LatLng(
            (c[1] as num).toDouble(),
            (c[0] as num).toDouble(),
          ));
        }
      }
    }

    // Parse steps from all legs
    final steps = <NavStep>[];
    for (final leg in legs) {
      final rawSteps = (leg as Map<String, dynamic>)['steps'] as List? ?? [];
      for (final s in rawSteps) {
        final m = s as Map<String, dynamic>;
        final maneuverData = m['maneuver'] as Map<String, dynamic>? ?? {};
        final name = (m['name'] as String?) ?? '';
        final distM = (m['distance'] as num?)?.toDouble() ?? 0;
        final durS = (m['duration'] as num?)?.toInt() ?? 0;

        // Mapbox maneuver instruction
        final instruction = (maneuverData['instruction'] as String?) ?? name;
        final type = (maneuverData['type'] as String?) ?? '';
        final modifier = (maneuverData['modifier'] as String?) ?? '';
        final maneuver = _mapboxManeuverToGoogle(type, modifier);

        // Location
        final loc = maneuverData['location'] as List?;
        final startLat = loc != null && loc.length >= 2
            ? (loc[1] as num).toDouble() : 0.0;
        final startLng = loc != null && loc.length >= 2
            ? (loc[0] as num).toDouble() : 0.0;

        // Per-step polyline (Mapbox GeoJSON)
        final stepPoly = <LatLng>[];
        final stepGeom = m['geometry'];
        if (stepGeom is Map<String, dynamic>) {
          final coords = stepGeom['coordinates'] as List?;
          if (coords != null) {
            for (final c in coords) {
              stepPoly.add(LatLng(
                (c[1] as num).toDouble(),
                (c[0] as num).toDouble(),
              ));
            }
          }
        }

        final endLoc = stepPoly.isNotEmpty ? stepPoly.last : LatLng(startLat, startLng);

        steps.add(NavStep(
          instruction: instruction,
          maneuver: maneuver,
          distanceMeters: distM,
          durationSeconds: durS,
          streetName: name,
          startLocation: LatLng(startLat, startLng),
          endLocation: endLoc,
          polyline: stepPoly,
        ));
      }
    }

    return NavRoute(
      overviewPolyline: overviewPoly,
      steps: steps,
      totalDistanceMeters: totalDist,
      totalDurationSeconds: totalDur,
      startAddress: '',
      endAddress: '',
    );
  }

  /// Convert OSRM maneuver type+modifier to Google-compatible maneuver string.
  static String _osrmManeuverToGoogle(String type, String modifier) {
    switch (type) {
      case 'turn':
        if (modifier.contains('left')) return modifier.contains('sharp') ? 'turn-sharp-left' : modifier.contains('slight') ? 'turn-slight-left' : 'turn-left';
        if (modifier.contains('right')) return modifier.contains('sharp') ? 'turn-sharp-right' : modifier.contains('slight') ? 'turn-slight-right' : 'turn-right';
        if (modifier == 'straight') return 'straight';
        return 'straight';
      case 'merge':
        return 'merge';
      case 'on ramp':
      case 'off ramp':
        return modifier.contains('left') ? 'ramp-left' : 'ramp-right';
      case 'fork':
        return modifier.contains('left') ? 'fork-left' : 'fork-right';
      case 'roundabout':
      case 'rotary':
        return 'roundabout-left';
      case 'continue':
        if (modifier.contains('left')) return 'turn-slight-left';
        if (modifier.contains('right')) return 'turn-slight-right';
        return 'straight';
      case 'depart':
      case 'arrive':
      case 'new name':
        return 'straight';
      case 'end of road':
        return modifier.contains('left') ? 'turn-left' : 'turn-right';
      default:
        return 'straight';
    }
  }

  /// Convert Mapbox maneuver type+modifier to Google-compatible maneuver string.
  static String _mapboxManeuverToGoogle(String type, String modifier) {
    // Mapbox uses same conventions as OSRM
    return _osrmManeuverToGoogle(type, modifier);
  }

  /// Build human-readable instruction from OSRM maneuver data.
  static String _osrmInstruction(String type, String modifier, String name) {
    final street = name.isNotEmpty ? ' onto $name' : '';
    switch (type) {
      case 'turn':
        if (modifier.contains('left')) return 'Turn ${modifier.replaceAll(' ', '-')}$street';
        if (modifier.contains('right')) return 'Turn ${modifier.replaceAll(' ', '-')}$street';
        return 'Continue$street';
      case 'merge':
        return 'Merge$street';
      case 'on ramp':
        return 'Take the ramp$street';
      case 'off ramp':
        return 'Take the exit$street';
      case 'fork':
        return 'Keep ${modifier.contains('left') ? 'left' : 'right'}$street';
      case 'roundabout':
      case 'rotary':
        return 'Enter roundabout$street';
      case 'depart':
        return 'Head$street';
      case 'arrive':
        return 'Arrive at destination';
      case 'new name':
      case 'continue':
        return 'Continue$street';
      case 'end of road':
        return 'Turn ${modifier.contains('left') ? 'left' : 'right'}$street';
      default:
        return 'Continue$street';
    }
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
