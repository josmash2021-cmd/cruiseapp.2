/*! guard-pin panel_trips_board: Viajes = UNA lista con pestañas (dueño 2026-11-16, dibujo https://claude.ai/artifact/MSML67sC6y5MHc4kNF2rxQ) - chunk escrito a mano, sin fuente React (CLAUDE.md #30). Reemplaza las 10 tarjetas y las páginas por categoría. Datos: GET /admin/trips/board?tab= cada 8 s con la pestaña visible. Tocar una fila abre la página del viaje. Si este chunk falla se ven las pantallas de antes. */
import{r as React,j as J,y as useNavigate}from"./vendor-react-DprhJQz-.js";
import{W as apiGet}from"./index-CuQT_62K.js";

function el(type,props,...kids){
 const p=Object.assign({},props||{});const key=p.key;delete p.key;
 const c=kids.filter(k=>k!==undefined);
 if(c.length===1)p.children=c[0];else if(c.length>1)p.children=c;
 return c.length>1?J.jsxs(type,p,key):J.jsx(type,p,key);
}

const CSS=`
.tb-page{display:flex;flex-direction:column;gap:18px;color:#F4F4F5;min-width:0}
.tb-top{display:flex;align-items:center;gap:12px;flex-wrap:wrap}
.tb-top h1{margin:0;font-size:28px;font-weight:800;line-height:1.15}
.tb-top p{margin:4px 0 0;font-size:13.5px;color:rgba(244,244,245,.55)}
.tb-chips{display:flex;gap:6px;flex-wrap:wrap}
.tb-chip{height:34px;padding:0 13px;border-radius:999px;border:1px solid rgba(255,255,255,.12);background:transparent;color:rgba(244,244,245,.72);font-family:inherit;font-size:12.5px;font-weight:600;cursor:pointer}
.tb-chip.on{background:#262630;border-color:#262630;color:#fff}
.tb-new{height:40px;padding:0 18px;border-radius:999px;border:0;background:#E8C547;color:#14141A;font-family:inherit;font-size:14px;font-weight:700;cursor:pointer;white-space:nowrap}
.tb-tabs{display:flex;gap:8px;flex-wrap:wrap;align-items:center}
.tb-tab{height:36px;padding:0 14px;border-radius:999px;border:1px solid rgba(255,255,255,.12);background:transparent;color:rgba(244,244,245,.72);font-family:inherit;font-size:13px;font-weight:600;cursor:pointer;display:inline-flex;align-items:center;gap:8px;white-space:nowrap}
.tb-tab b{font-weight:800}
.tb-tab.on{background:#E8C547;border-color:#E8C547;color:#14141A}
.tb-tab.hot:not(.on) b{color:#FF8A7A}
.tb-search{margin-left:auto;display:flex;align-items:center;gap:8px;height:38px;padding:0 14px;border-radius:999px;background:#1C1C24;border:1px solid rgba(255,255,255,.1);min-width:min(300px,100%);color:rgba(244,244,245,.55);box-sizing:border-box}
.tb-search input{flex:1;min-width:0;background:transparent;border:0;outline:0;color:#F4F4F5;font-family:inherit;font-size:13px}
.tb-box{background:#16161C;border:1px solid rgba(255,255,255,.06);border-radius:18px;padding:12px 0 6px;overflow-x:auto}
.tb-grid{min-width:1060px}
.tb-row{display:grid;grid-template-columns:150px 56px 150px minmax(84px,1fr) minmax(84px,1fr) minmax(160px,1.6fr) 80px 72px 150px;gap:12px;align-items:center;padding:12px 18px;border-top:1px solid rgba(255,255,255,.05);font-size:13.5px;color:#F4F4F5;cursor:pointer;width:100%;box-sizing:border-box;background:transparent;border-left:0;border-right:0;border-bottom:0;text-align:left;font-family:inherit}
.tb-row:hover{background:rgba(255,255,255,.03)}
.tb-row.head{cursor:default;font-size:11.5px;font-weight:700;letter-spacing:.06em;text-transform:uppercase;color:rgba(244,244,245,.48);border-top:0;padding-top:2px;padding-bottom:10px}
.tb-row.head:hover{background:transparent}
.tb-row.flash{animation:tb-flash 1.6s ease-out}
@keyframes tb-flash{0%{background:rgba(232,197,71,.16)}100%{background:transparent}}
.tb-pill{display:inline-flex;align-items:center;gap:6px;height:24px;padding:0 9px;border-radius:999px;font-size:11.5px;font-weight:700;white-space:nowrap}
.tb-pill i{width:7px;height:7px;border-radius:50%;display:block}
.p-search{background:rgba(255,107,87,.14);color:#FF8A7A}.p-search i{background:#FF6B57}
.p-go{background:rgba(232,197,71,.14);color:#E8C547}.p-go i{background:#E8C547}
.p-wait{background:rgba(232,197,71,.14);color:#E8C547}.p-wait i{background:#E8C547}
.p-trip{background:rgba(255,255,255,.1);color:#fff}.p-trip i{background:#fff}
.p-resv{background:rgba(127,209,255,.12);color:#8FD7FF}.p-resv i{background:#7FD1FF}
.p-open{background:rgba(255,154,122,.14);color:#FFB59E}.p-open i{background:#FF9A7A}
.p-done{background:rgba(61,214,140,.12);color:#6FE3AA}.p-done i{background:#3DD68C}
.p-off{background:#262630;color:rgba(244,244,245,.6)}.p-off i{background:rgba(244,244,245,.4)}
.tb-mut{color:rgba(244,244,245,.55)}
.tb-cut{overflow:hidden;text-overflow:ellipsis;white-space:nowrap;min-width:0}
.tb-route{display:flex;flex-direction:column;min-width:0;gap:3px}
.tb-route b{font-weight:600}
.tb-air{display:inline-flex;align-items:center;gap:5px;height:20px;padding:0 7px;border-radius:6px;background:#262630;font-size:11px;font-weight:700;color:#fff;align-self:flex-start;max-width:100%}
.tb-now{font-weight:700}
.tb-now.hot{color:#FF8A7A}.tb-now.gold{color:#E8C547}
.tb-empty{padding:30px 18px;color:rgba(244,244,245,.55);font-size:14px}
.tb-skel{height:46px;margin:6px 18px;border-radius:10px;background:linear-gradient(90deg,#1C1C24,#23232D,#1C1C24);background-size:200% 100%;animation:tb-sk 1.2s infinite linear}
@keyframes tb-sk{to{background-position:-200% 0}}
@media (prefers-reduced-motion:reduce){.tb-row.flash,.tb-skel{animation:none}}
@media (max-width:760px){
 .tb-search{margin-left:0;width:100%}
 .tb-box{padding:4px 0}
 .tb-grid{min-width:0}
 .tb-row.head{display:none}
 .tb-row{grid-template-columns:minmax(0,1fr) auto;grid-template-areas:"st now" "route route" "rider price" "when id";row-gap:7px;padding:14px 16px}
 .c-st{grid-area:st}.c-now{grid-area:now;text-align:right}.c-route{grid-area:route}.c-rider{grid-area:rider}.c-price{grid-area:price;text-align:right}.c-when{grid-area:when;color:rgba(244,244,245,.55)}.c-id{grid-area:id;text-align:right}
 .c-driver,.c-tier{display:none}
}
`;
function ensureCss(){if(typeof document==="undefined"||document.getElementById("tb-css"))return;const s=document.createElement("style");s.id="tb-css";s.textContent=CSS;document.head.appendChild(s)}

