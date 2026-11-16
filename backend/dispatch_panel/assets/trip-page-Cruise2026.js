/*! guard-pin panel_trip_page: página del viaje estilo Lyft (dueño 2026-11-16, dibujo https://claude.ai/artifact/1AXDLBTjRMz3PLXZHcXeZW) - chunk escrito a mano, sin fuente React (CLAUDE.md #30). Lo monta TripDetailScreen (index-B68rRA9U.js) ALREDEDOR de lo de siempre: el encabezado, las tarjetas y los botones viejos son los mismos elementos (mismos handlers y ventanas), solo cambian de lugar. Nuevo: mapa con la ruta y el conductor en vivo (GET /admin/trips/{id}/live) y la barra de progreso con la hora de cada paso. */
import{r as React,j as J}from"./vendor-react-DprhJQz-.js";
import{m as mapboxgl}from"./vendor-mapbox-ComAnvan.js";
import{N as navyStyle,a as applyNavyGold,r as refineRoads,h as hideTraffic}from"./mapNavyGold-CiIxy5Vj.js";
import{m as getMapboxToken}from"./mapboxToken-DDoCRQix.js";
import{W as apiGet}from"./index-CuQT_62K.js";
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
const LIVE_MS=6000,IDLE_MS=30000,LEAD_REFRESH_MS=30000,LEAD_MOVE_M=150,STALE_MS=90000;

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

function LiveTripMap({t,live}){
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
  const map=new mapboxgl.Map({container:node,style:navyStyle,center:pickup?[pickup.lng,pickup.lat]:[-86.8,33.45],zoom:11,maxPitch:0,dragRotate:false,pitchWithRotate:false,touchPitch:false,attributionControl:true});
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
  return()=>{ro?.disconnect();cancelAnimationFrame(anim.current);Object.values(mk.current).forEach(m=>m&&m.remove());mk.current={};mapRef.current=null;setReady(false);map.remove()}},[token]);

 // Pickup → destination, by the streets.
 const pKey=pickup?`${pickup.lat},${pickup.lng}`:"",dKey=dropoff?`${dropoff.lat},${dropoff.lng}`:"";
 React.useEffect(()=>{const map=mapRef.current;if(!map||!ready)return;
  const put=(name,kind,p)=>{if(!p){mk.current[name]?.remove();mk.current[name]=null;return}if(!mk.current[name])mk.current[name]=new mapboxgl.Marker({element:ringEl(kind),anchor:"center"}).setLngLat([p.lng,p.lat]).addTo(map);else mk.current[name].setLngLat([p.lng,p.lat])};
  put("pick","pick",pickup);put("drop","drop",dropoff);
  if(!pickup||!dropoff){setRoute(null);return}
  const ctrl=new AbortController();
  fetchStreetRoute(pickup,dropoff,token,ctrl.signal).then(r=>setRoute(r)).catch(()=>{if(!ctrl.signal.aborted)setRoute({coords:[[pickup.lng,pickup.lat],[dropoff.lng,dropoff.lat]],meters:0,seconds:0})});
  return()=>ctrl.abort()},[ready,pKey,dKey]);
 React.useEffect(()=>{const map=mapRef.current;if(!map||!ready)return;const src=map.getSource("tp-route");if(!src)return;
  src.setData(route?{type:"Feature",properties:{},geometry:{type:"LineString",coordinates:route.coords}}:EMPTY);
  map.setPaintProperty("tp-route-line","line-opacity",cancelled?0.3:target?0.4:1)},[ready,route,cancelled,!!target]);

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
  if(!drv||!target){src?.setData(EMPTY);setLead(null);return}
  const here={lat:drv.lat,lng:drv.lng},last=leadAt.current;
  const due=last.target!==tKey||!last.p||Date.now()-last.t>LEAD_REFRESH_MS||metersBetween(last.p,here)>LEAD_MOVE_M;
  if(!due)return;
  leadAt.current={t:Date.now(),p:here,target:tKey};
  const ctrl=new AbortController();
  fetchStreetRoute(here,target,token,ctrl.signal).then(r=>{src?.setData({type:"Feature",properties:{},geometry:{type:"LineString",coordinates:r.coords}});setLead({miles:r.meters/1609.34,minutes:Math.max(1,Math.round(r.seconds/60))})}).catch(()=>{});
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
 else if(isReservation(t)){title=el("span",null,"Recogida ",el(ZoneTime,{date:t.scheduledAtDate,lat:t.pickupLat,lng:t.pickupLng}));sub=t.driverName?`Conductor: ${t.driverName} · confirma 1 hora antes`:"Sin conductor todavía"}
 else{title="Buscando conductor";sub=route&&route.meters>0?`${Math.round(route.seconds/60)} min · ${(route.meters/1609.34).toFixed(1)} mi de viaje`:null}
 if(drv&&stale&&at>=1&&at<=4)sub=`Última ubicación ${when(drv.seen_at)||""}`;

 return el("section",{className:"tp-map","aria-label":"Mapa del viaje"},
  el("div",{ref:box,className:"tp-canvas"}),
  el("div",{className:"tp-pill"},el("b",null,title),sub?el("span",null,sub):null),
  token?el("div",{className:"tp-mapbtns"},
   drv?el("button",{type:"button",className:follow?"tp-mapbtn on":"tp-mapbtn",onClick:()=>{setFollow(true);const m=mapRef.current;if(m&&drv)m.easeTo({center:[drv.lng,drv.lat],zoom:Math.max(m.getZoom(),15),duration:800})}},"Seguir"):null,
   el("button",{type:"button",className:"tp-mapbtn",onClick:()=>{setFollow(false);frameAll(true)}},"Ruta completa")):null,
  !token?el("div",{className:"tp-hint"},el("span",null,"Mapa no disponible")):null);
}

