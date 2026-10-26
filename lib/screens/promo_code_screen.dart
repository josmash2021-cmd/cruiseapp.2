import 'dart:async';

import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../config/app_theme.dart';
import '../services/api_service.dart';
import '../services/socket_service.dart';

typedef PromotionsLoader = Future<Map<String, dynamic>> Function();

class PromoCodeScreen extends StatefulWidget {
  final PromotionsLoader? promotionsLoader;
  final Stream<Map<String, dynamic>>? pricingUpdates;

  const PromoCodeScreen({
    super.key,
    this.promotionsLoader,
    this.pricingUpdates,
  });

  @override
  State<PromoCodeScreen> createState() => _PromoCodeScreenState();
}

class _PromoCodeScreenState extends State<PromoCodeScreen> {
  static const _gold = Color(0xFFE8C547);

  List<_PromoItem> _promos = [];
  bool _loading = true;
  bool _refreshing = false;
  Object? _error;
  int _loadSeq = 0;
  Timer? _refreshDebounce;
  StreamSubscription<Map<String, dynamic>>? _pricingSub;

  @override
  void initState() {
    super.initState();
    _load();
    _pricingSub = (widget.pricingUpdates ?? SocketService.pricingUpdatedStream)
        .listen((_) {
      _refreshDebounce?.cancel();
      _refreshDebounce = Timer(
        const Duration(milliseconds: 300),
        _load,
      );
    });
  }

  @override
  void dispose() {
    _loadSeq++;
    _refreshDebounce?.cancel();
    _pricingSub?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    final requestSeq = ++_loadSeq;
    if (mounted) {
      setState(() {
        _loading = _promos.isEmpty;
        _refreshing = _promos.isNotEmpty;
        _error = null;
      });
    }
    try {
      final result =
          await (widget.promotionsLoader ?? ApiService.getMyPromotions)();
      final raw = result['promotions'];
      if (raw is! List) throw const FormatException('Missing promotions');
      final promos = raw
          .map((item) => _PromoItem.fromJson(
                Map<String, dynamic>.from(item as Map),
              ))
          .toList();
      if (!mounted || requestSeq != _loadSeq) return;
      setState(() {
        _promos = promos;
        _loading = false;
        _refreshing = false;
        _error = null;
      });
    } catch (e) {
      if (!mounted || requestSeq != _loadSeq) return;
      debugPrint('[Promotions] load failed: $e');
      setState(() {
        _loading = false;
        _refreshing = false;
        _error = e;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final s = S.of(context);
    return Scaffold(
      backgroundColor: c.bg,
      body: SafeArea(
        child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const SizedBox(height: 8),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 24),
                    child: GestureDetector(
                      onTap: () => Navigator.of(context).pop(),
                      child: Container(
                        width: 40,
                        height: 40,
                        decoration: BoxDecoration(
                          color: c.surface,
                          borderRadius: BorderRadius.circular(12),
                          border: c.isDark
                              ? null
                              : Border.all(
                            color: Colors.black.withValues(alpha: 0.06),
                                ),
                        ),
                        child: Icon(
                          Icons.arrow_back_ios_new_rounded,
                          color: c.textPrimary,
                          size: 18,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 28),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 24),
                    child: Text(
                s.promotions,
                      style: TextStyle(
                        fontSize: 28,
                        fontWeight: FontWeight.w800,
                        color: c.textPrimary,
                        letterSpacing: -0.5,
                      ),
                    ),
                  ),
            if (_refreshing)
              const Padding(
                padding: EdgeInsets.only(top: 8),
                child: LinearProgressIndicator(
                  minHeight: 2,
                  color: _gold,
                              ),
                      ),
            const SizedBox(height: 20),
            Expanded(child: _buildBody(c)),
          ],
                            ),
                          ),
    );
  }

