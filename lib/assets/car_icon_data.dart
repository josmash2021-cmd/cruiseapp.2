part of '../navigation/car_icon_loader.dart';

/// Compact 3D top-down car with closed roof, detailed doors,
/// properly placed lights, and strong shadows.
class _CarPalette {
  final Color body;
  final List<Color> barrelGrad;
  final List<Color> roofGrad;
  final Color outline;
  final Color mirrorBody;
  final Color mirrorArm;
  final Color bumperAccent;
  final Color crease;
  final Color fenderHighlight;
  final Color beltHighlight;
  final Color handleFill;
  const _CarPalette({
    required this.body,
    required this.barrelGrad,
    required this.roofGrad,
    required this.outline,
    required this.mirrorBody,
    required this.mirrorArm,
    required this.bumperAccent,
    required this.crease,
    required this.fenderHighlight,
    required this.beltHighlight,
    required this.handleFill,
  });

  static const whitePearl = _CarPalette(
    body: Color(0xFFE8EBF0),
    barrelGrad: [
      Color(0xFFAEB4BC),
      Color(0xFFC8CDD4),
      Color(0xFFE2E6EC),
      Color(0xFFF0F3F8),
      Color(0xFFE2E6EC),
      Color(0xFFC8CDD4),
      Color(0xFFAEB4BC),
    ],
    roofGrad: [
      Color(0xFFCCD0D8),
      Color(0xFFDEE2E8),
      Color(0xFFF0F3F8),
      Color(0xFFDEE2E8),
      Color(0xFFCCD0D8),
    ],
    outline: Color(0x30707070),
    mirrorBody: Color(0xFFDADEE4),
    mirrorArm: Color(0xFFD0D4DA),
    bumperAccent: Color(0xFFC0C5CC),
    crease: Color(0x12FFFFFF),
    fenderHighlight: Color(0x20FFFFFF),
    beltHighlight: Color(0x20FFFFFF),
    handleFill: Color(0x50FFFFFF),
  );

  static const black = _CarPalette(
    body: Color(0xFF1A1C20),
    barrelGrad: [
      Color(0xFF0E0F12),
      Color(0xFF1A1C20),
      Color(0xFF252830),
      Color(0xFF2E3038),
      Color(0xFF252830),
      Color(0xFF1A1C20),
      Color(0xFF0E0F12),
    ],
    roofGrad: [
      Color(0xFF141618),
      Color(0xFF1E2024),
      Color(0xFF282A30),
      Color(0xFF1E2024),
      Color(0xFF141618),
    ],
    outline: Color(0x40404040),
    mirrorBody: Color(0xFF2A2C32),
    mirrorArm: Color(0xFF222428),
    bumperAccent: Color(0xFF2A2E34),
    crease: Color(0x18FFFFFF),
    fenderHighlight: Color(0x14FFFFFF),
    beltHighlight: Color(0x14FFFFFF),
    handleFill: Color(0x30FFFFFF),
  );
}
