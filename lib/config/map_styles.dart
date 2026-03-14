import 'dart:io' show Platform;
import 'package:flutter/foundation.dart' show kIsWeb;

/// Google Maps JSON styling for light and dark themes.
/// Usage: `mapCtrl.setMapStyle(isDark ? MapStyles.dark : MapStyles.light);`
class MapStyles {
  MapStyles._();
  
  /// Detecta si es iOS
  static bool get isIOS => !kIsWeb && Platform.isIOS;

  // ═════════════════════════════════════════════════════
  //  DARK — Google Maps dark with all POIs, labels & icons
  // ═════════════════════════════════════════════════════
  static const dark = '''
[
  {"elementType":"geometry","stylers":[{"color":"#242f3e"}]},
  {"elementType":"labels","stylers":[{"visibility":"off"}]},
  {"featureType":"landscape","elementType":"geometry.fill","stylers":[{"color":"#263238"}]},
  {"featureType":"poi","elementType":"labels.text.fill","stylers":[{"color":"#d59563"}]},
  {"featureType":"poi.park","elementType":"geometry","stylers":[{"color":"#263c3f"}]},
  {"featureType":"poi.park","elementType":"labels.text.fill","stylers":[{"color":"#6b9a76"}]},
  {"featureType":"road","elementType":"geometry","stylers":[{"color":"#38414e"}]},
  {"featureType":"road","elementType":"geometry.stroke","stylers":[{"color":"#212a37"}]},
  {"featureType":"road","elementType":"labels.text.fill","stylers":[{"color":"#9ca5b3"}]},
  {"featureType":"road.highway","elementType":"geometry","stylers":[{"color":"#746855"}]},
  {"featureType":"road.highway","elementType":"geometry.stroke","stylers":[{"color":"#1f2835"}]},
  {"featureType":"road.highway","elementType":"labels.text.fill","stylers":[{"color":"#f3d19c"}]},
  {"featureType":"transit","elementType":"geometry","stylers":[{"color":"#2f3948"}]},
  {"featureType":"transit.station","elementType":"labels.text.fill","stylers":[{"color":"#d59563"}]},
  {"featureType":"water","elementType":"geometry","stylers":[{"color":"#17263c"}]},
  {"featureType":"water","elementType":"labels.text.fill","stylers":[{"color":"#515c6d"}]},
  {"featureType":"water","elementType":"labels.text.stroke","stylers":[{"color":"#17263c"}]}
]
''';

  // ═════════════════════════════════════════════════════
  //  DARK iOS — Carreteras doradas para iOS
  // ═════════════════════════════════════════════════════
  static const darkIOS = '''
[
  {"elementType":"geometry","stylers":[{"color":"#242f3e"}]},
  {"elementType":"labels","stylers":[{"visibility":"off"}]},
  {"featureType":"landscape","elementType":"geometry.fill","stylers":[{"color":"#263238"}]},
  {"featureType":"poi","elementType":"labels.text.fill","stylers":[{"color":"#d59563"}]},
  {"featureType":"poi.park","elementType":"geometry","stylers":[{"color":"#263c3f"}]},
  {"featureType":"poi.park","elementType":"labels.text.fill","stylers":[{"color":"#6b9a76"}]},
  {"featureType":"road","elementType":"geometry","stylers":[{"color":"#E8C547"}]},
  {"featureType":"road","elementType":"geometry.stroke","stylers":[{"color":"#B8972E"}]},
  {"featureType":"road","elementType":"labels.text.fill","stylers":[{"color":"#9ca5b3"}]},
  {"featureType":"road.highway","elementType":"geometry","stylers":[{"color":"#E8C547"}]},
  {"featureType":"road.highway","elementType":"geometry.stroke","stylers":[{"color":"#B8972E"}]},
  {"featureType":"road.highway","elementType":"labels.text.fill","stylers":[{"color":"#f3d19c"}]},
  {"featureType":"road.arterial","elementType":"geometry","stylers":[{"color":"#E8C547"}]},
  {"featureType":"road.arterial","elementType":"geometry.stroke","stylers":[{"color":"#B8972E"}]},
  {"featureType":"road.local","elementType":"geometry","stylers":[{"color":"#D4B03A"}]},
  {"featureType":"road.local","elementType":"geometry.stroke","stylers":[{"color":"#A88B2A"}]},
  {"featureType":"transit","elementType":"geometry","stylers":[{"color":"#2f3948"}]},
  {"featureType":"transit.station","elementType":"labels.text.fill","stylers":[{"color":"#d59563"}]},
  {"featureType":"water","elementType":"geometry","stylers":[{"color":"#17263c"}]},
  {"featureType":"water","elementType":"labels.text.fill","stylers":[{"color":"#515c6d"}]},
  {"featureType":"water","elementType":"labels.text.stroke","stylers":[{"color":"#17263c"}]}
]
''';