const TABS=[["vivo","En vivo"],["busca","Buscando conductor"],["reservas","Reservas"],["aero","Aeropuerto"],["hechos","Terminados hoy"],["cancel","Cancelados hoy"]];
const MARKETS=[["all","Todos"],["AL","Alabama"],["FL","Florida"]];
const KIND={search:["Buscando conductor","p-search"],pickup:["Yendo a recoger","p-go"],wait:["En la recogida","p-wait"],ontrip:["En viaje","p-trip"],reserved:["Reserva confirmada","p-resv"],reserved_open:["Reserva sin conductor","p-open"],done:["Terminado","p-done"],cancelled:["Cancelado","p-off"]};
const EMPTY={vivo:"Ningún conductor está en un viaje ahora.",busca:"Ningún viaje está buscando conductor.",reservas:"No hay reservas por delante.",aero:"Ningún viaje al aeropuerto ahora.",hechos:"Todavía no termina ningún viaje hoy.",cancel:"Ningún viaje cancelado hoy."};
// The old category pages (/viajes/categoria/:category) land on their tab.
function tabForCategory(c){const s=String(c||"").toLowerCase();if(s.includes("airport"))return"aero";if(s.includes("schedul")||s.includes("reserv"))return"reservas";if(s.includes("progress"))return"vivo";if(s.includes("complet"))return"hechos";if(s.includes("cancel"))return"cancel";if(s.includes("active")||s.includes("request"))return"busca";return null}
const memo={tab:null,market:null,data:{}};
try{memo.market=localStorage.getItem("cruise-trips-market")}catch{}

