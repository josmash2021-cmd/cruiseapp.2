import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart' show rootBundle;

import '../utils/smooth_motion.dart';

/// Animated own-location marker for Mapbox map screens.
///
/// Position smoothing is delegated to the canonical [SmoothMotion]
/// (constant-velocity + gentle correction + shortest-arc bearing).
/// The marker is driven by a real vsync [Ticker].
///
/// Two looks, one motion engine:
///
///  * default — the gold dot with a white ring. What a rider sees for
///    themselves: they are somewhere, they are not steering.
///  * [heading] — the navigation badge: black disc, gold ring, white arrow.
///    For the driver screens, where the direction the car is pointing is
///    half of what the marker has to say.
///
/// The arrow is rasterised once pointing north and turned by the map, never
/// redrawn per heading: callers set `iconRotate` on the annotation from
/// [bearing]. Re-encoding a PNG on every GPS fix is not a rotation.
class GoldLocationDot {
  GoldLocationDot({this.heading = false});

  /// Draw the direction arrow instead of the plain dot. Driver screens only.
  final bool heading;

  static const Color _gold = Color(0xFFE8C547);
  static const Color _body = Color(0xFF07070A);
  static const double _canvasSize = 160.0;

  /// Exposed so [GoldLocationDotOverlay] scales into the same coordinate
  /// space the bitmap is drawn in.
  static const double canvasSize = _canvasSize;

  // ── Driver marker size ────────────────────────────────────────────────
  //
  // The arrow is drawn two different ways — a Flutter overlay while the
  // marker is smooth, a Mapbox annotation while it is not — and the driver
  // crosses between them by dragging the map. If the two disagree on size
  // the arrow visibly grows or shrinks at that moment, which reads as a
  // glitch. So both come from one number here.
  //
  // [driverScale] is the only knob: raise it and both techniques follow.

  /// The size the overlay was matched to the annotation at, before scaling.
  static const double _driverBaseSize = 44.0;

  /// How much larger than that baseline the driver's arrow is drawn.
  ///
  /// Remember what this scales: the 44 is the marker's *box*, and the arrow
  /// itself fills a quarter of it — the rest is the room the halo needs to
  /// fade out in. So 1.45 drew a 64 px box with a 16 px arrow in it, which
  /// on a full-screen map the driver glances at while moving was too small
  /// to find. At 2.90 the arrow is 32 px and the box 128 — twice the 16 px
  /// it started at.
  static const double driverScale = 2.90;

  /// Width of the Flutter overlay, in logical pixels.
  static const double driverOverlaySize = _driverBaseSize * driverScale;

  /// `iconSize` for the Mapbox annotation, so it lands at the same size.
  static const double driverIconSize = driverScale;
  /// Outer edge of the marker.
  static const double _dotR = 20.0;
  /// The plain dot is smaller than the badge — it has no arrow to hold.
  static const double _plainDotR = 18.0;

  final SmoothMotion _motion = SmoothMotion();

  /// The rasterised marker, cached for the life of the process.
  ///
  /// There are exactly two of these in the whole app — the plain dot and the
  /// heading badge — and both are constant images. The arrow is drawn once
  /// pointing north and *turned by the map* via `iconRotate`, so nothing
  /// about a driver moving, turning or changing screens changes a pixel.
  ///
  /// Yet every screen that showed a marker rasterised its own copy, and
  /// every one of those was a chance to fail: encoding a PNG needs the GPU,
  /// and the GPU is exactly what is unreliable while backgrounding or under
  /// memory pressure. A failure there left `_frame` null, every draw became
  /// a silent no-op, and the driver's arrow was simply absent until
  /// something retried.
  ///
  /// Keyed by [heading] because that is the only thing that varies. After
  /// the first successful raster of each look, no screen ever rasterises
  /// again — the failure this class kept recovering from can happen at most
  /// once per launch instead of once per screen.
  static final Map<bool, Uint8List> _frameCache = <bool, Uint8List>{};

  // ── The driver badge artwork ──────────────────────────────────────────
  //
  // The badge used to be drawn with three circles and a four-point path.
  // It is a supplied PNG now, decoded once and stamped into the same
  // 40-unit circle those shapes filled — so every size downstream
  // (driverIconSize, driverOverlaySize, the overlay's canvas scale) keeps
  // working off the numbers it already had. Nothing about the marker's
  // dimensions changed; only what is inside the circle.

