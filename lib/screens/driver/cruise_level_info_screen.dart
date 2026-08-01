import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../widgets/neu_style.dart';

/// How Cruise Level works — the rules, written down.
///
/// A ladder with no published rules is a ladder a driver cannot plan
/// against. This is the page the Learn more link opens: what each level
/// requires, in a table they can read across, and what does and does not
/// count toward it.
///
/// The one thing it must not do is imply that the performance rates gate a
/// level. They do not — only completed trips and the average rating do —
/// and the Cruise Level screen shows all six figures together, which is
/// exactly the arrangement that invites the wrong conclusion. So the table
/// carries the two that count, and the rates get a section of their own
/// that says plainly what they are for.
class CruiseLevelInfoScreen extends StatelessWidget {
  const CruiseLevelInfoScreen({
    super.key,
    required this.completedTrips,
    required this.avgRating,
  });

  /// The driver's own figures, handed in by the level screen rather than
  /// fetched again. A table of thresholds with no "you are here" row makes
  /// the driver do the comparison in their head, and the screen that opens
  /// this one already has both numbers loaded.
  final int completedTrips;
  final double avgRating;

  /// The two value columns, shared by the header, the You row and every
  /// level row so the three always line up.
  static const _tripsCol = 76.0;
  static const _ratingCol = 64.0;

  /// Name, colour, trips, rating — the same five rungs the level screen
  /// builds, reduced to what this table needs.
  static const _rows = <_LevelRow>[
    _LevelRow('Bronze', Color(0xFFCD7F32), Icons.emoji_events_rounded, 0, 0.0),
    _LevelRow(
      'Silver',
      Color(0xFFB0BEC5),
      Icons.workspace_premium_rounded,
      50,
      4.5,
    ),
    _LevelRow('Gold', Color(0xFFE8C547), Icons.star_rounded, 150, 4.7),
    _LevelRow(
      'Platinum',
      Color(0xFF90CAF9),
      Icons.auto_awesome_rounded,
      300,
      4.8,
    ),
    _LevelRow('Diamond', Color(0xFF80DEEA), Icons.diamond_rounded, 500, 4.9),
  ];

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    return Scaffold(
      backgroundColor: neuBase,
      appBar: AppBar(
        backgroundColor: neuBase,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: true,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_rounded, color: Colors.white),
          onPressed: () => Navigator.pop(context),
        ),
        title: Text(
          s.cruiseHowItWorks,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 17,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
      body: ListView(
        physics: const BouncingScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 40),
        children: [
          _heading(s.cruiseWhatIsRequired),
          const SizedBox(height: 8),
          _body(s.cruiseCriteriaIntro),
          const SizedBox(height: 20),
          _table(context),
          const SizedBox(height: 30),
          _heading(s.cruiseHowYouMoveUp),
          const SizedBox(height: 8),
          _body(s.cruiseHowYouMoveUpBody),
          const SizedBox(height: 26),
          _heading(s.cruiseAboutTheRates),
          const SizedBox(height: 8),
          _body(s.cruiseAboutTheRatesBody),
          const SizedBox(height: 26),
          _heading(s.cruiseKeepingYourLevel),
          const SizedBox(height: 8),
          _body(s.cruiseKeepingYourLevelBody),
        ],
      ),
    );
  }

  Widget _heading(String t) => Text(
        t,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 19,
          fontWeight: FontWeight.w800,
          letterSpacing: -0.3,
        ),
      );

  Widget _body(String t) => Text(
        t,
        style: TextStyle(
          color: Colors.white.withValues(alpha: 0.5),
          fontSize: 14,
          height: 1.5,
        ),
      );

  /// Every level and what it takes, in two columns a driver can read across.
  ///
  /// Two columns and not six. The rates do not gate a level, and a table
  /// with a column for each would say they do — the strongest claim on this
  /// page would be the false one.
  Widget _table(BuildContext context) {
    final s = S.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      decoration: neuBox(radius: 20),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 14, bottom: 10),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    s.cruiseLevelColumn,
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.4),
                      fontSize: 11.5,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.6,
                    ),
                  ),
                ),
                SizedBox(
                  width: _tripsCol,
                  child: Text(
                    s.cruiseTripsColumn,
                    textAlign: TextAlign.end,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.4),
                      fontSize: 11.5,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.6,
                    ),
                  ),
                ),
                SizedBox(
                  width: _ratingCol,
                  child: Text(
                    s.cruiseRatingColumn,
                    textAlign: TextAlign.end,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.4),
                      fontSize: 11.5,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.6,
                    ),
                  ),
                ),
              ],
            ),
          ),
          // The driver's own line first, so the thresholds below it read as
          // a comparison rather than as a list.
          Divider(height: 1, color: Colors.white.withValues(alpha: 0.05)),
          _youRow(s),
          for (var i = 0; i < _rows.length; i++) ...[
            Divider(height: 1, color: Colors.white.withValues(alpha: 0.05)),
            _levelRow(_rows[i], s),
          ],
        ],
      ),
    );
  }

  /// Where the driver actually stands, in the same three columns.
  Widget _youRow(S s) {
    const gold = Color(0xFFE8C547);
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 13),
      child: Row(
        children: [
          Expanded(
            child: Row(
              children: [
                // The person icon marks this row as the driver's own
                // without a box around it — the colour already separates
                // it from the five thresholds below.
                const Icon(Icons.person_rounded, color: gold, size: 17),
                const SizedBox(width: 9),
                Text(
                  s.cruiseYouColumn,
                  style: const TextStyle(
                    color: gold,
                    fontSize: 14,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ],
            ),
          ),
          SizedBox(
            width: _tripsCol,
            child: Text(
              '$completedTrips',
              textAlign: TextAlign.end,
              style: const TextStyle(
                color: gold,
                fontSize: 13.5,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
          SizedBox(
            width: _ratingCol,
            child: Text(
              // A driver nobody has rated yet has no average, and printing
              // "0.00" would read as the worst possible score.
              avgRating <= 0 ? '—' : avgRating.toStringAsFixed(1),
              textAlign: TextAlign.end,
              style: const TextStyle(
                color: gold,
                fontSize: 13.5,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _levelRow(_LevelRow r, S s) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 13),
      child: Row(
        children: [
          Expanded(
            child: Row(
              children: [
                Icon(r.icon, color: r.color, size: 17),
                const SizedBox(width: 9),
                Text(
                  r.name,
                  style: TextStyle(
                    color: r.color,
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          ),
          SizedBox(
            width: _tripsCol,
            child: Text(
              // Bronze asks for nothing — it is where everyone starts, and
              // "0" would read as a target rather than as the floor.
              r.minTrips == 0 ? s.cruiseStartHere : '${r.minTrips}+',
              textAlign: TextAlign.end,
              style: TextStyle(
                color: r.minTrips == 0
                    ? Colors.white.withValues(alpha: 0.4)
                    : Colors.white,
                fontSize: 13.5,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          SizedBox(
            width: _ratingCol,
            child: Text(
              r.minRating == 0 ? '—' : '${r.minRating}+',
              textAlign: TextAlign.end,
              style: TextStyle(
                color: r.minRating == 0
                    ? Colors.white.withValues(alpha: 0.4)
                    : Colors.white,
                fontSize: 13.5,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _LevelRow {
  const _LevelRow(
    this.name,
    this.color,
    this.icon,
    this.minTrips,
    this.minRating,
  );

  final String name;
  final Color color;
  final IconData icon;
  final int minTrips;
  final double minRating;
}
