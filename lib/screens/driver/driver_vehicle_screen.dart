import 'dart:io';
import 'package:flutter/material.dart';
import '../../utils/vehicle_tier_style.dart';
import '../../widgets/neu_style.dart';
import 'driver_vehicle_detail_screen.dart';
import '../../services/haptic_service.dart';
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
  String _insuranceStatus = ''; // pending, approved, rejected, or ''
  String _registrationStatus = '';
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
      final results = await Future.wait([
        ApiService.getVehicle(),
        ApiService.getDocuments(),
      ]);
      if (!mounted) return;
      final v = results[0] as Map<String, dynamic>?;
      final docs = results[1] as List<dynamic>? ?? [];

      // Find latest document status for each type
      String insStatus = '';
      String regStatus = '';
      for (final d in docs) {
        final type = d['doc_type'] as String? ?? '';
        final status = d['status'] as String? ?? '';
        if (type == 'insurance' && insStatus.isEmpty) insStatus = status;
        if (type == 'registration' && regStatus.isEmpty) regStatus = status;
      }

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
        _insuranceStatus = insStatus;
        _registrationStatus = regStatus;
        _loading = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  /// The driver's own garage art: three-quarter views (driver_tier_*),
  /// shown ONLY on this screen and its detail page. The rider keeps the
  /// side-profile `cruisert*` set — tierCarImage() — everywhere else.
  String get _carImage {
    switch (tierKey(_vehicleType)) {
      case kTierBlack:
        return 'assets/images/driver_tier_black.png';
      case kTierPremium:
        return 'assets/images/driver_tier_premium.png';
      case kTierCompact:
        return 'assets/images/driver_tier_compact.png';
      default:
        return 'assets/images/driver_tier_standard.png';
    }
  }

  /// Tier label, colour and icon.
  ///
  /// This used to hold its own switch that knew only VIP, PREMIUM and
  /// COMFORT, so a `black` or `compact` car fell through to the default
  /// and a Black driver read "COMFORT" under a green leaf.
  ({String label, Color color, IconData icon}) get _tierInfo => (
        label: tierLabel(_vehicleType),
        color: tierColor(_vehicleType),
        icon: tierIcon(_vehicleType),
      );

  bool get _allDocsValid => _insuranceValid && _registrationValid;

  bool get _allDocsPending =>
      !_allDocsValid &&
      (_insuranceValid || _insuranceStatus == 'pending') &&
      (_registrationValid || _registrationStatus == 'pending');

  int get _missingDocsCount =>
      (!_insuranceValid && _insuranceStatus != 'pending' ? 1 : 0) +
      (!_registrationValid && _registrationStatus != 'pending' ? 1 : 0);

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
                title: Text(S.of(context).takePhoto,
                    style: TextStyle(
                        color: Colors.white, fontWeight: FontWeight.w600)),
                subtitle: Text(S.of(context).takePhotoSubtitle,
                    style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.4),
                        fontSize: 12)),
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
                title: Text(S.of(context).chooseFromGallery,
                    style: TextStyle(
                        color: Colors.white, fontWeight: FontWeight.w600)),
                subtitle: Text(S.of(context).chooseFromGallerySubtitle,
                    style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.4),
                        fontSize: 12)),
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
        maxWidth: 1280,
        maxHeight: 1280,
        imageQuality: 75,
      );
      if (xFile == null || !mounted) return;

      setState(() => _uploading = true);
      final fileSize = await File(xFile.path).length();
      debugPrint(
          '[Vehicle] Photo file: ${xFile.path} size: ${(fileSize / 1024).toStringAsFixed(0)} KB');

      // Multipart upload (sends raw file — no base64 bloat)
      // Retry once on failure
      try {
        await ApiService.uploadDocument(
          docType: docType,
          filePath: xFile.path,
        );
      } catch (firstErr) {
        debugPrint('[Vehicle] First attempt failed: $firstErr — retrying...');
        await Future.delayed(const Duration(seconds: 2));
        await ApiService.uploadDocument(
          docType: docType,
          filePath: xFile.path,
        );
      }

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
      debugPrint('[Vehicle] Upload FAILED for $docType: $e');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(S.of(context).failedToUpload(
              title,
              e.toString().length > 80
                  ? e.toString().substring(0, 80)
                  : e.toString())),
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
      // The app's own ground, not black. Black is not a neutral here —
      // neumorphic shadows are invisible on it, which is why neuBase is
      // #14141A and not #000000.
      backgroundColor: neuBase,
      body: Stack(
        children: [
          const Positioned.fill(child: NeuDotsBackdrop()),
          _loading
          ? const Center(
              child: CircularProgressIndicator(color: _gold, strokeWidth: 2))
          : Stack(
              children: [
                CustomScrollView(
                  physics: const BouncingScrollPhysics(),
                  slivers: [
                    SliverAppBar(
                      // Same ground as the page, so the colour runs behind
                      // the title instead of stopping at a seam under it.
                      // _surface was #141414 against a black page: near
                      // enough to look like a mistake, far enough to show.
                      backgroundColor: neuBase,
                      surfaceTintColor: neuBase,
                      actions: [
                        // Adding a car is a document flow, not a form: the
                        // registration and the insurance have to be
                        // photographed and reviewed. Support runs it, so
                        // this points there rather than opening a page
                        // that would only collect a make and a model.
                        Padding(
                          padding: const EdgeInsets.only(right: 12),
                          child: GestureDetector(
                            onTap: () {
                              HapticService.selectionClick();
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  content: Text(S.of(context).addVehicleAsk),
                                ),
                              );
                            },
                            child: Container(
                              width: 38,
                              height: 38,
                              decoration: neuBox(radius: 19),
                              child: const Icon(
                                Icons.add_rounded,
                                color: _gold,
                                size: 22,
                              ),
                            ),
                          ),
                        ),
                      ],
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
                            _buildVehicleCard(),
                            const SizedBox(height: 30),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
        ],
      ),
    );
  }

  // ══════════════════════════════════════════════════════════════════
  //  W I D G E T S
  // ══════════════════════════════════════════════════════════════════

  Widget _buildReviewingBanner() {
    const orange = Color(0xFFFFA726);
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            orange.withValues(alpha: 0.15),
            orange.withValues(alpha: 0.05),
          ],
        ),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: orange.withValues(alpha: 0.4)),
      ),
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: orange.withValues(alpha: 0.15),
              shape: BoxShape.circle,
            ),
            child: const Icon(Icons.hourglass_top_rounded,
                color: orange, size: 22),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Documents under review',
                  style: TextStyle(
                    color: orange,
                    fontSize: 15,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  'We\'re reviewing your documents. You\'ll be notified once approved.',
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
            child:
                const Icon(Icons.warning_amber_rounded, color: _gold, size: 22),
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

  /// The vehicle as a card you could put a second one beside.
  ///
  /// The old layout was a hero — a car floating over a gradient, the name
  /// centred under it, then five rows repeating what the hero had already
  /// said. It read as a poster for one car, and this driver has one car
  /// today and may have two tomorrow.
  ///
  /// This is the shape a list wants: the year and the name stacked on the
  /// left where the eye starts, the plate under them, the car itself small
  /// and to the right where it identifies rather than performs, and one
  /// row at the bottom that opens the detail.
  Widget _buildVehicleCard() {
    final s = S.of(context);
    final title = '$_make $_model'.trim();
    return Container(
      padding: const EdgeInsets.fromLTRB(18, 18, 18, 6),
      decoration: neuBox(radius: 22),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (_year.isNotEmpty)
                      Text(
                        _year,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 24,
                          fontWeight: FontWeight.w800,
                          height: 1.15,
                          letterSpacing: -0.4,
                        ),
                      ),
                    Text(
                      title.isEmpty ? s.noVehicleOnFile : title,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 24,
                        fontWeight: FontWeight.w800,
                        height: 1.15,
                        letterSpacing: -0.4,
                      ),
                    ),
                    const SizedBox(height: 8),
                    if (_plate.isNotEmpty)
                      Text(
                        _plate.toUpperCase(),
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.45),
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          letterSpacing: 1.1,
                        ),
                      ),
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        if (_color.isNotEmpty)
                          _vehicleChip(Icons.palette_rounded, _color, null),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              // The tier sits over the car it describes.
              //
              // It used to lead the left column, above the year, where it
              // read as a heading for the whole card. It is a fact about
              // the vehicle, and the vehicle is on this side.
              //
              // White, not the tier colour: the label names the category,
              // and the colour is already carried by the glyph beside it.
              Column(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      tierGlyph(_vehicleType, size: 15),
                      const SizedBox(width: 6),
                      Text(
                        _tierInfo.label,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 12.5,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 1.1,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  // Small, and to the right. On the old card it was 120 px
                  // tall and centred, which made a stock render the loudest
                  // thing on a screen about paperwork.
                  SizedBox(
                    width: 116,
                    height: 84,
                    child: Image.asset(
                      _carImage,
                      fit: BoxFit.contain,
                      errorBuilder: (_, __, ___) => Icon(
                        Icons.directions_car_rounded,
                        color: _gold.withValues(alpha: 0.5),
                        size: 40,
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 6),
          Divider(height: 1, color: Colors.white.withValues(alpha: 0.06)),
          InkWell(
            onTap: () {
              HapticService.selectionClick();
              Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => DriverVehicleDetailScreen(
                    make: _make,
                    model: _model,
                    year: _year,
                    color: _color,
                    plate: _plate,
                    carImage: _carImage,
                    tierLabel: _tierInfo.label,
                    tierColor: _tierInfo.color,
                    tierIcon: _tierInfo.icon,
                  ),
                ),
              );
            },
            borderRadius: BorderRadius.circular(12),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 14),
              child: Row(
                children: [
                  Icon(
                    Icons.info_outline_rounded,
                    color: Colors.white.withValues(alpha: 0.6),
                    size: 19,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      s.seeDetails,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  Icon(
                    Icons.chevron_right_rounded,
                    color: Colors.white.withValues(alpha: 0.35),
                    size: 22,
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _vehicleChip(IconData icon, String label, Color? accent) {
    final c = accent ?? Colors.white.withValues(alpha: 0.6);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
      decoration: neuBox(radius: 10, pressed: true),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 13, color: c),
          const SizedBox(width: 6),
          Text(
            label,
            style: TextStyle(
              color: c,
              fontSize: 12,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.3,
            ),
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
    String docStatus = '',
  }) {
    final isPending = !isValid && docStatus == 'pending';
    final isRejected = !isValid && docStatus == 'rejected';
    final canUpload = !isValid && !isPending;
    final displayTitle = isValid
        ? title
        : isPending
            ? invalidTitle
            : invalidTitle;
    final cardColor = isValid
        ? _green
        : isPending
            ? const Color(0xFFFFA726) // orange for pending
            : isRejected
                ? Colors.red
                : _gold;

    return GestureDetector(
      onTap: () {
        HapticService.selectionClick();
        if (canUpload) {
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
                      color: isValid || isPending ? cardColor : Colors.white,
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
            else if (isPending)
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                decoration: BoxDecoration(
                  color: cardColor.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SizedBox(
                      width: 12,
                      height: 12,
                      child: CircularProgressIndicator(
                        color: cardColor,
                        strokeWidth: 1.5,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      'Reviewing',
                      style: TextStyle(
                        color: cardColor,
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
              )
            else
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                decoration: BoxDecoration(
                  color:
                      (isRejected ? Colors.red : _gold).withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.upload_rounded,
                        color: isRejected ? Colors.red : _gold, size: 14),
                    const SizedBox(width: 4),
                    Text(
                      isRejected ? 'Re-upload' : 'Upload',
                      style: TextStyle(
                        color: isRejected ? Colors.red : _gold,
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
