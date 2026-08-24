import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import '../../services/haptic_service.dart';
import 'package:image_picker/image_picker.dart';
import '../../config/page_transitions.dart';
import '../../services/api_service.dart';
import '../../services/firebase_storage_service.dart';
import '../../l10n/app_localizations.dart';
import '../../widgets/neu_style.dart';
import 'background_check_consent_screen.dart';
import 'driver_license_plate_screen.dart';

enum _ExpiryStatus { ok, expiringSoon, expired }

/// Document management screen – driver's license, insurance, registration.
class DriverDocumentsScreen extends StatefulWidget {
  const DriverDocumentsScreen({super.key});

  @override
  State<DriverDocumentsScreen> createState() => _DriverDocumentsScreenState();
}

class _DriverDocumentsScreenState extends State<DriverDocumentsScreen> {
  static const _gold = Color(0xFFE8C547);

  bool _loading = true;
  bool _uploading = false;
  List<Map<String, dynamic>> _documents = [];
  String _vehicleLabel = '';
  // The completed list is the whole page — it opens expanded.
  bool _submittedOpen = true;
  final _picker = ImagePicker();

  // All required doc types for drivers
  static const _requiredDocs = [
    // Not a document — a field. It sits in this list because it is one
    // more thing dispatch has to be satisfied with before a driver
    // works, and because changing it invalidates the registration two
    // rows down. Keeping it on another screen would hide that link.
    {
      'doc_type': 'license_plate',
      'title': 'License plate number',
      'icon': Icons.pin_rounded,
    },
    {
      'doc_type': 'drivers_license',
      'title': "Driver's License",
      'icon': Icons.badge_rounded,
    },
    {
      'doc_type': 'background_check',
      'title': 'Background Check',
      'icon': Icons.verified_user_rounded,
    },
    {
      'doc_type': 'insurance',
      'title': 'Car Insurance',
      'icon': Icons.shield_rounded,
    },
    {
      'doc_type': 'registration',
      'title': 'Car Registration',
      'icon': Icons.description_rounded,
    },
    {
      'doc_type': 'profile_photo',
      'title': 'Face Biometrics',
      'icon': Icons.face_retouching_natural_rounded,
    },
  ];

  @override
  void initState() {
    super.initState();
    _fetchDocuments();
  }

