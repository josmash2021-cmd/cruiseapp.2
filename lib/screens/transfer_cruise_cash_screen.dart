import 'package:flutter/material.dart';
import '../services/haptic_service.dart';

import '../services/api_service.dart';

/// Send Cruise Cash to another rider by their referral code.
///
/// Flow:
///   1. Recipient code (uppercase, e.g. "MARI-A4F9") + amount input
///   2. Optional note
///   3. Confirm button -> POST /cruise-cash/transfer
///   4. Success animation -> pop with `true` so the parent can refresh
class TransferCruiseCashScreen extends StatefulWidget {
  const TransferCruiseCashScreen({super.key, required this.balanceCents});
  final int balanceCents;

  @override
  State<TransferCruiseCashScreen> createState() =>
      _TransferCruiseCashScreenState();
}

class _TransferCruiseCashScreenState extends State<TransferCruiseCashScreen>
    with SingleTickerProviderStateMixin {
  static const _gold = Color(0xFFE8C547);
  static const _bg = Colors.black;
  static const _chip = Color(0xFF1A1A1F);

  final _codeCtl = TextEditingController();
  final _amountCtl = TextEditingController();
  final _noteCtl = TextEditingController();
  bool _submitting = false;
  String? _error;
  bool _success = false;
  String _successName = '';

  late final AnimationController _checkCtl;

  @override
  void initState() {
    super.initState();
    _checkCtl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
    );
  }

  @override
  void dispose() {
    _codeCtl.dispose();
    _amountCtl.dispose();
    _noteCtl.dispose();
    _checkCtl.dispose();
    super.dispose();
  }

  String _fmt(int cents) => '\$${(cents / 100.0).toStringAsFixed(2)}';

  Future<void> _submit() async {
    final code = _codeCtl.text.trim().toUpperCase();
    final amountStr = _amountCtl.text.trim();
    final note = _noteCtl.text.trim();
    if (code.isEmpty) {
      setState(() => _error = 'Enter the recipient code');
      return;
    }
    final amount = double.tryParse(amountStr);
    if (amount == null || amount <= 0) {
      setState(() => _error = 'Enter a valid amount');
      return;
    }
    final cents = (amount * 100).round();
    if (cents > widget.balanceCents) {
      setState(() => _error = 'Amount exceeds your Cruise Cash balance');
      return;
    }
    setState(() {
      _submitting = true;
      _error = null;
    });
    HapticService.mediumImpact();
    try {
      final res = await ApiService.transferCruiseCash(
        recipientCode: code,
        amount: amount,
        note: note.isEmpty ? null : note,
      );
      if (!mounted) return;
      _successName =
          (res['recipient_first_name'] as String?) ?? 'your friend';
      setState(() {
        _submitting = false;
        _success = true;
      });
      _checkCtl.forward();
      await Future.delayed(const Duration(milliseconds: 1600));
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _submitting = false;
        _error = e.toString().replaceFirst('ApiException: ', '');
      });
      HapticService.heavyImpact();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _bg,
      body: SafeArea(
        child: _success ? _buildSuccess() : _buildForm(),
      ),
    );
  }

  Widget _buildForm() {
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
      physics: const BouncingScrollPhysics(),
      children: [
        Row(
          children: [
            GestureDetector(
              onTap: () => Navigator.of(context).maybePop(),
              child: Container(
                width: 40,
                height: 40,
                decoration: const BoxDecoration(
                  color: _chip,
                  shape: BoxShape.circle,
                ),
                alignment: Alignment.center,
                child: const Icon(Icons.arrow_back_rounded,
                    color: Colors.white, size: 20),
              ),
            ),
            const SizedBox(width: 14),
            const Text(
              'Transfer Cruise Cash',
              style: TextStyle(
                fontFamily: 'Poppins',
                fontSize: 20,
                fontWeight: FontWeight.w800,
                color: Colors.white,
                letterSpacing: -0.4,
              ),
            ),
          ],
        ),
        const SizedBox(height: 28),

        // Balance
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
          decoration: BoxDecoration(
            color: _chip,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
                color: _gold.withValues(alpha: 0.30), width: 1),
          ),
          child: Row(
            children: [
              const Icon(Icons.account_balance_wallet_rounded,
                  color: _gold, size: 18),
              const SizedBox(width: 10),
              Text(
                'Balance available',
                style: TextStyle(
                  fontFamily: 'Poppins',
                  color: Colors.white.withValues(alpha: 0.65),
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const Spacer(),
              Text(
                _fmt(widget.balanceCents),
                style: const TextStyle(
                  fontFamily: 'Poppins',
                  color: _gold,
                  fontSize: 18,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 22),

        _label('Recipient code'),
        _input(
          controller: _codeCtl,
          hint: 'MARI-A4F9',
          icon: Icons.confirmation_number_rounded,
          textCapitalization: TextCapitalization.characters,
        ),
        const SizedBox(height: 18),

        _label('Amount (USD)'),
        _input(
          controller: _amountCtl,
          hint: '10.00',
          icon: Icons.attach_money_rounded,
          keyboardType:
              const TextInputType.numberWithOptions(decimal: true),
        ),
        const SizedBox(height: 18),

        _label('Note (optional)'),
        _input(
          controller: _noteCtl,
          hint: 'Thanks for the help!',
          icon: Icons.edit_note_rounded,
          maxLength: 200,
        ),

        if (_error != null) ...[
          const SizedBox(height: 14),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: const Color(0xFF2A0E0E),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                  color: const Color(0xFFEF4444).withValues(alpha: 0.5),
                  width: 1),
            ),
            child: Row(
              children: [
                const Icon(Icons.error_outline_rounded,
                    color: Color(0xFFEF4444), size: 18),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    _error!,
                    style: const TextStyle(
                      fontFamily: 'Poppins',
                      color: Color(0xFFEF9A9A),
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],

        const SizedBox(height: 28),

        GestureDetector(
          onTap: _submitting ? null : _submit,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            height: 54,
            decoration: BoxDecoration(
              gradient: _submitting
                  ? null
                  : const LinearGradient(
                      colors: [_gold, Color(0xFFD4A574)],
                    ),
              color: _submitting ? _chip : null,
              borderRadius: BorderRadius.circular(16),
              boxShadow: _submitting
                  ? []
                  : [
                      BoxShadow(
                        color: _gold.withValues(alpha: 0.30),
                        blurRadius: 18,
                        offset: const Offset(0, 4),
                      ),
                    ],
            ),
            alignment: Alignment.center,
            child: _submitting
                ? const SizedBox(
                    width: 22,
                    height: 22,
                    child: CircularProgressIndicator(
                        strokeWidth: 2.4, color: _gold),
                  )
                : const Text(
                    'Send Cruise Cash',
                    style: TextStyle(
                      fontFamily: 'Poppins',
                      color: Colors.black,
                      fontSize: 16,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 0.2,
                    ),
                  ),
          ),
        ),
      ],
    );
  }

  Widget _label(String text) => Padding(
        padding: const EdgeInsets.only(left: 4, bottom: 8),
        child: Text(
          text.toUpperCase(),
          style: TextStyle(
            fontFamily: 'Poppins',
            color: _gold.withValues(alpha: 0.80),
            fontSize: 10.5,
            fontWeight: FontWeight.w700,
            letterSpacing: 1.2,
          ),
        ),
      );

  Widget _input({
    required TextEditingController controller,
    required String hint,
    required IconData icon,
    TextInputType? keyboardType,
    TextCapitalization textCapitalization = TextCapitalization.none,
    int? maxLength,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14),
      decoration: BoxDecoration(
        color: _chip,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
            color: Colors.white.withValues(alpha: 0.06), width: 1),
      ),
      child: Row(
        children: [
          Icon(icon, color: _gold.withValues(alpha: 0.7), size: 18),
          const SizedBox(width: 10),
          Expanded(
            child: TextField(
              controller: controller,
              keyboardType: keyboardType,
              textCapitalization: textCapitalization,
              maxLength: maxLength,
              cursorColor: _gold,
              style: const TextStyle(
                fontFamily: 'Poppins',
                color: Colors.white,
                fontSize: 15,
                fontWeight: FontWeight.w600,
              ),
              decoration: InputDecoration(
                hintText: hint,
                hintStyle: TextStyle(
                  fontFamily: 'Poppins',
                  color: Colors.white.withValues(alpha: 0.30),
                  fontSize: 15,
                  fontWeight: FontWeight.w500,
                ),
                border: InputBorder.none,
                contentPadding:
                    const EdgeInsets.symmetric(vertical: 16),
                counterText: '',
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSuccess() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ScaleTransition(
            scale: CurvedAnimation(
              parent: _checkCtl,
              curve: Curves.elasticOut,
            ),
            child: Container(
              width: 96,
              height: 96,
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  colors: [_gold, Color(0xFFD4A574)],
                ),
                shape: BoxShape.circle,
                boxShadow: [
                  BoxShadow(
                    color: _gold.withValues(alpha: 0.45),
                    blurRadius: 28,
                    spreadRadius: 2,
                  ),
                ],
              ),
              child:
                  const Icon(Icons.check_rounded, color: Colors.black, size: 56),
            ),
          ),
          const SizedBox(height: 24),
          const Text(
            'Transfer sent!',
            style: TextStyle(
              fontFamily: 'Poppins',
              color: Colors.white,
              fontSize: 22,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            'Your Cruise Cash is on its way to $_successName.',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontFamily: 'Poppins',
              color: Colors.white.withValues(alpha: 0.55),
              fontSize: 13,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }
}
