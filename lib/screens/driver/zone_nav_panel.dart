import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../../services/haptic_service.dart';
import '../../widgets/glass_style.dart';
import '../../widgets/map/heat_flame.dart';

/// The dark well the flame sits in.
const Color kZoneFlameWell = Color(0xFF0B0B0F);

/// The bottom panel of a drive to a heat zone (owner 2026-11-05): the nav
/// panel's CLOSED glass on the same floating margins — the gold flame in a
/// dark well, the title ("Zona con pasajeros" → "Llegaste a la zona"), the
/// zone with the live ETA and miles in grey, and "Terminar".
///
/// Nothing opens from it: there is no rider and no trip behind it. It
/// reports its height like `NavTripPanel` (closed, the height on screen IS
/// the resting height), so the chase camera's lift, the overview insets and
/// the mph / map buttons ride on it exactly as they ride on the trip panel.
class ZoneNavPanel extends StatelessWidget {
  const ZoneNavPanel({
    super.key,
    required this.title,
    required this.zoneName,
    required this.eta,
    required this.endLabel,
    required this.onEnd,
    this.mapControls,
    this.onHeightChanged,
    this.onRestHeightChanged,
  });

  final String title;

  /// The grey line is "zoneName · eta": a long zone name is the part that
  /// gets cut, never the live ETA and miles.
  final String zoneName;

  /// "7 min · 2.9 mi", live; empty = the zone's name alone.
  final String eta;
  final String endLabel;

  /// Terminar.
  final VoidCallback onEnd;

  /// The map's own buttons (mph, route overview, recenter), positioned
  /// against the whole screen — the same widget the trip panel gets.
  final Widget? mapControls;
  final ValueChanged<double>? onHeightChanged;
  final ValueChanged<double>? onRestHeightChanged;

  static final TextStyle _subStyle = TextStyle(
    color: Colors.white.withValues(alpha: 0.7),
    fontSize: 15,
    fontFeatures: const [FontFeature.tabularFigures()],
  );

  @override
  Widget build(BuildContext context) {
    final bottomPad = MediaQuery.maybeOf(context)?.padding.bottom ?? 0;
    final panel = Padding(
      // NavTripPanel's closed margins: the Mapbox wordmark is centred in the
      // strip under them (DriverNavView._showMapBrand).
      padding: EdgeInsets.fromLTRB(8, 0, 8, 8 + bottomPad * 0.5),
      child: GlassSurface(
        blur: kGlassSheetBlurOpen,
        tint: glassNavRestTint,
        roundFrostOnIOS: true,
        borderRadius: BorderRadius.circular(30),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 14, 16),
          child: Row(
            children: [
              Container(
                width: 42,
                height: 42,
                decoration: const BoxDecoration(
                  color: kZoneFlameWell,
                  shape: BoxShape.circle,
                ),
                alignment: Alignment.center,
                child: const HeatFlameIcon(size: 22),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // Arrival swaps the title softly, never in one frame.
                    AnimatedSwitcher(
                      duration: const Duration(milliseconds: 320),
                      layoutBuilder: (cur, prev) => Stack(
                        alignment: Alignment.centerLeft,
                        children: [...prev, if (cur != null) cur],
                      ),
                      // A narrow phone shrinks the title a touch instead of
                      // cutting it ("Zona con pasaj…").
                      child: FittedBox(
                        key: ValueKey('zone-nav-title-$title'),
                        fit: BoxFit.scaleDown,
                        alignment: Alignment.centerLeft,
                        child: Text(
                          title,
                          maxLines: 1,
                          softWrap: false,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 19,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 2),
                    // The ETA first, up to the whole line; the name gets
                    // what is left (no overflow on a narrow phone or with
                    // large text either).
                    LayoutBuilder(
                      key: const ValueKey('zone-nav-subtitle'),
                      builder: (context, c) => Row(
                        children: [
                          Flexible(
                            child: Text(
                              zoneName,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: _subStyle,
                            ),
                          ),
                          if (eta.isNotEmpty)
                            ConstrainedBox(
                              constraints:
                                  BoxConstraints(maxWidth: c.maxWidth),
                              child: Text(
                                ' · $eta',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: _subStyle,
                              ),
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              Semantics(
                button: true,
                label: endLabel,
                excludeSemantics: true,
                child: GestureDetector(
                  key: const ValueKey('zone-nav-end'),
                  behavior: HitTestBehavior.opaque,
                  onTap: () {
                    HapticService.lightImpact();
                    onEnd();
                  },
                  child: Container(
                    height: 44,
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(22),
                      border: Border.all(
                          color: Colors.white.withValues(alpha: 0.08)),
                    ),
                    child: Text(
                      endLabel,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    return Stack(
      children: [
        // Laid under the panel, like NavTripPanel's map controls.
        if (mapControls != null)
          Positioned.fill(
            key: const ValueKey('zone-nav-controls'),
            child: mapControls!,
          ),
        Align(
          key: const ValueKey('zone-nav-panel'),
          alignment: Alignment.bottomCenter,
          child: _ZoneHeightReporter(
            onHeight: (h) {
              onHeightChanged?.call(h);
              onRestHeightChanged?.call(h);
            },
            child: panel,
          ),
        ),
      ],
    );
  }
}

/// The heat zone's flame — the same one the online map draws on each
/// cloud (lib/widgets/map/heat_flame.dart), without its map outline.
class HeatFlameIcon extends StatelessWidget {
  const HeatFlameIcon({super.key, this.size = 24});

  final double size;

  @override
  Widget build(BuildContext context) => CustomPaint(
        size: Size.square(size),
        painter: const HeatFlamePainter(outline: false),
      );
}

/// Reports its child's laid-out height whenever it changes (twin of
/// NavTripPanel's private reporter) — after layout, never during it.
class _ZoneHeightReporter extends SingleChildRenderObjectWidget {
  const _ZoneHeightReporter({required this.onHeight, super.child});

  final ValueChanged<double> onHeight;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderZoneHeightReporter(onHeight);

  @override
  void updateRenderObject(
      BuildContext context, _RenderZoneHeightReporter renderObject) {
    renderObject.onHeight = onHeight;
  }
}

class _RenderZoneHeightReporter extends RenderProxyBox {
  _RenderZoneHeightReporter(this.onHeight);

  ValueChanged<double> onHeight;
  double? _last;

  @override
  void performLayout() {
    super.performLayout();
    final h = size.height;
    if (h != _last) {
      _last = h;
      WidgetsBinding.instance.addPostFrameCallback((_) => onHeight(h));
    }
  }
}
