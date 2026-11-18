/*! guard-pin panel_fleet_map: Mapa en vivo estilo Lyft (dueño 2026-11-17, dibujo https://claude.ai/artifact/77TcMSKxdi3vVEkis3puiw) - chunk escrito a mano, sin fuente React (CLAUDE.md #30). Datos: GET /admin/fleet/map cada 8 s; las flechas se mueven con /admin/drivers/live (como el Inicio). Flecha por estado: dorada libre, azul yendo a recoger, verde en viaje, gris sin señal. Pasajeros NUNCA como puntos (#67): la demanda son las celdas de ~400 m. Si este chunk falla vuelve el mapa de antes (index-OW_RZUQk.js). */
import{r as React,j as J,y as useNavigate}from"./vendor-react-DprhJQz-.js";
import{m as mapboxgl}from"./vendor-mapbox-ComAnvan.js";
import{N as navyStyle,a as applyNavyGold,r as refineRoads,h as hideTraffic}from"./mapNavyGold-CiIxy5Vj.js";
import{m as getMapboxToken}from"./mapboxToken-DDoCRQix.js";
import{W as apiGet,L as apiPost}from"./index-CuQT_62K.js";
import{fetchStreetRoute}from"./trip-route-map-Cruise2026.js";
import{Modal,CallModal,OfferModal,ensureCss as ensureProfileCss}from"./user-profile-Cruise2026.js";

function el(type,props,...kids){
 const p=Object.assign({},props||{});const key=p.key;delete p.key;
 const c=kids.filter(k=>k!==undefined);
 if(c.length===1)p.children=c[0];else if(c.length>1)p.children=c;
 return c.length>1?J.jsxs(type,p,key):J.jsx(type,p,key);
}

const GOLD="#E8C547",BLUE="#4C9BFF",GREEN="#3DDC84",GRAY="#7C7A86",RED="#FF6B5E",AMBER="#E8A53A";
const POLL_MS=8000,STALE_MS=180000,LIVE_FRESH_MS=20000,ROUTE_REFRESH_MS=30000,ROUTE_MOVE_M=150;
const EMPTY={type:"FeatureCollection",features:[]};
const AREAS={AL:{name:"Alabama",short:"AL",center:[-86.80,33.50],zoom:9.6},FL:{name:"Florida",short:"FL",center:[-80.20,26.10],zoom:9.4}};
const ALL_VIEW={center:[-84.2,29.6],zoom:5.4};
const ORDER=["pickup","free","ontrip","quiet"];
const STATUS={
 free:{label:"Libre",plural:"Libres",short:"Libres",color:GOLD},
 pickup:{label:"A recoger",plural:"A recoger",short:"Recoger",color:BLUE},
 ontrip:{label:"En viaje",plural:"En viaje",short:"Viaje",color:GREEN},
 quiet:{label:"Sin señal",plural:"Sin señal",short:"Sin señal",color:GRAY},
};
const ARROW="M12 2.5 L19 20.5 L12 16.6 L5 20.5 Z";

