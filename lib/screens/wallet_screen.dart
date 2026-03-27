import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../config/app_theme.dart';
import '../config/page_transitions.dart';
import '../l10n/app_localizations.dart';
import '../services/api_service.dart';
import '../services/analytics_service.dart';
import 'payment_accounts_screen.dart';

/// WalletScreen - Shows balance, transactions, and top-up functionality.
class WalletScreen extends StatefulWidget {
  const WalletScreen({super.key});

  @override
  State<WalletScreen> createState() => _WalletScreenState();
}

class _WalletScreenState extends State<WalletScreen> {
  static const _gold = Color(0xFFE8C547);

  bool _loading = true;
  double _balance = 0.0;
  String _currency = 'USD';
  List<Map<String, dynamic>> _transactions = [];
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadWalletData();
  }

  Future<void> _loadWalletData() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final data = await ApiService.getWalletTransactions(limit: 50);
      if (!mounted) return;
      setState(() {
        _balance = (data['balance'] as num?)?.toDouble() ?? 0.0;
        _currency = data['currency'] as String? ?? 'USD';
        _transactions = List<Map<String, dynamic>>.from(data['transactions'] ?? []);
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'Failed to load wallet data';
        _loading = false;
      });
    }
  }

  void _showSnack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(
        content: Text(msg),
        behavior: SnackBarBehavior.floating,
        backgroundColor: const Color(0xFF23262F),
      ));
  }

  void _showTopUpDialog() {
    double amount = 20.0;
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (ctx) => _TopUpSheet(
        initialAmount: amount,
        onTopUp: (selectedAmount) async {
          Navigator.pop(ctx);
          await _performTopUp(selectedAmount);
        },
      ),
    );
  }

  Future<void> _performTopUp(double amount) async {
    HapticFeedback.mediumImpact();
    _showSnack('Adding \$${amount.toStringAsFixed(2)} to wallet...');
    try {
      final result = await ApiService.topUpWallet(amount: amount);
      if (!mounted) return;
      final newBalance = (result['new_balance'] as num?)?.toDouble() ?? _balance;
      setState(() => _balance = newBalance);
      _showSnack('Successfully added \$${amount.toStringAsFixed(2)}!');
      AnalyticsService.instance.logEvent('wallet_top_up', parameters: {'amount': amount});
      await _loadWalletData(); // Refresh transactions
    } catch (e) {
      _showSnack('Top-up failed. Please try again.');
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final loc = S.of(context);

    return Scaffold(
      backgroundColor: c.bg,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: _backButton(c),
        centerTitle: true,
        title: Text(loc.wallet, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
        actions: [
          IconButton(
            icon: Icon(Icons.refresh_rounded, color: c.textPrimary),
            onPressed: _loadWalletData,
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator(color: _gold))
          : _error != null
              ? _buildError()
              : _buildContent(c),
    );
  }

  Widget _backButton(AppColors c) {
    return Padding(
      padding: const EdgeInsets.only(left: 12, top: 8, bottom: 8),
      child: GestureDetector(
        onTap: () => Navigator.pop(context),
        child: Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            color: c.surface,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: c.border),
          ),
          child: Icon(Icons.arrow_back_ios_new_rounded, size: 18, color: c.textPrimary),
        ),
      ),
    );
  }

  Widget _buildError() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.error_outline_rounded, size: 48, color: Colors.red.shade300),
          const SizedBox(height: 16),
          Text(_error!, style: const TextStyle(color: Colors.white70)),
          const SizedBox(height: 24),
          ElevatedButton(
            onPressed: _loadWalletData,
            style: ElevatedButton.styleFrom(backgroundColor: _gold),
            child: const Text('Retry', style: TextStyle(color: Colors.black)),
          ),
        ],
      ),
    );
  }

  Widget _buildContent(AppColors c) {
    return RefreshIndicator(
      onRefresh: _loadWalletData,
      color: _gold,
      child: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          _buildBalanceCard(c),
          const SizedBox(height: 24),
          _buildQuickActions(c),
          const SizedBox(height: 28),
          _buildTransactionsHeader(c),
          const SizedBox(height: 12),
          if (_transactions.isEmpty)
            _buildEmptyTransactions(c)
          else
            ..._transactions.map((txn) => _buildTransactionItem(txn, c)),
        ],
      ),
    );
  }

  Widget _buildBalanceCard(AppColors c) {
    return Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF2A2D35), Color(0xFF1A1C22)],
        ),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: _gold.withValues(alpha: 0.3)),
        boxShadow: [
          BoxShadow(
            color: _gold.withValues(alpha: 0.1),
            blurRadius: 20,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('Cruise Cash', style: TextStyle(
                color: Colors.white.withValues(alpha: 0.7),
                fontSize: 14,
                fontWeight: FontWeight.w500,
              )),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: _gold.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(_currency, style: const TextStyle(
                  color: _gold,
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                )),
              ),
            ],
          ),
          const SizedBox(height: 20),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('\$', style: TextStyle(
                color: _gold,
                fontSize: 28,
                fontWeight: FontWeight.w600,
              )),
              Text(
                _balance.toStringAsFixed(2),
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 48,
                  fontWeight: FontWeight.w800,
                  letterSpacing: -1,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text('Available Balance', style: TextStyle(
            color: Colors.white.withValues(alpha: 0.5),
            fontSize: 13,
          )),
        ],
      ),
    );
  }

  Widget _buildQuickActions(AppColors c) {
    return Row(
      children: [
        Expanded(child: _actionButton(
          icon: Icons.add_rounded,
          label: 'Top Up',
          color: _gold,
          onTap: _showTopUpDialog,
        )),
        const SizedBox(width: 12),
        Expanded(child: _actionButton(
          icon: Icons.credit_card_rounded,
          label: 'Payment Methods',
          color: c.textSecondary,
          onTap: () => Navigator.push(
            context,
            slideFromRightRoute(const PaymentAccountsScreen()),
          ),
        )),
      ],
    );
  }

  Widget _actionButton({
    required IconData icon,
    required String label,
    required Color color,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: () {
        HapticFeedback.lightImpact();
        onTap();
      },
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 16),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: color.withValues(alpha: 0.2)),
        ),
        child: Column(
          children: [
            Icon(icon, color: color, size: 26),
            const SizedBox(height: 8),
            Text(label, style: TextStyle(
              color: color,
              fontSize: 13,
              fontWeight: FontWeight.w600,
            )),
          ],
        ),
      ),
    );
  }

  Widget _buildTransactionsHeader(AppColors c) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text('Recent Activity', style: TextStyle(
          color: c.textPrimary,
          fontSize: 16,
          fontWeight: FontWeight.w700,
        )),
        Text('${_transactions.length} transactions', style: TextStyle(
          color: c.textTertiary,
          fontSize: 12,
        )),
      ],
    );
  }

  Widget _buildEmptyTransactions(AppColors c) {
    return Container(
      padding: const EdgeInsets.all(32),
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: c.border),
      ),
      child: Column(
        children: [
          Icon(Icons.receipt_long_rounded, size: 40, color: c.textTertiary),
          const SizedBox(height: 12),
          Text('No transactions yet', style: TextStyle(
            color: c.textSecondary,
            fontSize: 14,
          )),
          const SizedBox(height: 4),
          Text('Top up your wallet to get started', style: TextStyle(
            color: c.textTertiary,
            fontSize: 12,
          )),
        ],
      ),
    );
  }

  Widget _buildTransactionItem(Map<String, dynamic> txn, AppColors c) {
    final amount = (txn['amount'] as num?)?.toDouble() ?? 0.0;
    final type = txn['type'] as String? ?? 'unknown';
    final desc = txn['description'] as String? ?? type;
    final createdAt = txn['created_at'] as String?;
    
    final isCredit = amount > 0;
    final icon = _getTransactionIcon(type);
    final color = isCredit ? Colors.green : Colors.red;

    String formattedDate = '';
    if (createdAt != null) {
      try {
        final dt = DateTime.parse(createdAt);
        formattedDate = '${dt.month}/${dt.day} ${dt.hour}:${dt.minute.toString().padLeft(2, '0')}';
      } catch (_) {}
    }

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: c.border),
      ),
      child: Row(
        children: [
          Container(
            width: 42,
            height: 42,
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(icon, color: color, size: 20),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(desc, style: TextStyle(
                  color: c.textPrimary,
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                )),
                if (formattedDate.isNotEmpty)
                  Text(formattedDate, style: TextStyle(
                    color: c.textTertiary,
                    fontSize: 11,
                  )),
              ],
            ),
          ),
          Text(
            '${isCredit ? '+' : ''}\$${amount.abs().toStringAsFixed(2)}',
            style: TextStyle(
              color: color,
              fontSize: 15,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }

  IconData _getTransactionIcon(String type) {
    switch (type) {
      case 'top-up':
        return Icons.add_circle_outline_rounded;
      case 'ride-payment':
        return Icons.local_taxi_rounded;
      case 'refund':
        return Icons.replay_rounded;
      case 'promo':
        return Icons.card_giftcard_rounded;
      case 'withdrawal':
        return Icons.arrow_downward_rounded;
      default:
        return Icons.swap_horiz_rounded;
    }
  }
}

