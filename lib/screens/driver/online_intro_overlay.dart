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

bool onlineIntroAlwaysAccount({
  Map<String, dynamic>? live,
  Map<String, dynamic>? cached,
}) {
  final freshEmail = (live?['email'] ?? '').toString().trim();
  final cachedEmail = (cached?['email'] ?? '').toString().trim();
  final email =
      (freshEmail.isNotEmpty ? freshEmail : cachedEmail).toLowerCase();
  final freshPhone = (live?['phone'] ?? '').toString();
  final phoneDigits =
      (freshPhone.isNotEmpty ? freshPhone : (cached?['phone'] ?? ''))
          .replaceAll(RegExp(r'\D'), '');
  return kOnlineIntroAlwaysEmails.contains(email) ||
      kOnlineIntroAlwaysPhones.any((p) => phoneDigits.endsWith(p));
}

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
                    child: Stack(
                      clipBehavior: Clip.none,
                      alignment: Alignment.topCenter,
                      children: [
                        Container(
                          margin: const EdgeInsets.only(top: 92),
                          constraints: const BoxConstraints(maxWidth: 360),
                          padding: const EdgeInsets.fromLTRB(14, 60, 14, 14),
                          decoration: BoxDecoration(
                            color: const Color(0xFFE8C547),
                            borderRadius: BorderRadius.circular(30),
                            border: Border.all(
                              color: const Color(0xFFF4D876),
                              width: 1.1,
                            ),
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black.withValues(alpha: 0.22),
                                blurRadius: 26,
                                offset: const Offset(0, 12),
                              ),
                            ],
                          ),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                s.onlineIntroTitle,
                                textAlign: TextAlign.center,
                                style: const TextStyle(
                                  color: Color(0xFF17130A),
                                  fontSize: 27,
                                  fontWeight: FontWeight.w900,
                                  height: 1.05,
                                  letterSpacing: -0.4,
                                ),
                              ),
                              const SizedBox(height: 7),
                              Container(
                                width: 34,
                                height: 3,
                                color: const Color(0xFF5C4B12),
                              ),
                              const SizedBox(height: 8),
                              Text(
                                s.onlineIntroSub(kFirstDriverCount),
                                textAlign: TextAlign.center,
                                style: const TextStyle(
                                  color: Color(0xFF3D3830),
                                  fontSize: 11.5,
                                  height: 1.35,
                                ),
                              ),
                              const SizedBox(height: 14),
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
                              const SizedBox(height: 4),
                              FadeTransition(
                                opacity: _window(0.72, 1.0),
                                child: SizedBox(
                                  width: double.infinity,
                                  height: 44,
                                  child: ElevatedButton(
                                    onPressed: _dismiss,
                                    style: ElevatedButton.styleFrom(
                                      backgroundColor: _navy,
                                      foregroundColor: _gold,
                                      elevation: 0,
                                      shape: RoundedRectangleBorder(
                                        borderRadius: BorderRadius.circular(14),
                                      ),
                                    ),
                                    child: Text(
                                      s.onlineIntroUnderstood,
                                      style: const TextStyle(
                                        fontSize: 15,
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
                        Positioned(
                          top: 0,
                          left: 0,
                          right: 0,
                          child: ScaleTransition(
                            scale: Tween<double>(begin: 0.92, end: 1.0).animate(
                                _window(0.18, 0.60, curve: Curves.easeOutBack)),
                            child: Image.asset(
                              'assets/images/online_intro_hero.png',
                              height: 150,
                              fit: BoxFit.contain,
                              errorBuilder: (context, error, stackTrace) =>
                                  const SizedBox(height: 12),
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
      padding: const EdgeInsets.only(bottom: 10),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
        decoration: BoxDecoration(
          color: const Color(0xFFFFFDF6),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: const Color(0xFFE3CD92)),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: _gold.withValues(alpha: 0.18),
                shape: BoxShape.circle,
              ),
              child: Icon(icon, color: _gold, size: 21),
            ),
            Container(
              width: 1.5,
              height: 42,
              margin: const EdgeInsets.symmetric(horizontal: 9),
              color: _gold.withValues(alpha: 0.55),
            ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(
                      color: Color(0xFFB77A00),
                      fontSize: 12.5,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    body,
                    style: TextStyle(
                      color: const Color(0xFF3D3830).withValues(alpha: 0.82),
                      fontSize: 11.5,
                      height: 1.3,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