const CSS=`
.fm-wrap{width:100%;container-type:inline-size;container-name:fm}
html.fm-full main>.max-w-\\[1400px\\]{max-width:none;padding:0}
.fm-page{position:relative;overflow:hidden;background:#101318;color:#F4F4F5;font-family:Inter,system-ui,-apple-system,Segoe UI,sans-serif;height:calc(100dvh - 5.5rem);min-height:520px}
.fm-canvas{position:absolute;inset:0}
.fm-f{position:absolute;background:rgba(28,28,36,.95);border:1px solid rgba(255,255,255,.12);border-radius:16px;box-shadow:0 14px 34px rgba(0,0,0,.45)}
.fm-top{position:absolute;left:16px;right:16px;top:14px;display:flex;align-items:center;gap:10px;z-index:4;pointer-events:none}
.fm-top>*{pointer-events:auto}
.fm-title{display:flex;align-items:center;gap:8px;font-weight:700;font-size:15px;background:rgba(28,28,36,.95);border:1px solid rgba(255,255,255,.12);border-radius:12px;height:40px;padding:0 12px;white-space:nowrap}
.fm-live{width:8px;height:8px;border-radius:50%;background:${GREEN};box-shadow:0 0 0 4px rgba(61,220,132,.18)}
.fm-live.off{background:${GRAY};box-shadow:none}
.fm-seg{display:flex;background:rgba(28,28,36,.95);border:1px solid rgba(255,255,255,.12);border-radius:12px;padding:3px;height:40px;box-sizing:border-box}
.fm-seg button{border:0;background:transparent;padding:0 12px;display:flex;align-items:center;gap:6px;border-radius:9px;font-family:inherit;font-size:12.5px;font-weight:600;color:#9A98A6;cursor:pointer;white-space:nowrap}
.fm-seg button b{color:#F4F4F5;font-weight:700}
.fm-seg button.on{background:${GOLD};color:#0B0B0F}
.fm-seg button.on b{color:#0B0B0F}
.fm-short{display:none}
.fm-search{flex:1;min-width:0;max-width:330px;height:40px;display:flex;align-items:center;gap:8px;background:rgba(28,28,36,.95);border:1px solid rgba(255,255,255,.12);border-radius:12px;padding:0 12px;box-sizing:border-box}
.fm-search:focus-within{border-color:rgba(232,197,71,.55)}
.fm-search span{color:#6E6C78;font-size:15px}
.fm-search input{flex:1;min-width:0;border:0;outline:0;background:transparent;color:#F4F4F5;font-family:inherit;font-size:13px}
.fm-search input::placeholder{color:#6E6C78}
.fm-layers{margin-left:auto;display:flex;gap:6px;flex-wrap:wrap;justify-content:flex-end}
.fm-chip{height:32px;display:flex;align-items:center;gap:6px;padding:0 11px;border-radius:999px;background:rgba(28,28,36,.95);border:1px solid rgba(255,255,255,.12);font-family:inherit;font-size:12px;font-weight:600;color:#F4F4F5;cursor:pointer}
.fm-chip i{width:8px;height:8px;border-radius:50%}
.fm-chip.off{color:#6E6C78}
.fm-chip.off i{opacity:.35}

.fm-list{left:16px;top:78px;bottom:16px;width:330px;display:flex;flex-direction:column;overflow:hidden;z-index:2}
.fm-lh{padding:14px 14px 10px;display:flex;flex-direction:column;gap:10px;border-bottom:1px solid rgba(255,255,255,.07)}
.fm-lt{display:flex;justify-content:space-between;align-items:baseline;gap:8px}
.fm-lt b{font-size:15px}
.fm-lt span{font-size:12px;color:#9A98A6}
.fm-stat{display:grid;grid-template-columns:repeat(4,1fr);gap:6px}
.fm-stat button{background:#23232D;border-radius:10px;padding:7px 6px;display:flex;flex-direction:column;gap:1px;border:1px solid transparent;text-align:left;font-family:inherit;color:#F4F4F5;cursor:pointer;min-width:0}
.fm-stat button.on{border-color:rgba(232,197,71,.55)}
.fm-stat b{font-size:16px}
.fm-stat small{font-size:10px;color:#9A98A6;display:flex;align-items:center;gap:4px;white-space:nowrap;overflow:hidden}
.fm-stat small i{width:7px;height:7px;border-radius:50%;flex:none}
.fm-rows{flex:1;overflow-y:auto;padding:6px;min-height:0}
.fm-r{display:flex;gap:10px;align-items:center;padding:9px 8px;border-radius:12px;cursor:pointer;border:0;background:transparent;width:100%;text-align:left;font-family:inherit;color:#F4F4F5}
.fm-r:hover{background:rgba(255,255,255,.04)}
.fm-r.sel{background:rgba(232,197,71,.08);outline:1px solid rgba(232,197,71,.35)}
.fm-r.quiet{opacity:.62}
.fm-av{width:36px;height:36px;border-radius:50%;background:#34323F;display:grid;place-items:center;font-weight:700;font-size:12px;position:relative;flex:none;overflow:visible;color:#F4F4F5}
.fm-av img{width:100%;height:100%;border-radius:50%;object-fit:cover}
.fm-av i{position:absolute;right:-1px;bottom:-1px;width:11px;height:11px;border-radius:50%;border:2px solid #1C1C24}
.fm-mid{flex:1;min-width:0}
.fm-mid b{font-size:13px;display:block;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.fm-mid small{display:block;color:#9A98A6;font-size:11.5px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.fm-st{font-size:11px;font-weight:600;text-align:right;white-space:nowrap}
.fm-st small{display:block;color:#6E6C78;font-weight:500}
.fm-empty{padding:22px 14px;color:#9A98A6;font-size:13px;display:flex;flex-direction:column;gap:4px}
.fm-empty b{color:#F4F4F5;font-size:14px}
.fm-foot{border-top:1px solid rgba(255,255,255,.07);padding:11px 14px;display:flex;flex-direction:column;gap:6px;font-size:12px}
.fm-foot div{display:flex;justify-content:space-between;gap:8px;color:#9A98A6}
.fm-foot b{color:#F4F4F5}
.fm-foot b.red{color:${RED};cursor:pointer}

.fm-card{right:16px;top:78px;width:340px;max-height:calc(100% - 160px);overflow-y:auto;padding:16px;display:flex;flex-direction:column;gap:12px;z-index:3;box-sizing:border-box}
.fm-ch{display:flex;gap:12px;align-items:center}
.fm-ch .fm-av{width:48px;height:48px;font-size:15px}
.fm-ch b{font-size:16px;display:block}
.fm-ch small{color:#9A98A6;font-size:12px;display:block}
.fm-x{margin-left:auto;align-self:flex-start;border:0;background:transparent;color:#9A98A6;font-size:20px;line-height:1;cursor:pointer;padding:2px 4px}
.fm-status{display:flex;align-items:center;gap:8px;border-radius:12px;padding:9px 11px;font-size:13px;font-weight:600}
.fm-status i{width:8px;height:8px;border-radius:50%;flex:none}
.fm-warn{font-size:12px;color:#F2B8B5}
.fm-rail{display:flex;flex-direction:column;gap:8px;padding-left:2px}
.fm-rail div{display:flex;gap:10px;align-items:flex-start;font-size:12.5px}
.fm-rail small{display:block;color:#9A98A6;font-size:11px}
.fm-ring{width:12px;height:12px;border-radius:50%;border:2.5px solid ${GOLD};flex:none;margin-top:2px;box-sizing:border-box}
.fm-ring.w{border-color:#fff}
.fm-kv{display:grid;grid-template-columns:1fr 1fr;gap:6px}
.fm-kv div{background:#23232D;border-radius:10px;padding:7px 9px;font-size:11px;color:#9A98A6}
.fm-kv b{display:block;color:#F4F4F5;font-size:13px}
.fm-btns{display:grid;grid-template-columns:repeat(4,1fr);gap:6px}
.fm-btns button{height:34px;border-radius:10px;border:1px solid rgba(255,255,255,.14);background:transparent;color:#F4F4F5;font-family:inherit;font-size:12px;font-weight:600;cursor:pointer;padding:0 4px;white-space:nowrap}
.fm-btns button:hover{border-color:rgba(255,255,255,.3)}
.fm-btns button.g{background:${GOLD};color:#0B0B0F;border-color:${GOLD}}
.fm-open{border:0;background:transparent;padding:0;font-family:inherit;font-size:12.5px;color:${GOLD};font-weight:600;cursor:pointer;text-align:left}

.fm-legend{left:362px;bottom:16px;padding:8px 12px;display:flex;gap:14px;align-items:center;font-size:11.5px;color:#9A98A6;border-radius:12px;z-index:2;flex-wrap:wrap}
.fm-legend span{display:flex;align-items:center;gap:6px;white-space:nowrap}
.fm-legend i{width:9px;height:9px;border-radius:50%}
.fm-zoom{right:16px;bottom:44px;width:40px;display:flex;flex-direction:column;border-radius:12px;overflow:hidden;z-index:2}
.fm-zoom button{height:38px;border:0;border-bottom:1px solid rgba(255,255,255,.07);background:transparent;color:#F4F4F5;font-size:17px;cursor:pointer;font-family:inherit}
.fm-zoom button:last-child{border-bottom:0;font-size:14px}
.fm-nomap{position:absolute;inset:0;display:grid;place-items:center;color:#9A98A6;font-size:13px}

.fm-drv{width:30px;height:30px;display:grid;place-items:center;cursor:pointer;position:absolute;top:0;left:0}
.fm-drv svg{width:24px;height:24px;position:relative;transition:transform .6s ease}
.fm-drv path{fill:${GOLD};stroke:#0E1424;stroke-width:1.6;stroke-linejoin:round}
.fm-drv[data-s="pickup"] path{fill:${BLUE}}
.fm-drv[data-s="ontrip"] path{fill:${GREEN}}
.fm-drv[data-s="quiet"] path{fill:${GRAY}}
.fm-drv[data-s="quiet"] svg{opacity:.6}
.fm-drv .fm-halo{position:absolute;inset:-6px;border-radius:50%;border:2px solid #fff;background:rgba(255,255,255,.1);display:none}
.fm-drv.sel .fm-halo{display:block}
.fm-drv.sel{z-index:5}
.fm-pill{position:absolute;bottom:34px;left:50%;transform:translateX(-50%);white-space:nowrap;background:rgba(20,20,26,.92);border:1px solid rgba(255,255,255,.14);border-radius:999px;padding:3px 9px;font:700 11.5px Inter,system-ui,sans-serif;color:#fff;pointer-events:none;display:none}
.fm-drv:hover .fm-pill,.fm-drv.sel .fm-pill{display:block}
.fm-hide-drivers .fm-drv{display:none}
.fm-wait{width:16px;height:16px;border-radius:50%;background:${RED};border:2px solid #101318;cursor:pointer;position:absolute;top:0;left:0;box-sizing:border-box}
.fm-wait::after{content:"";position:absolute;inset:-9px;border-radius:50%;border:2px solid ${RED};animation:fmping 1.6s ease-out infinite}
.fm-wait .fm-pill{display:block;bottom:20px;background:${RED};border-color:${RED}}
.fm-wait.res{background:#101318;border:3px solid ${RED}}
.fm-hide-trips .fm-wait{display:none}
.fm-end{width:16px;height:16px;border-radius:50%;border:3px solid ${GOLD};background:#101318;position:absolute;top:0;left:0;box-sizing:border-box}
.fm-end.w{border-color:#fff}
.fm-end::after{content:"";position:absolute;left:50%;top:50%;width:5px;height:5px;margin:-2.5px 0 0 -2.5px;border-radius:50%;background:${GOLD}}
.fm-end.w::after{display:none}
@keyframes fmping{0%{transform:scale(.5);opacity:.9}100%{transform:scale(1.6);opacity:0}}

.fm-sheet{display:none}
@container fm (max-width:760px){
 .fm-top{left:10px;right:10px;top:10px;flex-wrap:wrap;gap:8px}
 .fm-title,.fm-layers,.fm-legend,.fm-list{display:none}
 .fm-seg{flex:1 1 100%;height:36px}
 .fm-seg button{flex:1;justify-content:center;padding:0 6px;font-size:12px}
 .fm-long{display:none}
 .fm-short{display:inline}
 .fm-search{max-width:none;flex:1 1 100%;height:38px}
 .fm-card{display:none}
 .fm-zoom{bottom:auto;top:106px;right:10px}
 .fm-sheet{display:flex;position:absolute;left:0;right:0;bottom:0;z-index:4;flex-direction:column;gap:10px;background:rgba(28,28,36,.97);border-top:1px solid rgba(255,255,255,.12);border-radius:22px 22px 0 0;padding:8px 12px 16px;max-height:58%;box-sizing:border-box}
 .fm-sheet .fm-rows{padding:0}
 .fm-sheet .fm-card{display:flex;position:static;width:auto;max-height:none;border:0;box-shadow:none;background:transparent;padding:0;overflow:visible}
 .fm-grab{width:38px;height:5px;border-radius:3px;background:#4A4855;align-self:center;border:0;padding:0;cursor:pointer;flex:none}
 .fm-sheet .fm-foot{padding:8px 4px 0}
}
`;
function ensureCss(){
 if(typeof document==="undefined")return;
 if(!document.getElementById("fm-mapbox-css")){const l=document.createElement("link");l.id="fm-mapbox-css";l.rel="stylesheet";l.href=new URL("./vendor-mapbox-EidcXNcp.css",import.meta.url).href;document.head.appendChild(l)}
 if(!document.getElementById("fm-css")){const s=document.createElement("style");s.id="fm-css";s.textContent=CSS;document.head.appendChild(s)}
}