  Widget _buildBody(AppColors c) {
    final s = S.of(context);
    if (_loading) {
      return const Center(child: CircularProgressIndicator(color: _gold));
    }
    if (_error != null && _promos.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
                            children: [
              Icon(Icons.error_outline_rounded,
                  color: c.textTertiary, size: 36),
              const SizedBox(height: 14),
              Text(
                s.promotionsLoadError,
                textAlign: TextAlign.center,
                style: TextStyle(color: c.textSecondary, fontSize: 15),
                                    ),
              const SizedBox(height: 16),
              TextButton.icon(
                onPressed: _load,
                icon: const Icon(Icons.refresh_rounded, color: _gold),
                label: Text(
                  s.retry,
                  style: const TextStyle(color: _gold),
                                  ),
                                ),
            ],
                              ),
                                  ),
      );
    }
    return RefreshIndicator(
      color: _gold,
      onRefresh: _load,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(24, 0, 24, 28),
        children: [
          Container(
            padding: const EdgeInsets.all(14),
                                  decoration: BoxDecoration(
              color: _gold.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: _gold.withValues(alpha: 0.18)),
            ),
            child: Row(
              children: [
                const Icon(
                  Icons.local_offer_rounded,
                                    color: _gold,
                  size: 21,
                                  ),
                const SizedBox(width: 10),
                Expanded(
                                  child: Text(
                    s.promotionsAutoApplied,
                    style: TextStyle(
                      color: c.textSecondary,
                      fontSize: 13,
                      height: 1.35,
                                ),
                              ),
                          ),
                        ],
                      ),
                    ),
          const SizedBox(height: 22),
          Text(
            s.availablePromos,
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                        color: c.textPrimary,
                      ),
                    ),
          if (_error != null) ...[
                  const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: c.surface,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                children: [
                  Expanded(
                            child: Text(
                      s.promotionsLoadError,
                      style: TextStyle(color: c.textSecondary, fontSize: 12),
                              ),
                            ),
                  TextButton(onPressed: _load, child: Text(s.retry)),
                ],
                          ),
                  ),
                ],
          const SizedBox(height: 12),
          if (_promos.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 70),
              child: Center(
                child: Text(
                  s.noPromosAvailable,
                  style: TextStyle(fontSize: 15, color: c.textSecondary),
              ),
      ),
            )
          else
            for (var i = 0; i < _promos.length; i++) ...[
              if (i > 0) const SizedBox(height: 10),
              _buildPromoCard(c, _promos[i]),
            ],
        ],
      ),
    );
  }

  Widget _buildPromoCard(AppColors c, _PromoItem promo) {
    final s = S.of(context);
    final isActive = promo.status == 'active';
    final title = promo.kind == 'free'
        ? s.free
        : promo.percent > 0
            ? '${promo.percent}% OFF'
            : '${promo.fallbackPercent}% OFF';
    final status = switch (promo.status) {
      'active' => s.promotionActive,
      'used' => s.used,
      'expired' => s.expired,
      'revoked' => s.promotionRevoked,
      _ => promo.status,
    };
    final tiers = promo.allowedTiers
        .map((tier) => tier.replaceAll('_', ' ').toUpperCase())
        .join(' · ');
    final validity = _validityText(promo);
    return Container(
      key: ValueKey('promotion_${promo.id}'),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
                color: isActive
                    ? _gold.withValues(alpha: 0.3)
              : Colors.black.withValues(alpha: 0.12),
              ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 46,
            height: 46,
            decoration: BoxDecoration(
              color: isActive
                  ? _gold.withValues(alpha: 0.12)
                  : c.textTertiary.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(
              isActive ? Icons.local_offer_rounded : Icons.block_rounded,
              color: isActive ? _gold : c.textTertiary,
              size: 23,
            ),
          ),
          const SizedBox(width: 13),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        title,
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w800,
                          color: isActive ? _gold : c.textTertiary,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Flexible(
                      child: Text(
                        status,
                        textAlign: TextAlign.right,
                  style: TextStyle(
                          fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: isActive ? c.textPrimary : c.textTertiary,
                  ),
                ),
                  ),
                  ],
                ),
                const SizedBox(height: 7),
                Text(
                  s.promotionUsesRemaining(
                    promo.remainingUses,
                    promo.usesPerRider,
                  ),
                  style: TextStyle(fontSize: 13, color: c.textSecondary),
                ),
                if (promo.maxMiles != null) ...[
                  const SizedBox(height: 3),
                  Text(
                    s.promotionMaxMiles(_milesText(promo.maxMiles!)),
                    style: TextStyle(fontSize: 13, color: c.textSecondary),
                ),
              ],
                if (promo.kind == 'free' && promo.fallbackPercent > 0) ...[
                  const SizedBox(height: 3),
                  Text(
                    s.promotionFallbackPercent(promo.fallbackPercent),
                    style: TextStyle(fontSize: 13, color: c.textSecondary),
            ),
                ],
                if (tiers.isNotEmpty) ...[
                  const SizedBox(height: 3),
                  Text(
                    s.promotionTiers(tiers),
                    style: TextStyle(fontSize: 12, color: c.textSecondary),
          ),
                ],
                const SizedBox(height: 3),
                Text(
                  validity,
                  style: TextStyle(fontSize: 12, color: c.textSecondary),
              ),
                if (promo.reason.isNotEmpty) ...[
                  const SizedBox(height: 5),
                  Text(
                    promo.reason,
                    style: TextStyle(fontSize: 12, color: c.textTertiary),
                ),
                ],
              ],
              ),
            ),
        ],
      ),
    );
  }

  String _validityText(_PromoItem promo) {
    final s = S.of(context);
    final start = _dateText(promo.startsAt);
    final end = _dateText(promo.expiresAt);
    if (start.isEmpty && end.isEmpty) return s.promotionNoExpiry;
    if (start.isEmpty) return s.promotionValidity(end);
    if (end.isEmpty) return s.promotionValidity('$start —');
    return s.promotionValidity('$start — $end');
  }

  String _dateText(DateTime? value) {
    if (value == null) return '';
    final date = value.toLocal();
    final day = date.day.toString().padLeft(2, '0');
    final month = date.month.toString().padLeft(2, '0');
    return S.of(context).isSpanish
        ? '$day/$month/${date.year}'
        : '$month/$day/${date.year}';
}

  String _milesText(double value) => value == value.roundToDouble()
      ? value.toStringAsFixed(0)
      : value.toStringAsFixed(1);
}

