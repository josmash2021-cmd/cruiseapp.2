import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import '../../services/api_service.dart';
import '../../services/user_session.dart';
import '../../config/page_transitions.dart';
import '../../l10n/app_localizations.dart';
import '../home_screen.dart';

/// Vehicle management screen – view car details & upload vehicle documents.
class DriverVehicleScreen extends StatefulWidget {
  const DriverVehicleScreen({super.key});

  @override
  State<DriverVehicleScreen> createState() => _DriverVehicleScreenState();
}

class _DriverVehicleScreenState extends State<DriverVehicleScreen> {
  static const _gold = Color(0xFFE8C547);
  static const _goldDark = Color(0xFFD4A843);
  static const _card = Color(0xFF1C1C1E);
  static const _surface = Color(0xFF141414);
  // _gold removed — use _gold for pending/missing doc styling
  static const _green = Color(0xFF4CAF50);

  String _make = '';
  String _model = '';
  String _year = '';
  String _color = '';
  String _plate = '';
  String _vehicleType = 'comfort';
  bool _insuranceValid = false;
  bool _registrationValid = false;
  bool _loading = true;
  bool _uploading = false;

  final _picker = ImagePicker();

  @override
  void initState() {
    super.initState();
    _enforceDriverRole();
    _fetchVehicle();
  }

  void _enforceDriverRole() {
    UserSession.getMode().then((mode) {
      if (mode != 'driver' && mounted) {
        Navigator.of(context).pushAndRemoveUntil(
          fadeThroughRoute(const HomeScreen()),
          (_) => false,
        );
      }
    });
  }