// ── Small helpers ──────────────────────────────────────────────────────────
const okPt=p=>p!=null&&Number.isFinite(Number(p.lat))&&Number.isFinite(Number(p.lng))&&Math.abs(p.lat)<=90&&Math.abs(p.lng)<=180&&!(Number(p.lat)===0&&Number(p.lng)===0);
function metersBetween(a,b){const R=6371000,toR=Math.PI/180;const dLat=(b.lat-a.lat)*toR,dLng=(b.lng-a.lng)*toR;const x=Math.sin(dLat/2)**2+Math.cos(a.lat*toR)*Math.cos(b.lat*toR)*Math.sin(dLng/2)**2;return 2*R*Math.asin(Math.sqrt(x))}
function bearing(a,b){const toR=Math.PI/180;const y=Math.sin((b.lng-a.lng)*toR)*Math.cos(b.lat*toR);const x=Math.cos(a.lat*toR)*Math.sin(b.lat*toR)-Math.sin(a.lat*toR)*Math.cos(b.lat*toR)*Math.cos((b.lng-a.lng)*toR);return(Math.atan2(y,x)/toR+360)%360}
function initials(n){const p=String(n||"").trim().split(/\s+/).filter(Boolean);return((p[0]||"?")[0]+(p.length>1?p[p.length-1][0]:"")).toUpperCase()}
function mins(ms){return Math.max(0,Math.round(ms/6e4))}
function ago(iso,now){const t=iso?Date.parse(iso):NaN;if(!isFinite(t))return null;const s=Math.max(0,Math.round((now-t)/1e3));if(s<60)return`hace ${s} s`;const m=Math.round(s/60);if(m<60)return`hace ${m} min`;const h=Math.floor(m/60);if(h<24)return`hace ${h} h${m%60&&h<6?` ${m%60} min`:""}`;return`hace ${Math.round(h/24)} d`}
function span(iso,now){const t=iso?Date.parse(iso):NaN;if(!isFinite(t))return"—";const m=mins(now-t);if(m<60)return`${m} min`;const h=Math.floor(m/60);return m%60?`${h} h ${m%60} min`:`${h} h`}
function money(v){const n=Number(v)||0;return`$${n%1?n.toFixed(2):n.toFixed(0)}`}
// The car as the app says it: color in Spanish, a plate never split in two.
const COLORS={black:"negro",white:"blanco",gray:"gris",grey:"gris",silver:"plateado",red:"rojo",blue:"azul",green:"verde",yellow:"amarillo",orange:"anaranjado",brown:"marrón",beige:"beige",gold:"dorado",purple:"morado",maroon:"vino",tan:"beige",navy:"azul marino",burgundy:"vino",champagne:"champán"};
function plateOf(v){return v&&v.plate?String(v.plate).replace(/ /g," "):""}
function carLine(v){if(!v)return"";return[[v.make,v.model].filter(Boolean).join(" "),plateOf(v)].filter(Boolean).join(" · ")}
function carColorLine(v){if(!v)return"";const raw=v.color?String(v.color).trim().toLowerCase():"";const c=COLORS[raw]||raw;return[[v.make,v.model,c].filter(Boolean).join(" "),plateOf(v)].filter(Boolean).join(" · ")}
function clockAt(iso){const t=iso?new Date(iso):null;if(!t||isNaN(t.getTime()))return"";let h=t.getHours(),m=t.getMinutes();const ap=h<12?"AM":"PM";h=h%12||12;return`${h}:${String(m).padStart(2,"0")} ${ap}`}
function readPrefs(){try{const v=JSON.parse(localStorage.getItem("fm-prefs")||"null");return v&&typeof v==="object"?v:{}}catch{return{}}}
function writePrefs(p){try{localStorage.setItem("fm-prefs",JSON.stringify(p))}catch{}}

// What each driver is doing right now. "Sin señal" wins while his app is
// quiet, unless the live stream just moved him.
function stateOf(d,live,now){
 const at=live&&live.get(d.id);
 const fresh=at&&now-at.at<STALE_MS;
 if(d.stale&&!fresh)return"quiet";
 return d.status||"free";
}

