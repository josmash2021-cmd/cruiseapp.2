import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../l10n/app_localizations.dart';

import '../config/app_theme.dart';
import '../services/api_service.dart';

class PromoCodeScreen extends StatefulWidget {
  const PromoCodeScreen({super.key});

  @override
  State<PromoCodeScreen> createState() => _PromoCodeScreenState();
}

class _PromoCodeScreenState extends State<PromoCodeScreen> {
  static const _gold = Color(0xFFE8C547);
  static const _promoKey = 'promo_codes_v1';

  final _controller = TextEditingController();
  List<_PromoItem> _promos = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_promoKey);
    if (raw != null && raw.isNotEmpty) {
      try {
        final list = jsonDecode(raw) as List;
        _promos = list
            .map(
              (e) => _PromoItem.fromJson(Map<String, dynamic>.from(e as Map)),
            )
            .toList();
      } catch (_) {}
    }

    // Add sample promos if none exist
    if (_promos.isEmpty) {
      _promos = [
        _PromoItem(
          code: 'WELCOME10',
          description: '10% off your first ride',
          discountPercent: 10,
          isUsed: false,
          expiresAt: DateTime.now().add(const Duration(days: 30)),
        ),
        _PromoItem(
          code: 'CRUISE50',
          description: '\$5 off CruiseX rides',
          discountPercent: 0,
          discountFlat: 5.0,
          isUsed: false,
          expiresAt: DateTime.now().add(const Duration(days: 14)),
        ),
      ];
      await _save();
    }

    if (!mounted) return;
    setState(() => _loading = false);
  }

  Future<void> _save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _promoKey,
      jsonEncode(_promos.map((e) => e.toJson()).toList()),
    );
  }

  void _applyCode() async {
    final code = _controller.text.trim().toUpperCase();
    if (code.isEmpty) return;

    // Check if already added
    if (_promos.any((p) => p.code == code)) {
      _showSnack(S.of(context).promoAlreadyAdded);
      return;
    }

    setState(() => _loading = true);

    try {
      final result = await ApiService.validatePromoCode(code);
      final discount = (result['discount_percent'] as num?)?.toInt() ?? 15;
      final msg = result['message'] as String? ?? 'Discount applied!';

      final newPromo = _PromoItem(
        code: code,
        description: msg,
        discountPercent: discount,
        isUsed: false,
        expiresAt: DateTime.now().add(const Duration(days: 7)),
      );

      setState(() {
        _promos.insert(0, newPromo);
        _controller.clear();
        _loading = false;
      });
      _save();
      _showSnack(msg);
    } on ApiException catch (e) {
      setState(() => _loading = false);
      _showSnack(e.message);
    } catch (_) {
      setState(() => _loading = false);
      _showSnack(S.of(context).couldNotValidatePromo);
    }
  }

  void _showSnack(String msg) {
    final c = AppColors.of(context);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg),
        backgroundColor: c.isDark ? c.surface : Colors.black87,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);

    return Scaffold(
      backgroundColor: c.bg,
      body: SafeArea(
        child: _loading
            ? Center(child: CircularProgressIndicator(color: _gold))
            : Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const SizedBox(height: 8),

                  // ── Header ──
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 24),
                    child: Row(
                      children: [
                        GestureDetector(
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
                                      color: Colors.black.withValues(
                                        alpha: 0.06,
                                      ),
                                    ),
                            ),
                            child: Icon(
                              Icons.arrow_back_ios_new_rounded,
                              color: c.textPrimary,
                              size: 18,
                            ),
                          ),
                        ),
                        const SizedBox(width: 16),
                        Text(
                          S.of(context).promotions,
                          style: TextStyle(
                            fontSize: 26,
                            fontWeight: FontWeight.w800,
                            color: c.textPrimary,
                            letterSpacing: -0.5,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 24),

                  // ── Enter code ──
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 24),
                    child: Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: c.surface,
                        borderRadius: BorderRadius.circular(16),
                        border: c.isDark
                            ? null
                            : Border.all(
                                color: Colors.black.withValues(alpha: 0.06),
                              ),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            S.of(context).havePromoCode,
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w700,
                              color: c.textPrimary,
                            ),
                          ),
                          const SizedBox(height: 12),
                          Row(
                            children: [
                              Expanded(
                                child: TextField(
                                  controller: _controller,
                                  textCapitalization:
                                      TextCapitalization.characters,
                                  style: TextStyle(
                                    fontSize: 16,
                                    fontWeight: FontWeight.w600,
                                    color: c.textPrimary,
                                    letterSpacing: 1.5,
                                  ),
                                  decoration: InputDecoration(
                                    hintText: S.of(context).enterCode,
                                    hintStyle: TextStyle(
                                      color: c.textTertiary,
                                      letterSpacing: 0.5,
                                    ),
                                    filled: true,
                                    fillColor: c.isDark
                                        ? c.bg
                                        : const Color(0xFFF5F6FA),
                                    contentPadding: const EdgeInsets.symmetric(
                                      horizontal: 14,
                                      vertical: 14,
                                    ),
                                    border: OutlineInputBorder(
                                      borderRadius: BorderRadius.circular(12),
                                      borderSide: BorderSide.none,
                                    ),
                                  ),
                                ),
                              ),
                              const SizedBox(width: 12),
                              GestureDetector(
                                onTap: _applyCode,
                                child: Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 20,
                                    vertical: 14,
                                  ),
                                  decoration: BoxDecoration(
                                    color: _gold,
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                  child: Text(
                                    S.of(context).apply,
                                    style: const TextStyle(
                                      fontSize: 15,
                                      fontWeight: FontWeight.w700,
                                      color: Colors.black,
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 24),

                  // ── Promo list ──
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 24),
                    child: Text(
                      S.of(context).availablePromos,
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                        color: c.textPrimary,
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),

                  Expanded(
                    child: _promos.isEmpty
                        ? Center(
                            child: Text(
                              S.of(context).noPromosAvailable,
                              style: TextStyle(
                                fontSize: 15,
                                color: c.textSecondary,
                              ),
                            ),
                          )
                        : ListView.separated(
                            physics: const BouncingScrollPhysics(),
                            cacheExtent: 300,
                            padding: const EdgeInsets.symmetric(horizontal: 24),
                            itemCount: _promos.length,
                            separatorBuilder: (context2, idx) =>
                                const SizedBox(height: 10),
                            itemBuilder: (context, i) =>
                                _buildPromoCard(c, _promos[i]),
                          ),
                  ),
                ],
              ),
      ),
    );
  }

  Widget _buildPromoCard(AppColors c, _PromoItem promo) {
    final isExpired = promo.expiresAt.isBefore(DateTime.now());
    final isActive = !promo.isUsed && !isExpired;
    final daysLeft = promo.expiresAt.difference(DateTime.now()).inDays;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(16),
        border: c.isDark
            ? (isActive
                  ? Border.all(color: _gold.withValues(alpha: 0.3))
                  : null)
            : Border.all(
                color: isActive
                    ? _gold.withValues(alpha: 0.3)
                    : Colors.black.withValues(alpha: 0.06),
              ),
      ),
      child: Row(
        children: [
          // ── Icon ──
          Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              color: isActive
                  ? _gold.withValues(alpha: 0.12)
                  : c.textTertiary.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(
              isActive ? Icons.local_offer_rounded : Icons.block_rounded,
              color: isActive ? _gold : c.textTertiary,
              size: 24,
            ),
          ),
          const SizedBox(width: 14),
          // ── Details ──
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  promo.code,
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    color: isActive ? c.textPrimary : c.textTertiary,
                    letterSpacing: 1,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  promo.description,
                  style: TextStyle(
                    fontSize: 14,
                    color: isActive ? c.textSecondary : c.textTertiary,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  promo.isUsed
                      ? S.of(context).used
                      : isExpired
                      ? S.of(context).expired
                      : S.of(context).expiresInDays(daysLeft),
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: isActive ? _gold : c.textTertiary,
                  ),
                ),
              ],
            ),
          ),

          // ── Discount badge ──
          if (isActive)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: _gold.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                promo.discountFlat != null
                    ? S
                          .of(context)
                          .dollarOff(promo.discountFlat!.toStringAsFixed(0))
                    : S.of(context).percentOff(promo.discountPercent),
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: _gold,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

// ── Promo data model ──

class _PromoItem {
  final String code;
  final String description;
  final int discountPercent;
  final double? discountFlat;
  final bool isUsed;
  final DateTime expiresAt;

  const _PromoItem({
    required this.code,
    required this.description,
    required this.discountPercent,
    this.discountFlat,
    required this.isUsed,
    required this.expiresAt,
  });

  Map<String, dynamic> toJson() => {
    'code': code,
    'description': description,
    'discountPercent': discountPercent,
    'discountFlat': discountFlat,
    'isUsed': isUsed,
    'expiresAt': expiresAt.toIso8601String(),
  };

  static _PromoItem fromJson(Map<String, dynamic> json) => _PromoItem(
    code: json['code']?.toString() ?? '',
    description: json['description']?.toString() ?? '',
    discountPercent: (json['discountPercent'] as num?)?.toInt() ?? 0,
    discountFlat: (json['discountFlat'] as num?)?.toDouble(),
    isUsed: json['isUsed'] == true,
    expiresAt:
        DateTime.tryParse(json['expiresAt']?.toString() ?? '') ??
        DateTime.now(),
  );
}
