import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

/// Renderer avanzado para coche estilizado 3D tipo juego
/// Genera imágenes PNG con efectos visuales:
/// - Forma isométrica
/// - Sombras proyectadas
/// - Gradientes para efecto 3D
/// - Luces y reflejos
class GameCarRenderer {
  static const double _carWidth = 120;
  static const double _carHeight = 200;

  /// Genera imagen del coche con todas las variantes de color
  static Future<Uint8List> renderCar({
    CarColor color = CarColor.blue,
    CarType type = CarType.sport,
  }) async {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    final size = const Size(_carWidth, _carHeight);

    switch (type) {
      case CarType.sport:
        await _drawSportCar(canvas, size, color);
        break;
      case CarType.suv:
        await _drawSUV(canvas, size, color);
        break;
      case CarType.futuristic:
        await _drawFuturisticCar(canvas, size, color);
        break;
    }

    final picture = recorder.endRecording();
    final image = await picture.toImage(
      size.width.toInt(),
      size.height.toInt(),
    );

    final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
    return byteData!.buffer.asUint8List();
  }

  /// Coche deportivo estilizado
  static Future<void> _drawSportCar(Canvas canvas, Size size, CarColor color) async {
    final cx = size.width / 2;
    final cy = size.height / 2;

    final palette = _getPalette(color);

    // ── SOMBRA PROYECTADA (más grande para efecto flotante) ──
    final shadowPaint = Paint()
      ..color = Colors.black.withOpacity(0.25)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 20);

    canvas.drawOval(
      Rect.fromCenter(center: Offset(cx, cy + 75), width: 90, height: 60),
      shadowPaint,
    );

    // ── CUERPO PRINCIPAL (forma trapezoidal aerodinámica) ──
    final bodyPath = Path()
      // Parte trasera ancha
      ..moveTo(cx - 45, cy + 55)
      ..quadraticBezierTo(cx - 50, cy + 20, cx - 42, cy - 15)
      // Lado izquierdo con curva de hombro
      ..quadraticBezierTo(cx - 38, cy - 45, cx - 30, cy - 65)
      // Capó puntiagudo
      ..lineTo(cx, cy - 80)
      ..lineTo(cx + 30, cy - 65)
      // Lado derecho
      ..quadraticBezierTo(cx + 38, cy - 45, cx + 42, cy - 15)
      ..quadraticBezierTo(cx + 50, cy + 20, cx + 45, cy + 55)
      // Curva trasera redondeada
      ..quadraticBezierTo(cx, cy + 72, cx - 45, cy + 55)
      ..close();

    // Base del coche
    canvas.drawPath(bodyPath, Paint()..color = palette.base);

