import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mapbox_maps_flutter/mapbox_maps_flutter.dart' as mapbox;

import '../config/mapbox_config.dart';
import '../config/map_theme.dart';
import '../config/page_transitions.dart';
import '../services/api_service.dart';
import '../services/analytics_service.dart';
import '../l10n/app_localizations.dart';
import '../widgets/verified_avatar.dart';
import 'home_screen.dart';

/// Full-screen post-ride rating page with frosted-glass map background.
/// Tip percentages are calculated from the actual ride fare.
class RiderRatingScreen extends StatefulWidget {
  const RiderRatingScreen({
    super.key,
    required this.driverName,
    this.tripId,
    this.fare = 0,
    this.driverPhotoUrl,
    this.driverUid,
    this.dropoffLat,
    this.dropoffLng,
  });

  final String driverName;
  final int? tripId;
  final double fare;
  final String? driverPhotoUrl;
  final String? driverUid;
  final double? dropoffLat;
  final double? dropoffLng;

  @override
  State<RiderRatingScreen> createState() => _RiderRatingScreenState();
}

class _RiderRatingScreenState extends State<RiderRatingScreen>
    with SingleTickerProviderStateMixin {
  static const _gold = Color(0xFFE8C547);
  static const _bg = Colors.black;
  static const _surface = Color(0xFF1A1A1F);

  int _ratingStars = 5;
  double _tipAmount = 0;
  bool _customTip = false;
  bool _saveDriver = false;
  final Set<String> _feedbackChips = {};
  String _anonymousFeedback = '';
  bool _submitting = false;

  late AnimationController _entranceCtrl;
  late Animation<double> _fadeAnim;

  @override
  void initState() {
    super.initState();
    _entranceCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 500),
    )..forward();
    _fadeAnim = CurvedAnimation(parent: _entranceCtrl, curve: Curves.easeOut);
  }

  @override
  void dispose() {
    _entranceCtrl.dispose();
    super.dispose();
  }

  String get _firstName => widget.driverName.split(' ').first;

  String _starLabel(S s) {
    switch (_ratingStars) {
      case 1:
        return s.ratingPoor;
      case 2:
        return s.ratingBelowAverage;
      case 3:
        return s.ratingAverage;
      case 4:
        return s.ratingGreat;
      case 5:
        return s.ratingExcellent;
      default:
        return '';
    }
  }

  void _showFeedbackDialog() {
    final controller = TextEditingController(text: _anonymousFeedback);
    final s = S.of(context);
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF2A2A2A),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text(s.leaveAnonymousFeedback,
            style: const TextStyle(color: Colors.white)),
        content: TextField(
          controller: controller,
          maxLines: 4,
          maxLength: 500,
          style: const TextStyle(color: Colors.white),
          decoration: InputDecoration(
            hintText: s.typeMessage,
            hintStyle: TextStyle(color: Colors.white.withValues(alpha: 0.3)),
            border: const OutlineInputBorder(),
            enabledBorder: OutlineInputBorder(
              borderSide:
                  BorderSide(color: Colors.white.withValues(alpha: 0.2)),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text(s.cancel, style: const TextStyle(color: Colors.white70)),
          ),
          ElevatedButton(
            onPressed: () {
              setState(() => _anonymousFeedback = controller.text.trim());
              Navigator.of(ctx).pop();
            },
            style: ElevatedButton.styleFrom(backgroundColor: _gold),
            child: Text(s.save, style: const TextStyle(color: Colors.black)),
          ),
        ],
      ),
    );
  }

  Future<void> _submit() async {
    if (_submitting) return;
    setState(() => _submitting = true);
    HapticFeedback.mediumImpact();

    if (widget.tripId != null) {
      try {
        await ApiService.rateTrip(
          tripId: widget.tripId!,
          stars: _ratingStars,
          tipAmount: _tipAmount,
          comment:
              _anonymousFeedback.isNotEmpty ? _anonymousFeedback : null,
        );
      } catch (_) {}
    }
    AnalyticsService.instance.logRideCompleted('', widget.fare, 0, 0);

    if (!mounted) return;
    _navigateToHome();
  }

  void _skip() {
    if (_submitting) return;
    HapticFeedback.lightImpact();
    _navigateToHome();
  }

  Future<void> _navigateToHome() async {
    // Smooth fade-out of this screen's content first
    await _entranceCtrl.reverse();
    if (!mounted) return;
    Navigator.of(context).pushAndRemoveUntil(
      PageRouteBuilder(
        pageBuilder: (_, __, ___) => const HomeScreen(),
        transitionsBuilder: (_, anim, __, child) => FadeTransition(
          opacity: CurvedAnimation(parent: anim, curve: Curves.easeInOut),
          child: child,
        ),
        transitionDuration: const Duration(milliseconds: 600),
      ),
      (_) => false,
    );
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final fare = widget.fare > 0 ? widget.fare : 23.0;
    final tipPercents = [15, 20, 25];
    final chipOptions = [
      s.friendlyDriver,
      s.cleanCar,
      s.goodDriving,
      s.aboveAndBeyond,
      s.greatMusic,
      s.goodConversation,
    ];

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.light,
      child: Scaffold(
        backgroundColor: _bg,
        body: Stack(
          children: [
            // ── Blurred dark Mapbox map background ──
            Positioned.fill(
              child: IgnorePointer(
                child: mapbox.MapWidget(
                  styleUri: MapboxConfig.styleDark,
                  cameraOptions: mapbox.CameraOptions(
                    center: mapbox.Point(
                      coordinates: mapbox.Position(
                        widget.dropoffLng ?? -80.1918,
                        widget.dropoffLat ?? 25.7617,
                      ),
                    ),
                    zoom: 14.0,
                    pitch: 0,
                  ),
                  onMapCreated: (ctrl) async {
                    await MapTheme.applyNavyGold(ctrl);
                    await ctrl.gestures.updateSettings(
                      mapbox.GesturesSettings(
                        scrollEnabled: false,
                        rotateEnabled: false,
                        pitchEnabled: false,
                        doubleTapToZoomInEnabled: false,
                        doubleTouchToZoomOutEnabled: false,
                        quickZoomEnabled: false,
                        pinchToZoomEnabled: false,
                      ),
                    );
                    await ctrl.compass.updateSettings(
                      mapbox.CompassSettings(enabled: false),
                    );
                    await ctrl.scaleBar.updateSettings(
                      mapbox.ScaleBarSettings(enabled: false),
                    );
                  },
                ),
              ),
            ),
            // ── Soft blur + semi-transparent dark overlay ──
            Positioned.fill(
              child: ClipRect(
                child: BackdropFilter(
                  filter: ui.ImageFilter.blur(sigmaX: 5, sigmaY: 5),
                  child: Container(
                    color: Colors.black.withValues(alpha: 0.45),
                  ),
                ),
              ),
            ),
            // ── Content ──
            FadeTransition(
              opacity: _fadeAnim,
              child: SafeArea(
                child: ListView(
                  physics: const BouncingScrollPhysics(
                    parent: AlwaysScrollableScrollPhysics(),
                  ),
                  padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                  children: [
                    const SizedBox(height: 16),

                    // ── Stars ──
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: List.generate(5, (i) {
                        final filled = i < _ratingStars;
                        return GestureDetector(
                          onTap: () {
                            HapticFeedback.lightImpact();
                            setState(() => _ratingStars = i + 1);
                          },
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 4),
                            child: AnimatedScale(
                              scale: filled ? 1.15 : 1.0,
                              duration: const Duration(milliseconds: 200),
                              child: Icon(
                                filled ? Icons.star_rounded : Icons.star_outline_rounded,
                                size: 48,
                                color: filled
                                    ? _gold
                                    : Colors.white.withValues(alpha: 0.15),
                              ),
                            ),
                          ),
                        );
                      }),
                    ),
                    const SizedBox(height: 8),

                    // ── Star label ──
                    Center(
                      child: AnimatedSwitcher(
                        duration: const Duration(milliseconds: 200),
                        child: Text(
                          _starLabel(s),
                          key: ValueKey(_ratingStars),
                          style: const TextStyle(
                            fontSize: 17,
                            fontWeight: FontWeight.w700,
                            color: _gold,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),

                    // ── "What went well?" ──
                    Center(
                      child: Text(
                        s.whatWentWell,
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                          color: Colors.white.withValues(alpha: 0.9),
                        ),
                      ),
                    ),
                    const SizedBox(height: 14),

                    // ── Feedback chips ──
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      alignment: WrapAlignment.center,
                      children: chipOptions.map((label) {
                        final sel = _feedbackChips.contains(label);
                        return GestureDetector(
                          onTap: () {
                            HapticFeedback.selectionClick();
                            setState(() {
                              sel
                                  ? _feedbackChips.remove(label)
                                  : _feedbackChips.add(label);
                            });
                          },
                          child: AnimatedContainer(
                            duration: const Duration(milliseconds: 200),
                            padding: const EdgeInsets.symmetric(
                              horizontal: 16,
                              vertical: 10,
                            ),
                            decoration: BoxDecoration(
                              color: sel
                                  ? _gold.withValues(alpha: 0.12)
                                  : const Color(0xFF1A1A1F),
                              borderRadius: BorderRadius.circular(22),
                              border: Border.all(
                                color: sel
                                    ? _gold
                                    : _gold.withValues(alpha: 0.15),
                                width: sel ? 1.5 : 1,
                              ),
                            ),
                            child: Text(
                              label,
                              style: TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w600,
                                color: sel
                                    ? _gold
                                    : Colors.white.withValues(alpha: 0.6),
                              ),
                            ),
                          ),
                        );
                      }).toList(),
                    ),
                    const SizedBox(height: 16),

                    // ── Leave anonymous feedback ──
                    GestureDetector(
                      onTap: _showFeedbackDialog,
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Text(
                            s.leaveAnonymousFeedback,
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w500,
                              color: Colors.white.withValues(alpha: 0.45),
                            ),
                          ),
                          const SizedBox(width: 6),
                          Icon(
                            Icons.edit_note_rounded,
                            size: 18,
                            color: Colors.white.withValues(alpha: 0.35),
                          ),
                        ],
                      ),
                    ),

                    const SizedBox(height: 22),

                    // ── Glass divider ──
                    Container(
                      height: 1,
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          colors: [
                            Colors.transparent,
                            _gold.withValues(alpha: 0.15),
                            Colors.transparent,
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 22),

                    // ── Tip section ──
                    Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                s.tipFor(_firstName),
                                style: const TextStyle(
                                  fontSize: 20,
                                  fontWeight: FontWeight.w800,
                                  color: Colors.white,
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                s.tipGoesToDriver,
                                style: TextStyle(
                                  fontSize: 13,
                                  color: Colors.white.withValues(alpha: 0.45),
                                ),
                              ),
                            ],
                          ),
                        ),
                        VerifiedAvatar(
                          radius: 24,
                          fallbackName: widget.driverName,
                          photoUrl: widget.driverPhotoUrl,
                          uid: widget.driverUid,
                          role: 'driver',
                          isVerified: true,
                        ),
                      ],
                    ),
                    const SizedBox(height: 18),

                    // ── Percentage tip buttons ──
                    Row(
                      children: tipPercents.map((pct) {
                        final amt =
                            double.parse((fare * pct / 100).toStringAsFixed(2));
                        final sel = _tipAmount == amt && !_customTip;
                        return Expanded(
                          child: Padding(
                            padding: EdgeInsets.only(
                              right: pct != tipPercents.last ? 10 : 0,
                            ),
                            child: GestureDetector(
                              onTap: () {
                                HapticFeedback.selectionClick();
                                setState(() {
                                  _customTip = false;
                                  _tipAmount = sel ? 0 : amt;
                                });
                              },
                              child: AnimatedContainer(
                                duration: const Duration(milliseconds: 200),
                                height: 68,
                                decoration: BoxDecoration(
                                  color: sel
                                      ? _gold.withValues(alpha: 0.10)
                                      : const Color(0xFF1A1A1F),
                                  borderRadius: BorderRadius.circular(14),
                                  border: Border.all(
                                    color: sel
                                        ? _gold
                                        : _gold.withValues(alpha: 0.15),
                                    width: sel ? 2 : 1,
                                  ),
                                  boxShadow: sel
                                      ? [
                                          BoxShadow(
                                            color: _gold.withValues(alpha: 0.15),
                                            blurRadius: 8,
                                          ),
                                        ]
                                      : null,
                                ),
                                child: Column(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    Text(
                                      '$pct%',
                                      style: TextStyle(
                                        fontSize: 17,
                                        fontWeight: FontWeight.w800,
                                        color: sel
                                            ? _gold
                                            : Colors.white.withValues(alpha: 0.8),
                                      ),
                                    ),
                                    const SizedBox(height: 2),
                                    Text(
                                      '\$${amt.toStringAsFixed(2)}',
                                      style: TextStyle(
                                        fontSize: 13,
                                        fontWeight: FontWeight.w500,
                                        color: sel
                                            ? _gold.withValues(alpha: 0.8)
                                            : Colors.white.withValues(alpha: 0.4),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        );
                      }).toList(),
                    ),
                    const SizedBox(height: 12),

                    // Custom tip link
                    Center(
                      child: GestureDetector(
                        onTap: () => setState(() {
                          _customTip = !_customTip;
                          if (!_customTip) _tipAmount = 0;
                        }),
                        child: Text(
                          _customTip ? s.cancelCustomTip : s.enterCustomAmount,
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                            color: _gold.withValues(alpha: 0.65),
                          ),
                        ),
                      ),
                    ),

                    if (_customTip) ...[
                      const SizedBox(height: 12),
                      Center(
                        child: SizedBox(
                          width: 160,
                          height: 52,
                          child: TextField(
                            keyboardType: const TextInputType.numberWithOptions(
                              decimal: true,
                            ),
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 22,
                              fontWeight: FontWeight.w700,
                            ),
                            textAlign: TextAlign.center,
                            decoration: InputDecoration(
                              prefixText: '\$ ',
                              prefixStyle: TextStyle(
                                color: Colors.white.withValues(alpha: 0.5),
                                fontSize: 22,
                                fontWeight: FontWeight.w700,
                              ),
                              hintText: '0',
                              hintStyle: TextStyle(
                                color: Colors.white.withValues(alpha: 0.3),
                              ),
                              filled: true,
                              fillColor: const Color(0xFF1A1A1F),
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(14),
                                borderSide: const BorderSide(color: _gold),
                              ),
                              enabledBorder: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(14),
                                borderSide: const BorderSide(color: _gold),
                              ),
                              focusedBorder: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(14),
                                borderSide:
                                    const BorderSide(color: _gold, width: 2),
                              ),
                              contentPadding:
                                  const EdgeInsets.symmetric(vertical: 12),
                            ),
                            onChanged: (v) {
                              final parsed = double.tryParse(v);
                              setState(() => _tipAmount = parsed ?? 0);
                            },
                          ),
                        ),
                      ),
                    ],
                    const SizedBox(height: 22),

                    // ── Favorite driver ──
                    GestureDetector(
                      onTap: () {
                        HapticFeedback.selectionClick();
                        setState(() => _saveDriver = !_saveDriver);
                      },
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(14),
                        child: BackdropFilter(
                          filter: ui.ImageFilter.blur(sigmaX: 8, sigmaY: 8),
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 16,
                              vertical: 16,
                            ),
                            decoration: BoxDecoration(
                              color: const Color(0xFF1A1A1F).withValues(alpha: 0.88),
                              borderRadius: BorderRadius.circular(14),
                              border: Border.all(
                                color: _saveDriver
                                    ? _gold.withValues(alpha: 0.5)
                                    : _gold.withValues(alpha: 0.12),
                              ),
                              boxShadow: [
                                BoxShadow(
                                  color: Colors.black.withValues(alpha: 0.3),
                                  blurRadius: 12,
                                  offset: const Offset(0, 4),
                                ),
                              ],
                            ),
                            child: Row(
                              children: [
                                AnimatedContainer(
                                  duration: const Duration(milliseconds: 200),
                                  width: 26,
                                  height: 26,
                                  decoration: BoxDecoration(
                                    color:
                                        _saveDriver ? _gold : Colors.transparent,
                                    borderRadius: BorderRadius.circular(7),
                                    border: Border.all(
                                      color: _saveDriver
                                          ? _gold
                                          : _gold.withValues(alpha: 0.3),
                                      width: 2,
                                    ),
                                  ),
                                  child: _saveDriver
                                      ? const Icon(Icons.check_rounded,
                                          size: 18, color: Colors.black)
                                      : null,
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        s.favoriteThisDriver,
                                        style: const TextStyle(
                                          fontSize: 16,
                                          fontWeight: FontWeight.w700,
                                          color: Colors.white,
                                        ),
                                      ),
                                      const SizedBox(height: 2),
                                      Text(
                                        s.favoriteDriverNote,
                                        style: TextStyle(
                                          fontSize: 12,
                                          color:
                                              Colors.white.withValues(alpha: 0.45),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 28),

                    // ── Send button ──
                    Container(
                      width: double.infinity,
                      height: 56,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(28),
                        gradient: const LinearGradient(
                          colors: [
                            Color(0xFFE8C547),
                            Color(0xFFD4AF37),
                            Color(0xFFC49B30),
                          ],
                        ),
                        boxShadow: [
                          BoxShadow(
                            color: _gold.withValues(alpha: 0.3),
                            blurRadius: 12,
                            offset: const Offset(0, 4),
                          ),
                        ],
                      ),
                      child: Material(
                        color: Colors.transparent,
                        child: InkWell(
                          onTap: _submitting ? null : _submit,
                          borderRadius: BorderRadius.circular(28),
                          child: Center(
                            child: _submitting
                                ? const SizedBox(
                                    width: 22,
                                    height: 22,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2.5,
                                      color: Colors.black54,
                                    ),
                                  )
                                : Text(
                                    s.send,
                                    style: const TextStyle(
                                      fontSize: 18,
                                      fontWeight: FontWeight.w800,
                                      color: Colors.black,
                                    ),
                                  ),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 14),

                    // ── Skip link ──
                    Center(
                      child: GestureDetector(
                        onTap: _submitting ? null : _skip,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 8),
                          child: Text(
                            s.skip,
                            style: TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w600,
                              color: Colors.white.withValues(alpha: 0.5),
                            ),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
