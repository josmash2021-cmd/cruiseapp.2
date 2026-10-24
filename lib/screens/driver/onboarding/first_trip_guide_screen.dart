import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../config/page_transitions.dart';
import '../../../l10n/app_localizations.dart';
import '../../../utils/selfie_variant.dart';
import '../../../widgets/neu_style.dart';
import '../../../widgets/selfie_verify_card.dart';
import '../driver_online_screen.dart';

/// First-trip guide — 6 swipeable pages shown after approval. Since
/// 2026-10-22 it is MANDATORY in the celebration flow: every exit of the
/// bank page (linked, Skip, back) lands here, never straight home. The
/// top Skip AVANZA a la página siguiente (user spec 2026-10-16); solo la
/// última página termina el flujo y va al home (y marca
/// `first_trip_guide_seen_v1`).
///
/// 2026-10-23 (owner mockup): page 1 is the DRESS CODE (tier×gender flat-lay
/// `guide_dress_{vip,std}_{m,f}.png`) gated by an Entendido button that
/// morphs into a white check — Next/Skip and the PageView swipe stay locked
/// (`NeverScrollableScrollPhysics`) until the morph completes; page 6 is the
/// 24 h SELFIE VERIFICATION (`guide_selfie_{vip,std}_{m,f}.png`) with a
/// one-shot camera flash over the card. Pages 2–5 are the original four,
/// re-numbered.
///
/// The variant is resolved ONCE at open: VIP when the driver's ACTIVE
/// vehicle is vip/black (`ApiService.getVehicles`), women's photos when the
/// cached profile gender is 'female' (`UserSession.getUser`) — anything
/// unknown falls back to the men's standard variant.
///
/// Page 2 is a static, non-interactive replica of the real offer card from
/// `driver_online_widgets.dart` (`_buildNormalCardContent`): fare + "+ Tips",
/// the "$/hr est. rate" line, the min/mi metric pills, the two-stop address
/// rail (gold pickup dot joined to the white dropoff ring), the rider row,
/// and the car inside a gold countdown ring (frozen — no live timer).
class FirstTripGuideScreen extends StatefulWidget {
  const FirstTripGuideScreen({super.key});

  @override
  State<FirstTripGuideScreen> createState() => _FirstTripGuideScreenState();
}

class _FirstTripGuideScreenState extends State<FirstTripGuideScreen> {
  static const _navy = Color(0xFF14141A);
  static const _gold = Color(0xFFE8C547);

  final _pageCtrl = PageController();
  int _page = 0;

  /// Dress-code gate: page 1 cannot be skipped or swiped past until its
  /// Entendido morph completes (user spec 2026-10-23).
  bool _dressAcknowledged = false;

  /// The guide's tier×gender variant, resolved once at open.
  bool _isVip = false;
  bool _isFemale = false;

  bool get _gateLocked => _page == 0 && !_dressAcknowledged;

  @override
  void initState() {
    super.initState();
    _resolveVariant();
  }

  Future<void> _resolveVariant() async {
    // One shared source (utils/selfie_variant.dart) — the selfie-check
    // screen resolves the exact same way.
    final variant = await resolveSelfieVariant();
    if (!mounted) return;
    final vip = variant.startsWith('vip');
    final female = variant.endsWith('_f');
    if (female != _isFemale || vip != _isVip) {
      setState(() {
        _isFemale = female;
        _isVip = vip;
      });
    }
  }

  @override
  void dispose() {
    _pageCtrl.dispose();
    super.dispose();
  }

