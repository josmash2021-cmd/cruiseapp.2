/// Google Maps JSON styling for light and dark themes.
/// All styles show WHITE labels on both iOS and Android.
/// Gold roads + blue buildings + 3D-ready dark backgrounds.
class MapStyles {
  MapStyles._();

  // ═════════════════════════════════════════════════════
  //  DARK — Uber Driver-style: navy bg, gold roads, blue buildings, WHITE labels
  // ═════════════════════════════════════════════════════
  static const dark = '''
[
  {"elementType":"geometry","stylers":[{"color":"#0a0e1a"}]},
  {"elementType":"labels.text.fill","stylers":[{"color":"#ffffff"}]},
  {"elementType":"labels.text.stroke","stylers":[{"color":"#0a0e1a"},{"weight":3}]},
  {"elementType":"labels.icon","stylers":[{"visibility":"on"}]},
  {"featureType":"administrative","elementType":"geometry.stroke","stylers":[{"color":"#1a2040"}]},
  {"featureType":"administrative","elementType":"labels.text.fill","stylers":[{"color":"#8090b0"}]},
  {"featureType":"landscape","elementType":"geometry.fill","stylers":[{"color":"#0d1220"}]},
  {"featureType":"landscape.man_made","elementType":"geometry.fill","stylers":[{"color":"#121832"}]},
  {"featureType":"landscape.man_made","elementType":"geometry.stroke","stylers":[{"color":"#1a2548"}]},
  {"featureType":"poi","elementType":"geometry","stylers":[{"color":"#101828"}]},
  {"featureType":"poi","elementType":"labels.text.fill","stylers":[{"color":"#c0c8d8"}]},
  {"featureType":"poi","elementType":"labels.icon","stylers":[{"visibility":"on"},{"saturation":-40},{"lightness":-20}]},
  {"featureType":"poi.park","elementType":"geometry","stylers":[{"color":"#0a1a12"}]},
  {"featureType":"poi.park","elementType":"labels.text.fill","stylers":[{"color":"#5a9a6a"}]},
  {"featureType":"road","elementType":"geometry.fill","stylers":[{"color":"#E8C547"}]},
  {"featureType":"road","elementType":"geometry.stroke","stylers":[{"color":"#B8972E"}]},
  {"featureType":"road","elementType":"labels.text.fill","stylers":[{"color":"#ffffff"}]},
  {"featureType":"road","elementType":"labels.text.stroke","stylers":[{"color":"#0a0e1a"},{"weight":4}]},
  {"featureType":"road.highway","elementType":"geometry.fill","stylers":[{"color":"#E8C547"}]},
  {"featureType":"road.highway","elementType":"geometry.stroke","stylers":[{"color":"#B8972E"},{"weight":1.5}]},
  {"featureType":"road.highway","elementType":"labels.text.fill","stylers":[{"color":"#ffffff"}]},
  {"featureType":"road.arterial","elementType":"geometry.fill","stylers":[{"color":"#D4B03A"}]},
  {"featureType":"road.arterial","elementType":"geometry.stroke","stylers":[{"color":"#A88B2A"}]},
  {"featureType":"road.local","elementType":"geometry.fill","stylers":[{"color":"#1a2548"}]},
  {"featureType":"road.local","elementType":"geometry.stroke","stylers":[{"color":"#0d1220"}]},
  {"featureType":"road.local","elementType":"labels.text.fill","stylers":[{"color":"#8090b0"}]},
  {"featureType":"transit","elementType":"geometry","stylers":[{"color":"#101828"}]},
  {"featureType":"transit.station","elementType":"labels.text.fill","stylers":[{"color":"#c0a050"}]},
  {"featureType":"water","elementType":"geometry","stylers":[{"color":"#060a14"}]},
  {"featureType":"water","elementType":"labels.text.fill","stylers":[{"color":"#3a5a8a"}]}
]
''';

  // ═════════════════════════════════════════════════════
  //  DARK iOS — Same as dark (unified white labels)
  // ═════════════════════════════════════════════════════
  static const darkIOS = dark;

  // ═════════════════════════════════════════════════════
  //  LIGHT — Clean white with gold accent roads, WHITE labels
  // ═════════════════════════════════════════════════════
  static const light = '''
[
  {"elementType":"geometry","stylers":[{"color":"#F0F0F5"}]},
  {"elementType":"labels.text.fill","stylers":[{"color":"#333333"}]},
  {"elementType":"labels.text.stroke","stylers":[{"color":"#F0F0F5"},{"weight":3}]},
  {"elementType":"labels.icon","stylers":[{"visibility":"on"}]},
  {"featureType":"administrative","elementType":"geometry","stylers":[{"color":"#D1D1D6"},{"visibility":"simplified"}]},
  {"featureType":"landscape","elementType":"geometry.fill","stylers":[{"color":"#EBEBF0"}]},
  {"featureType":"landscape.man_made","elementType":"geometry.fill","stylers":[{"color":"#E8E8ED"}]},
  {"featureType":"poi","elementType":"geometry","stylers":[{"color":"#E5E5EA"}]},
  {"featureType":"poi","elementType":"labels.text.fill","stylers":[{"color":"#6B4E2A"}]},
  {"featureType":"poi.park","elementType":"geometry.fill","stylers":[{"color":"#C8E6C5"}]},
  {"featureType":"poi.park","elementType":"labels.text.fill","stylers":[{"color":"#2E7D32"}]},
  {"featureType":"road","elementType":"geometry.fill","stylers":[{"color":"#E8C547"}]},
  {"featureType":"road","elementType":"geometry.stroke","stylers":[{"color":"#D4B03A"},{"weight":1}]},
  {"featureType":"road","elementType":"labels.text.fill","stylers":[{"color":"#222222"}]},
  {"featureType":"road","elementType":"labels.text.stroke","stylers":[{"color":"#FFFFFF"},{"weight":4}]},
  {"featureType":"road.highway","elementType":"geometry.fill","stylers":[{"color":"#E8C547"}]},
  {"featureType":"road.highway","elementType":"geometry.stroke","stylers":[{"color":"#B8972E"},{"weight":1.5}]},
  {"featureType":"road.local","elementType":"geometry.fill","stylers":[{"color":"#F5E8B8"}]},
  {"featureType":"transit","elementType":"geometry","stylers":[{"color":"#E5E5EA"}]},
  {"featureType":"water","elementType":"geometry.fill","stylers":[{"color":"#A8D4E6"}]},
  {"featureType":"water","elementType":"labels.text.fill","stylers":[{"color":"#3a6d8c"}]}
]
''';

