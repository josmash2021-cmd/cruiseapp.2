import 'package:flutter/material.dart';

import '../data/airport_airlines.dart';
import '../l10n/app_localizations.dart';
import '../widgets/neu_style.dart';

/// Push the "Select your airline" page for [airportCode]; [onDone] receives
/// the chosen airline name, or null when the rider skips.
///
/// Lives as a function (not a route name) because the schedule flow needs
/// the result inline: the airline line is appended to the booking notes
/// only when the rider actually picked one.
Future<void> maybeShowAirlineSelect(
  BuildContext context,
  String airportCode,
  void Function(String? airline) onDone,
) async {
  final airline = await Navigator.of(context).push<String>(
    PageRouteBuilder(
      pageBuilder: (_, __, ___) =>
          AirlineSelectScreen(airportCode: airportCode),
      transitionsBuilder: (_, anim, __, child) => SlideTransition(
        position: Tween<Offset>(
          begin: const Offset(1, 0),
          end: Offset.zero,
        ).animate(CurvedAnimation(parent: anim, curve: Curves.easeOutCubic)),
        child: child,
      ),
      transitionDuration: const Duration(milliseconds: 320),
    ),
  );
  onDone(airline);
}

/// "Select your airline" — popular row for the airport, "See more airlines"
/// search over the full list, Skip top-right. Neu dark, navy/gold.
class AirlineSelectScreen extends StatefulWidget {
  const AirlineSelectScreen({super.key, required this.airportCode});

  final String airportCode;

  @override
  State<AirlineSelectScreen> createState() => _AirlineSelectScreenState();
}

class _AirlineSelectScreenState extends State<AirlineSelectScreen> {
  static const _gold = Color(0xFFE8C547);

  bool _seeMore = false;
  String _query = '';
  final TextEditingController _searchCtrl = TextEditingController();

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final code = widget.airportCode.toUpperCase();
    final popular = popularAirlinesFor(code);
    final all = allAirlinesFor(code);
    final filtered = _query.trim().isEmpty
        ? all
        : all
            .where((a) =>
                a.toLowerCase().contains(_query.trim().toLowerCase()))
            .toList();

    return Scaffold(
      backgroundColor: neuBase,
      body: Stack(
        children: [
          const Positioned.fill(child: NeuDotsBackdrop()),
          SafeArea(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // ── Top row: back / Skip ──
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
                  child: Row(
                    children: [
                      GestureDetector(
                        onTap: () => Navigator.of(context).pop(),
                        child: Container(
                          width: 38,
                          height: 38,
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha: 0.06),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: const Icon(Icons.arrow_back_ios_new_rounded,
                              color: Colors.white, size: 18),
                        ),
                      ),
                      const Spacer(),
                      GestureDetector(
                        onTap: () => Navigator.of(context).pop(),
                        child: Padding(
                          padding: const EdgeInsets.all(8),
                          child: Text(
                            s.airlineSkip,
                            style: const TextStyle(
                              color: _gold,
                              fontSize: 15,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 14),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  child: Text(
                    s.airlineSelectTitle,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 24,
                      fontWeight: FontWeight.w800,
                      letterSpacing: -0.4,
                    ),
                  ),
                ),
                const SizedBox(height: 20),
                Expanded(
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
                    children: [
                      if (!_seeMore) ...[
                        Text(
                          s.airlinePopularAt(code),
                          style: const TextStyle(
                            color: Colors.white54,
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 12),
                        ...popular.map((a) => _airlineRow(a)),
                        const SizedBox(height: 8),
                        GestureDetector(
                          onTap: () => setState(() => _seeMore = true),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(vertical: 10),
                            child: Row(
                              children: [
                                const Icon(Icons.search_rounded,
                                    color: _gold, size: 18),
                                const SizedBox(width: 8),
                                Text(
                                  s.airlineSeeMore,
                                  style: const TextStyle(
                                    color: _gold,
                                    fontSize: 14,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ] else ...[
                        // Search field over the full list.
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 14),
                          decoration: neuBox(radius: 14, pressed: true),
                          child: TextField(
                            controller: _searchCtrl,
                            autofocus: true,
                            style: const TextStyle(
                                color: Colors.white, fontSize: 15),
                            decoration: InputDecoration(
                              border: InputBorder.none,
                              icon: const Icon(Icons.search_rounded,
                                  color: Colors.white38, size: 20),
                              hintText: s.airlineSearchHint,
                              hintStyle: const TextStyle(
                                  color: Colors.white38, fontSize: 15),
                            ),
                            onChanged: (v) => setState(() => _query = v),
                          ),
                        ),
                        const SizedBox(height: 12),
                        if (filtered.isEmpty)
                          Padding(
                            padding: const EdgeInsets.symmetric(vertical: 20),
                            child: Text(
                              s.airlineNoResults,
                              style: const TextStyle(
                                  color: Colors.white38, fontSize: 13),
                            ),
                          )
                        else
                          ...filtered.map((a) => _airlineRow(a)),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _airlineRow(String name) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: GestureDetector(
        onTap: () => Navigator.of(context).pop(name),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          decoration: neuBox(radius: 16),
          child: Row(
            children: [
              Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  color: _gold.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Icon(Icons.flight_rounded,
                    color: _gold, size: 19),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Text(
                  name,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              Icon(Icons.chevron_right_rounded,
                  color: Colors.white.withValues(alpha: 0.35), size: 20),
            ],
          ),
        ),
      ),
    );
  }
}