/// Bottom sheet for top-up amount selection.
class _TopUpSheet extends StatefulWidget {
  final double initialAmount;
  final Function(double) onTopUp;

  const _TopUpSheet({
    required this.initialAmount,
    required this.onTopUp,
  });

  @override
  State<_TopUpSheet> createState() => _TopUpSheetState();
}

class _TopUpSheetState extends State<_TopUpSheet> {
  static const _gold = Color(0xFFE8C547);
  static const _presetAmounts = [10.0, 20.0, 50.0, 100.0];

  late double _selectedAmount;
  final _customController = TextEditingController();
  bool _isCustom = false;

  @override
  void initState() {
    super.initState();
    _selectedAmount = widget.initialAmount;
  }

  @override
  void dispose() {
    _customController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(24),
      decoration: const BoxDecoration(
        color: Color(0xFF1A1C22),
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 40,
            height: 4,
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.2),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(height: 20),
          const Text('Add Cruise Cash', style: TextStyle(
            color: Colors.white,
            fontSize: 18,
            fontWeight: FontWeight.w700,
          )),
          const SizedBox(height: 8),
          Text('Choose an amount to add to your wallet', style: TextStyle(
            color: Colors.white.withValues(alpha: 0.5),
            fontSize: 13,
          )),
          const SizedBox(height: 24),
          // Preset amounts
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: _presetAmounts.map((amt) => _amountChip(amt)).toList(),
          ),
          const SizedBox(height: 16),
          // Custom amount toggle
          GestureDetector(
            onTap: () => setState(() => _isCustom = !_isCustom),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  _isCustom ? Icons.check_circle_rounded : Icons.circle_outlined,
                  color: _isCustom ? _gold : Colors.white30,
                  size: 20,
                ),
                const SizedBox(width: 8),
                Text('Custom amount', style: TextStyle(
                  color: _isCustom ? _gold : Colors.white54,
                  fontSize: 14,
                )),
              ],
            ),
          ),
          if (_isCustom) ...[
            const SizedBox(height: 16),
            TextField(
              controller: _customController,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              style: const TextStyle(color: Colors.white, fontSize: 18),
              decoration: InputDecoration(
                hintText: 'Enter amount',
                hintStyle: TextStyle(color: Colors.white.withValues(alpha: 0.3)),
                prefixText: '\$ ',
                prefixStyle: const TextStyle(color: _gold, fontSize: 18),
                filled: true,
                fillColor: const Color(0xFF23262F),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none,
                ),
                contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              ),
              onChanged: (val) {
                final parsed = double.tryParse(val);
                if (parsed != null && parsed > 0) {
                  setState(() => _selectedAmount = parsed);
                }
              },
            ),
          ],
          const SizedBox(height: 28),
          // Confirm button
          SizedBox(
            width: double.infinity,
            height: 52,
            child: ElevatedButton(
              onPressed: () {
                HapticFeedback.mediumImpact();
                widget.onTopUp(_selectedAmount);
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: _gold,
                foregroundColor: Colors.black,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
              ),
              child: Text(
                'Add \$${_selectedAmount.toStringAsFixed(2)}',
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ),
          SizedBox(height: MediaQuery.of(context).viewInsets.bottom + 16),
        ],
      ),
    );
  }

  Widget _amountChip(double amount) {
    final isSelected = !_isCustom && _selectedAmount == amount;
    return GestureDetector(
      onTap: () {
        HapticFeedback.lightImpact();
        setState(() {
          _selectedAmount = amount;
          _isCustom = false;
        });
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
        decoration: BoxDecoration(
          color: isSelected ? _gold : const Color(0xFF23262F),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: isSelected ? _gold : Colors.white.withValues(alpha: 0.1),
          ),
        ),
        child: Text(
          '\$${amount.toInt()}',
          style: TextStyle(
            color: isSelected ? Colors.black : Colors.white70,
            fontSize: 15,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    );
  }
}
