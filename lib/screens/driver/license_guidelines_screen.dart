import 'package:flutter/material.dart';

import '../../config/app_theme.dart';
import '../../config/page_transitions.dart';
import '../../widgets/doc_guidelines_view.dart';
import 'license_scanner_screen.dart';

/// Guidelines for photographing the driver's license, shown before every
/// license capture in driver signup — the same page the rider identity flow
/// shows, hosted as a thin screen so a caller can push it and still receive
/// the captured path as the result, exactly as if it had pushed
/// [LicenseScannerScreen] directly.
class LicenseGuidelinesScreen extends StatelessWidget {
  const LicenseGuidelinesScreen({super.key, required this.side});

  /// 'Front' | 'Back' — passed straight through to the scanner.
  final String side;

  Future<void> _openScanner(BuildContext context) async {
    final path = await Navigator.of(context).push<String?>(
      slideFromRightRoute(LicenseScannerScreen(side: side)),
    );
    // A captured path or a null cancel — either way it becomes this screen's
    // result, never a loop back to the guidelines.
    if (context.mounted) Navigator.of(context).pop(path);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.of(context).bg,
      body: SafeArea(
        child: DocGuidelinesView(
          docType: 'license',
          onNext: () => _openScanner(context),
        ),
      ),
    );
  }
}
