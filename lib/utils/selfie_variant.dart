import '../services/api_service.dart';
import '../services/user_session.dart';

/// The tier×gender variant of the dress-code/selfie assets (2026-10-23,
/// owner spec): VIP when the driver's ACTIVE vehicle is vip/black, women's
/// photos when the cached profile gender is 'female' — anything unknown
/// falls back to the men's standard variant.
///
/// ONE source, shared by the first-trip guide (pages 1 and 6) and the
/// selfie-check screen — never resolve the variant inline again.
Future<String> resolveSelfieVariant() async {
  var female = false;
  var vip = false;
  try {
    final u = await UserSession.getUser();
    female = u?['gender'] == 'female';
  } catch (_) {}
  try {
    final vehicles = await ApiService.getVehicles();
    if (vehicles.isNotEmpty) {
      final active = vehicles.firstWhere(
        (v) => v['is_active'] == true,
        orElse: () => vehicles.first,
      );
      final tier = (active['vehicle_type'] ?? '').toString().toLowerCase();
      vip = tier == 'vip' || tier == 'black';
    }
  } catch (_) {}
  return '${vip ? 'vip' : 'std'}_${female ? 'f' : 'm'}';
}