  Future<void> _finish() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('first_trip_guide_seen_v1', true);
    } catch (_) {}
    if (!mounted) return;
    Navigator.of(context).pushAndRemoveUntil(
      onboardingFadeSlideRoute(const DriverOnlineScreen()),
      (_) => false,
    );
  }

  void _next() {
    if (_gateLocked) return;
    if (_page >= 5) {
      _finish();
      return;
    }
    _pageCtrl.nextPage(
      duration: const Duration(milliseconds: 320),
      curve: Curves.easeInOut,
    );
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);

    final pages = <Widget>[
      _DressCodePage(
        vip: _isVip,
        female: _isFemale,
        active: _page == 0,
        onAcknowledged: () => setState(() => _dressAcknowledged = true),
      ),
      _GuidePage(
        data: _GuidePageData(
          number: 2,
          title: s.guideGoOnlineTitle,
          body: s.guideGoOnlineBody,
          art: const _StaticOfferCard(),
        ),
        active: _page == 1,
      ),
      _GuidePage(
        data: _GuidePageData(
          number: 3,
          title: s.guideNavigateTitle,
          body: s.guideNavigateBody,
          art: const _GuideImageArt(
              number: 3, asset: 'assets/images/onboarding/guide_nav.png'),
        ),
        active: _page == 2,
      ),
      _GuidePage(
        data: _GuidePageData(
          number: 4,
          title: s.guideArriveTitle,
          body: s.guideArriveBody,
          art: const _GuideImageArt(
              number: 4, asset: 'assets/images/onboarding/guide_pickup.png'),
        ),
        active: _page == 3,
      ),
      _GuidePage(
        data: _GuidePageData(
          number: 5,
          title: s.guideFinishTitle,
          body: s.guideFinishBody,
          art: const _GuideImageArt(
              number: 5, asset: 'assets/images/onboarding/guide_paid.png'),
        ),
        active: _page == 4,
      ),
      _SelfieVerifyPage(
        vip: _isVip,
        female: _isFemale,
        active: _page == 5,
      ),
    ];

    return Scaffold(
      backgroundColor: _navy,
      body: SafeArea(
        child: Column(
          children: [
            // Title left ("Instructions", user spec 2026-08-28) + Skip right.
            // 2026-10-16 (user spec: "el skip debe ir a la siguiente pagina
            // de las instrucciones, no al home"): Skip AVANZA una página;
            // solo en la última termina el flujo (misma acción que _next).
            Row(
              children: [
                Padding(
                  padding: const EdgeInsets.only(left: 24),
                  child: Text(
                    s.instructionsTitle,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 17,
                      fontWeight: FontWeight.w800,
                      letterSpacing: -0.2,
                    ),
                  ),
                ),
                const Spacer(),
                // The dress-code gate dims Skip on page 1 until the
                // Entendido morph completes — same lock as Next below.
                Opacity(
                  opacity: _gateLocked ? 0.4 : 1.0,
                  child: TextButton(
                    onPressed: _gateLocked ? null : _next,
                    child: Text(
                      s.skip,
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.55),
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
              ],
            ),

            Expanded(
              child: PageView.builder(
                controller: _pageCtrl,
                // The swipe cannot bypass the dress-code gate either.
                physics: _gateLocked
                    ? const NeverScrollableScrollPhysics()
                    : const BouncingScrollPhysics(),
                itemCount: pages.length,
                onPageChanged: (i) => setState(() => _page = i),
                itemBuilder: (_, i) => pages[i],
              ),
            ),

            // Dots — the active one is an elongated gold pill.
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: List.generate(pages.length, (i) {
                final active = i == _page;
                return AnimatedContainer(
                  duration: const Duration(milliseconds: 220),
                  margin: const EdgeInsets.symmetric(horizontal: 4),
                  width: active ? 22 : 7,
                  height: 7,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(4),
                    color: active
                        ? _gold
                        : Colors.white.withValues(alpha: 0.22),
                  ),
                );
              }),
            ),

            const SizedBox(height: 24),

            // The Next button lights up (fade from the dimmed gate state)
            // the moment the dress-code acknowledgment completes.
            AnimatedOpacity(
              duration: const Duration(milliseconds: 300),
              opacity: _gateLocked ? 0.4 : 1.0,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 28),
                child: SizedBox(
                  width: double.infinity,
                  height: 56,
                  child: ElevatedButton(
                    onPressed: _gateLocked ? null : _next,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: _gold,
                      foregroundColor: Colors.black,
                      elevation: 4,
                      shadowColor: _gold.withValues(alpha: 0.4),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(18),
                      ),
                    ),
                    child: Text(
                      _page == pages.length - 1 ? s.startDriving : s.next,
                      style: const TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 0.3,
                      ),
                    ),
                  ),
                ),
              ),
            ),

            const SizedBox(height: 28),
          ],
        ),
      ),
    );
  }
}

