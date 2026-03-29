import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:share_plus/share_plus.dart';

import '../config/app_theme.dart';
import '../config/env.dart';
import '../l10n/app_localizations.dart';
import '../services/api_service.dart';
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
  Map<String, dynamic>? _fareBreakdown;

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
    _loadFareBreakdown();
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

      const serviceId = Env.emailjsServiceId;
      const templateId = Env.emailjsTemplateId;
      const publicKey = Env.emailjsPublicKey;
      const privateKey = Env.emailjsPrivateKey;
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

  Future<void> _loadFareBreakdown() async {
    final tid = trip.tripId;
    if (tid == null) return;
    try {
      final data = await ApiService.getFareBreakdown(tid);
      if (mounted) setState(() => _fareBreakdown = data);
    } catch (_) {
      // Fare breakdown is optional — silently ignore errors
    }
  }

  // ── Share receipt as text ──
  Future<void> _shareReceipt() async {
    final date = _formatDate(trip.createdAt);
    final receiptNum = _fareBreakdown?['receipt_number'] ?? 'CR-${trip.tripId ?? 0}';
    final paymentMethod = _fareBreakdown?['payment_method'] as String?;
    
    final shareText = '''
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
     CRUISE RIDE · RECEIPT
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Receipt #: $receiptNum

✓  Ride Completed

Ride Type:  ${trip.rideName}
Total:      ${trip.price}
Distance:   ${trip.miles}
Duration:   ${trip.duration}
Date:       $date
${paymentMethod != null ? 'Payment:    $paymentMethod\n' : ''}
── Route ──────────────────────
◉  Pickup:   ${trip.pickup}
◉  Drop-off: ${trip.dropoff}

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Thank you for riding with Cruise!
''';
    
    await Share.share(shareText, subject: 'Cruise Ride Receipt - $receiptNum');
  }

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return Scaffold(
      backgroundColor: c.bg,
      body: SafeArea(
        child: FadeTransition(
          opacity: _fadeAnim,
          child: Column(
              children: [
                Expanded(
                  child: ListView(
                    physics: const BouncingScrollPhysics(),
                    padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
                    children: [
                      // ── TOP BAR (back + actions) ──
                      Row(
                        children: [
                          GestureDetector(
                            onTap: () => Navigator.of(context).pop(),
                            child: Container(
                              width: 40,
                              height: 40,
                              decoration: BoxDecoration(
                                color: c.surface,
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: Icon(
                                Icons.arrow_back_ios_new_rounded,
                                color: c.textPrimary,
                                size: 18,
                              ),
                            ),
                          ),
                          const Spacer(),
                          // Share button
                          GestureDetector(
                            onTap: _shareReceipt,
                            child: Container(
                              width: 40,
                              height: 40,
                              decoration: BoxDecoration(
                                color: c.surface,
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: Icon(
                                Icons.share_outlined,
                                color: c.textSecondary,
                                size: 18,
                              ),
                            ),
                          ),
                          const SizedBox(width: 10),
                          // Email button
                          GestureDetector(
                            onTap: _emailSending ? null : _sendEmailReceipt,
                            child: Container(
                              width: 40,
                              height: 40,
                              decoration: BoxDecoration(
                                color: _emailSent ? _gold.withValues(alpha: 0.15) : c.surface,
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: _emailSending
                                  ? Center(
                                      child: SizedBox(
                                        width: 16,
                                        height: 16,
                                        child: CircularProgressIndicator(
                                          color: _gold,
                                          strokeWidth: 2,
                                        ),
                                      ),
                                    )
                                  : Icon(
                                      _emailSent
                                          ? Icons.mark_email_read_rounded
                                          : Icons.email_outlined,
                                      color: _emailSent ? _gold : c.textSecondary,
                                      size: 18,
                                    ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 28),

                      // ── TITLE ──
                      Text(
                        S.of(context).tripReceipt,
                        style: TextStyle(
                          fontSize: 28,
                          fontWeight: FontWeight.w800,
                          color: c.textPrimary,
                          letterSpacing: -0.5,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        _fareBreakdown?['receipt_number'] ?? '#CR-${trip.tripId ?? 0}',
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w500,
                          color: c.textTertiary,
                          letterSpacing: 0.3,
                        ),
                      ),
                      const SizedBox(height: 28),

                      // ── TOTAL AMOUNT CARD ──
                      Container(
                        padding: const EdgeInsets.symmetric(vertical: 32, horizontal: 24),
                        decoration: BoxDecoration(
                          gradient: const LinearGradient(
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                            colors: [_gold, _goldLight],
                          ),
                          borderRadius: BorderRadius.circular(24),
                          boxShadow: [
                            BoxShadow(
                              color: _gold.withValues(alpha: 0.3),
                              blurRadius: 24,
                              offset: const Offset(0, 8),
                            ),
                          ],
                        ),
                        child: Column(
                          children: [
                            // Status badge
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
                              decoration: BoxDecoration(
                                color: const Color(0x2208090C),
                                borderRadius: BorderRadius.circular(20),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  const Icon(
                                    Icons.check_circle_rounded,
                                    color: Color(0xFF08090C),
                                    size: 13,
                                  ),
                                  const SizedBox(width: 5),
                                  Text(
                                    'Completed · ${_formatDate(trip.createdAt)}',
                                    style: const TextStyle(
                                      color: Color(0xBB08090C),
                                      fontSize: 11,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(height: 18),
                            // Total amount
                            Text(
                              trip.price,
                              style: const TextStyle(
                                color: Color(0xFF08090C),
                                fontSize: 44,
                                fontWeight: FontWeight.w800,
                                letterSpacing: -1,
                              ),
                            ),
                            const SizedBox(height: 6),
                            Text(
                              trip.rideName,
                              style: const TextStyle(
                                color: Color(0x9908090C),
                                fontSize: 14,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 16),

                      // ── TRIP DETAILS CARD ──
                      Container(
                        padding: const EdgeInsets.all(20),
                        decoration: BoxDecoration(
                          color: c.panel,
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(color: c.border),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Trip Details',
                              style: TextStyle(
                                color: c.textTertiary,
                                fontSize: 11,
                                fontWeight: FontWeight.w700,
                                letterSpacing: 1.2,
                              ),
                            ),
                            const SizedBox(height: 16),
                            _detailRow(c, Icons.straighten_rounded, S.of(context).distance, trip.miles),
                            Padding(
                              padding: const EdgeInsets.symmetric(vertical: 12),
                              child: Divider(color: c.divider, height: 1),
                            ),
                            _detailRow(c, Icons.schedule_rounded, S.of(context).duration, trip.duration),
                            if (_fareBreakdown?['payment_method'] != null) ...[
                              Padding(
                                padding: const EdgeInsets.symmetric(vertical: 12),
                                child: Divider(color: c.divider, height: 1),
                              ),
                              _detailRow(c, Icons.credit_card_rounded, 'Payment', _fareBreakdown!['payment_method'] as String),
                            ],
                          ],
                        ),
                      ),

                      const SizedBox(height: 12),

                      // ── FARE BREAKDOWN ──
                      if (_fareBreakdown != null)
                        Container(
                          padding: const EdgeInsets.all(20),
                          decoration: BoxDecoration(
                            color: c.panel,
                            borderRadius: BorderRadius.circular(20),
                            border: Border.all(color: c.border),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Fare Breakdown',
                                style: TextStyle(
                                  color: c.textTertiary,
                                  fontSize: 11,
                                  fontWeight: FontWeight.w700,
                                  letterSpacing: 1.2,
                                ),
                              ),
                              const SizedBox(height: 16),
                              _breakdownRow(c, 'Base fare', '\$${(_fareBreakdown!['base_fare'] as num?)?.toStringAsFixed(2) ?? '0.00'}'),
                              _breakdownRow(c, 'Mileage (${(_fareBreakdown!['distance_miles'] as num?)?.toStringAsFixed(1) ?? '0'} mi)', '\$${(_fareBreakdown!['mileage_charge'] as num?)?.toStringAsFixed(2) ?? '0.00'}'),
                              _breakdownRow(c, 'Time (${(_fareBreakdown!['duration_minutes'] as num?)?.toInt() ?? 0} min)', '\$${(_fareBreakdown!['time_charge'] as num?)?.toStringAsFixed(2) ?? '0.00'}'),
                              if ((_fareBreakdown!['surge_multiplier'] as num?) != null && (_fareBreakdown!['surge_multiplier'] as num) > 1.0)
                                _breakdownRow(c, 'Surge (${(_fareBreakdown!['surge_multiplier'] as num).toStringAsFixed(1)}x)', '+\$${(_fareBreakdown!['surge_extra'] as num?)?.toStringAsFixed(2) ?? '0.00'}', highlight: true),
                              if ((_fareBreakdown!['wait_time_charge'] as num?) != null && (_fareBreakdown!['wait_time_charge'] as num) > 0)
                                _breakdownRow(c, 'Wait time (${(_fareBreakdown!['wait_time_minutes'] as num?)?.toInt() ?? 0} min)', '\$${(_fareBreakdown!['wait_time_charge'] as num).toStringAsFixed(2)}'),
                              if ((_fareBreakdown!['tip_amount'] as num?) != null && (_fareBreakdown!['tip_amount'] as num) > 0)
                                _breakdownRow(c, 'Tip', '\$${(_fareBreakdown!['tip_amount'] as num).toStringAsFixed(2)}'),
                              Padding(
                                padding: const EdgeInsets.only(top: 12, bottom: 4),
                                child: Divider(color: c.divider, height: 1),
                              ),
                              const SizedBox(height: 4),
                              Row(
                                children: [
                                  Text('Total', style: TextStyle(color: c.textPrimary, fontSize: 15, fontWeight: FontWeight.w700)),
                                  const Spacer(),
                                  Text(trip.price, style: const TextStyle(color: _gold, fontSize: 18, fontWeight: FontWeight.w800)),
                                ],
                              ),
                            ],
                          ),
                        ),

                      if (_fareBreakdown != null) const SizedBox(height: 12),

                      // ── ROUTE CARD ──
                      Container(
                        padding: const EdgeInsets.all(20),
                        decoration: BoxDecoration(
                          color: c.panel,
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(color: c.border),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Route',
                              style: TextStyle(
                                color: c.textTertiary,
                                fontSize: 11,
                                fontWeight: FontWeight.w700,
                                letterSpacing: 1.2,
                              ),
                            ),
                            const SizedBox(height: 16),
                            _routePoint(
                              c,
                              isPickup: true,
                              label: 'PICKUP',
                              address: trip.pickup,
                            ),
                            Padding(
                              padding: const EdgeInsets.only(left: 5),
                              child: Column(
                                children: List.generate(
                                  3,
                                  (_) => Container(
                                    width: 1.5,
                                    height: 6,
                                    margin: const EdgeInsets.symmetric(vertical: 2),
                                    color: _gold.withValues(alpha: 0.3),
                                  ),
                                ),
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

                      const SizedBox(height: 20),

                      // ── ACTION BUTTONS ROW ──
                      Row(
                        children: [
                          // Share button
                          Expanded(
                            child: GestureDetector(
                              onTap: _shareReceipt,
                              child: Container(
                                padding: const EdgeInsets.symmetric(vertical: 16),
                                decoration: BoxDecoration(
                                  color: c.surface,
                                  borderRadius: BorderRadius.circular(16),
                                  border: Border.all(color: c.border),
                                ),
                                child: Row(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    Icon(Icons.share_outlined, color: c.textSecondary, size: 18),
                                    const SizedBox(width: 8),
                                    Text(
                                      'Share',
                                      style: TextStyle(
                                        color: c.textSecondary,
                                        fontSize: 14,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: 12),
                          // Email button
                          Expanded(
                            child: GestureDetector(
                              onTap: _emailSending ? null : _sendEmailReceipt,
                              child: Container(
                                padding: const EdgeInsets.symmetric(vertical: 16),
                                decoration: BoxDecoration(
                                  color: _emailSent ? _gold.withValues(alpha: 0.12) : c.surface,
                                  borderRadius: BorderRadius.circular(16),
                                  border: Border.all(
                                    color: _emailSent ? _gold.withValues(alpha: 0.3) : c.border,
                                  ),
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
                                        _emailSent ? Icons.mark_email_read_rounded : Icons.email_outlined,
                                        color: _emailSent ? _gold : c.textSecondary,
                                        size: 18,
                                      ),
                                    const SizedBox(width: 8),
                                    Text(
                                      _emailSent ? 'Sent' : S.of(context).sendReceipt,
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
                          ),
                        ],
                      ),

                      const SizedBox(height: 16),
                      Center(
                        child: Text(
                          'Thank you for riding with Cruise',
                          style: TextStyle(
                            color: c.textTertiary,
                            fontSize: 12,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),

                // ── DONE BUTTON ──
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
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

  Widget _breakdownRow(AppColors c, String label, String value, {bool highlight = false}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: TextStyle(
                color: highlight ? Colors.redAccent : c.textSecondary,
                fontSize: 13,
                fontWeight: highlight ? FontWeight.w600 : FontWeight.w400,
              ),
            ),
          ),
          Text(
            value,
            style: TextStyle(
              color: highlight ? Colors.redAccent : c.textPrimary,
              fontSize: 14,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}
