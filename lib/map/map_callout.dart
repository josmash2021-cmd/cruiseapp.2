import 'dart:math' as math;
import 'dart:ui' show lerpDouble;

import 'package:flutter/material.dart';

import '../utils/offer_metrics.dart';
import '../utils/vehicle_tier_style.dart';

// ══════════════════════════════════════════════════════════════════════════
//  Lyft-style map callouts (owner spec 2026-11-01)
//
//  A black speech bubble with a tail, in two variants that share every
//  number below:
//    • TRIP — on the pickup of each unclaimed trip: a gold rounded tile with
//      a hailing person, "$10 CRUISE", "9 min away". Tappable.
//    • AIRPORT — a gold plane (no tile), "BHM", "1-5 Drivers".
//  Zoomed in they are EXPANDED (two lines + tail, box centred on the point,
//  tail tip on it); zoomed out COMPACT (bigger icon + the price / code, a
//  touch bigger, no tail). The 380 ms morph between them never moves the
//  price's left edge: the box grows LEFT by the icon's growth, the price
//  slides down to the icon's centre line and grows 17 → 20 px, line 2 and
//  the product run (" CRUISE") fade and are clipped by the closing box.
//
//  Everything here is pure (no Mapbox, no widgets): label text, both rest
//  layouts, the frame at any instant of the morph, the zoom hysteresis and
//  the airport buckets are unit-tested. lib/widgets/map/map_callout_bubble
//  .dart draws a frame; the driver screen places it with FlatMapProjection.
//
//  All numbers are LOGICAL px. Top-level constants, not class statics: the
//  screen that uses them is a `part` library (CLAUDE.md rule #16).
// ══════════════════════════════════════════════════════════════════════════

/// Box fill: pure black, like Lyft's.
const Color kCalloutFill = Color(0xFF000000);

/// Box corner radius, both states.
const double kCalloutRadius = 14.0;

/// The tail of the expanded state: an isosceles triangle under the box, its
/// tip on the map point.
const double kCalloutTailBase = 16.0;
const double kCalloutTailHeight = 8.0;

/// The soft drop shadow under box + tail: black at 45 %, blur sigma 8,
/// pushed 4 px down.
const double kCalloutShadowOpacity = 0.45;
const double kCalloutShadowSigma = 8.0;
const double kCalloutShadowDy = 4.0;

/// How far that shadow reaches past the shape: 3 sigma (Skia sizes its blur
/// mask at 3 sigma; beyond it the shadow is < 0.1 % alpha) — shifted 4 px
/// down: 20 px above the box, 24 left/right, 28 below.
const double kCalloutShadowReach = 3 * kCalloutShadowSigma; // 24

/// Text: Poppins, white, line height 1.15. The price / code line is 17 px
/// expanded and grows to 20 px compact.
const double kCalloutTitleSize = 17.0;
const double kCalloutTitleSizeCompact = 20.0;
const double kCalloutTitleScaleCompact =
    kCalloutTitleSizeCompact / kCalloutTitleSize;
const double kCalloutSubtitleSize = 15.0;
const double kCalloutLineHeight = 1.15;

/// Air between the icon and the text, both states.
const double kCalloutGap = 10.0;

/// Gold of the trip tile (app gold); its corners are a quarter of its side
/// (36 → 9, 44 → 11).
const Color kTripCalloutTileGold = Color(0xFFE8C547);
const double kTripTileRadiusPerSide = 0.25;

/// The hailing person on the trip tile (black on gold).
const IconData kTripCalloutGlyph = Icons.hail_rounded;
const Color kTripCalloutGlyphColor = Color(0xFF000000);

/// The airport's plane: the standard Material plane, GOLD, no tile behind
/// it (owner 2026-11-01). It points up; Lyft's points up-right, so it is
/// turned 45° clockwise.
const IconData kAirportCalloutGlyph = Icons.flight_rounded;
const Color kAirportCalloutGlyphColor = Color(0xFFE8C547);
const double kAirportGlyphRotation = math.pi / 4;

// ── The morph ─────────────────────────────────────────────────────────────

