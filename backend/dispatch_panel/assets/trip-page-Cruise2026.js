/*! guard-pin panel_trip_page: página del viaje estilo Lyft (dueño 2026-11-16, dibujo https://claude.ai/artifact/1AXDLBTjRMz3PLXZHcXeZW) - chunk escrito a mano, sin fuente React (CLAUDE.md #30). Lo monta TripDetailScreen (index-B68rRA9U.js) ALREDEDOR de lo de siempre: el encabezado, las tarjetas y los botones viejos son los mismos elementos (mismos handlers y ventanas), solo cambian de lugar. Las tarjetas son las del dibujo (Ruta, Línea de tiempo, Pasajera, Conductor, Dinero) con GET /admin/trips/{id}/page; si eso falla se ven las tarjetas viejas. Mapa con la ruta y el conductor en vivo (GET /admin/trips/{id}/live) y barra de progreso con la hora de cada paso. */
import{y as useNavigate}from"./vendor-react-DprhJQz-.js";
import{r as React,j as J}from"./vendor-react-DprhJQz-.js";
import{m as mapboxgl}from"./vendor-mapbox-ComAnvan.js";
import{N as navyStyle,a as applyNavyGold,r as refineRoads,h as hideTraffic}from"./mapNavyGold-CiIxy5Vj.js";
import{m as getMapboxToken}from"./mapboxToken-DDoCRQix.js";
import{W as apiGet,L as apiPost}from"./index-CuQT_62K.js";
import{fetchStreetRoute,okPoint}from"./trip-route-map-Cruise2026.js";
import{ZoneTime}from"./local-zone-Cruise2026.js";

function el(type,props,...kids){
 const p=Object.assign({},props||{});const key=p.key;delete p.key;
 const c=kids.filter(k=>k!==undefined);
 if(c.length===1)p.children=c[0];else if(c.length>1)p.children=c;
 return c.length>1?J.jsxs(type,p,key):J.jsx(type,p,key);
}

const GOLD="#E8C547";
const EMPTY={type:"FeatureCollection",features:[]};
const LIVE_MS=6000,IDLE_MS=15000,LEAD_REFRESH_MS=30000,LEAD_MOVE_M=150,STALE_MS=90000;

