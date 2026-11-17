/*! guard-pin panel_home_lyft: Inicio estilo Lyft (dueño 2026-11-16, dibujo https://claude.ai/artifact/V1dhsXy7aw4BLVAPLTme67) - chunk escrito a mano, sin fuente React (CLAUDE.md #30). Lo monta la ruta /inicio de index-CuQT_62K.js; si este chunk no carga, falla, o GET /admin/home no contesta la primera vez, se ve el Inicio de antes. Todo sale de UNA llamada (GET /admin/home cada 10 s con la pestaña a la vista); las verificaciones, de la misma cola que la página Verificación. Nunca la posición de un pasajero (#67): "Pidiendo ahora" es un número y el calor son celdas de ~400 m. */
import{r as React,j as J,y as useNavigate}from"./vendor-react-DprhJQz-.js";
import{m as mapboxgl}from"./vendor-mapbox-ComAnvan.js";
import{N as navyStyle,a as applyNavyGold,r as refineRoads,h as hideTraffic}from"./mapNavyGold-CiIxy5Vj.js";
import{m as getMapboxToken}from"./mapboxToken-DDoCRQix.js";
import{W as apiGet,aA as useVerificationQueue}from"./index-CuQT_62K.js";
import{fetchStreetRoute}from"./trip-route-map-Cruise2026.js";

function el(type,props,...kids){
 const p=Object.assign({},props||{});const key=p.key;delete p.key;
 const c=kids.filter(k=>k!==undefined);
 if(c.length===1)p.children=c[0];else if(c.length>1)p.children=c;
 return c.length>1?J.jsxs(type,p,key):J.jsx(type,p,key);
}

const GOLD="#E8C547",CORAL="#FF9A7A";
const POLL_MS=10000;
const EMPTY={type:"FeatureCollection",features:[]};
const AREAS={AL:{name:"Alabama",center:[-86.80,33.50],zoom:9.6},FL:{name:"Florida",center:[-80.20,26.10],zoom:9.4}};
const PREF_KEY="cruise-home-market";

const I={
 car:"M5 11l1.6-4.2A2 2 0 0 1 8.5 5.5h7a2 2 0 0 1 1.9 1.3L19 11M4 11h16v6H4zM7 17v2M17 17v2",
 radar:"M12 13a1 1 0 1 0 0-2 1 1 0 0 0 0 2zM8.5 8.5a5 5 0 0 0 0 7M15.5 8.5a5 5 0 0 1 0 7M5.6 5.6a9 9 0 0 0 0 12.8M18.4 5.6a9 9 0 0 1 0 12.8",
 cal:"M4 6h16v14H4zM4 10h16M8 3v4M16 3v4",
 chat:"M4 5h16v11H9l-5 4z",
 user:"M12 12a4 4 0 1 0 0-8 4 4 0 0 0 0 8zM4 21a8 8 0 0 1 16 0",
 wheel:"M12 3a9 9 0 1 0 0 18 9 9 0 0 0 0-18zM3.5 11h5l2 3h3l2-3h5M12 14v7",
 shield:"M12 3l8 3v6c0 5-3.5 8-8 9-4.5-1-8-4-8-9V6zM8.5 12l2.5 2.5 4.5-5",
 wallet:"M3 7h18v12H3zM3 11h18M7 15h3",
 card:"M3 6h18v12H3zM3 10h18M7 15h4",
 check:"M5 12.5l4.5 4.5L19 7.5",
 search:"M11 18a7 7 0 1 0 0-14 7 7 0 0 0 0 14zM20 20l-4-4",
 plus:"M12 5v14M5 12h14",
};
const ARROW="M12 2.5 L19 20.5 L12 16.6 L5 20.5 Z";

