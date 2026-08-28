import 'package:flutter/material.dart';
import '../l10n/app_localizations.dart';
import '../services/api_service.dart';
import '../services/driver_report_service.dart';
import '../services/user_session.dart';

/// Dialog for drivers to submit bug reports, crashes, or other issues.
class DriverReportDialog extends StatefulWidget {
  final String? tripId;
  
  const DriverReportDialog({super.key, this.tripId});

  @override
  State<DriverReportDialog> createState() => _DriverReportDialogState();

  static Future<void> show(BuildContext context, {String? tripId}) {
    return showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => DriverReportDialog(tripId: tripId),
    );
  }
}

class _DriverReportDialogState extends State<DriverReportDialog> {
  String _selectedType = 'bug';
  final _messageController = TextEditingController();
  bool _submitting = false;

  List<Map<String, dynamic>> _getReportTypes(BuildContext context) {
    final loc = S.of(context);
    return [
      {'value': 'app_crash', 'label': loc.appCrashLabel, 'icon': Icons.error_outline, 'color': Colors.red},
      {'value': 'bug', 'label': loc.errorBugLabel, 'icon': Icons.bug_report, 'color': Colors.orange},
      {'value': 'feature_request', 'label': loc.featureRequestLabel, 'icon': Icons.lightbulb_outline, 'color': Colors.blue},
      {'value': 'complaint', 'label': loc.complaintLabel, 'icon': Icons.warning_amber, 'color': Colors.purple},
      {'value': 'other', 'label': loc.otherLabel, 'icon': Icons.report_problem, 'color': Colors.grey},
    ];
  }

  @override
  void dispose() {
    _messageController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_messageController.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(S.of(context).pleaseDescribeProblem)),
      );
      return;
    }

    setState(() => _submitting = true);

    try {
      final user = await UserSession.getUser();
      final driverId = user?['id']?.toString() ?? 'unknown';
      final driverName = '${user?['firstName'] ?? ''} ${user?['lastName'] ?? ''}'.trim();

      await DriverReportService.submitReport(
        driverId: driverId,
        driverName: driverName.isNotEmpty ? driverName : 'Driver $driverId',
        type: _selectedType,
        message: _messageController.text.trim(),
        tripId: widget.tripId,
      );

      if (mounted) {
        Navigator.pop(context);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(S.of(context).reportSentSuccess),
            backgroundColor: const Color(0xFF4CAF50),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        // Clean message (2026-08-28): the server's words for ApiException,
        // a generic one otherwise — never the raw "ApiException(400): …".
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content: Text(e is ApiException
                  ? e.message
                  : S.of(context).connectionError)),
        );
      }
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.all(16),
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: const Color(0xFF1A1E2E),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: const Color(0xFF2A2F42)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: const Color(0xFFF44336).withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Icon(Icons.report_problem, color: Color(0xFFF44336)),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      S.of(context).reportProblemTitle,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 20,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    Text(
                      S.of(context).helpUsImprove,
                      style: const TextStyle(color: Color(0xFF8A8FA0), fontSize: 13),
                    ),
                  ],
                ),
              ),
              IconButton(
                icon: const Icon(Icons.close, color: Colors.white54),
                onPressed: () => Navigator.pop(context),
              ),
            ],
          ),
          
          const SizedBox(height: 20),
          
          // Report type selector
          Text(
            S.of(context).problemTypeLabel,
            style: const TextStyle(color: Colors.white70, fontSize: 14, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: _getReportTypes(context).map((type) {
              final isSelected = _selectedType == type['value'];
              return ChoiceChip(
                label: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(type['icon'], size: 16, color: isSelected ? Colors.black : type['color']),
                    const SizedBox(width: 6),
                    Text(type['label']),
                  ],
                ),
                selected: isSelected,
                onSelected: (selected) {
                  if (selected) setState(() => _selectedType = type['value']);
                },
                selectedColor: type['color'],
                labelStyle: TextStyle(
                  color: isSelected ? Colors.black : Colors.white,
                  fontWeight: FontWeight.w600,
                ),
                backgroundColor: const Color(0xFF2A2F42),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
              );
            }).toList(),
          ),
          
          const SizedBox(height: 20),
          
          // Message input
          Text(
            S.of(context).descriptionLabel,
            style: const TextStyle(color: Colors.white70, fontSize: 14, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _messageController,
            maxLines: 4,
            maxLength: 500,
            style: const TextStyle(color: Colors.white),
            decoration: InputDecoration(
              hintText: S.of(context).describeIssue,
              hintStyle: const TextStyle(color: Color(0xFF8A8FA0)),
              filled: true,
              fillColor: const Color(0xFF2A2F42),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide.none,
              ),
              contentPadding: const EdgeInsets.all(16),
            ),
          ),
          
          const SizedBox(height: 20),
          
          // Submit button
          SizedBox(
            width: double.infinity,
            height: 54,
            child: ElevatedButton.icon(
              onPressed: _submitting ? null : _submit,
              icon: _submitting
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2, color: Colors.black),
                    )
                  : const Icon(Icons.send),
              label: Text(_submitting ? S.of(context).submittingLabel : S.of(context).submitReport),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFFD4A24C),
                foregroundColor: Colors.black,
                disabledBackgroundColor: const Color(0xFFD4A24C).withValues(alpha: 0.5),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
              ),
            ),
          ),
          
          // Safe area padding
          SizedBox(height: MediaQuery.of(context).viewInsets.bottom + 10),
        ],
      ),
    );
  }
}