const CSS=`
.tp-page{display:flex;flex-direction:column;gap:14px;min-width:0}
.tp-head{display:flex;flex-direction:column;gap:12px;background:#1C1C24;border:1px solid rgba(255,255,255,.06);border-radius:20px;padding:16px 18px;min-width:0}
.tp-head .mb-4{margin-bottom:0!important}
.tp-chips{display:flex;flex-wrap:wrap;gap:8px}
.tp-chip{display:inline-flex;align-items:center;gap:6px;height:26px;padding:0 10px;border-radius:999px;background:#23232D;color:rgba(255,255,255,.75);font:600 12px Inter,system-ui,sans-serif;white-space:nowrap}
.tp-chip.gold{background:rgba(232,197,71,.12);color:${GOLD}}
.tp-actions{display:flex;flex-wrap:wrap;gap:8px;align-items:center}
.tp-moreBox{position:relative}
.tp-more{height:40px;padding:0 14px;border-radius:12px;border:1px solid rgba(255,255,255,.14);background:transparent;color:#fff;font:600 13.5px Inter,system-ui,sans-serif;cursor:pointer}
.tp-more:hover,.tp-more.on{background:#23232D}
.tp-menu{position:absolute;top:calc(100% + 6px);left:0;min-width:230px;background:#23232D;border:1px solid rgba(255,255,255,.1);border-radius:14px;padding:8px;display:flex;flex-direction:column;gap:6px;z-index:40;box-shadow:0 14px 34px rgba(0,0,0,.5)}
.tp-menu>*{width:100%;justify-content:flex-start}
.tp-steps{display:flex;gap:10px;flex-wrap:wrap;background:#1C1C24;border:1px solid rgba(255,255,255,.06);border-radius:18px;padding:14px 18px}
.tp-step{flex:1 1 0;min-width:96px;display:flex;flex-direction:column;gap:6px}
.tp-bar{height:4px;border-radius:4px;background:#2A2A35}
.tp-bar.done{background:${GOLD}}
.tp-bar.now{background:linear-gradient(90deg,${GOLD} 55%,#2A2A35 55%)}
.tp-bar.off{background:#5A5A66}
.tp-sl{font:700 12.5px Inter,system-ui,sans-serif;color:rgba(255,255,255,.45)}
.tp-sl.on{color:#fff}
.tp-st{font:500 11.5px Inter,system-ui,sans-serif;color:rgba(255,255,255,.45)}
.tp-grid{display:grid;grid-template-columns:minmax(0,1.7fr) minmax(0,1fr);gap:14px;align-items:start}
@media(max-width:980px){.tp-grid{grid-template-columns:minmax(0,1fr)}}
.tp-col{display:flex;flex-direction:column;gap:12px;min-width:0}
.tp-map{position:relative;height:430px;border-radius:18px;overflow:hidden;border:1px solid rgba(255,255,255,.08);background:#0f1626}
@media(max-width:620px){.tp-map{height:320px}}
.tp-map>.tp-canvas{position:absolute;inset:0}
.tp-pill{position:absolute;left:14px;top:14px;z-index:2;max-width:calc(100% - 90px);box-sizing:border-box;background:rgba(20,20,26,.92);border:1px solid rgba(255,255,255,.08);border-radius:14px;padding:9px 13px;display:flex;flex-direction:column;gap:2px;pointer-events:none}
.tp-pill b{font:700 14.5px Inter,system-ui,sans-serif;color:#fff}
.tp-pill span{font:500 12px Inter,system-ui,sans-serif;color:rgba(255,255,255,.62)}
.tp-mapbtns{position:absolute;right:12px;bottom:34px;z-index:2;display:flex;gap:8px}
.tp-mapbtn{height:32px;padding:0 12px;border-radius:999px;border:1px solid rgba(255,255,255,.16);background:rgba(20,20,26,.92);color:#fff;font:600 12.5px Inter,system-ui,sans-serif;cursor:pointer}
.tp-mapbtn.on{border-color:${GOLD};color:${GOLD}}
.tp-hint{position:absolute;inset:0;display:grid;place-items:center;pointer-events:none;z-index:2}
.tp-hint span{background:rgba(20,20,26,.88);border-radius:999px;padding:7px 14px;font:500 12px Inter,system-ui,sans-serif;color:#9a9aa4}
.tp-ring{width:18px;height:18px;border-radius:50%;box-sizing:border-box;background:#0f1626;display:grid;place-items:center;box-shadow:0 2px 8px rgba(0,0,0,.5)}
.tp-ring.pick{border:3.5px solid ${GOLD}}
.tp-ring.pick::after{content:"";width:5px;height:5px;border-radius:50%;background:${GOLD}}
.tp-ring.drop{border:3.5px solid #fff}
.tp-car{width:40px;height:40px;display:grid;place-items:center;border-radius:50%;background:rgba(232,197,71,.18)}
.tp-car svg{width:22px;height:22px;transition:transform .6s ease;filter:drop-shadow(0 2px 4px rgba(0,0,0,.6))}
.tp-car.stale{background:rgba(255,255,255,.08)}
.tp-car.stale svg path{fill:#9a9aa4}
.tp-top{display:flex;flex-wrap:wrap;align-items:center;gap:14px;min-width:0}
.tp-back{width:40px;height:40px;border-radius:50%;border:1px solid rgba(255,255,255,.16);background:transparent;color:#fff;font-size:18px;cursor:pointer;flex:none}
.tp-back:hover{background:#23232D}
.tp-titlebox{display:flex;flex-direction:column;gap:8px;flex:1 1 320px;min-width:0}
.tp-tline{display:flex;flex-wrap:wrap;align-items:center;gap:10px}
.tp-h1{margin:0;font:700 24px Inter,system-ui,sans-serif;color:#fff}
.tp-chip.plain{background:#23232D;color:#fff}
.tp-chip.dim{background:#23232D;color:rgba(255,255,255,.55)}
.tp-card{background:#1C1C24;border:1px solid rgba(255,255,255,.06);border-radius:18px;padding:16px 18px;display:flex;flex-direction:column;gap:12px;min-width:0}
.tp-h3{margin:0;font:700 15px Inter,system-ui,sans-serif;color:#fff;display:flex;justify-content:space-between;align-items:center;gap:8px}
.tp-link{border:0;background:transparent;color:${GOLD};font:600 13px Inter,system-ui,sans-serif;cursor:pointer;padding:0}
.tp-link:hover{text-decoration:underline}
.tp-muted{color:rgba(255,255,255,.55);font:500 12.5px Inter,system-ui,sans-serif}
.tp-small{font:500 12px Inter,system-ui,sans-serif;color:rgba(255,255,255,.5)}
.tp-kv{display:flex;justify-content:space-between;gap:12px;font:13.5px Inter,system-ui,sans-serif;padding:8px 0;border-top:1px solid rgba(255,255,255,.06)}
.tp-kv:first-child{border-top:0}
.tp-kv span{color:rgba(255,255,255,.55)}
.tp-kv b{font-weight:600;color:#fff;text-align:right}
.tp-kv.tot{border-top:1px solid rgba(255,255,255,.2)}
.tp-kv.tot span,.tp-kv.tot b{color:#fff;font-weight:700}
.tp-kv.gold b{color:${GOLD}}
.tp-note{background:#14141A;border-radius:12px;padding:10px 12px;font:12.5px/1.45 Inter,system-ui,sans-serif;color:rgba(255,255,255,.72);white-space:pre-wrap;overflow-wrap:anywhere}
.tp-person{display:flex;gap:12px;align-items:center;min-width:0}
.tp-av{width:44px;height:44px;border-radius:50%;flex:none;display:grid;place-items:center;font:800 14px Inter,system-ui,sans-serif;background:rgba(232,197,71,.16);color:${GOLD};object-fit:cover}
.tp-pinfo{display:flex;flex-direction:column;gap:2px;min-width:0}
.tp-pinfo b{font:700 15px Inter,system-ui,sans-serif;color:#fff}
.tp-pinfo span{font:500 12.5px Inter,system-ui,sans-serif;color:rgba(255,255,255,.55)}
.tp-pinfo .tp-live{color:${GOLD};font-weight:600}
.tp-row{display:flex;flex-wrap:wrap;gap:8px}
.tp-row-end{display:flex;flex-wrap:wrap;gap:8px;justify-content:flex-end}
.tp-btn{height:40px;padding:0 14px;border-radius:999px;border:1px solid rgba(255,255,255,.16);background:transparent;color:#fff;font:600 13.5px Inter,system-ui,sans-serif;cursor:pointer;display:inline-flex;align-items:center;justify-content:center;text-decoration:none}
.tp-btn:hover{background:#23232D}
.tp-btn.sm{height:32px;padding:0 12px;font-size:12.5px}
.tp-btn.gold{background:${GOLD};border-color:${GOLD};color:#14141A}
.tp-rail{display:flex;flex-direction:column;gap:16px;position:relative;padding-left:24px}
.tp-stop{position:relative;display:flex;flex-direction:column;gap:2px;min-width:0}
.tp-stop::before{content:"";position:absolute;left:-24px;top:16px;width:12px;height:12px;border-radius:50%;border:3px solid ${GOLD};background:#1C1C24;box-sizing:border-box}
.tp-stop.end::before{border-color:#fff}
.tp-stop:not(.end)::after{content:"";position:absolute;left:-19px;top:28px;bottom:-32px;width:2px;background:linear-gradient(${GOLD},#fff)}
.tp-stop b{font:600 14px Inter,system-ui,sans-serif;color:#fff;overflow-wrap:anywhere}
.tp-tl{display:flex;gap:12px;align-items:flex-start;font:13.5px Inter,system-ui,sans-serif}
.tp-dot{width:10px;height:10px;border-radius:50%;margin-top:4px;flex:none;border:2px solid #4B4B57;box-sizing:border-box}
.tp-dot.on{border-color:${GOLD};background:${GOLD}}
.tp-tlw{flex:1;color:#fff;min-width:0}
.tp-tlt{color:rgba(255,255,255,.5);white-space:nowrap}
.tp-ov{position:fixed;inset:0;background:rgba(5,5,8,.72);display:flex;justify-content:center;align-items:flex-start;padding:80px 16px 16px;box-sizing:border-box;z-index:60}
.tp-dlg{width:100%;max-width:420px;background:#1C1C24;border:1px solid rgba(255,255,255,.08);border-radius:20px;padding:20px;display:flex;flex-direction:column;gap:14px;box-sizing:border-box}
.tp-dh{display:flex;justify-content:space-between;align-items:flex-start;gap:12px}
.tp-dh h2{margin:0;font:700 18px Inter,system-ui,sans-serif;color:#fff}
.tp-x{width:34px;height:34px;border-radius:50%;border:1px solid rgba(255,255,255,.16);background:transparent;color:#fff;font-size:16px;cursor:pointer;flex:none}
.tp-phone{font:700 26px Inter,system-ui,sans-serif;color:#fff;user-select:all}
.tp-skel{height:120px;border-radius:18px;background:linear-gradient(90deg,#1C1C24,#23232D,#1C1C24);background-size:200% 100%;animation:tpsk 1.2s infinite}
@keyframes tpsk{to{background-position:-200% 0}}
.tp-dlg-wide{max-width:600px}
.tp-air{display:flex;flex-wrap:wrap;gap:6px;align-items:center;margin-top:4px}
.tp-airlogo{width:18px;height:18px;border-radius:5px;background:#fff;object-fit:cover;flex:none}
.tp-airlogo.big{width:36px;height:36px;border-radius:9px}
.tp-airlogo.none{display:grid;place-items:center;background:#23232D;color:#fff;font-size:16px}
.tp-airgrid{display:grid;grid-template-columns:repeat(auto-fill,minmax(150px,1fr));gap:8px;max-height:380px;overflow-y:auto}
.tp-airtile{display:flex;flex-direction:column;align-items:flex-start;gap:6px;padding:10px;border-radius:14px;border:1px solid rgba(255,255,255,.1);background:#14141A;color:#F4F4F5;font:600 13px Inter,system-ui,sans-serif;cursor:pointer;text-align:left}
.tp-airtile:hover{border-color:rgba(255,255,255,.25)}
.tp-airtile.on{border-color:#E8C547;background:rgba(232,197,71,.08)}
.tp-stop .tp-link{align-self:flex-start;margin-top:4px}
`;
function ensureCss(){
 if(typeof document==="undefined")return;
 if(!document.getElementById("trm-mapbox-css")){const l=document.createElement("link");l.id="trm-mapbox-css";l.rel="stylesheet";l.href=new URL("./vendor-mapbox-EidcXNcp.css",import.meta.url).href;document.head.appendChild(l)}
 if(!document.getElementById("tp-css")){const s=document.createElement("style");s.id="tp-css";s.textContent=CSS;document.head.appendChild(s)}
}