const CSS=`
.ch-page{display:flex;flex-direction:column;gap:18px;min-width:0;color:#F4F4F5;font-family:Inter,system-ui,sans-serif}
.ch-page *{box-sizing:border-box}
.ch-head{display:flex;flex-wrap:wrap;align-items:center;gap:14px}
.ch-titlebox{display:flex;flex-direction:column;gap:4px;flex:1 1 220px;min-width:0}
.ch-h1{margin:0;font-size:26px;font-weight:800;color:#fff;letter-spacing:-.4px}
.ch-when{display:flex;flex-wrap:wrap;align-items:center;gap:12px;font-size:13px;color:rgba(255,255,255,.62)}
.ch-live{display:inline-flex;align-items:center;gap:7px;font-size:12.5px;font-weight:600;color:${GOLD}}
.ch-live.off{color:${CORAL}}
.ch-pulse{width:8px;height:8px;border-radius:50%;background:currentColor;position:relative;flex:none}
.ch-pulse::after{content:"";position:absolute;inset:-4px;border-radius:50%;border:2px solid currentColor;animation:chping 1.8s ease-out infinite}
@keyframes chping{0%{opacity:.8;transform:scale(.6)}100%{opacity:0;transform:scale(1.8)}}
@media (prefers-reduced-motion:reduce){.ch-pulse::after,.ch-ring::after{animation:none}}
.ch-segs{display:flex;gap:6px;flex-wrap:wrap}
.ch-seg{height:36px;padding:0 14px;border-radius:999px;border:1px solid rgba(255,255,255,.16);background:transparent;color:rgba(255,255,255,.8);font:600 13px Inter,system-ui,sans-serif;cursor:pointer}
.ch-seg:hover{background:rgba(255,255,255,.06)}
.ch-seg.sm{height:30px;padding:0 12px;font-size:12px}
.ch-seg.on{background:${GOLD};border-color:${GOLD};color:#14141A}
.ch-searchbox{position:relative;flex:1 1 260px;max-width:380px;min-width:0}
.ch-search{display:flex;align-items:center;gap:8px;height:40px;padding:0 14px;border-radius:999px;background:#1C1C24;border:1px solid rgba(255,255,255,.1);color:rgba(255,255,255,.55)}
.ch-search:focus-within{border-color:rgba(232,197,71,.6)}
.ch-search input{flex:1;min-width:0;background:transparent;border:0;outline:0;color:#F4F4F5;font:500 13.5px Inter,system-ui,sans-serif}
.ch-search input::placeholder{color:rgba(255,255,255,.5)}
.ch-results{position:absolute;top:46px;left:0;right:0;background:#23232D;border:1px solid rgba(255,255,255,.1);border-radius:14px;padding:6px;display:flex;flex-direction:column;z-index:30;box-shadow:0 14px 34px rgba(0,0,0,.5);max-height:360px;overflow-y:auto}
.ch-res{display:flex;flex-direction:column;gap:2px;text-align:left;border:0;background:transparent;color:#fff;padding:9px 12px;border-radius:10px;cursor:pointer;font:600 13.5px Inter,system-ui,sans-serif}
.ch-res:hover,.ch-res.on{background:rgba(255,255,255,.07)}
.ch-res span{font-size:12px;font-weight:500;color:rgba(255,255,255,.6)}
.ch-noresult{padding:10px 12px;font-size:13px;color:rgba(255,255,255,.6)}
.ch-btn{height:40px;padding:0 16px;border-radius:999px;border:1px solid rgba(255,255,255,.16);background:transparent;color:#F4F4F5;font:600 13.5px Inter,system-ui,sans-serif;cursor:pointer;white-space:nowrap;display:inline-flex;align-items:center;gap:8px}
.ch-btn:hover{background:rgba(255,255,255,.06)}
.ch-btn.gold{border-color:${GOLD};background:${GOLD};color:#14141A;font-weight:700}
.ch-btn.gold:hover{background:#F2D46A}
.ch-btn.sm{height:32px;padding:0 12px;font-size:12.5px}
.ch-link{border:0;background:transparent;color:${GOLD};font:600 13px Inter,system-ui,sans-serif;cursor:pointer;padding:6px 0}
.ch-link:hover{text-decoration:underline}
.ch-kpis{display:grid;grid-template-columns:repeat(auto-fit,minmax(180px,1fr));gap:12px}
@media (max-width:560px){.ch-kpis{grid-template-columns:repeat(2,minmax(0,1fr))}.ch-kpi{padding:14px}.ch-kv{font-size:28px}}
.ch-kpi{background:#1C1C24;border:1px solid rgba(255,255,255,.06);border-radius:18px;padding:16px 18px;display:flex;flex-direction:column;gap:6px;text-align:left;cursor:pointer;color:#F4F4F5;font-family:Inter,system-ui,sans-serif;min-width:0}
.ch-kpi:hover{background:#23232D}
.ch-kl{display:flex;align-items:center;gap:8px;font-size:12.5px;font-weight:600;color:rgba(255,255,255,.62)}
.ch-kv{font-size:32px;font-weight:800;line-height:1.1;color:#fff;letter-spacing:-.5px}
.ch-ks{font-size:12.5px;color:rgba(255,255,255,.62);overflow-wrap:anywhere}
.ch-kpi.hot{border-color:rgba(255,154,122,.5)}
.ch-kpi.hot .ch-kv,.ch-kpi.hot .ch-kl{color:${CORAL}}
.ch-kpi.warn .ch-kv{color:${GOLD}}
.ch-row{display:flex;flex-wrap:wrap;gap:16px;align-items:stretch}
.ch-wide{flex:999 1 560px;min-width:0}
.ch-narrow{flex:1 1 340px;min-width:0}
.ch-card{background:#1C1C24;border:1px solid rgba(255,255,255,.06);border-radius:18px;padding:18px 20px;display:flex;flex-direction:column;gap:14px;min-width:0}
.ch-chead{display:flex;flex-wrap:wrap;align-items:center;gap:10px;justify-content:space-between}
.ch-h3{margin:0;font-size:15px;font-weight:700;color:#fff;display:flex;align-items:center;gap:8px}
.ch-count{display:inline-grid;place-items:center;min-width:22px;height:22px;padding:0 7px;border-radius:8px;background:${GOLD};color:#14141A;font-size:12px;font-weight:800}
.ch-tools{display:flex;flex-wrap:wrap;align-items:center;gap:6px}
.ch-lchip{height:30px;padding:0 12px;border-radius:999px;border:1px solid rgba(255,255,255,.14);background:transparent;color:rgba(255,255,255,.55);font:600 12px Inter,system-ui,sans-serif;cursor:pointer}
.ch-lchip.on{border-color:rgba(232,197,71,.5);background:rgba(232,197,71,.1);color:${GOLD}}
.ch-map{position:relative;width:100%;flex:1 1 auto;min-height:420px;border-radius:14px;overflow:hidden;background:#0E1424}
.ch-map .ch-canvas{position:absolute;inset:0}
@media (max-width:700px){.ch-map{min-height:320px}}
.ch-mtitle{position:absolute;left:12px;top:12px;display:flex;flex-direction:column;gap:3px;background:rgba(20,20,26,.9);border:1px solid rgba(255,255,255,.08);border-radius:14px;padding:9px 13px;max-width:calc(100% - 80px);z-index:2;pointer-events:none}
.ch-mtitle b{font-size:14px;color:#fff}
.ch-mtitle span{font-size:12px;color:rgba(255,255,255,.62)}
.ch-nomap{position:absolute;inset:0;display:grid;place-items:center;color:rgba(255,255,255,.6);font-size:13px;padding:16px;text-align:center}
/* guard-pin home_marker_absolute: la raiz de un Marker de Mapbox va ABSOLUTA (como .mapboxgl-marker); con position:relative cada marcador quedaba en el flujo, corrido 30 px por cada uno anterior, y al hacer zoom los conductores se movian (dueño 2026-11-16) */
.ch-drv{width:30px;height:30px;display:grid;place-items:center;cursor:pointer;position:absolute;top:0;left:0}
.ch-drv svg{width:24px;height:24px;position:relative;transition:transform .6s ease}
.ch-drv path{fill:${GOLD};stroke:#0E1424;stroke-width:1.6;stroke-linejoin:round}
.ch-drv .ch-halo{position:absolute;inset:-4px;border-radius:50%;background:rgba(255,255,255,.12);border:2px solid ${GOLD};display:none}
.ch-drv.busy .ch-halo{display:block}
.ch-drv.busy path{fill:#fff}
/* guard-pin home_stale_driver: sin señal = SU color apagado, nunca gris (el gris se leía como En viaje; dueño 2026-11-16) */
.ch-drv.stale svg,.ch-drv.stale .ch-halo{opacity:.38}
.ch-pill{position:absolute;bottom:34px;left:50%;transform:translateX(-50%);white-space:nowrap;background:rgba(20,20,26,.92);border:1px solid rgba(255,255,255,.14);border-radius:999px;padding:3px 9px;font:700 11.5px Inter,system-ui,sans-serif;color:#fff;pointer-events:none}
.ch-drv:not(.busy) .ch-pill{display:none}
.ch-ring{width:22px;height:22px;border-radius:50%;border:3px solid ${CORAL};background:#0E1424;cursor:pointer;position:absolute;top:0;left:0;box-sizing:border-box}
.ch-ring::after{content:"";position:absolute;inset:-10px;border-radius:50%;border:2px solid ${CORAL};animation:chping 1.6s ease-out infinite}
.ch-ring .ch-pill{bottom:26px;color:${CORAL};border-color:rgba(255,154,122,.5)}
.ch-map.hide-drivers .ch-drv{display:none}
.ch-map.hide-trips .ch-ring,.ch-map.hide-trips .ch-pill,.ch-map.hide-trips .ch-halo{display:none}
.ch-legend{display:flex;flex-wrap:wrap;gap:14px;font-size:12px;color:rgba(255,255,255,.65)}
.ch-legend span{display:inline-flex;align-items:center;gap:6px}
.ch-lg{width:10px;height:10px;border-radius:50%;flex:none}
.ch-att{display:grid;grid-template-columns:40px minmax(0,1fr);column-gap:12px;row-gap:8px;align-items:start;padding:12px 0;border-top:1px solid rgba(255,255,255,.06)}
.ch-att .ch-btn{grid-column:2;justify-self:start}
.ch-att:first-child{border-top:0;padding-top:2px}
.ch-well{width:40px;height:40px;border-radius:12px;display:grid;place-items:center;flex:none}
.ch-well.hot{background:rgba(255,154,122,.14);color:${CORAL}}
.ch-well.warn{background:rgba(232,197,71,.14);color:${GOLD}}
.ch-well.info{background:#23232D;color:rgba(255,255,255,.75)}
.ch-attb{min-width:0;display:flex;flex-direction:column;gap:3px}
.ch-attb b{font-size:14px;color:#fff;font-weight:600;overflow-wrap:anywhere}
.ch-attt{display:flex;flex-wrap:wrap;align-items:center;gap:6px;font-size:11.5px;color:rgba(255,255,255,.55)}
.ch-atts{font-size:12.5px;color:rgba(255,255,255,.62);overflow-wrap:anywhere}
.ch-lvl{height:20px;padding:0 8px;border-radius:6px;font-size:11px;font-weight:800;display:inline-flex;align-items:center;letter-spacing:.2px}
.ch-lvl.hot{background:rgba(255,154,122,.16);color:${CORAL}}
.ch-lvl.warn{background:rgba(232,197,71,.16);color:${GOLD}}
.ch-lvl.info{background:#2A2A35;color:rgba(255,255,255,.75)}
.ch-tag{height:20px;padding:0 7px;border-radius:6px;background:#2A2A35;color:rgba(255,255,255,.8);font-size:11px;font-weight:700;display:inline-flex;align-items:center}
.ch-tag.gold{background:rgba(232,197,71,.14);color:${GOLD}}
.ch-attlist{display:flex;flex-direction:column;max-height:560px;overflow-y:auto}
.ch-empty{display:flex;flex-direction:column;align-items:center;text-align:center;gap:8px;padding:28px 12px}
.ch-empty .ch-well{width:52px;height:52px;border-radius:50%;background:rgba(232,197,71,.14);color:${GOLD}}
.ch-empty b{font-size:16px;color:#fff}
.ch-empty span{font-size:13px;color:rgba(255,255,255,.62);max-width:320px}
.ch-quiet{font-size:13px;color:rgba(255,255,255,.6);padding:10px 0}
.ch-trow{display:grid;grid-template-columns:96px minmax(0,1fr) auto;column-gap:14px;align-items:center;padding:12px 4px;border:0;border-top:1px solid rgba(255,255,255,.06);background:transparent;color:#F4F4F5;text-align:left;cursor:pointer;width:100%;font-family:Inter,system-ui,sans-serif}
.ch-trow:hover{background:rgba(255,255,255,.03)}
.ch-trow:first-child{border-top:0}
.ch-tid{display:flex;flex-wrap:wrap;gap:4px;align-items:center;font-size:13.5px;font-weight:700;color:#fff}
.ch-tmain{display:flex;flex-direction:column;gap:3px;min-width:0}
.ch-who{font-size:13.5px;color:#fff;overflow-wrap:anywhere}
.ch-who i,.ch-rt i{font-style:normal;color:rgba(255,255,255,.62)}
.ch-who i.none,.ch-rt i.none{color:${CORAL};font-weight:600}
.ch-rt{font-size:12.5px;color:rgba(255,255,255,.55);overflow-wrap:anywhere}
.ch-st{display:inline-flex;align-items:center;height:28px;padding:0 11px;border-radius:999px;font-size:12.5px;font-weight:700;white-space:nowrap;justify-self:end}
.ch-st.hot{background:rgba(255,154,122,.14);color:${CORAL}}
.ch-st.gold{background:rgba(232,197,71,.14);color:${GOLD}}
.ch-st.white{background:#2A2A35;color:#fff}
.ch-rrow{display:grid;grid-template-columns:100px minmax(0,1fr) auto;column-gap:14px;align-items:center;padding:12px 0;border-top:1px solid rgba(255,255,255,.06)}
.ch-rrow:first-child{border-top:0}
.ch-whenbox{display:flex;flex-direction:column;align-items:flex-start;gap:3px}
.ch-whenbox b{font-size:13.5px;color:#fff}
.ch-whenbox span{font-size:12px;color:rgba(255,255,255,.55)}
.ch-whenbox.late b,.ch-whenbox.late span{color:${CORAL}}
@media (max-width:560px){.ch-trow{grid-template-columns:72px minmax(0,1fr);row-gap:8px}.ch-trow .ch-st{grid-column:2;justify-self:start}.ch-rrow{grid-template-columns:88px minmax(0,1fr);row-gap:8px}.ch-rrow .ch-btn{grid-column:2;justify-self:start}}
.ch-hoy{display:grid;grid-template-columns:repeat(auto-fit,minmax(150px,1fr));gap:10px}
.ch-tile{background:#14141A;border-radius:14px;padding:12px 14px;display:flex;flex-direction:column;gap:4px;min-width:0}
.ch-tile span{font-size:12px;color:rgba(255,255,255,.6);font-weight:600}
.ch-tile b{font-size:22px;font-weight:800;color:#fff;letter-spacing:-.3px}
.ch-tile b.gold{color:${GOLD}}
.ch-tile i{font-style:normal;font-size:12px;color:rgba(255,255,255,.5)}
.ch-chart{display:grid;grid-template-columns:repeat(24,minmax(0,1fr));gap:4px;height:150px;align-items:end;padding-top:6px}
.ch-col{position:relative;height:100%}
.ch-lb{position:absolute;left:0;right:0;bottom:0;border-radius:4px 4px 0 0;background:rgba(255,255,255,.08)}
.ch-tb{position:absolute;left:20%;right:20%;bottom:0;border-radius:4px 4px 0 0;background:${GOLD}}
.ch-tb.now{opacity:.55}
.ch-xl{display:grid;grid-template-columns:repeat(24,minmax(0,1fr));gap:4px}
.ch-xl span{font-size:11px;color:rgba(255,255,255,.5);white-space:nowrap;overflow:visible}
.ch-key{display:flex;flex-wrap:wrap;gap:14px;font-size:12px;color:rgba(255,255,255,.65)}
.ch-key span{display:inline-flex;align-items:center;gap:6px}
.ch-sq{width:10px;height:10px;border-radius:3px;flex:none}
.ch-skel{border-radius:18px;background:linear-gradient(90deg,#1C1C24,#23232D,#1C1C24);background-size:200% 100%;animation:chsk 1.2s infinite}
@keyframes chsk{to{background-position:-200% 0}}
`;
function injectCss(){if(typeof document==="undefined"||document.getElementById("ch-home-css"))return;const s=document.createElement("style");s.id="ch-home-css";s.textContent=CSS;document.head.appendChild(s)}