  /// Decoded once per process. Null until the load finishes, or forever if
  /// it fails — [_paintHeadingBadge] draws the old vector badge in that case.
  static ui.Image? _badgeImage;

  /// Memoises the load, including a failed one. Retrying per frame would
  /// hammer the asset bundle for a file that is not going to appear.
  static Future<void>? _badgeLoad;

  /// Bumped when the artwork lands, so a painter that already drew the
  /// fallback has something to compare and knows to draw again.
  static int _artworkGeneration = 0;

  static Future<void> _ensureBadgeImage() {
    if (_badgeImage != null) return Future<void>.value();
    return _badgeLoad ??= () async {
      try {
        final data = await rootBundle.load('assets/markers/driver_arrow.png');
        final codec = await ui.instantiateImageCodec(data.buffer.asUint8List());
        _badgeImage = (await codec.getNextFrame()).image;
        _artworkGeneration++;
      } catch (e) {
        // Not fatal. The vector badge below is a complete marker on its own,
        // and a driver with no arrow at all is the failure that matters.
        debugPrint('[GoldLocationDot] badge artwork failed to load: $e');
      }
    }();
  }

  Uint8List? _frame;
  Ticker? _ticker;
  Duration _lastElapsed = Duration.zero;
  VoidCallback? _onTick;
  TickerProvider? _vsync;
  bool _isDisposing = false;

  // Throttle annotation redraws to ~30 fps. Mapbox point annotations don't
  // benefit from 60 fps updates and the extra platform-channel traffic can
  // cause micro-stutter on mid-range devices.
  static const int _minTickIntervalMs = 33;
  DateTime? _lastTickAt;

  /// Interpolated position — use this to place the Mapbox annotation.
  double? get lat => _motion.lat;
  double? get lng => _motion.lng;

  /// Smoothed heading in degrees (0 = north). Feed this straight into the
  /// annotation's `iconRotate` — the bitmap is drawn pointing north.
  double get bearing => _motion.bearing;

  bool get isReady => _frame != null;

  Uint8List? get currentBytes => _frame;

  /// Feed each raw GPS fix. The dot glides toward it at the measured
  /// velocity — no jumps, no stalls.
  ///
  /// [bearing] is optional because not every fix carries one: geolocator
  /// reports heading as -1 when the device cannot determine it (stationary,
  /// or no compass), and passing that through would swing the arrow to north
  /// every time the driver stops. Callers should drop invalid headings
  /// rather than forward them.
  /// [accuracyM] is the fix's own reported uncertainty, which sizes the
  /// standstill jitter hold — see SmoothMotion.setTarget.
  void setTarget(double lat, double lng, {double? bearing, double? accuracyM}) =>
      _motion.setTarget(lat, lng, bearing: bearing, accuracyM: accuracyM);

  /// Aim the marker without moving it.
  ///
  /// The compass reports far more often than the GPS, and while the driver
  /// is parked it reports when the GPS has nothing at all to say — so where
  /// the arrow points arrives on its own channel. See HeadingService.
  void setBearing(double bearing) => _motion.setBearing(bearing);

  /// Hard-reset the rendered position (e.g. resuming from background).
  void snapTo(double lat, double lng, {double? bearing}) =>
      _motion.snapTo(lat, lng, bearing: bearing);

  /// Build the dot image once, then start the vsync ticker.
  ///
  /// [vsync] must stay alive for the lifetime of the dot (usually the
  /// hosting [State] with `TickerProviderStateMixin`). [onTick] is called
  /// whenever the position changes and the annotation needs a redraw.
  /// Fired on every frame the marker actually moved, ahead of the throttle.
  ///
  /// [onTick] is rate-limited because it writes to a Mapbox annotation and
  /// that traffic has to be paced. Repainting a Flutter widget does not —
  /// it is the cheapest thing in the frame, and it is what makes the arrow
  /// turn smoothly through a bend instead of in steps. Two callbacks
  /// because they answer to two different constraints.
  VoidCallback? _onFrame;

