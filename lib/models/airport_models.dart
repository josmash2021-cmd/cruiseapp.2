/// Airport ride direction — determines whether airport is pickup or dropoff.
enum AirportDirection {
  /// User is flying out — airport is the DROPOFF destination.
  toAirport,

  /// User just landed — airport is the PICKUP origin.
  fromAirport,
}

/// A single terminal within an airport, with associated airlines and arrival doors.
class AirportTerminal {
  final String name;

  /// Airlines operating from this terminal (used for the toAirport path:
  /// rider picks airline → terminal is auto-resolved).
  final List<String> airlines;

  /// Specific arrival doors / zones (used for the fromAirport path:
  /// rider picks which door they will be at for pickup).
  final List<String> arrivalDoors;

  const AirportTerminal({
    required this.name,
    required this.airlines,
    required this.arrivalDoors,
  });
}

/// Airport data model with full terminal richness.
class AirportInfo {
  final String code;
  final String name;
  final List<AirportTerminal> terminals;
  final double? flatRateSurcharge;

  const AirportInfo({
    required this.code,
    required this.name,
    required this.terminals,
    this.flatRateSurcharge,
  });

  /// All airlines across all terminals, deduplicated and sorted.
  List<String> get allAirlines {
    final seen = <String>{};
    final result = <String>[];
    for (final t in terminals) {
      for (final a in t.airlines) {
        if (seen.add(a)) result.add(a);
      }
    }
    result.sort();
    return result;
  }

  /// Resolve which terminal an airline operates from.
  /// Returns the first terminal that lists [airline].
  /// If an airline is in multiple terminals, returns a list of all matches.
  List<AirportTerminal> terminalsForAirline(String airline) {
    return terminals.where((t) => t.airlines.contains(airline)).toList();
  }
}

/// The complete result of an airport ride selection.
class AirportSelection {
  final AirportInfo airport;
  final AirportDirection direction;
  final AirportTerminal? terminal;

  /// Set when direction == toAirport; the airline the user flies with.
  final String? airline;

  /// Set when direction == fromAirport; the specific arrival door for pickup.
  final String? arrivalDoor;

  /// Optional for toAirport, required for fromAirport.
  final String? flightNumber;

  const AirportSelection({
    required this.airport,
    required this.direction,
    this.terminal,
    this.airline,
    this.arrivalDoor,
    this.flightNumber,
  });
}