// ── Small helpers ──────────────────────────────────────────────────────────
function Icon({d,size=18,sw=1.9}){return el("svg",{width:size,height:size,viewBox:"0 0 24 24",fill:"none",stroke:"currentColor",strokeWidth:sw,strokeLinecap:"round",strokeLinejoin:"round","aria-hidden":"true"},el("path",{d}))}
function clock(sec){sec=Math.max(0,Math.floor(sec));if(sec<3600)return`${Math.floor(sec/60)}:${String(sec%60).padStart(2,"0")}`;const h=Math.floor(sec/3600),m=Math.floor(sec%3600/60);return`${h} h ${String(m).padStart(2,"0")} min`}
function ago(ms){const m=Math.max(0,Math.round(ms/60000));if(m<1)return"Ahora";if(m<60)return`Hace ${m} min`;const h=Math.round(m/60);return h<48?`Hace ${h} h`:`Hace ${Math.round(h/24)} días`}
function untilText(ms){if(ms<0)return`Hace ${Math.max(1,Math.round(-ms/60000))} min`;const m=Math.round(ms/60000);if(m<60)return`En ${Math.max(1,m)} min`;return`En ${Math.round(m/60)} h`}
function money(n){const v=Number(n)||0;return`${v<0?"−":""}$${Math.abs(v).toLocaleString("en-US",{minimumFractionDigits:2,maximumFractionDigits:2})}`}
function plural(n,one,many){return n===1?one:many}
const WD=["Domingo","Lunes","Martes","Miércoles","Jueves","Viernes","Sábado"],MO=["ene","feb","mar","abr","may","jun","jul","ago","sep","oct","nov","dic"];
function nyNow(ms){try{const p={};new Intl.DateTimeFormat("en-US",{timeZone:"America/New_York",month:"numeric",day:"numeric",weekday:"short",hour:"numeric",minute:"2-digit",hour12:true}).formatToParts(new Date(ms)).forEach(x=>{p[x.type]=x.value});const wd=["Sun","Mon","Tue","Wed","Thu","Fri","Sat"].indexOf(p.weekday);return`${WD[wd]??""} ${p.day} ${MO[Number(p.month)-1]??""} · ${p.hour}:${p.minute} ${p.dayPeriod||""}`.trim()}catch{return""}}
function hourLabel(h){return h%3?"":h===0?"12 AM":h<12?`${h} AM`:h===12?"12 PM":`${h-12} PM`}
function readPref(){try{const v=localStorage.getItem(PREF_KEY);return v==="AL"||v==="FL"||v==="todos"?v:null}catch{return null}}
function writePref(v){try{localStorage.setItem(PREF_KEY,v)}catch{}}
function metersBetween(a,b){const R=6371e3,r=x=>x*Math.PI/180;const dl=r(b.lat-a.lat),dn=r(b.lng-a.lng);const h=Math.sin(dl/2)**2+Math.cos(r(a.lat))*Math.cos(r(b.lat))*Math.sin(dn/2)**2;return 2*R*Math.asin(Math.sqrt(h))}
function bearing(a,b){const r=x=>x*Math.PI/180;const y=Math.sin(r(b.lng-a.lng))*Math.cos(r(b.lat));const x=Math.cos(r(a.lat))*Math.sin(r(b.lat))-Math.sin(r(a.lat))*Math.cos(r(b.lat))*Math.cos(r(b.lng-a.lng));return(Math.atan2(y,x)*180/Math.PI+360)%360}
function okPt(p){return p&&Number.isFinite(p.lat)&&Number.isFinite(p.lng)&&!(p.lat===0&&p.lng===0)}
function marketTag(market,m){if(market!=="todos")return null;return m==="AL"||m==="FL"?m:"Otro"}
function tripPath(id){return`/viajes/viaje/sql_${id}`}