// ── Small helpers ─────────────────────────────────────────────────────
const TZ="America/New_York";
const MES=["ene","feb","mar","abr","may","jun","jul","ago","sep","oct","nov","dic"];
function when(d){if(!d)return null;const x=d instanceof Date?d:new Date(d);if(isNaN(x.getTime()))return null;const p=Object.fromEntries(new Intl.DateTimeFormat("en-US",{timeZone:TZ,year:"numeric",month:"numeric",day:"numeric",hour:"numeric",minute:"2-digit",hour12:true}).formatToParts(x).map(q=>[q.type,q.value]));return`${+p.day} ${MES[+p.month-1]} · ${p.hour}:${p.minute} ${p.dayPeriod}`}
const firstName=n=>{const s=String(n||"").trim();return s?s.split(/\s+/)[0]:""};
const TIER={standard:"Standard",sedan:"Standard",economy:"Standard",compact:"Compact",comfort:"Comfort",premium:"Premium",vip:"VIP",electric_pro:"Electric Pro",suv:"SUV",xl:"XL"};
const tierName=v=>{const k=String(v||"").toLowerCase();return TIER[k]||(v?String(v):"")};
function metersBetween(a,b){const R=6371e3,r=x=>x*Math.PI/180;const dl=r(b.lat-a.lat),dn=r(b.lng-a.lng);const h=Math.sin(dl/2)**2+Math.cos(r(a.lat))*Math.cos(r(b.lat))*Math.sin(dn/2)**2;return 2*R*Math.asin(Math.sqrt(h))}
function bearing(a,b){const r=x=>x*Math.PI/180;const y=Math.sin(r(b.lng-a.lng))*Math.cos(r(b.lat));const x=Math.cos(r(a.lat))*Math.sin(r(b.lat))-Math.sin(r(a.lat))*Math.cos(r(b.lat))*Math.cos(r(b.lng-a.lng));return(Math.atan2(y,x)*180/Math.PI+360)%360}
function isReservation(t){const s=t.scheduledAtDate,c=t.createdAt;return!!(s&&c&&s.getTime()-c.getTime()>=3*60e3)}
function textOf(node){if(node==null||node===false)return"";if(typeof node==="string"||typeof node==="number")return String(node);if(Array.isArray(node))return node.map(textOf).join("");return node.props?textOf(node.props.children):""}
const kidsOf=node=>node&&node.props?(Array.isArray(node.props.children)?node.props.children:[node.props.children]).filter(c=>c!=null&&c!==false&&c!==true):[];

// Where the trip stands. The panel model folds driver_en_route and a
// reservation with its driver into "accepted"; the server's raw status
// (from /live) tells them apart.
function stage(raw,panel){
 const s=String(raw||"").toLowerCase();
 if(s)return({requested:0,scheduled:0,scheduled_accepted:1,scheduled_active:1,accepted:1,driver_assigned:1,driver_en_route:2,arrived:3,driver_arrived:3,in_trip:4,in_progress:4,completed:5,cancelled:-1,canceled:-1})[s]??null;
 return({requested:0,scheduled:0,accepted:1,driverArrived:3,inProgress:4,completed:5,cancelled:-1})[panel]??0;
}

function Steps({t,raw}){
 const at=stage(raw,t.status);
 const labels=["Pedido","Conductor asignado","En camino","Llegó","En viaje","Terminado"];
 const times=[t.createdAt,t.acceptedAt,null,t.driverArrivedAt,t.startedAt,t.completedAt];
 if(at===-1){
  const reached=[0,1,3,4].filter(i=>times[i]);
  const rows=reached.map(i=>({label:labels[i],time:when(times[i]),bar:"tp-bar done",on:true}));
  rows.push({label:"Cancelado",time:when(t.cancelledAt)||"—",bar:"tp-bar off",on:true});
  return el("section",{className:"tp-steps","aria-label":"Progreso del viaje"},rows.map((r,i)=>el("div",{className:"tp-step",key:i},el("div",{className:r.bar}),el("span",{className:"tp-sl on"},r.label),el("span",{className:"tp-st"},r.time))));
 }
 const cur=at==null?0:at;
 return el("section",{className:"tp-steps","aria-label":"Progreso del viaje"},labels.map((label,i)=>{
  const done=i<cur||cur===5,now=i===cur&&cur!==5;
  const time=times[i]?when(times[i]):now?"ahora":done?"":"—";
  return el("div",{className:"tp-step",key:i},el("div",{className:done?"tp-bar done":now?"tp-bar now":"tp-bar"}),el("span",{className:done||now?"tp-sl on":"tp-sl"},label),el("span",{className:"tp-st"},time));
 }));
}

// ── Live data ─────────────────────────────────────────────────────────
function useLive(id,terminal){
 const[live,setLive]=React.useState(null);
 React.useEffect(()=>{if(!(id>0))return;let off=false,timer=0;
  const tick=async()=>{let next=IDLE_MS;try{const d=await apiGet(`/admin/trips/${id}/live`,{retry:{maxAttempts:1}});if(off)return;setLive(d);if(d&&d.live)next=LIVE_MS;if(d&&(d.status==="completed"||d.status==="cancelled"))return}catch{if(off)return}timer=setTimeout(tick,next)};
  tick();return()=>{off=true;clearTimeout(timer)}},[id,terminal]);
 return live;
}

function carEl(){const d=document.createElement("div");d.className="tp-car";d.innerHTML='<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M12 2.5 L19 20.5 L12 16.6 L5 20.5 Z" fill="#E8C547" stroke="#14141A" stroke-width="1.6" stroke-linejoin="round"/></svg>';return d}
function ringEl(kind){const d=document.createElement("div");d.className=`tp-ring ${kind}`;return d}

