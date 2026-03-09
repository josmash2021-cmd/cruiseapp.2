import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../../config/page_transitions.dart';
import '../../l10n/app_localizations.dart';
import '../../services/api_service.dart';
import 'driver_home_screen.dart';

/// After approval, the driver must upload a profile photo before entering the app.
class DriverProfilePhotoScreen extends StatefulWidget {
  /// When true, pops back with the photo URL instead of navigating to home.
  final bool returnOnly;
  const DriverProfilePhotoScreen({super.key, this.returnOnly = false});

  @override
  State<DriverProfilePhotoScreen> createState() =>
      _DriverProfilePhotoScreenState();
}

class _DriverProfilePhotoScreenState extends State<DriverProfilePhotoScreen> {
  static const _gold = Color(0xFFE8C547);

  String? _photoPath;
  bool _uploading = false;

  Future<void> _pickPhoto(ImageSource source) async {
    final picker = ImagePicker();
    final xf = await picker.pickImage(
      source: source,
      maxWidth: 800,
      maxHeight: 800,
      imageQuality: 85,
    );
    if (xf != null && mounted) {
      setState(() => _photoPath = xf.path);
    }
  }

  void _showPickOptions() {
    final s = S.of(context);
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1A1A1A),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 20, horizontal: 24),
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
              ListTile(
                leading: const Icon(Icons.camera_alt_rounded, color: _gold),
                title: Text(
                  s.takePhoto,
                  style: const TextStyle(color: Colors.white),
                ),
                onTap: () {
                  Navigator.pop(context);
                  _pickPhoto(ImageSource.camera);
                },
              ),
              ListTile(
                leading: const Icon(Icons.photo_library_rounded, color: _gold),
                title: Text(
                  s.chooseFromGallery,
                  style: const TextStyle(color: Colors.white),
                ),
                onTap: () {
                  Navigator.pop(context);
                  _pickPhoto(ImageSource.gallery);
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _upload() async {
    if (_photoPath == null) return;
    setState(() => _uploading = true);
    try {
      final photoUrl = await ApiService.uploadPhoto(_photoPath!);
      await ApiService.updateMe({'photo_url': photoUrl});
      if (!mounted) return;
      if (widget.returnOnly) {
        Navigator.of(context).pop(photoUrl);
        return;
      }
      Navigator.of(context).pushAndRemoveUntil(
        slideFromRightRoute(const DriverHomeScreen()),
        (_) => false,
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _uploading = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(S.of(context).uploadFailed(e.toString())),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    return PopScope(
      canPop: widget.returnOnly,
      child: Scaffold(
        backgroundColor: Colors.black,
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 28),
            child: Column(
              children: [
                const Spacer(flex: 2),

                // Title
                Text(
                  s.uploadProfilePhoto,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 26,
                    fontWeight: FontWeight.w800,
                    letterSpacing: -0.5,
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  s.profilePhotoInstructions,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.55),
                    fontSize: 15,
                    height: 1.5,
                  ),
                ),

                const SizedBox(height: 40),

                // Photo circle
                GestureDetector(
                  onTap: _uploading ? null : _showPickOptions,
                  child: Container(
                    width: 160,
                    height: 160,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: Colors.white.withValues(alpha: 0.06),
                      border: Border.all(
                        color: _photoPath != null
                            ? _gold.withValues(alpha: 0.6)
                            : Colors.white.withValues(alpha: 0.15),
                        width: 2.5,
                      ),
                      image: _photoPath != null
                          ? DecorationImage(
                              image: FileImage(File(_photoPath!)),
                              fit: BoxFit.cover,
                            )
                          : null,
                    ),
                    child: _photoPath == null
                        ? Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(
                                Icons.camera_alt_rounded,
                                color: Colors.white.withValues(alpha: 0.3),
                                size: 44,
                              ),
                              const SizedBox(height: 8),
                              Text(
                                s.tapToAdd,
                                style: TextStyle(
                                  color: Colors.white.withValues(alpha: 0.3),
                                  fontSize: 13,
                                ),
                              ),
                            ],
                          )
                        : null,
                  ),
                ),

                if (_photoPath != null) ...[
                  const SizedBox(height: 16),
                  TextButton(
                    onPressed: _uploading ? null : _showPickOptions,
                    child: Text(
                      s.changePhoto,
                      style: TextStyle(
                        color: _gold.withValues(alpha: 0.8),
                        fontSize: 14,
                      ),
                    ),
                  ),
                ],

                const Spacer(flex: 3),

                // Continue button
                SizedBox(
                  width: double.infinity,
                  height: 56,
                  child: ElevatedButton(
                    onPressed: _photoPath != null && !_uploading
                        ? _upload
                        : null,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: _gold,
                      foregroundColor: Colors.black,
                      disabledBackgroundColor: _gold.withValues(alpha: 0.3),
                      disabledForegroundColor: Colors.black38,
                      elevation: 4,
                      shadowColor: _gold.withValues(alpha: 0.4),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(18),
                      ),
                    ),
                    child: _uploading
                        ? const SizedBox(
                            width: 22,
                            height: 22,
                            child: CircularProgressIndicator(
                              strokeWidth: 2.5,
                              color: Colors.black54,
                            ),
                          )
                        : Text(
                            s.continueButton,
                            style: TextStyle(
                              fontSize: 17,
                              fontWeight: FontWeight.w800,
                              letterSpacing: 0.3,
                            ),
                          ),
                  ),
                ),

                const SizedBox(height: 32),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