// ── The page ──────────────────────────────────────────────────────────
function MoreMenu({items}){
 const[open,setOpen]=React.useState(false),ref=React.useRef(null);
 React.useEffect(()=>{if(!open)return;const off=e=>{if(ref.current&&!ref.current.contains(e.target))setOpen(false)};document.addEventListener("mousedown",off);return()=>document.removeEventListener("mousedown",off)},[open]);
 if(!items.length)return null;
 return el("div",{className:"tp-moreBox",ref},
  el("button",{type:"button",className:open?"tp-more on":"tp-more","aria-haspopup":"true","aria-expanded":open?"true":"false",onClick:()=>setOpen(o=>!o)},"Más ⋯"),
  open?el("div",{className:"tp-menu",onClick:()=>setOpen(false)},items.map((c,i)=>J.jsx(React.Fragment,{children:c},i))):null);
}

function TripPageShell(props){
 ensureCss();
 const{cruiseTrip:t,cruiseBackendId:id}=props;
 const kids=Array.isArray(props.children)?props.children:[props.children];
 const[header,stepper,grid,mainBar,moreBar,...rest]=kids;
 const terminal=t.status==="completed"||t.status==="cancelled";
 const live=useLive(id,terminal);
 const raw=live?live.status:null;

 // Old buttons, same elements: the contextual ones stay in sight, the rest
 // go behind "Más". A refund is in sight once the trip is over.
 const main=kidsOf(mainBar),more=[],inline=[];
 kidsOf(moreBar).forEach(b=>{(textOf(b).includes("Reembolso")?inline:more).push(b)});

 const cols=kidsOf(grid);
 const left=cols.length===2?kidsOf(cols[0]):null,right=cols.length===2?kidsOf(cols[1]):null;

 const chips=[];
 const tier=tierName(t.vehicleType);if(tier)chips.push(el("span",{className:"tp-chip",key:"tier"},tier));
 if(isReservation(t))chips.push(el("span",{className:"tp-chip gold",key:"res"},"Reserva · ",el(ZoneTime,{date:t.scheduledAtDate,lat:t.pickupLat,lng:t.pickupLng})));
 if(t.createdAt)chips.push(el("span",{className:"tp-chip",key:"created"},`Pedido ${when(t.createdAt)}`));
 if(t.driverName)chips.push(el("span",{className:"tp-chip",key:"drv"},`Conductor: ${t.driverName}`));

 const actions=[...main,...inline];
 const map=el(LiveTripMap,{t,live});
 const cancelledCard=t.status==="cancelled"?stepper:null;

 return el("div",{className:"tp-page"},
  el("div",{className:"tp-head"},header,
   chips.length?el("div",{className:"tp-chips"},chips):null,
   actions.length||more.length?el("div",{className:"tp-actions"},actions.map((c,i)=>J.jsx(React.Fragment,{children:c},i)),el(MoreMenu,{items:more})):null),
  el(Steps,{t,raw}),
  cancelledCard,
  left&&right?el("div",{className:"tp-grid"},
   el("div",{className:"tp-col"},map,left.map((c,i)=>J.jsx(React.Fragment,{children:c},i))),
   el("div",{className:"tp-col"},right.map((c,i)=>J.jsx(React.Fragment,{children:c},i)))):
  J.jsxs(React.Fragment,{children:[map,grid]}),
  ...rest);
}

export{TripPageShell,stage,isReservation};
