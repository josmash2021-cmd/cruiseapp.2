// firestore.rules against the emulator (run.sh). RULES=<file> tests another
// file. One case per client access in the 2026-11-03 inventory (the app's
// rows are numbered as in that inventory) plus the attacks the hardening
// closes.
import { readFileSync } from 'node:fs';
import { after, before, beforeEach, describe, test } from 'node:test';
import {
  assertFails, assertSucceeds, initializeTestEnvironment,
} from '@firebase/rules-unit-testing';
import {
  addDoc, collection, deleteDoc, deleteField, doc, getDoc, getDocs, limit,
  orderBy, query, setDoc, updateDoc, where, writeBatch,
} from 'firebase/firestore';

const RULES = process.env.RULES || '../../firestore.rules';
let env;

// Rider 9 rides trip 1 with driver 3. Driver 4 was granted trip 2 (the
// accept mirror has not written driverId yet). User 5 is a stranger rider;
// driver 6 an approved driver with no relation to any trip.
const RIDER = 'user_9';
const DRIVER = 'user_3';
const GRANTED = 'user_4';
const STRANGER = 'user_5';
const OTHER_DRIVER = 'user_6';
const ADMIN = 'panelOperatorUid';

before(async () => {
  env = await initializeTestEnvironment({
    projectId: 'demo-cruise-rules',
    firestore: { rules: readFileSync(RULES, 'utf8') },
  });
});
after(async () => { await env?.cleanup(); });

beforeEach(async () => {
  await env.clearFirestore();
  await env.withSecurityRulesDisabled(async (ctx) => {
    const db = ctx.firestore();
    const seed = (path, data) => setDoc(doc(db, path), data);
    await seed(`admins/${ADMIN}`, { email: 'ops@cruise.test', role: 'dispatcher' });
    await seed('trips/sql_1', {
      passengerId: 'sql_9', passengerName: 'Ana R', passengerPhone: '+15550009',
      driverId: '3', driver_id: 3, status: 'driver_en_route', fare: 30,
      pickup_pin: 'KMFE', sqliteId: 1, accessUids: [DRIVER],
    });
    await seed('trips/sql_2', {
      passengerId: 'sql_5', driverId: null, status: 'requested', fare: 20,
      sqliteId: 2, accessUids: [GRANTED],
    });
    await seed('trips/sql_7', { // an active trip from before the grant existed
      passengerId: 'sql_8', driverId: 3, status: 'arrived', sqliteId: 7,
    });
    await seed('users/sql_9', { photoUrl: 'https://p/9.jpg', status: 'active', role: 'rider' });
    await seed('users/sql_3', { photoUrl: 'https://p/3.jpg', role: 'driver' });
    await seed('users/sql_9/inbox_chats/sql_1', { createdAt: 1, expiresAt: 0 });
    await seed('clients/sql_9', { sqliteId: 9, status: 'active', phone: '+15550009' });
    await seed('clients/autoId123', { sqliteId: 5, status: 'active' });
    await seed('drivers/sql_3', { sqliteId: 3, status: 'active', isApproved: true, approvalStatus: 'approved' });
    await seed('drivers/sql_6', { sqliteId: 6, status: 'active', isApproved: true });
    await seed('drivers/sql_4', { sqliteId: 4, status: 'pending', isApproved: false });
    await seed('verifications/sql_3', { userId: 3, status: 'approved' });
    await seed('verifications/sql_9', { userId: 9, status: 'pending' });
    await seed('config/serviceZones', { activeStates: ['AL', 'FL'] });
    await seed('support_chats/chat_1', { userId: 9 });
    await seed('admin_alerts/a1', { read: false });
  });
});

const db = (uid) => (uid
  ? env.authenticatedContext(uid).firestore()
  : env.unauthenticatedContext().firestore());
const ref = (uid, path) => doc(db(uid), path);