function LiveTripMap({t,live,onLead,onRoute}){
 const token=getMapboxToken();
 const box=React.useRef(null),mapRef=React.useRef(null),mk=React.useRef({}),leadAt=React.useRef({t:0,p:null,target:""}),carPos=React.useRef(null),carHeading=React.useRef(0),anim=React.useRef(0),fitted=React.useRef(false);
 const[ready,setReady]=React.useState(false),[route,setRoute]=React.useState(null),[lead,setLead]=React.useState(null),[follow,setFollow]=React.useState(false);
 const pickup=okPoint({lat:t.pickupLat,lng:t.pickupLng})?{lat:t.pickupLat,lng:t.pickupLng}:null;
 const dropoff=okPoint({lat:t.dropoffLat,lng:t.dropoffLng})?{lat:t.dropoffLat,lng:t.dropoffLng}:null;
 const raw=live?String(live.status||""):"";
 const at=stage(raw,t.status);
 const drv=live&&live.driver&&okPoint(live.driver)?live.driver:null;
 const stale=drv&&drv.seen_at?Date.now()-new Date(drv.seen_at).getTime()>STALE_MS:false;
 const target=at===4?dropoff:(at===1||at===2)?pickup:null;
 const cancelled=at===-1;

 React.useEffect(()=>{const node=box.current;if(!node||!token)return;mapboxgl.accessToken=token;
  // Scrolling the page over the map must not zoom it out (owner 2026-11-16: the route "disappeared" while scrolling): Ctrl/⌘ + wheel zooms.
  const map=new mapboxgl.Map({container:node,style:navyStyle,center:pickup?[pickup.lng,pickup.lat]:[-86.8,33.45],zoom:11,maxPitch:0,dragRotate:false,pitchWithRotate:false,touchPitch:false,attributionControl:true,cooperativeGestures:true});
  mapRef.current=map;map.addControl(new mapboxgl.NavigationControl({showCompass:false}),"top-right");
  map.on("dragstart",()=>setFollow(false));
  map.on("load",()=>{if(mapRef.current!==map)return;map.resize();applyNavyGold(map);refineRoads(map);hideTraffic(map);
   const all=(map.getStyle()||{}).layers||[];let lastRoad=-1;all.forEach((l,i)=>{if(l.type==="line"&&/^(road|bridge|tunnel)/.test(l.id))lastRoad=i});const labels=all.find((l,i)=>i>lastRoad&&l.type==="symbol");const before=labels?labels.id:undefined;
   map.addSource("tp-route",{type:"geojson",lineMetrics:true,data:EMPTY});
   map.addLayer({id:"tp-route-line",type:"line",source:"tp-route",layout:{"line-cap":"round","line-join":"round"},paint:{"line-width":5.5,"line-opacity":1,"line-gradient":["interpolate",["linear"],["line-progress"],0,GOLD,1,"#FFFFFF"]}},before);
   map.addSource("tp-lead",{type:"geojson",data:EMPTY});
   map.addLayer({id:"tp-lead-line",type:"line",source:"tp-lead",layout:{"line-cap":"round","line-join":"round"},paint:{"line-width":5.5,"line-color":GOLD}},before);
   setReady(true)});
  const ro=typeof ResizeObserver==="undefined"?null:new ResizeObserver(()=>map.resize());ro?.observe(node);
  return()=>{ro?.disconnect();cancelAnimationFrame(anim.current);/* guard-pin trip_page_marker_cleanup: mk.current also keeps _framedCar (a flag): only markers get remove() — true.remove() threw and the whole page fell back to the old one (#833, 2026-11-17) */Object.values(mk.current).forEach(m=>{if(m&&typeof m.remove==="function")m.remove()});mk.current={};mapRef.current=null;setReady(false);map.remove()}},[token]);

 // Pickup → destination, by the streets.
 const pKey=pickup?`${pickup.lat},${pickup.lng}`:"",dKey=dropoff?`${dropoff.lat},${dropoff.lng}`:"";
 React.useEffect(()=>{const map=mapRef.current;if(!map||!ready)return;
  const put=(name,kind,p)=>{if(!p){mk.current[name]?.remove();mk.current[name]=null;return}if(!mk.current[name])mk.current[name]=new mapboxgl.Marker({element:ringEl(kind),anchor:"center"}).setLngLat([p.lng,p.lat]).addTo(map);else mk.current[name].setLngLat([p.lng,p.lat])};
  put("pick","pick",pickup);put("drop","drop",dropoff);
  if(!pickup||!dropoff){setRoute(null);return}
  const ctrl=new AbortController();
  fetchStreetRoute(pickup,dropoff,token,ctrl.signal).then(r=>{setRoute(r);onRoute&&onRoute(r.meters>0?{miles:r.meters/1609.34,minutes:Math.max(1,Math.round(r.seconds/60))}:null)}).catch(()=>{if(!ctrl.signal.aborted)setRoute({coords:[[pickup.lng,pickup.lat],[dropoff.lng,dropoff.lat]],meters:0,seconds:0})});
  return()=>ctrl.abort()},[ready,pKey,dKey]);
 React.useEffect(()=>{const map=mapRef.current;if(!map||!ready)return;const src=map.getSource("tp-route");if(!src)return;
  src.setData(route?{type:"Feature",properties:{},geometry:{type:"LineString",coordinates:route.coords}}:EMPTY);
  map.setPaintProperty("tp-route-line","line-opacity",cancelled?0.3:target&&drv?0.4:1)},[ready,route,cancelled,!!(target&&drv)]);

 // The driver's arrow glides to each new reading and turns to where it went.
 const dKey2=drv?`${drv.lat},${drv.lng}`:"";
 React.useEffect(()=>{const map=mapRef.current;if(!map||!ready)return;
  if(!drv){mk.current.car?.remove();mk.current.car=null;carPos.current=null;return}
  const to={lat:drv.lat,lng:drv.lng};
  if(!mk.current.car){mk.current.car=new mapboxgl.Marker({element:carEl(),anchor:"center"}).setLngLat([to.lng,to.lat]).addTo(map);carPos.current=to;return}
  const from=carPos.current||to;if(metersBetween(from,to)>8)carHeading.current=bearing(from,to);
  const svg=mk.current.car.getElement().querySelector("svg");if(svg)svg.style.transform=`rotate(${carHeading.current}deg)`;
  cancelAnimationFrame(anim.current);const t0=performance.now(),dur=1200;
  const step=now=>{const k=Math.min(1,(now-t0)/dur);const p={lat:from.lat+(to.lat-from.lat)*k,lng:from.lng+(to.lng-from.lng)*k};carPos.current=p;mk.current.car?.setLngLat([p.lng,p.lat]);if(k<1)anim.current=requestAnimationFrame(step)};
  anim.current=requestAnimationFrame(step);
  if(follow)map.easeTo({center:[to.lng,to.lat],duration:1000})},[ready,dKey2]);
 React.useEffect(()=>{const c=mk.current.car;if(c)c.getElement().classList.toggle("stale",!!stale)},[stale,dKey2,ready]);

 // Driver → where they are going now (pickup, or the destination once on board).
 const tKey=target?`${target.lat},${target.lng}`:"";
 React.useEffect(()=>{const map=mapRef.current;if(!map||!ready)return;const src=map.getSource("tp-lead");
  if(!drv||!target){src?.setData(EMPTY);setLead(null);onLead&&onLead(null);return}
  const here={lat:drv.lat,lng:drv.lng},last=leadAt.current;
  const due=last.target!==tKey||!last.p||Date.now()-last.t>LEAD_REFRESH_MS||metersBetween(last.p,here)>LEAD_MOVE_M;
  if(!due)return;
  leadAt.current={t:Date.now(),p:here,target:tKey};
  const ctrl=new AbortController();
  fetchStreetRoute(here,target,token,ctrl.signal).then(r=>{src?.setData({type:"Feature",properties:{},geometry:{type:"LineString",coordinates:r.coords}});const l={miles:r.meters/1609.34,minutes:Math.max(1,Math.round(r.seconds/60))};setLead(l);onLead&&onLead(l)}).catch(()=>{});
  return()=>ctrl.abort()},[ready,dKey2,tKey]);

 const frameAll=React.useCallback((animate)=>{const map=mapRef.current;if(!map)return;const pts=[];if(route)route.coords.forEach(c=>pts.push(c));else{if(pickup)pts.push([pickup.lng,pickup.lat]);if(dropoff)pts.push([dropoff.lng,dropoff.lat])}if(drv)pts.push([drv.lng,drv.lat]);if(!pts.length)return;
  const b=new mapboxgl.LngLatBounds(pts[0],pts[0]);pts.forEach(p=>b.extend(p));map.fitBounds(b,{padding:{top:90,bottom:60,left:50,right:60},maxZoom:15.5,duration:animate?900:0})},[route,dKey2,pKey,dKey]);
 React.useEffect(()=>{if(!ready||fitted.current)return;if(route||(!pickup||!dropoff)){fitted.current=true;frameAll(false)}},[ready,route]);
 React.useEffect(()=>{if(ready&&drv&&fitted.current&&!follow&&!mk.current._framedCar){mk.current._framedCar=true;frameAll(true)}},[ready,dKey2]);

 const who=firstName(drv&&drv.first_name)||firstName(t.driverName)||"El conductor";
 let title,sub=null;
 if(cancelled){title="Viaje cancelado";sub=t.cancelReason?`Motivo: ${t.cancelReason}`:null}
 else if(at===5){title="Viaje terminado";const mi=t.distance>0?`${(t.distance*0.621371).toFixed(1)} mi`:null;sub=[t.duration>0?`${t.duration} min`:null,mi].filter(Boolean).join(" · ")||null}
 else if(at===4){title=lead?`Llega al destino en ${lead.minutes} min`:"En viaje";sub=lead?`${lead.miles.toFixed(1)} mi para llegar`:null}
 else if(at===3){title=`${who} llegó a la recogida`;sub="Esperando a la pasajera"}
 else if(at===2||(at===1&&!isReservation(t))){title=drv?(lead?`${who} llega en ${lead.minutes} min`:`${who} va en camino`):"Esperando la ubicación del conductor";sub=lead?`${lead.miles.toFixed(1)} mi de la recogida`:null}
 else if(isReservation(t)){title=["Recogida ",el(ZoneTime,{date:t.scheduledAtDate,lat:t.pickupLat,lng:t.pickupLng,key:"z"})];sub=t.driverName?`Conductor: ${t.driverName} · confirma 1 hora antes`:"Sin conductor todavía"}
 else{title="Buscando conductor";sub=route&&route.meters>0?`${Math.round(route.seconds/60)} min · ${(route.meters/1609.34).toFixed(1)} mi de viaje`:null}
 if(drv&&stale&&at>=1&&at<=4)sub=`Última ubicación ${when(drv.seen_at)||""}`;

 return el("section",{className:"tp-map","aria-label":"Mapa del viaje"},
  el("div",{ref:box,className:"tp-canvas"}),
  el("div",{className:"tp-pill"},Array.isArray(title)?el("b",null,...title):el("b",null,title),sub?el("span",null,sub):null),
  token?el("div",{className:"tp-mapbtns"},
   drv?el("button",{type:"button",className:follow?"tp-mapbtn on":"tp-mapbtn",onClick:()=>{setFollow(true);const m=mapRef.current;if(m&&drv)m.easeTo({center:[drv.lng,drv.lat],zoom:Math.max(m.getZoom(),15),duration:800})}},"Seguir"):null,
   el("button",{type:"button",className:"tp-mapbtn",onClick:()=>{setFollow(false);frameAll(true)}},"Ruta completa")):null,
  !token?el("div",{className:"tp-hint"},el("span",null,"Mapa no disponible")):null);
}

