import 'package:flutter/services.dart';

/// Shared US phone helpers — live input mask + display format.
///
/// Used by the edit-profile phone field, the driver's manage-account
/// field and the forgot-password identifier field, so every box masks a
/// number the same way as it is typed. The contract is pinned by
/// test/phone_format_test.dart.

/// Digits only, with a US country code stripped when there is one.
String usPhoneDigits(String raw) {
  var d = raw.replaceAll(RegExp(r'\D'), '');
  if (d.length == 11 && d.startsWith('1')) d = d.substring(1);
  return d;
}

/// Display form: +1 (XXX) XXX-XXXX, built progressively — the closing
/// paren and the dash only appear once there are digits after them, so
/// half-typed numbers never show punctuation for places not yet typed.
///
/// Empty input stays empty. Anything that is not a US number (more than
/// ten digits after the country-code strip) is returned untouched —
/// grouping a foreign number as (xxx) xxx-xxxx would be a lie about
/// where the breaks are.
String formatUsPhone(String raw) {
  final d = usPhoneDigits(raw);
  if (d.isEmpty) return '';
  if (d.length > 10) return raw;

  final b = StringBuffer('+1 (');
  b.write(d.substring(0, d.length < 3 ? d.length : 3));
  if (d.length > 3) {
    b.write(') ');
    b.write(d.substring(3, d.length < 6 ? d.length : 6));
  }
  if (d.length > 6) {
    b.write('-');
    b.write(d.substring(6));
  }
  return b.toString();
}

/// Storage form: E.164 (+1XXXXXXXXXX) — what the backend holds.
///
/// Anything that is not exactly ten digits is refused (empty string):
/// a half-typed or over-long field must never read as a valid change.
String usPhoneToE164(String raw) {
  final d = usPhoneDigits(raw);
  return d.length == 10 ? '+1$d' : '';
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