describe('rider app', () => {
  test('rows 1-6: reads his own trip, and one not mirrored yet', async () => {
    await assertSucceeds(getDoc(ref(RIDER, 'trips/sql_1')));
    await assertSucceeds(getDoc(ref(RIDER, 'trips/sql_999')));
  });
  test('row 7: answers a route proposal on his trip, nothing else', async () => {
    await assertSucceeds(setDoc(ref(RIDER, 'trips/sql_1'),
      { pending_route_change: { proposed_by: 'driver', status: 'declined' } }, { merge: true }));
    await assertSucceeds(setDoc(ref(RIDER, 'trips/sql_1'),
      { pending_route_change: deleteField() }, { merge: true }));
    await assertFails(updateDoc(ref(RIDER, 'trips/sql_1'), { status: 'cancelled' }));
    await assertFails(updateDoc(ref(RIDER, 'trips/sql_1'), { fare: 1 }));
  });
  test('rows 21-23: his inbox chats (write, list, batch delete)', async () => {
    await assertSucceeds(setDoc(ref(RIDER, 'users/sql_9/inbox_chats/sql_2'), { createdAt: 2 }));
    const q = query(collection(db(RIDER), 'users/sql_9/inbox_chats'),
      orderBy('createdAt', 'desc'), limit(30));
    await assertSucceeds(getDocs(q));
    await assertSucceeds(getDocs(query(collection(db(RIDER), 'users/sql_9/inbox_chats'),
      where('expiresAt', '<', 5))));
    const rider = db(RIDER);
    const b = writeBatch(rider);
    b.delete(doc(rider, 'users/sql_9/inbox_chats/sql_1'));
    await assertSucceeds(b.commit());
  });
  test('rows 24-25, 28-29: his notification prefs and photo', async () => {
    await assertSucceeds(getDoc(ref(RIDER, 'users/sql_9')));
    await assertSucceeds(setDoc(ref(RIDER, 'users/sql_9'),
      { notificationPrefs: { promos: false } }, { merge: true }));
    await assertSucceeds(setDoc(ref(RIDER, 'users/sql_9'),
      { photoUrl: 'https://p/9b.jpg', photoUpdatedAt: 1 }, { merge: true }));
  });
  test('rows 26, 30: the other party\'s photo, and a doc that is not there', async () => {
    await assertSucceeds(getDoc(ref(RIDER, 'users/sql_3')));
    await assertSucceeds(getDoc(ref(RIDER, 'users/3')));
  });
  test('row 32: finds his client doc by sqliteId and sets its photo', async () => {
    const q = query(collection(db(RIDER), 'clients'), where('sqliteId', '==', 9), limit(1));
    await assertSucceeds(getDocs(q));
    await assertSucceeds(updateDoc(ref(RIDER, 'clients/sql_9'), { photoUrl: 'https://p/x.jpg' }));
  });
  test('rows 36-38: his verification (by id and by userId query)', async () => {
    await assertSucceeds(getDoc(ref(RIDER, 'verifications/sql_9')));
    await assertSucceeds(getDocs(query(collection(db(RIDER), 'verifications'),
      where('userId', '==', 9))));
  });
  test('rows 39-41: global config', async () => {
    await assertSucceeds(getDoc(ref(RIDER, 'config/serviceZones')));
  });
});

