import 'package:flutter/material.dart';
import '../config/app_theme.dart';

/// Reusable fare breakdown widget for displaying trip fare components.
/// Used in TripReceiptScreen and potentially other payment-related screens.
class FareBreakdownWidget extends StatelessWidget {
  final Map<String, dynamic> fareData;
  final String totalDisplay;
  final String? paymentMethod;

  static const _gold = Color(0xFFE8C547);

  const FareBreakdownWidget({
    super.key,
    required this.fareData,
    required this.totalDisplay,
    this.paymentMethod,
  });

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);

    return Container(
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
              color: c.textPrimary,
              fontSize: 16,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 14),
          
          // Base fare
          _breakdownRow(c, 'Base fare', '\$${_formatNum(fareData['base_fare'])}'),
          
          // Mileage
          _breakdownRow(
            c,
            'Mileage (${_formatNum(fareData['distance_miles'], decimals: 1)} mi × \$${_formatNum(fareData['per_mile_rate'])}/mi)',
            '\$${_formatNum(fareData['mileage_charge'])}',
          ),
          
          // Time
          _breakdownRow(
            c,
            'Time (${_formatInt(fareData['duration_minutes'])} min × \$${_formatNum(fareData['per_minute_rate'])}/min)',
            '\$${_formatNum(fareData['time_charge'])}',
          ),
          
          // Surge (if applicable)
          if (_getSurgeMultiplier() > 1.0)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: _breakdownRow(
                c,
                'Surge (${_getSurgeMultiplier().toStringAsFixed(1)}x)',
                '+\$${_formatNum(fareData['surge_extra'])}',
                highlight: true,
              ),
            ),
          
          // Wait time (if applicable)
          if (_getWaitTimeCharge() > 0)
            _breakdownRow(
              c,
              'Wait time (${_formatInt(fareData['wait_time_minutes'])} min)',
              '\$${_formatNum(fareData['wait_time_charge'])}',
            ),
          
          // Tip (if applicable)
          if (_getTipAmount() > 0)
            _breakdownRow(
              c,
              'Tip',
              '\$${_formatNum(fareData['tip_amount'])}',
            ),
          
          // Divider
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Divider(color: c.divider, height: 1),
          ),
          
          // Total
          Row(
            children: [
              Text(
                'Total',
                style: TextStyle(
                  color: c.textPrimary,
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const Spacer(),
              Text(
                totalDisplay,
                style: const TextStyle(
                  color: _gold,
                  fontSize: 18,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ],
          ),
          
          // Payment method
          if (paymentMethod != null) ...[
            const SizedBox(height: 12),
            Row(
              children: [
                Icon(Icons.credit_card_rounded, color: c.textTertiary, size: 16),
                const SizedBox(width: 8),
                Text(
                  paymentMethod!,
                  style: TextStyle(color: c.textSecondary, fontSize: 13),
                ),
              ],
            ),
          ],
        ],
      ),
    );
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

  String _formatNum(dynamic value, {int decimals = 2}) {
    if (value == null) return '0.00';
    return (value as num).toStringAsFixed(decimals);
  }

  int _formatInt(dynamic value) {
    if (value == null) return 0;
    return (value as num).toInt();
  }

  double _getSurgeMultiplier() {
    final surge = fareData['surge_multiplier'];
    if (surge == null) return 1.0;
    return (surge as num).toDouble();
  }

  double _getWaitTimeCharge() {
    final charge = fareData['wait_time_charge'];
    if (charge == null) return 0.0;
    return (charge as num).toDouble();
  }

  double _getTipAmount() {
    final tip = fareData['tip_amount'];
    if (tip == null) return 0.0;
    return (tip as num).toDouble();
  }
}
