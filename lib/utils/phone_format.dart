import 'package:flutter/services.dart';

/// Shared US phone helpers — live input mask + display format.
///
/// Used by the edit-profile phone field and the forgot-password identifier
/// field, so both mask a number the same way as it is typed.

/// Digits only, without the US country code.
String usPhoneDigits(String raw) {
  var d = raw.replaceAll(RegExp(r'\D'), '');
  if (d.startsWith('1') && d.length > 10) d = d.substring(1);
  if (d.length > 10) d = d.substring(d.length - 10);
  return d;
}

/// Storage form: E.164 (+1XXXXXXXXXX) — what the backend holds.
String usPhoneToE164(String raw) {
  final d = usPhoneDigits(raw);
  return d.isEmpty ? '' : '+1$d';
}

/// Display form: +1 (XXX) XXX-XXXX. Empty input stays empty.
String formatUsPhone(String digits) {  if (digits.isEmpty) return '';
  final b = StringBuffer('+1 (');
  b.write(digits.substring(0, digits.length < 3 ? digits.length : 3));
  if (digits.length >= 3) b.write(')');
  if (digits.length > 3) {
    b.write(' ');
    b.write(digits.substring(3, digits.length < 6 ? digits.length : 6));
  }
  if (digits.length > 6) {
    b.write('-');
    b.write(digits.substring(6));
  }
  return b.toString();
}

/// Live mask: keeps at most 10 US digits (a leading 1 country code is
/// dropped) and renders them as +1 (XXX) XXX-XXXX while typing.
class UsPhoneFormatter extends TextInputFormatter {
  const UsPhoneFormatter();

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    var d = newValue.text.replaceAll(RegExp(r'\D'), '');
    if (d.startsWith('1')) d = d.substring(1);
    if (d.length > 10) d = d.substring(0, 10);
    final text = formatUsPhone(d);
    return TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
  }
}
