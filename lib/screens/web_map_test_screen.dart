// TEMPORARY web-map smoke test — DELETE after the web map migration lands.
//
// Cómo abrirla SIN tocar la navegación principal (2 opciones):
//
//   1) Entrada dedicada (recomendada):
//        flutter run -d web-server --web-port=5000 \
//          -t lib/screens/web_map_test_screen.dart \
//          --dart-define=MAPBOX_TOKEN=pk.tu_token
//
//   2) Temporalmente dentro de la app: añade un botón oculto que haga
//        Navigator.push(context, MaterialPageRoute(
//          builder: (_) => const WebMapTestScreen()));
//
// NO conectar a rutas de producción.

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../config/mapbox_config.dart';
import '../map/web_map_view.dart';

void main() => runApp(const _WebMapTestApp());

class _WebMapTestApp extends StatelessWidget {
  const _WebMapTestApp();

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      debugShowCheckedModeBanner: false,
      home: WebMapTestScreen(),
    );
  }
}

/// Pantalla demo a pantalla completa: 2 markers custom, polyline, círculo
/// y botones para flyTo / fitBounds / setStyle / tema navy-gold.
class WebMapTestScreen extends StatefulWidget {
  const WebMapTestScreen({super.key});

  @override
  State<WebMapTestScreen> createState() => _WebMapTestScreenState();
}

class _WebMapTestScreenState extends State<WebMapTestScreen> {
  // Santo Domingo, RD — zona de operación de Cruise.
  static const _pointA = (lng: -69.9312, lat: 18.4861);
  static const _pointB = (lng: -69.8465, lat: 18.4534);

  WebMapController? _map;
  bool _ready = false;
  bool _dark = true;

  /// assets/markers/ está vacío, así que generamos un pin dorado en runtime.
  Future<Uint8List> _pinPng(Color color) async {
    const size = 96.0;
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    canvas.drawCircle(
      const Offset(size / 2, size / 2),
      size / 2 - 4,
      Paint()..color = color,
    );
    canvas.drawCircle(
      const Offset(size / 2, size / 2),
      size / 2 - 4,
      Paint()
        ..color = Colors.white
        ..style = PaintingStyle.stroke
        ..strokeWidth = 6,
    );
    final image =
        await recorder.endRecording().toImage(size.toInt(), size.toInt());
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    return bytes!.buffer.asUint8List();
  }

  Future<void> _populate(WebMapController map) async {
    map.applyNavyGoldTheme();
    final goldPin = await _pinPng(const Color(0xFFD4AF37));
    final bluePin = await _pinPng(const Color(0xFF4A90D9));
    map.addMarker('pickup', _pointA.lng, _pointA.lat, iconBytes: goldPin);
    map.addMarker('dropoff', _pointB.lng, _pointB.lat, iconBytes: bluePin);
    map.setPolyline('route', const [_pointA, _pointB]);
    map.setCircle('pickup-radius', _pointA.lng, _pointA.lat, radiusPx: 80);
    map.fitBounds(const [_pointA, _pointB]);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0A1128),
      body: Stack(
        children: [
          Positioned.fill(
            child: WebMapView(
              initialLng: _pointA.lng,
              initialLat: _pointA.lat,
              initialZoom: 12,
              styleUri: MapboxConfig.styleDark,
              onControllerCreated: (controller) {
                _map = controller;
                controller.onReady = () {
                  setState(() => _ready = true);
                  _populate(controller);
                };
                controller.onMapTap = (lng, lat) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text(
                        'Tap: ${lat.toStringAsFixed(5)}, ${lng.toStringAsFixed(5)}',
                      ),
                      duration: const Duration(seconds: 1),
                    ),
                  );
                };
              },
            ),
          ),
          if (!_ready)
            const ColoredBox(
              color: Color(0xFF0A1128),
              child: Center(
                child: CircularProgressIndicator(color: Color(0xFFD4AF37)),
              ),
            ),
          Positioned(
            left: 16,
            right: 16,
            bottom: 24,
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              alignment: WrapAlignment.center,
              children: [
                _btn('flyTo A', () {
                  _map?.flyTo(
                      lng: _pointA.lng, lat: _pointA.lat, zoom: 15);
                }),
                _btn('flyTo B', () {
                  _map?.flyTo(
                      lng: _pointB.lng, lat: _pointB.lat, zoom: 15);
                }),
                _btn('fitBounds', () {
                  _map?.fitBounds(const [_pointA, _pointB]);
                }),
                _btn(_dark ? 'Style: light' : 'Style: dark', () {
                  _dark = !_dark;
                  _map?.setStyle(_dark
                      ? 'mapbox://styles/mapbox/dark-v11'
                      : 'mapbox://styles/mapbox/light-v11');
                }),
                _btn('Tema navy/gold', () {
                  _map?.applyNavyGoldTheme();
                }),
                _btn('Mover marker', () {
                  final m = _map;
                  if (m == null) return;
                  // Pequeño salto para probar updateMarkerPosition + rotación.
                  m.updateMarkerPosition(
                    'pickup',
                    _pointA.lng + 0.01,
                    _pointA.lat + 0.005,
                    rotation: 45,
                  );
                }),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _btn(String label, VoidCallback onPressed) {
    return ElevatedButton(
      style: ElevatedButton.styleFrom(
        backgroundColor: const Color(0xFF1A2B4D),
        foregroundColor: const Color(0xFFD4AF37),
      ),
      onPressed: _ready ? onPressed : null,
      child: Text(label),
    );
  }
}
