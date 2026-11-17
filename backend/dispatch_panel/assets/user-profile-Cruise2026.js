/*! guard-pin panel_user_profile: ficha de pasajero/conductor estilo Lyft (dueño 2026-11-16, dibujo https://claude.ai/artifact/FrBPF6VbtsioBEzWUMLJT6) - chunk escrito a mano, sin fuente React (CLAUDE.md #30). Lo monta PersonDetailScreen (index-azyIyM-i.js) ALREDEDOR de sus tarjetas de siempre y las reparte en pestañas por su título: ninguna tarjeta ni botón viejo se pierde (una tarjeta con título nuevo cae en Cuenta). Datos: GET /admin/users/{id}/profile, /notes y /chats. */
import{r as React,j as J,y as useNavigate}from"./vendor-react-DprhJQz-.js";
import{W as apiGet,L as apiPost}from"./index-CuQT_62K.js";
import{TripRouteMap,okPoint}from"./trip-route-map-Cruise2026.js";
import{ZoneTime}from"./local-zone-Cruise2026.js";

function el(type,props,...kids){
 const p=Object.assign({},props||{});const key=p.key;delete p.key;
 const c=kids.filter(k=>k!==undefined);
 if(c.length===1)p.children=c[0];else if(c.length>1)p.children=c;
 return c.length>1?J.jsxs(type,p,key):J.jsx(type,p,key);
}

