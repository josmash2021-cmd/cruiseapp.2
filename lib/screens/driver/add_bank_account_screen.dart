import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_stripe/flutter_stripe.dart' as stripe;

import '../../l10n/app_localizations.dart';
import '../../services/api_service.dart';
import '../../services/haptic_service.dart';
import '../../services/user_session.dart';
import '../../widgets/neu_style.dart';

/// Routing + account number, straight into the weekly payout schedule.
///
/// The numbers are handed to the Stripe SDK and never reach our servers: the
/// SDK returns a `btok_...`, and only that token is posted to
/// `/drivers/payout-methods/bank-account`, which attaches it as an
/// external_account on the driver's connected account. That is the whole
/// reason this form is allowed to exist in the app at all — typing the digits
/// into fields we then transmit ourselves would put Cruise inside the
/// compliance scope those digits carry.
class AddBankAccountScreen extends StatefulWidget {
  const AddBankAccountScreen({super.key});

  @override
  State<AddBankAccountScreen> createState() => _AddBankAccountScreenState();
}

class _AddBankAccountScreenState extends State<AddBankAccountScreen> {
  static const _gold = Color(0xFFE8C547);

  final _routing = TextEditingController();
  final _account = TextEditingController();
  final _confirm = TextEditingController();
  final _holder = TextEditingController();

  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _prefillHolder();
    // The submit button lives or dies on these, so it has to rebuild as they
    // are typed rather than only when the field loses focus.
    for (final c in [_routing, _account, _confirm, _holder]) {
      c.addListener(() {
        if (mounted) setState(() {});
      });
    }
  }

  Future<void> _prefillHolder() async {
    final u = await UserSession.getUser();
    if (!mounted || u == null) return;
    final name = '${u['firstName'] ?? ''} ${u['lastName'] ?? ''}'.trim();
    if (name.isNotEmpty && _holder.text.isEmpty) _holder.text = name;
  }

  @override
  void dispose() {
    _routing.dispose();
    _account.dispose();
    _confirm.dispose();
    _holder.dispose();
    super.dispose();
  }

  /// US routing numbers are 9 digits and carry a check digit. Validating it
  /// here turns the commonest typo into an inline message instead of a
  /// round trip that comes back as a generic Stripe rejection.
  bool get _routingValid {
    final r = _routing.text.trim();
    if (r.length != 9 || int.tryParse(r) == null) return false;
    final d = r.split('').map(int.parse).toList();
    final sum = 3 * (d[0] + d[3] + d[6]) +
        7 * (d[1] + d[4] + d[7]) +
        1 * (d[2] + d[5] + d[8]);
    return sum % 10 == 0;
  }

  bool get _canSubmit =>
      !_busy &&
      _holder.text.trim().isNotEmpty &&
      _routingValid &&
      _account.text.trim().length >= 4 &&
      _account.text.trim() == _confirm.text.trim();

  Future<void> _submit() async {
    if (!_canSubmit) return;
    HapticService.mediumImpact();
    setState(() {
      _busy = true;
      _error = null;
    });
    final s = S.of(context);
    try {
      // The digits go SDK → Stripe. What comes back is a token.
      final token = await stripe.Stripe.instance.createToken(
        stripe.CreateTokenParams.bankAccount(
          params: stripe.BankAccountTokenParams(
            accountNumber: _account.text.trim(),
            routingNumber: _routing.text.trim(),
            accountHolderName: _holder.text.trim(),
            accountHolderType: stripe.BankAccountHolderType.Individual,
            country: 'US',
            currency: 'usd',
          ),
        ),
      );
      if (!mounted) return;
      final btok = token.id;
      if (btok.isEmpty) {
        setState(() => _error = s.failedToAddMethod);
        return;
      }
      await ApiService.addBankAccountPayout(bankToken: btok, setDefault: true);
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } on stripe.StripeException catch (e) {
      if (!mounted) return;
      setState(() => _error = e.error.localizedMessage ?? s.failedToAddMethod);
    } catch (e) {
      if (!mounted) return;
      setState(() =>
          _error = e is ApiException ? e.message : s.failedToAddMethod);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    return Scaffold(
      backgroundColor: neuBase,
      appBar: AppBar(
        backgroundColor: neuBase,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: Colors.white),
          onPressed: () => Navigator.of(context).maybePop(),
        ),
      ),
      body: SafeArea(
        top: false,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 32),
          children: [
            Text(
              s.addBankAccountTitle,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 30,
                fontWeight: FontWeight.w800,
                letterSpacing: -0.5,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              s.addBankAccountSubtitle,
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.55),
                fontSize: 14,
                height: 1.4,
              ),
            ),
            const SizedBox(height: 28),
            _field(
              label: s.accountHolderName,
              controller: _holder,
              keyboard: TextInputType.name,
            ),
            _field(
              label: s.routingNumber,
              controller: _routing,
              keyboard: TextInputType.number,
              maxLength: 9,
              hint: s.routingNumberHint,
              showError: _routing.text.length == 9 && !_routingValid,
              errorText: s.routingNumberInvalid,
            ),
            _field(
              label: s.bankAccountNumber,
              controller: _account,
              keyboard: TextInputType.number,
              obscure: true,
            ),
            _field(
              label: s.reenterAccountNumber,
              controller: _confirm,
              keyboard: TextInputType.number,
              obscure: true,
              showError: _confirm.text.isNotEmpty &&
                  _confirm.text.trim() != _account.text.trim(),
              errorText: s.accountNumbersDoNotMatch,
            ),
            const SizedBox(height: 8),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.lock_outline,
                    size: 15, color: Colors.white.withValues(alpha: 0.4)),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    s.bankNumbersNeverStored,
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.4),
                      fontSize: 12.5,
                      height: 1.35,
                    ),
                  ),
                ),
              ],
            ),
            if (_error != null) ...[
              const SizedBox(height: 18),
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: const Color(0xFFEF4444).withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  _error!,
                  style: const TextStyle(
                      color: Color(0xFFEF4444), fontSize: 13.5),
                ),
              ),
            ],
            const SizedBox(height: 28),
            GestureDetector(
              onTap: _canSubmit ? _submit : null,
              child: Container(
                height: 54,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: _canSubmit ? _gold : Colors.white.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(27),
                ),
                child: _busy
                    ? const SizedBox(
                        width: 22,
                        height: 22,
                        child: CircularProgressIndicator(
                            strokeWidth: 2.4, color: Colors.black),
                      )
                    : Text(
                        s.submit,
                        style: TextStyle(
                          color: _canSubmit
                              ? Colors.black
                              : Colors.white.withValues(alpha: 0.3),
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _field({
    required String label,
    required TextEditingController controller,
    TextInputType keyboard = TextInputType.text,
    bool obscure = false,
    int? maxLength,
    String? hint,
    bool showError = false,
    String? errorText,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 14,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 8),
          Container(
            decoration: neuBox(radius: 14, pressed: true),
            child: TextField(
              controller: controller,
              keyboardType: keyboard,
              obscureText: obscure,
              maxLength: maxLength,
              inputFormatters: keyboard == TextInputType.number
                  ? [FilteringTextInputFormatter.digitsOnly]
                  : null,
              style: const TextStyle(color: Colors.white, fontSize: 16),
              decoration: InputDecoration(
                counterText: '',
                border: InputBorder.none,
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
              ),
            ),
          ),
          if (hint != null && !showError) ...[
            const SizedBox(height: 6),
            Text(
              hint,
              style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.4), fontSize: 12),
            ),
          ],
          if (showError && errorText != null) ...[
            const SizedBox(height: 6),
            Text(
              errorText,
              style: const TextStyle(color: Color(0xFFEF4444), fontSize: 12),
            ),
          ],
        ],
      ),
    );
  }
}
