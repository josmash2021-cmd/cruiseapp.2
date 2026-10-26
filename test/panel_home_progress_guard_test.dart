import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _entryPath() {
  final html = File('backend/dispatch_panel/index.html').readAsStringSync();
  final match = RegExp(r'src="/panel/assets/(index-[^"]+\.js)"')
      .firstMatch(html);
  if (match == null) throw StateError('Entry bundle not found');
  return 'backend/dispatch_panel/assets/${match.group(1)}';
}

void main() {
  final bundle = File(_entryPath()).readAsStringSync();

  test('home uses the exact verification queue without blocking every source', () {
    for (final needle in [
      'guard-pin panel_home_progress_guard_test',
      'guard-pin panel_home_count_parity_guard_test',
      's=ks(),i=Ye("rider"),a=Ye("driver"),o=nn()',
      'function Ye(e){return Js(e==="rider"?At:wt)}',
      'ridersPending:o.rows.filter(h=>h.role==="rider"&&h.status==="pending").length',
      'driversPending:o.rows.filter(h=>h.role==="driver"&&h.status==="pending").length',
      'driversWaitlist:o.rows.filter(h=>h.role==="driver"&&h.status==="waitlist").length',
      'verifPending:o.rows.filter(h=>h.status==="pending").length',
      'homeMetric(sectionState.viajes,x.requested)',
      'homeMetric(sectionState.reservas,x.scheduledPending)',
      'homeMetric(sectionState.soporte,x.supportOpen)',
      'homeMetric(sectionState.mapa,x.driversOnline)',
      'homeLabel(N,x,sectionState[N.id])',
      'homeBadge(N,x,sectionState[N.id])',
      'nn as aA',
    ]) {
      expect(bundle, contains(needle), reason: needle);
    }
    expect(
      bundle,
      isNot(contains(
          'if(s.loading||i.loading||a.loading||o.loading||l.loading||p.loading||u.loading)return')),
      reason: 'a slow source must not hide the entire dashboard',
    );
    expect(bundle, isNot(contains('function sharedVerificationDocs(')));
    expect(bundle, isNot(contains('shared=sharedVerificationDocs()')));
    expect(bundle, isNot(contains('useShared?null:R(k(T,"verifications")')));
    expect(
      bundle,
      isNot(contains(
          'i.people.map(h=>({role:"rider",status:h.verificationStatus}))')),
      reason: 'the badge must not replace the verification queue with people',
    );
    final verificationPage =
        File('backend/dispatch_panel/assets/index-jhlVlbS1.js')
            .readAsStringSync();
    expect(verificationPage, contains('aA as qe'));
    expect(verificationPage, contains('=qe()'));
  });

  test('real helpers show progress and errors without fake zeroes', () {
    final cardsStart = bundle.indexOf('function wn');
    final cardsEnd = bundle.indexOf('function In', cardsStart);
    final helpersStart = bundle.indexOf('function homeMetric');
    final helpersEnd = bundle.indexOf('function En(', helpersStart);
    expect(cardsStart, isNonNegative);
    expect(cardsEnd, greaterThan(cardsStart));
    expect(helpersStart, isNonNegative);
    expect(helpersEnd, greaterThan(helpersStart));
    final script = '''
${bundle.substring(cardsStart, cardsEnd)}
${bundle.substring(helpersStart, helpersEnd)}
const n={jsx:(type,props)=>({type,props})},he='skeleton';
const x={viajesBadge:0,scheduledPending:0,supportOpen:0,alertsUnread:0,
  ridersPending:1,driversPending:2,driversWaitlist:1,verifPending:3};
const actual={
  loadingLabel:homeLabel({id:'riders'},x,{loading:true,error:null}),
  loadingBadge:homeBadge({id:'riders'},x,{loading:true,error:null}),
  loadingMetric:homeMetric({loading:true,error:null},0).type,
  readyMetric:homeMetric({loading:false,error:null},0),
  errorLabel:homeLabel({id:'drivers'},x,{loading:false,error:'failed'}),
  errorBadge:homeBadge({id:'drivers'},x,{loading:false,error:'failed'}),
  errorMetric:homeMetric({loading:false,error:'failed'},0),
  readyDriversBadge:homeBadge({id:'drivers'},x,{loading:false,error:null}),
  readyVerificationBadge:homeBadge({id:'verificacion'},x,{loading:false,error:null}),
  configLabel:homeLabel({id:'precios-config'},x,undefined),
};
const expected={
  loadingLabel:'Cargando…',loadingBadge:null,loadingMetric:'skeleton',
  readyMetric:'0',errorLabel:'No disponible',errorBadge:null,errorMetric:'—',
  readyDriversBadge:3,readyVerificationBadge:3,
  configLabel:'Tarifas y ajustes',
};
if(JSON.stringify(actual)!==JSON.stringify(expected)){
  console.error(JSON.stringify(actual));process.exit(1);
}
console.log(JSON.stringify(actual));
''';
    final result = Process.runSync('node', ['-e', script]);
    expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
    expect('${result.stdout}', contains('"readyDriversBadge":3'));
  });

  test('backend status normalization preserves waitlist', () {
    final start = bundle.indexOf('function Nt(');
    final end = bundle.indexOf('function Vs(', start);
    expect(start, isNonNegative);
    expect(end, greaterThan(start));
    final script = '''
const c=e=>e==null?null:typeof e==='string'?(e===''?null:e):null;
${bundle.substring(start, end)}
const cases=[
  [{verification_status:'waitlist',is_verified:false},'waitlist'],
  [{verification_status:'pending',is_verified:false},'pending'],
  [{verification_status:'approved',is_verified:false},'approved'],
  [{verification_status:'rejected',is_verified:false},'rejected'],
  [{verification_status:'none',is_verified:true},'approved'],
];
for(const [input,expected] of cases){
  const actual=Nt(input);
  if(actual!==expected)throw new Error(JSON.stringify({input,expected,actual}));
}
console.log('waitlist and the other statuses are preserved');
''';
    final result = Process.runSync('node', ['-e', script]);
    expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
  });

  test('the edited entry bundle parses', () {
    final result = Process.runSync('node', ['--check', _entryPath()]);
    expect(result.exitCode, 0, reason: '${result.stderr}');
  });
}