// ── "Más" menu ───────────────────────────────────────────────────────
function MoreMenu({items}){
 const[open,setOpen]=React.useState(false),ref=React.useRef(null);
 React.useEffect(()=>{if(!open)return;const off=e=>{if(ref.current&&!ref.current.contains(e.target))setOpen(false)};document.addEventListener("mousedown",off);return()=>document.removeEventListener("mousedown",off)},[open]);
 if(!items.length)return null;
 return el("div",{className:"tp-moreBox",ref},
  el("button",{type:"button",className:open?"tp-more on":"tp-more","aria-haspopup":"true","aria-expanded":open?"true":"false",onClick:()=>setOpen(o=>!o)},"Más ⋯"),
  open?el("div",{className:"tp-menu",onClick:()=>setOpen(false)},items.map((c,i)=>J.jsx(React.Fragment,{children:c},i))):null);
}

// ── The page ──────────────────────────────────────────────────────────
const RAW_LABEL={requested:["Buscando conductor","gold"],scheduled:["Reserva sin conductor","gold"],scheduled_accepted:["Conductor asignado","gold"],scheduled_active:["Por empezar","gold"],accepted:["Aceptado","gold"],driver_en_route:["En camino a la recogida","gold"],arrived:["Llegó a la recogida","gold"],in_trip:["En viaje","gold"],completed:["Terminado",""],cancelled:["Cancelado","dim"]};
const PAY_LABEL={paid:"Cobrado",captured:"Cobrado",held:"Retenido",authorized:"Retenido",requires_capture:"Retenido",unpaid:"Pendiente",partial:"Cobrado en parte",failed:"Falló el cobro",not_required:"No se cobra",refunded:"Reembolsado",cancelled:"Sin cobro"};
const COURTESY=["platform_courtesy","dispatch_courtesy","review_test"];
const LANG={es:"Español",en:"Inglés"};
const money=v=>v==null||!isFinite(Number(v))?"—":"$"+Number(v).toLocaleString("en-US",{minimumFractionDigits:2,maximumFractionDigits:2});
const initials=n=>String(n||"").trim().split(/\s+/).slice(0,2).map(w=>w[0]||"").join("").toUpperCase()||"?";
const phoneFmt=p=>{const d=String(p||"").replace(/\D/g,"");return d.length===11&&d[0]==="1"?`+1 (${d.slice(1,4)}) ${d.slice(4,7)}-${d.slice(7)}`:d.length===10?`(${d.slice(0,3)}) ${d.slice(3,6)}-${d.slice(6)}`:String(p||"")};