  Future<void> build(
    TickerProvider vsync,
    VoidCallback onTick, {
    VoidCallback? onFrame,
  }) async {
    _onFrame = onFrame;
    // Re-arm. [dispose] latches _isDisposing and nothing ever cleared it, so
    // the flag outlived the thing it was guarding: the driver screens call
    // dispose() when the app is backgrounded, and on resume this object was
    // permanently deaf. Every later raster hit `if (_isDisposing) return`
    // and dropped the frame, so a marker that had failed to rasterise before
    // the pause could never come back — the arrow was simply gone for the
    // life of the screen. Calling build() is a request to run again.
    _isDisposing = false;

    // The artwork before anything else, because the raster below bakes it in.
    // A badge rasterised while the PNG was still loading would be cached as
    // the vector fallback and stay that way for the rest of the process.
    // Only the heading badge uses it; the plain dot is still all vectors.
    if (heading) await _ensureBadgeImage();

    // Already rasterised once in this process — reuse it. This is the path
    // every screen after the first takes, and it cannot fail: no canvas, no
    // GPU, no await before the marker is ready.
    final cached = _frameCache[heading];
    if (cached != null) {
      _frame = cached;
      _startTicker(vsync, onTick);
      return;
    }


    // Render a single static frame — no sprite atlas, no 90-frame loop.
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(
      recorder,
      const Rect.fromLTWH(0, 0, _canvasSize, _canvasSize),
    );
    const center = Offset(_canvasSize / 2, _canvasSize / 2);

    if (heading) {
      // Baked into the bitmap because Mapbox rotates the whole image and
      // there is nowhere else to put it. The overlay draws its own outside
      // the rotation — see _GoldDotOverlayPainter — so on a turning driver
      // the two differ, and the annotation is only on screen when they have
      // panned away from themselves and are looking at where they were.
      paintHeadingShadow(canvas, center);
      _paintHeadingBadge(canvas, center);
    } else {
      _paintPlainDot(canvas, center);
    }

    // Rasterising can fail (GPU context lost while backgrounding, OOM on
    // low-end devices). Left unguarded it escapes as an unhandled async
    // error AND leaves _frame null forever, so the dot never draws again
    // — callers see currentBytes == null and silently give up.
    try {
      final img = await recorder
          .endRecording()
          .toImage(_canvasSize.toInt(), _canvasSize.toInt());
      final data = await img.toByteData(format: ui.ImageByteFormat.png);
      img.dispose();
      if (data == null || _isDisposing) return;
      _frame = data.buffer.asUint8List();
      _frameCache[heading] = _frame!;
    } catch (e) {
      debugPrint('[GoldLocationDot] frame render failed: $e');
      return; // isReady stays false; the caller may build() again later
    }

    _startTicker(vsync, onTick);
  }

  /// Drive the marker from vsync. Split out of [build] so the cached path
  /// — which does no rasterising at all — starts the ticker the same way.
  void _startTicker(TickerProvider vsync, VoidCallback onTick) {
    // _onFrame is set by build() before this runs.
    _lastElapsed = Duration.zero;
    _onTick = onTick;
    _vsync = vsync;
    _ticker?.dispose();
    try {
      _ticker = vsync.createTicker((elapsed) {
        final dtSec = _lastElapsed == Duration.zero
            ? 0.0
            : (elapsed - _lastElapsed).inMicroseconds / 1e6;
        _lastElapsed = elapsed;

        final posChanged = _motion.tick(dtSec);
        if (!posChanged) return;

        // Unthrottled: the overlay repaints with the frame.
        _onFrame?.call();

        final now = DateTime.now();
        if (_lastTickAt != null &&
            now.difference(_lastTickAt!).inMilliseconds < _minTickIntervalMs) {
          return;
        }
        _lastTickAt = now;
        onTick();
      })
        ..start();
    } catch (_) {
      // TickerProvider was disposed while we were awaiting the image.
      // Leave the dot ready for the next build call.
      _ticker = null;
      _onTick = null;
      _vsync = null;
    }
  }

  /// The classic marker: gold core, white ring, soft white halo.
  static void paintPlainDot(Canvas canvas, Offset center) =>
      _paintPlainDot(canvas, center);

  static void paintHeadingBadge(Canvas canvas, Offset center) =>
      _paintHeadingBadge(canvas, center);