describe('driver app', () => {
  test('row 17: his trip, and the one granted before the mirror', async () => {
    await assertSucceeds(getDoc(ref(DRIVER, 'trips/sql_1')));
    await assertSucceeds(getDoc(ref(GRANTED, 'trips/sql_2')));
    await assertSucceeds(getDoc(ref(DRIVER, 'trips/sql_7')), 'int driverId, no accessUids');
  });
  test('rows 8-11, 16, 18-19: the writes he makes on his trip', async () => {
    const t = ref(DRIVER, 'trips/sql_1');
    await assertSucceeds(updateDoc(t, { driverLat: 1, driverLng: 2, driverBearing: 3 }));
    await assertSucceeds(setDoc(t, { status: 'arrived', arrivedAt: 1 }, { merge: true }));
    await assertSucceeds(setDoc(t, {
      pending_route_change: { type: 'stop', lat: 1, lng: 2, label: 'x', proposed_by: 'driver', status: 'proposed' },
    }, { merge: true }));
    await assertSucceeds(updateDoc(t, { driverLat: deleteField(), driverLng: deleteField() }));
    await assertSucceeds(updateDoc(t, { status: 'completed', completedAt: 1 }));
    await assertSucceeds(updateDoc(t, { riderRating: 5, riderRatedAt: 1 }));
  });
  test('row 9: right after accept he writes his card on the granted doc', async () => {
    await assertSucceeds(setDoc(ref(GRANTED, 'trips/sql_2'), {
      status: 'driver_en_route', driver_id: 4, driverId: '4', driver_name: 'J',
      driverName: 'J', driverPhone: '+1', acceptedAt: 1,
    }, { merge: true }));
  });
  test('row 10: after a release he can still read and write the release', async () => {
    await env.withSecurityRulesDisabled((ctx) => updateDoc(
      doc(ctx.firestore(), 'trips/sql_1'), { driverId: null, driver_id: null, status: 'requested' }));
    await assertSucceeds(getDoc(ref(DRIVER, 'trips/sql_1')));
    await assertSucceeds(setDoc(ref(DRIVER, 'trips/sql_1'),
      { status: 'requested', driverId: null }, { merge: true }));
  });
  test('row 13 (builds < 757): an approved driver may still list active trips', async () => {
    const q = query(collection(db(DRIVER), 'trips'),
      where('status', 'in', ['accepted', 'driver_en_route', 'arrived', 'in_trip']), limit(25));
    await assertSucceeds(getDocs(q));
  });
  test('row 20: files a report on his trip', async () => {
    await assertSucceeds(addDoc(collection(db(DRIVER), 'trips/sql_1/reports'),
      { type: 'rider', reason: 'x', tripId: 1, driverId: DRIVER }));
  });
  test('row 27: the rider\'s photo', async () => {
    await assertSucceeds(getDoc(ref(DRIVER, 'users/sql_9')));
  });
  test('rows 32-35: his own driver doc and verification', async () => {
    await assertSucceeds(getDoc(ref(DRIVER, 'drivers/sql_3')));
    await assertSucceeds(getDocs(query(collection(db(DRIVER), 'drivers'),
      where('sqliteId', '==', 3), limit(1))));
    await assertSucceeds(updateDoc(ref(DRIVER, 'drivers/sql_3'), { photoUrl: 'https://p/3b.jpg' }));
    await assertSucceeds(getDoc(ref(DRIVER, 'verifications/sql_3')));
    await assertSucceeds(getDoc(ref(GRANTED, 'verifications/sql_4')), 'not there yet');
  });
  test('config/scheduled_board', async () => {
    await assertSucceeds(getDoc(ref(DRIVER, 'config/scheduled_board')));
  });
});

describe('panel operator (admins/{uid})', () => {
  test('reads and writes everything it uses', async () => {
    const a = db(ADMIN);
    await assertSucceeds(getDocs(query(collection(a, 'trips'), where('status', '==', 'completed'))));
    await assertSucceeds(updateDoc(doc(a, 'trips/sql_1'), { dispatchOfferedDriverId: 6 }));
    await assertSucceeds(getDocs(collection(a, 'drivers')));
    await assertSucceeds(getDocs(collection(a, 'clients')));
    await assertSucceeds(getDocs(query(collection(a, 'users'), where('role', '==', 'rider'))));
    await assertSucceeds(getDocs(collection(a, 'verifications')));
    await assertSucceeds(setDoc(doc(a, 'verifications/sql_9'), { status: 'approved' }, { merge: true }));
    await assertSucceeds(updateDoc(doc(a, 'drivers/sql_3'), { status: 'blocked' }));
    await assertSucceeds(addDoc(collection(a, 'clients'), { firstName: 'X' }));
    await assertSucceeds(getDocs(collection(a, 'support_chats')));
    await assertSucceeds(getDocs(collection(a, 'admin_alerts')));
    await assertSucceeds(addDoc(collection(a, 'audit_log'), { action: 'login' }));
    await assertSucceeds(addDoc(collection(a, 'drivers/sql_3/notifications'), { title: 't' }));
    await assertSucceeds(setDoc(doc(a, 'config/pricing'), { base_fare: 3 }));
    await assertSucceeds(addDoc(collection(a, 'dispatch_driver_chats/3/messages'), { text: 'hi' }));
    await assertSucceeds(deleteDoc(doc(a, 'trips/sql_7')));
  });
  test('audit_log stays append-only', async () => {
    const a = db(ADMIN);
    const r = await addDoc(collection(a, 'audit_log'), { action: 'x' });
    await assertFails(updateDoc(r, { action: 'y' }));
    await assertFails(deleteDoc(r));
  });
});

