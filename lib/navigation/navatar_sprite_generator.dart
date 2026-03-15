import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

// 3D vector
class _V3 {
  final double x, y, z;
  const _V3(this.x, this.y, this.z);
  _V3 operator -(_V3 o) => _V3(x - o.x, y - o.y, z - o.z);
}

_V3 _cross(_V3 a, _V3 b) =>
    _V3(a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x);
double _dot(_V3 a, _V3 b) => a.x * b.x + a.y * b.y + a.z * b.z;
_V3 _norm(_V3 v) {
  final l = math.sqrt(v.x * v.x + v.y * v.y + v.z * v.z);
  return l > 1e-6 ? _V3(v.x / l, v.y / l, v.z / l) : const _V3(0, 1, 0);
}

_V3 _rotY(_V3 v, double r) {
  final c = math.cos(r), s = math.sin(r);
  return _V3(v.x * c + v.z * s, v.y, -v.x * s + v.z * c);
}

class _F3 {
  final List<_V3> v;
  final Color c;
  final String t;
  const _F3(this.v, this.c, this.t);
}

class _PF {
  final List<Offset> p;
  final double d, b;
  final Color c;
  final String t;
  const _PF(this.p, this.d, this.b, this.c, this.t);
}

/// Generates 8 Google-Maps-style 3D car sprites using real projection.
class NavatarSpriteGenerator {
  NavatarSpriteGenerator._();

  static const double _sc = 3.0;
  static const double _sz = 160.0;
  static double get _ps => _sz * _sc;

  // Camera 55° tilt = 35° elevation
  static final double _ce = math.cos(35 * math.pi / 180);
  static final double _se = math.sin(35 * math.pi / 180);
  static final _V3 _vd = _norm(_V3(0, -_ce, _se));
  static final _V3 _ld = _norm(const _V3(-0.35, 0.75, 0.45));

  static Future<List<BitmapDescriptor>> generateDescriptors() async {
    final bytes = await generateAll();
    // ignore: deprecated_member_use
    return bytes.map((b) => BitmapDescriptor.fromBytes(b)).toList();
  }

  static Future<List<Uint8List>> generateAll() async {
    final r = <Uint8List>[];
    for (final a in [0, 45, 90, 135, 180, 225, 270, 315]) {
      r.add(await renderAngle(a.toDouble()));
    }
    return r;
  }

  static Future<Uint8List> renderAngle(double deg) async {
    final s = _ps;
    final pi = s.toInt();
    final cx = s / 2, cy = s / 2;
    final rad = deg * math.pi / 180;
    final rec = ui.PictureRecorder();
    final cvs = Canvas(rec, Rect.fromLTWH(0, 0, s, s));

    final faces = _car();
    final vis = <_PF>[];
    for (final f in faces) {
      final rv = f.v.map((v) => _rotY(v, rad)).toList();
      final n = _fn(rv);
      if (_dot(n, _vd) > 0.08) continue;
      final pts = rv.map((v) {
        return Offset(cx + v.x * _sc, cy - (v.y * _ce - v.z * _se) * _sc);
      }).toList();
      final dp = rv.map((v) => v.y * _se + v.z * _ce).reduce((a, b) => a + b) / rv.length;
      vis.add(_PF(pts, dp, 0.35 + 0.65 * _dot(n, _ld).clamp(0.0, 1.0), f.c, f.t));
    }
    vis.sort((a, b) => a.d.compareTo(b.d));

    _shadow(cvs, cx, cy);
    for (final f in vis) {
      _draw(cvs, f);
    }

    final pic = rec.endRecording();
    final img = await pic.toImage(pi, pi);
    final data = await img.toByteData(format: ui.ImageByteFormat.png);
    img.dispose();
    return data!.buffer.asUint8List();
  }

  static _V3 _fn(List<_V3> v) {
    if (v.length < 3) return const _V3(0, 1, 0);
    return _norm(_cross(v[1] - v[0], v[v.length - 1] - v[0]));
  }