/// One expand/collapse, start to end (owner: "un poco más smooth").
const Duration kCalloutMorphDuration = Duration(milliseconds: 380);

/// Box, icon, the price's slide and growth, and the tail follow this.
const Curve kCalloutMorphCurve = Curves.easeInOutCubic;

/// Line 2 and the product run fade on the RAW morph value v (0 = compact,
/// 1 = expanded): collapsing they go 1 → 0 over the first 55 % of the run
/// (t = 1 − v from 0 to 0.55), expanding 0 → 1 over the last 55 % (v from
/// 0.45 to 1) — the box moves first. Both are the same line in v, so a
/// reversal mid-morph never makes the text jump.
const double kCalloutFadeStart = 0.45;

double calloutFadeOpacity(double v) =>
    ((v - kCalloutFadeStart) / (1 - kCalloutFadeStart)).clamp(0.0, 1.0);

/// Zoom hysteresis: expanded at zoom >= 11.0, compact below 10.6, and in
/// between whatever it already was — a camera hovering at 10.8 never
/// flickers between the two.
const double kCalloutExpandZoom = 11.0;
const double kCalloutCompactZoom = 10.6;

bool calloutExpandedForZoom(double zoom, {required bool wasExpanded}) {
  if (!zoom.isFinite) return wasExpanded;
  if (zoom >= kCalloutExpandZoom) return true;
  if (zoom < kCalloutCompactZoom) return false;
  return wasExpanded;
}

// ── The two variants ──────────────────────────────────────────────────────

enum CalloutVariant { trip, airport }

/// What a variant looks like. Padding is the same in both states.
@immutable
class CalloutSpec {
  const CalloutSpec({
    required this.padding,
    required this.iconExpanded,
    required this.iconCompact,
    required this.glyphPerIcon,
    required this.tile,
  });

  final EdgeInsets padding;

  /// The icon's side: the trip tile / the airport plane.
  final double iconExpanded;
  final double iconCompact;

  /// Glyph font size per px of icon side (trip 24 on 36; the plane IS the
  /// icon).
  final double glyphPerIcon;

  /// Whether the glyph sits on a gold tile.
  final bool tile;
}

/// TRIP: padding 10 / 10 / 14 / 10, gold tile 36 (glyph 24) → 44 (≈29).
const CalloutSpec kTripCalloutSpec = CalloutSpec(
  padding: EdgeInsets.fromLTRB(10, 10, 14, 10),
  iconExpanded: 36,
  iconCompact: 44,
  glyphPerIcon: 24 / 36,
  tile: true,
);

/// AIRPORT: padding 12 / 10 / 14 / 10, gold plane 26 → 34, no tile.
const CalloutSpec kAirportCalloutSpec = CalloutSpec(
  padding: EdgeInsets.fromLTRB(12, 10, 14, 10),
  iconExpanded: 26,
  iconCompact: 34,
  glyphPerIcon: 1.0,
  tile: false,
);

CalloutSpec calloutSpecOf(CalloutVariant v) =>
    v == CalloutVariant.trip ? kTripCalloutSpec : kAirportCalloutSpec;

// ── Geometry ──────────────────────────────────────────────────────────────

/// The measured text of a callout at its 17 / 15 px rest sizes.
@immutable
class CalloutText {
  const CalloutText({
    required this.keepWidth,
    this.tailWidth = 0,
    required this.titleHeight,
    this.subtitleWidth,
    this.subtitleHeight,
  });

  /// The run that stays when compact: "$10" / "BHM".
  final double keepWidth;

  /// The run that fades out: " CRUISE" / " CRUISE PREMIUM" (0 = none).
  final double tailWidth;
  final double titleHeight;

  /// Null = no second line (e.g. the airport count has not arrived yet).
  final double? subtitleWidth;
  final double? subtitleHeight;

  double get titleWidth => keepWidth + tailWidth;
  bool get hasSubtitle => subtitleWidth != null && subtitleHeight != null;
}

