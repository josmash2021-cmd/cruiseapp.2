import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../map/map_callout.dart';

/// Text style for a callout line. [CalloutFont] maps a weight to a family —
/// Poppins in the app (google_fonts names a family per weight, so the weight
/// goes in at construction, not via copyWith). Tests pass a plain style.
typedef CalloutFont = TextStyle Function(FontWeight weight);

TextStyle calloutPoppins(FontWeight weight) =>
    GoogleFonts.poppins(fontWeight: weight);

/// White, line height 1.15, `inherit: false` so the ambient DefaultTextStyle
/// can never make the widget differ from what [MapCalloutBubble] measured.
TextStyle calloutLineStyle(CalloutFont font,
        {required double size, required FontWeight weight}) =>
    font(weight).copyWith(
      inherit: false,
      color: Colors.white,
      fontSize: size,
      fontWeight: weight,
      height: kCalloutLineHeight,
      letterSpacing: 0,
    );

const TextHeightBehavior _kCalloutHeightBehavior = TextHeightBehavior();

/// The Lyft-style map callout (owner spec 2026-11-01), one widget for both
/// variants: TRIP (gold tile + "$10" + " CRUISE" + "9 min away", tappable)
/// and AIRPORT (gold plane + "BHM" + "1-5 Drivers").
///
/// Place it with its TOP-LEFT at the projected map pixel (a `Positioned`
/// with left/top): it translates itself so that pixel is the tail tip
/// (expanded) and stays the same pixel in every frame of the morph.
///
/// [expanded] flips run ONE 380 ms controller ([kCalloutMorphDuration]);
/// every frame is [CalloutLayout.frameAt] of its value, so nothing finishes
/// out of step and nothing snaps at either end. The price / code is the one
/// thing that is never clipped and never moves horizontally.
class MapCalloutBubble extends StatefulWidget {
  const MapCalloutBubble({
    super.key,
    required this.variant,
    required this.title,
    this.titleFade,
    this.subtitle,
    required this.expanded,
    this.onTap,
    this.font = calloutPoppins,
  });

  final CalloutVariant variant;

  /// The run that stays when compact: "$10" / "BHM".
  final String title;

  /// The run that fades on collapse: " CRUISE" / " CRUISE PREMIUM".
  final String? titleFade;

  /// "9 min away" / "1-5 Drivers"; null = no second line in either state.
  final String? subtitle;
  final bool expanded;

  /// Trip callouts open the claim card; airport ones pass null (and sit
  /// under an IgnorePointer).
  final VoidCallback? onTap;
  final CalloutFont font;

  /// Test handles (siblings never repeat them, so one per bubble is fine).
  static const Key boxKey = ValueKey('map-callout-box');
  static const Key iconKey = ValueKey('map-callout-icon');
  static const Key titleKey = ValueKey('map-callout-title');
  static const Key titleFadeKey = ValueKey('map-callout-title-fade');
  static const Key subtitleKey = ValueKey('map-callout-subtitle');

  @override
  State<MapCalloutBubble> createState() => _MapCalloutBubbleState();
}