describe('what the hardening closes', () => {
  test('a stranger cannot read, list or write someone else\'s trip', async () => {
    await assertFails(getDoc(ref(STRANGER, 'trips/sql_1')));
    await assertFails(getDocs(collection(db(STRANGER), 'trips')));
    await assertFails(updateDoc(ref(STRANGER, 'trips/sql_1'), { status: 'cancelled' }));
    await assertFails(setDoc(ref(STRANGER, 'trips/sql_1'), { status: 'cancelled' }, { merge: true }));
  });
  test('an approved driver not on the trip cannot open it', async () => {
    await assertFails(getDoc(ref(OTHER_DRIVER, 'trips/sql_1')));
    await assertFails(updateDoc(ref(OTHER_DRIVER, 'trips/sql_1'), { status: 'cancelled' }));
  });
  test('a driver applicant cannot list trips (only approved drivers, phase 1)', async () => {
    await assertFails(getDocs(collection(db(GRANTED), 'trips')));
  });
  test('the trip driver cannot rewrite who the trip belongs to, the price or the code', async () => {
    for (const [k, v] of [['passengerId', 'sql_3'], ['accessUids', [DRIVER, STRANGER]],
      ['fare', 999], ['pickup_pin', 'AAAA'], ['passengerPhone', '+1']]) {
      await assertFails(updateDoc(ref(DRIVER, 'trips/sql_1'), { [k]: v }), k);
    }
  });
  test('nobody but the backend creates a trip doc', async () => {
    await assertFails(setDoc(ref(RIDER, 'trips/sql_50'), { passengerId: 'sql_9', passengerName: 'A',
      pickupAddress: 'a', dropoffAddress: 'b' }));
  });
  test('nobody blocks, unblocks or approves an account from the app (#61)', async () => {
    const attempts = {
      'stranger blocks a driver': () => updateDoc(ref(STRANGER, 'drivers/sql_3'), { status: 'blocked' }),
      'applicant activates himself': () => updateDoc(ref(GRANTED, 'drivers/sql_4'), { status: 'active' }),
      'applicant approves himself': () => updateDoc(ref(GRANTED, 'drivers/sql_4'), { isApproved: true }),
      'stranger blocks a rider': () => updateDoc(ref(STRANGER, 'clients/sql_9'), { status: 'blocked' }),
      'applicant creates an approval': () => setDoc(ref(GRANTED, 'verifications/sql_4'), { userId: 4, status: 'approved' }),
      'rider approves himself': () => updateDoc(ref(RIDER, 'verifications/sql_9'), { status: 'approved' }),
      'stranger sets a photo': () => setDoc(ref(STRANGER, 'users/sql_9'), { photoUrl: 'https://evil' }, { merge: true }),
      'rider sets his users status': () => setDoc(ref(RIDER, 'users/sql_9'), { status: 'approved' }, { merge: true }),
    };
    const passed = [];
    for (const [name, attempt] of Object.entries(attempts)) {
      try { await assertFails(attempt()); } catch { passed.push(name); }
    }
    if (passed.length) throw new Error('allowed: ' + passed.join(', '));
  });
  test('profiles are not readable by others', async () => {
    await assertFails(getDoc(ref(STRANGER, 'clients/sql_9')));
    await assertFails(getDoc(ref(STRANGER, 'drivers/sql_3')));
    await assertFails(getDocs(collection(db(STRANGER), 'clients')));
    await assertFails(getDocs(query(collection(db(STRANGER), 'clients'), where('sqliteId', '==', 9))));
    await assertFails(getDoc(ref(STRANGER, 'verifications/sql_3')));
    await assertFails(getDocs(collection(db(STRANGER), 'verifications')));
    await assertFails(getDocs(collection(db(STRANGER), 'users')));
    await assertFails(getDocs(collection(db(STRANGER), 'users/sql_9/inbox_chats')));
  });
  test('panel-only collections are closed to app accounts', async () => {
    for (const p of ['support_chats/chat_1', 'admin_alerts/a1', 'payouts/p', 'promo_codes/x',
      'dispatch_chat_rooms/dispatch_9', 'trip_offers/o', 'driver_sessions/s',
      'account_appeals/a', 'audit_log/l', 'dispatch_notifications/n', 'scheduled_rides/r']) {
      await assertFails(getDoc(ref(RIDER, p)), p);
    }
    await assertFails(addDoc(collection(db(RIDER), 'admin_alerts'), { x: 1 }));
    await assertFails(addDoc(collection(db(RIDER), 'audit_log'), { x: 1 }));
    await assertFails(setDoc(ref(RIDER, 'config/pricing'), { base_fare: 0 }));
  });
  test('signed out: nothing', async () => {
    await assertFails(getDoc(ref(null, 'trips/sql_1')));
    await assertFails(getDoc(ref(null, 'users/sql_9')));
    await assertFails(getDoc(ref(null, 'config/serviceZones')));
  });
});