// guard-pin trip_page_refetch: the page data is read again with every change
// the trip's Firestore mirror brings (status, driver) and every status the
// /live poll sees, so the timeline never waits for a reload.
function usePage(id,raw,mirror){
 const[page,setPage]=React.useState(null),[err,setErr]=React.useState(null);
 React.useEffect(()=>{if(!(id>0))return;let off=false;
  apiGet(`/admin/trips/${id}/page`,{retry:{maxAttempts:2}}).then(d=>{if(!off){setPage(d);setErr(null)}}).catch(e=>{if(!off)setErr(e instanceof Error?e.message:String(e))});
  return()=>{off=true}},[id,raw,mirror]);
 return{page,err};
}

const Card=({title,right,children})=>el("section",{className:"tp-card"},title?el("h3",{className:"tp-h3"},title,right||null):null,children);
const Row=(k,v,cls)=>el("div",{className:"tp-kv"+(cls?" "+cls:""),key:k},el("span",null,k),el("b",null,v));

function Avatar({p}){return p&&p.photo_url?el("img",{className:"tp-av",src:p.photo_url,alt:""}):el("span",{className:"tp-av"},initials(p&&p.name))}

function CallDialog({name,phone,onClose}){
 const[copied,setCopied]=React.useState(false);
 React.useEffect(()=>{const k=e=>{if(e.key==="Escape")onClose()};window.addEventListener("keydown",k);return()=>window.removeEventListener("keydown",k)},[onClose]);
 const copy=()=>{try{navigator.clipboard.writeText(phone).then(()=>setCopied(true),()=>{})}catch{}};
 return el("div",{className:"tp-ov",onMouseDown:e=>{if(e.target===e.currentTarget)onClose()}},
  el("div",{className:"tp-dlg",role:"dialog","aria-modal":"true","aria-label":`Llamar a ${name}`},
   el("div",{className:"tp-dh"},el("h2",null,`Llamar a ${name}`),el("button",{type:"button",className:"tp-x","aria-label":"Cerrar",onClick:onClose},"×")),
   el("div",{className:"tp-phone"},phoneFmt(phone)),
   el("div",{className:"tp-muted"},"Márcalo desde tu teléfono. «Llamar» abre tu app de llamadas si la computadora tiene una."),
   el("div",{className:"tp-row-end"},el("button",{type:"button",className:"tp-btn",onClick:copy},copied?"Copiado":"Copiar"),el("a",{className:"tp-btn gold",href:`tel:${phone}`},"Llamar"))));
}

function PersonCard({title,p,line,live,onCall,onChat,onProfile,empty}){
 return el(Card,{title,right:p&&p.id&&onProfile?el("button",{type:"button",className:"tp-link",onClick:onProfile},"Ver ficha"):null},
  p?el("div",{className:"tp-person"},el(Avatar,{p}),el("div",{className:"tp-pinfo"},el("b",null,p.name||"—"),line?el("span",null,line):null,live?el("span",{className:"tp-live"},live):null)):el("div",{className:"tp-muted"},empty),
  p?el("div",{className:"tp-row"},p.phone?el("button",{type:"button",className:"tp-btn sm",onClick:onCall},"Llamar"):null,onChat?el("button",{type:"button",className:"tp-btn sm",onClick:onChat},"Chat"):null):null);
}

function MoneyCard({page}){
 const m=page.money,tier=tierName(page.vehicle_type),rider=page.rider,driver=page.driver;
 const rFirst=firstName(rider&&rider.name)||"el pasajero",dFirst=firstName(driver&&driver.name)||"el conductor";
 const cancelled=page.status==="cancelled",done=page.status==="completed";
 const courtesy=COURTESY.includes(m.funding);
 const rows=[Row(`Tarifa${tier?" "+tier:""}`,money(m.original))];
 if(m.discount>0)rows.push(Row("Descuento",`−${money(m.discount)}`));
 if(m.cruise_cash>0)rows.push(Row("Cruise Cash",`−${money(m.cruise_cash)}`));
 rows.push(Row(`Paga ${rFirst}`,money(m.rider_pays),"tot"));
 if(driver||m.driver_gets)rows.push(Row(`Gana ${dFirst}${m.driver_rate&&!cancelled?` (${Math.round(m.driver_rate*100)}%)`:""}${!m.driver_final&&!cancelled?" · aprox.":""}`,money(m.driver_gets),"gold"));
 if(m.cruise_puts>0)rows.push(Row("Pone Cruise",money(m.cruise_puts)));
 if(m.cruise_keeps>0)rows.push(Row("Queda a Cruise",money(m.cruise_keeps)));
 if(m.tip>0)rows.push(Row("Propina (toda para el conductor)",money(m.tip)));
 if(m.cancellation_fee>0)rows.push(Row("Cargo de cancelación",money(m.cancellation_fee)));
 if(m.refund_amount>0)rows.push(Row("Reembolsado",money(m.refund_amount)));
 rows.push(Row("Cobro",courtesy&&m.rider_pays===0?"Lo paga Cruise":(PAY_LABEL[m.payment_status]||m.payment_status)));
 const card=page.card;
 const note=courtesy&&m.rider_pays===0?`A ${rFirst} no se le cobra: Cruise paga el viaje.`:
  cancelled?(m.cancellation_fee>0?`Se cobró el cargo de cancelación${card?" a la "+card:""}.`:"No se cobró el viaje."):
  done?`Cobrado${card?" a la "+card:""}.${m.tip>0?" La propina va completa al conductor.":""}`:
  `Se cobra${card?" a la "+card:""} al terminar el viaje${page.reservation?"; se retiene 1 hora antes de la recogida":""}.`;
 return el(Card,{title:"Dinero"},el("div",null,...rows),el("div",{className:"tp-note"},note));
}