// Live-trip wording, shared by the list and the map's pills.
function liveStatus(t,nowMs){
 const since=t.since?nowMs-Date.parse(t.since):0;
 if(t.kind==="search")return{text:`Buscando · ${clock(since/1000)}`,cls:"hot"};
 if(t.kind==="wait")return{text:`Esperando · ${clock(since/1000)}`,cls:"gold"};
 if(t.kind==="pickup")return{text:t.eta_min!=null?`Yendo a recoger · ${t.eta_min} min`:"Yendo a recoger",cls:"gold"};
 return{text:t.eta_min!=null?`Con pasajero · ${t.eta_min} min`:"Con pasajero",cls:"white"};
}
function pillText(t){if(!t)return"";if(t.kind==="wait")return`#${t.id} · esperando`;return t.eta_min!=null?`#${t.id} · ${t.eta_min} min`:`#${t.id}`}
const KIND_ORDER={search:0,wait:1,pickup:2,ontrip:3};

// ── Street routes, fetched once per trip while the panel is open ───────────
const routeCache=new Map();
function routeFor(t,token){
 if(routeCache.has(t.id))return routeCache.get(t.id);
 const straight=[[t.pickup.lng,t.pickup.lat],[t.dropoff.lng,t.dropoff.lat]];
 const p=fetchStreetRoute(t.pickup,t.dropoff,token).then(r=>r.coords).catch(()=>straight);
 routeCache.set(t.id,p);
 if(routeCache.size>200){const first=routeCache.keys().next().value;routeCache.delete(first)}
 return p;
}

// ── The live map ───────────────────────────────────────────────────────────
function arrowEl(){const d=document.createElement("div");d.className="ch-drv";d.innerHTML=`<span class="ch-halo"></span><svg viewBox="0 0 24 24" aria-hidden="true"><path d="${ARROW}"/></svg><span class="ch-pill"></span>`;return d}
/*! guard-pin home_live_drivers: el Inicio escucha /admin/drivers/live y cada flecha se desliza a velocidad constante el tiempo entre lecturas (nunca 1.2 s y quieta); la consulta de 10 s no mueve a quien el flujo en vivo ya movió (dueño 2026-11-16) */
// Glide an arrow to a new reading over the time readings take to arrive
// (~5 s while driving): it reaches this one as the next lands, so it moves
// all the time instead of jumping and stopping. A jump over 3 km is a
// teleport (a new trip across town), not a drive.
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
// "sin señal hace 12 min": how long since his app last reported.
function quietFor(iso){const t=iso?Date.parse(iso):NaN;if(!isFinite(t))return"sin señal";const m=Math.max(1,Math.round((Date.now()-t)/6e4));return m<60?`sin señal hace ${m} min`:m<1440?`sin señal hace ${Math.round(m/60)} h`:`sin señal hace ${Math.round(m/1440)} d`}
function ringEl(){const d=document.createElement("div");d.className="ch-ring";d.innerHTML='<span class="ch-pill"></span>';return d}