const CSS=`
.up-page{display:flex;flex-direction:column;gap:16px;width:100%;max-width:1180px;margin:0 auto;padding-bottom:40px;min-width:0}
.up-hero{background:#1C1C24;border:1px solid rgba(255,255,255,.06);border-radius:20px;padding:18px 20px;display:flex;flex-direction:column;gap:14px;min-width:0}
.up-meta{display:flex;flex-wrap:wrap;gap:8px}
.up-chip{display:inline-flex;align-items:center;gap:6px;height:26px;padding:0 10px;border-radius:999px;background:#23232D;color:rgba(255,255,255,.75);font-size:12px;font-weight:600;white-space:nowrap}
.up-chip.gold{background:rgba(232,197,71,.12);color:#E8C547}
.up-chip.live::before{content:"";width:7px;height:7px;border-radius:50%;background:#E8C547;box-shadow:0 0 0 3px rgba(232,197,71,.25)}
.up-actions{display:flex;flex-wrap:wrap;gap:8px}
.up-btn{height:36px;padding:0 14px;border-radius:999px;border:1px solid rgba(255,255,255,.14);background:transparent;color:#fff;font:600 13px Inter,system-ui,sans-serif;cursor:pointer;display:inline-flex;align-items:center;justify-content:center;gap:6px;white-space:nowrap}
.up-btn:hover{background:#23232D}
.up-btn.gold{background:#E8C547;border-color:#E8C547;color:#14141A}
.up-btn.gold:hover{background:#F2D46A}
.up-btn[disabled]{opacity:.45;cursor:default}
.up-btn.sm{height:30px;padding:0 12px;font-size:12px}
.up-stats{display:grid;grid-template-columns:repeat(auto-fit,minmax(128px,1fr));gap:10px}
.up-stat{background:#14141A;border-radius:14px;padding:12px 14px;display:flex;flex-direction:column;gap:4px;min-width:0}
.up-stat span{font-size:11.5px;color:rgba(255,255,255,.5);font-weight:600}
.up-stat b{font-size:20px;font-weight:700;color:#fff;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.up-stat b.gold{color:#E8C547}
.up-tabs{display:flex;gap:2px;overflow-x:auto;border-bottom:1px solid rgba(255,255,255,.08);scrollbar-width:none}
.up-tabs::-webkit-scrollbar{display:none}
.up-tab{flex:none;height:42px;padding:0 14px;background:none;border:0;border-bottom:2px solid transparent;color:rgba(255,255,255,.55);font:600 13.5px Inter,system-ui,sans-serif;cursor:pointer;display:inline-flex;align-items:center;gap:6px}
.up-tab:hover{color:#fff}
.up-tab.on{color:#fff;border-bottom-color:#E8C547}
.up-tab i{font-style:normal;font-size:11px;background:#23232D;border-radius:999px;padding:1px 7px;color:rgba(255,255,255,.7)}
.up-grid{display:grid;grid-template-columns:minmax(0,1.6fr) minmax(0,1fr);gap:16px;align-items:start}
@media(max-width:960px){.up-grid{grid-template-columns:minmax(0,1fr)}}
.up-col{display:flex;flex-direction:column;gap:16px;min-width:0}
.up-card{background:#1C1C24;border:1px solid rgba(255,255,255,.06);border-radius:18px;padding:16px 18px;display:flex;flex-direction:column;gap:12px;min-width:0}
.up-card.hot{border-color:rgba(232,197,71,.35)}
.up-card h3{margin:0;font-size:15px;font-weight:700;color:#fff;display:flex;align-items:center;justify-content:space-between;gap:8px}
.up-link{color:#E8C547;font:600 12.5px Inter,system-ui,sans-serif;cursor:pointer;background:none;border:0;padding:0}
.up-link:hover{text-decoration:underline}
.up-kicker{font-size:11px;font-weight:800;letter-spacing:.08em;color:#E8C547;text-transform:uppercase}
.up-big{font-size:17px;font-weight:700;color:#fff}
.up-muted{color:rgba(255,255,255,.5);font-size:12.5px}
.up-route{display:flex;flex-direction:column;gap:10px;position:relative;padding-left:22px}
.up-route::before{content:"";position:absolute;left:6px;top:11px;bottom:11px;width:2px;background:linear-gradient(#E8C547,#fff)}
.up-route div{position:relative;font-size:13.5px;color:#fff;line-height:1.35}
.up-route div::before{content:"";position:absolute;left:-21px;top:3px;width:10px;height:10px;border-radius:50%;border:2px solid #E8C547;background:#1C1C24;box-sizing:border-box}
.up-route div:last-child::before{border-color:#fff}
.up-table{width:100%;border-collapse:collapse;font-size:13px}
.up-table th{text-align:left;font-size:11px;font-weight:700;color:rgba(255,255,255,.45);padding:0 8px 8px;white-space:nowrap}
.up-table td{padding:10px 8px;border-top:1px solid rgba(255,255,255,.06);color:#fff;vertical-align:middle}
.up-table td.r,.up-table th.r{text-align:right;white-space:nowrap}
.up-table td.route{max-width:340px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.up-table tr.click{cursor:pointer}
.up-table tr.click:hover td{background:rgba(255,255,255,.03)}
.up-scroll{overflow-x:auto;min-width:0}
.up-status{display:inline-flex;align-items:center;height:22px;padding:0 8px;border-radius:999px;font-size:11.5px;font-weight:700;background:#23232D;color:rgba(255,255,255,.75);white-space:nowrap}
.up-status.gold{background:rgba(232,197,71,.14);color:#E8C547}
.up-status.dim{color:rgba(255,255,255,.45)}
.up-filters{display:flex;flex-wrap:wrap;gap:8px}
.up-filter{height:32px;padding:0 12px;border-radius:999px;border:1px solid rgba(255,255,255,.14);background:none;color:rgba(255,255,255,.8);font:600 12.5px Inter,system-ui,sans-serif;cursor:pointer}
.up-filter.on{background:#E8C547;border-color:#E8C547;color:#14141A}
.up-rows{display:flex;flex-direction:column}
.up-row{display:flex;justify-content:space-between;gap:12px;padding:9px 0;border-top:1px solid rgba(255,255,255,.06);font-size:13px}
.up-row:first-child{border-top:0}
.up-row>span:first-child{color:rgba(255,255,255,.55)}
.up-row>b{font-weight:600;color:#fff;text-align:right;min-width:0;overflow-wrap:anywhere}
.up-row>b.gold{color:#E8C547}
.up-row.total{border-top:1px solid rgba(255,255,255,.18)}
.up-row.total>span:first-child,.up-row.total>b{color:#fff;font-weight:700}
.up-note{background:#14141A;border-radius:12px;padding:10px 12px;font-size:13px;color:#fff;display:flex;flex-direction:column;gap:4px;white-space:pre-wrap;overflow-wrap:anywhere}
.up-note small{color:rgba(255,255,255,.45);font-size:11.5px}
.up-text{width:100%;box-sizing:border-box;min-height:64px;resize:vertical;background:#14141A;border:1px solid rgba(255,255,255,.12);border-radius:12px;color:#fff;padding:10px 12px;font:13px Inter,system-ui,sans-serif}
.up-text:focus{outline:none;border-color:#E8C547}
.up-modal-bg{position:fixed;inset:0;background:rgba(0,0,0,.62);z-index:60;display:flex;align-items:flex-start;justify-content:center;padding:40px 16px;overflow-y:auto}
.up-modal{width:100%;max-width:640px;background:#1C1C24;border:1px solid rgba(255,255,255,.08);border-radius:20px;padding:20px;display:flex;flex-direction:column;gap:14px;box-sizing:border-box}
.up-modal header{display:flex;justify-content:space-between;align-items:flex-start;gap:12px}
.up-modal header h2{margin:0;font-size:18px;font-weight:700;color:#fff}
.up-modal footer{display:flex;flex-wrap:wrap;justify-content:flex-end;gap:8px}
.up-x{width:32px;height:32px;border-radius:50%;border:1px solid rgba(255,255,255,.14);background:none;color:#fff;cursor:pointer;font-size:16px;flex:none;line-height:1}
.up-map{height:230px;border-radius:14px;overflow:hidden;position:relative;background:#14141A}
.up-map .trm{height:100%}
.up-two{display:grid;grid-template-columns:minmax(0,1fr) minmax(0,1fr);gap:14px}
@media(max-width:620px){.up-two{grid-template-columns:minmax(0,1fr)}}
.up-pick{display:flex;flex-direction:column;gap:8px;max-height:340px;overflow-y:auto}
.up-pick button{text-align:left;background:#14141A;border:1px solid rgba(255,255,255,.08);border-radius:14px;padding:12px 14px;color:#fff;cursor:pointer;display:flex;flex-direction:column;gap:4px;font:13px Inter,system-ui,sans-serif}
.up-pick button.on{border-color:#E8C547;background:rgba(232,197,71,.06)}
.up-pick button b{font-size:13.5px}
.up-err{color:#F2B8B5;font-size:12.5px}
.up-toast{position:fixed;left:50%;bottom:28px;transform:translateX(-50%);background:#E8C547;color:#14141A;font:600 13.5px Inter,system-ui,sans-serif;padding:10px 16px;border-radius:12px;z-index:70;box-shadow:0 8px 24px rgba(0,0,0,.4);max-width:calc(100vw - 32px)}
.up-empty{color:rgba(255,255,255,.5);font-size:13px;padding:4px 0}
.up-skel{height:84px;border-radius:14px;background:linear-gradient(90deg,#1C1C24,#23232D,#1C1C24);background-size:200% 100%;animation:upsk 1.2s infinite}
@keyframes upsk{to{background-position:-200% 0}}
.up-phone{font-size:26px;font-weight:700;color:#fff;letter-spacing:.01em;user-select:all}
`;
function ensureCss(){if(typeof document==="undefined"||document.getElementById("up-css"))return;const s=document.createElement("style");s.id="up-css";s.textContent=CSS;document.head.appendChild(s)}

