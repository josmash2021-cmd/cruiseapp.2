import 'package:flutter/material.dart';

import '../models/ride_quote.dart';

class QuotedFareView extends StatelessWidget {
  final RideOption option;
  final int cruiseCashCents;
  final bool selected;
  final String freeLabel;
  final String cruiseCashLabel;

  const QuotedFareView({
    super.key,
    required this.option,
    required this.cruiseCashCents,
    required this.freeLabel,
    required this.cruiseCashLabel,
    this.selected = false,
  });

  static const gold = Color(0xFFE8C547);

  @override
  Widget build(BuildContext context) {
    final known = option.hasServerPrice;
    final cash = applicableCruiseCashCents(
      option: option,
      balanceCents: cruiseCashCents,
    );
    final priceStyle = TextStyle(
      fontFamily: 'Poppins',
      color: Colors.white,
      fontSize: selected ? 20 : 15,
      fontWeight: FontWeight.w800,
      letterSpacing: -0.3,
    );
    final originalStyle = TextStyle(
      fontFamily: 'Poppins',
      color: Colors.white.withValues(alpha: 0.48),
      fontSize: selected ? 13 : 11.5,
      fontWeight: FontWeight.w600,
      decoration: TextDecoration.lineThrough,
      decorationColor: Colors.white.withValues(alpha: 0.55),
    );
    final original = '\$${option.originalPriceEstimate.toStringAsFixed(2)}';
    final price = '\$${option.priceEstimate.toStringAsFixed(2)}';

    final content = !known
        ? Text('—', key: const ValueKey('quotedFareUnknown'), style: priceStyle)
        : Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerRight,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (option.isFree) ...[
                      Text(
                        freeLabel,
                        key: const ValueKey('quotedFareFree'),
                        style: priceStyle.copyWith(color: gold),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        original,
                        key: const ValueKey('quotedFareFreeOriginal'),
                        style: originalStyle.copyWith(
                          fontSize: selected ? 16 : 13,
                        ),
                      ),
                    ] else ...[
                      if (option.hasPercentageDiscount) ...[
                        Container(
                          key: const ValueKey('quotedFareBadge'),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 3,
                          ),
                          decoration: BoxDecoration(
                            color: gold.withValues(alpha: 0.13),
                            borderRadius: BorderRadius.circular(7),
                          ),
                          child: Text(
                            '${option.discountPercent}% OFF',
                            style: const TextStyle(
                              fontFamily: 'Poppins',
                              color: gold,
                              fontSize: 10.5,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ),
                        const SizedBox(width: 6),
                      ],
                      Text(
                        price,
                        key: const ValueKey('quotedFarePrice'),
                        style: priceStyle,
                      ),
                    ],
                  ],
                ),
              ),
              if (option.hasPercentageDiscount) ...[
                const SizedBox(height: 2),
                Text(
                  original,
                  key: const ValueKey('quotedFareOriginal'),
                  maxLines: 1,
                  style: originalStyle,
                ),
              ],
              if (cash > 0) ...[
                const SizedBox(height: 2),
                Text(
                  '−\$${(cash / 100).toStringAsFixed(2)} $cruiseCashLabel',
                  key: const ValueKey('quotedFareCash'),
                  maxLines: 1,
                  style: const TextStyle(
                    fontFamily: 'Poppins',
                    color: gold,
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ],
          );

    return ConstrainedBox(
      constraints: BoxConstraints(maxWidth: selected ? 190 : 155),
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 250),
        child: KeyedSubtree(
          key: ValueKey(
            '${option.originalTotalCents}:${option.promoTotalCents}:'
            '${option.discountPercent}:${option.isFree}:$cash:$known',
          ),
          child: content,
        ),
      ),
    );
  }
}