const money=v=>"$"+Number(v||0).toLocaleString("en-US",{minimumFractionDigits:2,maximumFractionDigits:2});
const ago=iso=>{const t=Date.parse(iso||"");return isFinite(t)?Math.max(0,Date.now()-t):0};
const clock=ms=>{const s=Math.floor(ms/1e3);if(s>=3600)return`${Math.floor(s/3600)} h ${Math.floor(s%3600/60)} min`;return`${Math.floor(s/60)}:${String(s%60).padStart(2,"0")}`};
function ahead(iso){const t=Date.parse(iso||"");if(!isFinite(t))return"";const m=Math.round((t-Date.now())/6e4);if(m<=0)return"Ya es la hora";if(m<60)return`En ${m} min`;const h=Math.round(m/60);if(h<24)return`En ${h} h`;const d=Math.round(h/24);return d===1?"En 1 día":`En ${d} días`}
function now(r){
 switch(r.kind){
  case"search":return[`Espera ${clock(ago(r.since))}`,"hot"];
  case"pickup":return[r.eta_min!=null?`Llega en ${r.eta_min} min`:"Yendo a recoger","gold"];
  case"wait":return[`Esperando ${clock(ago(r.since))}`,"gold"];
  case"ontrip":return[r.eta_min!=null?`Destino en ${r.eta_min} min`:"En viaje",""];
  case"reserved":return[ahead(r.when),"tb-mut"];
  case"reserved_open":return[`Sin conductor · ${ahead(r.when).toLowerCase()}`,"gold"];
  default:return[r.note||"—","tb-mut"];
 }
}
const sig=r=>[r.kind,r.driver||"",r.eta_min==null?"":r.eta_min].join("|");