  // ═════════════════════════════════════════════════════
  //  LIGHT — Apple Maps-inspired clean white
  // ═════════════════════════════════════════════════════
  static const light = '''
[
  {"elementType":"geometry","stylers":[{"color":"#F0F0F5"}]},
  {"elementType":"labels","stylers":[{"visibility":"off"}]},
  {"featureType":"administrative","elementType":"geometry","stylers":[{"color":"#D1D1D6"},{"visibility":"simplified"}]},
  {"featureType":"administrative.country","elementType":"geometry.stroke","stylers":[{"color":"#C7C7CC"}]},
  {"featureType":"landscape","elementType":"geometry.fill","stylers":[{"color":"#EBEBF0"}]},
  {"featureType":"landscape.man_made","elementType":"geometry.fill","stylers":[{"color":"#E8E8ED"}]},
  {"featureType":"poi","elementType":"geometry","stylers":[{"color":"#E5E5EA"}]},
  {"featureType":"poi","elementType":"labels","stylers":[{"visibility":"off"}]},
  {"featureType":"poi.park","elementType":"geometry.fill","stylers":[{"color":"#C8E6C5"}]},
  {"featureType":"road","elementType":"geometry.fill","stylers":[{"color":"#FFFFFF"}]},
  {"featureType":"road","elementType":"geometry.stroke","stylers":[{"color":"#D6D6DB"},{"weight":0.5}]},
  {"featureType":"road","elementType":"labels.text.fill","stylers":[{"color":"#8E8E93"}]},
  {"featureType":"road.arterial","elementType":"geometry.fill","stylers":[{"color":"#FFFFFF"}]},
  {"featureType":"road.highway","elementType":"geometry.fill","stylers":[{"color":"#FFF9E8"}]},
  {"featureType":"road.highway","elementType":"geometry.stroke","stylers":[{"color":"#E8DFC0"},{"weight":0.5}]},
  {"featureType":"road.highway.controlled_access","elementType":"geometry.fill","stylers":[{"color":"#FFF3D1"}]},
  {"featureType":"road.local","elementType":"geometry.fill","stylers":[{"color":"#FFFFFF"}]},
  {"featureType":"transit","elementType":"geometry","stylers":[{"color":"#E5E5EA"}]},
  {"featureType":"transit.station","elementType":"labels","stylers":[{"visibility":"off"}]},
  {"featureType":"water","elementType":"geometry.fill","stylers":[{"color":"#A8D4E6"}]},
  {"featureType":"water","elementType":"labels.text.fill","stylers":[{"color":"#7FBBD4"}]}
]
''';

