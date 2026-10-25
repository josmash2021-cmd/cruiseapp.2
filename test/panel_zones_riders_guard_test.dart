import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final module = File('backend/dispatch_panel/assets/rider-zones-Cruise2026.js');
  final zones = File('backend/dispatch_panel/assets/index-C5JQni4U.js');
  final source = module.readAsStringSync();
  final zonesSource = zones.readAsStringSync();
  final helperSource = File('backend/dispatch_panel/assets/users-DWu98l86.js')
      .readAsStringSync();

  test('the rider explorer is mounted without removing the driver editor', () {
    expect(source, contains('guard-pin panel_zones_riders_guard_test'));
    expect(zonesSource, contains('guard-pin panel_zones_riders_guard_test'));
    expect(zonesSource, contains('RiderZoneExplorer'));
    expect(source, contains('y as useNavigate}from"./vendor-react-'));
    expect(source, isNot(contains('useNavigate}from"./index-')),
        reason: 'useNavigate comes from React, not the panel entry exports');
    expect(zonesSource, contains('setZoneAudience("riders")'));
    expect(zonesSource, contains('onShowDrivers:()=>setZoneAudience("drivers")'));
    expect(
      'zoneAudience==="drivers"&&drvView==='
          .allMatches(zonesSource)
          .length,
      7,
      reason: 'all seven driver layers hide in rider mode and restore on return',
    );
    expect(zonesSource, contains('zoneAudience==="drivers"&&l.jsxs("div"'));
    for (final needle in ['Nuevo sector', 'Guardar cambios', 'Zonas del mapa']) {
      expect(zonesSource, contains(needle));
    }
  });

  test('rider filters, map points and privacy guards are present', () {
    for (final needle in [
      '"/admin/rider-insights"',
      'Verificados',
      'Sin verificar',
      'Sin dato',
      'Último viaje',
      'Casa',
      'Trabajo',
      'rider-zone-counts',
      'rider-points',
      'riderEsc(',
      'document.visibilityState',
    ]) {
      expect(source + zonesSource + helperSource, contains(needle),
          reason: needle);
    }
    expect(source, isNot(contains('row.lat')));
    expect(source, isNot(contains('row.lng')));
    expect(source, isNot(contains('pickup_lat')));
    expect(source, isNot(contains('FavoriteLocation')));
    expect(source, contains('center'));
    expect(source, contains('2.39996'));
  });

  test('real filter, summary and approximate-area functions run with Node', () {
    final script = r'''
const fs = require('fs'), vm = require('vm');
let src = fs.readFileSync(process.argv[1], 'utf8');
src = src.replace(/^import.*$/gm, '');
src = src.replace(/export\{RiderZoneExplorer,[^}]+\};?/g, '');
src += '\nmodule.exports={riderFilterRows,riderSummary,riderPointFeatures,riderZoneFeatures,riderCityKey,riderOriginLabel,riderAreaSourceLabel,riderDateTime};';
const sandbox = {module:{exports:{}},exports:{},console};
vm.runInNewContext(src, sandbox);
const {riderFilterRows,riderSummary,riderPointFeatures,riderZoneFeatures,riderCityKey,riderOriginLabel,riderAreaSourceLabel,riderDateTime} = sandbox.module.exports;
const rows = [
 {id:1,first_name:'Web Verified',phone:'111',verified:true,registration_source:'web',default_payment_method:{display_name:'Visa •••• 4242'},created_at:'2026-01-01T12:00:00Z',area:{city:'Miami',state:'FL',sector_id:'zone-fl',source:'last_trip',city_key:'FL|Miami'}},
 {id:2,first_name:'App Pending',phone:'222',verified:false,registration_source:'app',area:{city:'Miami',state:'FL',sector_id:'zone-fl',source:'home',city_key:'FL|Miami'}},
 {id:3,first_name:'Unknown',phone:'333',verification_status:'pending',registration_source:null,area:{city:'Orlando',state:'FL',sector_id:'zone-fl',source:'work',city_key:'FL|Orlando'}},
 {id:4,first_name:'No Area',phone:'444',is_verified:true,registration_source:'dispatch',area:null},
 {id:5,first_name:'Web Texas',phone:'555',verified:false,registration_source:'web',area:{city:'Austin',state:'TX',sector_id:'zone-tx',source:'last_trip',city_key:'TX|Austin'}},
];
const ids = items => items.map(item => item.id);
const actual = {
 summary:riderSummary(rows),
 web:ids(riderFilterRows(rows,{category:'web'})),
 verified:ids(riderFilterRows(rows,{category:'verified'})),
 unknown:ids(riderFilterRows(rows,{category:'unknown'})),
 miami:ids(riderFilterRows(rows,{cities:['FL|Miami']})),
 search:ids(riderFilterRows(rows,{query:'555'})),
 noAreaKey:riderCityKey(rows[3]),
 origin:riderOriginLabel(rows[3]),
 source:riderAreaSourceLabel(rows[2]),
 invalidDate:riderDateTime('bad'),
};
const expected = {summary:{all:5,verified:2,unverified:3,web:2,app:1,dispatch:1,unknown:1},web:[1,5],verified:[1,4],unknown:[3],miami:[1,2],search:[5],noAreaKey:'|Sin zona',origin:'Dispatch',source:'Trabajo',invalidDate:'Sin dato'};
if (JSON.stringify(actual)!==JSON.stringify(expected)) {console.error(JSON.stringify(actual));process.exit(1)}
const centers={'FL|Miami':[25.77,-80.19],'FL|Orlando':[28.53,-81.37]};
const sectors=[{key:'zone-fl',name:'Florida',center:[-81,27],geometry:{type:'Polygon',coordinates:[]}},{key:'zone-tx',name:'Texas',center:[-97,30],geometry:{type:'Polygon',coordinates:[]}}];
const points=riderPointFeatures(rows,centers,sectors);
if(points.length!==4)throw new Error('one unlocated rider must stay off map');
if(points[0].geometry.coordinates[0]!==-80.19||points[0].geometry.coordinates[1]!==25.77)throw new Error('city center anchor changed');
if(points[1].geometry.coordinates[0]===-80.19&&points[1].geometry.coordinates[1]===25.77)throw new Error('same-city riders overlap');
const texas=points.find(point=>point.properties.id===5);
if(texas.geometry.coordinates[0]!==-97||texas.geometry.coordinates[1]!==30)throw new Error('sector fallback missing');
const zoneCounts=riderZoneFeatures(rows,sectors).map(feature=>[feature.properties.key,feature.properties.n]);
if(JSON.stringify(zoneCounts)!==JSON.stringify([['zone-fl',3],['zone-tx',1]]))throw new Error('zone counts do not follow riders');
console.log(JSON.stringify({actual,points:points.length,zoneCounts}));
''';
    final result = Process.runSync('node', ['-e', script, module.path]);
    expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
    expect('${result.stdout}', contains('"points":4'));
  });

  test('all edited zone modules parse', () {
    for (final file in [module, zones]) {
      final result = Process.runSync('node', ['--check', file.path]);
      expect(result.exitCode, 0, reason: '${file.path}\n${result.stderr}');
    }
  });
}
