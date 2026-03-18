import 'dart:typed_data';
import 'dart:ui' as ui;
import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'suv_renderer.dart';

/// ─────────────────────────────────────────────────────────────────────────────
/// SUV Visual Preview Page
/// Run via: Navigator.push(ctx, MaterialPageRoute(builder: (_) => SuvPreviewPage()))
/// Shows the SUV in 3 angles exactly as it will appear during navigation.
/// ─────────────────────────────────────────────────────────────────────────────
class SuvPreviewPage extends StatefulWidget {
  const SuvPreviewPage({super.key});

  @override
  State<SuvPreviewPage> createState() => _SuvPreviewPageState();
}

class _SuvPreviewPageState extends State<SuvPreviewPage>
    with SingleTickerProviderStateMixin {
  Uint8List? _bytes;
  late AnimationController _fadeCtrl;
  late Animation<double> _fade;

  static const _bg       = Color(0xFF0F1117);
  static const _card     = Color(0xFF1A1D26);
  static const _border   = Color(0xFF2A2D3A);
  static const _gold     = Color(0xFFC9A433);
  static const _mapGrid  = Color(0xFF1E2130);

  @override
  void initState() {
    super.initState();
    _fadeCtrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 700));
    _fade = CurvedAnimation(parent: _fadeCtrl, curve: Curves.easeOut);
    _loadSuv();
  }

  Future<void> _loadSuv() async {
    final bytes = await SuvRenderer.render();
    if (!mounted) return;
    setState(() => _bytes = bytes);
    _fadeCtrl.forward();
  }

  @override
  void dispose() {
    _fadeCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _bg,
      appBar: AppBar(
        backgroundColor: const Color(0xFF12151E),
        title: const Text('SUV Preview', style: TextStyle(color: Color(0xFFF0F0F5), fontWeight: FontWeight.w600)),
        leading: BackButton(color: _gold),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(1),
          child: Container(height: 1, color: _border),
        ),
      ),
      body: _bytes == null
          ? const Center(child: CircularProgressIndicator(color: Color(0xFFC9A433)))
          : FadeTransition(
              opacity: _fade,
              child: _buildContent(),
            ),
    );
  }

  Widget _buildContent() {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _sectionLabel('🗺️  TOP-DOWN  (Navigation View)'),
        const SizedBox(height: 10),
        _topDownPanel(),
        const SizedBox(height: 24),

        _sectionLabel('🚗  FRONT 3/4 ANGLE'),
        const SizedBox(height: 10),
        _perspectivePanel(
          pitchX: -0.52,
          pitchY: 0.18,
          flipY: false,
          mapStyle: true,
          label: 'Front Perspective',
        ),
        const SizedBox(height: 24),

        _sectionLabel('🔴  REAR 3/4 ANGLE'),
        const SizedBox(height: 10),
        _perspectivePanel(
          pitchX: -0.48,
          pitchY: -0.18,
          flipY: true,
          mapStyle: false,
          label: 'Rear Perspective',
        ),
        const SizedBox(height: 32),

        _specCard(),
        const SizedBox(height: 24),
      ],
    );
  }

  // ── Top-Down Panel ────────────────────────────────────────────────────────

  Widget _topDownPanel() {
    return _card(
      child: Stack(
        alignment: Alignment.center,
        children: [
          // Map-tile grid background
          CustomPaint(painter: _MapGridPainter(), child: const SizedBox(height: 320, width: double.infinity)),

          // Route line simulation
          CustomPaint(painter: _RoutePainter()),

          // The actual SUV icon exactly as on the map
          Image.memory(_bytes!, width: 112, height: 192, filterQuality: FilterQuality.high),

          // Compass rose
          Positioned(
            top: 12, right: 12,
            child: _compass(),
          ),

          // Scale bar
          Positioned(
            bottom: 12, left: 12,
            child: _scaleBar(),
          ),

          // GPS label
          Positioned(
            bottom: 12, right: 12,
            child: _gpsTag(),
          ),
        ],
      ),
    );
  }

  // ── Perspective Panel ─────────────────────────────────────────────────────

  Widget _perspectivePanel({
    required double pitchX,
    required double pitchY,
    required bool flipY,
    required bool mapStyle,
    required String label,
  }) {
    final suv = Image.memory(
      _bytes!,
      width: 112,
      height: 192,
      filterQuality: FilterQuality.high,
    );

    final transformed = Transform(
      alignment: Alignment.center,
      transform: Matrix4.identity()
        ..setEntry(3, 2, 0.0018)            // perspective depth
        ..rotateX(pitchX)                   // tilt (look down at front or rear)
        ..rotateY(pitchY),                  // slight left turn for 3/4 view
      child: flipY
          ? Transform(
              alignment: Alignment.center,
              transform: Matrix4.rotationZ(math.pi),
              child: suv,
            )
          : suv,
    );

    return _card(
      child: Stack(
        alignment: Alignment.center,
        children: [
          // Background
          mapStyle
              ? CustomPaint(painter: _MapGridPainter(), child: const SizedBox(height: 300, width: double.infinity))
              : Container(
                  height: 300,
                  decoration: const BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [Color(0xFF1A1D26), Color(0xFF0F1117)],
                    ),
                  ),
                ),

          // Ground shadow
          Positioned(
            bottom: 60,
            child: Container(
              width: 120,
              height: 30,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(60),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.6),
                    blurRadius: 30,
                    spreadRadius: 5,
                  ),
                ],
              ),
            ),
          ),

          // SUV in perspective
          transformed,

          // Label
          Positioned(
            bottom: 14,
            child: Text(
              label,
              style: const TextStyle(
                color: Color(0xFF8A8FA0),
                fontSize: 11,
                letterSpacing: 1.2,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ── Spec Card ─────────────────────────────────────────────────────────────

  Widget _specCard() {
    final specs = [
      ('BODY',      'Dark Anthracite Metallic'),
      ('TRIM',      'Gold Belt-Line Strip'),
      ('ROOF',      'Panoramic Glass Panel'),
      ('LIGHTS',    'LED DRL + Amber Signals'),
      ('TAILLIGHTS','Continuous LED Bar'),
      ('WHEELS',    '5-Spoke + Gold Center Cap'),
      ('CANVAS',    '140 × 240 px  |  PNG'),
      ('SCALE',     '0.38× on Mapbox map'),
    ];

    return Container(
      decoration: BoxDecoration(
        color: _card,
        border: Border.all(color: _border),
        borderRadius: BorderRadius.circular(16),
      ),
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(width: 3, height: 16, color: _gold, margin: const EdgeInsets.only(right: 10)),
              const Text(
                'SUV DESIGN SPECS',
                style: TextStyle(color: Color(0xFFF0F0F5), fontWeight: FontWeight.w700, letterSpacing: 1.4, fontSize: 12),
              ),
            ],
          ),
          const SizedBox(height: 14),
          ...specs.map((s) => Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Row(
              children: [
                SizedBox(
                  width: 88,
                  child: Text(s.$1,
                    style: const TextStyle(color: Color(0xFFC9A433), fontSize: 11, fontWeight: FontWeight.w600, letterSpacing: 1)),
                ),
                Expanded(
                  child: Text(s.$2,
                    style: const TextStyle(color: Color(0xFFB0B4C0), fontSize: 12)),
                ),
              ],
            ),
          )),
        ],
      ),
    );
  }

  // ── Small Helpers ─────────────────────────────────────────────────────────

  Widget _sectionLabel(String text) => Padding(
    padding: const EdgeInsets.only(left: 4, bottom: 2),
    child: Text(text,
      style: const TextStyle(
        color: Color(0xFF8A8FA0),
        fontSize: 11,
        letterSpacing: 1.5,
        fontWeight: FontWeight.w600,
      )),
  );

  Widget _card({required Widget child}) => Container(
    decoration: BoxDecoration(
      color: _card,
      border: Border.all(color: _border),
      borderRadius: BorderRadius.circular(16),
      boxShadow: [
        BoxShadow(color: Colors.black.withOpacity(0.4), blurRadius: 20, offset: const Offset(0, 6)),
      ],
    ),
    clipBehavior: Clip.hardEdge,
    child: child,
  );

  Widget _compass() => Container(
    width: 36, height: 36,
    decoration: BoxDecoration(
      color: Colors.black.withOpacity(0.6),
      shape: BoxShape.circle,
      border: Border.all(color: _border),
    ),
    child: const Center(
      child: Text('N', style: TextStyle(color: Color(0xFFC9A433), fontSize: 12, fontWeight: FontWeight.w900)),
    ),
  );

  Widget _scaleBar() => Row(
    children: [
      Container(width: 40, height: 3, color: _gold),
      const SizedBox(width: 4),
      const Text('50m', style: TextStyle(color: Color(0xFF8A8FA0), fontSize: 10)),
    ],
  );

  Widget _gpsTag() => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
    decoration: BoxDecoration(
      color: Colors.black.withOpacity(0.5),
      borderRadius: BorderRadius.circular(8),
      border: Border.all(color: _border),
    ),
    child: const Text('GPS 60fps', style: TextStyle(color: Color(0xFF4CAF50), fontSize: 10, fontWeight: FontWeight.w600)),
  );
}