// ── Formatting ────────────────────────────────────────────────────────
const TZ="America/New_York";
const fmt$=n=>"$"+Number(n).toLocaleString("en-US",{minimumFractionDigits:2,maximumFractionDigits:2});
const money=v=>v==null||!isFinite(Number(v))?"—":fmt$(v);
const cents=v=>v==null||!isFinite(Number(v))?"—":fmt$(Number(v)/100);
const phoneFmt=p=>{const d=String(p||"").replace(/\D/g,"");return d.length===11&&d[0]==="1"?`+1 (${d.slice(1,4)}) ${d.slice(4,7)}-${d.slice(7)}`:d.length===10?`(${d.slice(0,3)}) ${d.slice(3,6)}-${d.slice(6)}`:String(p||"")};
const MES=["ene","feb","mar","abr","may","jun","jul","ago","sep","oct","nov","dic"];
// Same shape as ZoneTime ("17 nov · 5:00 AM"), in Miami time like the rest of the panel.
function parts(iso){if(!iso)return null;const d=new Date(iso);if(isNaN(d.getTime()))return null;return Object.fromEntries(new Intl.DateTimeFormat("en-US",{timeZone:TZ,year:"numeric",month:"numeric",day:"numeric",hour:"numeric",minute:"2-digit",hour12:true}).formatToParts(d).map(x=>[x.type,x.value]))}
function when(iso,dateOnly){const p=parts(iso);if(!p)return"—";const date=`${+p.day} ${MES[+p.month-1]}${+p.year!==new Date().getFullYear()?" "+p.year:""}`;return dateOnly?date:`${date} · ${p.hour}:${p.minute} ${p.dayPeriod}`}
function monthYear(iso){const p=parts(iso);return p?`${MES[+p.month-1]} ${p.year}`:""}
const short=a=>{const s=String(a||"").trim();return s?s.split(",")[0]:"—"};
const firstName=n=>{const s=String(n||"").trim();if(!s)return"";const p=s.split(/\s+/);return p.length>1?`${p[0]} ${p[1][0]}.`:p[0]};
function ago(iso){if(!iso)return null;const ms=Date.now()-new Date(iso).getTime();if(!isFinite(ms)||ms<0)return null;const m=Math.round(ms/6e4);if(m<1)return"ahora";if(m<60)return`hace ${m} min`;const h=Math.round(m/60);if(h<24)return`hace ${h} h`;const d=Math.round(h/24);return`hace ${d} d`}
function dur(iso){if(!iso)return null;const ms=Date.now()-new Date(iso).getTime();if(!isFinite(ms)||ms<0)return null;const m=Math.floor(ms/6e4);const h=Math.floor(m/60);return h>0?`${h} h ${m%60} min`:`${m} min`}
const TIERS={sedan:"Standard",standard:"Standard",comfort:"Comfort",premium:"Premium",vip:"VIP",suv:"SUV",xl:"XL",electric:"Electric"};
const tier=v=>v?TIERS[String(v).toLowerCase()]||String(v):"";
const STATUS={requested:["Buscando conductor","gold"],accepted:["Aceptado","gold"],driver_en_route:["En camino","gold"],arrived:["Llegó a la recogida","gold"],in_trip:["En viaje","gold"],completed:["Completado",""],cancelled:["Cancelado","dim"],canceled:["Cancelado","dim"],scheduled:["Reserva · sin conductor","gold"],scheduled_accepted:["Reserva · con conductor","gold"],scheduled_active:["Reserva · por empezar","gold"],no_show:["No se presentó","dim"]};
const statusOf=s=>STATUS[s]||[String(s||"—"),""];
const PAY={unpaid:"Sin cobrar",pending:"Pendiente",authorized:"Retenido",requires_capture:"Retenido",held:"Retenido",paid:"Cobrado",captured:"Cobrado",succeeded:"Cobrado",refunded:"Reembolsado",partially_refunded:"Reembolso parcial",failed:"Falló el cobro"};
const FUND={rider:"El pasajero",platform_courtesy:"Cruise (gratis)",review_test:"Cruise (cuenta de prueba)",platform:"Cruise"};
const LANG={es:"Español",en:"Inglés"};
function appLabel(u){const os=String(u.platform||"").toLowerCase();const dev=os==="ios"?"iPhone":os==="android"?"Android":os==="web"?"Web":(u.platform||"");const v=String(u.app_version||"");const m=/^([\d.]+)\+(\d+)$/.exec(v);const ver=m?`${m[1]} (${m[2]})`:v;return[dev,ver?`versión ${ver}`:""].filter(Boolean).join(" · ")}
// A reservation shows its pickup time in the pickup's own zone (CLAUDE.md #68).
function TripWhen({t}){return t.reservation&&t.scheduled_at&&okPoint(t.pickup)?el(ZoneTime,{date:t.scheduled_at,lat:t.pickup.lat,lng:t.pickup.lng}):when(t.reservation&&t.scheduled_at?t.scheduled_at:t.created_at)}
function StatusPill({s}){const[label,tone]=statusOf(s);return el("span",{className:`up-status ${tone}`},label)}

// ── Data ──────────────────────────────────────────────────────────────
function useProfile(id){
 const[data,setData]=React.useState(null),[err,setErr]=React.useState(null),[limit,setLimit]=React.useState(60),[tick,setTick]=React.useState(0);
 React.useEffect(()=>{if(!(id>0))return;let off=false;apiGet(`/admin/users/${id}/profile?limit=${limit}`).then(d=>{if(!off){setData(d);setErr(null)}}).catch(e=>{if(!off)setErr(e instanceof Error?e.message:String(e))});return()=>{off=true}},[id,limit,tick]);
 return{data,err,limit,setLimit,reload:React.useCallback(()=>setTick(t=>t+1),[])};
}
function useChats(id){
 const[chats,setChats]=React.useState(null);
 React.useEffect(()=>{if(!(id>0))return;let off=false;apiGet(`/admin/users/${id}/chats`).then(d=>{if(!off)setChats(Array.isArray(d)?d:[])}).catch(()=>{if(!off)setChats([])});return()=>{off=true}},[id]);
 return chats;
}

// ── Building blocks ───────────────────────────────────────────────────
function Modal({title,sub,onClose,children,width}){
 React.useEffect(()=>{const k=e=>{if(e.key==="Escape")onClose()};window.addEventListener("keydown",k);return()=>window.removeEventListener("keydown",k)},[onClose]);
 return el("div",{className:"up-modal-bg",onMouseDown:e=>{if(e.target===e.currentTarget)onClose()}},
  el("div",{className:"up-modal",role:"dialog","aria-modal":"true",style:width?{maxWidth:width}:undefined},
   el("header",null,el("div",null,el("h2",null,title),sub?el("div",{className:"up-muted",style:{marginTop:4}},sub):null),el("button",{type:"button",className:"up-x","aria-label":"Cerrar",onClick:onClose},"×")),
   children));
}
const Card=({title,action,hot,children})=>el("section",{className:hot?"up-card hot":"up-card"},title?el("h3",null,title,action||null):null,children);
const Row=(label,value,cls)=>el("div",{className:"up-row"+(cls==="total"?" total":""),key:label},el("span",null,label),el("b",{className:cls==="gold"?"gold":undefined},value));
const Route=({t})=>el("div",{className:"up-route"},el("div",null,t.pickup_address||"—"),el("div",null,t.dropoff_address||"—"));

