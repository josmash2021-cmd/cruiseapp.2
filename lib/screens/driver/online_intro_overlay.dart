import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../services/haptic_service.dart';

/// First-GO instruction overlay (user spec 2026-10-22): the first time a
/// driver taps GO and connects on this phone, this floats OVER the online
/// map (it is NOT a page — the map stays mounted underneath, dimmed).
/// Once per device (flag `online_intro_seen_v1`), dismissed only by the
/// gold "Entendido" button; if the app dies mid-overlay it simply shows
/// again on the next GO.
///
/// Animated: scrim fade, card slide-up, PNG soft-scale, and the four info
/// blocks cascading in — plain Flutter tweens, no animation packages.

/// The first-N-drivers figure used in the copy — EDITABLE by design.
const int kFirstDriverCount = 100;

/// Accounts that see the intro EVERY time they go online (owner spec
/// 2026-10-22 — Jhon's demo driver). Everyone else gets it once per phone.
/// Cosmetic and client-side only, same spirit as the test-account lists.
const Set<String> kOnlineIntroAlwaysEmails = {'josmash33@gmail.com'};

/// Same always-show rule by PHONE NUMBER (owner spec 2026-10-23: "debe ser
/// para este telefono 3854612042"). Needed because a phone-created account
/// can have an EMPTY cached email — the email-only rule never matched and
/// the seen flag then hid the intro forever. Digits-only comparison.
const Set<String> kOnlineIntroAlwaysPhones = {'3854612042'};

class OnlineIntroOverlay extends StatefulWidget {
  const OnlineIntroOverlay({super.key, required this.onUnderstood});

  /// Parent marks the seen flag and unmounts the overlay.
  final VoidCallback onUnderstood;

  @override
  State<OnlineIntroOverlay> createState() => _OnlineIntroOverlayState();
}

