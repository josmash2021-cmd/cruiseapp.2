import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Guard-pins for the manually edited Dispatch Drivers bundle. The React
/// source lives outside this repository, so a rebuild must re-apply these
/// behaviors: restore the view after opening a profile and expose waitlist /
/// incomplete-document filters above the advanced-filters submenu.
void main() {
  final chunk = File('backend/dispatch_panel/assets/index-azyIyM-i.js')
      .readAsStringSync();

  test('the Drivers view is restored from session storage on remount', () {
    expect(
        chunk, contains('guard-pin panel_drivers_waitlist_filter_guard_test'));
    expect(chunk, contains('DRIVERS_VIEW_KEY="cruise_drivers_filters_v1"'));
    expect(
      chunk,
      contains(
          'savedView=m.useMemo(()=>t==="driver"?readDriversView():null,[t])'),
      reason:
          'restore before initializing state so no unfiltered frame flashes',
    );
    for (final needle in [
      'm.useState(savedView?.tab??"todos")',
      'm.useState(savedView?.query??"")',
      'm.useState(savedView?.limit??de)',
      'm.useState(savedView?.stat??null)',
      'm.useState(()=>new Set(savedView?.cities??[]))',
      'JSON.stringify({tab:i,query:u,stat:statF,cities:[...cityFS],limit:c})',
      '[y,i,u,statF,cityFS,c]',
      'setStatF(null),setCityFS(new Set)',
    ]) {
      expect(chunk, contains(needle));
    }
    expect(
      chunk,
      contains(
          'console.warn("[Drivers] No se pudieron restaurar los filtros:"'),
      reason: 'storage failures are reported, never silently swallowed',
    );
    expect(
      chunk,
      contains(
          'console.warn("[Drivers] No se pudieron conservar los filtros:"'),
    );
  });

  test('waitlist and incomplete docs have direct buttons above the submenu',
      () {
    final quickButtons = chunk
        .indexOf('y&&e.jsxs("div",{className:"mb-2 grid grid-cols-2 gap-2"');
    final submenu = chunk.indexOf('y&&fleet!==null&&e.jsxs("details"');
    expect(quickButtons, greaterThan(-1));
    expect(submenu, greaterThan(quickButtons),
        reason:
            'the two requested actions are visible without opening Filtros');
    expect(
      chunk,
      contains(
          'chipBtn("waitlist","Lista de espera",waitlistCount,"border-warning/25 text-warning",!1,!0)'),
    );
    expect(
      chunk,
      contains(
          'chipBtn("docs_no","Docs incompletos",fleet===null?"…":incompleteCount,"border-error/25 text-error",!1,!0)'),
    );
    expect(chunk, contains('if(allStatuses){o("todos"),x(de)}'),
        reason: 'a quick filter must not stay trapped inside Aprobados or '
            'another incompatible status tab');
    expect(chunk, contains('waitlist:"Lista de espera"'));
  });

  test('waitlist and doc counts use the real fields and selected cities', () {
    expect(
      chunk,
      contains(
          'if(y&&statF==="waitlist")base=w.filter(d=>d.verificationStatus==="waitlist")'),
    );
    expect(
      chunk,
      contains(
          'waitlistCount=N.filter(d=>d.verificationStatus==="waitlist"&&(cityFS.size===0||cityFS.has(cityKeyOf(d)))).length'),
    );
    expect(
      chunk,
      contains(
          'cityFleetRows=fleet===null?[]:fleet.drivers.filter(d=>visibleDriverIds.has(d.id)&&(cityFS.size===0||cityFS.has(cityKeyOf(d))))'),
      reason: 'document counts follow both search and the multi-city selection',
    );
    expect(
        chunk,
        contains(
            'incompleteCount=cityFleetRows.filter(d=>d.docs===!1).length'));
    expect(chunk,
        contains('chipBtn("docs_no","Docs incompletos",incompleteCount'));
    expect(
      chunk,
      contains(
          'else if(y&&statF!==null){if(fleet===null)base=[];else{const ids='),
      reason: 'a restored doc/tier filter must not flash unfiltered drivers '
          'while its stats are loading',
    );
  });

  test('the real restore helper survives a simulated profile round trip',
      () async {
    final start = chunk.indexOf('const readDriversView=');
    final end = chunk.indexOf('\nfunction Wa', start);
    expect(start, greaterThan(-1));
    expect(end, greaterThan(start));
    final helper = chunk.substring(start, end);
    final script = '''
const de = 60;
const DRIVERS_VIEW_KEY = "cruise_drivers_filters_v1";
const be = [{id:"todos"},{id:"aprobados"},{id:"verificacion"}];
$helper
let stored = JSON.stringify({
  tab: "verificacion", query: "mar", stat: "docs_no",
  cities: ["FL|Miami", "FL|Orlando", "FL|Miami", 7], limit: 120,
});
globalThis.window = {sessionStorage: {getItem: key => {
  if (key !== DRIVERS_VIEW_KEY) throw new Error("wrong storage key");
  return stored;
}}};
const beforeProfile = readDriversView();
const afterProfile = readDriversView();
let warnings = 0;
console.warn = () => { warnings += 1; };
stored = "{broken";
const corrupt = readDriversView();
stored = JSON.stringify([]);
const wrongShape = readDriversView();
console.log(JSON.stringify({beforeProfile, afterProfile, corrupt, wrongShape, warnings}));
''';
    final result = await Process.run('node', ['-e', script]);
    expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
    final value =
        jsonDecode((result.stdout as String).trim()) as Map<String, dynamic>;
    final before = value['beforeProfile'] as Map<String, dynamic>;
    final after = value['afterProfile'] as Map<String, dynamic>;
    expect(before, {
      'tab': 'verificacion',
      'query': 'mar',
      'stat': 'docs_no',
      'cities': ['FL|Miami', 'FL|Orlando'],
      'limit': 120,
    });
    expect(after, before,
        reason: 'remounting for the profile retains the view');
    expect(value['corrupt'], {
      'tab': 'todos',
      'query': '',
      'stat': null,
      'cities': [],
      'limit': 60,
    });
    expect(value['wrongShape'], value['corrupt']);
    expect(value['warnings'], 1);
  });
}
