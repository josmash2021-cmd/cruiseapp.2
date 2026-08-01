import 'package:flutter/services.dart';

/// US phone formatting, applied while the driver types.
///
/// The app stores E.164 (`+13854612042`) because that is what Twilio and
/// the backend expect, but nobody reads a phone number as one run of
/// eleven digits. This formats for the eye and [digitsOnly] gives the
/// storage form back.
///
/// Only US/CA numbers get the (xxx) xxx-xxxx shape. Anything with a
/// different country code is left as typed rather than forced into a
/// pattern it does not have — a wrong grouping is worse than none.
class UsPhoneFormatter extends TextInputFormatter {
  const UsPhoneFormatter();

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    final digits = newValue.text.replaceAll(RegExp(r'[^0-9]'), '');
    final formatted = formatUsPhone(digits);
    // Keep the caret at the end. Mid-string editing in a mask is a rabbit
    // hole; a phone field is short enough that select-all-and-retype is
    // the normal correction anyway.
    return TextEditingValue(
      text: formatted,
      selection: TextSelection.collapsed(offset: formatted.length),
    );
  }
}

/// `13854612042` → `+1 (385) 461-2042`.
///
/// Accepts the number with or without the leading country digit, and with
/// or without punctuation, so it can format both what the server sent and
/// what the driver is typing.
String formatUsPhone(String raw) {
  var d = raw.replaceAll(RegExp(r'[^0-9]'), '');

  // A leading 1 on an 11-digit number is the country code, not an area
  // code. On a 10-digit number there is no country code to strip.
  if (d.length == 11 && d.startsWith('1')) {
    d = d.substring(1);
  } else if (d.length > 11) {
    // Not a US number — hand back what was typed, punctuation and all.
    return raw;
  }

  if (d.isEmpty) return '';
  if (d.length <= 3) return '+1 ($d';
  if (d.length <= 6) return '+1 (${d.substring(0, 3)}) ${d.substring(3)}';
  return '+1 (${d.substring(0, 3)}) ${d.substring(3, 6)}-${d.substring(6, d.length.clamp(0, 10))}';
}

/// The storage form: `+13854612042`.
///
/// Returns an empty string for anything that is not a complete US number,
/// so a half-typed field cannot be saved as a real one.
String usPhoneToE164(String formatted) {
  var d = formatted.replaceAll(RegExp(r'[^0-9]'), '');
  if (d.length == 11 && d.startsWith('1')) d = d.substring(1);
  if (d.length != 10) return '';
  return '+1$d';
}