// The airport end (2026-11-16): the airport's name, the airline with its
// logo, the terminal (only when confirmed) and Salidas/Llegadas; dispatch
// picks or changes the airline here. Only words change — never the point,
// the price or the airport fee (POST /admin/trips/{id}/airport).
function AirlineDialog({tripId,end,point,current,onClose,onSaved}){
 const[air,setAir]=React.useState(null),[pick,setPick]=React.useState(current||null),[busy,setBusy]=React.useState(false),[error,setError]=React.useState(null);
 React.useEffect(()=>{let alive=true;apiGet("/admin/airports/near",{query:{lat:point.lat,lng:point.lng},retry:{maxAttempts:1}}).then(r=>{if(alive)setAir(r&&r.airport?r.airport:false)}).catch(()=>{if(alive)setAir(false)});return()=>{alive=false}},[point.lat,point.lng]);
 React.useEffect(()=>{const k=e=>{if(e.key==="Escape")onClose()};window.addEventListener("keydown",k);return()=>window.removeEventListener("keydown",k)},[onClose]);
 const chosen=air&&pick?air.airlines.find(a=>a.name===pick):null;
 const save=async()=>{setBusy(true);setError(null);try{const r=await apiPost(`/admin/trips/${tripId}/airport`,{end,airline:pick},{retry:{maxAttempts:1}});onSaved(r)}catch(e){setError((e&&e.message)||"No se pudo guardar.");setBusy(false)}};
 return el("div",{className:"tp-ov",onMouseDown:e=>{if(e.target===e.currentTarget)onClose()}},
  el("div",{className:"tp-dlg tp-dlg-wide",role:"dialog","aria-modal":"true","aria-label":"Elegir aerolínea"},
   el("div",{className:"tp-dh"},el("div",null,el("h2",null,"¿Con qué aerolínea vuela?"),air?el("span",{className:"tp-muted"},air.name):null),el("button",{type:"button",className:"tp-x","aria-label":"Cerrar",onClick:onClose},"✕")),
   air===null?el("div",{className:"tp-skel",style:{height:160}}):air===false?el("div",{className:"tp-note"},"Este punto no está en un aeropuerto."):
    el("div",{className:"tp-airgrid"},air.airlines.map(a=>el("button",{key:a.name,type:"button","aria-pressed":pick===a.name,className:pick===a.name?"tp-airtile on":"tp-airtile",onClick:()=>setPick(a.name)},
     a.logo?el("img",{src:a.logo,alt:"",className:"tp-airlogo big"}):el("span",{className:"tp-airlogo big none"},"✈"),
     el("b",null,a.name),el("span",{className:"tp-small"},a.terminal||"Terminal sin confirmar")))),
   air?el("div",{className:"tp-note"},"El conductor verá: ",el("b",null,`${air.code} · ${(chosen&&chosen.terminal)||air.short_name}${pick?` — ${pick}`:""}`),chosen&&!chosen.terminal?". La terminal no está confirmada, así que no se la decimos.":"."):null,
   error?el("div",{className:"tp-note",style:{color:"#FF9A7A"}},error):null,
   el("div",{className:"tp-row-end"},
    current?el("button",{type:"button",className:"tp-btn",disabled:busy,onClick:()=>setPick(null)},"Quitar aerolínea"):null,
    el("button",{type:"button",className:"tp-btn",onClick:onClose},"Cancelar"),
    el("button",{type:"button",className:"tp-btn gold",disabled:busy||!air||(pick||null)===(current||null),onClick:save},busy?"Guardando…":"Guardar"))));
}

function AirportStop({info,address}){
 return [el("b",{key:"n"},info.name),
  el("div",{className:"tp-air",key:"c"},
   info.airline?el("span",{className:"tp-chip plain"},info.logo?el("img",{src:info.logo,alt:"",className:"tp-airlogo"}):null,info.airline):el("span",{className:"tp-chip dim"},"Sin aerolínea"),
   info.terminal?el("span",{className:"tp-chip gold"},info.terminal):null,
   el("span",{className:"tp-chip plain"},info.way)),
  el("span",{className:"tp-small",key:"a"},"El conductor ve: ",address)];
}

function RouteCard({page,summary,tripId}){
 const[over,setOver]=React.useState(null),[dlg,setDlg]=React.useState(null);
 const p=over?{...page,pickup:{...page.pickup,address:over.pickup_address},dropoff:{...page.dropoff,address:over.dropoff_address},airport:over.airport}:page;
 const facts=summary?`${summary.minutes} min · ${summary.miles.toFixed(1)} mi`:[p.minutes?`${Math.round(p.minutes)} min`:null,p.miles?`${Number(p.miles).toFixed(1)} mi`:null].filter(Boolean).join(" · ");
 const pickLabel=p.reservation&&p.scheduled_at&&okPoint(p.pickup)?["Recogida · ",el(ZoneTime,{date:p.scheduled_at,lat:p.pickup.lat,lng:p.pickup.lng,key:"z"})]:["Recogida"];
 const over_=p.status==="completed"||p.status==="cancelled";
 const near=p.airport_near||{};
 const stopBody=(end,addr)=>{const info=p.airport&&p.airport.end===end?p.airport:null;return info?AirportStop({info,address:addr||"—"}):[el("b",{key:"b"},addr||"—")]};
 const pickBtn=end=>{if(over_||!near[end])return null;const has=p.airport&&p.airport.end===end&&p.airport.airline;return el("button",{type:"button",className:"tp-link",key:"x",onClick:()=>setDlg(end)},has?"Cambiar aerolínea":`Elegir aerolínea · Aeropuerto ${near[end]}`)};
 return el(Card,{title:"Ruta",right:facts?el("span",{className:"tp-muted"},facts):null},
  el("div",{className:"tp-rail"},
   el("div",{className:"tp-stop"},el("span",{className:"tp-small"},...pickLabel),...stopBody("pickup",p.pickup.address),pickBtn("pickup")),
   el("div",{className:"tp-stop end"},el("span",{className:"tp-small"},p.airport&&p.airport.end==="dropoff"?"Destino · Aeropuerto":"Destino"),...stopBody("dropoff",p.dropoff.address),pickBtn("dropoff"))),
  dlg?el(AirlineDialog,{tripId,end:dlg,point:dlg==="pickup"?p.pickup:p.dropoff,current:p.airport&&p.airport.end===dlg?p.airport.airline:null,onClose:()=>setDlg(null),onSaved:r=>{setOver({pickup_address:r.pickup_address,dropoff_address:r.dropoff_address,airport:r.airport});setDlg(null)}}):null);
}

function TimelineCard({page,raw}){
 const st=raw||page.status;
 const taken=page.driver_taken_at||page.driver_assigned_at;
 const rows=[["Pedido",page.created_at,true],["Conductor asignado",taken,!!taken]];
 if(page.reservation&&page.scheduled_at){
  const confirm=new Date(new Date(page.scheduled_at).getTime()-3600e3).toISOString();
  rows.push(["Oferta para confirmar (1 hora antes)",confirm,["driver_en_route","arrived","in_trip","completed"].includes(st)]);
 }
 rows.push(["Llegó a la recogida",page.arrived_at,!!page.arrived_at]);
 rows.push(["Empezó el viaje",page.started_at,!!page.started_at]);
 rows.push(["Terminó",page.completed_at,!!page.completed_at]);
 const list=st==="cancelled"?rows.filter(r=>r[2]).concat([[page.cancel_reason?`Cancelado · ${page.cancel_reason}`:"Cancelado",page.updated_at,true]]):rows;
 return el(Card,{title:"Línea de tiempo"},list.map(([what,at,on],i)=>el("div",{className:"tp-tl",key:i},el("span",{className:on?"tp-dot on":"tp-dot"}),el("span",{className:"tp-tlw"},what),el("span",{className:"tp-tlt"},on?(when(at)||"—"):"pendiente"))));
}