class _PromoItem {
  final int id;
  final String kind;
  final int percent;
  final int fallbackPercent;
  final double? maxMiles;
  final List<String> allowedTiers;
  final int usesPerRider;
  final int remainingUses;
  final String status;
  final DateTime? startsAt;
  final DateTime? expiresAt;
  final String reason;

  const _PromoItem({
    required this.id,
    required this.kind,
    required this.percent,
    required this.fallbackPercent,
    required this.maxMiles,
    required this.allowedTiers,
    required this.usesPerRider,
    required this.remainingUses,
    required this.status,
    required this.startsAt,
    required this.expiresAt,
    required this.reason,
  });

  factory _PromoItem.fromJson(Map<String, dynamic> json) {
    final rawTiers = json['allowed_tiers'];
    return _PromoItem(
      id: (json['id'] as num?)?.toInt() ?? 0,
      kind: json['kind']?.toString() ?? 'percent',
      percent: (json['percent'] as num?)?.toInt() ?? 0,
      fallbackPercent: (json['fallback_percent'] as num?)?.toInt() ?? 0,
      maxMiles: (json['max_miles'] as num?)?.toDouble(),
      allowedTiers: rawTiers is List
          ? rawTiers.map((tier) => tier.toString()).toList()
          : const [],
      usesPerRider: (json['uses_per_rider'] as num?)?.toInt() ?? 0,
      remainingUses: (json['remaining_uses'] as num?)?.toInt() ?? 0,
      status: json['status']?.toString() ?? 'expired',
      startsAt: DateTime.tryParse(json['starts_at']?.toString() ?? ''),
      expiresAt: DateTime.tryParse(json['expires_at']?.toString() ?? ''),
      reason: json['reason']?.toString() ?? '',
  );
}
}
