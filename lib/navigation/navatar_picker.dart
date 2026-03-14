import 'dart:typed_data';

import 'package:flutter/material.dart';

import 'navatar_loader.dart';

/// Bottom-sheet picker for selecting a navigation car (Navatar).
///
/// Shows all 6 car models with preview images and names.
/// The selected model is stored in [NavatarLoader.current].
///
/// Usage:
/// ```dart
/// final selected = await NavatarPicker.show(context);
/// if (selected != null) { /* user picked a car */ }
/// ```
class NavatarPicker extends StatefulWidget {
  const NavatarPicker({super.key});

  /// Shows the picker as a modal bottom sheet. Returns the selected model
  /// or null if dismissed.
  static Future<NavatarModel?> show(BuildContext context) {
    return showModalBottomSheet<NavatarModel>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (_) => const NavatarPicker(),
    );
  }

  @override
  State<NavatarPicker> createState() => _NavatarPickerState();
}

class _NavatarPickerState extends State<NavatarPicker> {
  NavatarModel _selected = NavatarLoader.current;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _preload();
  }

  Future<void> _preload() async {
    await NavatarLoader.preloadAll();
    if (mounted) setState(() => _loading = false);
  }

  @override
  Widget build(BuildContext context) {
    final bottomPad = MediaQuery.of(context).padding.bottom;

    return Container(
      decoration: const BoxDecoration(
        color: Color(0xFF1A1A2E),
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      padding: EdgeInsets.fromLTRB(16, 8, 16, 16 + bottomPad),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Handle bar
          Container(
            width: 40,
            height: 4,
            margin: const EdgeInsets.only(bottom: 16),
            decoration: BoxDecoration(
              color: Colors.white24,
              borderRadius: BorderRadius.circular(2),
            ),
          ),

          // Title
          const Text(
            'Choose your car',
            style: TextStyle(
              color: Colors.white,
              fontSize: 18,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 4),
          const Text(
            'Pick a navigation icon for your trips',
            style: TextStyle(color: Colors.white38, fontSize: 13),
          ),
          const SizedBox(height: 20),

          // Car grid
          if (_loading)
            const Padding(
              padding: EdgeInsets.all(32),
              child: CircularProgressIndicator(color: Color(0xFF4285F4)),
            )
          else
            GridView.count(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              crossAxisCount: 3,
              mainAxisSpacing: 12,
              crossAxisSpacing: 12,
              childAspectRatio: 0.85,
              children: NavatarModel.values
                  .map((model) => _CarCard(
                        model: model,
                        isSelected: model == _selected,
                        onTap: () => setState(() => _selected = model),
                      ))
                  .toList(),
            ),

          const SizedBox(height: 20),

          // Confirm button
          SizedBox(
            width: double.infinity,
            height: 48,
            child: ElevatedButton(
              onPressed: () {
                NavatarLoader.current = _selected;
                Navigator.of(context).pop(_selected);
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF4285F4),
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              child: const Text(
                'Confirm',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _CarCard extends StatelessWidget {
  final NavatarModel model;
  final bool isSelected;
  final VoidCallback onTap;

  const _CarCard({
    required this.model,
    required this.isSelected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final previewBytes = NavatarLoader.previewBytes(model);

    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        decoration: BoxDecoration(
          color: isSelected
              ? const Color(0xFF1A2A4A)
              : const Color(0xFF111122),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: isSelected
                ? const Color(0xFF4285F4)
                : const Color(0xFF333344),
            width: isSelected ? 2 : 1,
          ),
        ),
        padding: const EdgeInsets.all(8),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            // Car preview image
            Expanded(
              child: previewBytes != null
                  ? Image.memory(
                      previewBytes,
                      fit: BoxFit.contain,
                      filterQuality: FilterQuality.high,
                    )
                  : Icon(
                      model.icon,
                      size: 40,
                      color: isSelected
                          ? const Color(0xFF4285F4)
                          : Colors.white38,
                    ),
            ),
            const SizedBox(height: 4),
            // Car name
            Text(
              model.displayName,
              style: TextStyle(
                color: isSelected ? const Color(0xFF4285F4) : Colors.white54,
                fontSize: 11,
                fontWeight: isSelected ? FontWeight.w600 : FontWeight.w400,
              ),
              textAlign: TextAlign.center,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            // Checkmark
            if (isSelected)
              const Padding(
                padding: EdgeInsets.only(top: 2),
                child: Icon(Icons.check_circle, color: Color(0xFF4285F4), size: 16),
              ),
          ],
        ),
      ),
    );
  }
}