class _MapCalloutBubbleState extends State<MapCalloutBubble>
    with SingleTickerProviderStateMixin {
  late final AnimationController _morph = AnimationController(
    vsync: this,
    duration: kCalloutMorphDuration,
    value: widget.expanded ? 1.0 : 0.0,
  );
  late TextStyle _titleStyle;
  late TextStyle _subStyle;
  late CalloutLayout _layout;

  @override
  void initState() {
    super.initState();
    _measure();
    // google_fonts loads Poppins asynchronously: re-measure when it lands,
    // or the box would keep the fallback face's width.
    PaintingBinding.instance.systemFonts.addListener(_onFontsChanged);
  }

  @override
  void didUpdateWidget(MapCalloutBubble old) {
    super.didUpdateWidget(old);
    if (old.title != widget.title ||
        old.titleFade != widget.titleFade ||
        old.subtitle != widget.subtitle ||
        old.font != widget.font ||
        old.variant != widget.variant) {
      _measure();
    }
    if (old.expanded != widget.expanded) {
      if (widget.expanded) {
        _morph.forward();
      } else {
        _morph.reverse();
      }
    }
  }

  void _onFontsChanged() {
    if (!mounted) return;
    setState(_measure);
  }

  Size _measureRun(String text, TextStyle style) {
    final tp = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: TextDirection.ltr,
      textHeightBehavior: _kCalloutHeightBehavior,
      maxLines: 1,
    )..layout();
    final size = tp.size;
    tp.dispose();
    return size;
  }

  void _measure() {
    _titleStyle = calloutLineStyle(widget.font,
        size: kCalloutTitleSize, weight: FontWeight.w700);
    _subStyle = calloutLineStyle(widget.font,
        size: kCalloutSubtitleSize, weight: FontWeight.w400);
    final keep = _measureRun(widget.title, _titleStyle);
    final fade = widget.titleFade;
    final fadeW = (fade == null || fade.isEmpty)
        ? 0.0
        : _measureRun(fade, _titleStyle).width;
    final sub = widget.subtitle;
    final subSize =
        (sub == null || sub.isEmpty) ? null : _measureRun(sub, _subStyle);
    _layout = CalloutLayout.of(
      widget.variant,
      CalloutText(
        keepWidth: keep.width,
        tailWidth: fadeW,
        titleHeight: keep.height,
        subtitleWidth: subSize?.width,
        subtitleHeight: subSize?.height,
      ),
    );
  }

  @override
  void dispose() {
    PaintingBinding.instance.systemFonts.removeListener(_onFontsChanged);
    _morph.dispose();
    super.dispose();
  }

  Widget _text(String text, TextStyle style, Key key) => Text(
        text,
        key: key,
        style: style,
        maxLines: 1,
        softWrap: false,
        overflow: TextOverflow.visible,
        textScaler: TextScaler.noScaling,
        textHeightBehavior: _kCalloutHeightBehavior,
        textDirection: TextDirection.ltr,
      );

  Widget _icon(CalloutFrame f) {
    if (widget.variant == CalloutVariant.trip) {
      return DecoratedBox(
        decoration: BoxDecoration(
          color: kTripCalloutTileGold,
          borderRadius: BorderRadius.circular(f.tileRadius),
        ),
        child: Center(
          child: Icon(kTripCalloutGlyph,
              size: f.glyph, color: kTripCalloutGlyphColor),
        ),
      );
    }
    // The plane fills its box (glyph = side) and turns about its centre.
    return Transform.rotate(
      angle: kAirportGlyphRotation,
      child: Icon(kAirportCalloutGlyph,
          size: f.glyph, color: kAirportCalloutGlyphColor),
    );
  }

  @override
  Widget build(BuildContext context) {
    final label = [
      '${widget.title}${widget.titleFade ?? ''}',
      if (widget.subtitle != null) widget.subtitle!,
    ].join(', ');
    final layout = _layout;
    final u = layout.bounds;
    Rect local(Rect r) => r.shift(-u.topLeft);
    // FractionalTranslation OUTERMOST: it is the one render box that hit-
    // tests without checking its own (unshifted) layout rect, so a tap on
    // the drawn bubble — which sits up-left of that rect — still lands.
    return FractionalTranslation(
      // The map pixel is the parent's (left, top): shift so it lands on the
      // point (0, 0) of the layout — the tail tip.
      translation: Offset(u.left / u.width, u.top / u.height),
      child: Semantics(
        label: label,
        button: widget.onTap != null,
        excludeSemantics: true,
        child: AnimatedBuilder(
          animation: _morph,
          builder: (context, _) {
            final f = layout.frameAt(_morph.value);
            final clip = f.textClip;
            final fade = widget.titleFade;
            final sub = widget.subtitle;
            final stack = SizedBox.fromSize(
              size: u.size,
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  Positioned.fromRect(
                    rect: local(f.box),
                    child: CustomPaint(
                      key: MapCalloutBubble.boxKey,
                      painter: _CalloutBoxPainter(
                        tailTip: -f.box.topLeft,
                        tailOpacity: f.tailOpacity,
                      ),
                    ),
                  ),
                  Positioned.fromRect(
                    key: MapCalloutBubble.iconKey,
                    rect: local(f.icon),
                    child: _icon(f),
                  ),
                  // Line 2 and the product run: fading, and trimmed by the
                  // closing box. Out of the tree once the collapse is done.
                  if (f.showFading)
                    Positioned.fromRect(
                      rect: local(clip),
                      child: ClipRect(
                        child: Stack(
                          clipBehavior: Clip.none,
                          children: [
                            if (fade != null && fade.isNotEmpty)
                              Positioned(
                                left: f.titleAt.dx +
                                    layout.text.keepWidth * f.titleScale -
                                    clip.left,
                                top: f.titleAt.dy - clip.top,
                                child: Opacity(
                                  opacity: f.fade,
                                  child: Transform.scale(
                                    scale: f.titleScale,
                                    alignment: Alignment.topLeft,
                                    child: _text(fade, _titleStyle,
                                        MapCalloutBubble.titleFadeKey),
                                  ),
                                ),
                              ),
                            if (sub != null && sub.isNotEmpty)
                              Positioned(
                                left: f.subtitleAt.dx - clip.left,
                                top: f.subtitleAt.dy - clip.top,
                                child: Opacity(
                                  opacity: f.fade,
                                  child: _text(sub, _subStyle,
                                      MapCalloutBubble.subtitleKey),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                  // The price / code: left edge fixed, slides to the icon's
                  // centre line and grows 13 → 15.5 px from its top-left.
                  Positioned(
                    left: f.titleAt.dx - u.left,
                    top: f.titleAt.dy - u.top,
                    child: Transform.scale(
                      scale: f.titleScale,
                      alignment: Alignment.topLeft,
                      child: _text(
                          widget.title, _titleStyle, MapCalloutBubble.titleKey),
                    ),
                  ),
                ],
              ),
            );
            final onTap = widget.onTap;
            if (onTap == null) return stack;
            // deferToChild: only the drawn parts take the tap — the empty
            // corners of the bounds let it through to the map.
            return GestureDetector(
              behavior: HitTestBehavior.deferToChild,
              onTap: onTap,
              child: stack,
            );
          },
        ),
      ),
    );
  }
}

/// The black box + tail + shadow, in the box's own coordinates; the tail
/// tip ([tailTip]) and the shadow paint outside it.
class _CalloutBoxPainter extends CustomPainter {
  _CalloutBoxPainter({required this.tailTip, required this.tailOpacity});

  final Offset tailTip;
  final double tailOpacity;

  @override
  void paint(Canvas canvas, Size size) {
    paintCalloutBubble(canvas, Offset.zero & size,
        tailTip: tailTip, tailOpacity: tailOpacity);
  }

  @override
  bool shouldRepaint(_CalloutBoxPainter old) =>
      old.tailTip != tailTip || old.tailOpacity != tailOpacity;
}
