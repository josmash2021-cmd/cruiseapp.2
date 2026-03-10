import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import '../../services/api_service.dart';
import '../../config/driver_colors.dart';
import '../../l10n/app_localizations.dart';

enum _ExpiryStatus { ok, expiringSoon, expired }

/// Document management screen – driver's license, insurance, registration.
class DriverDocumentsScreen extends StatefulWidget {
  const DriverDocumentsScreen({super.key});

  @override
  State<DriverDocumentsScreen> createState() => _DriverDocumentsScreenState();
}

class _DriverDocumentsScreenState extends State<DriverDocumentsScreen> {
  static const _gold = Color(0xFFE8C547);
  static const _card = Color(0xFF1C1C1E);
  static const _surface = Color(0xFF141414);

  bool _loading = true;
  List<Map<String, dynamic>> _documents = [];

  // Required doc types that we always show
  static const _requiredDocs = [
    {
      'doc_type': 'drivers_license',
      'title': "Driver's License",
      'icon': Icons.badge_rounded,
    },
    {
      'doc_type': 'insurance',
      'title': 'Vehicle Insurance',
      'icon': Icons.security_rounded,
    },
    {
      'doc_type': 'registration',
      'title': 'Vehicle Registration',
      'icon': Icons.description_rounded,
    },
    {
      'doc_type': 'background_check',
      'title': 'Background Check',
      'icon': Icons.verified_user_rounded,
    },
    {
      'doc_type': 'profile_photo',
      'title': 'Profile Photo',
      'icon': Icons.camera_alt_rounded,
    },
    {
      'doc_type': 'vehicle_photos',
      'title': 'Vehicle Photos',
      'icon': Icons.photo_library_rounded,
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
      final docs = await ApiService.getDocuments();
      if (!mounted) return;
      // Merge with required doc types — drivers upload everything during
      // registration, so default to 'approved' for any missing document.
      final merged = <Map<String, dynamic>>[];
      for (final req in _requiredDocs) {
        final existing = docs.firstWhere(
          (d) => d['doc_type'] == req['doc_type'],
          orElse: () => <String, dynamic>{},
        );
        if (existing.isNotEmpty) {
          merged.add({
            ...existing,
            'title': req['title'],
            'icon': req['icon'],
            'status': existing['status'] ?? 'approved',
          });
        } else {
          merged.add({
            'doc_type': req['doc_type'],
            'title': req['title'],
            'icon': req['icon'],
            'status': 'approved',
          });
        }
      }
      setState(() {
        _documents = merged;
        _loading = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  IconData _iconForDoc(Map<String, dynamic> doc) {
    if (doc['icon'] != null && doc['icon'] is IconData) {
      return doc['icon'] as IconData;
    }
    switch (doc['doc_type']) {
      case 'drivers_license':
        return Icons.badge_rounded;
      case 'insurance':
        return Icons.security_rounded;
      case 'registration':
        return Icons.description_rounded;
      case 'background_check':
        return Icons.verified_user_rounded;
      case 'profile_photo':
        return Icons.camera_alt_rounded;
      case 'vehicle_photos':
        return Icons.photo_library_rounded;
      default:
        return Icons.insert_drive_file_rounded;
    }
  }

  String _localizedDocTitle(String? docType, S s) {
    switch (docType) {
      case 'drivers_license':
        return s.driversLicenseTitle;
      case 'insurance':
        return s.vehicleInsuranceTitle;
      case 'registration':
        return s.vehicleRegistrationTitle;
      case 'background_check':
        return s.backgroundCheckTitle;
      case 'profile_photo':
        return s.profilePhotoTitle;
      case 'vehicle_photos':
        return s.vehiclePhotosTitle;
      default:
        return docType ?? 'Document';
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final approvedCount = _documents
        .where((d) => d['status'] == 'approved')
        .length;
    final total = _documents.length;
    final progress = total > 0 ? approvedCount / total : 0.0;
    final allComplete = approvedCount == total && total > 0;

    // Check for expiry issues
    final expiryIssues = _documents.where((d) {
      final expiry = (d['expiry_date'] ?? d['expiry'] ?? '') as String;
      final st = _checkExpiry(expiry);
      return d['status'] == 'approved' &&
          (st == _ExpiryStatus.expired || st == _ExpiryStatus.expiringSoon);
    }).length;
    final rejectedCount = _documents
        .where((d) => d['status'] == 'rejected')
        .length;
    final needsAttention = expiryIssues + rejectedCount;

    final dc = DriverColors.of(context);
    return Scaffold(
      backgroundColor: dc.bg,
      body: _loading
          ? const Center(
              child: CircularProgressIndicator(color: _gold, strokeWidth: 2),
            )
          : CustomScrollView(
              physics: const BouncingScrollPhysics(),
              slivers: [
                SliverAppBar(
                  backgroundColor: dc.surface,
                  pinned: true,
                  expandedHeight: 110,
                  leading: IconButton(
                    icon: Container(
                      width: 38,
                      height: 38,
                      decoration: BoxDecoration(
                        color: dc.glassBg,
                        shape: BoxShape.circle,
                      ),
                      child: Icon(
                        Icons.arrow_back_rounded,
                        color: dc.text,
                        size: 20,
                      ),
                    ),
                    onPressed: () => Navigator.pop(context),
                  ),
                  flexibleSpace: FlexibleSpaceBar(
                    titlePadding: const EdgeInsets.only(left: 56, bottom: 16),
                    title: Text(
                      s.documentsTitle,
                      style: TextStyle(
                        color: dc.text,
                        fontSize: 20,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  ),
                ),

                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.all(20),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // ── Progress card ──
                        Container(
                          padding: const EdgeInsets.all(20),
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              colors: allComplete && needsAttention == 0
                                  ? [
                                      const Color(
                                        0xFF4CAF50,
                                      ).withValues(alpha: 0.15),
                                      Colors.transparent,
                                    ]
                                  : needsAttention > 0
                                  ? [
                                      Colors.orange.withValues(alpha: 0.12),
                                      Colors.transparent,
                                    ]
                                  : [
                                      _gold.withValues(alpha: 0.15),
                                      Colors.transparent,
                                    ],
                              begin: Alignment.topLeft,
                              end: Alignment.bottomRight,
                            ),
                            borderRadius: BorderRadius.circular(22),
                            border: Border.all(
                              color: allComplete && needsAttention == 0
                                  ? const Color(
                                      0xFF4CAF50,
                                    ).withValues(alpha: 0.3)
                                  : needsAttention > 0
                                  ? Colors.orange.withValues(alpha: 0.25)
                                  : _gold.withValues(alpha: 0.2),
                            ),
                          ),
                          child: Column(
                            children: [
                              Row(
                                children: [
                                  if (allComplete && needsAttention == 0)
                                    Container(
                                      width: 56,
                                      height: 56,
                                      decoration: BoxDecoration(
                                        color: const Color(
                                          0xFF4CAF50,
                                        ).withValues(alpha: 0.15),
                                        shape: BoxShape.circle,
                                      ),
                                      child: const Icon(
                                        Icons.check_circle_rounded,
                                        color: Color(0xFF4CAF50),
                                        size: 32,
                                      ),
                                    )
                                  else
                                    SizedBox(
                                      width: 56,
                                      height: 56,
                                      child: Stack(
                                        alignment: Alignment.center,
                                        children: [
                                          SizedBox(
                                            width: 56,
                                            height: 56,
                                            child: CircularProgressIndicator(
                                              value: progress,
                                              backgroundColor: Colors.white
                                                  .withValues(alpha: 0.06),
                                              valueColor:
                                                  AlwaysStoppedAnimation<Color>(
                                                    needsAttention > 0
                                                        ? Colors.orange
                                                        : _gold,
                                                  ),
                                              strokeWidth: 4,
                                            ),
                                          ),
                                          Text(
                                            '${(progress * 100).toInt()}%',
                                            style: TextStyle(
                                              color: needsAttention > 0
                                                  ? Colors.orange
                                                  : _gold,
                                              fontSize: 14,
                                              fontWeight: FontWeight.w800,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  const SizedBox(width: 18),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          allComplete && needsAttention == 0
                                              ? s.allDocumentsComplete
                                              : s.documentStatus,
                                          style: TextStyle(
                                            color:
                                                allComplete &&
                                                    needsAttention == 0
                                                ? const Color(0xFF4CAF50)
                                                : Colors.white,
                                            fontSize: 17,
                                            fontWeight: FontWeight.w800,
                                          ),
                                        ),
                                        const SizedBox(height: 4),
                                        Text(
                                          needsAttention > 0
                                              ? s.documentNeedsUpdate
                                              : s.docsApproved(
                                                  approvedCount,
                                                  total,
                                                ),
                                          style: TextStyle(
                                            color: needsAttention > 0
                                                ? Colors.orange.withValues(
                                                    alpha: 0.7,
                                                  )
                                                : Colors.white.withValues(
                                                    alpha: 0.4,
                                                  ),
                                            fontSize: 13,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 24),

                        // ── Document list ──
                        ..._documents.map((doc) => _documentCard(doc)),
                        const SizedBox(height: 24),

                        // ── Upload new ──
                        SizedBox(
                          width: double.infinity,
                          height: 56,
                          child: OutlinedButton.icon(
                            onPressed: () {
                              HapticFeedback.mediumImpact();
                              _showUploadSheet();
                            },
                            icon: const Icon(
                              Icons.upload_file_rounded,
                              size: 20,
                            ),
                            label: const Text(
                              'Upload New Document',
                              style: TextStyle(
                                fontSize: 15,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            style: OutlinedButton.styleFrom(
                              foregroundColor: _gold,
                              side: BorderSide(
                                color: _gold.withValues(alpha: 0.3),
                              ),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(16),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(height: 30),
                      ],
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
    if (dt.difference(now).inDays <= 30) return _ExpiryStatus.expiringSoon;
    return _ExpiryStatus.ok;
  }

  Widget _documentCard(Map<String, dynamic> doc) {
    final s = S.of(context);
    final status = (doc['status'] ?? 'not_uploaded') as String;
    final isApproved = status == 'approved';
    final isPending = status == 'pending';
    final isNotUploaded = status == 'not_uploaded';
    final isRejected = status == 'rejected';

    final expiry = (doc['expiry_date'] ?? doc['expiry'] ?? '') as String;
    final createdAt = (doc['created_at'] ?? '') as String;
    final expiryStatus = _checkExpiry(expiry);

    // Determine status display
    Color statusColor;
    String statusText;
    IconData statusIcon;
    if (isApproved && expiryStatus == _ExpiryStatus.expired) {
      statusColor = Colors.red.shade400;
      statusText = s.documentExpired;
      statusIcon = Icons.error_rounded;
    } else if (isApproved && expiryStatus == _ExpiryStatus.expiringSoon) {
      statusColor = Colors.orange.shade400;
      statusText = s.documentExpiringSoon;
      statusIcon = Icons.warning_amber_rounded;
    } else if (isApproved) {
      statusColor = const Color(0xFF4CAF50);
      statusText = s.approved;
      statusIcon = Icons.check_circle_rounded;
    } else if (isPending) {
      statusColor = const Color(0xFFF5D990);
      statusText = s.pending;
      statusIcon = Icons.schedule_rounded;
    } else if (isRejected) {
      statusColor = Colors.red.shade400;
      statusText = s.documentNeedsUpdate;
      statusIcon = Icons.cancel_rounded;
    } else {
      statusColor = Colors.white.withValues(alpha: 0.3);
      statusText = s.uploadBtn;
      statusIcon = Icons.upload_rounded;
    }

    final icon = _iconForDoc(doc);
    final title = _localizedDocTitle(doc['doc_type'] as String?, s);

    // Determine the left icon background and color
    final iconBg = isApproved && expiryStatus == _ExpiryStatus.ok
        ? const Color(0xFF4CAF50).withValues(alpha: 0.12)
        : isApproved && expiryStatus == _ExpiryStatus.expiringSoon
        ? Colors.orange.withValues(alpha: 0.12)
        : isApproved && expiryStatus == _ExpiryStatus.expired
        ? Colors.red.withValues(alpha: 0.12)
        : isRejected
        ? Colors.red.withValues(alpha: 0.1)
        : _gold.withValues(alpha: 0.1);
    final iconColor = isApproved && expiryStatus == _ExpiryStatus.ok
        ? const Color(0xFF4CAF50)
        : isApproved && expiryStatus == _ExpiryStatus.expiringSoon
        ? Colors.orange.shade400
        : isApproved && expiryStatus == _ExpiryStatus.expired
        ? Colors.red.shade400
        : isRejected
        ? Colors.red.shade400
        : _gold;

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: _card,
        borderRadius: BorderRadius.circular(18),
        border: expiryStatus == _ExpiryStatus.expired
            ? Border.all(color: Colors.red.withValues(alpha: 0.3))
            : expiryStatus == _ExpiryStatus.expiringSoon
            ? Border.all(color: Colors.orange.withValues(alpha: 0.2))
            : null,
      ),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(18),
        child: InkWell(
          borderRadius: BorderRadius.circular(18),
          onTap: () => _showDocDetails(doc),
          child: Padding(
            padding: const EdgeInsets.all(18),
            child: Row(
              children: [
                Container(
                  width: 46,
                  height: 46,
                  decoration: BoxDecoration(
                    color: iconBg,
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Icon(icon, color: iconColor, size: 22),
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
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 4),
                      if (expiryStatus == _ExpiryStatus.expired)
                        Text(
                          s.documentExpired,
                          style: TextStyle(
                            color: Colors.red.shade300,
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                          ),
                        )
                      else if (expiryStatus == _ExpiryStatus.expiringSoon)
                        Builder(
                          builder: (_) {
                            final dt = DateTime.parse(expiry);
                            final days = dt.difference(DateTime.now()).inDays;
                            return Text(
                              s.expiresInDays(days),
                              style: TextStyle(
                                color: Colors.orange.shade300,
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                              ),
                            );
                          },
                        )
                      else if (expiry.isNotEmpty)
                        Text(
                          s.expiresDate(_formatShortDate(expiry)),
                          style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.35),
                            fontSize: 12,
                          ),
                        )
                      else if (createdAt.isNotEmpty)
                        Text(
                          '${s.uploadedLabel}: ${_formatShortDate(createdAt)}',
                          style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.35),
                            fontSize: 12,
                          ),
                        )
                      else
                        Text(
                          isNotUploaded ? s.notUploadedYet : '',
                          style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.35),
                            fontSize: 12,
                          ),
                        ),
                    ],
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 5,
                  ),
                  decoration: BoxDecoration(
                    color: statusColor.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(statusIcon, size: 13, color: statusColor),
                      const SizedBox(width: 4),
                      Text(
                        statusText,
                        style: TextStyle(
                          color: statusColor,
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
    final docNumber = (doc['doc_number'] ?? '') as String;
    final expiry = (doc['expiry_date'] ?? doc['expiry'] ?? 'N/A') as String;
    final status = (doc['status'] ?? 'not_uploaded') as String;
    final createdAt = (doc['created_at'] ?? 'N/A') as String;
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) {
        return Container(
          padding: const EdgeInsets.all(24),
          decoration: const BoxDecoration(
            color: _card,
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
                  Expanded(
                    child: SizedBox(
                      height: 52,
                      child: OutlinedButton.icon(
                        onPressed: () {
                          Navigator.pop(ctx);
                          _showUploadSheet(docType: doc['doc_type'] as String?);
                        },
                        icon: const Icon(Icons.refresh_rounded, size: 18),
                        label: Text(
                          s.updateBtn,
                          style: const TextStyle(fontWeight: FontWeight.w700),
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
                        child: Text(
                          s.close,
                          style: const TextStyle(fontWeight: FontWeight.w800),
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

  void _showUploadSheet({String? docType}) {
    final picker = ImagePicker();
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) {
        return Container(
          padding: const EdgeInsets.all(24),
          decoration: const BoxDecoration(
            color: _card,
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
    HapticFeedback.mediumImpact();
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
          content: Text('Upload failed: $e'),
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
