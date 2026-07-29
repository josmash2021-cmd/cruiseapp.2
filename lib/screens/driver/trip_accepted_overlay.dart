import 'package:flutter/material.dart';

import '../../widgets/verified_avatar.dart';
import '../../l10n/app_localizations.dart';
import '../../services/api_service.dart';

/// "Viaje Aceptado" celebration shown right after the driver accepts.
///
/// This is an OVERLAY, not a screen: it renders on top of the map
/// [DriverOnlineScreen] already owns. It used to be `TripAcceptedScreen`,
/// a full route that mounted its own `mapbox.MapWidget` while the online
/// screen's map was still alive — two native Mapbox surfaces, each with a
/// GL context and a tile cache, at the same moment the driver taps accept.
/// That is what crashed the app on iOS. The rider flow was moved to a
/// single shared canvas for the same reason; this is the driver side of it.
///
/// It owns no map, no controller and no navigation. The caller drives the
/// camera and the route on the existing canvas, and decides when the
/// celebration is over — this widget only draws the card and runs the
/// progress bar over [duration].
class TripAcceptedOverlay extends StatefulWidget {
  const TripAcceptedOverlay({
    super.key,
    required this.riderName,
    required this.riderInitials,
    required this.riderRating,
    required this.pickupAddress,
    required this.distToPickupKm,
    required this.etaMinutes,
    required this.duration,
    this.riderIsNew = true,
    this.riderPhotoUrl,
    this.riderVerified = false,
    this.riderId,
  });

  final String riderName;
  final String riderInitials;
  final String? riderPhotoUrl;
  final bool riderVerified;
  final double riderRating;
  final bool riderIsNew;
  final int? riderId;
  final String pickupAddress;
  final double distToPickupKm;
  final int etaMinutes;

  /// How long the celebration lasts — drives the gold progress bar. The
  /// caller owns the actual timing; this only keeps the bar in sync.
  final Duration duration;

  @override
  State<TripAcceptedOverlay> createState() => _TripAcceptedOverlayState();
}

