import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';

/// Animated illustration of an identity document sitting inside a scan frame.
///
/// Shown on the guidelines step, *before* the camera opens, so the rider knows
/// what the app is about to ask for. Everything is painted — there is no asset
/// for this and no emoji — which keeps it crisp at any [height] and lets the
/// three document variants share one composition.
///
/// The visual language (gold L-shaped corner brackets, cruise gold `#E8C547`)
/// deliberately matches `_CornerPainter` in the live scanner screen so the
/// preview and the real camera overlay read as the same object.
///
/// Reduced motion is honoured: when `MediaQuery.disableAnimations` is on the
/// controller never runs and a single representative frame is painted.
class DocScanIllustration extends StatefulWidget {
  const DocScanIllustration({super.key, required this.docType, this.height = 200});

  /// `'license'` | `'government_id'` | `'passport'`. Anything else — including
  /// the empty string the screen starts with — falls back to the license look.
  final String docType;

  /// Logical height of the whole illustration (card + brackets). The width
  /// follows from the variant's aspect ratio.
  final double height;

  @override
  State<DocScanIllustration> createState() => _DocScanIllustrationState();
}

/// One full sweep + breathing room, in the 2.5–3.5 s band asked for.
const Duration _kCycle = Duration(milliseconds: 3000);

/// Frame rendered when animations are disabled: sweep at mid-card, brackets at
/// the top of their pulse. Reads as a deliberate still, not a broken start.
const double _kStaticFrame = 0.40;

/// Fraction of the cycle the sweep is travelling; the remainder is the gap that
/// makes the loop seam invisible.
const double _kTravel = 0.80;

/// Padding around the card, as a fraction of the total height. This is the room
/// the corner brackets stand off into.
const double _kPadFrac = 0.085;

/// Cruise gold — same constant the identity screen and its scanner overlay use.
const Color _kGold = Color(0xFFE8C547);

/// Document paper, shared by both landscape variants: warm beige body with a
/// slightly darker band across the lower third.
const Color _kCardBase = Color(0xFFE8DDD0);
const Color _kCardLower = Color(0xFFCBB89E);

