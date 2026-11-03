import 'package:cruise_app/widgets/morph_box.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

/// One surface that turns into another: the nav panel growing into the
/// whole trip and folding back (owner 2026-11-02: "este mismo sheet es el
/// que se debe transformar").
void main() {
  Widget host(double t) => Directionality(
        textDirection: TextDirection.ltr,
        child: Align(
          alignment: Alignment.topCenter,
          child: SizedBox(
            width: 300,
            child: MorphBox(
              key: const ValueKey('morph'),
              t: t,
              children: const [
                SizedBox(key: ValueKey('face'), height: 50),
                SizedBox(key: ValueKey('body'), height: 200),
              ],
            ),
          ),
        ),
      );

  Size size(WidgetTester t, String k) => t.getSize(find.byKey(ValueKey(k)));

  testWidgets('its height glides between the two; both keep their own',
      (t) async {
    await t.pumpWidget(host(0));
    expect(size(t, 'morph').height, 50);
    await t.pumpWidget(host(0.5));
    expect(size(t, 'morph').height, 125);
    expect(size(t, 'body').height, 200,
        reason: 'folding, the body is drawn whole and clipped — it does not '
            'squash or vanish');
    expect(size(t, 'face').height, 50);
    await t.pumpWidget(host(1));
    expect(size(t, 'morph').height, 200);
    expect(t.takeException(), isNull);
  });
}