  static void _shadow(Canvas c, double cx, double cy) {
    c.drawOval(
      Rect.fromCenter(center: Offset(cx, cy + 18 * _sc), width: 46 * 2.4 * _sc, height: 50 * 1.2 * _sc * _se),
      Paint()..color = const Color(0x60000000)..maskFilter = const MaskFilter.blur(BlurStyle.normal, 20),
    );
    c.drawOval(
      Rect.fromCenter(center: Offset(cx, cy + 14 * _sc), width: 46 * 1.8 * _sc, height: 50 * 0.9 * _sc * _se),
      Paint()..color = const Color(0x80000000)..maskFilter = const MaskFilter.blur(BlurStyle.normal, 8),
    );
  }

  static Color _lit(Color c, double b) {
    final a = (c.a * 255).round().clamp(0, 255);
    final r = (c.r * 255 * b).round().clamp(0, 255);
    final g = (c.g * 255 * b).round().clamp(0, 255);
    final bl = (c.b * 255 * b).round().clamp(0, 255);
    return Color.fromARGB(a, r, g, bl);
  }

  static Offset _ctr(List<Offset> p) {
    double x = 0, y = 0;
    for (final o in p) {
      x += o.dx;
      y += o.dy;
    }
    return Offset(x / p.length, y / p.length);
  }

