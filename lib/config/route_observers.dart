import 'package:flutter/widgets.dart';

/// Route observer used by screens that own a native Mapbox surface.
///
/// Only one live `MapWidget` may exist at a time on iOS — a second native
/// surface is the crash the driver hits right after accepting a ride. The
/// pushes that hand a map from one screen to the next are already
/// coordinated by hand, but a screen underneath the stack has no way to
/// know something else took over the screen. `DriverHomeScreen` sits under
/// the online screen for the whole shift and kept its own map alive there;
/// this observer is how it finds out to let go.
///
/// Typed on [PageRoute] on purpose: bottom sheets and dialogs are
/// [PopupRoute]s, so they never reach subscribers. Opening a sheet over the
/// map must not tear the map down.
final RouteObserver<PageRoute<dynamic>> mapRouteObserver =
    RouteObserver<PageRoute<dynamic>>();