/// The callout at one instant of the morph, in px RELATIVE TO THE MAP POINT
/// (the point is (0, 0); y grows down).
@immutable
class CalloutFrame {
  const CalloutFrame({
    required this.box,
    required this.icon,
    required this.glyph,
    required this.tileRadius,
    required this.titleAt,
    required this.titleScale,
    required this.subtitleAt,
    required this.fade,
    required this.showFading,
    required this.textClip,
    required this.tailOpacity,
  });

  final Rect box;
  final Rect icon;
  final double glyph;
  final double tileRadius;

  /// Top-left of the price / code run, and its scale (1 → 20/17).
  final Offset titleAt;
  final double titleScale;

  /// Top-left of line 2 — it rides under the price while it fades.
  final Offset subtitleAt;

  /// Opacity of line 2 and the product run.
  final double fade;

  /// False only at rest compact: there line 2 and the product run are out
  /// of the tree.
  final bool showFading;

  /// What line 2 and the product run are clipped to: the box minus its
  /// right padding and 2 px off its bottom — the closing box trims them.
  final Rect textClip;

  /// 1 expanded → 0 compact. The tail runs from the box's bottom edge to its
  /// tip on the map point: the tip never moves.
  final double tailOpacity;

  bool get hasTail => tailOpacity > 0 && box.bottom < 0;
}

/// Both rest states of one callout, and every frame between them.
///
/// EXPANDED: box centred on the point, tail tip on it:
///   wE = padL + iconE + GAP + max(titleW, subW) + padR
///   hE = padT + max(iconE, titleH + subH) + padB
///   left = −wE/2, top = −(8 + hE)
///   titleX = left + padL + iconE + GAP, titleY_E = top + padT
/// COMPACT: same top, title x unchanged, the box grows left by iconC − iconE:
///   wC = padL + iconC + GAP + keepW·20/17 + padR
///   hC = padT + max(iconC, titleH·20/17) + padB
///   leftC = titleX − GAP − iconC − padL
///   titleY_C = top + padT + (contentH_C − titleH·20/17)/2 (centred on the
///   icon)
@immutable
class CalloutLayout {
  const CalloutLayout._(this.spec, this.text, this.expandedBox, this.compactBox,
      this.titleX, this.titleYExpanded, this.titleYCompact);

  factory CalloutLayout.of(CalloutVariant variant, CalloutText text) {
    final spec = calloutSpecOf(variant);
    final p = spec.padding;
    final textWE = math.max(text.titleWidth, text.subtitleWidth ?? 0.0);
    final textHE = text.titleHeight + (text.subtitleHeight ?? 0.0);
    final hE = p.top + math.max(spec.iconExpanded, textHE) + p.bottom;
    final wE = p.left + spec.iconExpanded + kCalloutGap + textWE + p.right;
    final top = -(kCalloutTailHeight + hE);
    final leftE = -wE / 2;
    final titleX = leftE + p.left + spec.iconExpanded + kCalloutGap;
    final titleHC = text.titleHeight * kCalloutTitleScaleCompact;
    final contentHC = math.max(spec.iconCompact, titleHC);
    final hC = p.top + contentHC + p.bottom;
    final wC = p.left +
        spec.iconCompact +
        kCalloutGap +
        text.keepWidth * kCalloutTitleScaleCompact +
        p.right;
    final leftC = titleX - kCalloutGap - spec.iconCompact - p.left;
    return CalloutLayout._(
      spec,
      text,
      Rect.fromLTWH(leftE, top, wE, hE),
      Rect.fromLTWH(leftC, top, wC, hC),
      titleX,
      top + p.top,
      top + p.top + (contentHC - titleHC) / 2,
    );
  }

  final CalloutSpec spec;
  final CalloutText text;
  final Rect expandedBox;
  final Rect compactBox;

  /// The price / code's left edge — the same in every frame.
  final double titleX;
  final double titleYExpanded;
  final double titleYCompact;

  /// Everything any frame can cover (the shadow paints outside it).
  Rect get bounds => Rect.fromLTRB(
        math.min(expandedBox.left, compactBox.left),
        expandedBox.top,
        math.max(expandedBox.right, compactBox.right),
        math.max(0.0, math.max(expandedBox.bottom, compactBox.bottom)),
      );

