import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../config/page_transitions.dart';
import '../../models/lat_lng.dart';
import 'driver_nav_view.dart';

/// The app's own navigation to a heat zone (owner 2026-11-05): the driver
/// tapped the gold flame on the online map, then "Navegar a la zona". The
/// same turn-by-turn the trip uses ([DriverNavView.zone]) — route, turn box,
/// chase camera, reroute, arrival — with the zone's small panel instead of
/// the trip's. Terminar (or the system back) pops it.
///
/// The one native Mapbox surface (two live MapWidgets close the app on
/// iOS): [DriverNavView] claims it from `MapSurfaceCoordinator` in its
/// initState — the coordinator runs the online screen's revoke and waits
/// until its map is really gone before this one mounts — and releases it in
/// dispose. On the way back the online screen claims it again through the
/// coordinator: its `didPopNext` (it subscribes to `mapRouteObserver`)
/// remounts whenever its map is down, and the push site's `whenComplete`
/// does the same. Nothing here touches the online screen.
class ZoneNavScreen extends StatefulWidget {
  const ZoneNavScreen({
    super.key,
    required this.destination,
    required this.zoneName,
    required this.initialDriverPos,
  });

  /// Already on a drivable street (the online screen snaps it).
  final LatLng destination;

  /// "Hoover".
  final String zoneName;
  final LatLng initialDriverPos;

  /// The route to push it with: the trip screen's page route — no iOS
  /// edge swipe-back (a MaterialPageRoute's would drag the whole navigation
  /// away when the driver pans the map from the left edge).
  static Route<void> route({
    required LatLng destination,
    required String zoneName,
    required LatLng initialDriverPos,
  }) =>
      slideFromRightRoute<void>(ZoneNavScreen(
        destination: destination,
        zoneName: zoneName,
        initialDriverPos: initialDriverPos,
      ));

  @override
  State<ZoneNavScreen> createState() => _ZoneNavScreenState();
}

class _ZoneNavScreenState extends State<ZoneNavScreen> {
  bool _leaving = false;

  /// Terminar: pops THIS screen, once. Only while it is the top route — a
  /// second tap during the pop would otherwise pop the driver home under it.
  void _end() {
    if (_leaving || !mounted) return;
    final route = ModalRoute.of(context);
    if (route == null || !route.isCurrent) return;
    final nav = Navigator.maybeOf(context);
    if (nav == null) return;
    _leaving = true;
    nav.pop();
  }

  @override
  Widget build(BuildContext context) {
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.light,
      child: Scaffold(
        backgroundColor: Colors.black,
        resizeToAvoidBottomInset: false,
        body: DriverNavView.zone(
          destination: widget.destination,
          zoneName: widget.zoneName,
          initialDriverPos: widget.initialDriverPos,
          onExit: _end,
        ),
      ),
    );
  }
}