// ── Painters ─────────────────────────────────────────────────────────────────

class _MapGridPainter extends CustomPainter {
  static const _gridColor = Color(0xFF1E2130);
  static const _roadColor = Color(0xFF22263A);
  static const _streetColor = Color(0xFF2A2F48);

  @override
  void paint(Canvas canvas, Size size) {
    final bg = Paint()..color = const Color(0xFF161924);
    canvas.drawRect(Rect.fromLTWH(0, 0, size.width, size.height), bg);

    // Grid lines (city blocks)
    final gridPaint = Paint()..color = _gridColor..strokeWidth = 0.5;
    for (double x = 0; x < size.width; x += 28) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), gridPaint);
    }
    for (double y = 0; y < size.height; y += 28) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), gridPaint);
    }

    // Horizontal road (thick)
    final roadPaint = Paint()..color = _roadColor;
    canvas.drawRect(Rect.fromLTWH(0, size.height / 2 - 24, size.width, 48), roadPaint);

    // Vertical road
    canvas.drawRect(Rect.fromLTWH(size.width / 2 - 18, 0, 36, size.height), roadPaint);

    // Road center line dashes
    final dashPaint = Paint()
      ..color = const Color(0xFFFFD700).withOpacity(0.15)
      ..strokeWidth = 1.5;
    for (double x = 0; x < size.width; x += 20) {
      canvas.drawLine(
        Offset(x, size.height / 2),
        Offset(x + 10, size.height / 2),
        dashPaint,
      );
    }

    // City blocks (filled rectangles)
    final blockPaint = Paint()..color = _streetColor;
    final blocks = [
      Rect.fromLTWH(8, 8, size.width / 2 - 30, size.height / 2 - 32),
      Rect.fromLTWH(size.width / 2 + 26, 8, size.width / 2 - 34, size.height / 2 - 32),
      Rect.fromLTWH(8, size.height / 2 + 32, size.width / 2 - 30, size.height / 2 - 40),
      Rect.fromLTWH(size.width / 2 + 26, size.height / 2 + 32, size.width / 2 - 34, size.height / 2 - 40),
    ];
    for (final b in blocks) {
      canvas.drawRRect(RRect.fromRectAndRadius(b, const Radius.circular(4)), blockPaint);
    }
  }

  @override
  bool shouldRepaint(_) => false;
}

class _RoutePainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    // Blue navigation route line going straight through car
    final routePaint = Paint()
      ..color = const Color(0xFF4A90E2).withOpacity(0.8)
      ..strokeWidth = 8
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;

    final path = Path()
      ..moveTo(size.width / 2, size.height)
      ..lineTo(size.width / 2, 0);

    canvas.drawPath(path, routePaint);

    // White center line on route
    final centerLine = Paint()
      ..color = Colors.white.withOpacity(0.15)
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke;
    canvas.drawPath(path, centerLine);
  }

  @override
  bool shouldRepaint(_) => false;
}