class _DocScanIllustrationState extends State<DocScanIllustration>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  bool _reducedMotion = false;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this, duration: _kCycle);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncMotion();
  }

  /// Starts or parks the loop according to the platform's reduced-motion flag.
  /// Called from `didChangeDependencies` so it re-evaluates if the user flips
  /// the accessibility setting while the page is open.
  void _syncMotion() {
    // Rule 26: `maybeOf`, never `.of`, for MediaQuery lookups.
    final reduced = MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    _reducedMotion = reduced;
    if (reduced) {
      if (_controller.isAnimating) _controller.stop();
      _controller.value = _kStaticFrame;
    } else if (!_controller.isAnimating) {
      _controller.repeat();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final spec = _DocSpec.forType(widget.docType);
    final s = S.of(context);

    // Defensive: a zero/NaN height would produce a negative SizedBox.
    final height = (widget.height.isFinite && widget.height > 0) ? widget.height : 200.0;
    final naturalWidth = _naturalWidth(height, spec.aspect);

    return Semantics(
      image: true,
      label: spec.label(s),
      child: LayoutBuilder(
        builder: (context, constraints) {
          var w = naturalWidth;
          var h = height;
          // On a narrow phone the landscape card can be wider than the column
          // it lives in. Scale the whole thing down rather than overflow.
          if (constraints.hasBoundedWidth &&
              constraints.maxWidth > 0 &&
              constraints.maxWidth < w) {
            final k = constraints.maxWidth / w;
            w *= k;
            h *= k;
          }
          return SizedBox(
            width: w,
            height: h,
            child: RepaintBoundary(
              child: AnimatedBuilder(
                animation: _controller,
                builder: (context, _) => CustomPaint(
                  size: Size(w, h),
                  isComplex: true,
                  willChange: !_reducedMotion,
                  painter: _DocScanPainter(spec: spec, t: _controller.value),
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  static double _naturalWidth(double height, double aspect) {
    final pad = height * _kPadFrac;
    return (height - pad * 2) * aspect + pad * 2;
  }
}

// ---------------------------------------------------------------------------
// Variant description
// ---------------------------------------------------------------------------

enum _Glyph { steeringWheel, idBadge, globe }

/// Everything that differs between the three document types. Instances are
/// canonical per [kind], so repaint comparison only needs to compare [kind].
@immutable
class _DocSpec {
  const _DocSpec({
    required this.kind,
    required this.aspect,
    required this.glyph,
    this.header = const Color(0xFFF4EDE3),
    this.accent = const Color(0xFFD9A441),
    this.stateLine = const Color(0xFFC6B69E),
  });

  /// Normalised kind: `license` | `government_id` | `passport`.
  final String kind;

  /// Card body aspect ratio (width / height). > 1 landscape, < 1 portrait.
  final double aspect;

  final _Glyph glyph;
  final Color header;
  final Color accent;
  final Color stateLine;

  bool get isPassport => kind == 'passport';

  String label(S s) {
    switch (kind) {
      case 'passport':
        return s.passport;
      case 'government_id':
        return s.governmentId;
      default:
        return s.driversLicense;
    }
  }

  /// ID-1 card ratio (85.6 × 54 mm) for the two landscape documents.
  static const _license = _DocSpec(
    kind: 'license',
    aspect: 1.586,
    glyph: _Glyph.steeringWheel,
  );

  /// Same card, cool blue header + blue accent so it never reads as a license.
  static const _governmentId = _DocSpec(
    kind: 'government_id',
    aspect: 1.586,
    glyph: _Glyph.idBadge,
    header: Color(0xFFC6D6E2),
    accent: Color(0xFF4E7C9B),
    stateLine: Color(0xFF93A9B9),
  );

  /// Booklet cover: taller than wide, navy, gold emblem.
  static const _passport = _DocSpec(
    kind: 'passport',
    aspect: 0.72,
    glyph: _Glyph.globe,
  );

  /// Never throws and never returns null — an unknown or empty string is a
  /// license. The identity screen starts with `_docType == ''`.
  static _DocSpec forType(String? raw) {
    switch ((raw ?? '').trim().toLowerCase()) {
      case 'passport':
        return _passport;
      case 'government_id':
      case 'government-id':
      case 'gov_id':
      case 'id':
        return _governmentId;
      default:
        return _license;
    }
  }
}

// ---------------------------------------------------------------------------
// Painter
// ---------------------------------------------------------------------------

class _DocScanPainter extends CustomPainter {
  const _DocScanPainter({required this.spec, required this.t});

  final _DocSpec spec;

  /// Cycle position, 0..1.
  final double t;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width <= 0 || size.height <= 0) return;

    // CustomPaint does not clip, and the bracket glow is a wide blurred
    // stroke that starts only ~7 px inside the edge — it was bleeding gold
    // onto whatever sits next to the widget. Clip to our own box.
    canvas.clipRect(Offset.zero & size);

    final pad = size.height * _kPadFrac;
    final card = Rect.fromLTWH(
      pad,
      pad,
      math.max(size.width - pad * 2, 1.0),
      math.max(size.height - pad * 2, 1.0),
    );
    final radius = math.min(card.width, card.height) * 0.075;
    final rrect = RRect.fromRectAndRadius(card, Radius.circular(radius));

    // Contact shadow so the document sits on the page instead of floating flat.
    canvas.drawRRect(
      rrect.shift(Offset(0, card.height * 0.03)),
      Paint()
        ..color = Colors.black.withValues(alpha: 0.38)
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, card.height * 0.05),
    );

    canvas.save();
    canvas.clipRRect(rrect);
    if (spec.isPassport) {
      _paintPassport(canvas, card);
    } else {
      _paintLandscapeCard(canvas, card);
    }
    _paintSweep(canvas, card);
    canvas.restore();

    // Hairline edge to keep the beige from bleeding into the dark page.
    canvas.drawRRect(
      rrect,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = Colors.black.withValues(alpha: 0.28),
    );

    _paintBrackets(canvas, size, card);
  }

  // -- landscape card (license / government id) -----------------------------

  void _paintLandscapeCard(Canvas canvas, Rect card) {
    final w = card.width;
    final h = card.height;
    double lx(double f) => card.left + w * f;
    double ly(double f) => card.top + h * f;

    // Body, then the slightly darker lower band that makes it read as a real
    // license layout rather than a blank rectangle.
    canvas.drawRect(card, Paint()..color = _kCardBase);
    canvas.drawRect(
      Rect.fromLTRB(card.left, ly(0.68), card.right, card.bottom),
      Paint()..color = _kCardLower,
    );

    // Header band + accent hairline + the pale "state name" block.
    canvas.drawRect(
      Rect.fromLTRB(card.left, card.top, card.right, ly(0.20)),
      Paint()..color = spec.header,
    );
    canvas.drawRect(
      Rect.fromLTRB(card.left, ly(0.20) - h * 0.014, card.right, ly(0.20)),
      Paint()..color = spec.accent,
    );
    _roundedBar(
      canvas,
      Rect.fromLTWH(lx(0.055), ly(0.058), w * 0.32, h * 0.078),
      spec.stateLine,
    );

    // Portrait placeholder.
    final side = h * 0.38;
    final portrait = Rect.fromLTWH(lx(0.06), ly(0.26), side, side);
    _paintPortrait(canvas, portrait);

    // Printed data lines to the right of the portrait.
    const widths = <double>[1.0, 0.68, 0.88, 0.5, 0.74];
    final barLeft = portrait.right + w * 0.05;
    final avail = math.max(card.right - w * 0.06 - barLeft, 1.0);
    final barH = h * 0.055;
    final step = barH + h * 0.038;
    // One ink for every bar. The variation is in the WIDTHS; an earlier
    // version faded the last two "because they sit on the darker band",
    // which they do not — the band starts at 0.68h and the lowest bar ends
    // at 0.677h. It was fading them against the same background as the rest.
    final ink = const Color(0xFF4A3B2A);
    for (var i = 0; i < widths.length; i++) {
      _roundedBar(
        canvas,
        Rect.fromLTWH(barLeft, ly(0.25) + step * i, avail * widths[i], barH),
        ink,
      );
    }

    // Signature scribble under the portrait.
    _paintSignature(
      canvas,
      Rect.fromLTWH(portrait.left, ly(0.74), portrait.width, h * 0.16),
    );

    // Type badge, bottom right.
    final badge = h * 0.21;
    _paintBadge(
      canvas,
      Rect.fromLTWH(card.right - w * 0.055 - badge, ly(0.72), badge, badge),
    );
  }

  /// Flat vector head-and-shoulders inside a square well. Painted shapes only.
  void _paintPortrait(Canvas canvas, Rect box) {
    final r = Radius.circular(box.width * 0.10);
    final well = RRect.fromRectAndRadius(box, r);

    canvas.drawRRect(well, Paint()..color = const Color(0xFFD8CBB8));

    canvas.save();
    canvas.clipRRect(well);

    final s = box.width;
    // Shoulders: top half of an ellipse pushed below the frame.
    canvas.drawArc(
      Rect.fromCenter(
        center: Offset(box.center.dx, box.top + s * 1.02),
        width: s * 0.80,
        height: s * 0.66,
      ),
      math.pi,
      math.pi,
      true,
      Paint()..color = const Color(0xFF5A6B7A),
    );

    final headCenter = Offset(box.center.dx, box.top + s * 0.42);
    final headR = s * 0.185;
    // Hair first as a slightly larger cap, then the face on top of it, then a
    // fringe arc — cheaper than a custom silhouette path and reads cleanly.
    canvas.drawCircle(
      headCenter.translate(0, -headR * 0.10),
      headR * 1.10,
      Paint()..color = const Color(0xFF3A2A20),
    );
    canvas.drawCircle(headCenter, headR, Paint()..color = const Color(0xFFE0B48C));
    canvas.drawArc(
      Rect.fromCircle(center: headCenter.translate(0, -headR * 0.34), radius: headR),
      math.pi,
      math.pi,
      true,
      Paint()..color = const Color(0xFF3A2A20),
    );

    canvas.restore();

    canvas.drawRRect(
      well,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = math.max(box.width * 0.02, 0.8)
        ..color = const Color(0xFFB4A288),
    );
  }

  /// Hand-drawn-looking signature: one continuous bezier scribble.
  void _paintSignature(Canvas canvas, Rect box) {
    final w = box.width;
    final y = box.center.dy;
    final a = box.height * 0.42; // amplitude

    final path = Path()..moveTo(box.left, y + a * 0.25);
    path.cubicTo(
      box.left + w * 0.12, y - a * 1.15,
      box.left + w * 0.24, y + a * 0.95,
      box.left + w * 0.36, y - a * 0.20,
    );
    path.cubicTo(
      box.left + w * 0.46, y - a * 1.20,
      box.left + w * 0.55, y + a * 1.05,
      box.left + w * 0.68, y + a * 0.10,
    );
    path.cubicTo(
      box.left + w * 0.78, y - a * 0.95,
      box.left + w * 0.90, y + a * 0.60,
      box.left + w, y - a * 0.45,
    );

    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = math.max(box.height * 0.11, 1.2)
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..color = const Color(0xFF33291D),
    );
  }

  // -- passport booklet -----------------------------------------------------

  void _paintPassport(Canvas canvas, Rect card) {
    final w = card.width;
    final h = card.height;
    double ly(double f) => card.top + h * f;

    canvas.drawRect(
      card,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF2C3648), Color(0xFF161C26)],
        ).createShader(card),
    );

    // Gold inner rule, the way a cover is embossed.
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        card.deflate(w * 0.055),
        Radius.circular(w * 0.05),
      ),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = math.max(w * 0.008, 1.0)
        ..color = _kGold.withValues(alpha: 0.55),
    );

    // Country line above the emblem.
    _roundedBar(
      canvas,
      Rect.fromCenter(
        center: Offset(card.center.dx, ly(0.16)),
        width: w * 0.46,
        height: h * 0.024,
      ),
      _kGold.withValues(alpha: 0.75),
    );

    // Emblem: a globe, the universal passport mark.
    _paintGlobe(
      canvas,
      Rect.fromCenter(
        center: Offset(card.center.dx, ly(0.40)),
        width: w * 0.42,
        height: w * 0.42,
      ),
      _kGold,
      math.max(w * 0.014, 1.2),
    );

    // Two title lines under it.
    _roundedBar(
      canvas,
      Rect.fromCenter(
        center: Offset(card.center.dx, ly(0.60)),
        width: w * 0.55,
        height: h * 0.022,
      ),
      _kGold.withValues(alpha: 0.85),
    );
    _roundedBar(
      canvas,
      Rect.fromCenter(
        center: Offset(card.center.dx, ly(0.67)),
        width: w * 0.36,
        height: h * 0.018,
      ),
      _kGold.withValues(alpha: 0.55),
    );

    // Type badge, same family as the landscape cards.
    final badge = w * 0.26;
    _paintBadge(
      canvas,
      Rect.fromLTWH(card.right - w * 0.09 - badge, ly(0.785), badge, badge),
    );
  }

  // -- shared bits ----------------------------------------------------------

  void _roundedBar(Canvas canvas, Rect r, Color color) {
    if (r.width <= 0 || r.height <= 0) return;
    canvas.drawRRect(
      RRect.fromRectAndRadius(r, Radius.circular(r.height / 2)),
      Paint()..color = color,
    );
  }

  /// Amber rounded-square badge carrying the per-variant glyph.
  void _paintBadge(Canvas canvas, Rect box) {
    if (box.width <= 0 || box.height <= 0) return;

    final rr = RRect.fromRectAndRadius(box, Radius.circular(box.width * 0.28));
    canvas.drawRRect(rr, Paint()..color = const Color(0xFFE0973A));
    // Top highlight — one paint, keeps it from looking like a flat swatch.
    canvas.save();
    canvas.clipRRect(rr);
    canvas.drawRect(
      Rect.fromLTRB(box.left, box.top, box.right, box.top + box.height * 0.42),
      Paint()..color = Colors.white.withValues(alpha: 0.14),
    );
    canvas.restore();

    const ink = Color(0xFFFFF6E6);
    final glyphBox = Rect.fromCenter(
      center: box.center,
      width: box.width * 0.60,
      height: box.height * 0.60,
    );
    final stroke = math.max(box.width * 0.09, 1.1);

    switch (spec.glyph) {
      case _Glyph.steeringWheel:
        _paintSteeringWheel(canvas, glyphBox, ink, stroke);
      case _Glyph.idBadge:
        _paintIdBadge(canvas, glyphBox, ink, stroke);
      case _Glyph.globe:
        _paintGlobe(canvas, glyphBox, ink, stroke);
    }
  }

  void _paintSteeringWheel(Canvas canvas, Rect box, Color color, double stroke) {
    final c = box.center;
    final r = box.width * 0.46;
    final line = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round
      ..color = color;

    canvas.drawCircle(c, r, line);
    canvas.drawCircle(c, r * 0.30, Paint()..color = color);
    // Spokes at left, right and bottom — the classic wheel read.
    for (final a in <double>[0, math.pi, math.pi / 2]) {
      final dir = Offset(math.cos(a), math.sin(a));
      canvas.drawLine(c + dir * (r * 0.30), c + dir * r, line);
    }
  }

  void _paintIdBadge(Canvas canvas, Rect box, Color color, double stroke) {
    final line = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeJoin = StrokeJoin.round
      ..color = color;
    final fill = Paint()..color = color;

    canvas.drawRRect(
      RRect.fromRectAndRadius(
        box.deflate(box.width * 0.04),
        Radius.circular(box.width * 0.18),
      ),
      line,
    );
    canvas.drawCircle(
      Offset(box.center.dx, box.top + box.height * 0.38),
      box.width * 0.13,
      fill,
    );
    canvas.drawArc(
      Rect.fromCenter(
        center: Offset(box.center.dx, box.top + box.height * 0.78),
        width: box.width * 0.46,
        height: box.height * 0.34,
      ),
      math.pi,
      math.pi,
      true,
      fill,
    );
  }

  void _paintGlobe(Canvas canvas, Rect box, Color color, double stroke) {
    final c = box.center;
    final r = box.width * 0.46;
    final line = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round
      ..color = color;

    canvas.drawCircle(c, r, line);
    canvas.drawOval(
      Rect.fromCenter(center: c, width: r * 0.92, height: r * 2),
      line,
    );
    canvas.drawLine(Offset(c.dx - r, c.dy), Offset(c.dx + r, c.dy), line);
  }

  // -- animation ------------------------------------------------------------

  /// Sweep position 0..1 down the card, or a negative value while the sweep is
  /// resting in the loop gap.
  double get _sweepPos {
    if (t > _kTravel) return -1;
    return Curves.easeInOut.transform((t / _kTravel).clamp(0.0, 1.0));
  }

  /// Bracket pulse 0..1 — peaks as the sweep crosses the middle of the card, so
  /// the brackets breathe *with* the scan rather than on their own clock.
  double get _pulse {
    if (t > _kTravel) return 0.15;
    return 0.15 + 0.85 * math.sin(math.pi * (t / _kTravel).clamp(0.0, 1.0));
  }

  /// Gold scan line + glow, already clipped to the card by the caller.
  void _paintSweep(Canvas canvas, Rect card) {
    final p = _sweepPos;
    if (p < 0) return;

    // Fade in and out at the ends so the loop has no visible seam.
    final alpha = (p < 0.12 ? p / 0.12 : (p > 0.86 ? (1 - p) / 0.14 : 1.0))
        .clamp(0.0, 1.0);
    if (alpha <= 0) return;

    final y = card.top + card.height * p;
    final band = card.height * 0.28;
    final trail = Rect.fromLTRB(
      card.left,
      y - band,
      card.right,
      y + band * 0.30,
    );

    canvas.drawRect(
      trail,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            _kGold.withValues(alpha: 0.0),
            _kGold.withValues(alpha: 0.30 * alpha),
            _kGold.withValues(alpha: 0.0),
          ],
          stops: const [0.0, 0.80, 1.0],
        ).createShader(trail),
    );

    canvas.drawLine(
      Offset(card.left, y),
      Offset(card.right, y),
      Paint()
        ..color = _kGold.withValues(alpha: 0.34 * alpha)
        ..strokeWidth = math.max(card.height * 0.05, 4.0)
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, card.height * 0.035),
    );
    canvas.drawLine(
      Offset(card.left, y),
      Offset(card.right, y),
      Paint()
        ..color = Color.lerp(_kGold, Colors.white, 0.25)!
            .withValues(alpha: 0.95 * alpha)
        ..strokeWidth = math.max(card.height * 0.014, 1.5),
    );
  }

  /// Four gold L brackets standing off the card corners — same two-stroke
  /// construction as `_CornerPainter` in the scanner overlay.
  void _paintBrackets(Canvas canvas, Size size, Rect card) {
    final pulse = _pulse;
    final outer = card.inflate(size.height * _kPadFrac * 0.55);
    final len = math.min(outer.width, outer.height) * (0.20 + 0.015 * pulse);
    final thick = (size.height * 0.026).clamp(4.0, 5.0);

    final path = Path();
    void corner(double x, double y, double dx, double dy) {
      path.moveTo(x, y + len * dy);
      path.lineTo(x, y);
      path.lineTo(x + len * dx, y);
    }

    corner(outer.left, outer.top, 1, 1);
    corner(outer.right, outer.top, -1, 1);
    corner(outer.left, outer.bottom, 1, -1);
    corner(outer.right, outer.bottom, -1, -1);

    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = thick * 1.9
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..color = _kGold.withValues(alpha: 0.10 + 0.20 * pulse)
        // Tight enough that the clip above lands where the halo is already
        // near-transparent, so there is no visible cut at the edge.
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, thick * 0.9),
    );
    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = thick
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..color = _kGold.withValues(alpha: 0.62 + 0.38 * pulse),
    );
  }

  @override
  bool shouldRepaint(_DocScanPainter old) => old.t != t || old.spec.kind != spec.kind;
}
