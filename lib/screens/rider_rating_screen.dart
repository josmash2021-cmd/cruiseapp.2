import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../config/page_transitions.dart';
import '../services/api_service.dart';
import '../l10n/app_localizations.dart';
import 'home_screen.dart';

/// Full-screen post-ride rating page.
/// Tip percentages are calculated from the actual ride fare.
class RiderRatingScreen extends StatefulWidget {
  const RiderRatingScreen({
    super.key,
    required this.driverName,
    this.tripId,
    this.fare = 0,
  });

  final String driverName;
  final int? tripId;
  final double fare;

  @override
  State<RiderRatingScreen> createState() => _RiderRatingScreenState();
}

class _RiderRatingScreenState extends State<RiderRatingScreen>
    with SingleTickerProviderStateMixin {
  static const _gold = Color(0xFFD4A843);

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

    if (!mounted) return;
    Navigator.of(context).pushAndRemoveUntil(
      PageRouteBuilder(
        pageBuilder: (_a, _b, _c) => const HomeScreen(),
        transitionsBuilder: (_a, anim, _c, child) =>
            FadeTransition(opacity: anim, child: child),
        transitionDuration: const Duration(milliseconds: 500),
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
        backgroundColor: const Color(0xFF121212),
        body: FadeTransition(
          opacity: _fadeAnim,
          child: SafeArea(
            child: ListView(
              physics: const BouncingScrollPhysics(
                parent: AlwaysScrollableScrollPhysics(),
              ),
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
              children: [
                const SizedBox(height: 20),

                // ── Stars ──
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: List.generate(5, (i) {
                    return GestureDetector(
                      onTap: () => setState(() => _ratingStars = i + 1),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 6),
                        child: Icon(
                          i < _ratingStars
                              ? Icons.star_rounded
                              : Icons.star_outline_rounded,
                          size: 52,
                          color: i < _ratingStars
                              ? _gold
                              : Colors.white.withValues(alpha: 0.2),
                        ),
                      ),
                    );
                  }),
                ),
                const SizedBox(height: 10),

                // ── Star label ──
                Center(
                  child: Text(
                    _starLabel(s),
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
                      color: _gold,
                    ),
                  ),
                ),
                const SizedBox(height: 8),

                // ── "What went well?" ──
                Center(
                  child: Text(
                    s.whatWentWell,
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                      color: Colors.white.withValues(alpha: 0.85),
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
                      onTap: () => setState(() {
                        sel
                            ? _feedbackChips.remove(label)
                            : _feedbackChips.add(label);
                      }),
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 200),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 10,
                        ),
                        decoration: BoxDecoration(
                          color: sel
                              ? _gold.withValues(alpha: 0.2)
                              : Colors.white.withValues(alpha: 0.06),
                          borderRadius: BorderRadius.circular(22),
                          border: Border.all(
                            color: sel
                                ? _gold
                                : Colors.white.withValues(alpha: 0.15),
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
                                : Colors.white.withValues(alpha: 0.7),
                          ),
                        ),
                      ),
                    );
                  }).toList(),
                ),
                const SizedBox(height: 18),

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
                          color: Colors.white.withValues(alpha: 0.5),
                        ),
                      ),
                      const SizedBox(width: 6),
                      Icon(
                        Icons.edit_note_rounded,
                        size: 18,
                        color: Colors.white.withValues(alpha: 0.4),
                      ),
                    ],
                  ),
                ),

                const SizedBox(height: 24),
                Divider(
                    height: 1,
                    color: Colors.white.withValues(alpha: 0.1)),
                const SizedBox(height: 24),

                // ── Tip section header ──
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
                              color: Colors.white.withValues(alpha: 0.5),
                            ),
                          ),
                        ],
                      ),
                    ),
                    // Driver avatar
                    Container(
                      width: 48,
                      height: 48,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: Colors.white.withValues(alpha: 0.1),
                        border: Border.all(
                          color: Colors.white.withValues(alpha: 0.2),
                          width: 2,
                        ),
                      ),
                      child: Center(
                        child: Text(
                          widget.driverName.isNotEmpty
                              ? widget.driverName[0].toUpperCase()
                              : 'D',
                          style: const TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.w800,
                            color: Colors.white,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 18),

                // ── Percentage tip buttons (calculated from fare) ──
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
                          onTap: () => setState(() {
                            _customTip = false;
                            _tipAmount = sel ? 0 : amt;
                          }),
                          child: AnimatedContainer(
                            duration: const Duration(milliseconds: 200),
                            height: 66,
                            decoration: BoxDecoration(
                              color: sel
                                  ? _gold.withValues(alpha: 0.15)
                                  : Colors.white.withValues(alpha: 0.06),
                              borderRadius: BorderRadius.circular(14),
                              border: Border.all(
                                color: sel
                                    ? _gold
                                    : Colors.white.withValues(alpha: 0.15),
                                width: sel ? 2 : 1,
                              ),
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
                                        : Colors.white
                                            .withValues(alpha: 0.8),
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
                                        : Colors.white
                                            .withValues(alpha: 0.45),
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
                        color: _gold.withValues(alpha: 0.7),
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
                          fillColor: Colors.white.withValues(alpha: 0.08),
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
                const SizedBox(height: 24),

                // ── Favorite driver ──
                GestureDetector(
                  onTap: () => setState(() => _saveDriver = !_saveDriver),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 16,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.05),
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(
                        color: _saveDriver
                            ? _gold
                            : Colors.white.withValues(alpha: 0.1),
                      ),
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
                                  : Colors.white.withValues(alpha: 0.3),
                              width: 2,
                            ),
                          ),
                          child: _saveDriver
                              ? const Icon(Icons.check_rounded,
                                  size: 18, color: Colors.white)
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
                                      Colors.white.withValues(alpha: 0.5),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 28),

                // ── Send button ──
                SizedBox(
                  width: double.infinity,
                  height: 56,
                  child: ElevatedButton(
                    onPressed: _submitting ? null : _submit,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: _gold,
                      foregroundColor: Colors.black,
                      disabledBackgroundColor:
                          _gold.withValues(alpha: 0.5),
                      elevation: 0,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(28),
                      ),
                    ),
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
                            ),
                          ),
                  ),
                ),
                const SizedBox(height: 16),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