  /// The frame at RAW morph value [v] (0 = compact, 1 = expanded). Geometry
  /// moves on [kCalloutMorphCurve]; every endpoint is the exact rest
  /// layout, so nothing snaps at the start or the end.
  CalloutFrame frameAt(double v) {
    final value = v.clamp(0.0, 1.0);
    final s = kCalloutMorphCurve.transform(value);
    double l(double a, double b) => lerpDouble(a, b, s)!;
    final c = compactBox, e = expandedBox;
    final box = Rect.fromLTWH(
        l(c.left, e.left), e.top, l(c.width, e.width), l(c.height, e.height));
    final side = l(spec.iconCompact, spec.iconExpanded);
    final icon = Rect.fromLTWH(box.left + spec.padding.left,
        box.top + (box.height - side) / 2, side, side);
    final scale = l(kCalloutTitleScaleCompact, 1.0);
    final titleAt = Offset(titleX, l(titleYCompact, titleYExpanded));
    final fading = (text.tailWidth > 0 || text.hasSubtitle) && value > 0;
    return CalloutFrame(
      box: box,
      icon: icon,
      glyph: side * spec.glyphPerIcon,
      tileRadius: spec.tile ? side * kTripTileRadiusPerSide : 0,
      titleAt: titleAt,
      titleScale: scale,
      subtitleAt: titleAt.translate(0, text.titleHeight * scale),
      fade: calloutFadeOpacity(value),
      showFading: fading,
      textClip: Rect.fromLTRB(box.left, box.top,
          box.right - spec.padding.right, box.bottom - 2),
      tailOpacity: s,
    );
  }
}

// ── The shape ─────────────────────────────────────────────────────────────

/// The rounded box, plus (when [tailTip] is given) the tail down to it, as
/// ONE closed contour — no seam where the tail joins, and the shadow is
/// cast by the same outline.
Path calloutPath(Rect box, {double radius = kCalloutRadius, Offset? tailTip}) {
  final r = Radius.circular(radius);
  final p = Path()
    ..moveTo(box.left + radius, box.top)
    ..lineTo(box.right - radius, box.top)
    ..arcToPoint(Offset(box.right, box.top + radius), radius: r)
    ..lineTo(box.right, box.bottom - radius)
    ..arcToPoint(Offset(box.right - radius, box.bottom), radius: r);
  if (tailTip != null && tailTip.dy > box.bottom) {
    final cx = tailTip.dx;
    p
      ..lineTo(cx + kCalloutTailBase / 2, box.bottom)
      ..lineTo(cx, tailTip.dy)
      ..lineTo(cx - kCalloutTailBase / 2, box.bottom);
  }
  p
    ..lineTo(box.left + radius, box.bottom)
    ..arcToPoint(Offset(box.left, box.bottom - radius), radius: r)
    ..lineTo(box.left, box.top + radius)
    ..arcToPoint(Offset(box.left + radius, box.top), radius: r)
    ..close();
  return p;
}

/// The tail alone, 1 px up into the box so the fading tail never shows a
/// hairline joint.
Path calloutTailPath(Rect box, Offset tip) => Path()
  ..moveTo(tip.dx - kCalloutTailBase / 2, box.bottom - 1)
  ..lineTo(tip.dx + kCalloutTailBase / 2, box.bottom - 1)
  ..lineTo(tip.dx, tip.dy)
  ..close();

