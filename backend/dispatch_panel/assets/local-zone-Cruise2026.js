/*! guard-pin panel_local_zone_guard_test: la hora de una reserva es la del lugar de recogida (owner 2026-11-07: "alabama y florida deben tener sus propios horarios al igual que para cualquier estado futuro") - chunk escrito a mano (CLAUDE.md #30). El servidor nombra la zona por coordenadas (GET /admin/geo/time-zone, sin costo); aquí se convierte y se muestra. */
import{r as React}from"./vendor-react-DprhJQz-.js";
import{W as apiGet}from"./index-CuQT_62K.js";

const MONTHS=["ene","feb","mar","abr","may","jun","jul","ago","sept","oct","nov","dic"];
const cache=new Map();

function okPoint(lat,lng){return Number.isFinite(lat)&&Number.isFinite(lng)&&Math.abs(lat)<=90&&Math.abs(lng)<=180&&!(lat===0&&lng===0)}
function keyOf(lat,lng){return`${lat.toFixed(4)},${lng.toFixed(4)}`}
function validZone(z){try{new Intl.DateTimeFormat("en-US",{timeZone:z});return true}catch(_){return false}}

// While the server answers (or if it cannot): the rule of the first two
// markets, Birmingham (Central) west of -85°, South Florida (Eastern) east.
function guessZone(lng){return Number.isFinite(lng)&&lng< -85?{zone:"America/Chicago",label:"hora del centro",guessed:true}:{zone:"America/New_York",label:"hora del este",guessed:true}}

function peekZone(lat,lng){if(!okPoint(lat,lng))return null;const v=cache.get(keyOf(lat,lng));return v&&typeof v.then!=="function"?v:null}

function loadZone(lat,lng){
 const k=keyOf(lat,lng),hit=cache.get(k);if(hit)return Promise.resolve(hit);
 const pr=apiGet("/admin/geo/time-zone",{query:{lat,lng},retry:{maxAttempts:2},timeoutMs:6000})
  .then(r=>{const z=r&&typeof r.zone==="string"&&r.zone!==""&&validZone(r.zone)?{zone:r.zone,label:typeof r.label==="string"?r.label:""}:guessZone(lng);cache.set(k,z);return z})
  .catch(()=>{cache.delete(k);return guessZone(lng)});
 cache.set(k,pr);return pr}

// null while it is not known (no point yet, or the first answer is on its way).
function useLocalZone(lat,lng){
 const ok=okPoint(lat,lng),k=ok?keyOf(lat,lng):"";
 const[z,setZ]=React.useState(()=>peekZone(lat,lng));
 React.useEffect(()=>{if(!ok){setZ(null);return}const now=peekZone(lat,lng);if(now){setZ(now);return}
  let live=true;setZ(null);loadZone(lat,lng).then(v=>{if(live)setZ(v)});return()=>{live=false}},[k]);
 return z}

function zoneOffsetMs(ms,zone){const p=Object.fromEntries(new Intl.DateTimeFormat("en-US",{timeZone:zone,hourCycle:"h23",year:"numeric",month:"2-digit",day:"2-digit",hour:"2-digit",minute:"2-digit",second:"2-digit"}).formatToParts(new Date(ms)).map(x=>[x.type,x.value]));return Date.UTC(+p.year,+p.month-1,+p.day,+p.hour,+p.minute,+p.second)-ms}

// "2026-11-20T15:20" written in `zone` → the real instant (ISO, UTC).
function wallToIso(v,zone){const mt=/^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2})/.exec(v||"");if(!mt||!zone||!validZone(zone))return null;const guess=Date.UTC(+mt[1],+mt[2]-1,+mt[3],+mt[4],+mt[5]);let ms=guess-zoneOffsetMs(guess,zone);const o2=zoneOffsetMs(ms,zone);if(guess-o2!==ms)ms=guess-o2;return new Date(ms).toISOString()}

// "CST" / "CDT" / "EST"… for that instant in that zone.
function zoneAbbr(date,zone){try{const d=date instanceof Date?date:new Date(date);const p=new Intl.DateTimeFormat("en-US",{timeZone:zone,timeZoneName:"short"}).formatToParts(Number.isNaN(d.getTime())?new Date():d).find(x=>x.type==="timeZoneName");return p?p.value:""}catch(_){return""}}

// "20 nov 2026 · 3:20 PM CST" in the pickup's zone.
function formatInZone(date,zone){const d=date instanceof Date?date:new Date(date);if(Number.isNaN(d.getTime()))return"";
 const p=Object.fromEntries(new Intl.DateTimeFormat("en-US",{timeZone:zone,year:"numeric",month:"numeric",day:"numeric",hour:"numeric",minute:"2-digit",hour12:true,timeZoneName:"short"}).formatToParts(d).map(x=>[x.type,x.value]));
 return`${+p.day} ${MONTHS[+p.month-1]} ${p.year} · ${p.hour}:${p.minute} ${p.dayPeriod} ${p.timeZoneName}`}

function ZoneTime({date,lat,lng}){const z=useLocalZone(lat,lng);return formatInZone(date,(z||guessZone(lng)).zone)}

export{useLocalZone,loadZone,peekZone,guessZone,wallToIso,zoneAbbr,formatInZone,ZoneTime};
