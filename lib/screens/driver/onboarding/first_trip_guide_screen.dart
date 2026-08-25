import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../config/page_transitions.dart';
import '../../../l10n/app_localizations.dart';
import '../../../widgets/neu_style.dart';
import '../driver_home_screen.dart';

/// First-trip guide — 4 swipeable pages shown exactly ONCE after approval
/// (flag `first_trip_guide_seen_v1`, set by the celebration flow before
/// pushing this and re-set here on finish/skip).
///
/// Page 1 is a static, non-interactive replica of the real offer card from
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
      onboardingFadeSlideRoute(const DriverHomeScreen()),
      (_) => false,
    );
  }

  void _next() {
    if (_page >= 3) {
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

    final pages = <_GuidePageData>[
      _GuidePageData(
        number: 1,
        title: s.guideGoOnlineTitle,
        body: s.guideGoOnlineBody,
        art: const _StaticOfferCard(),
      ),
      _GuidePageData(
        number: 2,
        title: s.guideNavigateTitle,
        body: s.guideNavigateBody,
        art: const _GuideImageArt(
            number: 2, asset: 'assets/images/onboarding/guide_nav.png'),
      ),
      _GuidePageData(
        number: 3,
        title: s.guideArriveTitle,
        body: s.guideArriveBody,
        art: const _GuideImageArt(
            number: 3, asset: 'assets/images/onboarding/guide_pickup.png'),
      ),
      _GuidePageData(
        number: 4,
        title: s.guideFinishTitle,
        body: s.guideFinishBody,
        art: const _GuideImageArt(
            number: 4, asset: 'assets/images/onboarding/guide_paid.png'),
      ),
    ];

    return Scaffold(
      backgroundColor: _navy,
      body: SafeArea(
        child: Column(
          children: [
            // Skip, top right.
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: _finish,
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

            Expanded(
              child: PageView.builder(
                controller: _pageCtrl,
                itemCount: pages.length,
                onPageChanged: (i) => setState(() => _page = i),
                itemBuilder: (_, i) =>
                    _GuidePage(data: pages[i], active: i == _page),
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

            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 28),
              child: SizedBox(
                width: double.infinity,
                height: 56,
                child: ElevatedButton(
                  onPressed: _next,
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

/// Art card for pages 2–4: the provided illustration, edge-to-edge in the
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

/// Static replica of the live offer card — demo data, no countdown, no
/// gestures. Mirrored from `_buildNormalCardContent` in
/// `driver_online_widgets.dart`; if the real card changes layout, update
/// this to match.
class _StaticOfferCard extends StatelessWidget {
  const _StaticOfferCard();

  static const _gold = Color(0xFFE8C547);

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    return Container(
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
                            s.offerHourlyRate('38.64'),
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 12.5,
                            ),
                          ),
                          const SizedBox(height: 10),
                          Row(
                            children: [
                              _metric(Icons.access_time_rounded,
                                  s.offerDuration(10)),
                              const SizedBox(width: 8),
                              _metric(Icons.straighten_rounded, '4.3 mi'),
                            ],
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 10),
                    // The car in the gold countdown ring — frozen at a
                    // partial sweep; the live card runs a 20 s timer.
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
                              child: CircularProgressIndicator(
                                value: 0.72,
                                strokeWidth: 3.5,
                                color: _gold,
                                backgroundColor:
                                    Colors.white.withValues(alpha: 0.10),
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
                                s.offerAway(1, '0.0'),
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
          // Gold page number in the corner of the art card.
          Positioned(
            top: 8,
            right: 12,
            child: Text(
              '1',
              style: TextStyle(
                color: _gold.withValues(alpha: 0.85),
                fontSize: 16,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _metric(IconData icon, String value) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: neuBox(radius: 10),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: _gold, size: 12),
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
