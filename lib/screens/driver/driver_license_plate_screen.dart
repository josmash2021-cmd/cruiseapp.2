import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../l10n/app_localizations.dart';
import '../../services/api_service.dart';
import '../../services/haptic_service.dart';
import '../../widgets/neu_style.dart';

/// Change the plate on file.
///
/// Typed twice on purpose. A plate is copied off a metal strip in a car
/// park and a single wrong character means the registration will not
/// match — and the cost of that mistake is a driver offline until
/// dispatch sorts it out, so it is worth the second field.
///
/// The consequence is stated before they type, not after they save.
class DriverLicensePlateScreen extends StatefulWidget {
  const DriverLicensePlateScreen({
    super.key,
    this.currentPlate = '',
    this.currentState,
  });

  final String currentPlate;
  final String? currentState;

  @override
  State<DriverLicensePlateScreen> createState() =>
      _DriverLicensePlateScreenState();
}

class _DriverLicensePlateScreenState extends State<DriverLicensePlateScreen> {
  static const _gold = Color(0xFFE8C547);

  /// The two states Cruise operates in. Adding one here is not enough on
  /// its own — dispatch radius is per-state in the backend too.
  static const _states = <String, String>{
    'AL': 'Alabama',
    'FL': 'Florida',
  };

  late final TextEditingController _plate =
      TextEditingController(text: widget.currentPlate);
  late final TextEditingController _confirm = TextEditingController();
  late String? _state = widget.currentState;

  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _plate.dispose();
    _confirm.dispose();
    super.dispose();
  }

  bool get _isChange =>
      _plate.text.trim().toUpperCase() !=
          widget.currentPlate.trim().toUpperCase() ||
      (_state ?? '') != (widget.currentState ?? '');

  Future<void> _save() async {
    final s = S.of(context);
    final plate = _plate.text.trim().toUpperCase();
    final confirm = _confirm.text.trim().toUpperCase();

    if (plate.isEmpty) {
      setState(() => _error = s.licensePlateNumber);
      return;
    }
    if (confirm != plate) {
      setState(() => _error = s.platesDoNotMatch);
      return;
    }

    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final res = await ApiService.changeLicensePlate(
        plate: plate,
        confirmPlate: confirm,
        state: _state,
      );
      if (!mounted) return;
      final changed = res['plate_changed'] == true;
      Navigator.pop(context, changed);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(changed ? s.plateChangePendingBody : s.plateSaved),
          duration: Duration(seconds: changed ? 6 : 3),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e is ApiException ? e.message : s.failedToAddMethod;
        _saving = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    return Scaffold(
      backgroundColor: neuBase,
      body: SafeArea(
        child: ListView(
          physics: const BouncingScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 40),
          children: [
            Row(
              children: [
                GestureDetector(
                  onTap: () => Navigator.pop(context),
                  child: Container(
                    width: 42,
                    height: 42,
                    decoration: neuBox(radius: 14),
                    child: const Icon(Icons.close_rounded,
                        color: Colors.white, size: 21),
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Text(
                    s.licensePlateNumber,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 20,
                      fontWeight: FontWeight.w800,
                      letterSpacing: -0.4,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 22),
            Text(
              s.licensePlateIntro,
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.5),
                fontSize: 14,
                height: 1.45,
              ),
            ),
            const SizedBox(height: 22),
            _field(s.licensePlateNumber, _plate),
            const SizedBox(height: 12),
            _field(s.confirmLicensePlate, _confirm),
            const SizedBox(height: 12),
            _statePicker(s),

            // Said before they type, not after they save. Changing a plate
            // costs a driver their shift, and nobody should learn that
            // from a snackbar once it has already happened.
            if (_isChange) ...[
              const SizedBox(height: 18),
              Container(
                padding: const EdgeInsets.all(14),
                decoration: neuBox(radius: 14, pressed: true),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Icon(Icons.warning_amber_rounded,
                        color: Color(0xFFE8A33D), size: 19),
                    const SizedBox(width: 11),
                    Expanded(
                      child: Text(
                        s.plateChangeWarning,
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.6),
                          fontSize: 12.5,
                          height: 1.45,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],

            if (_error != null) ...[
              const SizedBox(height: 14),
              Text(
                _error!,
                style: const TextStyle(color: Color(0xFFE05C5C), fontSize: 13),
              ),
            ],

            const SizedBox(height: 26),
            GestureDetector(
              onTap: _saving
                  ? null
                  : () {
                      HapticService.mediumImpact();
                      _save();
                    },
              child: Container(
                height: 54,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: _saving ? _gold.withValues(alpha: 0.4) : _gold,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: _saving
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                            color: Colors.black, strokeWidth: 2),
                      )
                    : Text(
                        s.save,
                        style: const TextStyle(
                          color: Colors.black,
                          fontSize: 16,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _field(String label, TextEditingController c) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: neuBox(radius: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.45),
              fontSize: 12.5,
            ),
          ),
          TextField(
            controller: c,
            // Plates are upper-case everywhere Cruise runs, and a driver
            // typing lower case should not fail a comparison over it.
            textCapitalization: TextCapitalization.characters,
            inputFormatters: [
              LengthLimitingTextInputFormatter(15),
              FilteringTextInputFormatter.allow(RegExp(r'[A-Za-z0-9 \-]')),
              TextInputFormatter.withFunction(
                (_, next) => next.copyWith(text: next.text.toUpperCase()),
              ),
            ],
            onChanged: (_) => setState(() {}),
            style: const TextStyle(
              color: Colors.white,
              fontSize: 17,
              fontWeight: FontWeight.w600,
              letterSpacing: 1.1,
            ),
            decoration: const InputDecoration(
              isDense: true,
              border: InputBorder.none,
              contentPadding: EdgeInsets.symmetric(vertical: 6),
            ),
          ),
        ],
      ),
    );
  }

  Widget _statePicker(S s) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: neuBox(radius: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            s.stateLabel,
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.45),
              fontSize: 12.5,
            ),
          ),
          DropdownButtonHideUnderline(
            child: DropdownButton<String>(
              value: _states.containsKey(_state) ? _state : null,
              isExpanded: true,
              dropdownColor: neuSurface,
              icon: Icon(Icons.keyboard_arrow_down_rounded,
                  color: Colors.white.withValues(alpha: 0.5)),
              hint: Text(
                s.stateLabel,
                style: TextStyle(color: Colors.white.withValues(alpha: 0.35)),
              ),
              style: const TextStyle(
                color: Colors.white,
                fontSize: 17,
                fontWeight: FontWeight.w600,
              ),
              items: [
                for (final e in _states.entries)
                  DropdownMenuItem(value: e.key, child: Text(e.value)),
              ],
              onChanged: (v) => setState(() => _state = v),
            ),
          ),
        ],
      ),
    );
  }
}