class _GuidePageData {
  final int number;
  final String title;
  final String body;
  final Widget art;
  const _GuidePageData({
    required this.number,
    required this.title,
    required this.body,
    required this.art,
  });
}

/// Gold circular badge of the new guide pages: the page number floats on the
/// card's top-left corner, the page icon on the top-right.
class _GoldCircleBadge extends StatelessWidget {
  static const _gold = Color(0xFFE8C547);

  final Widget child;
  const _GoldCircleBadge({required this.child});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 34,
      height: 34,
      decoration: const BoxDecoration(shape: BoxShape.circle, color: _gold),
      child: Center(child: child),
    );
  }
}

/// White check drawn stroke-by-stroke for the Entendido morph (page 1).
class _CheckPainter extends CustomPainter {
  final double progress;
  const _CheckPainter(this.progress);

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.white
      ..strokeWidth = 4
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;
    final p1 = Offset(size.width * 0.28, size.height * 0.52);
    final p2 = Offset(size.width * 0.45, size.height * 0.68);
    final p3 = Offset(size.width * 0.73, size.height * 0.32);
    final len1 = (p2 - p1).distance;
    final len2 = (p3 - p2).distance;
    final drawn = ((len1 + len2) * progress).clamp(0.0, len1 + len2);
    final path = Path()..moveTo(p1.dx, p1.dy);
    if (drawn <= len1) {
      final t = drawn / len1;
      path.lineTo(p1.dx + (p2.dx - p1.dx) * t, p1.dy + (p2.dy - p1.dy) * t);
    } else {
      path.lineTo(p2.dx, p2.dy);
      final t = (drawn - len1) / len2;
      path.lineTo(p2.dx + (p3.dx - p2.dx) * t, p2.dy + (p3.dy - p2.dy) * t);
    }
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(_CheckPainter old) => old.progress != progress;
}

/// Page 1 — the tier×gender dress code (owner mockup 2026-10-23). The
/// Entendido button sits BETWEEN the card and the title; tapping it morphs
/// it into a gold circle that draws a white check, holds, then fades away —
/// only then does `onAcknowledged` unlock the guide's Next/Skip/swipe.
class _DressCodePage extends StatefulWidget {
  final bool vip;
  final bool female;
  final bool active;
  final VoidCallback onAcknowledged;

  const _DressCodePage({
    required this.vip,
    required this.female,
    required this.active,
    required this.onAcknowledged,
  });

  @override
  State<_DressCodePage> createState() => _DressCodePageState();
}

