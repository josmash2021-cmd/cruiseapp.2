import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Whether the driver's earnings figures are covered on screen.
///
/// This is about the phone, not the account. A driver reads their earnings
/// with a passenger sitting behind them, and the amount sits in a chip at
/// the top of the map where it is legible from the back seat. The switch
/// that turns it off lives in Earnings; the figures it covers are on Home
/// and Online.
///
/// A [ValueNotifier] rather than a value each screen reads at build time,
/// because those screens are already mounted when the switch is flipped —
/// they are underneath the Earnings route, not rebuilt on the way back. A
/// preference read once in initState would take effect on the next launch,
/// which is not what anyone means by a switch.
class EarningsPrivacy {
  EarningsPrivacy._();

  static const _key = 'driver_hide_earnings';

  /// True while the figures should be covered. Listen to this.
  static final ValueNotifier<bool> hidden = ValueNotifier<bool>(false);

  static bool _loaded = false;

  /// Read the stored preference once per launch. Safe to call repeatedly.
  static Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      hidden.value = prefs.getBool(_key) ?? false;
    } catch (e) {
      debugPrint('[EarningsPrivacy] could not read the preference: $e');
    }
  }

  static Future<void> set(bool value) async {
    hidden.value = value;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_key, value);
    } catch (e) {
      debugPrint('[EarningsPrivacy] could not store the preference: $e');
    }
  }

  /// The amount as the driver should see it: the figure, or a bare dollar
  /// sign standing in for it.
  ///
  /// Not asterisks and not a blurred number — a row of dots still says "an
  /// amount is here, and it is four digits long". A lone $ says nothing at
  /// all, which is the point.
  static String format(double amount) =>
      hidden.value ? '\$' : '\$${amount.toStringAsFixed(2)}';
}
