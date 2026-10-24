import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';

/// The selfie-verification photo card (owner mockup 2026-10-23, "foto 4"):
/// the tier×gender photo fills the card edge-to-edge under a thin gold
/// frame, the gold number badge floats top-left, and TWO gold-ring badges
/// ride ON the photo's right edge (face scan + "24h"). The 4 requirement
/// chips moved OUT of the card — they live below the description in the
/// shared `SelfieVerifyChips` row (outlined gold circles, modern line
/// icons). The decorative face-icon circle top-right of the OLD design
/// stays dead ("el emoji de la esquina quítalo").
///
/// ONE design source — used by the first-trip guide (page 6, `flash: true`)
/// and by the selfie-check screen (step 1, `flash: false`). Same rule as
/// `doc_guidelines_view.dart`: never copy this layout into another screen.
///
/// Every icon glyph below EXISTS in the store-era tree-shaken MaterialIcons
/// font (device-proven 2026-10-23): a glyph first used by OTA-delivered
/// code paints "?" on those phones.
class SelfieVerifyCard extends StatefulWidget {
  static const gold = Color(0xFFE8C547);
  static const cardNavy = Color(0xFF1C1C24);

  /// vip_m / vip_f / std_m / std_f — from `resolveSelfieVariant()`.
  final String variant;

  /// Shutter flash over the photo: ONLY the guide (page 6) enables it — the
  /// selfie-check screen's step 1 never flashes.
  final bool flash;

  /// The page is currently visible — the flash fires once per entry.
  final bool active;

  /// The gold number badge (the guide passes its page number).
  final String badge;

  const SelfieVerifyCard({
    super.key,
    required this.variant,
    this.flash = false,
    this.active = true,
    required this.badge,
  });

  @override
  State<SelfieVerifyCard> createState() => _SelfieVerifyCardState();
}

