import 'package:flutter/material.dart';

import '../services/network_service.dart';

/// Animated banner that slides in from the top when the device goes offline.
/// Place at the top of a Stack (inside SafeArea) on any screen.
class OfflineBanner extends StatelessWidget {
  const OfflineBanner({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: NetworkService().onlineNotifier,
      builder: (_, online, __) {
        return AnimatedSlide(
          offset: online ? const Offset(0, -1) : Offset.zero,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeInOut,
          child: AnimatedOpacity(
            opacity: online ? 0.0 : 1.0,
            duration: const Duration(milliseconds: 300),
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(vertical: 6),
              color: const Color(0xFFB71C1C),
              child: const Center(
                child: Text(
                  'No connection — using local data',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