const HomeMap=React.memo(function HomeMap({area,drivers,live,heat,layers,skewRef,title,sub,onTrip,onDriver}){
 const token=getMapboxToken();
 const box=React.useRef(null),mapRef=React.useRef(null),mk=React.useRef({drv:new Map(),ring:new Map()}),framed=React.useRef("");
 const handlers=React.useRef({onTrip,onDriver});handlers.current={onTrip,onDriver};
 const[ready,setReady]=React.useState(false);
 const here=React.useMemo(()=>({
  drivers:drivers.filter(d=>d.market===area),
  live:live.filter(t=>t.market===area),
  heat:heat.filter(c=>c.market===area),
 }),[area,drivers,live,heat]);

 React.useEffect(()=>{const node=box.current;if(!node||!token)return;mapboxgl.accessToken=token;
  const a=AREAS[area]||AREAS.AL;
  // Scrolling the page over the map must not zoom it (owner 2026-11-16): Ctrl/⌘ + wheel zooms.
  const map=new mapboxgl.Map({container:node,style:navyStyle,center:a.center,zoom:a.zoom,maxPitch:0,dragRotate:false,pitchWithRotate:false,touchPitch:false,attributionControl:true,cooperativeGestures:true});
  mapRef.current=map;map.addControl(new mapboxgl.NavigationControl({showCompass:false}),"top-right");
  map.on("load",()=>{if(mapRef.current!==map)return;map.resize();applyNavyGold(map);refineRoads(map);hideTraffic(map);
   const all=(map.getStyle()||{}).layers||[];let lastRoad=-1;all.forEach((l,i)=>{if(l.type==="line"&&/^(road|bridge|tunnel)/.test(l.id))lastRoad=i});const labels=all.find((l,i)=>i>lastRoad&&l.type==="symbol");const before=labels?labels.id:undefined;
   map.addSource("ch-heat",{type:"geojson",data:EMPTY});
   map.addLayer({id:"ch-heat-layer",type:"heatmap",source:"ch-heat",paint:{"heatmap-weight":["interpolate",["linear"],["get","w"],0,0,3,1],"heatmap-intensity":1,"heatmap-radius":["interpolate",["linear"],["zoom"],8,18,11,36,14,70],"heatmap-color":["interpolate",["linear"],["heatmap-density"],0,"rgba(232,197,71,0)",0.3,"rgba(232,197,71,0.22)",0.7,"rgba(232,197,71,0.42)",1,"rgba(245,220,122,0.6)"],"heatmap-opacity":0.9}},before);
   map.addSource("ch-routes",{type:"geojson",lineMetrics:true,data:EMPTY});
   map.addLayer({id:"ch-routes-line",type:"line",source:"ch-routes",layout:{"line-cap":"round","line-join":"round"},paint:{"line-width":4.5,"line-gradient":["interpolate",["linear"],["line-progress"],0,GOLD,1,"#FFFFFF"]}},before);
   map.addSource("ch-leads",{type:"geojson",data:EMPTY});
   map.addLayer({id:"ch-leads-line",type:"line",source:"ch-leads",layout:{"line-cap":"round"},paint:{"line-width":2.5,"line-color":GOLD,"line-opacity":0.85,"line-dasharray":[1.5,2.5]}},before);
   setReady(true)});
  const ro=typeof ResizeObserver==="undefined"?null:new ResizeObserver(()=>map.resize());ro?.observe(node);
  return()=>{ro?.disconnect();for(const m of mk.current.drv.values()){cancelAnimationFrame(m.raf);m.marker.remove()}for(const m of mk.current.ring.values())m.marker.remove();mk.current={drv:new Map(),ring:new Map()};framed.current="";mapRef.current=null;setReady(false);map.remove()}},[token]);

 // Layers on/off.
 React.useEffect(()=>{const map=mapRef.current,node=box.current;if(!node)return;
  node.parentElement?.classList.toggle("hide-drivers",!layers.drivers);node.parentElement?.classList.toggle("hide-trips",!layers.trips);
  if(!map||!ready)return;
  const vis=(id,on)=>{if(map.getLayer(id))map.setLayoutProperty(id,"visibility",on?"visible":"none")};
  vis("ch-heat-layer",layers.heat);vis("ch-routes-line",layers.trips);vis("ch-leads-line",layers.trips)},[ready,layers.drivers,layers.trips,layers.heat]);

 // Heat cells.
 React.useEffect(()=>{const map=mapRef.current;if(!map||!ready)return;
  map.getSource("ch-heat")?.setData({type:"FeatureCollection",features:here.heat.map(c=>({type:"Feature",properties:{w:c.w},geometry:{type:"Point",coordinates:[c.lng,c.lat]}}))})},[ready,here.heat]);

 // Live: each fix the moment the driver's app sends it (same SSE as the
 // fleet map). Unknown ids wait for the next poll to create their arrow.
 React.useEffect(()=>{if(!ready||typeof EventSource==="undefined")return;let es=null,retry=null,off=false;
  const connect=()=>{if(off||document.visibilityState!=="visible")return;es?.close();es=new EventSource("/admin/drivers/live");
   es.addEventListener("driver_location",ev=>{let d;try{d=JSON.parse(ev.data)}catch{return}
    if(!d||d.is_online===false)return;const m=mk.current.drv.get(Number(d.id));const lat=Number(d.lat),lng=Number(d.lng);
    if(!m||!isFinite(lat)||!isFinite(lng)||(lat===0&&lng===0))return;
    m.liveAt=Date.now();m.target={lat,lng};
    const moving=d.speed!=null&&Number(d.speed)>1.5;
    glideTo(m,m.target,moving&&d.heading!=null?Number(d.heading):null);
    m.marker.getElement().classList.remove("stale")});
   es.onerror=()=>{es?.close();es=null;if(!off){clearTimeout(retry);retry=setTimeout(connect,3000)}}};
  const vis=()=>{if(document.visibilityState==="visible"){if(!es)connect()}else{es?.close();es=null}};
  connect();document.addEventListener("visibilitychange",vis);
  return()=>{off=true;clearTimeout(retry);es?.close();document.removeEventListener("visibilitychange",vis)}},[ready]);

 // Drivers: one arrow each, gliding to each new reading.
 React.useEffect(()=>{const map=mapRef.current;if(!map||!ready)return;
  const byTrip=new Map(here.live.map(t=>[t.id,t]));const keep=new Set();
  for(const d of here.drivers){keep.add(d.id);const to={lat:d.lat,lng:d.lng};let m=mk.current.drv.get(d.id);
   if(!m){const node=arrowEl();node.addEventListener("click",()=>{const cur=mk.current.drv.get(d.id);const h=handlers.current;if(cur&&cur.tripId)h.onTrip(cur.tripId);else h.onDriver(d.id)});
    m={marker:new mapboxgl.Marker({element:node,anchor:"center"}).setLngLat([to.lng,to.lat]).addTo(map),pos:to,heading:null,raf:0,tripId:null};mk.current.drv.set(d.id,m)}
   else if(!(m.liveAt&&Date.now()-m.liveAt<20000)&&(!m.target||metersBetween(m.target,to)>0.5)){m.target=to;glideTo(m,to,null)}
   const trip=d.trip_id?byTrip.get(d.trip_id):null;m.tripId=d.busy?d.trip_id:null;
   if(m.heading==null&&trip){const target=trip.kind==="ontrip"?trip.dropoff:trip.pickup;if(okPt(target)&&metersBetween(to,target)>30)m.heading=bearing(to,target)}
   const node=m.marker.getElement();node.classList.toggle("busy",!!d.busy);node.classList.toggle("stale",!!d.stale&&!(m.liveAt&&Date.now()-m.liveAt<180000));
   node.title=(d.busy?`${d.name||"Conductor"} · viaje #${d.trip_id}`:`${d.name||"Conductor"} · libre`)+(d.stale?` · ${quietFor(d.last_seen)}`:"");
   const svg=node.querySelector("svg");if(svg)svg.style.transform=`rotate(${m.heading||0}deg)`;
   const pill=node.querySelector(".ch-pill");if(pill)pill.textContent=pillText(trip)}
  for(const[id,m]of mk.current.drv){if(!keep.has(id)){cancelAnimationFrame(m.raf);m.marker.remove();mk.current.drv.delete(id)}}},[ready,here.drivers,here.live]);

 // Trips waiting for a driver: a ring at the pickup with its clock.
 React.useEffect(()=>{const map=mapRef.current;if(!map||!ready)return;const keep=new Set();
  for(const t of here.live){if(t.kind!=="search"||!okPt(t.pickup))continue;keep.add(t.id);let m=mk.current.ring.get(t.id);
   if(!m){const node=ringEl();node.title=`Viaje #${t.id} buscando conductor`;node.addEventListener("click",()=>handlers.current.onTrip(t.id));m={marker:new mapboxgl.Marker({element:node,anchor:"center"}).setLngLat([t.pickup.lng,t.pickup.lat]).addTo(map),since:t.since};mk.current.ring.set(t.id,m)}
   m.since=t.since}
  for(const[id,m]of mk.current.ring){if(!keep.has(id)){m.marker.remove();mk.current.ring.delete(id)}}},[ready,here.live]);
 React.useEffect(()=>{const tick=()=>{const now=Date.now()+(skewRef.current||0);for(const[id,m]of mk.current.ring){const pill=m.marker.getElement().querySelector(".ch-pill");if(pill&&m.since)pill.textContent=`Buscando · ${clock((now-Date.parse(m.since))/1000)}`}};tick();const h=setInterval(tick,1000);return()=>clearInterval(h)},[ready,here.live]);

 // Routes by the streets (pickup → destination) and the dashed lead driver → pickup.
 React.useEffect(()=>{const map=mapRef.current;if(!map||!ready)return;let alive=true;
  const trips=here.live.filter(t=>t.kind!=="search"&&okPt(t.pickup)&&okPt(t.dropoff));
  Promise.all(trips.map(t=>routeFor(t,token))).then(lines=>{if(!alive)return;
   map.getSource("ch-routes")?.setData({type:"FeatureCollection",features:lines.map(coords=>({type:"Feature",properties:{},geometry:{type:"LineString",coordinates:coords}}))})});
  const pos=new Map(here.drivers.map(d=>[d.id,d]));
  map.getSource("ch-leads")?.setData({type:"FeatureCollection",features:here.live.filter(t=>t.kind==="pickup"&&pos.has(t.driver_id)&&okPt(t.pickup)).map(t=>{const d=pos.get(t.driver_id);return{type:"Feature",properties:{},geometry:{type:"LineString",coordinates:[[d.lng,d.lat],[t.pickup.lng,t.pickup.lat]]}}})});
  return()=>{alive=false}},[ready,here.live,here.drivers]);

 // Frame the state once per state; later polls never move a map the operator moved.
 React.useEffect(()=>{const map=mapRef.current;if(!map||!ready||framed.current===area)return;framed.current=area;
  const pts=[];here.drivers.forEach(d=>pts.push([d.lng,d.lat]));here.live.forEach(t=>{if(okPt(t.pickup))pts.push([t.pickup.lng,t.pickup.lat]);if(okPt(t.dropoff))pts.push([t.dropoff.lng,t.dropoff.lat])});
  const a=AREAS[area]||AREAS.AL;
  if(!pts.length){map.jumpTo({center:a.center,zoom:a.zoom});return}
  const b=new mapboxgl.LngLatBounds(pts[0],pts[0]);pts.forEach(p=>b.extend(p));
  map.fitBounds(b,{padding:{top:80,bottom:40,left:40,right:60},maxZoom:12.5,duration:0})},[ready,area,here]);

 return el("div",{className:"ch-map"},
  el("div",{ref:box,className:"ch-canvas"}),
  token?el("div",{className:"ch-mtitle"},el("b",null,title),el("span",null,sub)):el("div",{className:"ch-nomap"},"El mapa no está disponible ahora."));
});