  Future<void> _fetchVehicle() async {
    try {
      final v = await ApiService.getVehicle();
      if (!mounted) return;
      if (v == null) {
        setState(() => _loading = false);
        return;
      }
      setState(() {
        _make = (v['make'] ?? '') as String;
        _model = (v['model'] ?? '') as String;
        _year = (v['year'] ?? '').toString();
        _color = (v['color'] ?? '') as String;
        _plate = (v['plate'] ?? '') as String;
        _vehicleType = (v['vehicle_type'] ?? 'comfort') as String;
        _insuranceValid = v['insurance_valid'] == true;
        _registrationValid = v['registration_valid'] == true;
        _loading = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  /// Vehicle tier → car image asset
  String get _carImage {
    switch (_vehicleType.toLowerCase()) {
      case 'vip':
        return 'assets/images/cruise_3.png';
      case 'premium':
        return 'assets/images/cruise_7.png';
      default: // comfort
        return 'assets/images/cruise_6.png';
    }
  }

  /// Vehicle tier → display info
  ({String label, Color color, IconData icon}) get _tierInfo {
    switch (_vehicleType.toLowerCase()) {
      case 'vip':
        return (
          label: 'VIP',
          color: const Color(0xFFD4A843),
          icon: Icons.star_rounded,
        );
      case 'premium':
        return (
          label: 'PREMIUM',
          color: const Color(0xFFB0BEC5),
          icon: Icons.diamond_rounded,
        );
      default:
        return (
          label: 'COMFORT',
          color: const Color(0xFF66BB6A),
          icon: Icons.eco_rounded,
        );
    }
  }

  bool get _allDocsValid => _insuranceValid && _registrationValid;

  int get _missingDocsCount =>
      (!_insuranceValid ? 1 : 0) +
      (!_registrationValid ? 1 : 0);

  /// Upload a document photo via camera or gallery
  Future<void> _uploadDocument(String docType, String title) async {
    final source = await showModalBottomSheet<ImageSource>(
      context: context,
      backgroundColor: _card,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.white24,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(height: 20),
              Text(
                'Upload $title',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 17,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 20),
              ListTile(
                leading: Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: _gold.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: const Icon(Icons.camera_alt_rounded,
                      color: _gold, size: 22),
                ),
                title: const Text('Take Photo',
                    style: TextStyle(
                        color: Colors.white, fontWeight: FontWeight.w600)),
                subtitle: Text('Use camera to capture document',
                    style:
                        TextStyle(color: Colors.white.withValues(alpha: 0.4), fontSize: 12)),
                onTap: () => Navigator.pop(ctx, ImageSource.camera),
              ),
              ListTile(
                leading: Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: _gold.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: const Icon(Icons.photo_library_rounded,
                      color: _gold, size: 22),
                ),
                title: const Text('Choose from Gallery',
                    style: TextStyle(
                        color: Colors.white, fontWeight: FontWeight.w600)),
                subtitle: Text('Select an existing photo',
                    style:
                        TextStyle(color: Colors.white.withValues(alpha: 0.4), fontSize: 12)),
                onTap: () => Navigator.pop(ctx, ImageSource.gallery),
              ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
    if (source == null || !mounted) return;

    try {
      final xFile = await _picker.pickImage(
        source: source,
        maxWidth: 1920,
        maxHeight: 1920,
        imageQuality: 85,
      );
      if (xFile == null || !mounted) return;

      setState(() => _uploading = true);
      final bytes = await File(xFile.path).readAsBytes();
      final base64Photo = base64Encode(bytes);

      await ApiService.uploadDocument(
        docType: docType,
        photoBase64: base64Photo,
      );

      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('$title uploaded successfully'),
          backgroundColor: _green,
          behavior: SnackBarBehavior.floating,
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        ),
      );

      // Refresh vehicle data
      await _fetchVehicle();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Failed to upload $title'),
          backgroundColor: Colors.red,
          behavior: SnackBarBehavior.floating,
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        ),
      );
    } finally {
      if (mounted) setState(() => _uploading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    return Scaffold(
      backgroundColor: Colors.black,
      body: _loading
          ? const Center(
              child: CircularProgressIndicator(color: _gold, strokeWidth: 2))
          : Stack(
              children: [
                CustomScrollView(
                  physics: const BouncingScrollPhysics(),
                  slivers: [
                    SliverAppBar(
                      backgroundColor: _surface,
                      pinned: true,
                      expandedHeight: 110,
                      leading: IconButton(
                        icon: Container(
                          width: 38,
                          height: 38,
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha: 0.06),
                            shape: BoxShape.circle,
                          ),
                          child: const Icon(Icons.arrow_back_rounded,
                              color: Colors.white, size: 20),
                        ),
                        onPressed: () => Navigator.pop(context),
                      ),
                      centerTitle: true,
                      title: Text(
                        s.vehicleTitle,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 20,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                    ),
                    SliverToBoxAdapter(
                      child: Padding(
                        padding: const EdgeInsets.all(20),
                        child: Column(
                          children: [
                            // ── Top banner: Required to go online ──
                            if (!_allDocsValid) _buildRequiredBanner(),

                            // ── Car visual card ──
                            _buildCarCard(),
                            const SizedBox(height: 20),

                            // ── Vehicle document cards ──
                            _buildDocCard(
                              isValid: _insuranceValid,
                              title: s.vehicleInsuranceValid,
                              invalidTitle: 'Vehicle Insurance',
                              subtitle: _insuranceValid
                                  ? s.insuranceUpToDate
                                  : 'Required to go online',
                              icon: Icons.security_rounded,
                              docType: 'insurance',
                            ),
                            const SizedBox(height: 10),
                            _buildDocCard(
                              isValid: _registrationValid,
                              title: 'Registration Valid',
                              invalidTitle: 'Vehicle Registration',
                              subtitle: _registrationValid
                                  ? 'Vehicle registration up to date'
                                  : 'Required to go online',
                              icon: Icons.description_rounded,
                              docType: 'registration',
                            ),
                            const SizedBox(height: 24),

                            // ── Vehicle details ──
                            _buildSectionTitle('Vehicle Details'),
                            const SizedBox(height: 12),
                            _detailRow(s.makeLabel, _make,
                                Icons.directions_car_filled_rounded),
                            _detailRow(
                                s.modelLabel, _model, Icons.local_taxi_rounded),
                            _detailRow(s.yearLabel, _year,
                                Icons.calendar_today_rounded),
                            _detailRow(
                                s.colorLabel, _color, Icons.palette_rounded),
                            _detailRow(s.licensePlate, _plate,
                                Icons.confirmation_number_rounded),
                            const SizedBox(height: 30),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),

                // Uploading overlay
                if (_uploading)
                  Container(
                    color: Colors.black54,
                    child: const Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          CircularProgressIndicator(
                              color: _gold, strokeWidth: 2),
                          SizedBox(height: 16),
                          Text(
                            'Uploading document...',
                            style: TextStyle(
                              color: Colors.white70,
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
    );
  }

  // ══════════════════════════════════════════════════════════════════
  //  W I D G E T S
  // ══════════════════════════════════════════════════════════════════

  Widget _buildRequiredBanner() {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            _gold.withValues(alpha: 0.15),
            _gold.withValues(alpha: 0.05),
          ],
        ),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: _gold.withValues(alpha: 0.4)),
      ),
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: _gold.withValues(alpha: 0.15),
              shape: BoxShape.circle,
            ),
            child: const Icon(Icons.warning_amber_rounded,
                color: _gold, size: 22),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Required to go online',
                  style: TextStyle(
                    color: _gold,
                    fontSize: 15,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  'Upload $_missingDocsCount vehicle document${_missingDocsCount > 1 ? 's' : ''} below to activate your driver account.',
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.5),
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCarCard() {
    final tier = _tierInfo;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(24, 28, 24, 20),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            _gold.withValues(alpha: 0.10),
            Colors.transparent,
          ],
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
        ),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: _gold.withValues(alpha: 0.15)),
      ),
      child: Column(
        children: [
          // Car image based on vehicle tier
          SizedBox(
            height: 120,
            child: Image.asset(
              _carImage,
              fit: BoxFit.contain,
              errorBuilder: (_, __, ___) => Container(
                width: 80,
                height: 80,
                decoration: BoxDecoration(
                  color: _gold.withValues(alpha: 0.15),
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.directions_car_rounded,
                    color: _gold, size: 42),
              ),
            ),
          ),
          const SizedBox(height: 16),
          // Year Make Model
          Text(
            _year.isNotEmpty || _make.isNotEmpty || _model.isNotEmpty
                ? '$_year $_make $_model'.trim()
                : 'No vehicle info',
            style: const TextStyle(
              color: Colors.white,
              fontSize: 22,
              fontWeight: FontWeight.w900,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 8),
          // Plate number
          if (_plate.isNotEmpty)
            Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.06),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                _plate,
                style: const TextStyle(
                  color: _gold,
                  fontSize: 16,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 2,
                ),
              ),
            ),
          const SizedBox(height: 14),
          // Color + Vehicle tier badge
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (_color.isNotEmpty) ...[
                _tag(Icons.palette_rounded, _color),
                const SizedBox(width: 12),
              ],
              // Tier badge — styled like rider's Choose a Ride
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [
                      tier.color.withValues(alpha: 0.25),
                      tier.color.withValues(alpha: 0.10),
                    ],
                  ),
                  borderRadius: BorderRadius.circular(10),
                  border:
                      Border.all(color: tier.color.withValues(alpha: 0.35)),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(tier.icon, size: 14, color: tier.color),
                    const SizedBox(width: 6),
                    Text(
                      tier.label,
                      style: TextStyle(
                        color: tier.color,
                        fontSize: 12,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 1.5,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildDocCard({
    required bool isValid,
    required String title,
    required String invalidTitle,
    required String subtitle,
    required IconData icon,
    required String docType,
  }) {
    final displayTitle = isValid ? title : invalidTitle;
    final cardColor = isValid ? _green : _gold;

    return GestureDetector(
      onTap: () {
        HapticFeedback.selectionClick();
        if (!isValid) {
          _uploadDocument(docType, invalidTitle);
        }
      },
      child: Container(
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(
          color: cardColor.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: cardColor.withValues(alpha: 0.35)),
        ),
        child: Row(
          children: [
            Container(
              width: 42,
              height: 42,
              decoration: BoxDecoration(
                color: cardColor.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(icon, color: cardColor, size: 22),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    displayTitle,
                    style: TextStyle(
                      color: isValid ? cardColor : Colors.white,
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: TextStyle(
                      color: isValid
                          ? Colors.white.withValues(alpha: 0.4)
                          : cardColor.withValues(alpha: 0.8),
                      fontSize: 12,
                      fontWeight: isValid ? FontWeight.w400 : FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
            if (isValid)
              Icon(Icons.check_circle_rounded,
                  color: cardColor.withValues(alpha: 0.6), size: 20)
            else
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                decoration: BoxDecoration(
                  color: _gold.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.upload_rounded, color: _gold, size: 14),
                    SizedBox(width: 4),
                    Text(
                      'Upload',
                      style: TextStyle(
                        color: _gold,
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildSectionTitle(String title) {
    return Align(
      alignment: Alignment.centerLeft,
      child: Text(
        title.toUpperCase(),
        style: TextStyle(
          color: Colors.white.withValues(alpha: 0.35),
          fontSize: 11,
          fontWeight: FontWeight.w800,
          letterSpacing: 2,
        ),
      ),
    );
  }

  Widget _tag(IconData icon, String text) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: Colors.white.withValues(alpha: 0.4)),
          const SizedBox(width: 6),
          Text(
            text,
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.6),
              fontSize: 13,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }

  Widget _detailRow(String label, String value, IconData icon) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: _card,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.05),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(icon,
                color: Colors.white.withValues(alpha: 0.4), size: 18),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.35),
                    fontSize: 12,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  value.isNotEmpty ? value : '—',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