function statusLine(d,s,now){
 const t=d.trip;
 if(t&&t.kind==="pickup")return`Yendo a recoger a ${t.rider||"su pasajero"}${t.eta_min!=null?` · llega en ${t.eta_min} min`:""}`;
 if(t&&t.kind==="wait")return`Esperando a ${t.rider||"su pasajero"}${t.since?` · ${ago(t.since,now).replace("hace ","desde hace ")}`:""}`;
 if(t)return`Llevando a ${t.rider||"su pasajero"}${t.eta_min!=null?` · llega en ${t.eta_min} min`:""}`;
 if(s==="quiet")return"Sin viaje";
 return d.free_since?`Libre ${ago(d.free_since,now)}`:"Libre";
}
function rowRight(d,s,now){
 const t=d.trip;
 if(s==="quiet")return[STATUS.quiet.label,`${ago(d.last_seen,now)||"—"}${t?` · #${t.id}`:""}`];
 if(t&&t.kind==="pickup")return["A recoger",t.eta_min!=null?`llega en ${t.eta_min} min`:`#${t.id}`];
 if(t&&t.kind==="wait")return["Esperando",t.since?ago(t.since,now):`#${t.id}`];
 if(t)return["En viaje",`#${t.id}${t.eta_min!=null?` · ${t.eta_min} min`:""}`];
 return["Libre",d.free_since?ago(d.free_since,now):""];
}
function tone(s){const c=STATUS[s]||STATUS.free;return c.color}

// Glide an arrow to a new reading over the time readings take to arrive,
// as on the Inicio (home_live_drivers): it moves all the time instead of
// jumping and stopping. A jump over 3 km is a teleport, not a drive.
function glideTo(m,to,heading){
 const now=performance.now();
 if(m.lastFix){const gap=now-m.lastFix;if(gap>300&&gap<20000)m.gap=m.gap?m.gap*0.6+gap*0.4:gap}
 m.lastFix=now;
 const from=m.pos,far=metersBetween(from,to);
 if(heading!=null&&isFinite(heading))m.heading=heading;else if(far>8)m.heading=bearing(from,to);
 cancelAnimationFrame(m.raf);
 const svg=m.marker.getElement().querySelector("svg");if(svg)svg.style.transform=`rotate(${m.heading||0}deg)`;
 if(far>3000||far<0.5){m.pos=to;m.marker.setLngLat([to.lng,to.lat]);return}
 const dur=Math.min(8000,Math.max(900,(m.gap||5000)*1.05)),t0=now;
 const step=t=>{const k=Math.min(1,(t-t0)/dur);const p={lat:from.lat+(to.lat-from.lat)*k,lng:from.lng+(to.lng-from.lng)*k};m.pos=p;m.marker.setLngLat([p.lng,p.lat]);if(k<1)m.raf=requestAnimationFrame(step)};
 m.raf=requestAnimationFrame(step);
}
function arrowEl(){const d=document.createElement("div");d.className="fm-drv";d.innerHTML=`<span class="fm-halo"></span><svg viewBox="0 0 24 24" aria-hidden="true"><path d="${ARROW}"/></svg><span class="fm-pill"></span>`;return d}
function waitEl(){const d=document.createElement("div");d.className="fm-wait";d.innerHTML='<span class="fm-pill"></span>';return d}
function endEl(white){const d=document.createElement("div");d.className=white?"fm-end w":"fm-end";return d}

// ── Data ───────────────────────────────────────────────────────────────────
const memo={data:null};
function useFleet(){
 const[data,setData]=React.useState(memo.data),[err,setErr]=React.useState(null);
 const skew=React.useRef(0);
 React.useEffect(()=>{let off=false,timer=0;
  const tick=async()=>{if(document.visibilityState==="visible"){try{const d=await apiGet("/admin/fleet/map",{retry:{maxAttempts:1}});if(off)return;if(d&&Array.isArray(d.drivers)){const srv=Date.parse(d.now);if(isFinite(srv))skew.current=srv-Date.now();memo.data=d;setData(d);setErr(null)}}catch(e){if(!off)setErr(e instanceof Error?e.message:String(e))}}if(!off)timer=setTimeout(tick,POLL_MS)};
  tick();
  const vis=()=>{if(document.visibilityState==="visible"){clearTimeout(timer);tick()}};
  document.addEventListener("visibilitychange",vis);
  return()=>{off=true;clearTimeout(timer);document.removeEventListener("visibilitychange",vis)}},[]);
 return{data,err,skew};
}
function useTick(ms){const[,s]=React.useState(0);React.useEffect(()=>{const i=setInterval(()=>s(x=>x+1),ms);return()=>clearInterval(i)},[ms])}

// ── Map ────────────────────────────────────────────────────────────────────
const FleetMap=React.memo(function FleetMap({area,drivers,states,waiting,heat,layers,selected,onSelect,onWaiting,liveRef,apiRef,skewRef}){
 const token=getMapboxToken();
 const box=React.useRef(null),mapRef=React.useRef(null),mk=React.useRef({drv:new Map(),wait:new Map()}),framed=React.useRef(""),route=React.useRef({key:"",at:0,from:null,next:""});
 const handlers=React.useRef({onSelect,onWaiting});handlers.current={onSelect,onWaiting};
 const[ready,setReady]=React.useState(false);

 React.useEffect(()=>{const node=box.current;if(!node||!token)return;mapboxgl.accessToken=token;
  const a=AREAS[area]||null;
  const map=new mapboxgl.Map({container:node,style:navyStyle,center:a?a.center:ALL_VIEW.center,zoom:a?a.zoom:ALL_VIEW.zoom,maxPitch:0,dragRotate:false,pitchWithRotate:false,touchPitch:false,attributionControl:true,logoPosition:"bottom-right"});
  mapRef.current=map;
  map.on("click",e=>{const t=e&&e.originalEvent&&e.originalEvent.target;if(t&&t.closest&&t.closest(".fm-drv,.fm-wait,.fm-end"))return;handlers.current.onSelect(null)});
  map.on("load",()=>{if(mapRef.current!==map)return;map.resize();applyNavyGold(map);refineRoads(map);hideTraffic(map);
   const all=(map.getStyle()||{}).layers||[];let lastRoad=-1;all.forEach((l,i)=>{if(l.type==="line"&&/^(road|bridge|tunnel)/.test(l.id))lastRoad=i});const labels=all.find((l,i)=>i>lastRoad&&l.type==="symbol");const before=labels?labels.id:undefined;
   map.addSource("fm-zones",{type:"geojson",data:EMPTY});
   map.addLayer({id:"fm-zones-fill",type:"fill",source:"fm-zones",paint:{"fill-color":GOLD,"fill-opacity":0.035}},before);
   map.addLayer({id:"fm-zones-line",type:"line",source:"fm-zones",paint:{"line-color":GOLD,"line-opacity":0.4,"line-width":1.4,"line-dasharray":[3,3]}},before);
   map.addSource("fm-heat",{type:"geojson",data:EMPTY});
   map.addLayer({id:"fm-heat-layer",type:"heatmap",source:"fm-heat",paint:{"heatmap-weight":["interpolate",["linear"],["get","w"],0,0,3,1],"heatmap-intensity":1,"heatmap-radius":["interpolate",["linear"],["zoom"],8,18,11,36,14,70],"heatmap-color":["interpolate",["linear"],["heatmap-density"],0,"rgba(232,165,58,0)",0.3,"rgba(232,165,58,0.22)",0.7,"rgba(232,165,58,0.42)",1,"rgba(245,200,110,0.6)"],"heatmap-opacity":0.9}},before);
   map.addSource("fm-next",{type:"geojson",data:EMPTY});
   map.addLayer({id:"fm-next-line",type:"line",source:"fm-next",layout:{"line-cap":"round","line-join":"round"},paint:{"line-width":3,"line-color":"#FFFFFF","line-opacity":0.5,"line-dasharray":[0.6,2.2]}},before);
   map.addSource("fm-leg",{type:"geojson",data:EMPTY});
   map.addLayer({id:"fm-leg-line",type:"line",source:"fm-leg",layout:{"line-cap":"round","line-join":"round"},paint:{"line-width":4.5,"line-color":["get","c"]}},before);
   apiGet("/admin/zones/sectors",{retry:{maxAttempts:1}}).then(z=>{if(mapRef.current===map&&z&&z.geojson&&map.getSource("fm-zones"))map.getSource("fm-zones").setData(z.geojson)}).catch(()=>{});
   setReady(true)});
  const ro=typeof ResizeObserver==="undefined"?null:new ResizeObserver(()=>map.resize());ro?.observe(node);
  apiRef.current={
   zoomIn:()=>map.zoomIn(),zoomOut:()=>map.zoomOut(),
   frame:()=>{framed.current="";apiRef.current.refit&&apiRef.current.refit()},
   flyTo:(p,z)=>{if(okPt(p))map.easeTo({center:[p.lng,p.lat],zoom:Math.max(map.getZoom(),z||13),duration:700,padding:paddingFor(true)})},
  };
  return()=>{ro?.disconnect();for(const m of mk.current.drv.values()){cancelAnimationFrame(m.raf);m.marker.remove()}for(const m of mk.current.wait.values())m.marker.remove();mk.current={drv:new Map(),wait:new Map()};framed.current="";mapRef.current=null;setReady(false);map.remove()}},[token]);// eslint-disable-line

 // The list on the left and the card on the right cover the map: frames and
 // follows keep what matters in the part you can see.
 const paddingFor=card=>{const node=box.current;const w=node?node.clientWidth:1200;if(w<=760)return{top:120,bottom:Math.round((node?node.clientHeight:700)*0.42),left:30,right:30};return{top:110,bottom:50,left:370,right:card?380:70}};

 // Layers on/off.
 React.useEffect(()=>{const map=mapRef.current,node=box.current;if(!node)return;
  node.classList.toggle("fm-hide-drivers",!layers.drivers);node.classList.toggle("fm-hide-trips",!layers.trips);
  if(!map||!ready)return;const vis=(id,on)=>{if(map.getLayer(id))map.setLayoutProperty(id,"visibility",on?"visible":"none")};
  vis("fm-heat-layer",layers.heat);vis("fm-zones-fill",layers.zones);vis("fm-zones-line",layers.zones);vis("fm-leg-line",layers.trips);vis("fm-next-line",layers.trips)},[ready,layers]);

 // Demand cells (never a rider's point, #67).
 React.useEffect(()=>{const map=mapRef.current;if(!map||!ready)return;
  map.getSource("fm-heat")?.setData({type:"FeatureCollection",features:heat.map(c=>({type:"Feature",properties:{w:c.w},geometry:{type:"Point",coordinates:[c.lng,c.lat]}}))})},[ready,heat]);

 // Live: each fix the moment the driver's app sends it.
 React.useEffect(()=>{if(!ready||typeof EventSource==="undefined")return;let es=null,retry=null,off=false;
  const connect=()=>{if(off||document.visibilityState!=="visible")return;es?.close();es=new EventSource("/admin/drivers/live");
   es.addEventListener("driver_location",ev=>{let d;try{d=JSON.parse(ev.data)}catch{return}
    if(!d||d.is_online===false)return;const id=Number(d.id);const lat=Number(d.lat),lng=Number(d.lng);
    if(!isFinite(lat)||!isFinite(lng)||(lat===0&&lng===0))return;
    const speed=d.speed!=null&&isFinite(Number(d.speed))?Number(d.speed):null;
    liveRef.current.set(id,{at:Date.now(),lat,lng,speed});
    const m=mk.current.drv.get(id);if(!m)return;
    m.liveAt=Date.now();m.target={lat,lng};
    glideTo(m,m.target,speed!=null&&speed>1.5&&d.heading!=null?Number(d.heading):null)});
   es.onerror=()=>{es?.close();es=null;if(!off){clearTimeout(retry);retry=setTimeout(connect,3000)}}};
  const vis=()=>{if(document.visibilityState==="visible"){if(!es)connect()}else{es?.close();es=null}};
  connect();document.addEventListener("visibilitychange",vis);
  return()=>{off=true;clearTimeout(retry);es?.close();document.removeEventListener("visibilitychange",vis)}},[ready]);// eslint-disable-line

 // One arrow per driver, colored by what he is doing.
 React.useEffect(()=>{const map=mapRef.current;if(!map||!ready)return;const keep=new Set();
  for(const d of drivers){keep.add(d.id);const to={lat:d.lat,lng:d.lng};let m=mk.current.drv.get(d.id);
   if(!m){const node=arrowEl();node.addEventListener("click",e=>{e.stopPropagation();handlers.current.onSelect(d.id)});
    m={marker:new mapboxgl.Marker({element:node,anchor:"center"}).setLngLat([to.lng,to.lat]).addTo(map),pos:to,heading:d.heading,raf:0};mk.current.drv.set(d.id,m)}
   else if(!(m.liveAt&&Date.now()-m.liveAt<LIVE_FRESH_MS)&&(!m.target||metersBetween(m.target,to)>0.5)){m.target=to;glideTo(m,to,null)}
   if(m.heading==null&&d.trip){const target=d.trip.kind==="ontrip"?d.trip.dropoff:d.trip.pickup;if(okPt(target)&&metersBetween(to,target)>30)m.heading=bearing(to,target)}
   const node=m.marker.getElement();const s=states.get(d.id)||"free";node.dataset.s=s;node.classList.toggle("sel",selected===d.id);
   node.title=`${d.name} · ${(STATUS[s]||STATUS.free).label}`;
   const svg=node.querySelector("svg");if(svg)svg.style.transform=`rotate(${m.heading||0}deg)`;
   const pill=node.querySelector(".fm-pill");if(pill)pill.textContent=d.trip?`${d.name} · #${d.trip.id}`:d.name}
  for(const[id,m]of mk.current.drv){if(!keep.has(id)){cancelAnimationFrame(m.raf);m.marker.remove();mk.current.drv.delete(id)}}},[ready,drivers,states,selected]);

 // Rides with no driver: a red dot at the pickup with how long it waits.
 React.useEffect(()=>{const map=mapRef.current;if(!map||!ready)return;const keep=new Set();
  for(const w of waiting){if(!okPt(w.pickup))continue;keep.add(w.id);let m=mk.current.wait.get(w.id);
   if(!m){const node=waitEl();node.addEventListener("click",e=>{e.stopPropagation();handlers.current.onWaiting(w.id)});m={marker:new mapboxgl.Marker({element:node,anchor:"center"}).setLngLat([w.pickup.lng,w.pickup.lat]).addTo(map),w};mk.current.wait.set(w.id,m)}
   m.w=w;m.marker.getElement().classList.toggle("res",!!w.reservation)}
  for(const[id,m]of mk.current.wait){if(!keep.has(id)){m.marker.remove();mk.current.wait.delete(id)}}},[ready,waiting]);
 React.useEffect(()=>{const tick=()=>{const now=Date.now()+(skewRef.current||0);for(const m of mk.current.wait.values()){const pill=m.marker.getElement().querySelector(".fm-pill");if(!pill)continue;const w=m.w;pill.textContent=w.reservation?`#${w.id} · Reserva ${clockAt(w.at)} · sin conductor`:`#${w.id} · ${Math.max(1,mins(now-Date.parse(w.since)))} min sin conductor`}};tick();const h=setInterval(tick,15000);return()=>clearInterval(h)},[ready,waiting]);// eslint-disable-line

 // The selected driver's way: where he goes now (by the streets, in his
 // color) and, before the rider is in, the ride after it (dashed).
 const sel=selected!=null?drivers.find(d=>d.id===selected)||null:null;
 const selTrip=sel&&sel.trip;
 const fc=coords=>({type:"FeatureCollection",features:[{type:"Feature",properties:{},geometry:{type:"LineString",coordinates:coords}}]});
 // Pickup and destination rings of the selected trip.
 React.useEffect(()=>{const map=mapRef.current;if(!map||!ready||!sel||!selTrip)return;const t=selTrip,ends=[];
  if(okPt(t.pickup)&&t.kind!=="ontrip")ends.push(new mapboxgl.Marker({element:endEl(false),anchor:"center"}).setLngLat([t.pickup.lng,t.pickup.lat]).addTo(map));
  if(okPt(t.dropoff))ends.push(new mapboxgl.Marker({element:endEl(true),anchor:"center"}).setLngLat([t.dropoff.lng,t.dropoff.lat]).addTo(map));
  return()=>ends.forEach(e=>e.remove())},[ready,sel&&sel.id,selTrip&&selTrip.id,selTrip&&selTrip.kind]);// eslint-disable-line
 // The lines: asked again only for another trip/leg, or every 30 s once he
 // moved 150 m (a poll never aborts one in flight).
 React.useEffect(()=>{const map=mapRef.current;if(!map||!ready)return;
  const leg=map.getSource("fm-leg"),next=map.getSource("fm-next");
  if(!sel||!selTrip){leg?.setData(EMPTY);next?.setData(EMPTY);route.current={key:"",at:0,from:null,next:""};return}
  const t=selTrip;
  const target=t.kind==="ontrip"?t.dropoff:t.kind==="pickup"?t.pickup:null;
  const color=t.kind==="ontrip"?GREEN:BLUE;
  const m=mk.current.drv.get(sel.id);const from=m?m.pos:{lat:sel.lat,lng:sel.lng};
  const key=`${sel.id}:${t.id}:${t.kind}`;const r=route.current;
  const draw=coords=>{if(route.current.key!==key)return;const f=fc(coords);f.features[0].properties.c=color;map.getSource("fm-leg")?.setData(f)};
  if(r.key!==key)leg?.setData(EMPTY);
  if(r.key!==key||!r.from||(Date.now()-r.at>ROUTE_REFRESH_MS&&metersBetween(r.from,from)>ROUTE_MOVE_M)){
   route.current={...r,key,at:Date.now(),from};
   if(target&&okPt(target)&&token)fetchStreetRoute(from,target,token).then(x=>draw(x.coords)).catch(()=>{if(route.current.key===key)route.current={...route.current,from:null}});
   else leg?.setData(EMPTY)}
  const nextKey=t.kind!=="ontrip"&&okPt(t.pickup)&&okPt(t.dropoff)?`${t.id}`:"";
  if(nextKey!==route.current.next){route.current.next=nextKey;next?.setData(EMPTY);
   if(nextKey&&token)fetchStreetRoute(t.pickup,t.dropoff,token).then(x=>{if(route.current.next===nextKey)map.getSource("fm-next")?.setData(fc(x.coords))}).catch(()=>{})}
 },[ready,sel&&sel.id,selTrip&&selTrip.id,selTrip&&selTrip.kind,sel&&sel.lat,sel&&sel.lng]);// eslint-disable-line

 // Frame the state once per state (and on "encuadrar"); a poll never moves
 // a map the operator moved.
 React.useEffect(()=>{const map=mapRef.current;if(!map||!ready)return;
  const refit=()=>{const pts=[];drivers.forEach(d=>pts.push([d.lng,d.lat]));waiting.forEach(w=>{if(okPt(w.pickup))pts.push([w.pickup.lng,w.pickup.lat])});
   const a=AREAS[area];
   if(!pts.length){map.jumpTo(a?{center:a.center,zoom:a.zoom}:ALL_VIEW);return}
   const b=new mapboxgl.LngLatBounds(pts[0],pts[0]);pts.forEach(p=>b.extend(p));
   map.fitBounds(b,{padding:paddingFor(false),maxZoom:13,duration:framed.current?600:0})};
  if(apiRef.current)apiRef.current.refit=refit;
  if(framed.current===area)return;framed.current=area;refit()},[ready,area,drivers,waiting]);// eslint-disable-line

 return el("div",{className:"fm-canvas"},
  el("div",{ref:box,className:"fm-canvas"}),
  token?null:el("div",{className:"fm-nomap"},"El mapa no está disponible ahora."));
});

// ── Pieces ─────────────────────────────────────────────────────────────────
function Avatar({d,s,size}){const[bad,setBad]=React.useState(false);React.useEffect(()=>setBad(false),[d.photo_url]);
 return el("span",{className:"fm-av",style:size?{width:size,height:size}:undefined},d.photo_url&&!bad?el("img",{src:d.photo_url,alt:"",onError:()=>setBad(true)}):initials(d.full_name||d.name),s?el("i",{style:{background:tone(s)}}):null)}

function Stats({counts,filter,setFilter}){
 return el("div",{className:"fm-stat"},["free","pickup","ontrip","quiet"].map(k=>el("button",{type:"button",key:k,className:filter===k?"on":undefined,"aria-pressed":filter===k,onClick:()=>setFilter(filter===k?null:k)},el("b",null,String(counts[k]||0)),el("small",null,el("i",{style:{background:STATUS[k].color}}),STATUS[k].short))));
}

function Row({d,s,now,sel,onPick}){
 const[a,b]=rowRight(d,s,now);
 const where=d.trip?(d.trip.kind==="ontrip"?d.trip.to:d.trip.from):d.city;
 return el("button",{type:"button",className:`fm-r${sel?" sel":""}${s==="quiet"?" quiet":""}`,onClick:()=>onPick(d.id)},
  el(Avatar,{d,s}),
  el("div",{className:"fm-mid"},el("b",null,d.name),el("small",null,[carLine(d.vehicle),where].filter(Boolean).join(" · ")||"—")),
  el("div",{className:"fm-st",style:{color:s==="pickup"?"#9CC6FF":tone(s)}},a,b?el("small",null,b):null));
}

function Footer({area,data,waiting,now,avgEta,onWaiting}){
 const p=data&&data.pidiendo;const building=p?(area==="all"?p.total:(p.by_market||{})[area]||0):null;
 const first=waiting[0];
 return el("div",{className:"fm-foot"},
  building!=null?el("div",null,el("span",null,"Pidiendo ahora"),el("b",null,String(building))):null,
  el("div",null,el("span",null,"Buscando conductor"),first?el("b",{className:"red",role:"button",tabIndex:0,onClick:()=>onWaiting(first.id)},`${waiting.length} · #${first.id} ${first.reservation?`reserva ${clockAt(first.at)}`:ago(first.since,now)}`):el("b",null,"0")),
  avgEta!=null?el("div",null,el("span",null,"Llegada promedio"),el("b",null,`${avgEta} min`)):null);
}

function DriverCard({d,s,now,live,onClose,onModal,navigate}){
 const t=d.trip;const c=tone(s==="quiet"?d.status:s);
 const lv=live.get(d.id);
 const seenAt=lv&&lv.at?new Date(lv.at).toISOString():d.last_seen;
 const mps=lv&&lv.speed!=null?lv.speed:d.speed_mps;
 const mph=mps!=null&&isFinite(mps)?Math.max(0,Math.round(mps*2.23694)):null;
 const bg=c===BLUE?"rgba(76,155,255,.1)":c===GREEN?"rgba(61,220,132,.1)":"rgba(232,197,71,.1)";
 const fg=c===BLUE?"#9CC6FF":c===GREEN?"#8BEBB4":"#F3DC8A";
 return el("div",{className:"fm-f fm-card",role:"dialog","aria-label":`Conductor ${d.name}`},
  el("div",{className:"fm-ch"},el(Avatar,{d,size:48}),el("div",{style:{minWidth:0}},el("b",null,d.name),el("small",null,[d.rating?`★ ${Number(d.rating).toFixed(2)}`:null,carColorLine(d.vehicle)].filter(Boolean).join(" · ")||"Sin carro registrado")),el("button",{type:"button",className:"fm-x","aria-label":"Cerrar",onClick:onClose},"×")),
  el("div",{className:"fm-status",style:{background:bg,border:`1px solid ${c}55`,color:fg}},el("i",{style:{background:c}}),statusLine(d,s,now)),
  s==="quiet"?el("div",{className:"fm-warn"},`Su app no reporta ${ago(d.last_seen,now)||""}. Puede tener el teléfono bloqueado o sin señal.`):null,
  t?el("div",{className:"fm-rail"},
   el("div",null,el("span",{className:"fm-ring"}),el("div",null,t.pickup_address||t.from||"—",el("small",null,"Recogida"))),
   el("div",null,el("span",{className:"fm-ring w"}),el("div",null,t.dropoff_address||t.to||"—",el("small",null,"Destino")))):null,
  el("div",{className:"fm-kv"},
   el("div",null,"Última señal",el("b",null,ago(seenAt,now)||"—")),
   el("div",null,"Velocidad",el("b",null,mph!=null?`${mph} mph`:"—")),
   el("div",null,"En línea",el("b",null,d.online_since?span(d.online_since,now):"—")),
   el("div",null,"Hoy",el("b",null,`${d.today?d.today.trips:0} ${d.today&&d.today.trips===1?"viaje":"viajes"} · ${money(d.today?d.today.earned:0)}`))),
  el("div",{className:"fm-btns"},
   el("button",{type:"button",onClick:()=>onModal("call",d)},"Llamar"),
   el("button",{type:"button",onClick:()=>onModal("write",d)},"Escribir"),
   el("button",{type:"button",onClick:()=>navigate(`/personas/driver/sql_${d.id}`)},"Ficha"),
   t?el("button",{type:"button",className:"g",onClick:()=>navigate(`/viajes/viaje/sql_${t.id}`)},"Viaje"):el("button",{type:"button",className:"g",onClick:()=>onModal("offer",d)},"Ofrecer viaje")),
  t?el("button",{type:"button",className:"fm-open",onClick:()=>navigate(`/viajes/viaje/sql_${t.id}`)},`Abrir viaje #${t.id} →`):null);
}

// "Escribir": the open support chat if there is one, else a first message.
function WriteModal({d,onClose,navigate}){
 const[chat,setChat]=React.useState(undefined),[text,setText]=React.useState(""),[busy,setBusy]=React.useState(false),[err,setErr]=React.useState(null);
 React.useEffect(()=>{let off=false;apiGet(`/admin/users/${d.id}/support-chat`,{retry:{maxAttempts:1}}).then(r=>{if(off)return;if(r&&r.chat_id){navigate(`/soporte/chat/${r.chat_id}`);onClose()}else setChat(null)}).catch(()=>{if(!off)setChat(null)});return()=>{off=true}},[d.id]);// eslint-disable-line
 const send=async()=>{const message=text.trim();if(!message||busy)return;setBusy(true);setErr(null);
  let persona=null;try{const v=JSON.parse(localStorage.getItem("si-persona-last")||"null");if(v&&typeof v.kind==="string")persona={kind:v.kind,name:v.kind==="name"?v.name:null}}catch{}
  try{const r=await apiPost(`/admin/users/${d.id}/support-chat`,persona?{message,persona}:{message},{retry:{maxAttempts:1}});navigate(`/soporte/chat/${r.chat_id}`);onClose()}catch(e){setBusy(false);setErr(e instanceof Error?e.message:String(e))}};
 const first=String(d.full_name||d.name||"").split(/\s+/)[0];
 return el(Modal,{title:`Escribirle a ${d.name}`,sub:"Le llega como un mensaje de Soporte en su app, con aviso.",onClose,width:480},
  chat===undefined?el("div",{className:"up-muted"},"Buscando su chat…"):
  el("textarea",{className:"up-text",autoFocus:true,value:text,maxLength:2000,placeholder:`Hola ${first}, `,onChange:e=>setText(e.target.value)}),
  err?el("div",{className:"up-err"},err):null,
  el("footer",null,el("button",{type:"button",className:"up-btn",onClick:onClose},"Cancelar"),el("button",{type:"button",className:"up-btn gold",disabled:chat===undefined||!text.trim()||busy,onClick:send},busy?"Enviando…":"Enviar")));
}

// ── Screen ─────────────────────────────────────────────────────────────────
function FleetMapScreen(){
 ensureCss();ensureProfileCss();
 const navigate=useNavigate();
 const{data,err,skew}=useFleet();
 useTick(5000);
 const prefs=React.useRef(readPrefs());
 const[area,setAreaState]=React.useState(null);
 const[layers,setLayersState]=React.useState(()=>Object.assign({drivers:true,trips:true,heat:true,zones:false},prefs.current.layers||{}));
 const[filter,setFilter]=React.useState(null),[selected,setSelected]=React.useState(null),[q,setQ]=React.useState("");
 const[modal,setModal]=React.useState(null),[toastMsg,setToastMsg]=React.useState(null),[sheetOpen,setSheetOpen]=React.useState(false);
 const liveRef=React.useRef(new Map()),apiRef=React.useRef(null),toastT=React.useRef(null);
 const toast=React.useCallback(m=>{setToastMsg(m);clearTimeout(toastT.current);toastT.current=setTimeout(()=>setToastMsg(null),4e3)},[]);

 // The whole work area, edge to edge (as Soporte).
 const wrapRef=React.useRef(null);const[height,setHeight]=React.useState(null);
 React.useLayoutEffect(()=>{const root=document.documentElement;root.classList.add("fm-full");const fit=()=>{const w=wrapRef.current;if(!w)return;const top=w.getBoundingClientRect().top;setHeight(Math.max(520,Math.round(window.innerHeight-Math.max(0,top))))};fit();window.addEventListener("resize",fit);return()=>{window.removeEventListener("resize",fit);root.classList.remove("fm-full")}},[]);

 const now=Date.now()+(skew.current||0);
 const all=data?data.drivers:[];
 const byMarket=React.useMemo(()=>{const c={all:all.length,AL:0,FL:0};all.forEach(d=>{if(d.market==="AL"||d.market==="FL")c[d.market]++});return c},[all]);

 // Opens where the drivers are: the state with the most online.
 React.useEffect(()=>{if(area||!data)return;const c={AL:0,FL:0};data.drivers.forEach(d=>{if(c[d.market]!=null)c[d.market]++});
  setAreaState(c.AL===0&&c.FL===0?(prefs.current.area||"FL"):c.FL>=c.AL?"FL":"AL")},[data,area]);
 const setArea=a=>{setAreaState(a);setSelected(null);prefs.current={...prefs.current,area:a};writePrefs(prefs.current)};
 const setLayer=k=>{const next={...layers,[k]:!layers[k]};setLayersState(next);prefs.current={...prefs.current,layers:next};writePrefs(prefs.current)};
 const cur=area||"FL";

 const inArea=x=>cur==="all"||x.market===cur;
 const drivers=React.useMemo(()=>all.filter(inArea),[all,cur]);// eslint-disable-line
 const waiting=React.useMemo(()=>(data?data.waiting:[]).filter(inArea),[data,cur]);// eslint-disable-line
 const heat=React.useMemo(()=>(data?data.heat||[]:[]).filter(c=>cur==="all"||c.market===cur),[data,cur]);
 const states=new Map(drivers.map(d=>[d.id,stateOf(d,liveRef.current,Date.now())]));
 const statesKey=drivers.map(d=>`${d.id}:${states.get(d.id)}`).join(",");
 const stableStates=React.useMemo(()=>states,[statesKey]);// eslint-disable-line
 const counts={free:0,pickup:0,ontrip:0,quiet:0};drivers.forEach(d=>{counts[stableStates.get(d.id)]++});
 const etas=drivers.filter(d=>d.trip&&d.trip.kind==="pickup"&&d.trip.eta_min!=null).map(d=>d.trip.eta_min);
 const avgEta=etas.length?Math.round(etas.reduce((a,b)=>a+b,0)/etas.length):null;

 const needle=q.trim().toLowerCase();
 const listed=drivers.filter(d=>{if(filter&&stableStates.get(d.id)!==filter)return false;if(!needle)return true;
  const v=d.vehicle||{};return[d.name,d.full_name,v.plate,v.make,v.model,d.city,d.trip&&`#${d.trip.id}`,d.trip&&String(d.trip.id)].filter(Boolean).some(x=>String(x).toLowerCase().includes(needle.replace(/^#/,"")))})
  .sort((a,b)=>ORDER.indexOf(stableStates.get(a.id))-ORDER.indexOf(stableStates.get(b.id))||(a.name||"").localeCompare(b.name||""));

 const sel=selected!=null?all.find(d=>d.id===selected)||null:null;
 React.useEffect(()=>{if(selected!=null&&data&&!all.some(d=>d.id===selected))setSelected(null)},[data]);// eslint-disable-line
 const pick=id=>{setSelected(id);if(id==null)return;const d=all.find(x=>x.id===id);if(d){if(cur!=="all"&&d.market!==cur)setAreaState("all");setTimeout(()=>{const lv=liveRef.current.get(id);apiRef.current&&apiRef.current.flyTo(lv&&Date.now()-lv.at<LIVE_FRESH_MS?lv:d,13.5)},0)}};
 // "Ver en el mapa" from Conductores opens here focused on that driver (navigate state driverId, 2026-11-18).
 const focusRef=React.useRef((()=>{try{const u=window.history.state&&window.history.state.usr;const v=u&&u.driverId;return v!=null&&v!==""?Number(v):null}catch{return null}})());
 React.useEffect(()=>{const want=focusRef.current;if(want==null||!data)return;focusRef.current=null;if(all.some(d=>d.id===want)){pick(want);setSheetOpen(true)}else toast("Ese conductor no está en línea ahora.")},[data]);// eslint-disable-line
 const onWaiting=id=>{const w=(data?data.waiting:[]).find(x=>x.id===id);if(w&&okPt(w.pickup)){apiRef.current&&apiRef.current.flyTo(w.pickup,13.5)}navigate(`/viajes/viaje/sql_${id}`)};
 const onSearch=e=>{if(e.key!=="Enter")return;const t=q.trim().replace(/^#/,"");if(!t)return;
  if(/^\d+$/.test(t)){const n=Number(t);const d=all.find(x=>x.trip&&x.trip.id===n);if(d){pick(d.id);return}navigate(`/viajes/viaje/sql_${n}`);return}
  if(listed.length===1)pick(listed[0].id)};

 const last=data&&data.last_online||{};
 const emptyText=()=>{if(!data)return null;if(drivers.length)return null;const names=cur==="all"?"ningún estado":AREAS[cur].name;const l=cur==="all"?null:last[cur];
  return el("div",{className:"fm-empty"},el("b",null,`Nadie en línea en ${names}`),l?`El último fue ${l.name} ${ago(l.at,now)}.`:"Cuando un conductor se conecte aparece aquí.")};
 const noMatch=drivers.length&&!listed.length?el("div",{className:"fm-empty"},el("b",null,"Nadie coincide"),filter?"Quita el filtro de arriba para ver a todos.":"Prueba con otro nombre, placa o número de viaje."):null;
 const rows=el("div",{className:"fm-rows"},emptyText()||noMatch||listed.map(d=>el(Row,{key:d.id,d,s:stableStates.get(d.id),now,sel:d.id===selected,onPick:pick})));
 const title=cur==="all"?`Todos · ${drivers.length} en línea`:`${AREAS[cur].name} · ${drivers.length} en línea`;
 const card=sel?el(DriverCard,{d:sel,s:stateOf(sel,liveRef.current,Date.now()),now,live:liveRef.current,onClose:()=>setSelected(null),onModal:(k,d)=>setModal({k,d}),navigate}):null;

 return el("div",{ref:wrapRef,className:"fm-wrap"},
  el("div",{className:"fm-page",style:height?{height}:undefined},
   el(FleetMap,{area:cur,drivers,states:stableStates,waiting,heat,layers,selected,onSelect:pick,onWaiting,liveRef,apiRef,skewRef:skew}),
   el("div",{className:"fm-top"},
    el("span",{className:"fm-title"},el("span",{className:err?"fm-live off":"fm-live"}),"Mapa en vivo"),
    el("div",{className:"fm-seg",role:"group","aria-label":"Estado"},
     [["all","Todos","Todos"],["AL","Alabama","AL"],["FL","Florida","FL"]].map(([k,long,short])=>el("button",{type:"button",key:k,className:cur===k?"on":undefined,"aria-pressed":cur===k,onClick:()=>setArea(k)},el("span",{className:"fm-long"},long),el("span",{className:"fm-short"},short),el("b",null,String(byMarket[k]||0))))),
    el("label",{className:"fm-search"},el("span",{"aria-hidden":"true"},"⌕"),el("input",{value:q,placeholder:"Buscar conductor, placa o viaje #","aria-label":"Buscar conductor, placa o viaje",onChange:e=>{setQ(e.target.value);setSheetOpen(true)},onKeyDown:onSearch})),
    el("div",{className:"fm-layers"},
     [["drivers","Conductores",GOLD],["trips","Viajes",BLUE],["heat","Demanda",AMBER],["zones","Zonas","#9A98A6"]].map(([k,label,c])=>el("button",{type:"button",key:k,className:layers[k]?"fm-chip":"fm-chip off","aria-pressed":!!layers[k],onClick:()=>setLayer(k)},el("i",{style:{background:c}}),label)))),
   el("div",{className:"fm-f fm-list"},
    el("div",{className:"fm-lh"},el("div",{className:"fm-lt"},el("b",null,title),el("span",null,err?"sin conexión":"en vivo")),el(Stats,{counts,filter,setFilter})),
    rows,
    el(Footer,{area:cur,data,waiting,now,avgEta,onWaiting})),
   card,
   el("div",{className:"fm-f fm-legend"},
    el("span",null,el("i",{style:{background:GOLD}}),"Libre"),el("span",null,el("i",{style:{background:BLUE}}),"Yendo a recoger"),el("span",null,el("i",{style:{background:GREEN}}),"En viaje"),el("span",null,el("i",{style:{background:GRAY}}),"Sin señal"),el("span",null,el("i",{style:{background:RED}}),"Sin conductor"),el("span",null,el("i",{style:{background:AMBER,opacity:.6}}),"Pasajeros pidiendo")),
   el("div",{className:"fm-f fm-zoom"},
    el("button",{type:"button","aria-label":"Acercar",onClick:()=>apiRef.current&&apiRef.current.zoomIn()},"+"),
    el("button",{type:"button","aria-label":"Alejar",onClick:()=>apiRef.current&&apiRef.current.zoomOut()},"−"),
    el("button",{type:"button","aria-label":"Encuadrar a todos",title:"Encuadrar a todos",onClick:()=>apiRef.current&&apiRef.current.frame()},"◎")),
   // Phone: the list and the card live in a sheet.
   el("div",{className:"fm-sheet"},
    el("button",{type:"button",className:"fm-grab","aria-label":sheetOpen?"Bajar la lista":"Subir la lista",onClick:()=>setSheetOpen(v=>!v)}),
    sel?card:el(React.Fragment,null,
     el(Stats,{counts,filter,setFilter:f=>{setFilter(f);setSheetOpen(true)}}),
     sheetOpen?rows:(listed.slice(0,2).map(d=>el(Row,{key:d.id,d,s:stableStates.get(d.id),now,sel:false,onPick:pick}))),
     el(Footer,{area:cur,data,waiting,now,avgEta,onWaiting}))),
   modal&&modal.k==="call"?el(CallModal,{name:modal.d.full_name||modal.d.name,phone:modal.d.phone,onClose:()=>setModal(null),toast}):null,
   modal&&modal.k==="offer"?el(OfferModal,{driverId:modal.d.id,name:modal.d.name,onClose:()=>setModal(null),toast}):null,
   modal&&modal.k==="write"?el(WriteModal,{d:modal.d,onClose:()=>setModal(null),navigate}):null,
   toastMsg?el("div",{className:"up-toast",role:"status"},toastMsg):null));
}

export{FleetMapScreen};