  Future<void> _fetchDocuments() async {
    setState(() => _loading = true);
    try {
      final results = await Future.wait([
        ApiService.getDocuments(),
        ApiService.getMe(),
        ApiService.getVehicle(),
        ApiService.getOnboardingItems(),
      ]);
      if (!mounted) return;

      final docs = results[0] as List<Map<String, dynamic>>;
      final me = results[1] as Map<String, dynamic>?;
      final vehicle = results[2] as Map<String, dynamic>?;
      final onboarding =
          (results[3] as Map<String, dynamic>?)?['items']
              as Map<String, dynamic>? ??
          <String, dynamic>{};

      // Check if user is verified
      final verificationStatus = me?['verification_status'] ?? 'none';
      final isVerified = verificationStatus == 'approved';
      final bgCheckStatus = me?['background_check_status'] as String? ?? 'none';

      // Vehicle-level document validity
      final insuranceValid = vehicle?['insurance_valid'] == true;
      final registrationValid = vehicle?['registration_valid'] == true;

      // Merge with required doc types
      final merged = <Map<String, dynamic>>[];
      for (final req in _requiredDocs) {
        final docType = req['doc_type'] as String;

        // The plate is read off the vehicle, not the documents table.
        // "Pending" here means the driver changed it and dispatch has
        // not approved the new registration yet.
        if (docType == 'license_plate') {
          final plate = (vehicle?['plate'] ?? '').toString().trim();
          final pending = vehicle?['plate_pending_review'] == true;
          merged.add({
            'doc_type': docType,
            'title': req['title'],
            'icon': req['icon'],
            'status': plate.isEmpty
                ? 'not_uploaded'
                : pending
                    ? 'pending'
                    : 'approved',
            'plate': plate,
            'plate_state': (vehicle?['plate_state'] ?? '').toString(),
          });
          continue;
        }

        // Background check — use status from user profile
        if (docType == 'background_check') {
          String bgStatus;
          if (isVerified || bgCheckStatus == 'clear') {
            bgStatus = 'approved';
          } else if (bgCheckStatus == 'pending' || bgCheckStatus == 'processing') {
            bgStatus = 'pending';
          } else if (bgCheckStatus == 'consider' || bgCheckStatus == 'suspended') {
            bgStatus = 'rejected';
          } else {
            bgStatus = 'not_uploaded';
          }
          merged.add({
            'doc_type': docType,
            'title': req['title'],
            'icon': req['icon'],
            'status': bgStatus,
          });
          continue;
        }

        // Insurance/Registration — check vehicle-level validity
        if (docType == 'insurance' || docType == 'registration') {
          final vehicleOk = docType == 'insurance' ? insuranceValid : registrationValid;
          final existing = docs.firstWhere(
            (d) => d['doc_type'] == docType,
            orElse: () => <String, dynamic>{},
          );

          String status;
          if (vehicleOk || isVerified) {
            status = 'approved';
          } else if (existing.isNotEmpty) {
            status = existing['status'] as String? ?? 'pending';
          } else {
            status = isVerified ? 'approved' : 'not_uploaded';
          }

          merged.add({
            if (existing.isNotEmpty) ...existing,
            'doc_type': docType,
            'title': req['title'],
            'icon': req['icon'],
            'status': status,
          });
          continue;
        }

        final existing = docs.firstWhere(
          (d) => d['doc_type'] == docType,
          orElse: () => <String, dynamic>{},
        );

        if (existing.isNotEmpty) {
          merged.add({
            ...existing,
            'title': req['title'],
            'icon': req['icon'],
            'status': existing['status'] ?? 'pending',
          });
        } else {
          merged.add({
            'doc_type': docType,
            'title': req['title'],
            'icon': req['icon'],
            'status': isVerified ? 'approved' : 'not_uploaded',
          });
        }
      }
      // Onboarding items carry states the documents table cannot:
      // SSN lives encrypted on the user, and a license/photo that only
      // exists on the profile has no document row. They backstop any
      // item the merge above could only mark "not_uploaded".
      const obKeyByDocType = {
        'license_plate': 'plate',
        'drivers_license': 'license',
        'profile_photo': 'photo',
        'background_check': 'background',
      };
      for (final m in merged) {
        final obKey = obKeyByDocType[m['doc_type']];
        if (obKey == null) continue;
        if (m['status'] != 'not_uploaded') continue;
        final obStatus =
            (onboarding[obKey] as Map<String, dynamic>?)?['status']
                as String?;
        if (obStatus == 'approved' || obStatus == 'rejected') {
          m['status'] = obStatus;
        } else if (obStatus == 'submitted') {
          m['status'] = 'pending';
        }
      }

      // SSN — never a document, never shown. Presence is all the driver
      // gets to see.
      final ssnStatus =
          (onboarding['ssn'] as Map<String, dynamic>?)?['status'] as String?;
      if (ssnStatus != null && ssnStatus != 'pending') {
        merged.add({
          'doc_type': 'ssn',
          'status': ssnStatus == 'submitted' ? 'approved' : ssnStatus,
        });
      }

      // Inspection only applies where the state requires one; the row
      // appears when dispatch actually has one on file.
      final inspection = docs.firstWhere(
        (d) => d['doc_type'] == 'vehicle_inspection',
        orElse: () => <String, dynamic>{},
      );
      if (inspection.isNotEmpty) {
        merged.add({
          ...inspection,
          'doc_type': 'vehicle_inspection',
          'status': inspection['status'] ?? 'pending',
        });
      }

      setState(() {
        _documents = merged;
        _vehicleLabel = _describeVehicle(vehicle);
        _loading = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  /// "2013 Jeep Grand Cherokee (A0D044Y)", skipping whatever is missing.
  ///
  /// Empty when there is no car on file, which is the signal the header
  /// card uses to stay off the screen entirely rather than render a row
  /// of blanks.
  String _describeVehicle(Map<String, dynamic>? v) {
    if (v == null) return '';
    final parts = [
      (v['year'] ?? '').toString(),
      (v['make'] ?? '').toString(),
      (v['model'] ?? '').toString(),
    ].where((p) => p.trim().isNotEmpty).join(' ');
    final plate = (v['plate'] ?? '').toString().trim();
    if (parts.isEmpty) return plate;
    return plate.isEmpty ? parts : '$parts (${plate.toUpperCase()})';
  }

  /// Upload a new document photo (for expired or rejected docs)
  Future<void> _uploadDocument(String docType, String title) async {
    final source = await showModalBottomSheet<ImageSource>(
      context: context,
      backgroundColor: neuSurface,
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
                width: 40, height: 4,
                decoration: BoxDecoration(
                  color: Colors.white24,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(height: 20),
              Text('Upload $title',
                  style: const TextStyle(color: Colors.white, fontSize: 17, fontWeight: FontWeight.w800)),
              const SizedBox(height: 20),
              ListTile(
                leading: Container(
                  width: 44, height: 44,
                  decoration: BoxDecoration(color: _gold.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(12)),
                  child: const Icon(Icons.camera_alt_rounded, color: _gold, size: 22),
                ),
                title: Text(S.of(context).takePhoto, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
                subtitle: Text(S.of(context).takePhotoSubtitle,
                    style: TextStyle(color: Colors.white.withValues(alpha: 0.4), fontSize: 12)),
                onTap: () => Navigator.pop(ctx, ImageSource.camera),
              ),
              ListTile(
                leading: Container(
                  width: 44, height: 44,
                  decoration: BoxDecoration(color: _gold.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(12)),
                  child: const Icon(Icons.photo_library_rounded, color: _gold, size: 22),
                ),
                title: Text(S.of(context).chooseFromGallery, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
                subtitle: Text(S.of(context).chooseFromGallerySubtitle,
                    style: TextStyle(color: Colors.white.withValues(alpha: 0.4), fontSize: 12)),
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
      final xFile = await _picker.pickImage(source: source, maxWidth: 1280, maxHeight: 1280, imageQuality: 75);
      if (xFile == null || !mounted) return;

      setState(() => _uploading = true);
      await ApiService.uploadDocument(docType: docType, filePath: xFile.path).timeout(const Duration(seconds: 60));

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('$title uploaded — under review'),
          backgroundColor: const Color(0xFF4CAF50),
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        ),
      );
      await _fetchDocuments();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Failed to upload $title'),
          backgroundColor: Colors.red,
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        ),
      );
    } finally {
      if (mounted) setState(() => _uploading = false);
    }
  }

  IconData _iconForDoc(Map<String, dynamic> doc) {
    if (doc['icon'] != null && doc['icon'] is IconData) {
      return doc['icon'] as IconData;
    }
    switch (doc['doc_type']) {
      case 'drivers_license':
        return Icons.badge_rounded;
      case 'background_check':
        return Icons.verified_user_rounded;
      case 'profile_photo':
        return Icons.face_retouching_natural_rounded;
      case 'insurance':
        return Icons.shield_rounded;
      case 'registration':
        return Icons.description_rounded;
      default:
        return Icons.insert_drive_file_rounded;
    }
  }

  String _localizedDocTitle(String? docType, S s) {
    switch (docType) {
      case 'license_plate':
        return s.licensePlateNumber;
      case 'drivers_license':
        return s.driversLicenseTitle;
      case 'background_check':
        return s.backgroundCheckTitle;
      case 'profile_photo':
        return s.docsFaceBiometrics;
      case 'insurance':
        return s.docsCarInsurance;
      case 'registration':
        return s.docsCarRegistration;
      case 'vehicle_inspection':
        return s.docsVehicleInspectionTitle;
      case 'ssn':
        return s.obItemSsnTitle;
      default:
        return docType ?? 'Document';
    }
  }

  /// The only four records a driver may ever touch themselves.
  ///
  /// Everything else — background check, registration, the inspection
  /// form — is issued or verified by someone other than the driver, so
  /// the card is inert. A tap that does nothing is worse than a card
  /// that plainly cannot be tapped.
  static const _editableDocTypes = {
    'license_plate',
    'drivers_license',
    'profile_photo',
    'insurance',
  };

  /// Open the plate editor and reload if it actually changed anything.
  Future<void> _editPlate(Map<String, dynamic> doc) async {
    final changed = await Navigator.of(context).push<bool>(
      slideFromRightRoute(
        DriverLicensePlateScreen(
          currentPlate: (doc['plate'] ?? '').toString(),
          currentState: (doc['plate_state'] ?? '').toString().isEmpty
              ? null
              : (doc['plate_state'] ?? '').toString(),
        ),
      ),
    );
    if (!mounted) return;
    // Reload either way: even an unchanged save can have corrected the
    // state, and the registration row below may have just been rejected.
    await _fetchDocuments();
    if (changed == true && mounted) {
      setState(() => _submittedOpen = true);
    }
  }

  /// How early the update window opens, in days before expiry.
  ///
  /// Twenty, not zero: insurance and a licence have to be renewed while
  /// the old one is still valid. Waiting for the expiry to land means
  /// the driver is already offline by the time the app lets them fix it.
  static const _reuploadWindowDays = 20;

  /// Whether the card can be tapped at all.
  bool _isEditable(Map<String, dynamic> doc) =>
      _editableDocTypes.contains(doc['doc_type'] as String?);

  /// Whether the driver may replace this document right now.
  ///
  /// Editable type, and something to act on: never uploaded, rejected,
  /// expired, or inside the twenty-day window.
  ///
  /// The details sheet has to ask this too. It carries an "Update"
  /// button and was unreachable until this pass, so nothing was
  /// enforcing the rule there.
  bool _canReupload(Map<String, dynamic> doc) {
    if (!_isEditable(doc)) return false;
    final status = (doc['status'] ?? 'not_uploaded') as String;
    if (status == 'coming_soon') return false;
    if (status == 'not_uploaded' || status == 'rejected') return true;
    final expiry = (doc['expiry_date'] ?? doc['expiry'] ?? '') as String;
    if (expiry.isEmpty) return false;
    final dt = DateTime.tryParse(expiry);
    if (dt == null) return false;
    return dt.difference(DateTime.now()).inDays <= _reuploadWindowDays;
  }

  /// True when this document still asks something of the driver.
  ///
  /// Expiry counts: an approved insurance that lapses next week is not
  /// "done", however green it looked yesterday.
  bool _needsAction(Map<String, dynamic> doc) {
    final status = (doc['status'] ?? 'not_uploaded') as String;
    if (status == 'coming_soon') return false;
    if (status == 'not_uploaded' || status == 'rejected') return true;
    final expiry = (doc['expiry_date'] ?? doc['expiry'] ?? '') as String;
    return _checkExpiry(expiry) != _ExpiryStatus.ok;
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);

    // Action items first; everything else keeps its canonical order.
    final docs = [..._documents]
      ..sort((a, b) {
        final na = _needsAction(a) ? 0 : 1;
        final nb = _needsAction(b) ? 0 : 1;
        return na.compareTo(nb);
      });
    final approvedCount =
        docs.where((d) => d['status'] == 'approved').length;

    return Scaffold(
      backgroundColor: neuBase,
      body: Stack(
        children: [
          const Positioned.fill(child: NeuDotsBackdrop()),
          _loading
          ? const Center(
              child: CircularProgressIndicator(color: _gold, strokeWidth: 2),
            )
          : Stack(
              children: [
                SafeArea(
                  bottom: false,
                  child: ListView(
                    physics: const BouncingScrollPhysics(),
                    padding: const EdgeInsets.fromLTRB(20, 8, 20, 40),
                    children: [
                      _closeRow(s),
                      const SizedBox(height: 18),
                      _hero(s),
                      const SizedBox(height: 22),
                      if (_vehicleLabel.isNotEmpty) ...[
                        _vehicleCard(s),
                        const SizedBox(height: 22),
                      ],
                      if (docs.isNotEmpty)
                        _section(
                          title: s.docsSubmitted,
                          open: _submittedOpen,
                          onToggle: () =>
                              setState(() => _submittedOpen = !_submittedOpen),
                          chips: [
                            if (approvedCount > 0)
                              _countChip(
                                Icons.check_circle_rounded,
                                approvedCount,
                                const Color(0xFF4CAF50),
                              ),
                          ],
                          children: docs.map(_documentCard).toList(),
                        ),
                      const SizedBox(height: 20),
                      _lockedNote(s),
                    ],
                  ),
                ),
                if (_uploading)
                  Container(
                    color: Colors.black54,
                    child: Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const CircularProgressIndicator(
                              color: _gold, strokeWidth: 2),
                          const SizedBox(height: 16),
                          Text(
                            S.of(context).uploadingDocument,
                            style: const TextStyle(
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
        ],
      ),
    );
  }

  /// Illustration + greeting, Lyft-style. This page is read for pleasure
  /// ("you're done") far more often than for work, so it opens with the
  /// good news instead of a form label.
  Widget _hero(S s) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(20),
          child: Image.asset(
            'assets/images/onboarding/documents.jpg',
            width: double.infinity,
            height: 200,
            fit: BoxFit.cover,
          ),
        ),
        const SizedBox(height: 18),
        Text(
          s.docsAllSetTitle,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 22,
            fontWeight: FontWeight.w800,
            letterSpacing: -0.4,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          s.docsAllSetSubtitle,
          style: TextStyle(
            color: Colors.white.withValues(alpha: 0.5),
            fontSize: 14,
            fontWeight: FontWeight.w500,
          ),
        ),
      ],
    );
  }

  /// An X, not a back arrow. This screen is a stack the driver steps out
  /// of, and the reference reads it that way. The hero below carries the
  /// title, so the row stays bare.
  Widget _closeRow(S s) {
    return Row(
      children: [
        GestureDetector(
          onTap: () {
            HapticService.selectionClick();
            Navigator.pop(context);
          },
          child: Container(
            width: 42,
            height: 42,
            decoration: neuBox(radius: 14),
            child:
                const Icon(Icons.close_rounded, color: Colors.white, size: 21),
          ),
        ),
      ],
    );
  }

  /// Which car these documents belong to.
  ///
  /// Insurance, registration and the inspection form are all about one
  /// specific vehicle, and a driver with two of them has no other way to
  /// tell which list they are looking at.
  Widget _vehicleCard(S s) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 15),
      decoration: neuBox(radius: 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            s.primaryVehicle,
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.45),
              fontSize: 12.5,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            _vehicleLabel,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 16,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }

  /// A collapsible group. The header is always tappable; the body grows
  /// and shrinks rather than appearing, so nothing under the thumb jumps
  /// somewhere else between frames.
  Widget _section({
    required String title,
    required bool open,
    required VoidCallback onToggle,
    required List<Widget> chips,
    required List<Widget> children,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () {
            HapticService.selectionClick();
            onToggle();
          },
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 20,
                    fontWeight: FontWeight.w800,
                    letterSpacing: -0.4,
                  ),
                ),
                const SizedBox(width: 10),
                ...chips,
                const Spacer(),
                AnimatedRotation(
                  turns: open ? 0.5 : 0,
                  duration: const Duration(milliseconds: 240),
                  curve: Curves.easeOutCubic,
                  child: Icon(
                    Icons.keyboard_arrow_down_rounded,
                    color: Colors.white.withValues(alpha: 0.8),
                    size: 28,
                  ),
                ),
              ],
            ),
          ),
        ),
        AnimatedSize(
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeInOutCubic,
          alignment: Alignment.topCenter,
          child: open
              ? Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Column(children: children),
                )
              : const SizedBox(width: double.infinity),
        ),
      ],
    );
  }

  Widget _countChip(IconData icon, int count, Color tint) {
    return Padding(
      padding: const EdgeInsets.only(right: 7),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
        decoration: neuBox(radius: 11, pressed: true),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 13, color: tint),
            const SizedBox(width: 5),
            Text(
              '$count',
              style: TextStyle(
                color: tint,
                fontSize: 12.5,
                fontWeight: FontWeight.w800,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _lockedNote(S s) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
      decoration: neuBox(radius: 14, pressed: true),
      child: Row(
        children: [
          Icon(
            Icons.info_outline_rounded,
            color: Colors.white.withValues(alpha: 0.35),
            size: 18,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              s.documentsLockedNote,
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.4),
                fontSize: 12,
                height: 1.4,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Check if an expiry date is expired or expiring soon (within 30 days).
  _ExpiryStatus _checkExpiry(String expiryStr) {
    if (expiryStr.isEmpty) return _ExpiryStatus.ok;
    final dt = DateTime.tryParse(expiryStr);
    if (dt == null) return _ExpiryStatus.ok;
    final now = DateTime.now();
    if (dt.isBefore(now)) return _ExpiryStatus.expired;
    // Same twenty days the update window uses. It was thirty, which put
    // a card in "action needed", tinted it orange, and then refused the
    // tap for ten days — a warning the driver could not answer.
    if (dt.difference(now).inDays <= _reuploadWindowDays) {
      return _ExpiryStatus.expiringSoon;
    }
    return _ExpiryStatus.ok;
  }

  /// One document.
  ///
  /// The status is the circle on the left and nothing else — the old
  /// card said it three times over: a tinted icon, a coloured border and
  /// a pill on the right, all encoding the same word. The subtitle is
  /// free to say something the icon cannot, which is when it expires.
  Widget _documentCard(Map<String, dynamic> doc) {
    final s = S.of(context);
    final status = (doc['status'] ?? 'not_uploaded') as String;
    final isApproved = status == 'approved';
    final isPending = status == 'pending';
    final isNotUploaded = status == 'not_uploaded';
    final isRejected = status == 'rejected';
    final isComingSoon = status == 'coming_soon';
    final isDisabled = doc['disabled'] == true;

    final expiry = (doc['expiry_date'] ?? doc['expiry'] ?? '') as String;
    final createdAt = (doc['created_at'] ?? '') as String;
    final expiryStatus = _checkExpiry(expiry);

    // One decision, read once, used by both the circle and the subtitle.
    final Color tint;
    final IconData mark;
    if (isComingSoon) {
      tint = Colors.white.withValues(alpha: 0.3);
      mark = Icons.upcoming_rounded;
    } else if (isApproved && expiryStatus == _ExpiryStatus.expired) {
      tint = const Color(0xFFE05C5C);
      mark = Icons.priority_high_rounded;
    } else if (isApproved && expiryStatus == _ExpiryStatus.expiringSoon) {
      tint = const Color(0xFFE8A33D);
      mark = Icons.warning_amber_rounded;
    } else if (isApproved) {
      tint = const Color(0xFF4CAF50);
      mark = Icons.check_rounded;
    } else if (isPending) {
      tint = Colors.white.withValues(alpha: 0.55);
      mark = Icons.schedule_rounded;
    } else if (isRejected) {
      tint = const Color(0xFFE05C5C);
      mark = Icons.close_rounded;
    } else {
      tint = _gold;
      mark = Icons.arrow_upward_rounded;
    }

    final title = _localizedDocTitle(doc['doc_type'] as String?, s);

    final docType = doc['doc_type'] as String?;
    final canUpload = _canReupload(doc);
    // Only genuinely unavailable rows dim and go dead. Everything else —
    // including the read-only background check and the SSN receipt —
    // stays full-strength, because a completed document is the content
    // of this page, not a disabled control.
    final inert = isComingSoon || isDisabled;

    String subtitle;
    Color subtitleColor = Colors.white.withValues(alpha: 0.45);
    // The plate says what it is, not when it was uploaded. The SSN says
    // nothing at all — presence is the only thing on display.
    if (docType == 'ssn') {
      subtitle = s.docsOnFile;
    } else if (docType == 'license_plate') {
      final plate = (doc['plate'] ?? '').toString();
      final st = (doc['plate_state'] ?? '').toString();
      if (isPending) {
        subtitle = s.plateChangePendingTitle;
        subtitleColor = const Color(0xFFE8A33D);
      } else if (plate.isEmpty) {
        subtitle = s.notUploadedYet;
      } else {
        subtitle = st.isEmpty ? plate : '$plate · $st';
      }
    } else if (expiryStatus == _ExpiryStatus.expired) {
      subtitle = s.documentExpired;
      subtitleColor = const Color(0xFFE05C5C);
    } else if (expiryStatus == _ExpiryStatus.expiringSoon) {
      final dt = DateTime.tryParse(expiry);
      final days = dt == null ? 0 : dt.difference(DateTime.now()).inDays;
      subtitle = s.expiresInDays(days);
      subtitleColor = const Color(0xFFE8A33D);
    } else if (isRejected) {
      subtitle = s.documentNeedsUpdate;
      subtitleColor = const Color(0xFFE05C5C);
    } else if (isComingSoon) {
      subtitle = s.comingSoon;
    } else if (expiry.isNotEmpty) {
      subtitle = s.expiresDate(_formatShortDate(expiry));
    } else if (createdAt.isNotEmpty) {
      subtitle = '${s.uploadedLabel}: ${_formatShortDate(createdAt)}';
    } else if (isNotUploaded) {
      subtitle = s.notUploadedYet;
    } else if (isPending) {
      subtitle = s.pending;
    } else {
      subtitle = s.approved;
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: GestureDetector(
        // Tapping a document to see it is the whole point of a screen
        // called "view documents", so the tap goes there unless the card
        // is asking for a re-upload instead.
        onTap: inert
            ? null
            : () {
                HapticService.selectionClick();
                // The plate is a form, not a photo; the SSN has no
                // readable payload at all.
                if (docType == 'ssn') {
                  return;
                } else if (docType == 'license_plate') {
                  _editPlate(doc);
                } else if (canUpload) {
                  _uploadDocument(docType!, title);
                } else {
                  _showDocDetails(doc);
                }
              },
        child: Opacity(
          opacity: inert ? 0.45 : 1.0,
          child: Container(
            padding: const EdgeInsets.all(16),
            decoration: neuBox(radius: 18),
            child: Row(
              children: [
                Container(
                  width: 42,
                  height: 42,
                  decoration: neuBox(radius: 21, pressed: true),
                  child: Icon(mark, color: tint, size: 20),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 15.5,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        subtitle,
                        style: TextStyle(
                          color: subtitleColor,
                          fontSize: 12.5,
                          height: 1.35,
                        ),
                      ),
                    ],
                  ),
                ),
                if (canUpload)
                  Padding(
                    padding: const EdgeInsets.only(left: 8),
                    child: Icon(Icons.file_upload_outlined,
                        color: _gold, size: 20),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  String _formatShortDate(String raw) {
    final dt = DateTime.tryParse(raw);
    if (dt == null) return raw;
    const months = [
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
    ];
    return '${months[dt.month - 1]} ${dt.day}, ${dt.year}';
  }

  void _showDocDetails(Map<String, dynamic> doc) {
    final s = S.of(context);
    final icon = _iconForDoc(doc);
    final title = _localizedDocTitle(doc['doc_type'] as String?, s);
    final docType = doc['doc_type'] as String?;
    final docNumber = (doc['doc_number'] ?? '') as String;
    final expiry = (doc['expiry_date'] ?? doc['expiry'] ?? 'N/A') as String;
    final status = (doc['status'] ?? 'not_uploaded') as String;
    final createdAt = (doc['created_at'] ?? 'N/A') as String;
    
    // Special handling for background_check
    if (docType == 'background_check') {
      _showBackgroundCheckSheet(doc);
      return;
    }
    
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) {
        return Container(
          padding: const EdgeInsets.all(24),
          decoration: const BoxDecoration(
            color: neuSurface,
            borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.white12,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(height: 24),
              Container(
                width: 64,
                height: 64,
                decoration: BoxDecoration(
                  color: _gold.withValues(alpha: 0.12),
                  shape: BoxShape.circle,
                ),
                child: Icon(icon, color: _gold, size: 30),
              ),
              const SizedBox(height: 16),
              Text(
                title,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 20,
                  fontWeight: FontWeight.w900,
                ),
              ),
              const SizedBox(height: 20),
              if (docNumber.isNotEmpty)
                _detailRow(s.documentNumberLabel, docNumber),
              _detailRow(
                s.expiryDetailLabel,
                expiry.isNotEmpty ? expiry : 'N/A',
              ),
              _detailRow(
                s.uploadedLabel,
                createdAt != 'N/A' ? _formatShortDate(createdAt) : 'N/A',
              ),
              _detailRow(s.statusLabel, status.toUpperCase()),
              const SizedBox(height: 20),
              Row(
                children: [
                  if (_canReupload(doc)) ...[
                  Expanded(
                    child: SizedBox(
                      height: 52,
                      child: OutlinedButton.icon(
                        onPressed: () {
                          Navigator.pop(ctx);
                          _showUploadSheet(docType: doc['doc_type'] as String?);
                        },
                        icon: const Icon(Icons.refresh_rounded, size: 18),
                        label: FittedBox(
                          fit: BoxFit.scaleDown,
                          child: Text(
                            s.updateBtn,
                            style: const TextStyle(fontWeight: FontWeight.w700),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: _gold,
                          side: BorderSide(color: _gold.withValues(alpha: 0.3)),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(14),
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  ],
                  Expanded(
                    child: SizedBox(
                      height: 52,
                      child: ElevatedButton(
                        onPressed: () => Navigator.pop(ctx),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: _gold,
                          foregroundColor: Colors.black,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(14),
                          ),
                        ),
                        child: FittedBox(
                          fit: BoxFit.scaleDown,
                          child: Text(
                            s.close,
                            style: const TextStyle(fontWeight: FontWeight.w800),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    );
  }

  Widget _detailRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            label,
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.4),
              fontSize: 14,
            ),
          ),
          Text(
            value,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 14,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }

  // ── Background Check special sheet ──
  void _showBackgroundCheckSheet(Map<String, dynamic> doc) {
    final s = S.of(context);
    final status = (doc['status'] ?? 'not_uploaded') as String;
    final isApproved = status == 'approved';
    final isPending = status == 'pending';
    final isNotStarted = status == 'not_uploaded';
    
    String statusText;
    Color statusColor;
    IconData statusIcon;
    String description;
    
    if (isApproved) {
      statusText = s.approved;
      statusColor = const Color(0xFF4CAF50);
      statusIcon = Icons.verified_user_rounded;
      description = 'Your background check has been approved. You\'re all set to drive!';
    } else if (isPending) {
      statusText = 'In Progress';
      statusColor = _gold;
      statusIcon = Icons.hourglass_top_rounded;
      description = 'Your background check is being processed. This typically takes 2-5 business days. We\'ll notify you when it\'s complete.';
    } else {
      statusText = 'Not Started';
      statusColor = Colors.white.withValues(alpha: 0.4);
      statusIcon = Icons.privacy_tip_rounded;
      description = 'A background check is required before you can start driving. Tap below to initiate your Checkr background check.';
    }
    
    final loadingNotifier = ValueNotifier<bool>(false);
    
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (ctx) {
        return ValueListenableBuilder<bool>(
          valueListenable: loadingNotifier,
          builder: (ctx, isLoading, _) {
            return Container(
              padding: const EdgeInsets.all(24),
              decoration: const BoxDecoration(
                color: neuSurface,
                borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 36,
                    height: 4,
                    decoration: BoxDecoration(
                      color: Colors.white12,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                  const SizedBox(height: 24),
                  Container(
                    width: 72,
                    height: 72,
                    decoration: BoxDecoration(
                      color: statusColor.withValues(alpha: 0.12),
                      shape: BoxShape.circle,
                    ),
                    child: Icon(statusIcon, color: statusColor, size: 34),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    s.backgroundCheckTitle,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 22,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                    decoration: BoxDecoration(
                      color: statusColor.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Text(
                      statusText,
                      style: TextStyle(
                        color: statusColor,
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  const SizedBox(height: 20),
                  Text(
                    description,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.7),
                      fontSize: 14,
                      height: 1.5,
                    ),
                  ),
                  const SizedBox(height: 24),
                  if (isNotStarted) ...[
                    // Info box about Checkr
                    Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: _gold.withValues(alpha: 0.08),
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(color: _gold.withValues(alpha: 0.2)),
                      ),
                      child: Row(
                        children: [
                          Icon(Icons.info_outline, color: _gold, size: 20),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Text(
                              'Powered by Checkr. You\'ll receive an email invitation to complete the check.',
                              style: TextStyle(
                                color: Colors.white.withValues(alpha: 0.8),
                                fontSize: 12,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 20),
                    SizedBox(
                      width: double.infinity,
                      height: 54,
                      child: ElevatedButton.icon(
                        onPressed: isLoading ? null : () async {
                          Navigator.pop(ctx);
                          final result = await Navigator.push<Map<String, dynamic>>(
                            context,
                            slideFromRightRoute<Map<String, dynamic>>(const BackgroundCheckConsentScreen()),
                          );
                          if (result != null) {
                            if (!mounted) return;
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Text(S.of(context).backgroundCheckInitiated),
                                backgroundColor: _gold,
                                behavior: SnackBarBehavior.floating,
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                              ),
                            );
                            _fetchDocuments(); // Refresh status
                          }
                        },
                        icon: isLoading 
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(
                                color: Colors.black,
                                strokeWidth: 2,
                              ),
                            )
                          : const Icon(Icons.play_arrow_rounded, size: 22),
                        label: Text(
                          isLoading ? 'Starting...' : 'Start Background Check',
                          style: const TextStyle(
                            fontWeight: FontWeight.w800,
                            fontSize: 16,
                          ),
                        ),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: _gold,
                          foregroundColor: Colors.black,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(16),
                          ),
                        ),
                      ),
                    ),
                  ] else ...[
                    SizedBox(
                      width: double.infinity,
                      height: 52,
                      child: ElevatedButton(
                        onPressed: () => Navigator.pop(ctx),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: _gold,
                          foregroundColor: Colors.black,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(16),
                          ),
                        ),
                        child: Text(
                          s.close,
                          style: const TextStyle(fontWeight: FontWeight.w800),
                        ),
                      ),
                    ),
                  ],
                  const SizedBox(height: 8),
                ],
              ),
            );
          },
        );
      },
    );
  }

  void _showUploadSheet({String? docType}) {
    final picker = ImagePicker();
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) {
        return Container(
          padding: const EdgeInsets.all(24),
          decoration: const BoxDecoration(
            color: neuSurface,
            borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.white12,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(height: 24),
              Builder(
                builder: (ctx2) {
                  final s2 = S.of(ctx2);
                  return Text(
                    s2.uploadDocument,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 20,
                      fontWeight: FontWeight.w900,
                    ),
                  );
                },
              ),
              const SizedBox(height: 24),
              _uploadOption(
                ctx,
                Icons.camera_alt_rounded,
                S.of(ctx).takePhoto,
                S.of(ctx).useYourCamera,
                () async {
                  Navigator.pop(ctx);
                  final img = await picker.pickImage(
                    source: ImageSource.camera,
                    imageQuality: 80,
                  );
                  if (img != null) _uploadFile(img.path, docType ?? 'other');
                },
              ),
              const SizedBox(height: 12),
              _uploadOption(
                ctx,
                Icons.photo_library_rounded,
                S.of(ctx).chooseFromGallery,
                S.of(ctx).selectFromPhotos,
                () async {
                  Navigator.pop(ctx);
                  final img = await picker.pickImage(
                    source: ImageSource.gallery,
                    imageQuality: 80,
                  );
                  if (img != null) _uploadFile(img.path, docType ?? 'other');
                },
              ),
              const SizedBox(height: 20),
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: Text(
                  S.of(ctx).cancel,
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.4),
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _uploadFile(String path, String docType) async {
    HapticService.mediumImpact();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(S.of(context).uploadingDocument),
        backgroundColor: _gold,
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 2),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    );
    try {
      // Upload to Firebase Storage for permanent URL visible in Dispatch
      try {
        final me = await ApiService.getMe().timeout(const Duration(seconds: 15));
        final userId = int.tryParse(me?['id']?.toString() ?? '') ?? 0;
        final url = await FirebaseStorageService.uploadDocumentPhoto(
          path,
          userId,
          docType,
        );
        await FirebaseStorageService.saveVerificationPhoto(userId, docType, url);
      } catch (e) {
        debugPrint('[Documents] Firebase Storage upload failed: $e');
      }

      final bytes = await File(path).readAsBytes();
      final base64Photo = base64Encode(bytes);
      await ApiService.uploadDocument(
        docType: docType,
        photoBase64: base64Photo,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(S.of(context).documentUploadedSuccessfully),
          backgroundColor: _gold,
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
      );
      _fetchDocuments();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(S.of(context).uploadFailed(e.toString())),
          backgroundColor: Colors.red,
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  Widget _uploadOption(
    BuildContext ctx,
    IconData icon,
    String title,
    String subtitle,
    VoidCallback onTap,
  ) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.04),
        borderRadius: BorderRadius.circular(16),
      ),
      child: ListTile(
        onTap: onTap,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        leading: Container(
          width: 44,
          height: 44,
          decoration: BoxDecoration(
            color: _gold.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(13),
          ),
          child: Icon(icon, color: _gold, size: 22),
        ),
        title: Text(
          title,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 15,
            fontWeight: FontWeight.w700,
          ),
        ),
        subtitle: Text(
          subtitle,
          style: TextStyle(
            color: Colors.white.withValues(alpha: 0.35),
            fontSize: 12,
          ),
        ),
        trailing: Icon(
          Icons.chevron_right_rounded,
          color: Colors.white.withValues(alpha: 0.15),
        ),
      ),
    );
  }
}