  static void _draw(Canvas cvs, _PF f) {
    if (f.p.length < 3) return;
    final path = Path()..moveTo(f.p[0].dx, f.p[0].dy);
    for (int i = 1; i < f.p.length; i++) {
      path.lineTo(f.p[i].dx, f.p[i].dy);
    }
    path.close();

    final col = _lit(f.c, f.b);
    cvs.drawPath(path, Paint()..color = col..isAntiAlias = true);

    if (f.t.startsWith('glass')) {
      final ct = _ctr(f.p);
      cvs.drawLine(
        Offset(ct.dx - 12, ct.dy), Offset(ct.dx + 12, ct.dy),
        Paint()..color = const Color(0x28FFFFFF)..strokeWidth = 2..strokeCap = StrokeCap.round..isAntiAlias = true,
      );
    } else if (f.t == 'lf') {
      cvs.drawCircle(_ctr(f.p), 7, Paint()..color = const Color(0x40FFFDE0)..maskFilter = const MaskFilter.blur(BlurStyle.normal, 5));
    } else if (f.t == 'lr') {
      cvs.drawCircle(_ctr(f.p), 7, Paint()..color = const Color(0x50FF2020)..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4));
    } else if (f.t == 'roof') {
      cvs.drawOval(Rect.fromCenter(center: _ctr(f.p), width: 28, height: 16),
        Paint()..color = const Color(0x24FFFFFF)..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4));
    } else if (f.t == 'hood') {
      final ct = _ctr(f.p);
      final mn = f.p.map((p) => p.dy).reduce(math.min);
      final mx = f.p.map((p) => p.dy).reduce(math.max);
      cvs.drawLine(Offset(ct.dx, mn + 3), Offset(ct.dx, mx - 3),
        Paint()..color = const Color(0x14FFFFFF)..strokeWidth = 1.2..strokeCap = StrokeCap.round..isAntiAlias = true);
    }

    cvs.drawPath(path, Paint()..color = const Color(0x14000000)..style = PaintingStyle.stroke..strokeWidth = 0.7..isAntiAlias = true);
  }

  // Car model — dark premium sedan (BMW/Audi style)
  static List<_F3> _car() {
    const hw = 24.0, fl = 52.0, rl = 52.0, bh = 17.0;
    const fhw = hw * 0.84, rhw = hw * 0.96;
    // Dark navy body
    const cb = Color(0xFF161A24);
    // Blue-tinted glass
    const cg = Color(0xFF1A3858);
    // Hood (slightly lighter than body)
    const ch = Color(0xFF1E2230);
    // Trunk
    const ct = Color(0xFF181C24);
    // Roof (dark with subtle blue)
    const cr = Color(0xFF222838);
    // Front/rear panels (darkest)
    const cbm = Color(0xFF0E1018);
    // Tire rubber
    const cw = Color(0xFF0C0C10);
    // Silver rim
    const cwRim = Color(0xFF707880);
    // Headlights (bright white)
    const clf = Color(0xFFFFFFFF);
    // Taillights (bright red)
    const clr = Color(0xFFFF2020);

    return [
      // Body sides
      _F3([_V3(-fhw,2,fl),_V3(-hw,2,0),_V3(-rhw,2,-rl),_V3(-rhw,bh,-rl),_V3(-hw,bh,0),_V3(-fhw,bh,fl)], cb, 'body'),
      _F3([_V3(rhw,2,-rl),_V3(hw,2,0),_V3(fhw,2,fl),_V3(fhw,bh,fl),_V3(hw,bh,0),_V3(rhw,bh,-rl)], cb, 'body'),
      // Front/rear
      _F3([_V3(-fhw,2,fl),_V3(fhw,2,fl),_V3(fhw,bh,fl),_V3(-fhw,bh,fl)], cbm, 'bf'),
      _F3([_V3(rhw,2,-rl),_V3(-rhw,2,-rl),_V3(-rhw,bh,-rl),_V3(rhw,bh,-rl)], cbm, 'br'),
      // Hood
      _F3([_V3(-fhw*0.95,bh,fl),_V3(fhw*0.95,bh,fl),_V3(hw*0.88,bh+2,20),_V3(-hw*0.88,bh+2,20)], ch, 'hood'),
      // Windshield
      _F3([_V3(-hw*0.82,bh+2,20),_V3(hw*0.82,bh+2,20),_V3(hw*0.72,31,9),_V3(-hw*0.72,31,9)], cg, 'glass'),
      // Roof
      _F3([_V3(-hw*0.70,33,9),_V3(hw*0.70,33,9),_V3(hw*0.68,33,-14),_V3(-hw*0.68,33,-14)], cr, 'roof'),
      // Rear window
      _F3([_V3(-hw*0.68,33,-14),_V3(hw*0.68,33,-14),_V3(hw*0.78,bh+1,-24),_V3(-hw*0.78,bh+1,-24)], cg, 'glass_r'),
      // Trunk
      _F3([_V3(-hw*0.80,bh+1,-24),_V3(hw*0.80,bh+1,-24),_V3(rhw*0.92,bh,-rl),_V3(-rhw*0.92,bh,-rl)], ct, 'trunk'),
      // Side windows
      _F3([_V3(-hw-0.5,bh+3,7),_V3(-hw-0.5,bh+3,-12),_V3(-hw-0.5,29,-12),_V3(-hw-0.5,29,7)], cg, 'glass_s'),
      _F3([_V3(hw+0.5,bh+3,-12),_V3(hw+0.5,bh+3,7),_V3(hw+0.5,29,7),_V3(hw+0.5,29,-12)], cg, 'glass_s'),
      // Headlights (larger, brighter)
      _F3([_V3(-fhw*0.78-7,bh*0.55,fl+.5),_V3(-fhw*0.78+1,bh*0.55,fl+.5),_V3(-fhw*0.78+1,bh*0.55+5,fl+.5),_V3(-fhw*0.78-7,bh*0.55+5,fl+.5)], clf, 'lf'),
      _F3([_V3(fhw*0.78-1,bh*0.55,fl+.5),_V3(fhw*0.78+7,bh*0.55,fl+.5),_V3(fhw*0.78+7,bh*0.55+5,fl+.5),_V3(fhw*0.78-1,bh*0.55+5,fl+.5)], clf, 'lf'),
      // Taillights (larger, brighter red)
      _F3([_V3(-rhw*0.78,bh*0.5,-rl-.5),_V3(-rhw*0.78+8,bh*0.5,-rl-.5),_V3(-rhw*0.78+8,bh*0.5+5.5,-rl-.5),_V3(-rhw*0.78,bh*0.5+5.5,-rl-.5)], clr, 'lr'),
      _F3([_V3(rhw*0.78-8,bh*0.5,-rl-.5),_V3(rhw*0.78,bh*0.5,-rl-.5),_V3(rhw*0.78,bh*0.5+5.5,-rl-.5),_V3(rhw*0.78-8,bh*0.5+5.5,-rl-.5)], clr, 'lr'),
      // Front wheels — tire (outer face)
      _F3([_V3(-hw-6,0,fl*0.52-6),_V3(-hw,0,fl*0.52-6),_V3(-hw,8,fl*0.52-6),_V3(-hw-6,8,fl*0.52-6)], cw, 'w'),
      _F3([_V3(hw,0,fl*0.52-6),_V3(hw+6,0,fl*0.52-6),_V3(hw+6,8,fl*0.52-6),_V3(hw,8,fl*0.52-6)], cw, 'w'),
      // Rear wheels — tire (outer face)
      _F3([_V3(-hw-6,0,-rl*0.52-6),_V3(-hw,0,-rl*0.52-6),_V3(-hw,8,-rl*0.52-6),_V3(-hw-6,8,-rl*0.52-6)], cw, 'w'),
      _F3([_V3(hw,0,-rl*0.52-6),_V3(hw+6,0,-rl*0.52-6),_V3(hw+6,8,-rl*0.52-6),_V3(hw,8,-rl*0.52-6)], cw, 'w'),
      // Wheel side faces (tire sides)
      _F3([_V3(-hw-6,0,fl*0.52+6),_V3(-hw-6,0,fl*0.52-6),_V3(-hw-6,8,fl*0.52-6),_V3(-hw-6,8,fl*0.52+6)], cw, 'w'),
      _F3([_V3(hw+6,0,fl*0.52-6),_V3(hw+6,0,fl*0.52+6),_V3(hw+6,8,fl*0.52+6),_V3(hw+6,8,fl*0.52-6)], cw, 'w'),
      _F3([_V3(-hw-6,0,-rl*0.52+6),_V3(-hw-6,0,-rl*0.52-6),_V3(-hw-6,8,-rl*0.52-6),_V3(-hw-6,8,-rl*0.52+6)], cw, 'w'),
      _F3([_V3(hw+6,0,-rl*0.52-6),_V3(hw+6,0,-rl*0.52+6),_V3(hw+6,8,-rl*0.52+6),_V3(hw+6,8,-rl*0.52-6)], cw, 'w'),
      // Wheel rim faces (silver — visible from side)
      _F3([_V3(-hw-6,1.5,fl*0.52-4),_V3(-hw-1,1.5,fl*0.52-4),_V3(-hw-1,6.5,fl*0.52-4),_V3(-hw-6,6.5,fl*0.52-4)], cwRim, 'rim'),
      _F3([_V3(hw+1,1.5,fl*0.52-4),_V3(hw+6,1.5,fl*0.52-4),_V3(hw+6,6.5,fl*0.52-4),_V3(hw+1,6.5,fl*0.52-4)], cwRim, 'rim'),
      _F3([_V3(-hw-6,1.5,-rl*0.52-4),_V3(-hw-1,1.5,-rl*0.52-4),_V3(-hw-1,6.5,-rl*0.52-4),_V3(-hw-6,6.5,-rl*0.52-4)], cwRim, 'rim'),
      _F3([_V3(hw+1,1.5,-rl*0.52-4),_V3(hw+6,1.5,-rl*0.52-4),_V3(hw+6,6.5,-rl*0.52-4),_V3(hw+1,6.5,-rl*0.52-4)], cwRim, 'rim'),
      // Rim side faces
      _F3([_V3(-hw-6,1.5,fl*0.52+4),_V3(-hw-6,1.5,fl*0.52-4),_V3(-hw-6,6.5,fl*0.52-4),_V3(-hw-6,6.5,fl*0.52+4)], cwRim, 'rim'),
      _F3([_V3(hw+6,1.5,fl*0.52-4),_V3(hw+6,1.5,fl*0.52+4),_V3(hw+6,6.5,fl*0.52+4),_V3(hw+6,6.5,fl*0.52-4)], cwRim, 'rim'),
      _F3([_V3(-hw-6,1.5,-rl*0.52+4),_V3(-hw-6,1.5,-rl*0.52-4),_V3(-hw-6,6.5,-rl*0.52-4),_V3(-hw-6,6.5,-rl*0.52+4)], cwRim, 'rim'),
      _F3([_V3(hw+6,1.5,-rl*0.52-4),_V3(hw+6,1.5,-rl*0.52+4),_V3(hw+6,6.5,-rl*0.52+4),_V3(hw+6,6.5,-rl*0.52-4)], cwRim, 'rim'),
    ];
  }
}
