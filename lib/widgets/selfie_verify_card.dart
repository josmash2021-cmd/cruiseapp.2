import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';

/// The selfie-verification card (owner mockup 2026-10-23): navy card with a
/// thin gold frame, the tier×gender photo, the gold number badge top-left,
/// the gold face icon circle top-right, and the 4 requirement chips with
/// their caption UNDER the icon.
///
/// ONE design source — used by the first-trip guide (page 6, `flash: true`)
/// and by the selfie-check screen (step 1, `flash: false`). Same rule as
/// `doc_guidelines_view.dart`: never copy this layout into another screen.
///
/// Icons are passed as full `const Icon(...)` WIDGETS at the call sites —
/// an `IconData` handed around loose (param/ternary/collection) gets
/// tree-shaken to "?" in release builds (owner-confirmed on device).
class SelfieVerifyCard extends StatefulWidget {
  static const gold = Color(0xFFE8C547);
  static const cardNavy = Color(0xFF1C1C24);

  /// vip_m / vip_f / std_m / std_f — from `resolveSelfieVariant()`.
  final String variant;
  final bool vip;

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
    required this.vip,
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

  /// Chip with the label UNDER the icon (gold circle + small white caption).
  Widget _chip(Widget icon, String label) {
    return Expanded(
      child: Column(
        children: [
          Container(
            width: 46,
            height: 46,
            decoration: const BoxDecoration(
              shape: BoxShape.circle,
              color: SelfieVerifyCard.gold,
            ),
            child: icon,
          ),
          const SizedBox(height: 6),
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
    return Stack(
      clipBehavior: Clip.none,
      children: [
        Container(
          width: double.infinity,
          padding: const EdgeInsets.fromLTRB(18, 22, 18, 18),
          decoration: BoxDecoration(
            color: SelfieVerifyCard.cardNavy,
            borderRadius: BorderRadius.circular(22),
            border: Border.all(
                color: SelfieVerifyCard.gold.withValues(alpha: 0.55)),
          ),
          child: Column(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(16),
                child: SizedBox(
                  height: 230,
                  width: double.infinity,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      Image.asset(
                        'assets/images/onboarding/guide_selfie_${widget.variant}.png',
                        fit: BoxFit.cover,
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
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  _chip(
                      const Icon(Icons.face_outlined,
                          color: Color(0xFF14141A), size: 22),
                      s.selfieChipFaceVisible),
                  const SizedBox(width: 8),
                  if (widget.vip)
                    _chip(
                        const Icon(Icons.workspace_premium_outlined,
                            color: Color(0xFF14141A), size: 22),
                        s.selfieChipDressVip)
                  else
                    _chip(
                        const Icon(Icons.checkroom,
                            color: Color(0xFF14141A), size: 22),
                        s.selfieChipDressStd),
                  const SizedBox(width: 8),
                  _chip(
                      const Icon(Icons.wb_sunny_outlined,
                          color: Color(0xFF14141A), size: 22),
                      s.selfieChipLighting),
                  const SizedBox(width: 8),
                  _chip(
                      const Icon(Icons.visibility_off_outlined,
                          color: Color(0xFF14141A), size: 22),
                      s.selfieChipNoGlasses),
                ],
              ),
            ],
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
        const Positioned(
          top: -12,
          right: -8,
          child: _FaceIconBadge(),
        ),
      ],
    );
  }
}

/// The gold circle with the face icon, top-right of the card.
class _FaceIconBadge extends StatelessWidget {
  const _FaceIconBadge();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 34,
      height: 34,
      decoration: const BoxDecoration(
        shape: BoxShape.circle,
        color: SelfieVerifyCard.gold,
      ),
      child: const Icon(
        Icons.face_retouching_natural,
        color: Color(0xFF14141A),
        size: 18,
      ),
    );
  }
}
