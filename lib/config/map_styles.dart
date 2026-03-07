/// Google Maps JSON styling for light and dark themes.
/// Usage: `mapCtrl.setMapStyle(isDark ? MapStyles.dark : MapStyles.light);`
class MapStyles {
  MapStyles._();

  // ═════════════════════════════════════════════════════
  //  DARK — Google Maps dark with all POIs, labels & icons
  // ═════════════════════════════════════════════════════
  static const dark = '''
[
  {"elementType":"geometry","stylers":[{"color":"#242f3e"}]},
  {"elementType":"labels.text.fill","stylers":[{"color":"#746855"}]},
  {"elementType":"labels.text.stroke","stylers":[{"color":"#242f3e"}]},
  {"featureType":"administrative.locality","elementType":"labels.text.fill","stylers":[{"color":"#d59563"}]},
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
  //  LIGHT — Apple Maps-inspired clean white
  // ═════════════════════════════════════════════════════
  static const light = '''
[
  {"elementType":"geometry","stylers":[{"color":"#F0F0F5"}]},
  {"elementType":"labels.icon","stylers":[{"visibility":"off"}]},
  {"elementType":"labels.text.fill","stylers":[{"color":"#6E6E73"}]},
  {"elementType":"labels.text.stroke","stylers":[{"color":"#FFFFFF"},{"weight":3}]},
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
  //  NAVIGATION — Ultra-dark Google Maps navigation style
  // ═════════════════════════════════════════════════════
  static const navigation = '''
[
  {"elementType":"geometry","stylers":[{"color":"#1a1a2e"}]},
  {"elementType":"labels.text.fill","stylers":[{"color":"#5a5a7a"}]},
  {"elementType":"labels.text.stroke","stylers":[{"color":"#1a1a2e"}]},
  {"featureType":"administrative.locality","elementType":"labels.text.fill","stylers":[{"color":"#8888aa"}]},
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
}