function TripTable({trips,role,onOpen,compact}){
 if(!trips.length)return el("div",{className:"up-empty"},"Sin viajes todavía.");
 const isDriver=role==="driver";
 return el("div",{className:"up-scroll"},el("table",{className:"up-table"},
  el("thead",null,el("tr",null,compact?null:el("th",null,"#"),el("th",null,"Fecha"),el("th",null,"Ruta"),compact?null:el("th",null,isDriver?"Pasajero":"Conductor"),el("th",null,"Estado"),el("th",{className:"r"},isDriver?"Ganó":"Total"),el("th",null,""))),
  el("tbody",null,trips.map(t=>el("tr",{key:t.id,className:"click",onClick:()=>onOpen(t)},
   compact?null:el("td",{className:"up-muted"},t.id),
   el("td",{style:{whiteSpace:"nowrap"}},el(TripWhen,{t})),
   el("td",{className:"route",title:`${t.pickup_address} → ${t.dropoff_address}`},`${short(t.pickup_address)} → ${short(t.dropoff_address)}`),
   compact?null:el("td",null,isDriver?(firstName(t.rider_name)||"—"):(firstName(t.driver_name)||"—")),
   el("td",null,el(StatusPill,{s:t.status})),
   el("td",{className:"r"},isDriver?money(t.driver_earnings):money(t.fare)),
   el("td",{className:"r"},el("button",{type:"button",className:"up-link",onClick:e=>{e.stopPropagation();onOpen(t)}},"Ver detalles")))))));
}

// ── Trip detail ───────────────────────────────────────────────────────
function TripModal({t,role,onClose}){
 const navigate=useNavigate();
 const promo=t.original_fare_cents&&t.rider_promo_total_cents!=null&&t.original_fare_cents>t.rider_promo_total_cents?t.original_fare_cents-t.rider_promo_total_cents:0;
 const live=["requested","accepted","driver_en_route","arrived","in_trip","scheduled","scheduled_accepted","scheduled_active"].includes(t.status);
 const cancelled=t.status==="cancelled"||t.status==="canceled";
 const other=role==="driver"?{label:"Pasajero",name:t.rider_name,role:"rider",id:t.rider_id}:{label:"Conductor",name:t.driver_name,role:"driver",id:t.driver_id};
 const hasMap=okPoint(t.pickup)||okPoint(t.dropoff);
 const facts=hasMap?"":[t.minutes?`${Math.round(t.minutes)} min`:null,t.miles?`${Number(t.miles).toFixed(1)} mi`:null].filter(Boolean).join(" · ");
 const timeline=[["Creado",when(t.created_at)],t.reservation?["Recogida reservada",el(TripWhen,{t})]:null,t.driver_assigned_at?["Conductor asignado",when(t.driver_assigned_at)]:null,t.arrived_at?["Llegó a la recogida",when(t.arrived_at)]:null,t.started_at?["Empezó el viaje",when(t.started_at)]:null,t.completed_at?["Terminó",when(t.completed_at)]:null,cancelled?["Cancelado",when(t.updated_at)]:null].filter(Boolean);
 return el(Modal,{title:`${t.reservation?"Reserva":"Viaje"} #${t.id}`,sub:[tier(t.vehicle_type),statusOf(t.status)[0]].filter(Boolean).join(" · "),onClose,width:720},
  hasMap?el("div",{className:"up-map"},el(TripRouteMap,{pickup:t.pickup,dropoff:t.dropoff})):null,
  el(Route,{t}),
  facts?el("div",{className:"up-muted"},facts):null,
  el("div",{className:"up-two"},
   el(Card,{title:"Dinero"},el("div",{className:"up-rows"},
    promo?Row("Precio sin descuento",cents(t.original_fare_cents)):null,
    promo?Row("Descuento",`−${cents(promo)}`):null,
    t.cruise_cash_cents>0?Row("Cruise Cash",`−${cents(t.cruise_cash_cents)}`):null,
    Row(role==="driver"?"Paga el pasajero":"Paga",money(t.fare),"total"),
    t.tip>0?Row("Propina",money(t.tip)):null,
    t.cancellation_fee>0?Row("Cargo de cancelación",money(t.cancellation_fee)):null,
    Row("Lo paga",FUND[t.funding_source]||(t.funding_source||"El pasajero")),
    Row("Cobro",PAY[t.payment_status]||(t.payment_status||"—")),
    t.refund_amount>0?Row("Reembolsado",money(t.refund_amount)):null,
    Row("Gana el conductor",t.driver_earnings!=null?money(t.driver_earnings):"Se calcula al terminar","gold"))),
   el(Card,{title:"Línea de tiempo"},el("div",{className:"up-rows"},timeline.map(([a,b])=>Row(a,b))),
    cancelled&&t.cancel_reason?el("div",{className:"up-muted"},`Motivo: ${t.cancel_reason}`):null)),
  other.id?el("div",{className:"up-row",style:{borderTop:0}},el("span",null,other.label),el("b",null,other.name||"—"," ",el("button",{type:"button",className:"up-link",style:{marginLeft:8},onClick:()=>{onClose();navigate(`/personas/${other.role}/sql_${other.id}`)}},"Ver ficha"))):null,
  el("footer",null,
   live?el("span",{className:"up-muted",style:{marginRight:"auto",alignSelf:"center"}},"En el viaje cambias el conductor o lo cancelas."):null,
   el("button",{type:"button",className:"up-btn",onClick:onClose},"Cerrar"),
   el("button",{type:"button",className:"up-btn gold",onClick:()=>{onClose();navigate(`/viajes/viaje/sql_${t.id}`)}},"Abrir viaje")));
}