class _SelfieVerifyCardState extends State<SelfieVerifyCard>
    with SingleTickerProviderStateMixin {
  late final AnimationController _flash;
  late final Animation<double> _flashOpacity;

  /// Fires the flash once per entry into view; reset when the page leaves
  /// view so the NEXT entry flashes again (once — never a loop).
  bool _flashFired = false;

  @override
  void initState() {
    super.initState();
    _flash = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
    );
    _flashOpacity = TweenSequence<double>([
      TweenSequenceItem(tween: Tween<double>(begin: 0, end: 0.55), weight: 40),
      TweenSequenceItem(tween: Tween<double>(begin: 0.55, end: 0), weight: 60),
    ]).animate(CurvedAnimation(parent: _flash, curve: Curves.easeOut));
    if (widget.flash && widget.active) _fireFlash();
  }

  @override
  void didUpdateWidget(covariant SelfieVerifyCard old) {
    super.didUpdateWidget(old);
    if (!widget.flash) return;
    if (widget.active && !old.active) _fireFlash();
    if (!widget.active && old.active) _flashFired = false;
  }

  void _fireFlash() {
    if (_flashFired) return;
    _flashFired = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _flash.forward(from: 0);
    });
  }

  @override
  void dispose() {
    _flash.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      clipBehavior: Clip.none,
      children: [
        Container(
          width: double.infinity,
          height: 330,
          decoration: BoxDecoration(
            color: SelfieVerifyCard.cardNavy,
            borderRadius: BorderRadius.circular(22),
            border: Border.all(
                color: SelfieVerifyCard.gold.withValues(alpha: 0.55)),
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(21),
            child: Stack(
              fit: StackFit.expand,
              children: [
                Image.asset(
                  'assets/images/onboarding/guide_selfie_${widget.variant}.png',
                  fit: BoxFit.cover,
                  // OTA patches do NOT carry new assets (proven on device
                  // 2026-10-23): on a store build that predates this PNG the
                  // photo is simply missing — a dignified stand-in beats an
                  // empty void until the next store build lands.
                  errorBuilder: (context, error, stackTrace) => const Center(
                    child: Icon(
                      Icons.face_retouching_natural,
                      color: SelfieVerifyCard.gold,
                      size: 72,
                    ),
                  ),
                ),
                // The shutter flash — one sweep up to ~0.55 and back,
                // fired once per page entry (guide only).
                if (widget.flash)
                  IgnorePointer(
                    child: AnimatedBuilder(
                      animation: _flashOpacity,
                      builder: (ctx, _) => Opacity(
                        opacity: _flashOpacity.value,
                        child: const ColoredBox(color: Colors.white),
                      ),
                    ),
                  ),
                // The two gold-ring badges ride ON the photo's right edge
                // (owner mockup 2026-10-23, foto 4): face scan + "24h".
                const Positioned(
                  top: 22,
                  right: 12,
                  child: _PhotoBadge(
                    child: Icon(
                      Icons.face_retouching_natural,
                      color: SelfieVerifyCard.gold,
                      size: 26,
                    ),
                  ),
                ),
                const Positioned(
                  top: 88,
                  right: 12,
                  child: _PhotoBadge(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          Icons.update_rounded,
                          color: SelfieVerifyCard.gold,
                          size: 17,
                        ),
                        Text(
                          '24h',
                          style: TextStyle(
                            color: SelfieVerifyCard.gold,
                            fontSize: 10,
                            fontWeight: FontWeight.w900,
                            height: 1.0,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        Positioned(
          top: -12,
          left: -8,
          child: Container(
            width: 34,
            height: 34,
            decoration: const BoxDecoration(
              shape: BoxShape.circle,
              color: SelfieVerifyCard.gold,
            ),
            child: Center(
              child: Text(
                widget.badge,
                style: const TextStyle(
                  color: Color(0xFF14141A),
                  fontWeight: FontWeight.w800,
                  fontSize: 15,
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// The gold-ring badge that rides ON the photo (mockup foto 4): dark fill,
/// thin gold ring, gold content.
class _PhotoBadge extends StatelessWidget {
  final Widget child;
  const _PhotoBadge({required this.child});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 54,
      height: 54,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: const Color(0xFF14141A),
        border: Border.all(
            color: SelfieVerifyCard.gold.withValues(alpha: 0.85), width: 1.5),
      ),
      child: Center(child: child),
    );
  }
}

/// The 4 requirement chips of the selfie check (owner mockup 2026-10-23,
/// foto 4): OUTLINED gold circles, modern line icons, caption UNDER each.
/// They live BELOW the description — never inside the photo card. ONE
/// source, shared by the guide (page 6) and the selfie-check screen.
class SelfieVerifyChips extends StatelessWidget {
  final bool vip;
  const SelfieVerifyChips({super.key, required this.vip});

  /// Chip with the label UNDER the icon (outlined gold circle + small white
  /// caption).
  Widget _chip(Widget icon, String label) {
    return Expanded(
      child: Column(
        children: [
          Container(
            width: 56,
            height: 56,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(
                  color: SelfieVerifyCard.gold.withValues(alpha: 0.8),
                  width: 1.4),
            ),
            child: Center(child: icon),
          ),
          const SizedBox(height: 7),
          Text(
            label,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.85),
              fontSize: 10,
              fontWeight: FontWeight.w600,
              height: 1.25,
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    return Row(
      children: [
        _chip(
            const Icon(Icons.face_retouching_natural,
                color: SelfieVerifyCard.gold, size: 24),
            s.selfieChipFaceVisible),
        const SizedBox(width: 8),
        if (vip)
          _chip(
              const Icon(Icons.workspace_premium_rounded,
                  color: SelfieVerifyCard.gold, size: 24),
              s.selfieChipDressVip)
        else
          _chip(
              const Icon(Icons.person_outline_rounded,
                  color: SelfieVerifyCard.gold, size: 24),
              s.selfieChipDressStd),
        const SizedBox(width: 8),
        _chip(
            const Icon(Icons.lightbulb_outline_rounded,
                color: SelfieVerifyCard.gold, size: 24),
            s.selfieChipLighting),
        const SizedBox(width: 8),
        _chip(
            const Icon(Icons.visibility_off_outlined,
                color: SelfieVerifyCard.gold, size: 24),
            s.selfieChipNoGlasses),
      ],
    );
  }
}