class _DressCodePageState extends State<_DressCodePage>
    with SingleTickerProviderStateMixin {
  static const _gold = Color(0xFFE8C547);
  static const _cardNavy = Color(0xFF1C1C24);

  /// One controller with per-element intervals — the cascade entrance
  /// language of the rest of the app (~800 ms total, easeOutCubic).
  late final AnimationController _entry;

  /// Traces the white check inside the morphed gold circle (~300 ms).
  late final AnimationController _check;

  /// 0 = button · 1 = morphing (circle + check) · 2 = gone (ack done).
  int _ack = 0;

  @override
  void initState() {
    super.initState();
    _entry = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 800),
    )..forward();
    _check = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
    );
    _check.addStatusListener((st) {
      if (st != AnimationStatus.completed) return;
      // Hold the drawn check a beat, then fade the whole control away.
      Future.delayed(const Duration(milliseconds: 350), () {
        if (!mounted || _ack != 1) return;
        setState(() => _ack = 2);
        widget.onAcknowledged();
      });
    });
  }

  @override
  void dispose() {
    _entry.dispose();
    _check.dispose();
    super.dispose();
  }

  void _onAck() {
    if (_ack != 0) return;
    setState(() => _ack = 1);
    _check.forward(from: 0);
  }

  Widget _cascade(Widget child, double begin, double end) {
    final anim = CurvedAnimation(
      parent: _entry,
      curve: Interval(begin, end, curve: Curves.easeOutCubic),
    );
    return FadeTransition(
      opacity: anim,
      child: SlideTransition(
        position:
            Tween<Offset>(begin: const Offset(0, 0.06), end: Offset.zero)
                .animate(anim),
        child: child,
      ),
    );
  }

  Widget _chip(Widget icon, String label) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.06),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: _gold.withValues(alpha: 0.35)),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            icon,
            const SizedBox(width: 5),
            Flexible(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCard(String variant, List<String> labels) {
    return Stack(
      clipBehavior: Clip.none,
      children: [
        Container(
          width: double.infinity,
          padding: const EdgeInsets.fromLTRB(18, 22, 18, 18),
          decoration: BoxDecoration(
            color: _cardNavy,
            borderRadius: BorderRadius.circular(22),
            border: Border.all(color: _gold.withValues(alpha: 0.55)),
          ),
          child: Column(
            children: [
              SizedBox(
                height: 210,
                child: Image.asset(
                  'assets/images/onboarding/guide_dress_$variant.png',
                  fit: BoxFit.contain,
                  // OTA patches do NOT carry new assets (proven on device
                  // 2026-10-23): on a store build that predates this PNG the
                  // photo is simply missing — a dignified stand-in beats an
                  // empty void until the next store build lands.
                  errorBuilder: (context, error, stackTrace) => Center(
                    child: Icon(
                      Icons.person_outline_rounded,
                      color: _gold.withValues(alpha: 0.7),
                      size: 96,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 14),
              Row(
                children: [
                  // Store-font rule (2026-10-23, proven on the owner's
                  // phone): the installed build carries a tree-shaken
                  // MaterialIcons font — glyphs first used by OTA code paint
                  // "?". Every icon below exists in the store-era font
                  // (auto_awesome_ROUNDED was in; auto_awesome was not).
                  _chip(
                      const Icon(Icons.auto_awesome_rounded,
                          color: _gold, size: 15),
                      labels[0]),
                  const SizedBox(width: 8),
                  _chip(
                      const Icon(Icons.verified_user_outlined,
                          color: _gold, size: 15),
                      labels[1]),
                  const SizedBox(width: 8),
                  _chip(
                    widget.vip
                        ? const Icon(Icons.workspace_premium_rounded,
                            color: _gold, size: 15)
                        : const Icon(Icons.thumb_up_rounded,
                            color: _gold, size: 15),
                    labels[2],
                  ),
                ],
              ),
            ],
          ),
        ),
        const Positioned(
          top: -12,
          left: -8,
          child: _GoldCircleBadge(
            child: Text(
              '1',
              style: TextStyle(
                color: Color(0xFF14141A),
                fontWeight: FontWeight.w800,
                fontSize: 15,
              ),
            ),
          ),
        ),
        Positioned(
          top: -12,
          right: -8,
          child: _GoldCircleBadge(
            // Glyphs that EXIST in the store-era subsetted font (2026-10-23
            // device proof: workspace_premium_outlined/checkroom painted
            // "?" — the _rounded/person variants are in).
            child: widget.vip
                ? const Icon(Icons.workspace_premium_rounded,
                    color: Color(0xFF14141A), size: 18)
                : const Icon(Icons.person_outline_rounded,
                    color: Color(0xFF14141A), size: 18),
          ),
        ),
      ],
    );
  }

  Widget _buildAckButton(S s) {
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 300),
      transitionBuilder: (child, anim) => FadeTransition(
        opacity: anim,
        child: ScaleTransition(scale: anim, child: child),
      ),
      child: switch (_ack) {
        0 => SizedBox(
            key: const ValueKey('ack-btn'),
            width: double.infinity,
            height: 52,
            child: ElevatedButton(
              onPressed: _onAck,
              style: ElevatedButton.styleFrom(
                backgroundColor: _gold,
                foregroundColor: Colors.black,
                elevation: 4,
                shadowColor: _gold.withValues(alpha: 0.4),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                ),
              ),
              child: Text(
                s.onlineIntroUnderstood,
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
          ),
        1 => Container(
            key: const ValueKey('ack-circle'),
            width: 52,
            height: 52,
            decoration: const BoxDecoration(
              shape: BoxShape.circle,
              color: _gold,
            ),
            child: AnimatedBuilder(
              animation: _check,
              builder: (ctx, _) =>
                  CustomPaint(painter: _CheckPainter(_check.value)),
            ),
          ),
        _ => const SizedBox(key: ValueKey('ack-gone'), height: 52),
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final variant = '${widget.vip ? 'vip' : 'std'}_${widget.female ? 'f' : 'm'}';
    final labels = widget.vip
        ? [s.dressChipElegant, s.dressChipProfessional, s.dressChipPremium]
        : widget.female
            ? [
                s.dressChipCleanF,
                s.dressChipProfessional,
                s.dressChipComfortable,
              ]
            : [
                s.dressChipCleanM,
                s.dressChipProfessional,
                s.dressChipPresentable,
              ];
    return AnimatedOpacity(
      duration: const Duration(milliseconds: 450),
      curve: Curves.easeOut,
      opacity: widget.active ? 1.0 : 0.0,
      child: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 24),
        child: Column(
          children: [
            const SizedBox(height: 20),
            _cascade(_buildCard(variant, labels), 0.0, 0.45),
            const SizedBox(height: 22),
            _cascade(_buildAckButton(s), 0.25, 0.6),
            const SizedBox(height: 26),
            _cascade(
              Text(
                widget.vip ? s.dressVipTitle : s.dressStdTitle,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 24,
                  fontWeight: FontWeight.w800,
                  letterSpacing: -0.4,
                ),
              ),
              0.45,
              0.8,
            ),
            const SizedBox(height: 14),
            _cascade(
              Text(
                widget.vip
                    ? (widget.female ? s.dressBodyVipF : s.dressBodyVipM)
                    : (widget.female ? s.dressBodyStdF : s.dressBodyStdM),
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.6),
                  fontSize: 15,
                  height: 1.55,
                ),
              ),
              0.6,
              1.0,
            ),
            const SizedBox(height: 16),
          ],
        ),
      ),
    );
  }
}