    // Degradado para efecto 3D (parte superior más clara)
    final gradientRect = Rect.fromLTWH(cx - 50, cy - 85, 100, 150);
    final gradientPaint = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [
          palette.highlight.withOpacity(0.6),
          Colors.transparent,
        ],
      ).createShader(gradientRect);

    canvas.drawPath(bodyPath, gradientPaint);

    // ── TECHO (cristal panorámico) ──
    final roofPath = Path()
      ..moveTo(cx - 22, cy - 5)
      ..lineTo(cx - 20, cy - 50)
      ..quadraticBezierTo(cx, cy - 60, cx + 20, cy - 50)
      ..lineTo(cx + 22, cy - 5)
      ..quadraticBezierTo(cx, cy + 5, cx - 22, cy - 5)
      ..close();

    // Cristal oscuro
    canvas.drawPath(
      roofPath,
      Paint()..color = const Color(0xFF152535),
    );

    // Reflejo en cristal
    canvas.drawPath(
      roofPath,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            palette.highlight.withOpacity(0.3),
            Colors.transparent,
          ],
        ).createShader(Rect.fromLTWH(cx - 22, cy - 60, 44, 55)),
    );

    // ── PARABRISAS ──
    final windshieldPath = Path()
      ..moveTo(cx - 20, cy - 48)
      ..lineTo(cx, cy - 58)
      ..lineTo(cx + 20, cy - 48)
      ..lineTo(cx + 18, cy - 25)
      ..lineTo(cx - 18, cy - 25)
      ..close();

    canvas.drawPath(
      windshieldPath,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            const Color(0xFF1A3A5C),
            const Color(0xFF0D1F33),
          ],
        ).createShader(Rect.fromLTWH(cx - 20, cy - 58, 40, 35)),
    );

    // Reflejo brillante en parabrisas
    final glarePath = Path()
      ..moveTo(cx - 15, cy - 45)
      ..lineTo(cx - 5, cy - 50)
      ..lineTo(cx - 3, cy - 35)
      ..lineTo(cx - 13, cy - 30)
      ..close();

    canvas.drawPath(
      glarePath,
      Paint()..color = Colors.white.withOpacity(0.4),
    );

    // ── FAROS DELANTEROS (LED brillante) ──
    _drawHeadlight(canvas, Offset(cx - 22, cy - 70), palette.accent);
    _drawHeadlight(canvas, Offset(cx + 22, cy - 70), palette.accent);

    // ── LUCES TRASERAS (tipo LED strip) ──
    final taillightPaint = Paint()
      ..color = const Color(0xFFFF3333)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3);

    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromCenter(center: Offset(cx - 28, cy + 58), width: 20, height: 6),
        const Radius.circular(2),
      ),
      taillightPaint,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromCenter(center: Offset(cx + 28, cy + 58), width: 20, height: 6),
        const Radius.circular(2),
      ),
      taillightPaint,
    );

    // Strip conectando luces traseras
    canvas.drawRect(
      Rect.fromCenter(center: Offset(cx, cy + 58), width: 36, height: 3),
      Paint()..color = const Color(0xFFCC0000),
    );

    // ── RUEDAS (estilo sport con llanta grande) ──
    final wheelPositions = [
      Offset(cx - 35, cy + 30),  // Trasera izq
      Offset(cx + 35, cy + 30),  // Trasera der
      Offset(cx - 25, cy - 50),  // Delantera izq
      Offset(cx + 25, cy - 50),  // Delantera der
    ];

    for (final pos in wheelPositions) {
      await _drawSportWheel(canvas, pos);
    }

    // ── AERODINÁMICA (spoiler y difusor) ──
    // Spoiler trasero
    canvas.drawPath(
      Path()
        ..moveTo(cx - 40, cy + 45)
        ..lineTo(cx - 45, cy + 35)
        ..lineTo(cx + 45, cy + 35)
        ..lineTo(cx + 40, cy + 45)
        ..close(),
      Paint()..color = palette.dark,
    );

    // Difusor trasero
    canvas.drawPath(
      Path()
        ..moveTo(cx - 25, cy + 65)
        ..lineTo(cx - 20, cy + 72)
        ..lineTo(cx + 20, cy + 72)
        ..lineTo(cx + 25, cy + 65)
        ..close(),
      Paint()..color = const Color(0xFF111111),
    );

    // ── LÍNEAS DE CONTORNO ──
    canvas.drawPath(
      bodyPath,
      Paint()
        ..color = palette.outline
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5,
    );

    // ── BRILLO METÁLICO (línea de cintura) ──
    final waistLine = Path()
      ..moveTo(cx - 45, cy + 10)
      ..quadraticBezierTo(cx, cy + 15, cx + 45, cy + 10);

    canvas.drawPath(
      waistLine,
      Paint()
        ..color = Colors.white.withOpacity(0.3)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );
  }

  static void _drawHeadlight(Canvas canvas, Offset center, Color color) {
    // Halo exterior
    canvas.drawOval(
      Rect.fromCenter(center: center, width: 18, height: 12),
      Paint()
        ..color = color.withOpacity(0.3)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 8),
    );

    // Lente principal
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromCenter(center: center, width: 14, height: 10),
        const Radius.circular(3),
      ),
      Paint()
        ..shader = RadialGradient(
          colors: [
            Colors.white,
            color,
          ],
        ).createShader(Rect.fromCenter(center: center, width: 14, height: 10)),
    );
  }

  static Future<void> _drawSportWheel(Canvas canvas, Offset center) async {
    // Neumático
    canvas.drawOval(
      Rect.fromCenter(center: center, width: 22, height: 32),
      Paint()..color = const Color(0xFF1A1A1A),
    );

    // Llanta
    canvas.drawOval(
      Rect.fromCenter(center: center, width: 14, height: 22),
      Paint()
        ..shader = RadialGradient(
          colors: [
            const Color(0xFF666666),
            const Color(0xFF333333),
          ],
        ).createShader(Rect.fromCenter(center: center, width: 14, height: 22)),
    );

    // Centro de llanta
    canvas.drawCircle(
      center,
      4,
      Paint()..color = const Color(0xFF999999),
    );

    // Rayos de la llanta (5 radios)
    for (int i = 0; i < 5; i++) {
      final angle = (i * 72) * math.pi / 180;
      final dx = math.cos(angle) * 8;
      final dy = math.sin(angle) * 12;

      canvas.drawLine(
        center,
        center.translate(dx, dy),
        Paint()
          ..color = const Color(0xFFAAAAAA)
          ..strokeWidth = 1.5,
      );
    }
  }

  /// SUV estilizado
  static Future<void> _drawSUV(Canvas canvas, Size size, CarColor color) async {
    final cx = size.width / 2;
    final cy = size.height / 2;
    final palette = _getPalette(color);

    // Sombra
    canvas.drawOval(
      Rect.fromCenter(center: Offset(cx, cy + 70), width: 100, height: 50),
      Paint()
        ..color = Colors.black.withOpacity(0.25)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 18),
    );

    // Cuerpo más alto y recto
    final bodyPath = Path()
      ..moveTo(cx - 48, cy + 50)
      ..lineTo(cx - 48, cy - 30)
      ..quadraticBezierTo(cx - 45, cy - 60, cx - 35, cy - 70)
      ..lineTo(cx + 35, cy - 70)
      ..quadraticBezierTo(cx + 45, cy - 60, cx + 48, cy - 30)
      ..lineTo(cx + 48, cy + 50)
      ..quadraticBezierTo(cx, cy + 65, cx - 48, cy + 50)
      ..close();

    canvas.drawPath(bodyPath, Paint()..color = palette.base);

    // Techo más alto
    final roofPath = Path()
      ..moveTo(cx - 38, cy - 20)
      ..lineTo(cx - 35, cy - 65)
      ..lineTo(cx + 35, cy - 65)
      ..lineTo(cx + 38, cy - 20)
      ..close();

    canvas.drawPath(roofPath, Paint()..color = const Color(0xFF152535));

    // Ventanas laterales
    canvas.drawRect(
      Rect.fromLTWH(cx - 35, cy - 60, 70, 35),
      Paint()..color = const Color(0xFF1A2A3A),
    );

    // Ruedas más grandes
    for (final pos in [
      Offset(cx - 38, cy + 35),
      Offset(cx + 38, cy + 35),
      Offset(cx - 30, cy - 55),
      Offset(cx + 30, cy - 55),
    ]) {
      await _drawSUVWheel(canvas, pos);
    }

    // Faros cuadrados
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromCenter(center: Offset(cx - 25, cy - 65), width: 16, height: 10),
        const Radius.circular(2),
      ),
      Paint()
        ..shader = LinearGradient(
          colors: [Colors.white, palette.accent],
        ).createShader(Rect.fromLTWH(cx - 33, cy - 70, 16, 10)),
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromCenter(center: Offset(cx + 25, cy - 65), width: 16, height: 10),
        const Radius.circular(2),
      ),
      Paint()
        ..shader = LinearGradient(
          colors: [Colors.white, palette.accent],
        ).createShader(Rect.fromLTWH(cx + 17, cy - 70, 16, 10)),
    );

    canvas.drawPath(
      bodyPath,
      Paint()
        ..color = palette.outline
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5,
    );
  }

  static Future<void> _drawSUVWheel(Canvas canvas, Offset center) async {
    canvas.drawOval(
      Rect.fromCenter(center: center, width: 24, height: 34),
      Paint()..color = const Color(0xFF1A1A1A),
    );
    canvas.drawOval(
      Rect.fromCenter(center: center, width: 16, height: 24),
      Paint()
        ..shader = RadialGradient(
          colors: [const Color(0xFF666666), const Color(0xFF333333)],
        ).createShader(Rect.fromCenter(center: center, width: 16, height: 24)),
    );
    canvas.drawCircle(center, 5, Paint()..color = const Color(0xFF999999));
  }

  /// Coche futurista tipo cyberpunk
  static Future<void> _drawFuturisticCar(Canvas canvas, Size size, CarColor color) async {
    final cx = size.width / 2;
    final cy = size.height / 2;
    final palette = _getPalette(color);

    // Sombra con glow
    canvas.drawOval(
      Rect.fromCenter(center: Offset(cx, cy + 70), width: 80, height: 45),
      Paint()
        ..color = palette.accent.withOpacity(0.2)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 25),
    );

    // Cuerpo muy angular y aerodinámico
    final bodyPath = Path()
      ..moveTo(cx - 40, cy + 50)
      ..lineTo(cx - 45, cy)
      ..lineTo(cx - 30, cy - 60)
      ..lineTo(cx, cy - 75)
      ..lineTo(cx + 30, cy - 60)
      ..lineTo(cx + 45, cy)
      ..lineTo(cx + 40, cy + 50)
      ..close();

    canvas.drawPath(bodyPath, Paint()..color = palette.dark);

    // Líneas de neón (tron)
    final neonPath = Path()
      ..moveTo(cx - 30, cy - 50)
      ..lineTo(cx - 40, cy + 40)
      ..moveTo(cx + 30, cy - 50)
      ..lineTo(cx + 40, cy + 40);

    canvas.drawPath(
      neonPath,
      Paint()
        ..color = palette.accent
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6),
    );

    // Cabina tipo burbuja
    final cabinPath = Path()
      ..moveTo(cx - 20, cy - 30)
      ..quadraticBezierTo(cx, cy - 50, cx + 20, cy - 30)
      ..lineTo(cx + 15, cy + 10)
      ..lineTo(cx - 15, cy + 10)
      ..close();

    canvas.drawPath(
      cabinPath,
      Paint()
        ..shader = LinearGradient(
          colors: [
            Colors.cyan.withOpacity(0.4),
            Colors.blue.withOpacity(0.2),
          ],
        ).createShader(Rect.fromLTWH(cx - 20, cy - 50, 40, 60)),
    );

    // Luces delanteras LED slim
    canvas.drawRect(
      Rect.fromCenter(center: Offset(cx - 25, cy - 68), width: 20, height: 4),
      Paint()
        ..color = Colors.white
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4),
    );
    canvas.drawRect(
      Rect.fromCenter(center: Offset(cx + 25, cy - 68), width: 20, height: 4),
      Paint()
        ..color = Colors.white
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4),
    );

    // Ruedas "hubless"
    for (final pos in [
      Offset(cx - 32, cy + 35),
      Offset(cx + 32, cy + 35),
    ]) {
      canvas.drawCircle(pos, 18, Paint()..color = const Color(0xFF222222));
      canvas.drawCircle(pos, 12, Paint()
        ..color = palette.accent
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3);
    }
  }

  static CarPalette _getPalette(CarColor color) {
    switch (color) {
      case CarColor.blue:
        return CarPalette(
          base: const Color(0xFF4A90E2),
          highlight: const Color(0xFF7AB8F7),
          dark: const Color(0xFF2E5A8C),
          accent: const Color(0xFF5BA3F5),
          outline: const Color(0xFF1E4A7C),
        );
      case CarColor.red:
        return CarPalette(
          base: const Color(0xFFE74C3C),
          highlight: const Color(0xFFFF6B6B),
          dark: const Color(0xFF8B2C22),
          accent: const Color(0xFFFF4444),
          outline: const Color(0xFF7B1C12),
        );
      case CarColor.green:
        return CarPalette(
          base: const Color(0xFF2ECC71),
          highlight: const Color(0xFF58D68D),
          dark: const Color(0xFF1E8449),
          accent: const Color(0xFF3DCC61),
          outline: const Color(0xFF0E7439),
        );
      case CarColor.gold:
        return CarPalette(
          base: const Color(0xFFD4A24C),
          highlight: const Color(0xFFE8C547),
          dark: const Color(0xFF8B6914),
          accent: const Color(0xFFF0C555),
          outline: const Color(0xFF6B4914),
        );
      case CarColor.purple:
        return CarPalette(
          base: const Color(0xFF9B59B6),
          highlight: const Color(0xFFBB79D6),
          dark: const Color(0xFF6C3483),
          accent: const Color(0xFFAF7AC5),
          outline: const Color(0xFF4C1453),
        );
      case CarColor.cyan:
        return CarPalette(
          base: const Color(0xFF00CED1),
          highlight: const Color(0xFF48D1CC),
          dark: const Color(0xFF008B8B),
          accent: const Color(0xFF00FFFF),
          outline: const Color(0xFF006B6B),
        );
    }
  }
}

enum CarColor { blue, red, green, gold, purple, cyan }
enum CarType { sport, suv, futuristic }

class CarPalette {
  final Color base;
  final Color highlight;
  final Color dark;
  final Color accent;
  final Color outline;

  CarPalette({
    required this.base,
    required this.highlight,
    required this.dark,
    required this.accent,
    required this.outline,
  });
}