  /// The ground shadow that lifts the badge off the map.
  ///
  /// Separate from the badge on purpose. The badge is rotated — by Mapbox
  /// through `iconRotate`, by the overlay through `canvas.rotate` — and a
  /// shadow that turns with it would swing around the disc as the driver
  /// drives, which reads as the sun orbiting them. Drawn on its own, before
  /// the rotation is applied, it stays where a shadow belongs.
  ///
  /// Two passes: a wide soft one for the ambient darkening under the disc,
  /// and a tighter darker one just below it for the contact edge. That pair
  /// is what makes a flat circle read as a disc standing above the street
  /// rather than printed on it.
  static void paintHeadingShadow(Canvas canvas, Offset center) {
    canvas.drawOval(
      Rect.fromCenter(
        center: center + const Offset(0, _shadowDrop * 1.5),
        width: _dotR * 2.2,
        height: _dotR * 1.6,
      ),
      Paint()
        ..color = Colors.black.withValues(alpha: 0.62)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 8),
    );
    canvas.drawCircle(
      center + const Offset(0, _shadowDrop),
      _dotR * 0.99,
      Paint()
        ..color = Colors.black.withValues(alpha: 0.88)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 2.5),
    );
  }

  /// How far below the badge the shadow sits, in canvas units.
  ///
  /// The whole lift is carried by this number and the two opacities above.
  /// Both were raised once already: the first pass was tuned against a white
  /// mock-up and disappeared on the actual map, which is a dark navy the
  /// shadow has to be darker than to be seen at all.
  static const double _shadowDrop = 4.5;

  static void _paintPlainDot(Canvas canvas, Offset center) {
    canvas.drawCircle(
      center,
      _plainDotR * 1.8,
      Paint()
        ..color = Colors.white.withValues(alpha: 0.12)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6),
    );
    canvas.drawCircle(
      center,
      _plainDotR * 1.3,
      Paint()
        ..color = Colors.white.withValues(alpha: 0.15)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3),
    );
    canvas.drawCircle(
      center,
      _plainDotR,
      Paint()
        ..color = Colors.white
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.5,
    );
    canvas.drawCircle(
      center,
      _plainDotR - 1.5,
      Paint()..color = _gold.withValues(alpha: 0.9),
    );
  }

  /// The driver badge: black disc, gold ring, white arrow pointing north.
  static void _paintHeadingBadge(Canvas canvas, Offset center) {
    // Gold halo — the only thing holding the badge off a dark map. Kept
    // faint: this sits under the driver's own car at all times.
    canvas.drawCircle(
      center,
      _dotR * 1.7,
      Paint()
        ..color = _gold.withValues(alpha: 0.16)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 7),
    );

    // The supplied badge, stamped into exactly the circle the vector one
    // filled: a 40-unit square centred on the same point, which is what
    // `drawCircle(center, _dotR)` covered. The asset is cropped to its own
    // artwork and squared around its centre (see the marker build script),
    // so its disc lands edge to edge in that square — same diameter, same
    // centre of rotation.
    final img = _badgeImage;
    if (img != null) {
      canvas.drawImageRect(
        img,
        Rect.fromLTWH(0, 0, img.width.toDouble(), img.height.toDouble()),
        Rect.fromCircle(center: center, radius: _dotR),
        Paint()
          ..isAntiAlias = true
          // The source is 512 px landing in a 40-unit box that is itself
          // drawn at a few different scales — a 12:1 reduction, where
          // anything below `high` shows the ring aliasing into a dashed
          // line as the marker turns.
          ..filterQuality = FilterQuality.high,
      );
      return;
    }

    // ── Fallback: the badge drawn by hand ──────────────────────────────
    // Reached only when the asset fails to decode. Same shape, same sizes.

    // Black body.
    canvas.drawCircle(center, _dotR, Paint()..color = _body);

    // Gold ring around it.
    canvas.drawCircle(
      center,
      _dotR - 1.75,
      Paint()
        ..color = _gold
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3.5,
    );

    // White arrow, drawn pointing north — the map turns it.
    //
    // The notch in the base is what makes it read as a direction arrow
    // rather than a triangle; it is the shape every navigation app uses,
    // and the one the driver already knows from Google Maps.
    const tipY = -11.5;      // apex, relative to centre
    const baseY = 9.5;       // outer corners
    const notchY = 4.0;      // centre of the base, pulled up
    const halfW = 8.6;
    final arrow = Path()
      ..moveTo(center.dx, center.dy + tipY)
      ..lineTo(center.dx + halfW, center.dy + baseY)
      ..lineTo(center.dx, center.dy + notchY)
      ..lineTo(center.dx - halfW, center.dy + baseY)
      ..close();

    // Shadow under the arrow so it survives against the gold ring.
    canvas.drawPath(
      arrow,
      Paint()
        ..color = Colors.black.withValues(alpha: 0.55)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 2),
    );
    canvas.drawPath(arrow, Paint()..color = Colors.white);
  }

  /// Restart the ticker if it was stopped (e.g. after app resume).
  /// Safe to call multiple times. No-op if [dispose] has already been called.
  void ensureRunning() {
    if (_isDisposing) return;
    if (_ticker == null || _onTick == null || _vsync == null) return;
    if (!_ticker!.isActive) {
      _lastElapsed = Duration.zero;
      _ticker!.start();
    }
  }

  void dispose() {
    _isDisposing = true;
    _ticker?.dispose();
    _ticker = null;
    _onTick = null;
    _vsync = null;
  }
}

