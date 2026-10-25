import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final people = File('backend/dispatch_panel/assets/index-azyIyM-i.js');
  final entry = File('backend/dispatch_panel/assets/index-CuQT_62K.js');
  final users = File('backend/dispatch_panel/assets/users-DWu98l86.js');
  final source = people.readAsStringSync();
  final entrySource = entry.readAsStringSync();
  final usersSource = users.readAsStringSync();

  test('rider roster, fallback, filters and payment detail are wired', () {
    for (final needle in [
      'guard-pin panel_rider_insights_guard_test',
      'getRiderInsights',
      'getRiderPaymentMethods',
      'mergeRiderInsightPeople',
      'readRidersView',
      'cruise_riders_filters_v1',
      'riderInsightsError',
      'riderRetry',
      'sqlMethods:f.sqlPaymentMethods',
      'riderDateTimeLabel(k,"last_activity")',
      'riderDateTimeLabel(k,"last_trip")',
      'weekday:"short"',
      'type:"datetime-local"',
      'Origen de registro',
      'Última actividad',
    ]) {
      expect(source, contains(needle), reason: needle);
    }
    expect(source, contains('const match=/^sql_(\\d+)\$/'));
    expect(source, contains('data.riders.find(item=>Number(item.id)===id)'));
    expect(usersSource, contains('"/admin/rider-insights"'));
    expect(usersSource, contains('/payment-methods'));
    expect(usersSource, contains('registration_source:"dispatch"'));
    expect(entrySource, contains('registrationSource:c(e.registration_source)'));
    expect(entrySource, contains('lastActiveAt:S(e.last_active_at)'));
  });

  test('real filters, summaries and persisted view execute with Node', () {
    final script = r'''
const fs=require('fs'),vm=require('vm');
const source=fs.readFileSync(process.argv[1],'utf8');
const start=source.indexOf('const riderFilterDefaults=');
const end=source.indexOf('/*! guard-pin panel_drivers_waitlist_filter_guard_test',start);
if(start<0||end<0||end<=start)throw new Error('rider helper block not found');
const code=source.slice(start,end);
const store=new Map;
const sandbox={console,module:{exports:{}},exports:{},window:{sessionStorage:{getItem:key=>store.has(key)?store.get(key):null,setItem:(key,value)=>store.set(key,value)}}};
vm.runInNewContext(`const de=60,RIDERS_VIEW_KEY="cruise_riders_filters_v1",be=[{id:"todos"},{id:"aprobados"},{id:"verificacion"}];${code};module.exports={filterRiderInsights,summarizeRiderInsights,riderAreaGroups,readRidersView,riderPreferredPayment,riderDateTimeLabel,riderAreaLabel,riderOriginLabel};`,sandbox);
const api=sandbox.module.exports,ids=rows=>rows.map(row=>row.id),eq=(actual,expected,label)=>{if(JSON.stringify(actual)!==JSON.stringify(expected))throw new Error(`${label}: ${JSON.stringify(actual)} != ${JSON.stringify(expected)}`)};
const rows=[
 {id:1,verified:true,hasDocuments:true,documentStatuses:['approved'],registrationSource:'web',paymentMethods:[{methodType:'stripe_card',displayName:'Visa •••• 4242',isDefault:true}],area:{state:'FL',city:'Miami',sectorId:'zone-fl',source:'last_trip'},createdAt:'2026-01-01T12:00:00Z',lastActiveAt:'2026-01-04T12:00:00Z',lastTripAt:'2026-01-03T12:00:00Z'},
 {id:2,verified:false,hasDocuments:false,documentStatuses:[],registrationSource:'app',paymentMethods:[],area:{state:'FL',city:'Orlando',sectorId:'zone-fl',source:'home'},createdAt:'2026-02-01T12:00:00Z',lastActiveAt:null,lastTripAt:null},
 {id:3,verificationStatus:'approved',documentStatuses:['pending'],registrationSource:null,paymentMethods:[{methodType:'apple_pay',displayName:null,isDefault:false}],area:null,createdAt:'2026-03-01T12:00:00Z',lastActiveAt:null,lastTripAt:'2026-03-02T12:00:00Z'},
 {id:4,verified:false,documentStatuses:['pending'],registrationSource:'dispatch',paymentMethods:[],area:{state:'TX',city:'Austin',sectorId:null,source:null},createdAt:'2026-04-01T12:00:00Z',lastActiveAt:null,lastTripAt:'2026-04-02T12:00:00Z'},
];
const filter=filters=>ids(api.filterRiderInsights(rows,filters));
eq(filter({verification:'verified'}),[1,3],'verified');
eq(filter({verification:'unverified'}),[2,4],'unverified');
eq(filter({documents:'with'}),[1,3,4],'with documents');
eq(filter({documents:'without'}),[2],'without documents');
eq(filter({documentStatus:'pending'}),[3,4],'document review');
eq(filter({origin:'web'}),[1],'web');
eq(filter({origin:'app'}),[2],'app');
eq(filter({origin:'dispatch'}),[4],'dispatch');
eq(filter({origin:'unknown'}),[3],'unknown origin');
eq(filter({payment:'none'}),[2,4],'no payment');
eq(filter({payment:'stripe_card'}),[1],'card');
eq(filter({states:['FL']}),[1,2],'state');
eq(filter({areas:['FL|Miami']}),[1],'city');
eq(filter({sector:'zone-fl'}),[1,2],'sector');
eq(filter({sector:'unknown'}),[3,4],'without sector');
eq(filter({dateField:'registration',dateFrom:'2026-01-01T00:00',dateTo:'2026-01-31T23:59'}),[1],'registration range');
eq(filter({dateField:'last_trip',dateFrom:'2026-03-01T00:00',dateTo:'2026-03-31T23:59'}),[3],'last trip range');
eq(filter({dateField:'last_activity',dateFrom:'2026-01-04T00:00',dateTo:'2026-01-04T23:59'}),[1],'activity range');
eq(filter({dateField:'last_trip',dateFrom:'2020-01-01T00:00'}),[1,3,4],'missing trip dates excluded');
const summary=api.summarizeRiderInsights(rows);
eq({total:summary.total,verified:summary.verified,unverified:summary.unverified,withDocuments:summary.withDocuments,withoutDocuments:summary.withoutDocuments,origins:summary.origins,withoutPaymentMethod:summary.withoutPaymentMethod,withArea:summary.withArea,withoutArea:summary.withoutArea},{total:4,verified:2,unverified:2,withDocuments:3,withoutDocuments:1,origins:{web:1,app:1,dispatch:1,unknown:1},withoutPaymentMethod:2,withArea:3,withoutArea:1},'summary');
eq(api.riderAreaGroups(rows).map(group=>[group.state,group.total]),[['FL',2],['TX',1],['unknown',1]],'area groups');
eq(api.riderPreferredPayment(rows[0]),'Visa •••• 4242','preferred payment');
eq(api.riderPreferredPayment(rows[2]),'Apple Pay','fallback payment label');
if(api.riderDateTimeLabel(rows[0],'registration')==='Sin dato'||!api.riderDateTimeLabel(rows[0],'registration').includes('2026'))throw new Error('full date missing');
eq(api.riderDateTimeLabel({created_at:'bad'},'registration'),'Sin dato','invalid date');
store.set('cruise_riders_filters_v1',JSON.stringify({tab:'aprobados',query:'miami',limit:120,filters:{origin:'web',states:['FL'],dateField:'last_trip',dateFrom:'2026-01-01T10:30'}}));
const restored=api.readRidersView();
eq({tab:restored.tab,query:restored.query,limit:restored.limit,origin:restored.filters.origin,states:restored.filters.states,dateField:restored.filters.dateField,dateFrom:restored.filters.dateFrom},{tab:'aprobados',query:'miami',limit:120,origin:'web',states:['FL'],dateField:'last_trip',dateFrom:'2026-01-01T10:30'},'view round trip');
store.set('cruise_riders_filters_v1','{broken');
const fallback=api.readRidersView();
eq({tab:fallback.tab,limit:fallback.limit,origin:fallback.filters.origin},{tab:'todos',limit:60,origin:'all'},'invalid storage fallback');
console.log(JSON.stringify({summary,filters:'ok',restored}));
''';
    final result = Process.runSync('node', ['-e', script, people.path]);
    expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
    expect('${result.stdout}', contains('"filters":"ok"'));
  });

  test('real backend mapper and roster merge preserve existing people', () {
    final script = r'''
const fs=require('fs'),vm=require('vm');
const people=fs.readFileSync(process.argv[1],'utf8'),entry=fs.readFileSync(process.argv[2],'utf8');
const ps=people.indexOf('const riderFilterDefaults='),pe=people.indexOf('/*! guard-pin panel_drivers_waitlist_filter_guard_test',ps);
const helpers=people.slice(ps,pe);
const ms=entry.indexOf('function riderBackendPaymentMethod'),me=entry.indexOf('function qs(',ms);
if(ms<0||me<0||me<=ms)throw new Error('backend mapper block not found');
const mapper=entry.slice(ms,me);
const sandbox={console,module:{exports:{}},exports:{},window:{sessionStorage:{getItem:()=>null}}};
vm.runInNewContext(`const de=60,RIDERS_VIEW_KEY="x",be=[];${helpers};module.exports={mergeRiderInsightPeople};`,sandbox);
const {mergeRiderInsightPeople}=sandbox.module.exports;
vm.runInNewContext(`const I=e=>typeof e==='number'&&Number.isFinite(e)?Math.trunc(e):null,c=e=>typeof e==='string'?e.trim():null,y=e=>typeof e==='string'?e.trim():'',P=e=>c(e),S=e=>e?new Date(e):null;${mapper};module.exports={Bs,Vs};`,sandbox);
const {Bs,Vs}=sandbox.module.exports;
const raw={id:77,first_name:'Backend',last_name:'Only',phone:'555',email:null,role:'rider',verification_status:'approved',verified:true,has_documents:true,document_statuses:['approved'],registration_source:'web',created_at:'2026-01-01T00:00:00Z',last_active_at:'2026-01-04T00:00:00Z',last_trip_at:'2026-01-03T00:00:00Z',payment_methods:[{method_type:'stripe_card',display_name:'Visa •••• 4242',is_default:true,stripe_pm_id:'must-not-map'}],payment_types:['stripe_card'],default_payment_method:{method_type:'stripe_card',display_name:'Visa •••• 4242',is_default:true},area:{city:'Miami',state:'FL',sector_id:'zone-fl',source:'last_trip',city_key:'FL|Miami'}};
const mapped=Bs(raw);
if(mapped.clientId!=='sql_77'||mapped.registrationSource!=='web'||mapped.verified!==true||mapped.hasDocuments!==true||mapped.area.cityKey!=='FL|Miami'||mapped.lastActiveAt===null||mapped.paymentMethods.length!==1||mapped.paymentMethods[0].stripe_pm_id!==undefined)throw new Error('mapper lost or leaked fields');
const existing={clientId:'firestore-doc',sqliteId:77,firstName:'Existing',lastName:'Person',phone:'555',email:null,photoUrl:null,role:'rider',platform:null,hasPassword:false,totalTrips:0,totalSpent:0,rating:null,lastTripAt:null,lastActiveAt:null,createdAt:null,lastUpdated:null,status:'active',source:null,paymentMethod:null,cardLast4:null,cardBrand:null,cardNumber:null,cardExpiry:null,bankName:null,username:null,licenseUrl:null,documentUrl:null,idPhotoUrl:null,selfieUrl:null,idDocumentType:null,verificationStatus:'pending',isOnline:false};
const merged=mergeRiderInsightPeople([existing],[raw],{fromBackend:Bs,fillFrom:Vs,compare:null});
if(merged.length!==1||merged[0].clientId!=='firestore-doc'||merged[0].firstName!=='Existing'||merged[0].registrationSource!=='web'||merged[0].area.cityKey!=='FL|Miami')throw new Error('existing person was not enriched safely');
const appended=mergeRiderInsightPeople([existing],[{...raw,id:78,clientId:'sql_78'}],{fromBackend:Bs,fillFrom:Vs,compare:null});
if(appended.length!==2||appended[1].clientId!=='sql_78')throw new Error('missing PG rider was not appended');
console.log(JSON.stringify({mapped:mapped.clientId,merged:merged.length,appended:appended.length}));
''';
    final result = Process.runSync(
        'node', ['-e', script, people.path, entry.path]);
    expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
    expect('${result.stdout}', contains('"appended":2'));
  });

  test('all modified rider modules parse', () {
    for (final file in [people, entry, users]) {
      final result = Process.runSync('node', ['--check', file.path]);
      expect(result.exitCode, 0, reason: '${file.path}\n${result.stderr}');
    }
  });
}
