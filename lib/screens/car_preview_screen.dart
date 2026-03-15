import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import '../navigation/car_icon_loader.dart';

/// Quick visual preview of the Google Maps–style navigation car marker.
/// Shows the car at multiple rotation angles so you can verify it looks correct.
class CarPreviewScreen extends StatefulWidget {
  const CarPreviewScreen({super.key});

  @override
  State<CarPreviewScreen> createState() => _CarPreviewScreenState();
}

class _CarPreviewScreenState extends State<CarPreviewScreen>
    with TickerProviderStateMixin {
  Uint8List? _carBytes;
  late AnimationController _rotateCtrl;
  double _rotation = 0;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _rotateCtrl = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 6),
    )
      ..repeat()
      ..addListener(() {
        setState(() => _rotation = _rotateCtrl.value * 360);
      });
    _loadCar();
  }

  Future<void> _loadCar() async {
    final bytes = await CarIconLoader.loadUberBytes();
    if (mounted) {
      setState(() {
        _carBytes = bytes;
        _loading = false;
      });
    }
  }

  @override
  void dispose() {
    _rotateCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF080c16),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0d1220),
        title: const Text(
          'Car Preview — Google Maps Nav Style',
          style: TextStyle(color: Colors.white, fontSize: 15),
        ),
        iconTheme: const IconThemeData(color: Colors.white),
      ),
      body: _loading
          ? const Center(
              child: CircularProgressIndicator(color: Color(0xFFE8C547)),
            )
          : SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  const Text(
                    'Ícono real del marcador (tamaño del mapa)',
                    style: TextStyle(color: Colors.white70, fontSize: 13),
                  ),
                  const SizedBox(height: 16),

                  // ── Mapa simulado con el carro en posición real ──
                  Container(
                    width: double.infinity,
                    height: 260,
                    decoration: BoxDecoration(
                      color: const Color(0xFF0a0f1c),
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: Colors.white12),
                    ),
                    child: Stack(
                      alignment: Alignment.center,
                      children: [
                        // Simulated road
                        Positioned(
                          left: 0,
                          right: 0,
                          top: 80,
                          bottom: 80,
                          child: Container(color: const Color(0xFF141e38)),
                        ),
                        // Route polyline
                        Positioned(
                          left: MediaQuery.of(context).size.width * 0.4,
                          top: 0,
                          bottom: 0,
                          width: 14,
                          child: Container(
                            decoration: BoxDecoration(
                              color: const Color(0xFF4285F4),
                              boxShadow: [
                                BoxShadow(
                                  color: const Color(0xFF4285F4)
                                      .withValues(alpha: 0.5),
                                  blurRadius: 8,
                                ),
                              ],
                            ),
                          ),
                        ),
                        // Car marker (rotating)
                        if (_carBytes != null)
                          Transform.rotate(
                            angle: _rotation * 3.14159 / 180,
                            child: Image.memory(
                              _carBytes!,
                              width: 28,
                              height: 80,
                              filterQuality: FilterQuality.high,
                            ),
                          ),
                        // Label
                        const Positioned(
                          bottom: 12,
                          child: Text(
                            'Girando 360° — así se ve en el mapa',
                            style:
                                TextStyle(color: Colors.white38, fontSize: 11),
                          ),
                        ),
                      ],
                    ),
                  ),

                  const SizedBox(height: 32),
                  const Text(
                    '8 ángulos direccionales',
                    style: TextStyle(color: Colors.white70, fontSize: 13),
                  ),
                  const SizedBox(height: 16),

                  // ── 8 sprites rotados ──
                  Wrap(
                    spacing: 20,
                    runSpacing: 20,
                    alignment: WrapAlignment.center,
                    children: List.generate(8, (i) {
                      final angleDeg = i * 45.0;
                      final label = [
                        'N↑', 'NE↗', 'E→', 'SE↘',
                        'S↓', 'SW↙', 'W←', 'NW↖',
                      ][i];
                      return _AngleCard(
                        bytes: _carBytes!,
                        angleDeg: angleDeg,
                        label: label,
                      );
                    }),
                  ),

                  const SizedBox(height: 32),
                  const Text(
                    'Simulación inclinación 55° (como Google Maps)',
                    style: TextStyle(color: Colors.white70, fontSize: 13),
                  ),
                  const SizedBox(height: 16),

                  // ── Vista inclinada 55° ──
                  Container(
                    width: 200,
                    height: 160,
                    decoration: BoxDecoration(
                      color: const Color(0xFF0a0f1c),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: Colors.white12),
                    ),
                    child: Center(
                      child: Transform(
                        alignment: Alignment.center,
                        transform: Matrix4.identity()
                          ..setEntry(3, 2, 0.001)
                          ..rotateX(55 * 3.14159 / 180),
                        child: _carBytes != null
                            ? Image.memory(
                                _carBytes!,
                                width: 28,
                                height: 80,
                                filterQuality: FilterQuality.high,
                              )
                            : const SizedBox.shrink(),
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'Proporciones compensadas para tilt=55°',
                    style: TextStyle(color: Colors.white38, fontSize: 11),
                  ),
                  const SizedBox(height: 40),
                ],
              ),
            ),
    );
  }
}

class _AngleCard extends StatelessWidget {
  final Uint8List bytes;
  final double angleDeg;
  final String label;

  const _AngleCard({
    required this.bytes,
    required this.angleDeg,
    required this.label,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Container(
          width: 70,
          height: 100,
          decoration: BoxDecoration(
            color: const Color(0xFF0d1220),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: Colors.white12),
          ),
          child: Center(
            child: Transform.rotate(
              angle: angleDeg * 3.14159 / 180,
              child: Image.memory(
                bytes,
                width: 24,
                height: 68,
                filterQuality: FilterQuality.high,
              ),
            ),
          ),
        ),
        const SizedBox(height: 6),
        Text(
          label,
          style: const TextStyle(color: Colors.white54, fontSize: 11),
        ),
      ],
    );
  }
}