// ── Search box ─────────────────────────────────────────────────────────────
function SearchBox({navigate}){
 const[q,setQ]=React.useState(""),[items,setItems]=React.useState(null),[open,setOpen]=React.useState(false),[sel,setSel]=React.useState(0);
 const box=React.useRef(null);
 React.useEffect(()=>{const t=q.trim();if(!t){setItems(null);return}let alive=true;
  const h=setTimeout(async()=>{try{const r=await apiGet("/admin/home/search",{query:{q:t},retry:{maxAttempts:1}});if(alive){setItems(Array.isArray(r&&r.results)?r.results:[]);setSel(0);setOpen(true)}}catch{if(alive){setItems([]);setOpen(true)}}},250);
  return()=>{alive=false;clearTimeout(h)}},[q]);
 React.useEffect(()=>{const onDoc=e=>{if(box.current&&!box.current.contains(e.target))setOpen(false)};document.addEventListener("mousedown",onDoc);return()=>document.removeEventListener("mousedown",onDoc)},[]);
 const go=it=>{if(!it)return;setOpen(false);setQ("");navigate(it.kind==="trip"?tripPath(it.id):`/personas/${it.role}/sql_${it.id}`)};
 const onKey=e=>{if(e.key==="Escape"){setOpen(false);return}if(!items||!items.length)return;if(e.key==="ArrowDown"){e.preventDefault();setSel(s=>Math.min(items.length-1,s+1))}else if(e.key==="ArrowUp"){e.preventDefault();setSel(s=>Math.max(0,s-1))}else if(e.key==="Enter"){e.preventDefault();go(items[sel])}};
 return el("div",{className:"ch-searchbox",ref:box},
  el("label",{className:"ch-search"},el(Icon,{d:I.search,size:16,sw:2}),
   el("input",{type:"search",value:q,"aria-label":"Buscar viaje, pasajero o conductor",placeholder:"Buscar viaje #, pasajero o conductor",onChange:e=>setQ(e.target.value),onFocus:()=>{if(items)setOpen(true)},onKeyDown:onKey})),
  open&&items?el("div",{className:"ch-results",role:"listbox"},
   items.length?items.map((it,i)=>el("button",{key:`${it.kind}-${it.role||""}-${it.id}`,type:"button",role:"option","aria-selected":i===sel,className:i===sel?"ch-res on":"ch-res",onMouseEnter:()=>setSel(i),onClick:()=>go(it)},it.label,el("span",null,it.sub||""))):el("div",{className:"ch-noresult"},"Sin resultados.")):null);
}

// ── Page ───────────────────────────────────────────────────────────────────
function Skeleton(){
 return el("div",{className:"ch-page"},
  el("div",{className:"ch-skel",style:{height:64}}),
  el("div",{className:"ch-kpis"},[0,1,2,3,4].map(i=>el("div",{key:i,className:"ch-skel",style:{height:112}}))),
  el("div",{className:"ch-row"},el("div",{className:"ch-skel ch-wide",style:{height:480}}),el("div",{className:"ch-skel ch-narrow",style:{height:480}})));
}