/// The same marker as [GoldLocationDot], painted by Flutter instead of being
/// handed to Mapbox as an image.
///
/// A point annotation can only move as fast as the platform channel lets it:
/// the driver screen writes fresh geometry every frame but can only flush
/// when the previous round trip has landed, so on a busy channel the marker
/// advances ten or fifteen times a second while the map under it renders at
/// sixty. That difference is the stepping a driver sees while walking.
///
/// Whenever the camera is following the driver, the marker does not actually
/// move across the screen at all — the map slides underneath it. So there is
/// nothing to send: paint it in Flutter at the point the camera centres on
/// and it glides at the display's own rate, with no channel involved.
///
/// It also cannot fail. There is no PNG to rasterise, no annotation manager
/// to be ready, and no native object to die with the map surface — the three
/// things the watchdog on the driver screens exists to recover from.
class GoldLocationDotOverlay extends StatelessWidget {
  const GoldLocationDotOverlay({
    super.key,
    required this.bearing,
    this.heading = true,
    this.size = GoldLocationDot.driverOverlaySize,
  });

  /// Degrees clockwise from north, already smoothed by SmoothMotion.
  final double bearing;

  /// Match [GoldLocationDot.heading]: arrow badge vs plain dot.
  final bool heading;

  /// Rendered width. The painter draws into the same 160-unit canvas the
  /// bitmap uses and is scaled down, so both looks stay identical.
  final double size;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: SizedBox(
        width: size,
        height: size,
        child: CustomPaint(
          painter: _GoldDotOverlayPainter(bearing: bearing, heading: heading),
        ),
      ),
    );
  }
}

class _GoldDotOverlayPainter extends CustomPainter {
  _GoldDotOverlayPainter({required this.bearing, required this.heading})
      : _badgeGeneration = GoldLocationDot._artworkGeneration;

  final double bearing;
  final bool heading;

  /// What the badge artwork looked like when this painter was made.
  ///
  /// The overlay is a static drawing whenever the driver is stopped, so
  /// without this a marker painted during the frame or two before the PNG
  /// finished decoding would keep showing the fallback until something else
  /// moved.
  final int _badgeGeneration;

  @override
  void paint(Canvas canvas, Size size) {
    // The shared painters draw in absolute coordinates on a 160x160 canvas.
    // Scale into whatever box we were given so the overlay and the bitmap
    // are the same drawing at different sizes.
    final scale = size.width / GoldLocationDot.canvasSize;
    canvas.save();
    canvas.scale(scale);
    const center = Offset(
      GoldLocationDot.canvasSize / 2,
      GoldLocationDot.canvasSize / 2,
    );
    if (heading) {
      // Shadow first and unrotated, so it stays under the badge instead of
      // orbiting it as the driver turns. Then the badge, rotated.
      GoldLocationDot.paintHeadingShadow(canvas, center);
      // The bitmap is rotated by Mapbox via iconRotate; here we rotate the
      // canvas ourselves, around the same centre.
      canvas.translate(center.dx, center.dy);
      canvas.rotate(bearing * math.pi / 180.0);
      canvas.translate(-center.dx, -center.dy);
      GoldLocationDot.paintHeadingBadge(canvas, center);
    } else {
      GoldLocationDot.paintPlainDot(canvas, center);
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_GoldDotOverlayPainter old) =>
      old.bearing != bearing ||
      old.heading != heading ||
      old._badgeGeneration != _badgeGeneration;
}