function TripsBoard({category}){
 ensureCss();
 const navigate=useNavigate();
 const st0=(()=>{try{return window.history.state&&window.history.state.usr||{}}catch{return{}}})();
 const[tab,setTabState]=React.useState(()=>st0.cruiseTab||tabForCategory(category)||memo.tab||"vivo");
 const[market,setMarketState]=React.useState(memo.market||"all");
 const[q,setQ]=React.useState("");
 const[data,setData]=React.useState(memo.data[tab]||null),[err,setErr]=React.useState(null);
 const[,tick]=React.useState(0);
 const prevSig=React.useRef(new Map()),[flash,setFlash]=React.useState(new Set());
 const setTab=t=>{memo.tab=t;setTabState(t);setData(memo.data[t]||null)};
 const setMarket=m=>{memo.market=m;try{localStorage.setItem("cruise-trips-market",m)}catch{}setMarketState(m)};
 React.useEffect(()=>{const t=st0.cruiseTab||tabForCategory(category);if(t&&t!==tab)setTab(t)},[category]);// eslint-disable-line
 React.useEffect(()=>{let off=false,timer=null;
  const load=async()=>{clearTimeout(timer);if(document.visibilityState!=="visible"){timer=setTimeout(load,8e3);return}
   try{const d=await apiGet("/admin/trips/board",{query:{tab},retry:{maxAttempts:1},timeoutMs:9e3});if(off)return;
    if(d&&Array.isArray(d.rows)){
     const changed=new Set();const ps=prevSig.current;
     for(const r of d.rows){const s=sig(r);if(ps.has(r.id)&&ps.get(r.id)!==s)changed.add(r.id);ps.set(r.id,s)}
     if(changed.size){setFlash(changed);setTimeout(()=>{if(!off)setFlash(new Set())},1700)}
     memo.data[tab]=d;setData(d);setErr(null)}
   }catch(e){if(!off)setErr(e instanceof Error?e.message:String(e))}
   if(!off)timer=setTimeout(load,8e3)};
  prevSig.current=new Map();load();
  const vis=()=>{if(document.visibilityState==="visible")load()};document.addEventListener("visibilitychange",vis);
  return()=>{off=true;clearTimeout(timer);document.removeEventListener("visibilitychange",vis)}},[tab]);
 React.useEffect(()=>{const i=setInterval(()=>tick(x=>x+1),1e3);return()=>clearInterval(i)},[]);

 const counts=data&&data.counts||{};
 const qq=q.trim().toLowerCase().replace(/^#/,"");
 const rows=(data&&data.rows||[]).filter(r=>(market==="all"||r.market===market)&&(!qq||String(r.id)===qq||[r.rider,r.driver,r.from,r.to,r.airline].some(v=>String(v||"").toLowerCase().includes(qq))));
 const head=el("div",{className:"tb-row head",role:"row"},...["Estado","#","Cuándo","Pasajero","Conductor","Ruta","Categoría","Precio","Ahora"].map(h=>el("span",{key:h,role:"columnheader"},h)));
 return el("div",{className:"tb-page"},
  el("div",{className:"tb-top"},
   el("div",{style:{flex:"1 1 260px",minWidth:0}},el("h1",null,"Viajes"),el("p",null,"Todo en una lista: en vivo, reservas y aeropuerto. Se actualiza sola.")),
   el("div",{className:"tb-chips",role:"group","aria-label":"Estado"},MARKETS.map(([m,label])=>el("button",{type:"button",key:m,className:m===market?"tb-chip on":"tb-chip","aria-pressed":m===market,onClick:()=>setMarket(m)},label))),
   el("button",{type:"button",className:"tb-new",onClick:()=>navigate("/viajes/nuevo")},"+ Nuevo viaje")),
  el("div",{className:"tb-tabs"},
   TABS.map(([id,label])=>{const n=(counts[id]||{})[market]||0;return el("button",{type:"button",key:id,className:"tb-tab"+(id===tab?" on":"")+(id==="busca"&&n>0?" hot":""),"aria-pressed":id===tab,onClick:()=>setTab(id)},label,el("b",null,data?String(n):"·"))}),
   el("label",{className:"tb-search"},el("svg",{width:15,height:15,viewBox:"0 0 24 24",fill:"none",stroke:"currentColor",strokeWidth:2,strokeLinecap:"round","aria-hidden":"true"},el("circle",{cx:11,cy:11,r:7}),el("path",{d:"m20 20-4-4"})),el("input",{type:"search",value:q,placeholder:"Viaje #, pasajero, conductor o lugar","aria-label":"Buscar viajes",onChange:e=>setQ(e.target.value)}))),
  el("section",{className:"tb-box","aria-label":"Lista de viajes"},
   el("div",{className:"tb-grid",role:"table"},head,
    data===null?(err?el("div",{className:"tb-empty"},`No se pudo cargar la lista: ${err}`):[0,1,2,3].map(i=>el("div",{key:i,className:"tb-skel"}))):
    rows.length===0?el("div",{className:"tb-empty"},q.trim()?"Nada coincide con la búsqueda.":EMPTY[tab]):
    rows.map(r=>{const[label,pill]=KIND[r.kind]||[r.status,"p-off"];const[nowText,nowCls]=now(r);
     return el("button",{type:"button",key:r.id,role:"row",className:"tb-row"+(flash.has(r.id)?" flash":""),onClick:()=>navigate(`/viajes/viaje/sql_${r.id}`)},
      el("span",{className:"c-st"},el("span",{className:`tb-pill ${pill}`},el("i"),label)),
      el("span",{className:"tb-mut c-id"},`#${r.id}`),
      el("span",{className:"tb-cut c-when"},`${r.when_day} ${r.when_time}`.trim()),
      el("span",{className:"tb-cut c-rider"},r.rider),
      el("span",{className:r.driver?"tb-cut c-driver":"tb-cut tb-mut c-driver"},r.driver||"Sin conductor"),
      el("span",{className:"tb-route c-route"},el("span",{className:"tb-cut"},el("b",null,r.from||"—")," → ",r.to||"—"),r.airline?el("span",{className:"tb-air tb-cut"},"✈ ",r.airline):null),
      el("span",{className:"tb-mut tb-cut c-tier"},r.tier||"—"),
      el("span",{className:"c-price"},money(r.price)),
      el("span",{className:`tb-now c-now ${nowCls}`},nowText))}))));
}

export{TripsBoard};
