import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_database/firebase_database.dart';

import '../../config/page_transitions.dart';
import '../../widgets/verified_avatar.dart';
import 'driver_online_screen.dart';
import '../../utils/responsive.dart';

// ═══════════════════════════════════════════════════════════════════════════
//  DRIVER RATE RIDER SCREEN — Post-trip feedback
//  Stars 1–5, quick tags, submit → back to online screen
// ═══════════════════════════════════════════════════════════════════════════

class DriverRateRiderScreen extends StatefulWidget {
  const DriverRateRiderScreen({
    super.key,
    required this.tripId,
    required this.riderName,
    this.riderPhotoUrl = '',
    this.fare = 0,
  });

  final int tripId;
  final String riderName;
  final String riderPhotoUrl;
  final double fare;

  @override
  State<DriverRateRiderScreen> createState() => _DriverRateRiderScreenState();
}

class _DriverRateRiderScreenState extends State<DriverRateRiderScreen>
    with SingleTickerProviderStateMixin {
  static const _gold = Color(0xFFD4A843);
  static const _bg   = Color(0xFF0A0D1A);

  int _stars = 0;
  final Set<String> _selectedTags = {};
  bool _submitting = false;

  late final AnimationController _fadeCtrl;
  late final Animation<double> _fadeAnim;

  static const _tags = [
    '👍 Puntual',
    '😊 Amable',
    '🤫 Respetuoso',
    '🧹 Orden',
    '💬 Buen trato',
    '⭐ Excelente rider',
  ];

  @override
  void initState() {
    super.initState();
    _fadeCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 500),
    )..forward();
    _fadeAnim = CurvedAnimation(parent: _fadeCtrl, curve: Curves.easeOut);
  }

  @override
  void dispose() {
    _fadeCtrl.dispose();
    super.dispose();
  }

  String get _firstName => widget.riderName.split(' ').first;

  // ── Submit rating ────────────────────────────────────────────────────────
  Future<void> _submit() async {
    if (_submitting) return;
    setState(() => _submitting = true);
    HapticFeedback.mediumImpact();

    // Save to Firebase RTDB
    if (_stars > 0) {
      try {
        await FirebaseDatabase.instance
            .ref('ratings/riders')
            .push()
            .set({
          'stars': _stars,
          'tags': _selectedTags.toList(),
          'tripId': widget.tripId,
          'timestamp': ServerValue.timestamp,
        });
      } catch (_) {}
      // Also save to Firestore trip document
      try {
        await FirebaseFirestore.instance
            .collection('trips')
            .doc(widget.tripId.toString())
            .update({
          'riderRating': _stars,
          'riderRatedAt': FieldValue.serverTimestamp(),
        });
      } catch (_) {}
    }

    if (!mounted) return;
    _goOnline();
  }

  void _goOnline() {
    Navigator.of(context).pushAndRemoveUntil(
      PageRouteBuilder(
        pageBuilder: (_, anim, __) => const DriverOnlineScreen(),
        transitionsBuilder: (_, anim, __, child) => FadeTransition(
          opacity: CurvedAnimation(parent: anim, curve: Curves.easeInOutCubic),
          child: child,
        ),
        transitionDuration: const Duration(milliseconds: 600),
      ),
      (route) => false,
    );
  }

  // ── BUILD ─────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    final top = MediaQuery.of(context).padding.top;
    final bot = MediaQuery.of(context).padding.bottom;

    return Scaffold(
      backgroundColor: _bg,
      body: FadeTransition(
        opacity: _fadeAnim,
        child: Padding(
          padding: EdgeInsets.fromLTRB(Responsive.w(24), top + 24, Responsive.w(24), bot + 24),
          child: Column(
            children: [
              SizedBox(height: Responsive.h(20)),
              _buildAvatar(),
              SizedBox(height: Responsive.h(20)),
              Text(
                '¿Cómo fue tu viaje\ncon $_firstName?',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: Colors.white,
                  fontSize: Responsive.sp(22),
                  fontWeight: FontWeight.w700,
                  height: 1.3,
                ),
              ),
              SizedBox(height: Responsive.h(32)),
              _buildStars(),
              SizedBox(height: Responsive.h(28)),
              if (_stars > 0) _buildTags(),
              const Spacer(),
              // Submit
              SizedBox(
                width: double.infinity,
                height: Responsive.h(52),
                child: ElevatedButton(
                  onPressed: _stars > 0 && !_submitting ? _submit : null,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _stars > 0 ? _gold : _gold.withValues(alpha: 0.3),
                    disabledBackgroundColor: _gold.withValues(alpha: 0.3),
                    foregroundColor: Colors.black,
                    elevation: 0,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                  ),
                  child: _submitting
                      ? const SizedBox(
                          width: 22, height: 22,
                          child: CircularProgressIndicator(
                            color: Colors.black, strokeWidth: 2.5))
                      : Text(
                          'Enviar',
                          style: TextStyle(
                            color: _stars > 0 ? Colors.black : Colors.white38,
                            fontSize: 16,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                ),
              ),
              const SizedBox(height: 12),
              // Skip
              TextButton(
                onPressed: _submitting ? null : _goOnline,
                child: Text(
                  'Omitir',
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.38),
                    fontSize: 14,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ── Avatar ────────────────────────────────────────────────────────────────
  Widget _buildAvatar() {
    return VerifiedAvatar(
      photoUrl: widget.riderPhotoUrl.isNotEmpty ? widget.riderPhotoUrl : null,
      radius: Responsive.w(44),
      fallbackName: widget.riderName,
      isVerified: true,
    );
  }

  Widget _initialsFill(String init) => Container(
    color: const Color(0xFF1A1F35),
    child: Center(
      child: Text(init,
        style: const TextStyle(
          color: _gold, fontSize: 32, fontWeight: FontWeight.w700)),
    ),
  );

  // ── Stars ─────────────────────────────────────────────────────────────────
  Widget _buildStars() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: List.generate(5, (i) {
        final filled = i < _stars;
        return GestureDetector(
          onTap: () {
            HapticFeedback.lightImpact();
            setState(() => _stars = i + 1);
          },
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            margin: const EdgeInsets.symmetric(horizontal: 6),
            child: AnimatedScale(
              scale: filled ? 1.0 : 0.85,
              duration: const Duration(milliseconds: 200),
              curve: Curves.easeOutBack,
              child: Icon(
                filled ? Icons.star_rounded : Icons.star_outline_rounded,
                color: filled ? _gold : Colors.white.withValues(alpha: 0.24),
                size: 48,
              ),
            ),
          ),
        );
      }),
    );
  }

  // ── Tags ──────────────────────────────────────────────────────────────────
  Widget _buildTags() {
    return AnimatedOpacity(
      opacity: _stars > 0 ? 1.0 : 0.0,
      duration: const Duration(milliseconds: 300),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        alignment: WrapAlignment.center,
        children: _tags.map((tag) {
          final selected = _selectedTags.contains(tag);
          return GestureDetector(
            onTap: () {
              HapticFeedback.selectionClick();
              setState(() {
                if (selected) {
                  _selectedTags.remove(tag);
                } else {
                  _selectedTags.add(tag);
                }
              });
            },
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              decoration: BoxDecoration(
                color: selected
                    ? _gold.withValues(alpha: 0.20)
                    : const Color(0xFF1A1F35),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(
                  color: selected ? _gold : Colors.white.withValues(alpha: 0.12),
                ),
              ),
              child: Text(
                tag,
                style: TextStyle(
                  color: selected ? _gold : Colors.white.withValues(alpha: 0.60),
                  fontSize: 13,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
                ),
              ),
            ),
          );
        }).toList(),
      ),
    );
  }
}