function TripPageShell(props){
 ensureCss();
 const{cruiseTrip:t,cruiseBackendId:id}=props;
 const navigate=useNavigate();
 const kids=Array.isArray(props.children)?props.children:[props.children];
 const[header,stepper,grid,mainBar,moreBar,...rest]=kids;
 const terminal=t.status==="completed"||t.status==="cancelled";
 const live=useLive(id,terminal);
 const raw=live?live.status:null;
 const{page,err}=usePage(id,raw,`${t.status}|${t.driverId||""}`);
 const[lead,setLead]=React.useState(null),[summary,setSummary]=React.useState(null),[call,setCall]=React.useState(null);

 // Old buttons, same elements: the contextual ones stay in sight, the rest
 // go behind "Más". A refund is in sight once the trip is over.
 const main=kidsOf(mainBar),more=[],inline=[];
 kidsOf(moreBar).forEach(b=>{(textOf(b).includes("Reembolso")?inline:more).push(b)});
 const actions=[...main,...inline];
 const backBtn=kidsOf(header)[0];
 const goBack=backBtn&&backBtn.props&&typeof backBtn.props.onClick==="function"?backBtn.props.onClick:()=>navigate(-1);

 const map=el(LiveTripMap,{t,live,onLead:setLead,onRoute:setSummary});
 const buttons=actions.length||more.length?el("div",{className:"tp-actions"},actions.map((c,i)=>J.jsx(React.Fragment,{children:c},i)),el(MoreMenu,{items:more})):null;

 // Without the page data (an error, an older server) the old cards stay.
 if(!page){
  const cols=kidsOf(grid);
  const left=cols.length===2?kidsOf(cols[0]):null,right=cols.length===2?kidsOf(cols[1]):null;
  const body=!err?el("div",{className:"tp-grid"},el("div",{className:"tp-col"},map,el("div",{className:"tp-skel"})),el("div",{className:"tp-col"},el("div",{className:"tp-skel"}),el("div",{className:"tp-skel"}))):
   left&&right?el("div",{className:"tp-grid"},el("div",{className:"tp-col"},map,left.map((c,i)=>J.jsx(React.Fragment,{children:c},i))),el("div",{className:"tp-col"},right.map((c,i)=>J.jsx(React.Fragment,{children:c},i)))):
   J.jsxs(React.Fragment,{children:[map,grid]});
  return el("div",{className:"tp-page"},el("div",{className:"tp-head"},header,buttons),el(Steps,{t,raw}),t.status==="cancelled"?stepper:null,body,...rest);
 }

 const st=raw||page.status;
 const[label,tone]=RAW_LABEL[st]||[st,""];
 const at=v=>v?new Date(v):null;
 const stepsT=Object.assign({},t,{createdAt:at(page.created_at)||t.createdAt,acceptedAt:at(page.driver_taken_at||page.driver_assigned_at)||t.acceptedAt,driverArrivedAt:at(page.arrived_at)||t.driverArrivedAt,startedAt:at(page.started_at)||t.startedAt,completedAt:at(page.completed_at)||t.completedAt,cancelledAt:st==="cancelled"?(at(page.updated_at)||t.cancelledAt):t.cancelledAt});
 const rider=page.rider,driver=page.driver;
 const chips=[];
 const tier=tierName(page.vehicle_type);if(tier)chips.push(el("span",{className:"tp-chip",key:"tier"},tier));
 if(page.is_airport)chips.push(el("span",{className:"tp-chip",key:"apt"},page.airport_code?`Aeropuerto ${page.airport_code}`:"Aeropuerto"));
 if(page.reservation&&page.scheduled_at&&okPoint(page.pickup))chips.push(el("span",{className:"tp-chip gold",key:"res"},"Reserva · ",el(ZoneTime,{date:page.scheduled_at,lat:page.pickup.lat,lng:page.pickup.lng})));
 chips.push(el("span",{className:"tp-chip",key:"created"},`Pedido ${when(page.created_at)||"—"}`));
 if(page.card)chips.push(el("span",{className:"tp-chip",key:"card"},page.card));
 else if(COURTESY.includes(page.money.funding))chips.push(el("span",{className:"tp-chip",key:"card"},"Lo paga Cruise"));

 const v=driver&&driver.vehicle;
 const veh=v?[v.make,v.model,v.color?String(v.color).toLowerCase():null].filter(Boolean).join(" ")+(v.plate?` · ${v.plate}`:""):null;
 const confirmAt=page.scheduled_at?when(new Date(new Date(page.scheduled_at).getTime()-3600e3)):null;
 const driverLive=st==="driver_en_route"||(st==="accepted"&&!page.reservation)?(lead?`En camino · llega en ${lead.minutes} min`:"En camino"):
  st==="arrived"?"Llegó a la recogida":
  st==="in_trip"?(lead?`En viaje · llega al destino en ${lead.minutes} min`:"En viaje"):
  (st==="scheduled_accepted"||st==="scheduled_active")&&confirmAt?`Confirma la reserva ${confirmAt}`:null;
 const riderLine=rider?[rider.rating?`★ ${Number(rider.rating).toFixed(1)}`:null,rider.trips!=null?`${rider.trips} ${rider.trips===1?"viaje":"viajes"}`:null,rider.locale&&LANG[String(rider.locale).slice(0,2)]].filter(Boolean).join(" · "):null;
 const driverLine=driver?[driver.rating?`★ ${Number(driver.rating).toFixed(2)}`:null,veh].filter(Boolean).join(" · "):null;

 return el("div",{className:"tp-page"},
  el("header",{className:"tp-top"},
   el("button",{type:"button",className:"tp-back","aria-label":"Volver",onClick:goBack},"←"),
   el("div",{className:"tp-titlebox"},
    el("div",{className:"tp-tline"},el("h1",{className:"tp-h1"},`${page.reservation?"Reserva":"Viaje"} #${page.id}`),el("span",{className:`tp-chip ${tone==="gold"?"gold":tone==="dim"?"dim":"plain"}`},label)),
    el("div",{className:"tp-chips"},chips)),
   buttons),
  el(Steps,{t:stepsT,raw:st}),
  el("div",{className:"tp-grid"},
   el("div",{className:"tp-col"},map,el(RouteCard,{page,summary,tripId:id}),el(TimelineCard,{page,raw:st})),
   el("div",{className:"tp-col"},
    el(PersonCard,{title:"Pasajero",p:rider,line:riderLine,onCall:()=>setCall({name:rider.name,phone:rider.phone}),onChat:()=>navigate("/soporte",{state:{tripId:t.tripId}}),onProfile:rider&&rider.id?()=>navigate(`/personas/rider/sql_${rider.id}`):null,empty:"Sin datos del pasajero"}),
    el(PersonCard,{title:"Conductor",p:driver,line:driverLine,live:driverLive,onCall:()=>setCall({name:driver.name,phone:driver.phone}),onChat:driver?()=>navigate("/soporte",{state:{tripId:t.tripId,driverId:t.driverId}}):null,onProfile:driver?()=>navigate(`/personas/driver/sql_${driver.id}`):null,empty:"Sin conductor todavía"}),
    el(MoneyCard,{page}),
    page.notes?el(Card,{title:"Nota del viaje"},el("div",{className:"tp-note"},page.notes)):null)),
  call?el(CallDialog,{name:call.name,phone:call.phone,onClose:()=>setCall(null)}):null,
  ...rest);
}

export{TripPageShell,stage,isReservation};
