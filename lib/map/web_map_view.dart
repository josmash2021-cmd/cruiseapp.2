/// Web map foundation (etapa 1): Mapbox GL JS v3 embedded via HtmlElementView.
///
/// Import this file everywhere — on native builds the conditional import
/// swaps in a no-op stub so `dart:ui_web` / `dart:js_interop` are never
/// compiled for Android/iOS:
///
/// ```dart
/// import 'package:cruise_app/map/web_map_view.dart';
/// ```
library;

export 'web_map_controller_base.dart';
export 'web_map_view_stub.dart'
    if (dart.library.js_interop) 'web_map_view_web.dart';