function HomeShell({fallback}){
 injectCss();
 const navigate=useNavigate();
 const[data,setData]=React.useState(null),[failed,setFailed]=React.useState(false),[offline,setOffline]=React.useState(false);
 const[market,setMarketState]=React.useState(()=>readPref()||"todos");
 const[mapPick,setMapPick]=React.useState(null);
 const[layers,setLayers]=React.useState({drivers:true,trips:true,heat:true});
 const[,setTick]=React.useState(0);
 const skewRef=React.useRef(0);
 const verif=useVerificationQueue();

 React.useEffect(()=>{let alive=true,inFlight=false;
  const load=async()=>{if(inFlight||document.visibilityState!=="visible")return;inFlight=true;
   try{const d=await apiGet("/admin/home",{retry:{maxAttempts:1}});if(!alive)return;const at=Date.parse(d&&d.now);skewRef.current=Number.isFinite(at)?at-Date.now():0;setData(d);setOffline(false)}
   catch(err){if(!alive)return;console.warn("[Inicio] /admin/home failed",err);setFailed(true);setOffline(true)}
   finally{inFlight=false}};
  load();const h=setInterval(load,POLL_MS);
  const onVis=()=>{if(document.visibilityState==="visible")load()};document.addEventListener("visibilitychange",onVis);
  return()=>{alive=false;clearInterval(h);document.removeEventListener("visibilitychange",onVis)}},[]);
 React.useEffect(()=>{const h=setInterval(()=>setTick(x=>x+1),1000);return()=>clearInterval(h)},[]);
 const openTrip=React.useCallback(id=>navigate(tripPath(id)),[navigate]);
 const openDriver=React.useCallback(id=>navigate(`/personas/driver/sql_${id}`),[navigate]);

 // Without the server's answer the old Inicio is shown.
 if(!data&&failed)return fallback;
 if(!data)return el(Skeleton,null);

 const nowMs=Date.now()+skewRef.current;
 const setMarket=m=>{setMarketState(m);writePref(m)};
 const inM=m=>market==="todos"||m===market;
 const live=(data.live||[]).filter(t=>inM(t.market)).sort((a,b)=>(KIND_ORDER[a.kind]-KIND_ORDER[b.kind])||String(a.since||"").localeCompare(String(b.since||"")));
 const drivers=(data.drivers||[]).filter(d=>inM(d.market));
 const res=(data.reservations||[]).filter(r=>inM(r.market));
 const search=live.filter(t=>t.kind==="search");
 const toPick=live.filter(t=>t.kind==="pickup"||t.kind==="wait").length,onBoard=live.filter(t=>t.kind==="ontrip").length;
 const longest=search.length?Math.max(...search.map(t=>nowMs-Date.parse(t.since))):0;
 const free=drivers.filter(d=>!d.busy).length,busyN=drivers.length-free,quietN=drivers.filter(d=>d.stale).length;
 const pid=data.pidiendo?(market==="todos"?data.pidiendo.total:(data.pidiendo.by_market||{})[market]||0):null;
 const resNo=res.filter(r=>!r.driver).length;

 const kpis=[
  {k:"viaje",label:"En viaje",icon:I.car,value:String(toPick+onBoard),sub:`${toPick} por recoger · ${onBoard} con pasajero`,cls:"ch-kpi",go:()=>navigate("/viajes/categoria/inProgress")},
  {k:"busca",label:"Buscando conductor",icon:I.radar,value:String(search.length),sub:search.length?`El que más lleva: ${clock(longest/1000)}`:"Nadie esperando",cls:search.length?"ch-kpi hot":"ch-kpi",go:()=>navigate("/viajes/categoria/active")},
  {k:"cond",label:"Conductores en línea",icon:I.wheel,value:String(drivers.length),sub:`${free} ${plural(free,"libre","libres")} · ${busyN} ${plural(busyN,"ocupado","ocupados")}`+(quietN?` · ${quietN} sin señal`:""),cls:"ch-kpi",go:()=>navigate("/mapa")},
  {k:"pide",label:"Pidiendo ahora",icon:I.user,value:pid==null?"—":String(pid),sub:pid==null?"No disponible ahora":plural(pid,"1 pasajero armando un viaje",`${pid} pasajeros armando un viaje`),cls:"ch-kpi",go:()=>navigate("/pidiendo-ahora")},
  {k:"res",label:"Reservas · 24 h",icon:I.cal,value:String(res.length),sub:resNo?`${resNo} sin conductor`:res.length?"Todas con conductor":"Ninguna por ahora",cls:resNo?"ch-kpi warn":"ch-kpi",go:()=>navigate("/reservas")},
 ];

 // Needs a person: urgent first.
 const att=[];
 for(const t of search)att.push({key:`s${t.id}`,lvl:"hot",icon:I.radar,title:`Viaje #${t.id} sin conductor`,sub:[t.rider,t.tier,t.from&&t.to?`${t.from} → ${t.to}`:""].filter(Boolean).join(" · "),time:`Lleva ${clock((nowMs-Date.parse(t.since))/1000)}`,tag:marketTag(market,t.market),action:"Ofrecer",go:()=>openTrip(t.id),order:0});
 for(const r of res){if(r.driver)continue;const left=Date.parse(r.at)-nowMs;att.push({key:`r${r.id}`,lvl:left<=3600e3?"hot":"warn",icon:I.cal,title:`Reserva #${r.id} sin conductor`,sub:[`${r.day} ${r.time}`,r.from&&r.to?`${r.from} → ${r.to}`:""].filter(Boolean).join(" · "),time:untilText(left),tag:marketTag(market,r.market),action:"Asignar",go:()=>openTrip(r.id),order:left<=3600e3?1:3})}
 for(const c of (data.attention&&data.attention.chats)||[])att.push({key:`c${c.chat_id}`,lvl:"warn",icon:I.chat,title:`${c.name} espera respuesta`,sub:`Chat de soporte · ${c.role==="driver"?"conductor":"pasajero"}`,time:ago(nowMs-Date.parse(c.since)),tag:null,action:"Responder",go:()=>navigate(`/soporte/chat/${c.chat_id}`),order:2});
 for(const c of ((data.attention&&data.attention.charges)||[]).filter(c=>inM(c.market)))att.push({key:`p${c.trip_id}`,lvl:"info",icon:I.card,title:`Cobro rechazado · viaje #${c.trip_id}`,sub:[c.rider,money(c.amount)].filter(Boolean).join(" · "),time:ago(nowMs-Date.parse(c.at)),tag:marketTag(market,c.market),action:"Ver viaje",go:()=>openTrip(c.trip_id),order:4});
 const vRows=(verif&&!verif.loading&&!verif.error&&verif.rows)||[];
 const vDrivers=vRows.filter(r=>r.role==="driver"&&r.status==="pending").length,vRiders=vRows.filter(r=>r.role==="rider"&&r.status==="pending").length;
 if(vDrivers+vRiders>0)att.push({key:"verif",lvl:"info",icon:I.shield,title:`${vDrivers+vRiders} ${plural(vDrivers+vRiders,"verificación pendiente","verificaciones pendientes")}`,sub:[vDrivers?`${vDrivers} ${plural(vDrivers,"conductor","conductores")}`:"",vRiders?`${vRiders} ${plural(vRiders,"pasajero","pasajeros")}`:""].filter(Boolean).join(" · "),time:"",tag:null,action:"Revisar",go:()=>navigate("/verificacion"),order:5});
 const po=data.attention&&data.attention.payouts;
 if(po)att.push({key:"payout",lvl:"info",icon:I.wallet,title:`Pago falló a ${po.drivers} ${plural(po.drivers,"conductor","conductores")}`,sub:`${money(po.amount)} sin enviar`,time:po.at?ago(nowMs-Date.parse(po.at)):"",tag:null,action:"Ver pagos",go:()=>navigate("/pagos"),order:6});
 att.sort((a,b)=>a.order-b.order);

 // Hoy.
 const T=data.today||{};const keys=market==="todos"?["AL","FL","other"]:[market];
 const day={done:0,canc:0,cobrado:0,cond:0,hours:Array(24).fill(0),last:Array(24).fill(0)};
 for(const k of keys){const d=T[k];if(!d)continue;day.done+=d.done;day.canc+=d.canc;day.cobrado+=d.cobrado;day.cond+=d.cond;for(let h=0;h<24;h++){day.hours[h]+=(d.hours&&d.hours[h])||0;day.last[h]+=(d.last&&d.last[h])||0}}
 const nowHour=((T[market==="todos"?"FL":market]||T.FL||{}).now_hour)??new Date().getHours();
 const cruise=Math.round((day.cobrado-day.cond)*100)/100;
 const cancPct=day.done+day.canc?Math.round(day.canc/(day.done+day.canc)*100):0;
 const tiles=[
  {label:"Completados",value:String(day.done),sub:plural(day.done,"viaje terminado","viajes terminados")},
  {label:"Cancelados",value:String(day.canc),sub:`${cancPct}% de los pedidos`},
  {label:"Cobrado",value:money(day.cobrado),sub:"pagado por los pasajeros"},
  {label:"A conductores",value:money(day.cond),sub:"su parte de hoy"},
  {label:"Para Cruise",value:money(cruise),sub:cruise<0?"Cruise puso de su parte":"cobrado menos conductores",gold:true},
 ];
 const max=Math.max(1,...day.hours,...day.last);
 const todayTotal=day.hours.slice(0,nowHour+1).reduce((s,v)=>s+v,0),lastSoFar=day.last.slice(0,nowHour+1).reduce((s,v)=>s+v,0);

 // Map: the chosen state, or (Todos) the busier one unless the operator picked.
 const count=m=>(data.drivers||[]).filter(d=>d.market===m).length+(data.live||[]).filter(t=>t.market===m).length;
 const area=market==="AL"||market==="FL"?market:(mapPick||(count("FL")>count("AL")?"FL":"AL"));
 const aDrivers=(data.drivers||[]).filter(d=>d.market===area),aLive=(data.live||[]).filter(t=>t.market===area&&t.kind!=="search");
 const aQuiet=aDrivers.filter(d=>d.stale).length;
 const mapSub=`${aDrivers.length} ${plural(aDrivers.length,"conductor","conductores")} en línea · ${aLive.length} en viaje`+(aQuiet?` · ${aQuiet} sin señal`:"");

 return el("div",{className:"ch-page"},
  el("header",{className:"ch-head"},
   el("div",{className:"ch-titlebox"},
    el("h1",{className:"ch-h1"},"Inicio"),
    el("div",{className:"ch-when"},el("span",null,nyNow(nowMs)),
     offline?el("span",{className:"ch-live off"},el("span",{className:"ch-pulse"}),"Sin conexión · reintentando"):el("span",{className:"ch-live"},el("span",{className:"ch-pulse"}),"En vivo"))),
   el("div",{className:"ch-segs",role:"group","aria-label":"Estado"},[["todos","Todos"],["AL","Alabama"],["FL","Florida"]].map(([id,label])=>el("button",{key:id,type:"button","aria-pressed":market===id,className:market===id?"ch-seg on":"ch-seg",onClick:()=>setMarket(id)},label))),
   el(SearchBox,{navigate}),
   el("button",{type:"button",className:"ch-btn gold",onClick:()=>navigate("/viajes/nuevo")},el(Icon,{d:I.plus,size:16,sw:2.4}),"Nuevo viaje")),

  el("section",{className:"ch-kpis","aria-label":"Ahora mismo"},kpis.map(k=>el("button",{key:k.k,type:"button",className:k.cls,onClick:k.go},
   el("span",{className:"ch-kl"},el(Icon,{d:k.icon,size:16,sw:2}),k.label),el("span",{className:"ch-kv"},k.value),el("span",{className:"ch-ks"},k.sub)))),

  el("div",{className:"ch-row"},
   el("section",{className:"ch-card ch-wide","aria-label":"Mapa en vivo"},
    el("div",{className:"ch-chead"},el("h2",{className:"ch-h3"},"Mapa en vivo"),
     el("div",{className:"ch-tools"},
      market==="todos"?[["AL","Alabama"],["FL","Florida"]].map(([id,label])=>el("button",{key:id,type:"button","aria-pressed":area===id,className:area===id?"ch-seg sm on":"ch-seg sm",onClick:()=>setMapPick(id)},label)):null,
      [["drivers","Conductores"],["trips","Viajes"],["heat","Calor"]].map(([k,label])=>el("button",{key:k,type:"button","aria-pressed":layers[k],className:layers[k]?"ch-lchip on":"ch-lchip",onClick:()=>setLayers(l=>Object.assign({},l,{[k]:!l[k]}))},label)))),
    el(HomeMap,{area,drivers:data.drivers||[],live:data.live||[],heat:data.heat||[],layers,skewRef,title:AREAS[area].name,sub:mapSub,onTrip:openTrip,onDriver:openDriver}),
    el("div",{className:"ch-chead"},
     el("div",{className:"ch-legend"},
      el("span",null,el("svg",{width:14,height:14,viewBox:"0 0 24 24","aria-hidden":"true"},el("path",{d:ARROW,fill:GOLD})),"Libre"),
      el("span",null,el("svg",{width:14,height:14,viewBox:"0 0 24 24","aria-hidden":"true"},el("path",{d:ARROW,fill:"#FFFFFF"})),"En viaje"),
      el("span",{title:"Su app no manda ubicación hace más de 3 min (teléfono bloqueado, app cerrada o sin conexión)"},el("svg",{width:14,height:14,viewBox:"0 0 24 24","aria-hidden":"true",style:{opacity:.38}},el("path",{d:ARROW,fill:GOLD})),"Sin señal"),
      el("span",null,el("span",{className:"ch-lg",style:{border:`2px solid ${CORAL}`}}),"Buscando conductor"),
      el("span",null,el("span",{className:"ch-lg",style:{background:"rgba(232,197,71,.45)"}}),"Pasajeros armando un viaje")),
     el("button",{type:"button",className:"ch-link",onClick:()=>navigate("/mapa")},"Abrir el mapa completo →"))),

   el("section",{className:"ch-card ch-narrow","aria-label":"Necesita atención"},
    el("div",{className:"ch-chead"},el("h2",{className:"ch-h3"},"Necesita atención",att.length?el("span",{className:"ch-count"},String(att.length)):null)),
    att.length?el("div",{className:"ch-attlist"},att.map(a=>el("div",{key:a.key,className:"ch-att"},
     el("span",{className:`ch-well ${a.lvl}`},el(Icon,{d:a.icon,size:19})),
     el("div",{className:"ch-attb"},
      el("span",{className:"ch-attt"},el("span",{className:`ch-lvl ${a.lvl}`},a.lvl==="hot"?"Urgente":a.lvl==="warn"?"Pronto":"Revisar"),a.tag?el("span",{className:"ch-tag"},a.tag):null,a.time?el("span",null,a.time):null),
      el("b",null,a.title),
      a.sub?el("span",{className:"ch-atts"},a.sub):null),
     el("button",{type:"button",className:"ch-btn sm",onClick:a.go},a.action)))):
    el("div",{className:"ch-empty"},el("span",{className:"ch-well"},el(Icon,{d:I.check,size:24,sw:2.4})),el("b",null,"Todo al día"),el("span",null,"Aquí sale solo lo que necesita una persona: viajes sin conductor, reservas sin conductor, chats esperando, cobros rechazados.")))),

  el("div",{className:"ch-row"},
   el("section",{className:"ch-card ch-wide","aria-label":"Viajes en vivo"},
    el("div",{className:"ch-chead"},el("h2",{className:"ch-h3"},"En vivo",el("span",{className:"ch-count"},String(live.length))),el("button",{type:"button",className:"ch-link",onClick:()=>navigate("/viajes")},"Ver todos los viajes →")),
    live.length?el("div",null,live.map(t=>{const st=liveStatus(t,nowMs);const tag=marketTag(market,t.market);
     return el("button",{key:t.id,type:"button",className:"ch-trow",onClick:()=>openTrip(t.id)},
      el("span",{className:"ch-tid"},`#${t.id}`,tag?el("span",{className:"ch-tag"},tag):null,t.reservation?el("span",{className:"ch-tag gold"},"Reserva"):null),
      el("span",{className:"ch-tmain"},
       el("span",{className:"ch-who"},t.rider||"Pasajero"," ",t.driver?el("i",null,`· con ${t.driver}`):el("i",{className:"none"},"· Sin conductor")),
       el("span",{className:"ch-rt"},[t.tier,t.from&&t.to?`${t.from} → ${t.to}`:t.from||t.to].filter(Boolean).join(" · "))),
      el("span",{className:`ch-st ${st.cls}`},st.text))})):el("div",{className:"ch-quiet"},"No hay viajes en curso ahora.")),

   el("section",{className:"ch-card ch-narrow","aria-label":"Próximas reservas"},
    el("div",{className:"ch-chead"},el("h2",{className:"ch-h3"},"Próximas reservas · 24 h"),el("button",{type:"button",className:"ch-link",onClick:()=>navigate("/reservas")},"Ver todas →")),
    res.length?el("div",null,res.slice(0,8).map(r=>{const late=!r.driver&&Date.parse(r.at)<nowMs;const tag=marketTag(market,r.market);
     return el("div",{key:r.id,className:"ch-rrow"},
      el("span",{className:late?"ch-whenbox late":"ch-whenbox"},el("b",null,r.day),el("span",null,r.time),tag?el("span",{className:"ch-tag"},tag):null),
      el("span",{className:"ch-tmain"},
       el("span",{className:"ch-who"},r.from||`Reserva #${r.id}`),
       r.to?el("span",{className:"ch-who"},`→ ${r.to}`):null,
       el("span",{className:"ch-rt"},r.driver?el("i",null,r.driver):el("i",{className:"none"},"Sin conductor"),r.tier?` · ${r.tier}`:"")),
      el("button",{type:"button",className:r.driver?"ch-btn sm":"ch-btn sm gold",onClick:()=>openTrip(r.id)},r.driver?"Ver":"Asignar"))})):el("div",{className:"ch-quiet"},"Sin reservas en las próximas 24 horas."))),

  el("section",{className:"ch-card","aria-label":"Hoy"},
   el("div",{className:"ch-chead"},el("h2",{className:"ch-h3"},"Hoy"),el("button",{type:"button",className:"ch-link",onClick:()=>navigate("/reportes")},"Ver reportes →")),
   el("div",{className:"ch-hoy"},tiles.map(t=>el("div",{key:t.label,className:"ch-tile"},el("span",null,t.label),el("b",{className:t.gold?"gold":""},t.value),el("i",null,t.sub)))),
   el("div",{className:"ch-chead",style:{marginTop:4}},el("span",{style:{fontSize:13.5,fontWeight:700,color:"#fff"}},"Viajes por hora"),
    el("div",{className:"ch-key"},el("span",null,el("span",{className:"ch-sq",style:{background:GOLD}}),"Hoy"),el("span",null,el("span",{className:"ch-sq",style:{background:"rgba(255,255,255,.18)"}}),"Mismo día la semana pasada"))),
   el("div",{className:"ch-chart",role:"img","aria-label":`Viajes por hora: hoy ${todayTotal} hasta esta hora, la semana pasada ${lastSoFar} a la misma hora.`},
    day.last.map((lv,h)=>el("div",{key:h,className:"ch-col"},
     el("div",{className:"ch-lb",style:{height:`${Math.round(lv/max*100)}%`}}),
     el("div",{className:h===nowHour?"ch-tb now":"ch-tb",style:{height:`${h<=nowHour?Math.round((day.hours[h]||0)/max*100):0}%`}})))),
   el("div",{className:"ch-xl","aria-hidden":"true"},day.last.map((_,h)=>el("span",{key:h},hourLabel(h))))));
}

export{HomeShell};