/// Page 6 — the 24 h selfie verification (owner mockup 2026-10-23): the
/// SHARED SelfieVerifyCard (one design source with the selfie-check
/// screen), here with its one-shot white shutter flash over the photo —
/// fired by the card itself, once per entry into view, never in a loop.
class _SelfieVerifyPage extends StatefulWidget {
  final bool vip;
  final bool female;
  final bool active;

  const _SelfieVerifyPage({
    required this.vip,
    required this.female,
    required this.active,
  });

  @override
  State<_SelfieVerifyPage> createState() => _SelfieVerifyPageState();
}

class _SelfieVerifyPageState extends State<_SelfieVerifyPage>
    with SingleTickerProviderStateMixin {

  late final AnimationController _entry;

  @override
  void initState() {
    super.initState();
    _entry = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 800),
    )..forward();
  }

  @override
  void dispose() {
    _entry.dispose();
    super.dispose();
  }

  Widget _cascade(Widget child, double begin, double end) {
    final anim = CurvedAnimation(
      parent: _entry,
      curve: Interval(begin, end, curve: Curves.easeOutCubic),
    );
    return FadeTransition(
      opacity: anim,
      child: SlideTransition(
        position:
            Tween<Offset>(begin: const Offset(0, 0.06), end: Offset.zero)
                .animate(anim),
        child: child,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final variant = '${widget.vip ? 'vip' : 'std'}_${widget.female ? 'f' : 'm'}';
    return AnimatedOpacity(
      duration: const Duration(milliseconds: 450),
      curve: Curves.easeOut,
      opacity: widget.active ? 1.0 : 0.0,
      child: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 24),
        child: Column(
          children: [
            const SizedBox(height: 20),
            _cascade(
              SelfieVerifyCard(
                variant: variant,
                flash: true,
                active: widget.active,
                badge: '6',
              ),
              0.0,
              0.45,
            ),
            const SizedBox(height: 26),
            _cascade(
              Text(
                s.selfieVerifyTitle,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 24,
                  fontWeight: FontWeight.w800,
                  letterSpacing: -0.4,
                ),
              ),
              0.35,
              0.7,
            ),
            const SizedBox(height: 14),
            _cascade(
              Text(
                widget.vip ? s.selfieBodyVip : s.selfieBodyStd,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.6),
                  fontSize: 15,
                  height: 1.55,
                ),
              ),
              0.6,
              1.0,
            ),
            const SizedBox(height: 18),
            _cascade(
              SelfieVerifyChips(vip: widget.vip),
              0.72,
              1.0,
            ),
            const SizedBox(height: 16),
          ],
        ),
      ),
    );
  }
}