  // ═════════════════════════════════════════════════════
  //  LIGHT iOS — Carreteras doradas para iOS
  // ═════════════════════════════════════════════════════
  static const lightIOS = '''
[
  {"elementType":"geometry","stylers":[{"color":"#F0F0F5"}]},
  {"elementType":"labels","stylers":[{"visibility":"off"}]},
  {"featureType":"administrative","elementType":"geometry","stylers":[{"color":"#D1D1D6"},{"visibility":"simplified"}]},
  {"featureType":"administrative.country","elementType":"geometry.stroke","stylers":[{"color":"#C7C7CC"}]},
  {"featureType":"landscape","elementType":"geometry.fill","stylers":[{"color":"#EBEBF0"}]},
  {"featureType":"landscape.man_made","elementType":"geometry.fill","stylers":[{"color":"#E8E8ED"}]},
  {"featureType":"poi","elementType":"geometry","stylers":[{"color":"#E5E5EA"}]},
  {"featureType":"poi","elementType":"labels","stylers":[{"visibility":"off"}]},
  {"featureType":"poi.park","elementType":"geometry.fill","stylers":[{"color":"#C8E6C5"}]},
  {"featureType":"road","elementType":"geometry.fill","stylers":[{"color":"#E8C547"}]},
  {"featureType":"road","elementType":"geometry.stroke","stylers":[{"color":"#D4B03A"},{"weight":1}]},
  {"featureType":"road","elementType":"labels.text.fill","stylers":[{"color":"#8E8E93"}]},
  {"featureType":"road.arterial","elementType":"geometry.fill","stylers":[{"color":"#E8C547"}]},
  {"featureType":"road.arterial","elementType":"geometry.stroke","stylers":[{"color":"#D4B03A"},{"weight":1}]},
  {"featureType":"road.highway","elementType":"geometry.fill","stylers":[{"color":"#E8C547"}]},
  {"featureType":"road.highway","elementType":"geometry.stroke","stylers":[{"color":"#B8972E"},{"weight":1.5}]},
  {"featureType":"road.highway.controlled_access","elementType":"geometry.fill","stylers":[{"color":"#F5D990"}]},
  {"featureType":"road.highway.controlled_access","elementType":"geometry.stroke","stylers":[{"color":"#D4B03A"},{"weight":1.5}]},
  {"featureType":"road.local","elementType":"geometry.fill","stylers":[{"color":"#F5E8B8"}]},
  {"featureType":"road.local","elementType":"geometry.stroke","stylers":[{"color":"#E8DFC0"},{"weight":0.5}]},
  {"featureType":"transit","elementType":"geometry","stylers":[{"color":"#E5E5EA"}]},
  {"featureType":"transit.station","elementType":"labels","stylers":[{"visibility":"off"}]},
  {"featureType":"water","elementType":"geometry.fill","stylers":[{"color":"#A8D4E6"}]},
  {"featureType":"water","elementType":"labels.text.fill","stylers":[{"color":"#7FBBD4"}]}
]
''';

  // ═════════════════════════════════════════════════════
  //  NAVIGATION — Ultra-dark Google Maps navigation style
  // ═════════════════════════════════════════════════════
  static const navigation = '''
[
  {"elementType":"geometry","stylers":[{"color":"#1a1a2e"}]},
  {"elementType":"labels","stylers":[{"visibility":"off"}]},
  {"featureType":"landscape","elementType":"geometry.fill","stylers":[{"color":"#16162b"}]},
  {"featureType":"landscape.man_made","elementType":"geometry.fill","stylers":[{"color":"#1e1e38"}]},
  {"featureType":"poi","elementType":"labels","stylers":[{"visibility":"off"}]},
  {"featureType":"poi","elementType":"geometry","stylers":[{"color":"#1e1e38"}]},
  {"featureType":"poi.park","elementType":"geometry","stylers":[{"color":"#1a2e1a"}]},
  {"featureType":"road","elementType":"geometry.fill","stylers":[{"color":"#2a2a4a"}]},
  {"featureType":"road","elementType":"geometry.stroke","stylers":[{"color":"#141428"}]},
  {"featureType":"road","elementType":"labels.text.fill","stylers":[{"color":"#7a7a9a"}]},
  {"featureType":"road.highway","elementType":"geometry.fill","stylers":[{"color":"#3a3a5a"}]},
  {"featureType":"road.highway","elementType":"geometry.stroke","stylers":[{"color":"#1a1a30"}]},
  {"featureType":"road.highway","elementType":"labels.text.fill","stylers":[{"color":"#8a8aaa"}]},
  {"featureType":"road.arterial","elementType":"geometry.fill","stylers":[{"color":"#2e2e4e"}]},
  {"featureType":"transit","elementType":"geometry","stylers":[{"color":"#1e1e38"}]},
  {"featureType":"transit.station","elementType":"labels","stylers":[{"visibility":"off"}]},
  {"featureType":"water","elementType":"geometry","stylers":[{"color":"#0e1a2e"}]},
  {"featureType":"water","elementType":"labels.text.fill","stylers":[{"color":"#3a4a6a"}]}
]
''';

