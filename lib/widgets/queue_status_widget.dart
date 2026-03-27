import 'dart:async';
import 'package:flutter/material.dart';

/// Simulated queue status widget shown while "waiting" for an agent.
///
/// Displays position in queue, estimated wait time, and an animated
/// progress bar. Fully decorative — the queue is simulated locally.
class QueueStatusWidget extends StatefulWidget {
  const QueueStatusWidget({
    super.key,
    required this.totalDuration,
    required this.onComplete,
    required this.isSpanish,
  });

  /// Total wait time in seconds (typically 180-240).
  final int totalDuration;

  /// Called when the queue simulation completes.
  final VoidCallback onComplete;

  /// Whether to show Spanish labels.
  final bool isSpanish;

  @override
  State<QueueStatusWidget> createState() => _QueueStatusWidgetState();
}

class _QueueStatusWidgetState extends State<QueueStatusWidget>
    with SingleTickerProviderStateMixin {
  static const _gold = Color(0xFFE8C547);

  late final AnimationController _progressCtrl;
  Timer? _updateTimer;
  int _elapsed = 0;

  int get _position {
    final pct = _elapsed / widget.totalDuration;
    if (pct < 0.25) return 3;
    if (pct < 0.50) return 2;
    if (pct < 0.75) return 1;
    return 0;
  }

  String get _estimatedTime {
    final remaining = widget.totalDuration - _elapsed;
    final mins = (remaining / 60).ceil().clamp(0, 10);
    if (mins <= 0) {
      return widget.isSpanish ? '< 1 min' : '< 1 min';
    }
    return '~$mins min';
  }

  String get _statusText {
    final pos = _position;
    if (pos == 0) {
      return widget.isSpanish
          ? 'Estás siguiente en la cola'
          : "You're next in queue";
    }
    return widget.isSpanish
        ? 'Posición: $pos en cola'
        : 'Position: $pos in queue';
  }

  @override
  void initState() {
    super.initState();
    _progressCtrl = AnimationController(
      vsync: this,
      duration: Duration(seconds: widget.totalDuration),
    )..forward();

    _updateTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() => _elapsed++);
      if (_elapsed >= widget.totalDuration) {
        _updateTimer?.cancel();
        widget.onComplete();
      }
    });
  }

  @override
  void dispose() {
    _updateTimer?.cancel();
    _progressCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _progressCtrl,
      builder: (_, __) {
        return Container(
          margin: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: const Color(0xFF1E1E1E),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: _gold.withValues(alpha: 0.2),
            ),
            boxShadow: [
              BoxShadow(
                color: _gold.withValues(alpha: 0.05),
                blurRadius: 12,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Header
              Row(
                children: [
                  const Icon(Icons.hourglass_top_rounded, color: Colors.white70, size: 20),
                  const SizedBox(width: 10),
                  Text(
                    widget.isSpanish
                        ? 'En cola para un agente'
                        : 'Waiting for an agent',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),

              // Position & estimated time
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    _statusText,
                    style: TextStyle(
                      color: Colors.grey[400],
                      fontSize: 13,
                    ),
                  ),
                  Text(
                    '${widget.isSpanish ? 'Tiempo estimado' : 'Estimated wait'}: $_estimatedTime',
                    style: TextStyle(
                      color: Colors.grey[400],
                      fontSize: 13,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 14),

              // Progress bar
              ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: LinearProgressIndicator(
                  value: _progressCtrl.value,
                  backgroundColor: Colors.white.withValues(alpha: 0.08),
                  valueColor: const AlwaysStoppedAnimation<Color>(_gold),
                  minHeight: 6,
                ),
              ),
              const SizedBox(height: 10),

              // Percentage
              Text(
                '${(_progressCtrl.value * 100).toInt()}%',
                style: TextStyle(
                  color: _gold,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