class _TripAcceptedOverlayState extends State<TripAcceptedOverlay>
    with TickerProviderStateMixin {
  static const _gold = Color(0xFFD4AF37);
  static const _card = Color(0xFF1A1A1F);

  late final AnimationController _fadeCtrl;
  late final Animation<double> _fadeAnim;

  // Slide-up animation for the content card
  late final AnimationController _slideCtrl;
  late final Animation<Offset> _slideAnim;
  late final Animation<double> _slideFadeAnim;

  @override
  void initState() {
    super.initState();
    _fadeCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
    );
    _fadeAnim = CurvedAnimation(parent: _fadeCtrl, curve: Curves.easeInOut);
    _fadeCtrl.forward();

    // Slide-up + fade for the bottom card
    _slideCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 400),
    );
    _slideAnim = Tween<Offset>(
      begin: const Offset(0, 0.3),
      end: Offset.zero,
    ).animate(CurvedAnimation(parent: _slideCtrl, curve: Curves.easeOutCubic));
    _slideFadeAnim =
        CurvedAnimation(parent: _slideCtrl, curve: Curves.easeOutCubic);

    // Start the slide a beat after the map camera has begun moving.
    Future.delayed(const Duration(milliseconds: 150), () {
      if (mounted) _slideCtrl.forward();
    });
  }

  @override
  void dispose() {
    _fadeCtrl.dispose();
    _slideCtrl.dispose();
    super.dispose();
  }

  String? _normalizedPhotoUrl(String? rawUrl) {
    final raw = (rawUrl ?? '').replaceAll('"', '').trim();
    if (raw.isEmpty) return null;
    if (raw == 'null' || raw == 'None' || raw == 'undefined' || raw == 'none') {
      return null;
    }
    if (raw.startsWith('http://') || raw.startsWith('https://')) return raw;
    if (raw.startsWith('/')) return '${ApiService.publicBaseUrl}$raw';
    return '${ApiService.publicBaseUrl}/$raw';
  }

  @override
  Widget build(BuildContext context) {
    final bottomPad = MediaQuery.of(context).padding.bottom;
    final firstName = widget.riderName.split(' ').first;

    return FadeTransition(
      opacity: _fadeAnim,
      child: Stack(
        fit: StackFit.expand,
        children: [
          // Dark gradient over the live map — same wash the old screen had.
          IgnorePointer(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Colors.black.withValues(alpha: 0.15),
                    Colors.black.withValues(alpha: 0.55),
                    Colors.black.withValues(alpha: 0.85),
                  ],
                  stops: const [0.0, 0.5, 1.0],
                ),
              ),
            ),
          ),
          // Content — slides up from the bottom.
          Positioned(
            bottom: 0,
            left: 0,
            right: 0,
            child: SlideTransition(
              position: _slideAnim,
              child: FadeTransition(
                opacity: _slideFadeAnim,
                child: SafeArea(
                  top: false,
                  child: Padding(
                    padding: EdgeInsets.fromLTRB(16, 0, 16, 16 + bottomPad),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        // ── Gold check circle ──
                        TweenAnimationBuilder<double>(
                          tween: Tween(begin: 0.0, end: 1.0),
                          duration: const Duration(milliseconds: 600),
                          curve: Curves.elasticOut,
                          builder: (_, scale, child) =>
                              Transform.scale(scale: scale, child: child),
                          child: Container(
                            width: 72,
                            height: 72,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: _gold.withValues(alpha: 0.15),
                              border: Border.all(color: _gold, width: 2),
                              boxShadow: [
                                BoxShadow(
                                  color: _gold.withValues(alpha: 0.3),
                                  blurRadius: 24,
                                  spreadRadius: 4,
                                ),
                              ],
                            ),
                            child: const Icon(
                              Icons.check_rounded,
                              color: _gold,
                              size: 36,
                            ),
                          ),
                        ),

                        const SizedBox(height: 16),

                        // ── Title ──
                        Text(
                          S.of(context).tripAcceptedTitle,
                          style: const TextStyle(
                            color: _gold,
                            fontSize: 28,
                            fontWeight: FontWeight.bold,
                            letterSpacing: -0.5,
                          ),
                        ),

                        const SizedBox(height: 6),

                        // ── Subtitle ──
                        Text(
                          S.of(context).riderIsWaiting(firstName),
                          style: const TextStyle(
                            color: Colors.white54,
                            fontSize: 16,
                          ),
                        ),

                        const SizedBox(height: 20),

                        // ── Rider info card ──
                        Container(
                          decoration: BoxDecoration(
                            color: _card,
                            borderRadius: BorderRadius.circular(20),
                            border: Border.all(
                              color: _gold.withValues(alpha: 0.2),
                              width: 1,
                            ),
                            boxShadow: [
                              BoxShadow(
                                color: _gold.withValues(alpha: 0.08),
                                blurRadius: 20,
                                spreadRadius: 2,
                              ),
                            ],
                          ),
                          padding: const EdgeInsets.all(16),
                          child: Column(
                            children: [
                              // Rider avatar (centered)
                              VerifiedAvatar(
                                uid: widget.riderId?.toString(),
                                role: 'rider',
                                fallbackName: widget.riderInitials,
                                photoUrl: _normalizedPhotoUrl(widget.riderPhotoUrl),
                                isVerified: widget.riderVerified,
                                radius: 28,
                              ),
                              const SizedBox(height: 10),
                              // Rider name (centered)
                              Text(
                                widget.riderName,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 16,
                                  fontWeight: FontWeight.bold,
                                ),
                                textAlign: TextAlign.center,
                              ),
                              const SizedBox(height: 6),
                              // Rating + ETA + distance (centered, miles)
                              Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  if (widget.riderIsNew)
                                    Text(
                                      S.of(context).newRiderLabel,
                                      style: const TextStyle(
                                        color: _gold,
                                        fontSize: 13,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    )
                                  else if (widget.riderRating > 0) ...[
                                    const Icon(Icons.star_rounded,
                                        color: _gold, size: 14),
                                    const SizedBox(width: 4),
                                    Text(
                                      widget.riderRating.toStringAsFixed(1),
                                      style: const TextStyle(
                                        color: Colors.white70,
                                        fontSize: 13,
                                      ),
                                    ),
                                  ],
                                  if (widget.riderIsNew || widget.riderRating > 0)
                                    const SizedBox(width: 12),
                                  Text(
                                    '${widget.etaMinutes} min · '
                                    '${(widget.distToPickupKm * 0.621371).toStringAsFixed(1)} mi',
                                    style: const TextStyle(
                                      color: Colors.white38,
                                      fontSize: 12,
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),

                        const SizedBox(height: 12),

                        // ── Pickup address pill ──
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 16, vertical: 10),
                          decoration: BoxDecoration(
                            color: _gold.withValues(alpha: 0.1),
                            borderRadius: BorderRadius.circular(20),
                            border:
                                Border.all(color: _gold.withValues(alpha: 0.3)),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(Icons.location_on_rounded,
                                  color: _gold, size: 16),
                              const SizedBox(width: 6),
                              Flexible(
                                child: Text(
                                  widget.pickupAddress,
                                  style: const TextStyle(
                                    color: _gold,
                                    fontSize: 13,
                                    fontWeight: FontWeight.w500,
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ],
                          ),
                        ),

                        const SizedBox(height: 16),

                        // ── Gold progress bar (fills over [duration]) ──
                        TweenAnimationBuilder<double>(
                          tween: Tween(begin: 0.0, end: 1.0),
                          duration: widget.duration,
                          curve: Curves.easeInOut,
                          builder: (_, value, __) => ClipRRect(
                            borderRadius: BorderRadius.circular(2),
                            child: LinearProgressIndicator(
                              value: value,
                              backgroundColor: Colors.white12,
                              valueColor:
                                  const AlwaysStoppedAnimation<Color>(_gold),
                              minHeight: 3,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
