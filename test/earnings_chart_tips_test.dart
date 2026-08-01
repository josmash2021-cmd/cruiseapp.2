import 'package:flutter_test/flutter_test.dart';

/// The rule that decides which hourly columns get their amount printed.
///
/// A copy of _tipColumns from driver_home_screen, which is private to a
/// State class and cannot be reached from here. It is eight lines of pure
/// arithmetic with no Flutter in it, and the thing worth pinning down is the
/// rule itself: labels never land close enough to overlap, and the ones that
/// survive are the hours that earned most.
Set<int> tipColumns(List<double> values) {
  final order = <int>[
    for (var i = 0; i < values.length; i++)
      if (values[i] > 0) i,
  ]..sort((a, b) => values[b].compareTo(values[a]));
  final taken = <int>{};
  for (final i in order) {
    if (taken.any((j) => (j - i).abs() < 3)) continue;
    taken.add(i);
  }
  return taken;
}

void main() {
  List<double> day(Map<int, double> earned) =>
      List<double>.generate(24, (i) => earned[i] ?? 0.0);

  test('an hour that earned nothing is never labelled', () {
    final tips = tipColumns(day({9: 12.0}));
    expect(tips, {9});
  });

  test('no two labels land within three columns', () {
    // A busy morning: five consecutive hours, all with money.
    final tips = tipColumns(day({7: 8, 8: 14, 9: 9, 10: 22, 11: 6}));
    final sorted = tips.toList()..sort();
    for (var i = 1; i < sorted.length; i++) {
      expect(sorted[i] - sorted[i - 1], greaterThanOrEqualTo(3),
          reason: 'labels at ${sorted[i - 1]} and ${sorted[i]} would overlap');
    }
  });

  test('when two are too close, the bigger one keeps its label', () {
    final tips = tipColumns(day({8: 5.0, 9: 40.0}));
    expect(tips, contains(9));
    expect(tips, isNot(contains(8)));
  });

  test('a full day still labels the peaks', () {
    final tips = tipColumns(List<double>.generate(24, (i) => (i + 1) * 2.0));
    expect(tips, isNotEmpty);
    expect(tips, contains(23), reason: 'the largest hour is always labelled');
    // 24 columns, three apart — eight is the most that can fit.
    expect(tips.length, lessThanOrEqualTo(8));
  });

  test('an empty day labels nothing', () {
    expect(tipColumns(day(const {})), isEmpty);
  });

  test('it always works down from the largest', () {
    //            0   1   2   3  4   5   6
    final v = <double>[10, 0, 25, 0, 8, 0, 30];
    // 30 at 6 goes in first. 25 at 2 is four columns away, so it fits. 10 at
    // 0 is two from 2, and 8 at 4 is two from 6 — both crowded out by
    // something larger, which is the point of the ordering.
    expect(tipColumns(v), {6, 2});
  });
}