// ── Modals of the header ─────────────────────────────────────────────
function CallModal({name,phone,onClose,toast}){
 const copy=()=>{try{navigator.clipboard.writeText(phone).then(()=>toast("Número copiado"),()=>toast("Selecciona el número para copiarlo"))}catch{toast("Selecciona el número para copiarlo")}};
 return el(Modal,{title:`Llamar a ${name}`,onClose,width:420},
  el("div",{className:"up-phone"},phone?phoneFmt(phone):"Sin teléfono"),
  el("div",{className:"up-muted"},"Márcalo desde tu teléfono. El botón Llamar abre tu app de llamadas si la computadora tiene una."),
  el("footer",null,el("button",{type:"button",className:"up-btn",onClick:copy,disabled:!phone},"Copiar"),phone?el("a",{className:"up-btn gold",href:`tel:${phone}`,style:{textDecoration:"none"}},"Llamar"):null));
}

function OfferModal({driverId,name,onClose,toast}){
 const[rows,setRows]=React.useState(null),[pick,setPick]=React.useState(null),[busy,setBusy]=React.useState(false),[err,setErr]=React.useState(null);
 React.useEffect(()=>{let off=false;Promise.all(["requested","scheduled"].map(s=>apiGet(`/admin/trips?status=${s}&limit=100`).catch(()=>[]))).then(([a,b])=>{if(off)return;const all=[...(Array.isArray(a)?a:[]),...(Array.isArray(b)?b:[])].filter(t=>!t.driver_id);setRows(all)});return()=>{off=true}},[]);
 const send=async()=>{if(!pick||busy)return;setBusy(true);setErr(null);try{await apiPost(`/admin/trips/${pick.id}/reassign`,{mode:"driver",driver_id:driverId},{retry:{maxAttempts:1}});toast(`Le llegó la oferta del viaje #${pick.id} a ${name}`);onClose()}catch(e){setBusy(false);setErr(e instanceof Error?e.message:String(e))}};
 return el(Modal,{title:`Ofrecer un viaje a ${name}`,sub:"Viajes y reservas sin conductor. Le llega como una oferta normal; si no la toma, sigue la cascada.",onClose,width:560},
  rows===null?el("div",{className:"up-skel"}):rows.length===0?el("div",{className:"up-empty"},"No hay viajes ni reservas sin conductor ahora."):
  el("div",{className:"up-pick"},rows.map(t=>el("button",{type:"button",key:t.id,className:pick&&pick.id===t.id?"on":"",onClick:()=>setPick(t)},
   el("b",null,t.status==="scheduled"?`Reserva #${t.id} · `:`Viaje #${t.id} · ahora`,t.status==="scheduled"&&t.scheduled_at?(okPoint({lat:t.pickup_lat,lng:t.pickup_lng})?el(ZoneTime,{date:t.scheduled_at,lat:t.pickup_lat,lng:t.pickup_lng}):when(t.scheduled_at)):null),
   el("span",{className:"up-muted"},`${short(t.pickup_address)} → ${short(t.dropoff_address)} · ${money(t.fare)}${t.vehicle_type?" · "+tier(t.vehicle_type):""}`)))),
  err?el("div",{className:"up-err"},err):null,
  el("footer",null,el("button",{type:"button",className:"up-btn",onClick:onClose},"Cancelar"),el("button",{type:"button",className:"up-btn gold",disabled:!pick||busy,onClick:send},busy?"Ofreciendo…":"Ofrecer")));
}

function PayModal({driverId,name,amount,onClose,onDone,toast}){
 const[busy,setBusy]=React.useState(false),[err,setErr]=React.useState(null);
 const pay=async()=>{if(busy)return;setBusy(true);setErr(null);try{await apiPost(`/admin/drivers/${driverId}/payout`,{},{retry:{maxAttempts:1}});toast(`Pago de ${money(amount)} enviado a ${name}`);onDone();onClose()}catch(e){setBusy(false);setErr(e instanceof Error?e.message:String(e))}};
 return el(Modal,{title:`Pagarle ahora a ${name}`,onClose,width:440},
  el("div",{className:"up-rows"},Row("Monto",money(amount),"total"),Row("A","Su banco (el de Banco y pagos)"),Row("Llega","1 a 2 días hábiles")),
  el("div",{className:"up-muted"},"Es el mismo pago del lunes, adelantado: el saldo no se puede pagar dos veces."),
  err?el("div",{className:"up-err"},err):null,
  el("footer",null,el("button",{type:"button",className:"up-btn",onClick:onClose},"Cancelar"),el("button",{type:"button",className:"up-btn gold",disabled:busy||!(amount>0),onClick:pay},busy?"Pagando…":`Pagar ${money(amount)}`)));
}

// ── Cards ─────────────────────────────────────────────────────────────
function NotesCard({id}){
 const[notes,setNotes]=React.useState(null),[text,setText]=React.useState(""),[busy,setBusy]=React.useState(false),[err,setErr]=React.useState(null);
 React.useEffect(()=>{if(!(id>0))return;let off=false;apiGet(`/admin/users/${id}/notes`).then(d=>{if(!off)setNotes(d&&Array.isArray(d.notes)?d.notes:[])}).catch(()=>{if(!off)setNotes([])});return()=>{off=true}},[id]);
 const save=async()=>{const v=text.trim();if(!v||busy)return;setBusy(true);setErr(null);try{const d=await apiPost(`/admin/users/${id}/notes`,{text:v},{retry:{maxAttempts:1}});setNotes(d.notes||[]);setText("")}catch(e){setErr(e instanceof Error?e.message:String(e))}setBusy(false)};
 return el(Card,{title:"Notas del equipo"},
  notes===null?el("div",{className:"up-skel",style:{height:48}}):notes.length===0?el("div",{className:"up-empty"},"Sin notas. Solo las ve el equipo."):
  notes.slice(0,5).map((n,i)=>el("div",{className:"up-note",key:i},n.text,el("small",null,when(n.at)))),
  el("textarea",{className:"up-text",placeholder:"Agregar nota",value:text,maxLength:1000,onChange:e=>setText(e.target.value)}),
  err?el("div",{className:"up-err"},err):null,
  el("div",null,el("button",{type:"button",className:"up-btn sm gold",disabled:!text.trim()||busy,onClick:save},busy?"Guardando…":"Guardar nota")));
}

