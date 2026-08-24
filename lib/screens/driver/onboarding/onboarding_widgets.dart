import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// Shared visual language for the driver onboarding Phase 2 flow
/// (navy #0A1128 + gold #E8C547). Keep every screen on these.
const kOnboardingNavy = Color(0xFF0A1128);
const kOnboardingGold = Color(0xFFE8C547);

/// Big gold primary button (58 h, radius 18) — the same one the earlier
/// onboarding steps use. Disabled renders dimmed.
class OnboardingGoldButton extends StatelessWidget {
  const OnboardingGoldButton({
    super.key,
    required this.label,
    required this.onTap,
    this.loading = false,
  });

  final String label;

  /// Null → disabled (dimmed gold).
  final VoidCallback? onTap;
  final bool loading;

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null && !loading;
    return GestureDetector(
      onTap: enabled ? onTap : null,
      child: AnimatedOpacity(
        duration: const Duration(milliseconds: 150),
        opacity: enabled ? 1 : 0.45,
        child: Container(
          width: double.infinity,
          height: 58,
          decoration: BoxDecoration(
            color: kOnboardingGold,
            borderRadius: BorderRadius.circular(18),
          ),
          alignment: Alignment.center,
          child: loading
              ? const SizedBox(
                  width: 24,
                  height: 24,
                  child: CircularProgressIndicator(
                    strokeWidth: 2.5,
                    color: Colors.black,
                  ),
                )
              : Text(
                  label,
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                    color: Colors.black,
                  ),
                ),
        ),
      ),
    );
  }
}

/// Centered secondary text action ("Skip for now" and friends).
class OnboardingTextButton extends StatelessWidget {
  const OnboardingTextButton({super.key, required this.label, this.onTap});

  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 14),
        child: Center(
          child: Text(
            label,
            style: GoogleFonts.inter(
              fontSize: 15,
              fontWeight: FontWeight.w600,
              color: Colors.white.withValues(alpha: 0.55),
            ),
          ),
        ),
      ),
    );
  }
}

/// Dark text field used by the capture screens (plate / SSN / vehicle).
class OnboardingField extends StatelessWidget {
  const OnboardingField({
    super.key,
    required this.controller,
    required this.label,
    this.keyboardType,
    this.inputFormatters,
    this.textCapitalization = TextCapitalization.none,
    this.errorText,
    this.onChanged,
    this.maxLength,
  });

  final TextEditingController controller;
  final String label;
  final TextInputType? keyboardType;
  final List<dynamic>? inputFormatters;
  final TextCapitalization textCapitalization;
  final String? errorText;
  final ValueChanged<String>? onChanged;
  final int? maxLength;

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      keyboardType: keyboardType,
      inputFormatters: inputFormatters?.cast(),
      textCapitalization: textCapitalization,
      maxLength: maxLength,
      onChanged: onChanged,
      style: const TextStyle(
        color: Colors.white,
        fontSize: 16,
        fontWeight: FontWeight.w600,
      ),
      cursorColor: kOnboardingGold,
      decoration: InputDecoration(
        counterText: '',
        labelText: label,
        labelStyle: TextStyle(color: Colors.white.withValues(alpha: 0.55)),
        floatingLabelStyle: const TextStyle(color: kOnboardingGold),
        errorText: errorText,
        filled: true,
        fillColor: Colors.white.withValues(alpha: 0.06),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: Colors.white.withValues(alpha: 0.18)),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: kOnboardingGold, width: 1.6),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: Color(0xFFE57373)),
        ),
        focusedErrorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: Color(0xFFE57373), width: 1.6),
        ),
      ),
    );
  }
}

/// Dark dropdown matching [OnboardingField].
class OnboardingDropdown<T> extends StatelessWidget {
  const OnboardingDropdown({
    super.key,
    required this.label,
    required this.value,
    required this.items,
    required this.onChanged,
  });

  final String label;
  final T? value;
  final List<T> items;
  final ValueChanged<T?> onChanged;

  @override
  Widget build(BuildContext context) {
    return DropdownButtonFormField<T>(
      initialValue: value,
      // Cap the menu so long lists (50 states, ~30 makes) open as a
      // floating card, not an ugly full-height top-to-bottom wall.
      menuMaxHeight: 340,
      borderRadius: BorderRadius.circular(16),
      items: [
        for (final item in items)
          DropdownMenuItem<T>(
            value: item,
            child: Text(
              item.toString(),
              style: const TextStyle(
                color: Colors.white,
                fontSize: 16,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
      ],
      onChanged: onChanged,
      dropdownColor: const Color(0xFF131C3A),
      icon: Icon(
        Icons.keyboard_arrow_down_rounded,
        color: Colors.white.withValues(alpha: 0.6),
      ),
      style: const TextStyle(color: Colors.white),
      decoration: InputDecoration(
        labelText: label,
        labelStyle: TextStyle(color: Colors.white.withValues(alpha: 0.55)),
        floatingLabelStyle: const TextStyle(color: kOnboardingGold),
        filled: true,
        fillColor: Colors.white.withValues(alpha: 0.06),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: Colors.white.withValues(alpha: 0.18)),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: kOnboardingGold, width: 1.6),
        ),
      ),
    );
  }
}

/// Shared error snackbar for onboarding submits.
void showOnboardingError(BuildContext context, String message) {
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      backgroundColor: Colors.redAccent,
      content: Text(
        message,
        style: const TextStyle(fontWeight: FontWeight.w600),
      ),
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      duration: const Duration(seconds: 4),
    ),
  );
}