class _GuidePage extends StatelessWidget {
  final _GuidePageData data;
  final bool active;
  const _GuidePage({required this.data, required this.active});

  @override
  Widget build(BuildContext context) {
    // Content fades/rises in softly when the page becomes current — never
    // an abrupt swap (user spec: fluid continuous fade, ~450 ms).
    return AnimatedOpacity(
      duration: const Duration(milliseconds: 450),
      curve: Curves.easeOut,
      opacity: active ? 1.0 : 0.0,
      child: AnimatedSlide(
        duration: const Duration(milliseconds: 450),
        curve: Curves.easeOut,
        offset: active ? Offset.zero : const Offset(0, 0.04),
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Column(
            children: [
              const SizedBox(height: 8),
              data.art,
              const SizedBox(height: 28),
              Text(
                data.title,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 24,
                  fontWeight: FontWeight.w800,
                  letterSpacing: -0.4,
                ),
              ),
              const SizedBox(height: 14),
              Text(
                data.body,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.6),
                  fontSize: 15,
                  height: 1.55,
                ),
              ),
              const SizedBox(height: 16),
            ],
          ),
        ),
      ),
    );
  }
}

/// Art card for pages 3–5: the provided illustration, edge-to-edge in the
/// same glowing card frame, with the page number in gold at the top corner.
class _GuideImageArt extends StatelessWidget {
  static const _gold = Color(0xFFE8C547);