function ChatList({chats,navigate,limit}){
 if(chats===null)return el("div",{className:"up-skel",style:{height:48}});
 if(!chats.length)return el("div",{className:"up-empty"},"Nunca ha escrito a soporte.");
 const STATUS_CHAT={open:"Abierto",escalated:"Con un agente",dispatch_takeover:"Con un agente",closed:"Cerrado",resolved:"Cerrado"};
 return el("div",{className:"up-rows"},chats.slice(0,limit||99).map(c=>el("div",{className:"up-row",key:c.id,style:{cursor:"pointer"},onClick:()=>navigate(`/soporte/chat/${c.id}`)},
  el("span",{style:{minWidth:0,overflow:"hidden",textOverflow:"ellipsis",whiteSpace:"nowrap"}},`Chat #${c.id} · ${STATUS_CHAT[c.status]||c.status||"—"}${c.last_message?" · "+String(c.last_message).slice(0,60):""}`),
  el("b",{style:{whiteSpace:"nowrap"}},ago(c.last_message_at||c.updated_at)||"—"))));
}

function WriteSupport({id,name,navigate}){
 const[text,setText]=React.useState(""),[busy,setBusy]=React.useState(false),[err,setErr]=React.useState(null);
 const send=async()=>{const message=text.trim();if(!message||busy)return;setBusy(true);setErr(null);try{const r=await apiPost(`/admin/users/${id}/support-chat`,{message},{retry:{maxAttempts:1}});navigate(`/soporte/chat/${r.chat_id}`)}catch(e){setBusy(false);setErr(e instanceof Error?e.message:String(e))}};
 return el(Card,{title:`Escribirle a ${name}`},
  el("div",{className:"up-muted"},"Le llega como un mensaje de Soporte en su app, con aviso. Usa el chat abierto si lo hay."),
  el("textarea",{className:"up-text",value:text,maxLength:2000,placeholder:`Hola ${name}, `,onChange:e=>setText(e.target.value)}),
  err?el("div",{className:"up-err"},err):null,
  el("div",null,el("button",{type:"button",className:"up-btn sm gold",disabled:!text.trim()||busy,onClick:send},busy?"Enviando…":"Enviar")));
}

function TripCard({t,role,kicker,onOpen}){
 const other=role==="driver"?(t.rider_name?`Pasajero: ${firstName(t.rider_name)}`:null):(t.driver_name?`Conductor: ${firstName(t.driver_name)}`:"Sin conductor todavía");
 return el(Card,{hot:true},
  el("div",{style:{display:"flex",justifyContent:"space-between",gap:8,flexWrap:"wrap",alignItems:"center"}},el("span",{className:"up-kicker"},kicker),el(StatusPill,{s:t.status})),
  el("div",{className:"up-big"},el(TripWhen,{t})),
  el(Route,{t}),
  el("div",{className:"up-muted"},[tier(t.vehicle_type),money(role==="driver"&&t.driver_earnings!=null?t.driver_earnings:t.fare),other].filter(Boolean).join(" · ")),
  el("div",{className:"up-actions"},el("button",{type:"button",className:"up-btn sm gold",onClick:()=>onOpen(t)},"Ver detalles")));
}

// ── Tabs ──────────────────────────────────────────────────────────────
const RIDER_TABS=[["resumen","Resumen"],["viajes","Viajes"],["pagos","Pagos"],["soporte","Soporte"],["verificacion","Verificación"],["cuenta","Cuenta"],["historial","Historial"]];
const DRIVER_TABS=[["resumen","Resumen"],["viajes","Viajes"],["ganancias","Ganancias"],["documentos","Documentos"],["vehiculo","Vehículo"],["soporte","Soporte"],["cuenta","Cuenta"],["historial","Historial"]];
const RIDER_HOME={"Información de cuenta":"cuenta","Contratos":"cuenta","Métodos de pago":"pagos","Historial de pagos":"pagos","Fotos de verificación":"verificacion","Vencimientos (IA)":"verificacion","Historial de cambios":"historial"};
const DRIVER_HOME={"Información de cuenta":"cuenta","Sobre el driver":"cuenta","Métodos de pago":"cuenta","Historial de pagos":"cuenta","Vehículo":"vehiculo","Banco y pagos":"ganancias","Ganancias":"ganancias","Rendimiento":"ganancias","Fotos de verificación":"documentos","Vencimientos (IA)":"documentos","Contratos":"documentos","Historial de cambios":"historial"};

function flatten(list,out){(Array.isArray(list)?list:[list]).forEach(c=>{if(c==null||c===false||c===true)return;if(c.type===React.Fragment&&c.props)flatten(c.props.children,out);else out.push(c)});return out}