/// Shadow first, then the black fill. A fully grown tail is part of the
/// box's single contour (and of its shadow); a fading one is drawn on its
/// own at [tailOpacity] over the box's bottom edge.
void paintCalloutBubble(Canvas canvas, Rect box,
    {Offset? tailTip, double tailOpacity = 1}) {
  final tip = (tailTip != null && tailTip.dy > box.bottom && tailOpacity > 0)
      ? tailTip
      : null;
  final whole = tip != null && tailOpacity >= 0.999;
  final outline = calloutPath(box, tailTip: whole ? tip : null);
  canvas.drawPath(
    outline.shift(const Offset(0, kCalloutShadowDy)),
    Paint()
      ..color = Colors.black.withValues(alpha: kCalloutShadowOpacity)
      ..maskFilter =
          const MaskFilter.blur(BlurStyle.normal, kCalloutShadowSigma),
  );
  canvas.drawPath(outline, Paint()..color = kCalloutFill);
  if (tip != null && !whole) {
    canvas.drawPath(
      calloutTailPath(box, tip),
      Paint()..color = kCalloutFill.withValues(alpha: tailOpacity),
    );
  }
}

// ── Trip callout: the label ───────────────────────────────────────────────

/// A number off the JSON feed: a num, or a numeric string. Anything else
/// (null, bool, garbage) is null.
double? calloutNum(Object? v) {
  if (v is num) return v.toDouble();
  if (v is String) return double.tryParse(v.trim());
  return null;
}

/// The driver's pay rounded to whole dollars: 9.5 → "$10", 10.49 → "$10".
/// Null when the feed has no usable number.
String? tripCalloutPrice(Object? fare) {
  final f = calloutNum(fare);
  if (f == null || !f.isFinite) return null;
  return '\$${(f < 0 ? 0 : f).round()}';
}

/// "CRUISE" for the standard tier, "CRUISE COMPACT" / "CRUISE PREMIUM" /
/// "CRUISE VIP" / "CRUISE ELECTRIC PRO" for the rest — the BOOKING meaning
/// of the trip's vehicle_type (tripTierKey: "Sedan" is Compact, "SUV XL" is
/// Premium), in uppercase. Product names are not translated.
String tripCalloutProduct(Object? vehicleType) {
  final raw = vehicleType?.toString();
  if (tripTierKey(raw) == kTierStandard) return 'CRUISE';
  return 'CRUISE ${tripTierLabel(raw)}';
}

/// Minutes to the pickup: the backend's `pickup_eta_min` (driving minutes
/// with traffic) as-is, never capped; without it, the road miles at the
/// offer card's fallback speed (offerLegMinutes). Null when neither exists.
int? tripCalloutMinutes(Map<String, dynamic> item) {
  final eta = calloutNum(item['pickup_eta_min']);
  if (eta != null && eta.isFinite && eta > 0) {
    return offerLegMinutes(km: 0, roadMinutes: eta);
  }
  final miles = calloutNum(item['pickup_distance_miles']);
  if (miles != null && miles.isFinite && miles >= 0) {
    return offerLegMinutes(km: miles * 1.609);
  }
  return null;
}

/// The pickup off the feed, or null — the field may be missing (older
/// backend), null, a string, or junk. (0, 0) is "unknown", not the Gulf of
/// Guinea.
({double lat, double lng})? tripCalloutPickup(Map<String, dynamic> item) {
  final lat = calloutNum(item['pickup_lat']);
  final lng = calloutNum(item['pickup_lng']);
  if (lat == null || lng == null || !lat.isFinite || !lng.isFinite) {
    return null;
  }
  if (lat.abs() > 90 || lng.abs() > 180) return null;
  if (lat == 0 && lng == 0) return null;
  return (lat: lat, lng: lng);
}

/// One trip callout on the map.
@immutable
class TripCallout {
  const TripCallout({
    required this.tripId,
    required this.lat,
    required this.lng,
    required this.price,
    required this.product,
    this.subtitle,
  });

  final int tripId;
  final double lat;
  final double lng;

  /// "$10"; null when the feed had no fare.
  final String? price;

  /// "CRUISE" / "CRUISE PREMIUM"
  final String product;

  /// "9 min away" / "a 9 min". Null = one-line callout.
  final String? subtitle;

  /// Line 1: "$10 CRUISE".
  String get title => price == null ? product : '$price $product';

  /// The run that stays compact (and never moves): the price — or the
  /// product when there is no price.
  String get keepRun => price ?? product;

  /// The run that fades on collapse: " CRUISE" (null without a price).
  String? get fadeRun => price == null ? null : ' $product';

