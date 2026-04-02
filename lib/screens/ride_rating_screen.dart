import 'package:flutter/material.dart';

import '../config/app_theme.dart';
import '../services/api_service.dart';
import '../l10n/app_localizations.dart';
import '../utils/responsive.dart';
import '../utils/name_helper.dart' as nh;

/// Result returned from the rating screen.
class RideRating {
  final int stars; // 1‑5
  final double tipAmount;
  final String comment;

  const RideRating({
    required this.stars,
    required this.tipAmount,
    this.comment = '',
  });
}

class RideRatingScreen extends StatefulWidget {
  final String driverName;
  final String rideName;
  final String price;
  final int? tripId;

  const RideRatingScreen({
    super.key,
    required this.driverName,
    required this.rideName,
    required this.price,
    this.tripId,
  });

  @override
  State<RideRatingScreen> createState() => _RideRatingScreenState();
}

class _RideRatingScreenState extends State<RideRatingScreen>
    with SingleTickerProviderStateMixin {
  static const _gold = Color(0xFFE8C547);

  int _stars = 0;
  int _selectedTipIndex = -1; // -1 = no tip
  final _tipAmounts = [1.0, 3.0, 5.0, 10.0];
  final _commentController = TextEditingController();

  late AnimationController _entryCtrl;
  late Animation<double> _fade;

  @override
  void initState() {
    super.initState();
    _entryCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 500),
    );
    _fade = CurvedAnimation(parent: _entryCtrl, curve: Curves.easeOut);
    _entryCtrl.forward();
  }

  @override
  void dispose() {
    _entryCtrl.dispose();
    _commentController.dispose();
    super.dispose();
  }

  void _submit() async {
    if (_stars == 0) return;
    final stars = _stars;
    final tip = _selectedTipIndex >= 0 ? _tipAmounts[_selectedTipIndex] : 0.0;
    final rating = RideRating(
      stars: stars,
      tipAmount: tip,
      comment: _commentController.text.trim(),
    );

    // Send to backend
    if (widget.tripId != null) {
      try {
        await ApiService.rateTrip(
          tripId: widget.tripId!,
          stars: stars,
          tipAmount: tip,
          comment: _commentController.text.trim(),
        );
      } catch (_) {}
    }

    if (mounted) Navigator.of(context).pop(rating);
  }

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);

    return Scaffold(
      backgroundColor: c.bg,
      body: SafeArea(
        child: FadeTransition(
          opacity: _fade,
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: Responsive.w(28)),
            child: Column(
              children: [
                SizedBox(height: Responsive.h(60)),

                // ── Driver avatar ──
                Container(
                  width: Responsive.w(90),
                  height: Responsive.w(90),
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: c.surface,
                    border: Border.all(
                      color: _gold.withValues(alpha: 0.4),
                      width: 2.5,
                    ),
                  ),
                  child: Icon(
                    Icons.person_rounded,
                    size: Responsive.sp(48),
                    color: c.textTertiary,
                  ),
                ),
                SizedBox(height: Responsive.h(20)),

                Text(
                  S.of(context).howWasRide,
                  style: TextStyle(
                    fontSize: Responsive.sp(26),
                    fontWeight: FontWeight.w800,
                    color: c.textPrimary,
                    letterSpacing: -0.5,
                  ),
                ),
                SizedBox(height: Responsive.h(8)),
                Text(
                  S.of(context).rateExperience(nh.displayName(widget.driverName, widget.rideName)),
                  style: TextStyle(fontSize: Responsive.sp(15), color: c.textSecondary),
                ),
                SizedBox(height: Responsive.h(32)),

                // ── Stars ──
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: List.generate(5, (i) {
                    final filled = i < _stars;
                    return GestureDetector(
                      onTap: () => setState(() => _stars = i + 1),
                      child: Padding(
                        padding: EdgeInsets.symmetric(horizontal: Responsive.w(6)),
                        child: AnimatedScale(
                          scale: filled ? 1.15 : 1.0,
                          duration: const Duration(milliseconds: 200),
                          child: Icon(
                            filled
                                ? Icons.star_rounded
                                : Icons.star_outline_rounded,
                            size: Responsive.sp(44),
                            color: filled
                                ? _gold
                                : c.textTertiary.withValues(alpha: 0.4),
                          ),
                        ),
                      ),
                    );
                  }),
                ),
                const SizedBox(height: 8),
                AnimatedOpacity(
                  duration: const Duration(milliseconds: 300),
                  opacity: _stars > 0 ? 1 : 0,
                  child: Text(
                    _starLabel(context),
                    style: TextStyle(
                      fontSize: Responsive.sp(14),
                      fontWeight: FontWeight.w600,
                      color: _gold,
                    ),
                  ),
                ),
                SizedBox(height: Responsive.h(40)),

                // ── Tip section ──
                Text(
                  S.of(context).addTip,
                  style: TextStyle(
                    fontSize: Responsive.sp(18),
                    fontWeight: FontWeight.w700,
                    color: c.textPrimary,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  S.of(context).tipGoesToDriver,
                  style: TextStyle(fontSize: Responsive.sp(14), color: c.textSecondary),
                ),
                SizedBox(height: Responsive.h(18)),

                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    _tipChip(c, -1, S.of(context).noTip),
                    ...List.generate(_tipAmounts.length, (i) {
                      return _tipChip(
                        c,
                        i,
                        '\$${_tipAmounts[i].toStringAsFixed(0)}',
                      );
                    }),
                  ],
                ),
                SizedBox(height: Responsive.h(28)),

                // ── Comment ──
                TextField(
                  controller: _commentController,
                  maxLines: 2,
                  maxLength: 200,
                  style: TextStyle(fontSize: Responsive.sp(14), color: c.textPrimary),
                  decoration: InputDecoration(
                    hintText: S.of(context).leaveComment,
                    hintStyle: TextStyle(color: c.textTertiary),
                    filled: true,
                    fillColor: c.surface,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide.none,
                    ),
                    counterStyle: TextStyle(
                      color: c.textTertiary,
                      fontSize: 11,
                    ),
                  ),
                ),

                const Spacer(),

                // ── Submit ──
                SizedBox(
                  width: double.infinity,
                  height: Responsive.h(56),
                  child: ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: _gold,
                      foregroundColor: Colors.black,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16),
                      ),
                      elevation: 0,
                    ),
                    onPressed: _stars > 0 ? _submit : null,
                    child: Text(
                      _selectedTipIndex >= 0
                          ? S
                                .of(context)
                                .submitWithTip(
                                  _tipAmounts[_selectedTipIndex]
                                      .toStringAsFixed(0),
                                )
                          : S.of(context).submitRating,
                      style: const TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 16),

                TextButton(
                  onPressed: () => Navigator.of(context).pop(null),
                  child: Text(
                    S.of(context).skip,
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: c.textSecondary,
                    ),
                  ),
                ),
                const SizedBox(height: 24),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _tipChip(AppColors c, int index, String label) {
    final selected = _selectedTipIndex == index;
    return GestureDetector(
      onTap: () => setState(() => _selectedTipIndex = index),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        margin: const EdgeInsets.symmetric(horizontal: 5),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          color: selected ? _gold : (c.surface),
          borderRadius: BorderRadius.circular(12),
          border: selected
              ? null
              : Border.all(
                  color: c.isDark
                      ? c.border
                      : Colors.black.withValues(alpha: 0.08),
                ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.w700,
            color: selected ? Colors.black : c.textPrimary,
          ),
        ),
      ),
    );
  }

  String _starLabel(BuildContext context) {
    final s = S.of(context);
    switch (_stars) {
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
}
