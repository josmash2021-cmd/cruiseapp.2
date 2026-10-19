import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Guardian for the driver map's boot placeholder (user report 2026-10-18:
/// "cuando entro a la app como driver el mapa se queda negro unos
/// segundos"). The veil's while-loading placeholder was #07080D —
/// near-black — so a cold start on a slow network showed seconds of black
/// before the static snapshot (itself a network image) and the live style
/// landed. It must be the navy of the final styled map (#0A1128) so the
/// load is invisible.
void main() {
  final src =
      File('lib/widgets/static_map_snapshot.dart').readAsStringSync();

  test('the loading placeholder is the navy of the styled map, never black',
      () {
    expect(src, contains('ColoredBox(color: Color(0xFF0A1128))'),
        reason: 'the navy of the final styled map while the still loads');
    expect(src, isNot(contains('0xFF07080D')),
        reason: 'the near-black placeholder is exactly what the user saw '
            'as a black screen while the snapshot downloaded');
  });
}