  // ═════════════════════════════════════════════════════
  //  NAVIGATION iOS — Carreteras doradas para iOS
  // ═════════════════════════════════════════════════════
  static const navigationIOS = '''
[
  {"elementType":"geometry","stylers":[{"color":"#1a1a2e"}]},
  {"elementType":"labels","stylers":[{"visibility":"off"}]},
  {"featureType":"landscape","elementType":"geometry.fill","stylers":[{"color":"#16162b"}]},
  {"featureType":"landscape.man_made","elementType":"geometry.fill","stylers":[{"color":"#1e1e38"}]},
  {"featureType":"poi","elementType":"labels","stylers":[{"visibility":"off"}]},
  {"featureType":"poi","elementType":"geometry","stylers":[{"color":"#1e1e38"}]},
  {"featureType":"poi.park","elementType":"geometry","stylers":[{"color":"#1a2e1a"}]},
  {"featureType":"road","elementType":"geometry.fill","stylers":[{"color":"#E8C547"}]},
  {"featureType":"road","elementType":"geometry.stroke","stylers":[{"color":"#B8972E"}]},
  {"featureType":"road","elementType":"labels.text.fill","stylers":[{"color":"#7a7a9a"}]},
  {"featureType":"road.highway","elementType":"geometry.fill","stylers":[{"color":"#E8C547"}]},
  {"featureType":"road.highway","elementType":"geometry.stroke","stylers":[{"color":"#B8972E"}]},
  {"featureType":"road.highway","elementType":"labels.text.fill","stylers":[{"color":"#8a8aaa"}]},
  {"featureType":"road.arterial","elementType":"geometry.fill","stylers":[{"color":"#E8C547"}]},
  {"featureType":"road.arterial","elementType":"geometry.stroke","stylers":[{"color":"#B8972E"}]},
  {"featureType":"road.local","elementType":"geometry.fill","stylers":[{"color":"#D4B03A"}]},
  {"featureType":"road.local","elementType":"geometry.stroke","stylers":[{"color":"#A88B2A"}]},
  {"featureType":"transit","elementType":"geometry","stylers":[{"color":"#1e1e38"}]},
  {"featureType":"transit.station","elementType":"labels","stylers":[{"visibility":"off"}]},
  {"featureType":"water","elementType":"geometry","stylers":[{"color":"#0e1a2e"}]},
  {"featureType":"water","elementType":"labels.text.fill","stylers":[{"color":"#3a4a6a"}]}
]
''';

  // ═════════════════════════════════════════════════════
  //  MÉTODOS HELPER - Selección automática según plataforma
  // ═════════════════════════════════════════════════════
  
  /// Obtiene el estilo dark apropiado según la plataforma
  static String getDark() => darkIOS;
  
  /// Obtiene el estilo light apropiado según la plataforma
  static String getLight() => lightIOS;
  
  /// Obtiene el estilo de navegación apropiado según la plataforma
  static String getNavigation() => navigationIOS;
  
  /// Obtiene el estilo apropiado según tema y plataforma
  /// [isDark] - true para tema oscuro, false para tema claro
  static String getStyle({required bool isDark}) => isDark ? getDark() : getLight();
}

