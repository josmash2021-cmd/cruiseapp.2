import 'package:flutter/material.dart';
import '../config/app_theme.dart';
import '../config/page_transitions.dart';
import '../l10n/app_localizations.dart';
import '../services/api_service.dart';
import '../services/analytics_service.dart';
import '../services/local_data_service.dart';
import 'map_picker_screen.dart';

class SavedAddressesScreen extends StatefulWidget {
  const SavedAddressesScreen({super.key});

  @override
  State<SavedAddressesScreen> createState() => _SavedAddressesScreenState();
}

class _SavedAddressesScreenState extends State<SavedAddressesScreen> {
  static const _gold = Color(0xFFE8C547);

  List<Map<String, dynamic>> _addresses = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final list = await ApiService.getSavedAddresses();
      if (!mounted) return;
      setState(() {
        _addresses = list.cast<Map<String, dynamic>>();
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _loading = false);
    }
  }

  Map<String, dynamic>? _findByType(String type) {
    for (final a in _addresses) {
      if ((a['label'] as String?)?.toLowerCase() == type) return a;
    }
    return null;
  }

  List<Map<String, dynamic>> get _favorites {
    return _addresses.where((a) {
      final l = (a['label'] as String?)?.toLowerCase() ?? '';
      return l != 'home' && l != 'work';
    }).toList();
  }

  Future<void> _addOrUpdateAddress(String type, {Map<String, dynamic>? existing}) async {
    // Navigate to map picker
    final result = await Navigator.of(context).push<Map<String, dynamic>>(
      slideFromRightRoute(MapPickerScreen(isPickup: true)),
    );
    if (result == null || !mounted) return;

    final address = result['address'] as String? ?? '';
    final lat = (result['lat'] as num?)?.toDouble() ?? 0.0;
    final lng = (result['lng'] as num?)?.toDouble() ?? 0.0;

    if (address.isEmpty) return;

    String label = type;
    String icon = type == 'home' ? 'home' : type == 'work' ? 'work' : 'star';

    // For favorites, ask for custom label
    if (type == 'favorite') {
      final customLabel = await _askLabel();
      if (customLabel == null || customLabel.isEmpty) return;
      label = customLabel;
    }

    try {
      if (existing != null && existing['id'] != null) {
        await ApiService.updateSavedAddress(
          id: existing['id'] as int,
          label: label,
          address: address,
          lat: lat,
          lng: lng,
          icon: icon,
        );
      } else {
        await ApiService.addSavedAddress(
          label: label,
          address: address,
          lat: lat,
          lng: lng,
          icon: icon,
        );
        AnalyticsService.instance.logEvent('saved_address_added', parameters: {'type': type});
      }
      // Sync to local storage
      await LocalDataService.saveFavorite(FavoritePlace(
        label: label,
        address: address,
        lat: lat,
        lng: lng,
        icon: icon,
      ));
      _load();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to save address: $e')),
      );
    }
  }

  Future<String?> _askLabel() async {
    final ctrl = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1E1E1E),
        title: const Text('Name this place', style: TextStyle(color: Colors.white)),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          style: const TextStyle(color: Colors.white),
          decoration: InputDecoration(
            hintText: 'e.g. Gym, Mom\'s house',
            hintStyle: TextStyle(color: Colors.white38),
            filled: true,
            fillColor: Colors.white.withValues(alpha: 0.06),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: BorderSide.none,
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text('Cancel', style: TextStyle(color: Colors.white54)),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(ctrl.text.trim()),
            child: Text('Save', style: TextStyle(color: _gold)),
          ),
        ],
      ),
    );
  }

  Future<void> _deleteAddress(Map<String, dynamic> addr) async {
    final id = addr['id'] as int?;
    if (id == null) return;
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1E1E1E),
        title: const Text('Delete address?', style: TextStyle(color: Colors.white)),
        content: Text(
          'Remove "${addr['label']}" from saved addresses?',
          style: const TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel', style: TextStyle(color: Colors.white54)),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Delete', style: TextStyle(color: Colors.redAccent)),
          ),
        ],
      ),
    );
    if (confirm != true) return;
    try {
      await ApiService.deleteSavedAddress(id);
      await LocalDataService.removeFavorite(addr['label'] as String? ?? '');
      AnalyticsService.instance.logEvent('saved_address_deleted', parameters: {
        'type': (addr['label'] as String?)?.toLowerCase() ?? 'favorite',
      });
      _load();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to delete: $e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final l = S.of(context);
    final home = _findByType('home');
    final work = _findByType('work');
    final favs = _favorites;

    return Scaffold(
      backgroundColor: c.bg,
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ── Header ──
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 12, 16, 0),
              child: Row(
                children: [
                  GestureDetector(
                    onTap: () => Navigator.of(context).pop(),
                    child: Padding(
                      padding: const EdgeInsets.all(8),
                      child: Icon(Icons.arrow_back_rounded,
                          color: c.textPrimary, size: 24),
                    ),
                  ),
                  const SizedBox(width: 4),
                  Text(
                    l.savedAddresses,
                    style: TextStyle(
                      fontSize: 28,
                      fontWeight: FontWeight.w800,
                      color: c.textPrimary,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 20),
            Expanded(
              child: _loading
                  ? const Center(child: CircularProgressIndicator(color: _gold))
                  : RefreshIndicator(
                      color: _gold,
                      onRefresh: _load,
                      child: ListView(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        children: [
                          // ── Home ──
                          _buildFixedAddress(
                            c,
                            icon: Icons.home_rounded,
                            label: 'Home',
                            address: home?['address'] as String?,
                            onTap: () => _addOrUpdateAddress('home', existing: home),
                          ),
                          const SizedBox(height: 10),
                          // ── Work ──
                          _buildFixedAddress(
                            c,
                            icon: Icons.work_rounded,
                            label: 'Work',
                            address: work?['address'] as String?,
                            onTap: () => _addOrUpdateAddress('work', existing: work),
                          ),
                          const SizedBox(height: 20),

                          // ── Favorites header ──
                          Row(
                            children: [
                              Icon(Icons.star_rounded, color: _gold, size: 18),
                              const SizedBox(width: 8),
                              Text(
                                'Favorites',
                                style: TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.w700,
                                  color: c.textPrimary,
                                ),
                              ),
                              const Spacer(),
                              if (favs.length < 10)
                                GestureDetector(
                                  onTap: () => _addOrUpdateAddress('favorite'),
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 12, vertical: 6),
                                    decoration: BoxDecoration(
                                      color: _gold.withValues(alpha: 0.12),
                                      borderRadius: BorderRadius.circular(20),
                                    ),
                                    child: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Icon(Icons.add_rounded,
                                            color: _gold, size: 16),
                                        const SizedBox(width: 4),
                                        Text('Add',
                                            style: TextStyle(
                                                color: _gold,
                                                fontSize: 13,
                                                fontWeight: FontWeight.w600)),
                                      ],
                                    ),
                                  ),
                                ),
                            ],
                          ),
                          const SizedBox(height: 10),
                          if (favs.isEmpty)
                            Padding(
                              padding: const EdgeInsets.symmetric(vertical: 24),
                              child: Center(
                                child: Text(
                                  'No favorite places saved yet',
                                  style: TextStyle(
                                      color: c.textTertiary, fontSize: 14),
                                ),
                              ),
                            )
                          else
                            ...favs.map((f) => Padding(
                                  padding: const EdgeInsets.only(bottom: 8),
                                  child: Dismissible(
                                    key: ValueKey(f['id']),
                                    direction: DismissDirection.endToStart,
                                    background: Container(
                                      alignment: Alignment.centerRight,
                                      padding:
                                          const EdgeInsets.only(right: 20),
                                      decoration: BoxDecoration(
                                        color: Colors.redAccent
                                            .withValues(alpha: 0.15),
                                        borderRadius:
                                            BorderRadius.circular(14),
                                      ),
                                      child: const Icon(
                                          Icons.delete_outline_rounded,
                                          color: Colors.redAccent),
                                    ),
                                    confirmDismiss: (_) async {
                                      await _deleteAddress(f);
                                      return false; // We handle refresh in _deleteAddress
                                    },
                                    child: _buildFavoriteItem(c, f),
                                  ),
                                )),
                          const SizedBox(height: 32),
                        ],
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildFixedAddress(
    AppColors c, {
    required IconData icon,
    required String label,
    String? address,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          color: c.surface,
          borderRadius: BorderRadius.circular(14),
          border: c.isDark
              ? null
              : Border.all(color: Colors.black.withValues(alpha: 0.06)),
        ),
        child: Row(
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: _gold.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(icon, color: _gold, size: 20),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label,
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        color: c.textPrimary,
                      )),
                  if (address != null)
                    Text(address,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontSize: 12, color: c.textTertiary))
                  else
                    Text('Tap to add',
                        style: TextStyle(
                            fontSize: 12, color: _gold.withValues(alpha: 0.7))),
                ],
              ),
            ),
            Text(
              address != null ? 'Change' : 'Add',
              style: TextStyle(
                  color: _gold, fontSize: 13, fontWeight: FontWeight.w600),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildFavoriteItem(AppColors c, Map<String, dynamic> f) {
    return GestureDetector(
      onTap: () => _addOrUpdateAddress('favorite', existing: f),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          color: c.surface,
          borderRadius: BorderRadius.circular(14),
          border: c.isDark
              ? null
              : Border.all(color: Colors.black.withValues(alpha: 0.06)),
        ),
        child: Row(
          children: [
            Icon(Icons.star_rounded, color: _gold.withValues(alpha: 0.6), size: 20),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(f['label']?.toString() ?? '',
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        color: c.textPrimary,
                      )),
                  Text(f['address']?.toString() ?? '',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 12, color: c.textTertiary)),
                ],
              ),
            ),
            Icon(Icons.chevron_right_rounded,
                color: Colors.white.withValues(alpha: 0.3), size: 20),
          ],
        ),
      ),
    );
  }
}
