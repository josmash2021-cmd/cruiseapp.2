import 'package:flutter/foundation.dart';
import 'package:mapbox_maps_flutter/mapbox_maps_flutter.dart' as mapbox;

/// The ONE live driver map, lent by the home screen to the online overlay
/// (user spec 2026-08-25 — Lyft mechanics): going online must never
/// remount the map. No fog, no black frame, no blink — the same surface
/// stays up, does a gentle zoom-out, and only the sheet/buttons change.
///
/// Home owns the `MapWidget` and registers its controller here on every
/// `onMapCreated`. The online screen — pushed as a TRANSPARENT route on
/// top — attaches to this handle instead of mounting a second surface
/// (two live Mapbox surfaces are the iOS crash). While attached:
///
/// - home suppresses its own follow-camera writes and its marker (the
///   overlay drives both), so there is never a second camera writer or a
///   second arrow on the same map;
/// - the overlay's camera/marker code runs on [map] exactly as it did on
///   its own surface;
/// - trip screens still claim the surface through MapSurfaceCoordinator
///   as always — that revoke lands on HOME, which tears the widget down
///   and unregisters here; the overlay re-attaches when [requestRemount]
///   brings home's map back.
///
/// Web never registers (no native map), so the online screen takes its
/// legacy self-mount path there untouched.
class DriverMapHost {
  DriverMapHost._();

  static final DriverMapHost instance = DriverMapHost._();

  /// Home's live controller; null while home's surface is down.
  mapbox.MapboxMap? map;

  /// Camera-state mirror fed by home's onCameraChangeListener — the
  /// overlay's projection and marker repaint read this instead of opening
  /// a second channel subscription on the same map.
  final ValueNotifier<mapbox.CameraState?> camState =
      ValueNotifier<mapbox.CameraState?>(null);

  /// Bumped on every register/unregister so the overlay can detach and
  /// re-attach without ever poking a dead controller.
  final ValueNotifier<int> generation = ValueNotifier<int>(0);

  /// The overlay sets this while attached; home forwards its onScroll
  /// events so the overlay's follow-pause keeps working on home's widget.
  void Function()? onUserScroll;

  /// The overlay sets this while attached; home calls it after its own
  /// style reload + theme re-apply so the overlay can re-write its
  /// annotation layer properties (applyNavyGold resets them).
  void Function()? onStyleReloaded;

  /// True while the online overlay is attached. Home listens and
  /// suppresses its follow-camera + marker for exactly that span.
  final ValueNotifier<bool> overlayAttached = ValueNotifier<bool>(false);

  /// Installed by home: re-mounts home's surface after the screen that
  /// borrowed it (trip accept) is gone. The overlay calls this where the
  /// legacy path remounted its own MapWidget.
  Future<void> Function()? requestRemount;

  void register(mapbox.MapboxMap ctrl) {
    map = ctrl;
    generation.value++;
  }

  void unregister(mapbox.MapboxMap ctrl) {
    if (map != ctrl) return;
    map = null;
    onUserScroll = null;
    onStyleReloaded = null;
    camState.value = null;
    generation.value++;
  }
}
