import 'package:flutter/material.dart';
import '../config/app_theme.dart';
import '../l10n/app_localizations.dart';
import '../main.dart' show accessibilityNotifier;

class AccessibilityScreen extends StatefulWidget {
  const AccessibilityScreen({super.key});

  @override
  State<AccessibilityScreen> createState() => _AccessibilityScreenState();
}

class _AccessibilityScreenState extends State<AccessibilityScreen> {
  static const _gold = Color(0xFFE8C547);

  @override
  void initState() {
    super.initState();
    accessibilityNotifier.addListener(_onChanged);
  }

  @override
  void dispose() {
    accessibilityNotifier.removeListener(_onChanged);
    super.dispose();
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final l = S.of(context);
    final n = accessibilityNotifier;

    return Scaffold(
      backgroundColor: const Color(0xFF1A1A1F),
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ── Header ──
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 12, 16, 0),
              child: Row(
                children: [
                  GestureDetector(
                    onTap: () => Navigator.of(context).pop(),
                    child: Padding(
                      padding: const EdgeInsets.all(8),
                      child: Icon(Icons.arrow_back_rounded,
                          color: c.textPrimary, size: 24),
                    ),
                  ),
                  const SizedBox(width: 4),
                  Text(
                    l.accessibility,
                    style: TextStyle(
                      fontSize: 28,
                      fontWeight: FontWeight.w800,
                      color: c.textPrimary,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 20),

            Expanded(
              child: ListView(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                children: [
                  // ── 1. Text Size ──
                  _sectionLabel(c, l.textSize),
                  const SizedBox(height: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 16, vertical: 14),
                    decoration: _boxDecor(c),
                    child: Column(
                      children: [
                        Row(
                          children: [
                            const Text('A',
                                style: TextStyle(
                                    fontSize: 12, color: Colors.white54)),
                            Expanded(
                              child: Slider(
                                value: n.textScale,
                                min: 0.8,
                                max: 1.6,
                                divisions: 8,
                                activeColor: _gold,
                                inactiveColor: Colors.white12,
                                label:
                                    '${(n.textScale * 100).round()}%',
                                onChanged: (v) => n.setTextScale(v),
                              ),
                            ),
                            const Text('A',
                                style: TextStyle(
                                    fontSize: 22, color: Colors.white54)),
                          ],
                        ),
                        Text(
                          l.textSizePreview,
                          style: TextStyle(
                            fontSize: 14 * n.textScale,
                            color: c.textSecondary,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),

                  // ── 2. High Contrast ──
                  _toggleItem(
                    c,
                    icon: Icons.contrast_rounded,
                    label: l.highContrast,
                    subtitle: l.highContrastDesc,
                    value: n.highContrast,
                    onChanged: (v) => n.setHighContrast(v),
                  ),
                  const SizedBox(height: 10),

                  // ── 3. Reduce Motion ──
                  _toggleItem(
                    c,
                    icon: Icons.animation_rounded,
                    label: l.reduceMotion,
                    subtitle: l.reduceMotionDesc,
                    value: n.reduceMotion,
                    onChanged: (v) => n.setReduceMotion(v),
                  ),
                  const SizedBox(height: 10),

                  // ── 4. Screen Reader Hints ──
                  _toggleItem(
                    c,
                    icon: Icons.record_voice_over_rounded,
                    label: l.screenReaderHints,
                    subtitle: l.screenReaderHintsDesc,
                    value: n.screenReaderHints,
                    onChanged: (v) => n.setScreenReaderHints(v),
                  ),
                  const SizedBox(height: 10),

                  // ── 5. Color Blind Mode ──
                  _sectionLabel(c, l.colorBlindMode),
                  const SizedBox(height: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 16, vertical: 8),
                    decoration: _boxDecor(c),
                    child: Column(
                      children: [
                        _colorBlindOption(c, 'none', l.colorBlindNone, n),
                        _colorBlindOption(
                            c, 'protanopia', l.colorBlindProtanopia, n),
                        _colorBlindOption(
                            c, 'deuteranopia', l.colorBlindDeuteranopia, n),
                        _colorBlindOption(
                            c, 'tritanopia', l.colorBlindTritanopia, n),
                      ],
                    ),
                  ),
                  const SizedBox(height: 10),

                  // ── 6. Haptic Feedback ──
                  _toggleItem(
                    c,
                    icon: Icons.vibration_rounded,
                    label: l.hapticFeedback,
                    subtitle: l.hapticFeedbackDesc,
                    value: n.hapticFeedback,
                    onChanged: (v) => n.setHapticFeedback(v),
                  ),
                  const SizedBox(height: 32),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _sectionLabel(AppColors c, String text) {
    return Text(
      text,
      style: TextStyle(
        fontSize: 13,
        fontWeight: FontWeight.w600,
        color: c.textTertiary,
        letterSpacing: 0.5,
      ),
    );
  }

  BoxDecoration _boxDecor(AppColors c) {
    return BoxDecoration(
      color: c.surface,
      borderRadius: BorderRadius.circular(14),
      border: c.isDark
          ? null
          : Border.all(color: Colors.black.withValues(alpha: 0.06)),
    );
  }

  Widget _toggleItem(
    AppColors c, {
    required IconData icon,
    required String label,
    required String subtitle,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: _boxDecor(c),
      child: Row(
        children: [
          Icon(icon, size: 22, color: c.textPrimary),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label,
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: c.textPrimary,
                    )),
                const SizedBox(height: 2),
                Text(subtitle,
                    style: TextStyle(
                        fontSize: 12, color: c.textTertiary)),
              ],
            ),
          ),
          Switch.adaptive(
            value: value,
            activeThumbColor: _gold,
            onChanged: onChanged,
          ),
        ],
      ),
    );
  }

  Widget _colorBlindOption(
      AppColors c, String mode, String label, dynamic n) {
    final selected = n.colorBlindMode == mode;
    return GestureDetector(
      onTap: () => n.setColorBlindMode(mode),
      behavior: HitTestBehavior.opaque,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Row(
          children: [
            Icon(
              selected
                  ? Icons.radio_button_checked_rounded
                  : Icons.radio_button_off_rounded,
              color: selected ? _gold : Colors.white30,
              size: 20,
            ),
            const SizedBox(width: 12),
            Text(label,
                style: TextStyle(
                  fontSize: 15,
                  color: selected
                      ? c.textPrimary
                      : c.textSecondary,
                  fontWeight:
                      selected ? FontWeight.w600 : FontWeight.w400,
                )),
          ],
        ),
      ),
    );
  }
}
