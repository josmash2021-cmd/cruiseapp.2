import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
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
  static const green = Color(0xFF22C55E);

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
    // The discounted price on top; under it the full fare struck through,
    // and on the picked price "$10 off aplicado" beside it (owner
    // 2026-11-09). The payment row under the list still says "Promo
    // aplicada".
    final discounted =
        option.hasPercentageDiscount || option.hasAmountDiscount;
    final applied = option.hasAmountDiscount
        ? S
            .of(context)
            .amountOffApplied(discountDollarsLabel(option.discountAmountCents))
        : S.of(context).percentOffApplied(option.discountPercent);
    // Plain green text, no box (owner 2026-11-09: "no quiero que tenga ese
    // cuadro amarillo y quiero que esté en verde").
    final appliedTag = Text(
      applied,
      key: const ValueKey('quotedFareApplied'),
      maxLines: 1,
      style: const TextStyle(
        fontFamily: 'Poppins',
        color: green,
        fontSize: 12,
        fontWeight: FontWeight.w600,
      ),
    );
    final struck = Text(
      original,
      key: const ValueKey('quotedFareOriginal'),
      maxLines: 1,
      style: originalStyle,
    );

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
                      Text(
                        price,
                        key: const ValueKey('quotedFarePrice'),
                        style: priceStyle,
                      ),
                    ],
                  ],
                ),
              ),
              if (discounted) ...[
                const SizedBox(height: 3),
                // The tag rides on the PICKED price only: in a list row,
                // beside the struck fare it cut "Sin conductores cerca ·
                // Reserva", and under it every row grew until the open
                // list covered the route again (2026-11-09).
                if (selected)
                  FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.centerRight,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        appliedTag,
                        const SizedBox(width: 6),
                        struck,
                      ],
                    ),
                  )
                else
                  struck,
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
            '${option.discountPercent}:${option.discountAmountCents}:'
            '${option.isFree}:$cash:$known',
          ),
          child: content,
        ),
      ),
    );
  }
}
