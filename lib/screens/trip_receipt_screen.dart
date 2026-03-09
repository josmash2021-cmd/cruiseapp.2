import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../config/app_theme.dart';
import '../l10n/app_localizations.dart';
import '../services/local_data_service.dart';
import '../services/user_session.dart';

class TripReceiptScreen extends StatefulWidget {
  final TripHistoryItem trip;

  const TripReceiptScreen({super.key, required this.trip});

  @override
  State<TripReceiptScreen> createState() => _TripReceiptScreenState();
}

class _TripReceiptScreenState extends State<TripReceiptScreen>
    with SingleTickerProviderStateMixin {
  static const _gold = Color(0xFFE8C547);
  static const _goldLight = Color(0xFFF5D990);

  late AnimationController _entryController;
  late Animation<double> _fadeAnim;
  late Animation<Offset> _slideAnim;
  bool _emailSending = false;
  bool _emailSent = false;

  @override
  void initState() {
    super.initState();
    _entryController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
    );
    _fadeAnim = CurvedAnimation(
      parent: _entryController,
      curve: const Interval(0.0, 0.7, curve: Curves.easeOut),
    );
    _slideAnim = Tween<Offset>(begin: const Offset(0, 0.05), end: Offset.zero)
        .animate(
          CurvedAnimation(parent: _entryController, curve: Curves.easeOutCubic),
        );
    _entryController.forward();
  }

  @override
  void dispose() {
    _entryController.dispose();
    super.dispose();
  }

  TripHistoryItem get trip => widget.trip;

  // ── Send receipt via EmailJS ──
  Future<void> _sendEmailReceipt() async {
    if (_emailSending || _emailSent) return;
    setState(() => _emailSending = true);

    try {
      final user = await UserSession.getUser();
      final email = user?['email'] ?? '';
      final name = user?['firstName'] ?? 'Cruise User';

      if (email.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(S.of(context).noEmailError),
              behavior: SnackBarBehavior.floating,
            ),
          );
        }
        setState(() => _emailSending = false);
        return;
      }

      const serviceId = 'service_kgjbuew';
      const templateId = 'template_oucb3n9';
      const publicKey = '5R65y1qr1-lXDwGRb';
      const privateKey = 'xeR8WDCTgskv9g9ITzote';
      const apiUrl = 'https://api.emailjs.com/api/v1.0/email/send';

      final date = _formatDate(trip.createdAt);

      final response = await http.post(
        Uri.parse(apiUrl),
        headers: {
          'Content-Type': 'application/json',
          'origin': 'http://localhost',
          'User-Agent': 'Mozilla/5.0',
        },
        body: jsonEncode({
          'service_id': serviceId,
          'template_id': templateId,
          'user_id': publicKey,
          'accessToken': privateKey,
          'template_params': {
            'to_email': email,
            'to_name': name,
            'code':
                '━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n'
                '     CRUISE RIDE · RECEIPT\n'
                '━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n\n'
                '✓  Ride Completed\n\n'
                'Ride Type:  ${trip.rideName}\n'
                'Total:      ${trip.price}\n'
                'Distance:   ${trip.miles}\n'
                'Duration:   ${trip.duration}\n'
                'Date:       $date\n\n'
                '── Route ──────────────────────\n'
                '◉  Pickup:   ${trip.pickup}\n'
                '◉  Drop-off: ${trip.dropoff}\n\n'
                '━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n'
                'Thank you for riding with Cruise!\n',
          },
        }),
      );

      if (response.statusCode == 200) {
        debugPrint('✅ Receipt email sent to $email');
        if (mounted) {
          setState(() {
            _emailSending = false;
            _emailSent = true;
          });
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Receipt sent to $email'),
              backgroundColor: _gold,
              behavior: SnackBarBehavior.floating,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
          );
        }
      } else {
        debugPrint('❌ Receipt email error: ${response.statusCode}');
        _emailError();
      }
    } catch (e) {
      debugPrint('❌ Receipt email failed: $e');
      _emailError();
    }
  }

  void _emailError() {
    if (mounted) {
      setState(() => _emailSending = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(S.of(context).couldNotSendReceipt),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return Scaffold(
      backgroundColor: c.bg,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        foregroundColor: c.textPrimary,
        elevation: 0,
        title: Text(
          S.of(context).tripReceipt,
          style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 18),
        ),
        actions: [
          IconButton(
            onPressed: _emailSending ? null : _sendEmailReceipt,
            icon: _emailSending
                ? SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                      color: _gold,
                      strokeWidth: 2,
                    ),
                  )
                : Icon(
                    _emailSent
                        ? Icons.mark_email_read_rounded
                        : Icons.email_outlined,
                    color: _emailSent ? _gold : c.textSecondary,
                  ),
            tooltip: _emailSent ? 'Receipt sent' : 'Email receipt',
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: SafeArea(
        child: FadeTransition(
          opacity: _fadeAnim,
          child: SlideTransition(
            position: _slideAnim,
            child: Column(
              children: [
                Expanded(
                  child: ListView(
                    physics: const BouncingScrollPhysics(),
                    padding: const EdgeInsets.fromLTRB(18, 8, 18, 20),
                    children: [
                      // ── GOLD HEADER BANNER ──
                      Container(
                        padding: const EdgeInsets.fromLTRB(22, 22, 22, 18),
                        decoration: const BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                            colors: [_gold, _goldLight],
                          ),
                          borderRadius: BorderRadius.vertical(
                            top: Radius.circular(22),
                          ),
                        ),
                        child: Row(
                          children: [
                            const Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    'Cruise Ride',
                                    style: TextStyle(
                                      color: Color(0xFF08090C),
                                      fontSize: 22,
                                      fontWeight: FontWeight.w800,
                                      letterSpacing: -0.5,
                                    ),
                                  ),
                                  SizedBox(height: 4),
                                  Text(
                                    'RECEIPT',
                                    style: TextStyle(
                                      color: Color(0x9908090C),
                                      fontSize: 11,
                                      fontWeight: FontWeight.w700,
                                      letterSpacing: 2,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            Container(
                              padding: const EdgeInsets.all(10),
                              decoration: BoxDecoration(
                                color: const Color(0x2208090C),
                                borderRadius: BorderRadius.circular(14),
                              ),
                              child: const Icon(
                                Icons.receipt_long_rounded,
                                color: Color(0xFF08090C),
                                size: 22,
                              ),
                            ),
                          ],
                        ),
                      ),

                      // ── MAIN CONTENT CARD ──
                      Container(
                        padding: const EdgeInsets.fromLTRB(22, 20, 22, 22),
                        decoration: BoxDecoration(
                          color: c.panel,
                          borderRadius: const BorderRadius.vertical(
                            bottom: Radius.circular(22),
                          ),
                          border: Border.all(color: c.border),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withValues(alpha: 0.3),
                              blurRadius: 30,
                              offset: const Offset(0, 12),
                            ),
                          ],
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            // Status + date
                            Row(
                              children: [
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 10,
                                    vertical: 5,
                                  ),
                                  decoration: BoxDecoration(
                                    color: const Color(0xFF0D3B0D),
                                    borderRadius: BorderRadius.circular(20),
                                  ),
                                  child: const Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Icon(
                                        Icons.check_circle_rounded,
                                        color: Color(0xFF4ADE80),
                                        size: 14,
                                      ),
                                      SizedBox(width: 5),
                                      Text(
                                        'Completed',
                                        style: TextStyle(
                                          color: Color(0xFF4ADE80),
                                          fontSize: 11,
                                          fontWeight: FontWeight.w700,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                const Spacer(),
                                Text(
                                  _formatDate(trip.createdAt),
                                  style: TextStyle(
                                    color: c.textTertiary,
                                    fontSize: 12,
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 18),

                            // Ride type
                            Text(
                              trip.rideName,
                              style: TextStyle(
                                color: c.textPrimary,
                                fontSize: 30,
                                fontWeight: FontWeight.w800,
                                letterSpacing: -0.5,
                              ),
                            ),
                            const SizedBox(height: 22),

                            // ── Price card (dark inset) ──
                            Container(
                              padding: const EdgeInsets.all(18),
                              decoration: BoxDecoration(
                                color: c.surface,
                                borderRadius: BorderRadius.circular(16),
                                border: Border.all(
                                  color: c.border.withValues(alpha: 0.5),
                                ),
                              ),
                              child: Column(
                                children: [
                                  Row(
                                    children: [
                                      Text(
                                        S.of(context).total,
                                        style: TextStyle(
                                          color: c.textSecondary,
                                          fontSize: 15,
                                        ),
                                      ),
                                      const Spacer(),
                                      Text(
                                        trip.price,
                                        style: const TextStyle(
                                          color: _gold,
                                          fontSize: 28,
                                          fontWeight: FontWeight.w800,
                                          letterSpacing: -0.3,
                                        ),
                                      ),
                                    ],
                                  ),
                                  Padding(
                                    padding: const EdgeInsets.symmetric(
                                      vertical: 14,
                                    ),
                                    child: Divider(color: c.divider, height: 1),
                                  ),
                                  _detailRow(
                                    c,
                                    Icons.straighten_rounded,
                                    S.of(context).distance,
                                    trip.miles,
                                  ),
                                  const SizedBox(height: 10),
                                  _detailRow(
                                    c,
                                    Icons.schedule_rounded,
                                    S.of(context).duration,
                                    trip.duration,
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),

                      const SizedBox(height: 14),

                      // ── ROUTE CARD ──
                      Container(
                        padding: const EdgeInsets.all(20),
                        decoration: BoxDecoration(
                          color: c.panel,
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(color: c.border),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withValues(alpha: 0.15),
                              blurRadius: 16,
                              offset: const Offset(0, 6),
                            ),
                          ],
                        ),
                        child: Column(
                          children: [
                            _routePoint(
                              c,
                              isPickup: true,
                              label: 'PICKUP',
                              address: trip.pickup,
                            ),
                            Padding(
                              padding: const EdgeInsets.only(left: 5),
                              child: Row(
                                children: [
                                  Column(
                                    children: List.generate(
                                      3,
                                      (_) => Container(
                                        width: 1.5,
                                        height: 6,
                                        margin: const EdgeInsets.symmetric(
                                          vertical: 2,
                                        ),
                                        color: _gold.withValues(alpha: 0.3),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            _routePoint(
                              c,
                              isPickup: false,
                              label: 'DROP-OFF',
                              address: trip.dropoff,
                            ),
                          ],
                        ),
                      ),

                      const SizedBox(height: 14),

                      // ── Email receipt action row ──
                      GestureDetector(
                        onTap: _emailSending ? null : _sendEmailReceipt,
                        child: Container(
                          padding: const EdgeInsets.symmetric(vertical: 14),
                          decoration: BoxDecoration(
                            color: c.surface,
                            borderRadius: BorderRadius.circular(16),
                            border: Border.all(color: c.border),
                          ),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              if (_emailSending)
                                SizedBox(
                                  width: 16,
                                  height: 16,
                                  child: CircularProgressIndicator(
                                    color: _gold,
                                    strokeWidth: 2,
                                  ),
                                )
                              else
                                Icon(
                                  _emailSent
                                      ? Icons.mark_email_read_rounded
                                      : Icons.email_outlined,
                                  color: _emailSent ? _gold : c.textSecondary,
                                  size: 18,
                                ),
                              const SizedBox(width: 10),
                              Text(
                                _emailSent
                                    ? S.of(context).sendReceipt
                                    : S.of(context).sendReceipt,
                                style: TextStyle(
                                  color: _emailSent ? _gold : c.textSecondary,
                                  fontSize: 14,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),

                      const SizedBox(height: 12),
                      Center(
                        child: Padding(
                          padding: const EdgeInsets.only(top: 4, bottom: 8),
                          child: Text(
                            'Thank you for riding with Cruise',
                            style: TextStyle(
                              color: c.textTertiary,
                              fontSize: 12,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),

                // ── DONE BUTTON ──
                Padding(
                  padding: const EdgeInsets.fromLTRB(18, 0, 18, 16),
                  child: SizedBox(
                    width: double.infinity,
                    height: 54,
                    child: ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: _gold,
                        foregroundColor: const Color(0xFF08090C),
                        elevation: 0,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(16),
                        ),
                      ),
                      onPressed: () => Navigator.of(context).pop(),
                      child: Text(
                        S.of(context).done,
                        style: const TextStyle(
                          fontWeight: FontWeight.w700,
                          fontSize: 17,
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
    );
  }

  Widget _detailRow(AppColors c, IconData icon, String label, String value) {
    return Row(
      children: [
        Icon(icon, color: c.textTertiary, size: 16),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            label,
            style: TextStyle(color: c.textSecondary, fontSize: 14),
          ),
        ),
        Text(
          value,
          style: TextStyle(
            color: c.textPrimary,
            fontSize: 15,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
  }

  Widget _routePoint(
    AppColors c, {
    required bool isPickup,
    required String label,
    required String address,
  }) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 12,
          height: 12,
          margin: const EdgeInsets.only(top: 2),
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: isPickup ? Colors.transparent : _gold,
            border: isPickup ? Border.all(color: _gold, width: 2.5) : null,
          ),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: TextStyle(
                  color: c.textTertiary,
                  fontSize: 10,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1,
                ),
              ),
              const SizedBox(height: 3),
              Text(
                address,
                style: TextStyle(
                  color: c.textPrimary,
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  String _formatDate(DateTime value) {
    const months = [
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
    ];
    final hour = value.hour % 12 == 0 ? 12 : value.hour % 12;
    final minute = value.minute.toString().padLeft(2, '0');
    final amPm = value.hour >= 12 ? 'PM' : 'AM';
    return '${months[value.month - 1]} ${value.day}, ${value.year} · $hour:$minute $amPm';
  }
}
