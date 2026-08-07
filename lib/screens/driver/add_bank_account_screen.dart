import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_stripe/flutter_stripe.dart' as stripe;
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../l10n/app_localizations.dart';
import '../../services/api_service.dart';
import '../../services/haptic_service.dart';
import '../../services/user_session.dart';
import '../../widgets/neu_style.dart';

/// Routing + account number, typed in our own form — the Uber-style flow.
///
/// This only works because our connected accounts are Custom-style
/// (controller.requirement_collection == 'application'): the platform
/// collects requirements, so Stripe allows API bank attaches on them.
/// (On Stripe-hosted accounts every attach bounces with
/// oauth_not_supported — proven against live mode, 2026-08-07.)
///
/// Two safety lines hold here:
///   - The bank digits go from the Stripe SDK straight to Stripe; only the
///     resulting btok_ is posted to `/drivers/payout-methods/bank-account`.
///   - Because the platform collects KYC on these accounts, the form also
///     gathers DOB + address (what Stripe needs to enable transfers) and a
///     TOS checkbox linked to Stripe's Connected Account Agreement — the
///     backend records acceptance with date + IP + user agent, as Stripe
///     requires.
class AddBankAccountScreen extends StatefulWidget {
  const AddBankAccountScreen({super.key, this.replacing = false});

  /// A bank is already attached, so this is a replacement rather than a first
  /// setup. Only the wording changes here — the swap itself is the caller's
  /// job, since only it knows which method to remove.
  final bool replacing;

  @override
  State<AddBankAccountScreen> createState() => _AddBankAccountScreenState();
}

class _AddBankAccountScreenState extends State<AddBankAccountScreen> {
  static const _gold = Color(0xFFE8C547);

  /// (code, display name) — value sent to Stripe is the 2-letter code.
  static const _usStates = <(String, String)>[
    ('AL', 'Alabama'), ('AK', 'Alaska'), ('AZ', 'Arizona'), ('AR', 'Arkansas'),
    ('CA', 'California'), ('CO', 'Colorado'), ('CT', 'Connecticut'),
    ('DE', 'Delaware'), ('DC', 'District of Columbia'), ('FL', 'Florida'),
    ('GA', 'Georgia'), ('HI', 'Hawaii'), ('ID', 'Idaho'), ('IL', 'Illinois'),
    ('IN', 'Indiana'), ('IA', 'Iowa'), ('KS', 'Kansas'), ('KY', 'Kentucky'),
    ('LA', 'Louisiana'), ('ME', 'Maine'), ('MD', 'Maryland'),
    ('MA', 'Massachusetts'), ('MI', 'Michigan'), ('MN', 'Minnesota'),
    ('MS', 'Mississippi'), ('MO', 'Missouri'), ('MT', 'Montana'),
    ('NE', 'Nebraska'), ('NV', 'Nevada'), ('NH', 'New Hampshire'),
    ('NJ', 'New Jersey'), ('NM', 'New Mexico'), ('NY', 'New York'),
    ('NC', 'North Carolina'), ('ND', 'North Dakota'), ('OH', 'Ohio'),
    ('OK', 'Oklahoma'), ('OR', 'Oregon'), ('PA', 'Pennsylvania'),
    ('RI', 'Rhode Island'), ('SC', 'South Carolina'), ('SD', 'South Dakota'),
    ('TN', 'Tennessee'), ('TX', 'Texas'), ('UT', 'Utah'), ('VT', 'Vermont'),
    ('VA', 'Virginia'), ('WA', 'Washington'), ('WV', 'West Virginia'),
    ('WI', 'Wisconsin'), ('WY', 'Wyoming'),
  ];

  final _routing = TextEditingController();
  final _account = TextEditingController();
  final _confirm = TextEditingController();
  final _holder = TextEditingController();
  final _address = TextEditingController();
  final _city = TextEditingController();
  final _zip = TextEditingController();