function ProfileShell(props){
 ensureCss();
 const{cruiseRole:role,cruiseId:id,cruisePerson:person,cruiseOnline:online,children}=props;
 const isDriver=role==="driver";
 const navigate=useNavigate();
 const{data,err,limit,setLimit,reload}=useProfile(id);
 const chats=useChats(id);
 const[tab,setTab]=React.useState("resumen"),[filter,setFilter]=React.useState("todos"),[trip,setTrip]=React.useState(null),[modal,setModal]=React.useState(null),[toastMsg,setToastMsg]=React.useState(null);
 const toastTimer=React.useRef(0);
 const toast=React.useCallback(m=>{setToastMsg(m);clearTimeout(toastTimer.current);toastTimer.current=setTimeout(()=>setToastMsg(null),3500)},[]);
 React.useEffect(()=>()=>clearTimeout(toastTimer.current),[]);
 // "Mensaje al driver / Chat con rider" (the old header button) lands here:
 // the open support chat, or the first message that opens one.
 React.useEffect(()=>{if(!(id>0))return;
  const fn=async uid=>{if(uid!==id)return;try{const r=await apiGet(`/admin/users/${id}/support-chat`,{retry:{maxAttempts:1}});if(r&&r.chat_id){navigate(`/soporte/chat/${r.chat_id}`);return}}catch{}setModal("write")};
  window.__cruiseWriteSupport=fn;return()=>{if(window.__cruiseWriteSupport===fn)delete window.__cruiseWriteSupport}},[id,navigate]);

 // Old cards → tabs by their title; anything without a title (dialogs,
 // re-auth) always renders. A titled card nobody mapped lands in Cuenta.
 const all=flatten(children,[]);
 const header=all.length?all[0]:null;
 const home=isDriver?DRIVER_HOME:RIDER_HOME;
 const buckets={},always=[];
 all.slice(1).forEach(c=>{const title=c&&c.props&&typeof c.props.title==="string"?c.props.title:null;if(title===null){always.push(c);return}const k=home[title]||"cuenta";(buckets[k]=buckets[k]||[]).push(c)});
 const old=k=>(buckets[k]||[]).map((c,i)=>J.jsx(React.Fragment,{children:c},`${k}-${i}`));

 const u=data&&data.user||{};
 const st=data&&data.stats||{};
 const name=`${person&&person.firstName||u.first_name||""}`.trim()||"este usuario";
 const fullName=`${person&&person.firstName||u.first_name||""} ${person&&person.lastName||u.last_name||""}`.trim();
 const phone=u.phone||person&&person.phone||"";
 const trips=data&&Array.isArray(data.trips)?data.trips:[];
 const counts={todos:trips.length,completados:trips.filter(t=>t.status==="completed").length,cancelados:trips.filter(t=>t.status==="cancelled"||t.status==="canceled").length,reservas:trips.filter(t=>t.reservation).length};
 const shown=trips.filter(t=>filter==="todos"||(filter==="completados"&&t.status==="completed")||(filter==="cancelados"&&(t.status==="cancelled"||t.status==="canceled"))||(filter==="reservas"&&t.reservation));

 const chips=[];
 if(data){
  chips.push(el("span",{className:"up-chip",key:"r"},[isDriver?"Conductor":"Pasajero",isDriver&&data.vehicle?tier(data.vehicle.vehicle_type):null,isDriver&&u.drive_city?`${u.drive_city}${u.drive_state?", "+u.drive_state:""}`:null].filter(Boolean).join(" · ")));
  if(isDriver&&online)chips.push(el("span",{className:"up-chip gold live",key:"on"},u.online_since?`En línea · ${dur(u.online_since)}`:"En línea"));
  if(isDriver&&u.go_online_disabled)chips.push(el("span",{className:"up-chip",key:"gate"},"No puede conectarse"));
  if(u.verified_at)chips.push(el("span",{className:"up-chip gold",key:"v"},`${isDriver?"Aprobado":"Verificado"} · ${when(u.verified_at,true)}`));
  if(isDriver&&u.cruise_level)chips.push(el("span",{className:"up-chip",key:"lvl"},`Nivel ${u.cruise_level}`));
  const app=appLabel(u);if(app)chips.push(el("span",{className:"up-chip",key:"app"},app));
  if(u.locale&&LANG[String(u.locale).slice(0,2)])chips.push(el("span",{className:"up-chip",key:"lang"},LANG[String(u.locale).slice(0,2)]));
  if(u.created_at)chips.push(el("span",{className:"up-chip",key:"since"},`Desde ${monthYear(u.created_at)}`));
  const seen=ago(u.last_active_at);if(seen)chips.push(el("span",{className:"up-chip",key:"seen"},`Activo ${seen}`));
 }

 const stats=!data?null:isDriver?[
  ["Viajes",st.trips_completed??0],["Calificación",st.rating?`★ ${Number(st.rating).toFixed(2)}`:"—"],["Aceptación",st.acceptance!=null?`${Math.round(st.acceptance*100)}%`:"—"],["Esta semana",money(st.week_earnings),"gold"],["Por pagarle",money(st.pending_balance)]
 ]:[
  ["Viajes",st.trips_completed??0],["Gastado",money(st.spent),"gold"],["Reservas",st.reservations_upcoming??0],["Calificación",st.rating?`★ ${Number(st.rating).toFixed(1)}`:"—"],["Cancelaciones",st.trips_cancelled??0]
 ];

 const tabs=isDriver?DRIVER_TABS:RIDER_TABS;
 const tripsTotal=data?data.trips_total:null;

 const recent=trips.filter(t=>!["scheduled","scheduled_accepted","scheduled_active"].includes(t.status)).slice(0,5);
 const nowCard=data&&data.current?el(TripCard,{t:data.current,role,kicker:"Ahora",onOpen:setTrip}):null;
 const nextCard=data&&data.upcoming&&data.upcoming.length?el(TripCard,{t:data.upcoming[0],role,kicker:data.upcoming.length>1?`Próxima reserva · ${data.upcoming.length} en total`:"Próxima reserva",onOpen:setTrip}):null;
 const recentCard=el(Card,{title:"Últimos viajes",action:trips.length?el("button",{type:"button",className:"up-link",onClick:()=>setTab("viajes")},"Ver todos"):null},data?el(TripTable,{trips:recent,role,onOpen:setTrip,compact:true}):el("div",{className:"up-skel"}));
 const contactCard=el(Card,{title:"Contacto"},el("div",{className:"up-rows"},Row("Teléfono",phone?phoneFmt(phone):"—"),Row("Correo",u.email||person&&person.email||"—"),Row("ID",id>0?String(id):"—")));
 const supportMini=el(Card,{title:"Soporte",action:el("button",{type:"button",className:"up-link",onClick:()=>setTab("soporte")},"Ver todo")},el(ChatList,{chats,navigate,limit:3}));

 let body=null;
 if(tab==="resumen"){
  body=el("div",{className:"up-grid"},
   el("div",{className:"up-col"},nowCard,nextCard,
    isDriver?el(Card,{title:"Esta semana",action:el("button",{type:"button",className:"up-link",onClick:()=>setTab("ganancias")},"Ver detalle")},data?el("div",{className:"up-rows"},Row("Viajes",String(st.week_trips??0)),Row("Propinas",money(st.week_tips)),Row("Ganó",money(st.week_earnings),"gold"),Row("Por pagarle",money(st.pending_balance),"total")):el("div",{className:"up-skel"}),el("div",{className:"up-muted"},"Pago automático los lunes a su banco.")):null,
    recentCard),
   el("div",{className:"up-col"},
    isDriver&&data&&data.vehicle?el(Card,{title:"Vehículo",action:el("button",{type:"button",className:"up-link",onClick:()=>setTab("vehiculo")},"Ver")},el("div",{className:"up-big"},[data.vehicle.make,data.vehicle.model,data.vehicle.year].filter(Boolean).join(" ")),el("div",{className:"up-muted"},[data.vehicle.color,data.vehicle.plate,data.vehicle.plate_state,tier(data.vehicle.vehicle_type)].filter(Boolean).join(" · "))):null,
    !isDriver?el(Card,{title:"Pagos",action:el("button",{type:"button",className:"up-link",onClick:()=>setTab("pagos")},"Ver pagos")},el("div",{className:"up-rows"},Row("Cruise Cash",data?cents(st.cruise_cash_cents):"—"),Row("Gastado en total",data?money(st.spent):"—"))):null,
    supportMini,contactCard,el(NotesCard,{id})));
 }else if(tab==="viajes"){
  body=el(Card,{title:`Viajes de ${name}`},
   el("div",{className:"up-filters"},[["todos","Todos"],["completados","Completados"],["cancelados","Cancelados"],["reservas","Reservas"]].map(([k,l])=>el("button",{type:"button",key:k,className:filter===k?"up-filter on":"up-filter",onClick:()=>setFilter(k)},`${l} · ${counts[k]}`))),
   data?el(TripTable,{trips:shown,role,onOpen:setTrip}):el("div",{className:"up-skel"}),
   data&&tripsTotal>trips.length&&limit<200?el("div",null,el("button",{type:"button",className:"up-btn sm",onClick:()=>setLimit(200)},`Ver más (${tripsTotal} en total)`)):null,
   data&&tripsTotal>trips.length&&limit>=200?el("div",{className:"up-muted"},`Se muestran los ${trips.length} más recientes de ${tripsTotal}.`):null);
 }else if(tab==="pagos"){
  body=el("div",{className:"up-col"},el(Card,{title:"Cruise Cash"},el("div",{className:"up-rows"},Row("Saldo",data?cents(st.cruise_cash_cents):"—","gold"))),old("pagos"));
 }else if(tab==="ganancias"){
  body=el("div",{className:"up-col"},
   el(Card,{title:"Esta semana"},data?el("div",{className:"up-rows"},Row("Viajes",String(st.week_trips??0)),Row("Propinas",money(st.week_tips)),Row("Ganó esta semana",money(st.week_earnings),"gold"),Row("Ganó en total",money(st.total_earnings)),Row("Por pagarle",money(st.pending_balance),"total")):el("div",{className:"up-skel"}),
    el("div",{className:"up-actions"},el("button",{type:"button",className:"up-btn sm gold",disabled:!data||!(st.pending_balance>0),onClick:()=>setModal("pay")},`Pagar ahora ${data?money(st.pending_balance):""}`))),
   old("ganancias"));
 }else if(tab==="soporte"){
  body=el("div",{className:"up-grid"},el("div",{className:"up-col"},el(Card,{title:"Chats de soporte"},el(ChatList,{chats,navigate}))),
   el("div",{className:"up-col"},id>0?el(WriteSupport,{id,name,navigate}):null,null));
 }else{
  const cards=old(tab);
  body=el("div",{className:"up-col"},cards.length?cards:el(Card,null,el("div",{className:"up-empty"},"Nada aquí todavía.")),tab==="cuenta"?el(NotesCard,{id}):null);
 }

 return el("div",{className:"up-page"},
  el("div",{className:"up-hero"},
   header,
   chips.length?el("div",{className:"up-meta"},chips):null,
   el("div",{className:"up-actions"},
    el("button",{type:"button",className:"up-btn",onClick:()=>setModal("call")},"Llamar"),
    !isDriver&&id>0?el("button",{type:"button",className:"up-btn",onClick:()=>navigate("/viajes/nuevo",{state:{bookingPrefill:{rider:{id,first_name:u.first_name||person&&person.firstName||"",last_name:u.last_name||person&&person.lastName||"",phone,photo_url:u.photo_url||person&&person.photoUrl||null},pickup:null,dropoff:null}}})},"Crear viaje"):null,
    isDriver&&id>0?el("button",{type:"button",className:"up-btn",onClick:()=>setModal("offer")},"Ofrecer viaje"):null,
    isDriver&&online?el("button",{type:"button",className:"up-btn",onClick:()=>navigate("/mapa")},"Ver en el mapa"):null),
   err?el("div",{className:"up-err"},`No se pudieron cargar los números: ${err}`):stats?el("div",{className:"up-stats"},stats.map(([l,v,c])=>el("div",{className:"up-stat",key:l},el("span",null,l),el("b",{className:c==="gold"?"gold":undefined},String(v))))):id>0?el("div",{className:"up-skel",style:{height:64}}):null),
  el("nav",{className:"up-tabs","aria-label":"Secciones"},tabs.map(([k,l])=>el("button",{type:"button",key:k,className:tab===k?"up-tab on":"up-tab",onClick:()=>setTab(k)},l,k==="viajes"&&tripsTotal?el("i",null,tripsTotal):null))),
  body,
  ...always,
  trip?el(TripModal,{t:trip,role,onClose:()=>setTrip(null)}):null,
  modal==="call"?el(CallModal,{name:fullName||name,phone,onClose:()=>setModal(null),toast}):null,
  modal==="write"?el(Modal,{title:`Escribirle a ${name}`,onClose:()=>setModal(null),width:480},el(WriteSupport,{id,name,navigate})):null,
  modal==="offer"?el(OfferModal,{driverId:id,name,onClose:()=>setModal(null),toast}):null,
  modal==="pay"?el(PayModal,{driverId:id,name,amount:st.pending_balance,onClose:()=>setModal(null),onDone:reload,toast}):null,
  toastMsg?el("div",{className:"up-toast",role:"status"},toastMsg):null);
}

export{ProfileShell,Modal,CallModal,OfferModal,PayModal,ensureCss};