class _OnlineIntroOverlayState extends State<OnlineIntroOverlay>
    with SingleTickerProviderStateMixin {
  static const _gold = Color(0xFFE8C547);
  static const _navy = Color(0xFF14141A);

  late final AnimationController _ctrl;
  bool _leaving = false;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1150),
      reverseDuration: const Duration(milliseconds: 260),
    )..forward();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _dismiss() async {
    if (_leaving) return;
    _leaving = true;
    HapticService.lightImpact();
    await _ctrl.reverse();
    if (mounted) widget.onUnderstood();
  }

  Animation<double> _window(double start, double end, {Curve? curve}) =>
      CurvedAnimation(
        parent: _ctrl,
        curve: Interval(start, end, curve: curve ?? Curves.easeOutCubic),
      );

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final bottom = MediaQuery.of(context).padding.bottom;

    return Material(
      type: MaterialType.transparency,
      child: FadeTransition(
        opacity: _window(0.0, 0.22),
        child: Container(
          color: Colors.black.withValues(alpha: 0.42),
          child: SafeArea(
            child: Center(
              child: SingleChildScrollView(
                physics: const BouncingScrollPhysics(),
                padding: EdgeInsets.fromLTRB(20, 12, 20, 12 + bottom),
                child: SlideTransition(
                  position: Tween<Offset>(
                    begin: const Offset(0, 0.10),
                    end: Offset.zero,
                  ).animate(_window(0.12, 0.55)),
                  child: FadeTransition(
                    opacity: _window(0.12, 0.50),
                    child: Container(
                      constraints: const BoxConstraints(maxWidth: 420),
                      padding: const EdgeInsets.fromLTRB(22, 18, 22, 18),
                      decoration: BoxDecoration(
                        color: _navy,
                        borderRadius: BorderRadius.circular(24),
                        border: Border.all(
                            color: _gold.withValues(alpha: 0.28), width: 1.2),
                        boxShadow: [
                          BoxShadow(
                            color: _gold.withValues(alpha: 0.14),
                            blurRadius: 40,
                            offset: const Offset(0, 14),
                          ),
                        ],
                      ),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          // Transparent PNG floats on the navy card — a soft
                          // scale-in gives it the "hero" beat.
                          ScaleTransition(
                            scale: Tween<double>(begin: 0.92, end: 1.0)
                                .animate(_window(0.18, 0.60,
                                    curve: Curves.easeOutBack)),
                            child: Image.asset(
                              'assets/images/online_intro_hero.png',
                              height: 170,
                              fit: BoxFit.contain,
                              // A Shorebird patch can ship WITHOUT the new
                              // asset (asset diffs excluded) — the card must
                              // render anyway, image or no image.
                              errorBuilder: (context, error, stackTrace) =>
                                  const SizedBox(height: 12),
                            ),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            s.onlineIntroTitle,
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                              color: _gold,
                              fontSize: 30,
                              fontWeight: FontWeight.w900,
                              letterSpacing: -0.5,
                            ),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            s.onlineIntroSub(kFirstDriverCount),
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color: Colors.white.withValues(alpha: 0.72),
                              fontSize: 13.5,
                              height: 1.4,
                            ),
                          ),
                          const SizedBox(height: 16),
                          _cascade(
                            0,
                            _IntroBlock(
                              icon: Icons.groups_rounded,
                              title: s.onlineIntroB1Title,
                              body: s.onlineIntroB1Body,
                            ),
                          ),
                          _cascade(
                            1,
                            _IntroBlock(
                              icon: Icons.bar_chart_rounded,
                              title: s.onlineIntroB2Title,
                              body: s.onlineIntroB2Body,
                            ),
                          ),
                          _cascade(
                            2,
                            _IntroBlock(
                              icon: Icons.schedule_rounded,
                              title: s.onlineIntroB3Title,
                              body: s.onlineIntroB3Body,
                            ),
                          ),
                          _cascade(
                            3,
                            _IntroBlock(
                              icon: Icons.emoji_events_rounded,
                              title: s.onlineIntroB4Title,
                              body: s.onlineIntroB4Body(kFirstDriverCount),
                            ),
                          ),
                          const SizedBox(height: 18),
                          FadeTransition(
                            opacity: _window(0.72, 1.0),
                            child: SizedBox(
                              width: double.infinity,
                              height: 52,
                              child: ElevatedButton(
                                onPressed: _dismiss,
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: _gold,
                                  foregroundColor: Colors.black,
                                  elevation: 0,
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(16),
                                  ),
                                ),
                                child: Text(
                                  s.onlineIntroUnderstood,
                                  style: const TextStyle(
                                    fontSize: 16,
                                    fontWeight: FontWeight.w900,
                                    letterSpacing: 0.2,
                                  ),
                                ),
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
          ),
        ),
      ),
    );
  }

  /// The 4 info blocks enter one after another (cascade).
  Widget _cascade(int index, Widget child) {
    final start = 0.42 + index * 0.11;
    final end = (start + 0.28).clamp(0.0, 1.0);
    return FadeTransition(
      opacity: _window(start, end),
      child: SlideTransition(
        position: Tween<Offset>(
          begin: const Offset(0, 0.14),
          end: Offset.zero,
        ).animate(_window(start, end)),
        child: child,
      ),
    );
  }
}

/// Gold icon in a soft disc + title/body — one info row of the card.
/// Icons are passed as plain const constructor args (NEVER through a
/// record literal — the release tree-shaker drops those glyphs).
class _IntroBlock extends StatelessWidget {
  const _IntroBlock({
    required this.icon,
    required this.title,
    required this.body,
  });

  final IconData icon;
  final String title;
  final String body;

  static const _gold = Color(0xFFE8C547);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: _gold.withValues(alpha: 0.14),
              shape: BoxShape.circle,
            ),
            child: Icon(icon, color: _gold, size: 24),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    color: _gold,
                    fontSize: 14.5,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  body,
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.66),
                    fontSize: 12.5,
                    height: 1.35,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