  int? _dobDay;
  int? _dobMonth;
  int? _dobYear;
  String? _stateCode;
  bool _tosAccepted = false;

  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _prefillHolder();
    // The submit button lives or dies on these, so it has to rebuild as they
    // are typed rather than only when the field loses focus.
    for (final c in [_routing, _account, _confirm, _holder, _address, _city, _zip]) {
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
    _address.dispose();
    _city.dispose();
    _zip.dispose();
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
      _account.text.trim() == _confirm.text.trim() &&
      _dobDay != null &&
      _dobMonth != null &&
      _dobYear != null &&
      _address.text.trim().isNotEmpty &&
      _city.text.trim().isNotEmpty &&
      _stateCode != null &&
      _zip.text.trim().length >= 5 &&
      _tosAccepted;

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
      // Holder name as typed goes on the token; the account's KYC name comes
      // from the signup session (that is the legal identity Stripe checks).
      String? firstName;
      String? lastName;
      final u = await UserSession.getUser();
      if (u != null) {
        firstName = (u['firstName'] ?? '').toString().trim();
        lastName = (u['lastName'] ?? '').toString().trim();
      }
      if (!mounted) return;
      await ApiService.addBankAccountPayout(
        bankToken: btok,
        setDefault: true,
        firstName: firstName?.isNotEmpty == true ? firstName : null,
        lastName: lastName?.isNotEmpty == true ? lastName : null,
        dob: {'day': _dobDay!, 'month': _dobMonth!, 'year': _dobYear!},
        address: {
          'line1': _address.text.trim(),
          'city': _city.text.trim(),
          'state': _stateCode!,
          'postal_code': _zip.text.trim(),
        },
        tosAccepted: _tosAccepted,
      );
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
    final monthFormat =
        DateFormat.MMM(Localizations.localeOf(context).languageCode);
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
              widget.replacing ? s.editBankAccountTitle : s.addBankAccountTitle,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 30,
                fontWeight: FontWeight.w800,
                letterSpacing: -0.5,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              widget.replacing
                  ? s.editBankAccountSubtitle
                  : s.addBankAccountSubtitle,
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
            Text(
              s.dateOfBirth,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 14,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: _dropdown<int>(
                    value: _dobDay,
                    hint: s.dayLabel,
                    items: [
                      for (var d = 1; d <= 31; d++)
                        DropdownMenuItem(value: d, child: Text('$d')),
                    ],
                    onChanged: (v) => setState(() => _dobDay = v),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: _dropdown<int>(
                    value: _dobMonth,
                    hint: s.monthLabel,
                    items: [
                      for (var m = 1; m <= 12; m++)
                        DropdownMenuItem(
                          value: m,
                          child: Text(monthFormat.format(DateTime(2024, m))),
                        ),
                    ],
                    onChanged: (v) => setState(() => _dobMonth = v),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: _dropdown<int>(
                    value: _dobYear,
                    hint: s.yearLabel,
                    items: [
                      for (var y = DateTime.now().year - 18; y >= 1930; y--)
                        DropdownMenuItem(value: y, child: Text('$y')),
                    ],
                    onChanged: (v) => setState(() => _dobYear = v),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 18),
            _field(
              label: s.addressLabel,
              controller: _address,
              keyboard: TextInputType.streetAddress,
            ),
            _field(label: s.cityLabel, controller: _city),
            Text(
              s.stateLabel,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 14,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 8),
            _dropdown<String>(
              value: _stateCode,
              hint: s.stateLabel,
              items: [
                for (final st in _usStates)
                  DropdownMenuItem(value: st.$1, child: Text(st.$2)),
              ],
              onChanged: (v) => setState(() => _stateCode = v),
            ),
            const SizedBox(height: 18),
            _field(
              label: s.zipPostalCode,
              controller: _zip,
              keyboard: TextInputType.number,
              maxLength: 10,
            ),
            const SizedBox(height: 2),
            // Platform-collected accounts need an explicit yes to Stripe's
            // terms — without it Stripe ignores the acceptance entirely.
            GestureDetector(
              onTap: () => setState(() => _tosAccepted = !_tosAccepted),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 22,
                    height: 22,
                    child: Checkbox(
                      value: _tosAccepted,
                      onChanged: (v) =>
                          setState(() => _tosAccepted = v ?? false),
                      activeColor: _gold,
                      checkColor: Colors.black,
                      side: BorderSide(
                        color: Colors.white.withValues(alpha: 0.35),
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: GestureDetector(
                      onTap: () => launchUrl(
                        Uri.parse('https://stripe.com/legal/connect-account'),
                        mode: LaunchMode.externalApplication,
                      ),
                      child: Text(
                        s.agreeToStripeAgreement,
                        style: const TextStyle(
                          color: _gold,
                          fontSize: 13,
                          decoration: TextDecoration.underline,
                          decorationColor: _gold,
                          height: 1.35,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 14),
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

  Widget _dropdown<T>({
    required T? value,
    required String hint,
    required List<DropdownMenuItem<T>> items,
    required ValueChanged<T?> onChanged,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: neuBox(radius: 14, pressed: true),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<T>(
          value: value,
          hint: Text(
            hint,
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.35),
              fontSize: 14,
            ),
          ),
          isExpanded: true,
          dropdownColor: neuBase,
          iconEnabledColor: Colors.white.withValues(alpha: 0.5),
          style: const TextStyle(color: Colors.white, fontSize: 15),
          items: items,
          onChanged: onChanged,
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