  final int number;
  final String asset;
  const _GuideImageArt({required this.number, required this.asset});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 300,
      width: double.infinity,
      child: Stack(
        children: [
          Positioned.fill(
            child: Container(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(24),
                boxShadow: [
                  BoxShadow(
                    color: _gold.withValues(alpha: 0.12),
                    blurRadius: 60,
                    spreadRadius: -6,
                  ),
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.5),
                    offset: const Offset(0, 16),
                    blurRadius: 32,
                    spreadRadius: -8,
                  ),
                ],
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(24),
                child: Image.asset(asset, fit: BoxFit.cover),
              ),
            ),
          ),
          Positioned(
            top: 12,
            left: 12,
            child: Container(
              width: 30,
              height: 30,
              decoration: const BoxDecoration(
                shape: BoxShape.circle,
                color: _gold,
              ),
              child: Center(
                child: Text(
                  '$number',
                  style: const TextStyle(
                    color: Color(0xFF14141A),
                    fontWeight: FontWeight.w800,
                    fontSize: 14,
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

/// Static replica of the live offer card — coherent demo data, a simulated
/// 20 s countdown ring that restarts on every visit, no gestures. Mirrored
/// from `_buildNormalCardContent` in `driver_online_widgets.dart` (plus the
/// gold Accept stadium that floats under the real card); if the real card
/// changes layout, update this to match.
class _StaticOfferCard extends StatefulWidget {
  const _StaticOfferCard();

  @override
  State<_StaticOfferCard> createState() => _StaticOfferCardState();
}

class _StaticOfferCardState extends State<_StaticOfferCard>
    with SingleTickerProviderStateMixin {
  static const _gold = Color(0xFFE8C547);

  /// The live card gives 20 s to accept — the replica sweeps the ring over
  /// the same window so the page teaches the real mechanic.
  late final AnimationController _countdown;

  @override
  void initState() {
    super.initState();
    _countdown = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 20),
    )..forward();
  }

  @override
  void dispose() {
    _countdown.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Stack(
          clipBehavior: Clip.none,
          children: [
        Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: neuSurface,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.white.withValues(alpha: 0.05)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.55),
            offset: const Offset(0, 16),
            blurRadius: 32,
            spreadRadius: -8,
          ),
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.35),
            offset: const Offset(0, 4),
            blurRadius: 10,
            spreadRadius: -3,
          ),
          BoxShadow(
            color: Colors.white.withValues(alpha: 0.06),
            offset: const Offset(0, -1),
            blurRadius: 2,
          ),
        ],
      ),
      child: Stack(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 14),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // ── Fare + "+ Tips" + hourly, with the countdown ring ──
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.baseline,
                            textBaseline: TextBaseline.alphabetic,
                            children: [
                              const Text(
                                '\$6.44',
                                style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 30,
                                  fontWeight: FontWeight.w800,
                                  letterSpacing: -0.5,
                                ),
                              ),
                              const SizedBox(width: 8),
                              Text(
                                s.plusTips,
                                style: const TextStyle(
                                  color: _gold,
                                  fontSize: 13,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 4),
                          Text(
                            s.offerHourlyRate('29.72'),
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 12.5,
                            ),
                          ),
                          const SizedBox(height: 10),
                          Row(
                            children: [
                              _metric(
                                  const Icon(Icons.access_time_rounded,
                                      color: _gold, size: 12),
                                  s.offerDuration(13)),
                              const SizedBox(width: 8),
                              _metric(
                                  const Icon(Icons.straighten_rounded,
                                      color: _gold, size: 12),
                                  '6.1 mi'),
                            ],
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 10),
                    // The car in the gold countdown ring — simulated 20 s
                    // sweep, restarted every time this page is built.
                    Container(
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: neuSurface,
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.5),
                            offset: const Offset(0, 5),
                            blurRadius: 12,
                            spreadRadius: -3,
                          ),
                          BoxShadow(
                            color: Colors.white.withValues(alpha: 0.07),
                            offset: const Offset(0, -1),
                            blurRadius: 2,
                          ),
                        ],
                      ),
                      child: SizedBox(
                        width: 64,
                        height: 64,
                        child: Stack(
                          alignment: Alignment.center,
                          children: [
                            SizedBox(
                              width: 64,
                              height: 64,
                              child: AnimatedBuilder(
                                animation: _countdown,
                                builder: (ctx, _) =>
                                    CircularProgressIndicator(
                                  value: 1.0 - _countdown.value,
                                  strokeWidth: 3.5,
                                  color: _gold,
                                  backgroundColor:
                                      Colors.white.withValues(alpha: 0.10),
                                ),
                              ),
                            ),
                            Padding(
                              padding: const EdgeInsets.all(14),
                              child: Image.asset(
                                'assets/images/cruise_logo.png',
                                fit: BoxFit.contain,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),

                const SizedBox(height: 18),

                // ── Pickup, then dropoff — one rail, gold dot → white ring ──
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 14, vertical: 12),
                  decoration: neuBox(radius: 16),
                  child: IntrinsicHeight(
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        SizedBox(
                          width: 16,
                          child: Column(
                            children: [
                              const SizedBox(height: 4),
                              // Pickup: gold ring with a solid dot inside.
                              Container(
                                width: 11,
                                height: 11,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  border:
                                      Border.all(color: _gold, width: 1.5),
                                ),
                                child: Center(
                                  child: Container(
                                    width: 4,
                                    height: 4,
                                    decoration: const BoxDecoration(
                                      color: _gold,
                                      shape: BoxShape.circle,
                                    ),
                                  ),
                                ),
                              ),
                              Expanded(
                                child: Container(
                                  width: 1.5,
                                  margin:
                                      const EdgeInsets.symmetric(vertical: 3),
                                  decoration: BoxDecoration(
                                    gradient: LinearGradient(
                                      begin: Alignment.topCenter,
                                      end: Alignment.bottomCenter,
                                      colors: [
                                        _gold.withValues(alpha: 0.7),
                                        Colors.white.withValues(alpha: 0.35),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                              // Dropoff: hollow white ring.
                              Container(
                                width: 11,
                                height: 11,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  border: Border.all(
                                      color: Colors.white, width: 1.5),
                                ),
                              ),
                              const SizedBox(height: 4),
                            ],
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              _stopText(
                                s.offerAway(4, '1.8'),
                                '3412 Canopy Drive, Pelham, Alabama',
                              ),
                              const SizedBox(height: 22),
                              _stopText(
                                s.offerTrip(9, '4.3'),
                                '3659 Lorna Road, Hoover, Alabama',
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),

                const SizedBox(height: 16),
                Container(
                    height: 1, color: Colors.white.withValues(alpha: 0.05)),
                const SizedBox(height: 16),

                // ── Who is riding ──
                Row(
                  children: [
                    Container(
                      width: 30,
                      height: 30,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: Colors.white.withValues(alpha: 0.15),
                          width: 1,
                        ),
                      ),
                      child: const Center(
                        child: Text(
                          'J',
                          style: TextStyle(
                            color: _gold,
                            fontSize: 13,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    const Expanded(
                      child: Text(
                        'jhon martinez',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      s.newRiderLabel,
                      style: const TextStyle(
                        color: _gold,
                        fontSize: 12.5,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
        ),
        // Gold page number badge floats on the card's OUTER corner
        // (user spec 2026-08-28) — inside the card it overlapped the fare.
        Positioned(
          top: -6,
          left: -6,
          child: Container(
            width: 26,
            height: 26,
            decoration: const BoxDecoration(
              shape: BoxShape.circle,
              color: _gold,
            ),
            child: const Center(
              child: Text(
                '1',
                style: TextStyle(
                  color: Color(0xFF14141A),
                  fontWeight: FontWeight.w800,
                  fontSize: 13,
                ),
              ),
            ),
          ),
        ),
          ],
        ),
        const SizedBox(height: 12),
        // Gold Accept stadium — static replica of the pill that floats
        // under the real offer card (no gestures on a guide page).
        Container(
          width: double.infinity,
          height: 54,
          decoration: BoxDecoration(
            color: _gold,
            borderRadius: BorderRadius.circular(27),
          ),
          child: Center(
            child: Text(
              s.accept,
              style: const TextStyle(
                color: Colors.black,
                fontSize: 16,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _metric(Widget icon, String value) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: neuBox(radius: 10),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          icon,
          const SizedBox(width: 5),
          Text(
            value,
            style: const TextStyle(
              color: _gold,
              fontSize: 12,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }

  Widget _stopText(String meta, String address) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisAlignment: MainAxisAlignment.center,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          meta,
          style: const TextStyle(color: Colors.white, fontSize: 11),
        ),
        const SizedBox(height: 2),
        Text(
          address,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: Colors.white.withValues(alpha: 0.4),
            fontSize: 14,
            fontWeight: FontWeight.w500,
          ),
        ),
      ],
    );
  }
}