  // ═════════════════════════════════════════════════════
  //  LIGHT iOS — Same as light (unified labels)
  // ═════════════════════════════════════════════════════
  static const lightIOS = light;

  // ═════════════════════════════════════════════════════
  //  NAVIGATION — Ultra-dark 3D nav: gold roads, blue buildings, WHITE labels
  // ═════════════════════════════════════════════════════
  static const navigation = '''
[
  {"elementType":"geometry","stylers":[{"color":"#080c16"}]},
  {"elementType":"labels.text.fill","stylers":[{"color":"#ffffff"}]},
  {"elementType":"labels.text.stroke","stylers":[{"color":"#080c16"},{"weight":3}]},
  {"elementType":"labels.icon","stylers":[{"visibility":"on"},{"saturation":-60},{"lightness":-30}]},
  {"featureType":"administrative","elementType":"labels.text.fill","stylers":[{"color":"#607090"}]},
  {"featureType":"landscape","elementType":"geometry.fill","stylers":[{"color":"#0a0f1c"}]},
  {"featureType":"landscape.man_made","elementType":"geometry.fill","stylers":[{"color":"#101830"}]},
  {"featureType":"landscape.man_made","elementType":"geometry.stroke","stylers":[{"color":"#182040"}]},
  {"featureType":"poi","elementType":"geometry","stylers":[{"color":"#0e1424"}]},
  {"featureType":"poi","elementType":"labels.text.fill","stylers":[{"color":"#8898b0"}]},
  {"featureType":"poi.park","elementType":"geometry","stylers":[{"color":"#0a1a10"}]},
  {"featureType":"poi.park","elementType":"labels.text.fill","stylers":[{"color":"#4a8a5a"}]},
  {"featureType":"road","elementType":"geometry.fill","stylers":[{"color":"#E8C547"}]},
  {"featureType":"road","elementType":"geometry.stroke","stylers":[{"color":"#B8972E"}]},
  {"featureType":"road","elementType":"labels.text.fill","stylers":[{"color":"#ffffff"}]},
  {"featureType":"road","elementType":"labels.text.stroke","stylers":[{"color":"#080c16"},{"weight":4}]},
  {"featureType":"road.highway","elementType":"geometry.fill","stylers":[{"color":"#E8C547"}]},
  {"featureType":"road.highway","elementType":"geometry.stroke","stylers":[{"color":"#B8972E"},{"weight":1.5}]},
  {"featureType":"road.arterial","elementType":"geometry.fill","stylers":[{"color":"#D4B03A"}]},
  {"featureType":"road.arterial","elementType":"geometry.stroke","stylers":[{"color":"#A88B2A"}]},
  {"featureType":"road.local","elementType":"geometry.fill","stylers":[{"color":"#141e38"}]},
  {"featureType":"road.local","elementType":"geometry.stroke","stylers":[{"color":"#0a0f1c"}]},
  {"featureType":"road.local","elementType":"labels.text.fill","stylers":[{"color":"#607090"}]},
  {"featureType":"transit","elementType":"geometry","stylers":[{"color":"#0e1424"}]},
  {"featureType":"transit.station","elementType":"labels.text.fill","stylers":[{"color":"#b0903a"}]},
  {"featureType":"water","elementType":"geometry","stylers":[{"color":"#040810"}]},
  {"featureType":"water","elementType":"labels.text.fill","stylers":[{"color":"#2a4a7a"}]}
]
''';

  // ═════════════════════════════════════════════════════
  //  NAVIGATION iOS — Same as navigation (unified white labels)
  // ═════════════════════════════════════════════════════
  static const navigationIOS = navigation;

  // ═════════════════════════════════════════════════════
  //  HELPER METHODS
  // ═════════════════════════════════════════════════════
  
  /// Dark style (unified for all platforms)
  static String getDark() => dark;
  
  /// Light style (unified for all platforms)
  static String getLight() => light;
  
  /// Navigation style (unified for all platforms)
  static String getNavigation() => navigation;
  
  /// Get style by theme
  static String getStyle({required bool isDark}) => isDark ? dark : light;
}