  /// Text AND position: equal keys draw the same thing in the same place.
  String get key => '$tripId\u0001$title\u0001${subtitle ?? ''}\u0001'
      '${lat.toStringAsFixed(6)},${lng.toStringAsFixed(6)}';
}

/// The callouts for the available-trips feed. Items without a trip id or a
/// usable pickup are skipped — the feature is inert, never broken, on a
/// backend that does not send `pickup_lat` / `pickup_lng`.
List<TripCallout> buildTripCallouts(
  Iterable<Map<String, dynamic>> items, {
  required String Function(int minutes) minAway,
}) {
  final out = <TripCallout>[];
  final seen = <int>{};
  for (final item in items) {
    final idNum = calloutNum(item['trip_id']);
    if (idNum == null || !idNum.isFinite) continue;
    final id = idNum.toInt();
    if (!seen.add(id)) continue;
    final at = tripCalloutPickup(item);
    if (at == null) continue;
    final minutes = tripCalloutMinutes(item);
    out.add(TripCallout(
      tripId: id,
      lat: at.lat,
      lng: at.lng,
      price: tripCalloutPrice(item['fare'] ?? item['driver_earnings']),
      product: tripCalloutProduct(item['vehicle_type']),
      subtitle: minutes == null ? null : minAway(minutes),
    ));
  }
  return out;
}

/// True when two callout lists draw exactly the same thing — a 12 s poll
/// that brings back the same trips keeps the old list (and every widget
/// built from it) untouched.
bool sameTripCallouts(List<TripCallout> a, List<TripCallout> b) {
  if (identical(a, b)) return true;
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i].key != b[i].key) return false;
  }
  return true;
}

// ── Airport callout: the driver count ─────────────────────────────────────

/// The owner's buckets (2026-11-01) for how many OTHER drivers are online
/// near an airport: 0 → "0", 1–5 → "1-5", 6–9 → "5-15", 10–15 → "10-15",
/// 16–20 → "15-20", 21–30 → "20-30", 31+ → "30+". The word after it
/// ("Drivers" / "conductores") comes from S.airportDriversLabel.
String airportDriversBucket(int count) {
  if (count <= 0) return '0';
  if (count <= 5) return '1-5';
  if (count <= 9) return '5-15';
  if (count <= 15) return '10-15';
  if (count <= 20) return '15-20';
  if (count <= 30) return '20-30';
  return '30+';
}

/// The local-clock hour [now] falls in, as a key: the label may change only
/// when this changes (owner: at most once per hour).
int calloutHourKey(DateTime now) =>
    DateTime(now.year, now.month, now.day, now.hour).millisecondsSinceEpoch;

/// When the next local hour starts.
DateTime calloutNextHour(DateTime now) =>
    DateTime(now.year, now.month, now.day, now.hour + 1);

/// The airport counts the app holds, per code, each stamped with the hour
/// it was fetched in.
///
/// The app fetches the first time an airport callout needs a value, then
/// again only once the local clock is in a NEW hour — until that answer
/// arrives the old value stays on screen, so the label changes at most
/// once per hour.
class AirportDriverCounts {
  final Map<String, ({int hour, int count})> _byCode = {};

  /// The count to show for [code], or null (no second line yet).
  int? countFor(String code) => _byCode[code]?.count;

  /// The codes in [onScreen] with no value for the hour of [now].
  List<String> staleCodes(Iterable<String> onScreen, DateTime now) {
    final hour = calloutHourKey(now);
    return [
      for (final c in onScreen)
        if (_byCode[c]?.hour != hour) c,
    ];
  }

  /// Store an answer fetched during the hour of [now]. A code the server
  /// did not mention counts 0 for that hour (it was asked and nobody is
  /// there), so it is not asked again until the next hour.
  void store(Iterable<String> asked, Map<String, int> counts, DateTime now) {
    final hour = calloutHourKey(now);
    for (final c in asked) {
      final n = counts[c] ?? 0;
      _byCode[c] = (hour: hour, count: n < 0 ? 0 : n);
    }
  }
}
