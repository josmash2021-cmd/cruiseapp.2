/*! guard-pin panel_reservations_board: Reservas estilo Lyft (dueño 2026-11-18, dibujo https://claude.ai/artifact/3PRGKiMqbLtYVhYC8DdG5H) - chunk escrito a mano, sin fuente React (CLAUDE.md #30). 4 números arriba (sin conductor, con conductor, hoy, al aeropuerto), pestañas Próximas / Sin conductor / Con conductor / En curso / Completadas / Canceladas, la lista por el día del lugar de recogida (#68) y el detalle a la derecha (en teléfono, hoja abajo). Datos: GET /admin/reservations/board cada 10 s con la pestaña a la vista. Acciones = endpoints de siempre: avisar / ofrecer = POST /admin/trips/{id}/reassign (#88), cancelar = POST /admin/trips/{id}/cancel (al conductor de una reserva no le llega nada, #44). Si este chunk falla se ve la página de antes. */
import{r as React,j as J,y as useNavigate}from"./vendor-react-DprhJQz-.js";
import{W as apiGet,L as apiPost}from"./index-CuQT_62K.js";
import{Modal,CallModal,ensureCss as ensureProfileCss}from"./user-profile-Cruise2026.js";

function el(type,props,...kids){
 const p=Object.assign({},props||{});const key=p.key;delete p.key;
 const c=kids.filter(k=>k!==undefined);
 if(c.length===1)p.children=c[0];else if(c.length>1)p.children=c;
 return c.length>1?J.jsxs(type,p,key):J.jsx(type,p,key);
}

const RouteMap=React.lazy(()=>import("./trip-route-map-Cruise2026.js").then(m=>({default:m.TripRouteMap})));

const CSS=`
.rv-page{display:flex;flex-direction:column;gap:20px;color:#F4F4F5;min-width:0;container-type:inline-size;container-name:rv}
.rv-top{display:flex;align-items:flex-end;gap:12px;flex-wrap:wrap}
.rv-top h1{margin:0;font-size:28px;font-weight:800;line-height:1.15;letter-spacing:-.01em}
.rv-top p{margin:4px 0 0;font-size:14px;color:#A1A1AA}
.rv-chips{display:flex;gap:6px;flex-wrap:wrap}
.rv-chip{height:34px;padding:0 13px;border-radius:999px;border:1px solid rgba(255,255,255,.12);background:transparent;color:#C9C9D0;font-family:inherit;font-size:12.5px;font-weight:600;cursor:pointer;white-space:nowrap}
.rv-chip.on{background:#262630;border-color:#262630;color:#fff}
.rv-search{display:flex;align-items:center;gap:8px;height:38px;padding:0 14px;border-radius:999px;background:#1C1C24;border:1px solid rgba(255,255,255,.1);width:260px;max-width:100%;box-sizing:border-box;color:#A1A1AA}
.rv-search input{flex:1;min-width:0;background:transparent;border:0;outline:0;color:#F4F4F5;font-family:inherit;font-size:13px}
.rv-btn{height:38px;padding:0 15px;border-radius:999px;border:1px solid rgba(255,255,255,.14);background:#1E1E26;color:#F4F4F5;font-family:inherit;font-size:13px;font-weight:600;display:inline-flex;align-items:center;justify-content:center;gap:8px;cursor:pointer;white-space:nowrap;box-sizing:border-box}
.rv-btn:disabled{opacity:.5;cursor:default}
.rv-btn.gold{background:#E8C547;color:#14141A;border-color:#E8C547;font-weight:700}
.rv-btn.red{color:#FF9496;border-color:rgba(229,72,77,.35);background:transparent}
.rv-btn.big{height:44px}
.rv-btn.sm{height:34px}
.rv-tiles{display:grid;grid-template-columns:repeat(4,minmax(0,1fr));gap:14px}
.rv-tile{background:#16161C;border:1px solid rgba(255,255,255,.06);border-radius:18px;padding:16px 18px;display:flex;flex-direction:column;gap:4px;min-width:0;text-align:left;font-family:inherit;color:#F4F4F5;cursor:pointer}
.rv-tile.hot{border-color:rgba(229,72,77,.35)}
.rv-tile span{font-size:12.5px;font-weight:600;color:#A1A1AA}
.rv-tile b{font-size:30px;font-weight:800;line-height:1.15}
.rv-tile small{font-size:12.5px;color:#A1A1AA;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.rv-tabs{display:flex;gap:8px;flex-wrap:wrap}
.rv-tab{height:36px;padding:0 14px;border-radius:999px;border:1px solid rgba(255,255,255,.12);background:transparent;color:#C9C9D0;font-family:inherit;font-size:13px;font-weight:600;display:inline-flex;align-items:center;gap:8px;cursor:pointer;white-space:nowrap}
.rv-tab b{font-weight:800}
.rv-tab.on{background:#E8C547;border-color:#E8C547;color:#14141A}
.rv-tab.hot:not(.on) b{color:#FF8A7A}
.rv-split{display:flex;gap:18px;align-items:flex-start}
.rv-box{background:#16161C;border:1px solid rgba(255,255,255,.06);border-radius:18px}
.rv-list{flex:999 1 560px;min-width:0;padding-bottom:4px;overflow:hidden}
.rv-nowline{display:flex;align-items:center;gap:10px;padding:14px 18px 10px}
.rv-nowline i{width:8px;height:8px;border-radius:50%;background:#E8C547;flex:none}
.rv-nowline span{font-size:12.5px;font-weight:700;color:#E8C547}
.rv-nowline em{flex:1;height:1px;background:rgba(232,197,71,.35)}
.rv-day{padding:12px 18px 8px;font-size:11.5px;letter-spacing:.09em;font-weight:800;color:#A1A1AA;text-transform:uppercase}
.rv-row{display:grid;grid-template-columns:92px minmax(0,1fr) 128px 200px;gap:14px;align-items:center;padding:14px 18px;border:0;border-top:1px solid rgba(255,255,255,.05);background:transparent;width:100%;box-sizing:border-box;text-align:left;font-family:inherit;color:#F4F4F5;cursor:pointer}
.rv-row:hover{background:#1A1A21}
.rv-row.sel{background:#1D1B15;box-shadow:inset 3px 0 0 #E8C547}
.rv-row.flash{animation:rv-fl 1.6s ease-out}
@keyframes rv-fl{0%{background:rgba(232,197,71,.18)}100%{background:transparent}}
.rv-when{display:flex;flex-direction:column;gap:2px;min-width:0}
.rv-when b{font-size:16px;font-weight:800}
.rv-when small{font-size:11.5px;font-weight:600;color:#A1A1AA}
.rv-when em{font-style:normal;font-size:12px;font-weight:700;color:#A1A1AA}
.rv-when em.hot{color:#FF9496}
.rv-route{display:flex;flex-direction:column;gap:7px;min-width:0}
.rv-stop{display:flex;align-items:center;gap:9px;min-width:0}
.rv-stop b{font-size:13.5px;font-weight:600}
.rv-stop small{font-size:12.5px;color:#A1A1AA}
.rv-ring{width:10px;height:10px;border-radius:50%;box-sizing:border-box;flex:none;background:#14141A;border:2.5px solid #F4F4F5}
.rv-ring.g{border-color:#E8C547}
.rv-tags{display:flex;gap:6px;flex-wrap:wrap}
.rv-tag{display:inline-flex;align-items:center;gap:5px;height:20px;padding:0 7px;border-radius:6px;background:#262630;font-size:11px;font-weight:700;color:#fff;max-width:100%;box-sizing:border-box}
.rv-tag.air{background:#2A2618;color:#E8C547}
.rv-who{display:flex;align-items:center;gap:9px;min-width:0}
.rv-who>div{min-width:0}
.rv-who b{display:block;font-size:13.5px;font-weight:600}
.rv-who small{display:block;font-size:12px;color:#A1A1AA;font-weight:600}
.rv-who small.on{color:#5FE3A1}
.rv-av{width:34px;height:34px;border-radius:50%;display:inline-flex;align-items:center;justify-content:center;font-size:12.5px;font-weight:700;flex:none;color:#14141A}
.rv-av.none{background:transparent;border:1.5px dashed rgba(255,255,255,.25);color:#A1A1AA}
.rv-state{display:flex;flex-direction:column;gap:6px;align-items:flex-start;min-width:0}
.rv-state small{font-size:11.5px;color:#A1A1AA}
.rv-pill{display:inline-flex;align-items:center;gap:6px;min-height:24px;padding:3px 10px;border-radius:999px;font-size:12px;font-weight:700;box-sizing:border-box;max-width:100%}
.rv-pill.red{background:rgba(229,72,77,.15);color:#FF9496}
.rv-pill.gold{background:rgba(232,197,71,.14);color:#E8C547}
.rv-pill.green{background:rgba(61,214,140,.13);color:#5FE3A1}
.rv-pill.blue{background:rgba(96,165,250,.15);color:#93C5FD}
.rv-pill.gray{background:rgba(255,255,255,.07);color:#B9B9C1}
.rv-cut{overflow:hidden;text-overflow:ellipsis;white-space:nowrap;min-width:0}
.rv-empty{padding:30px 18px;color:#A1A1AA;font-size:14px}
.rv-skel{height:62px;margin:8px 18px;border-radius:12px;background:linear-gradient(90deg,#1C1C24,#23232D,#1C1C24);background-size:200% 100%;animation:rv-sk 1.2s infinite linear}
@keyframes rv-sk{to{background-position:-200% 0}}
.rv-detail{flex:1 1 340px;min-width:0;max-width:400px;padding:20px;display:flex;flex-direction:column;gap:16px;box-sizing:border-box}
.rv-detail h2{margin:0;font-size:22px;font-weight:800}
.rv-dhead{display:flex;align-items:center;justify-content:space-between;gap:10px}
.rv-dhead span{font-size:12.5px;font-weight:600;color:#A1A1AA}
.rv-x{width:34px;height:34px;padding:0;border-radius:50%;border:1px solid rgba(255,255,255,.14);background:#1E1E26;color:#F4F4F5;cursor:pointer;font-size:15px;flex:none}
.rv-sub{font-size:13px;font-weight:700;margin-top:3px;color:#A1A1AA}
.rv-sub.hot{color:#FF9496}
.rv-map{height:160px;border-radius:14px;overflow:hidden;background:#1B1B23;pointer-events:none}
.rv-map .trm{height:160px;border-radius:14px}
.rv-map .mapboxgl-ctrl-top-right{display:none}
.rv-rail{display:flex;flex-direction:column;gap:10px}
.rv-rail>div{display:flex;gap:10px;align-items:flex-start}
.rv-rail .rv-ring{margin-top:4px}
.rv-rail b{display:block;font-size:14px;font-weight:600}
.rv-rail small{display:block;font-size:12.5px;color:#A1A1AA}
.rv-steps h3{margin:0 0 8px;font-size:11.5px;letter-spacing:.09em;font-weight:800;color:#A1A1AA}
.rv-step{display:flex;gap:11px}
.rv-step>i{display:flex;flex-direction:column;align-items:center;font-style:normal}
.rv-step>i>b{width:12px;height:12px;border-radius:50%;box-sizing:border-box;border:2px solid #6B6B75;margin-top:3px;flex:none}
.rv-step>i>em{width:2px;flex:1;background:rgba(255,255,255,.08);min-height:16px}
.rv-step.done>i>b{border-color:#5FE3A1;background:#5FE3A1}
.rv-step.next>i>b{border-color:#E8C547}
.rv-step:last-child>i>em{visibility:hidden}
.rv-step>div{padding-bottom:10px;min-width:0}
.rv-step>div b{display:block;font-size:13.5px;font-weight:600}
.rv-step>div small{display:block;font-size:12px;color:#A1A1AA}
.rv-person{display:flex;align-items:center;gap:10px;padding:12px;border-radius:14px;background:#1B1B23}
.rv-person>div{flex:1;min-width:0}
.rv-person b{display:block;font-size:14px;font-weight:600}
.rv-person small{display:block;font-size:12px;color:#A1A1AA}
.rv-two{display:flex;gap:8px}
.rv-two>*{flex:1 1 0}
.rv-pick{display:flex;flex-direction:column;gap:6px;max-height:360px;overflow-y:auto}
.rv-pick button{display:flex;align-items:center;gap:10px;padding:10px 12px;border-radius:12px;border:1px solid rgba(255,255,255,.08);background:#14141A;color:#F4F4F5;font-family:inherit;text-align:left;cursor:pointer}
.rv-pick button.on{border-color:#E8C547;background:#221F14}
.rv-pick button>div{flex:1;min-width:0}
.rv-pick b{display:block;font-size:13.5px;font-weight:600}
.rv-pick small{display:block;font-size:12px;color:#A1A1AA}
.rv-dot{width:9px;height:9px;border-radius:50%;flex:none;background:#6B6B75}
.rv-dot.on{background:#3DD68C}
.rv-input{width:100%;box-sizing:border-box;height:38px;border-radius:12px;border:1px solid rgba(255,255,255,.12);background:#14141A;color:#fff;padding:0 12px;font-family:inherit;font-size:13px;outline:0}
.rv-toast{position:fixed;left:50%;bottom:24px;transform:translateX(-50%);z-index:80;background:#24242C;border:1px solid rgba(255,255,255,.1);border-radius:999px;padding:10px 18px;font-size:13.5px;color:#fff;box-shadow:0 12px 30px rgba(0,0,0,.45);max-width:calc(100vw - 32px);box-sizing:border-box}
@container rv (max-width:1100px){.rv-tiles{grid-template-columns:repeat(2,minmax(0,1fr))}}
.rv-detail.sheet{position:fixed;left:0;right:0;bottom:0;max-width:none;max-height:86vh;overflow-y:auto;z-index:70;border-radius:20px 20px 0 0;padding:20px max(16px,env(safe-area-inset-right)) calc(20px + env(safe-area-inset-bottom)) max(16px,env(safe-area-inset-left));background:#16161C;box-shadow:0 -18px 40px rgba(0,0,0,.5)}
.rv-shade{display:block;position:fixed;inset:0;z-index:69;background:rgba(0,0,0,.55)}
@container rv (max-width:760px){
 .rv-search{width:100%}
 .rv-row{grid-template-columns:minmax(0,1fr) auto;grid-template-areas:"route when" "who who" "state state";row-gap:10px;padding:14px 16px}
 .rv-when{grid-area:when;text-align:right;align-items:flex-end}
 .rv-route{grid-area:route}
 .rv-who.c-rider{grid-area:who}
 .rv-state{grid-area:state;flex-direction:row;flex-wrap:wrap;align-items:center}
}
@media (prefers-reduced-motion:reduce){.rv-row.flash,.rv-skel{animation:none}}
`;
function ensureCss(){if(typeof document==="undefined"||document.getElementById("rv-css"))return;const s=document.createElement("style");s.id="rv-css";s.textContent=CSS;document.head.appendChild(s)}

const TABS=[["proximas","Próximas"],["sin_conductor","Sin conductor"],["con_conductor","Con conductor"],["en_curso","En curso"],["completadas","Completadas"],["canceladas","Canceladas"]];
const MARKETS=[["all","Todos"],["AL","Alabama"],["FL","Florida"]];
const EMPTY={proximas:"No hay reservas por delante.",sin_conductor:"Todas las reservas tienen conductor.",con_conductor:"Ninguna reserva tiene conductor todavía.",en_curso:"Ninguna reserva está en curso ahora.",completadas:"Ninguna reserva se completó en los últimos 30 días.",canceladas:"Ninguna reserva se canceló en los últimos 30 días."};
const AV=["#FCD34D","#93C5FD","#86EFAC","#F9A8D4","#FDBA74","#C4B5FD","#A5F3FC","#FCA5A5","#BEF264","#FDE68A"];
const avBg=k=>AV[Math.abs(Number(k)||String(k||"").length)%AV.length];
const initials=n=>String(n||"").replace(/\./g,"").split(/\s+/).filter(Boolean).slice(0,2).map(s=>s[0].toUpperCase()).join("")||"?";
const money=v=>"$"+Number(v||0).toLocaleString("en-US",{minimumFractionDigits:2,maximumFractionDigits:2});
const plural=(n,one,many)=>`${n} ${n===1?one:many}`;
const memo={tab:"proximas",market:"all",data:{}};
try{memo.market=localStorage.getItem("cruise-resv-market")||"all";memo.tab=localStorage.getItem("cruise-resv-tab")||"proximas"}catch{}
if(!TABS.some(([t])=>t===memo.tab))memo.tab="proximas";

function dur(m){if(m<60)return`${m} min`;const h=Math.floor(m/60),mm=m%60;return mm?`${h} h ${mm} min`:`${h} h`}
function inText(r){
 if(r.kind==="completadas"||r.kind==="canceladas"||r.kind==="en_curso")return["",""];
 const t=Date.parse(r.pickup_at||"");if(!isFinite(t))return["",""];
 const m=Math.round((t-Date.now())/6e4);
 if(m<0)return[`hace ${dur(-m)}`,"hot"];
 if(m<1)return["ahora","hot"];
 const hot=!r.driver&&m<180;
 if(m<18*60)return[`en ${dur(m)}`,hot?"hot":""];
 if(r.day_delta===1)return["mañana",""];
 return[`en ${Math.max(2,r.day_delta||2)} días`,""];
}
const sig=r=>[r.kind,r.status,r.driver?r.driver.id+":"+r.driver.online:"",r.target?r.target.id:"",r.pill&&r.pill.text].join("|");
const errText=e=>{const m=e instanceof Error?e.message:String(e||"");return m||"No se pudo completar"};

function Tiles({t,setTab}){
 if(!t)return el("div",{className:"rv-tiles"},[0,1,2,3].map(i=>el("div",{key:i,className:"rv-tile",style:{height:96,boxSizing:"border-box"}})));
 const s=t.sin_conductor,c=t.con_conductor,h=t.hoy,a=t.aeropuerto;
 return el("div",{className:"rv-tiles"},
  el("button",{type:"button",className:s.n?"rv-tile hot":"rv-tile",onClick:()=>setTab("sin_conductor")},el("span",null,"Sin conductor"),el("b",{style:s.n?{color:"#FF9496"}:undefined},String(s.n)),el("small",null,s.soon?`${s.soon} ${s.soon===1?"sale":"salen"} en menos de 3 h`:"Ninguna sale en las próximas 3 h")),
  el("button",{type:"button",className:"rv-tile",onClick:()=>setTab("con_conductor")},el("span",null,"Con conductor"),el("b",null,String(c.n)),el("small",null,c.n?`${plural(c.online,"conectado","conectados")} · ${plural(c.offline,"desconectado","desconectados")}`:"Nadie tiene una reserva todavía")),
  el("button",{type:"button",className:"rv-tile",onClick:()=>setTab("proximas")},el("span",null,"Hoy"),el("b",{style:{color:"#E8C547"}},String(h.n)),el("small",null,h.next?(h.next.day==="Hoy"?`Próxima a las ${h.next.time}`:`Próxima: ${h.next.day.toLowerCase()} · ${h.next.time}`):"No hay más por delante")),
  el("button",{type:"button",className:"rv-tile",onClick:()=>setTab("proximas")},el("span",null,"Al aeropuerto"),el("b",null,String(a.n)),el("small",null,a.codes.length?a.codes.map(x=>`${x.code} ${x.n}`).join(" · "):"Ninguna al aeropuerto")));
}

function Row({r,sel,flash,onPick}){
 const[txt,cls]=inText(r);
 const d=r.driver;
 return el("button",{type:"button",className:"rv-row"+(sel?" sel":"")+(flash?" flash":""),"aria-pressed":sel,onClick:()=>onPick(r)},
  el("div",{className:"rv-when"},el("b",null,r.time),el("small",null,r.tz),txt?el("em",{className:cls},txt):null),
  el("div",{className:"rv-route"},
   el("div",{className:"rv-stop"},el("span",{className:"rv-ring g"}),el("b",{className:"rv-cut"},r.from||"—"),r.from_city?el("small",{className:"rv-cut"},r.from_city):null),
   el("div",{className:"rv-stop"},el("span",{className:"rv-ring"}),el("b",{className:"rv-cut"},r.to||"—"),r.to_city?el("small",{className:"rv-cut"},r.to_city):null),
   el("div",{className:"rv-tags"},r.tier?el("span",{className:"rv-tag"},r.tier):null,el("span",{className:"rv-tag"},money(r.price)),r.airport&&r.airport.airline?el("span",{className:"rv-tag air rv-cut"},"✈ ",r.airport.airline):null,el("span",{className:"rv-tag",style:{background:"transparent",color:"#A1A1AA",padding:0}},`#${r.id}`))),
  el("div",{className:"rv-who c-rider"},el("span",{className:"rv-av",style:{background:avBg(r.rider.id||r.id)}},initials(r.rider.name)),el("div",null,el("b",{className:"rv-cut"},r.rider.name),el("small",null,r.rider.rating?`★ ${Number(r.rider.rating).toFixed(1)}`:(r.rider.id?"Sin calificación":"Reserva web")))),
  el("div",{className:"rv-state"},
   d?el("div",{className:"rv-who"},el("span",{className:"rv-av",style:{background:avBg(d.id)}},initials(d.name)),el("div",null,el("b",{className:"rv-cut"},d.name),el("small",{className:d.online?"on":""},d.online?"● Conectado":"○ Desconectado"))):null,
   el("span",{className:`rv-pill ${r.pill.tone}`},r.pill.text),
   r.note?el("small",null,r.note):null));
}

function Detail({r,onClose,onAction,sheet}){
 const[txt]=inText(r);
 const d=r.driver,rd=r.rider;
 let sub="",hot=false;
 if(r.kind==="sin_conductor"){sub=`${txt?"Sale "+txt:"Ya es la hora"} · sin conductor`;hot=Date.parse(r.pickup_at||"")-Date.now()<3*3600e3}
 else if(r.kind==="con_conductor")sub=`${txt?"Sale "+txt:"Ya es la hora"} · con ${d?d.name:"conductor"}`;
 else sub=r.pill.text+(r.note?` · ${r.note}`:"");
 const facts=[r.airport&&r.airport.airline,r.minutes_trip?`${r.minutes_trip} min`:null,r.miles?`${r.miles} mi`:null].filter(Boolean).join(" · ");
 return el("aside",{className:sheet?"rv-box rv-detail sheet":"rv-box rv-detail","aria-label":`Reserva #${r.id}`,role:sheet?"dialog":undefined,"aria-modal":sheet?"true":undefined},
  el("div",{className:"rv-dhead"},el("span",null,`Reserva #${r.id}`),el("button",{type:"button",className:"rv-x","aria-label":"Cerrar",onClick:onClose},"✕")),
  el("div",null,el("h2",null,`${r.pickup_day} · ${r.time} ${r.tz}`.trim()),el("div",{className:hot?"rv-sub hot":"rv-sub"},sub)),
  r.pickup&&r.dropoff?el("div",{className:"rv-map","aria-hidden":"true"},el(React.Suspense,{fallback:null},el(RouteMap,{key:r.id,pickup:r.pickup,dropoff:r.dropoff}))):null,
  el("div",{className:"rv-rail"},
   el("div",null,el("span",{className:"rv-ring g"}),el("div",{style:{minWidth:0}},el("b",null,r.from||"—"),el("small",null,r.pickup_address||r.from_city||""))),
   el("div",null,el("span",{className:"rv-ring"}),el("div",{style:{minWidth:0}},el("b",null,r.to||"—"),el("small",null,facts||r.dropoff_address||r.to_city||"")))),
  el("div",{className:"rv-tags"},r.tier?el("span",{className:"rv-tag"},r.tier):null,el("span",{className:"rv-tag"},money(r.price)),rd.card?el("span",{className:"rv-tag"},rd.card):null),
  el("div",{className:"rv-steps"},el("h3",null,"QUÉ PASA CON ESTA RESERVA"),
   (r.steps||[]).map((s,i)=>el("div",{key:i,className:`rv-step ${s.state}`},el("i",null,el("b"),el("em")),el("div",null,el("b",null,s.t),el("small",null,[s.w?`${s.w.day} · ${s.w.time}`:null,s.sub].filter(Boolean).join(" · ")))))),
  el("div",{className:"rv-person"},el("span",{className:"rv-av",style:{background:avBg(rd.id||r.id)}},initials(rd.name)),
   el("div",null,el("b",{className:"rv-cut"},rd.name),el("small",null,[rd.id?(rd.female?"Pasajera":"Pasajero"):"Reserva web",rd.rating?`★ ${Number(rd.rating).toFixed(1)}`:null,rd.trips!=null?plural(rd.trips,"viaje","viajes"):null].filter(Boolean).join(" · "))),
   rd.phone?el("button",{type:"button",className:"rv-btn sm",onClick:()=>onAction("call",{name:rd.name,phone:rd.phone})},"Llamar"):null,
   rd.id?el("button",{type:"button",className:"rv-btn sm",onClick:()=>onAction("write",{id:rd.id,name:rd.name})},"Escribir"):null),
  d?el("div",{className:"rv-person"},el("span",{className:"rv-av",style:{background:avBg(d.id)}},initials(d.name)),
   el("div",null,el("b",{className:"rv-cut"},d.name),el("small",{style:d.online?{color:"#5FE3A1"}:undefined},d.online?"Conductor · conectado":"Conductor · desconectado")),
   d.phone?el("button",{type:"button",className:"rv-btn sm",onClick:()=>onAction("call",{name:d.name,phone:d.phone})},"Llamar"):null,
   el("button",{type:"button",className:"rv-btn sm",onClick:()=>onAction("write",{id:d.id,name:d.name})},"Escribir")):null,
  r.can_offer?el("button",{type:"button",className:"rv-btn gold big",onClick:()=>onAction("offer",r)},d?"Ofrecer a otro conductor":"Ofrecer a un conductor"):null,
  r.can_offer?el("button",{type:"button",className:"rv-btn big",onClick:()=>onAction("notify",r)},d?"Avisar a los demás conductores":"Avisar a los conductores cercanos"):null,
  el("div",{className:"rv-two"},
   el("button",{type:"button",className:"rv-btn",onClick:()=>onAction("open",r)},"Abrir viaje"),
   r.can_cancel?el("button",{type:"button",className:"rv-btn red",onClick:()=>onAction("cancel",r)},"Cancelar reserva"):null));
}

// "Escribir": the open support chat if there is one, else a first message (rule #86).
function WriteModal({d,onClose,navigate}){
 const[chat,setChat]=React.useState(undefined),[text,setText]=React.useState(""),[busy,setBusy]=React.useState(false),[err,setErr]=React.useState(null);
 React.useEffect(()=>{let off=false;apiGet(`/admin/users/${d.id}/support-chat`,{retry:{maxAttempts:1}}).then(r=>{if(off)return;if(r&&r.chat_id){navigate(`/soporte/chat/${r.chat_id}`);onClose()}else setChat(null)}).catch(()=>{if(!off)setChat(null)});return()=>{off=true}},[d.id]);// eslint-disable-line
 const send=async()=>{const message=text.trim();if(!message||busy)return;setBusy(true);setErr(null);
  let persona=null;try{const v=JSON.parse(localStorage.getItem("si-persona-last")||"null");if(v&&typeof v.kind==="string")persona={kind:v.kind,name:v.kind==="name"?v.name:null}}catch{}
  try{const r=await apiPost(`/admin/users/${d.id}/support-chat`,persona?{message,persona}:{message},{retry:{maxAttempts:1}});navigate(`/soporte/chat/${r.chat_id}`);onClose()}catch(e){setBusy(false);setErr(errText(e))}};
 const first=String(d.name||"").split(/\s+/)[0];
 return el(Modal,{title:`Escribirle a ${d.name}`,sub:"Le llega como un mensaje de Soporte en su app, con aviso.",onClose,width:480},
  chat===undefined?el("div",{className:"up-muted"},"Buscando su chat…"):
  el("textarea",{className:"up-text",autoFocus:true,value:text,maxLength:2000,placeholder:`Hola ${first}, `,onChange:e=>setText(e.target.value)}),
  err?el("div",{className:"up-err"},err):null,
  el("footer",null,el("button",{type:"button",className:"up-btn",onClick:onClose},"Cancelar"),el("button",{type:"button",className:"up-btn gold",disabled:chat===undefined||!text.trim()||busy,onClick:send},busy?"Enviando…":"Enviar")));
}

// "Ofrecer a un conductor": any approved driver; online and nearest first.
function OfferModal({r,onClose,toast,done}){
 const[q,setQ]=React.useState(""),[list,setList]=React.useState(null),[pick,setPick]=React.useState(null),[busy,setBusy]=React.useState(false),[err,setErr]=React.useState(null);
 React.useEffect(()=>{let off=false;const t=setTimeout(()=>{apiGet(`/admin/reservations/${r.id}/drivers`,{query:q.trim()?{q:q.trim()}:undefined,retry:{maxAttempts:1}}).then(x=>{if(!off)setList(x&&Array.isArray(x.drivers)?x.drivers:[])}).catch(e=>{if(!off){setList([]);setErr(errText(e))}})},q?300:0);return()=>{off=true;clearTimeout(t)}},[q,r.id]);
 const send=async()=>{if(!pick||busy)return;setBusy(true);setErr(null);try{const x=await apiPost(`/admin/trips/${r.id}/reassign`,{mode:"driver",driver_id:pick.id},{retry:{maxAttempts:1}});toast(x&&x.message||`Reserva ofrecida a ${pick.name}`);done();onClose()}catch(e){setBusy(false);setErr(errText(e))}};
 const cur=r.driver?r.driver.id:null;
 return el(Modal,{title:`Ofrecer la reserva #${r.id}`,sub:r.driver?`Se la quitamos a ${r.driver.name} sin avisarle. Solo el conductor que elijas la ve y es suya cuando la acepte.`:"Solo el conductor que elijas la ve y es suya cuando la acepte. Si no la toma, se ofrece a todos a su hora.",onClose,width:520},
  el("input",{className:"rv-input",type:"search",value:q,placeholder:"Buscar por nombre o teléfono","aria-label":"Buscar conductor",onChange:e=>setQ(e.target.value)}),
  list===null?el("div",{className:"up-skel"}):list.length===0?el("div",{className:"up-empty"},q?"Nadie coincide con la búsqueda.":"No hay conductores aprobados."):
  el("div",{className:"rv-pick"},list.filter(x=>x.id!==cur).map(x=>el("button",{type:"button",key:x.id,className:pick&&pick.id===x.id?"on":"",onClick:()=>setPick(x)},
   el("span",{className:x.online?"rv-dot on":"rv-dot"}),
   el("div",null,el("b",{className:"rv-cut"},x.name),el("small",{className:"rv-cut"},[x.online?(x.busy?"En un viaje":"Conectado"):"Desconectado",[x.car,x.tier].filter(Boolean).join(" · ")||null,x.miles!=null?`${x.miles} mi`:null,x.same_state?null:"otro estado"].filter(Boolean).join(" · "))),
   r.tier&&x.tier&&x.tier!==r.tier?el("span",{className:"rv-pill gray",style:{minHeight:20,fontSize:11}},x.tier):null))),
  err?el("div",{className:"up-err"},err):null,
  el("footer",null,el("button",{type:"button",className:"up-btn",onClick:onClose},"Cancelar"),el("button",{type:"button",className:"up-btn gold",disabled:!pick||busy,onClick:send},busy?"Enviando…":pick?`Ofrecer a ${pick.name}`:"Elige un conductor")));
}

function NotifyModal({r,onClose,toast,done}){
 const[busy,setBusy]=React.useState(false),[err,setErr]=React.useState(null);
 const go=async()=>{if(busy)return;setBusy(true);setErr(null);try{const x=await apiPost(`/admin/trips/${r.id}/reassign`,{mode:"nearest"},{retry:{maxAttempts:1}});toast(x&&x.message||"Listo: les avisamos a los conductores de la zona.");done();onClose()}catch(e){setBusy(false);setErr(errText(e))}};
 return el(Modal,{title:r.driver?"Avisar a los demás conductores":"Avisar a los conductores cercanos",sub:r.driver?`Se la quitamos a ${r.driver.name} sin avisarle y vuelve a la lista de reservas. Les llega un aviso a los conductores cercanos y la toma el primero que la acepte.`:"Les llega un aviso a los conductores cercanos y la toma el primero que la acepte.",onClose,width:460},
  err?el("div",{className:"up-err"},err):null,
  el("footer",null,el("button",{type:"button",className:"up-btn",onClick:onClose},"Volver"),el("button",{type:"button",className:"up-btn gold",disabled:busy,onClick:go},busy?"Avisando…":"Avisar")));
}

function CancelModal({r,onClose,toast,done}){
 const[reason,setReason]=React.useState(""),[busy,setBusy]=React.useState(false),[err,setErr]=React.useState(null);
 const go=async()=>{if(busy)return;setBusy(true);setErr(null);try{await apiPost(`/admin/trips/${r.id}/cancel`,{reason:reason.trim()||"Reserva cancelada"},{retry:{maxAttempts:1}});toast(`Reserva #${r.id} cancelada`);done(true);onClose()}catch(e){setBusy(false);setErr(errText(e))}};
 return el(Modal,{title:`Cancelar la reserva #${r.id}`,sub:`${r.rider.name} recibe "Tu viaje fue cancelado".${r.driver?` A ${r.driver.name} no le llega nada: la reserva solo desaparece de su app.`:""}`,onClose,width:480},
  el("textarea",{className:"up-text",value:reason,maxLength:300,placeholder:"Motivo (solo para el equipo, opcional)",onChange:e=>setReason(e.target.value)}),
  err?el("div",{className:"up-err"},err):null,
  el("footer",null,el("button",{type:"button",className:"up-btn",onClick:onClose},"Volver"),el("button",{type:"button",className:"up-btn",style:{color:"#FF9496",borderColor:"rgba(229,72,77,.45)"},disabled:busy,onClick:go},busy?"Cancelando…":"Cancelar reserva")));
}

function ReservationsBoard(){
 ensureCss();ensureProfileCss();
 const navigate=useNavigate();
 const pageRef=React.useRef(null);
 const[tab,setTabState]=React.useState(memo.tab);
 const[market,setMarketState]=React.useState(memo.market);
 const[q,setQ]=React.useState(""),[qLive,setQLive]=React.useState("");
 const key=`${tab}|${market}|${qLive}`;
 const[data,setData]=React.useState(memo.data[key]||null),[err,setErr]=React.useState(null);
 const[sel,setSel]=React.useState(null),[modal,setModal]=React.useState(null),[toastMsg,setToastMsg]=React.useState(null);
 const[wide,setWide]=React.useState(true),[,tick]=React.useState(0),[reload,setReload]=React.useState(0);
 const prevSig=React.useRef(new Map()),[flash,setFlash]=React.useState(new Set());
 const toastT=React.useRef(null);
 const toast=React.useCallback(m=>{setToastMsg(m);clearTimeout(toastT.current);toastT.current=setTimeout(()=>setToastMsg(null),4e3)},[]);
 const setTab=t=>{memo.tab=t;try{localStorage.setItem("cruise-resv-tab",t)}catch{}setTabState(t);setSel(null)};
 const setMarket=m=>{memo.market=m;try{localStorage.setItem("cruise-resv-market",m)}catch{}setMarketState(m);setSel(null)};
 React.useEffect(()=>{const t=setTimeout(()=>setQLive(q.trim()),350);return()=>clearTimeout(t)},[q]);
 React.useLayoutEffect(()=>{const n=pageRef.current;if(!n||typeof ResizeObserver==="undefined")return;const fit=()=>setWide(n.getBoundingClientRect().width>940);fit();const ro=new ResizeObserver(fit);ro.observe(n);return()=>ro.disconnect()},[]);
 React.useEffect(()=>{let off=false,timer=null;setData(memo.data[key]||null);prevSig.current=new Map();
  const load=async()=>{clearTimeout(timer);if(document.visibilityState!=="visible"){timer=setTimeout(load,1e4);return}
   try{const query={tab,state:market};if(qLive)query.q=qLive;
    const d=await apiGet("/admin/reservations/board",{query,retry:{maxAttempts:1},timeoutMs:9e3});if(off)return;
    if(d&&Array.isArray(d.groups)){
     const changed=new Set(),ps=prevSig.current,first=ps.size===0;
     for(const g of d.groups)for(const r of g.rows){const s=sig(r);if(!first&&ps.has(r.id)&&ps.get(r.id)!==s)changed.add(r.id);ps.set(r.id,s)}
     if(changed.size){setFlash(changed);setTimeout(()=>{if(!off)setFlash(new Set())},1700)}
     memo.data[key]=d;setData(d);setErr(null)}
   }catch(e){if(!off)setErr(errText(e))}
   if(!off)timer=setTimeout(load,1e4)};
  load();
  const vis=()=>{if(document.visibilityState==="visible")load()};document.addEventListener("visibilitychange",vis);
  return()=>{off=true;clearTimeout(timer);document.removeEventListener("visibilitychange",vis)}},[key,reload]);// eslint-disable-line
 React.useEffect(()=>{const i=setInterval(()=>tick(x=>x+1),3e4);return()=>clearInterval(i)},[]);

 const rows=data?data.groups.flatMap(g=>g.rows):[];
 let picked=sel!=null?rows.find(r=>r.id===sel)||null:null;
 if(!picked&&wide&&rows.length&&sel!=="none")picked=rows[0];
 const counts=data&&data.counts||{};
 const states=data&&data.states||{};
 const upcoming=tab!=="completadas"&&tab!=="canceladas";
 const done=closeSel=>{if(closeSel)setSel(null);setReload(x=>x+1)};
 const onAction=(k,x)=>{if(k==="open"){navigate(`/viajes/viaje/sql_${x.id}`);return}setModal({k,x})};
 const nowClock=new Date().toLocaleTimeString("en-US",{hour:"numeric",minute:"2-digit"});
 // Sheet, dialogs and the toast sit OUTSIDE the container: container-type
 // makes .rv-page the containing block of position:fixed children.
 return el("div",{style:{minWidth:0}},el("div",{className:"rv-page",ref:pageRef},
  el("div",{className:"rv-top"},
   el("div",{style:{flex:"1 1 260px",minWidth:0}},el("h1",null,"Reservas"),el("p",null,`${data?`${plural(states.all||0,"viaje programado","viajes programados")} · `:""}se actualiza en vivo · hora del lugar de recogida`)),
   el("div",{className:"rv-chips",role:"group","aria-label":"Estado"},MARKETS.map(([m,label])=>el("button",{type:"button",key:m,className:m===market?"rv-chip on":"rv-chip","aria-pressed":m===market,onClick:()=>setMarket(m)},data?`${label} ${states[m]||0}`:label))),
   el("label",{className:"rv-search"},el("svg",{width:16,height:16,viewBox:"0 0 24 24",fill:"none",stroke:"currentColor",strokeWidth:2,strokeLinecap:"round","aria-hidden":"true"},el("circle",{cx:11,cy:11,r:7}),el("path",{d:"m20 20-4-4"})),el("input",{type:"search",value:q,placeholder:"Pasajero, conductor o #viaje","aria-label":"Buscar reservas",onChange:e=>setQ(e.target.value)})),
   el("button",{type:"button",className:"rv-btn gold",onClick:()=>navigate("/viajes/nuevo")},"+ Nueva reserva")),
  el(Tiles,{t:data&&data.tiles,setTab}),
  el("div",{className:"rv-tabs"},TABS.map(([id,label])=>{const c=counts[id]||0;return el("button",{type:"button",key:id,className:"rv-tab"+(id===tab?" on":"")+(id==="sin_conductor"&&c>0?" hot":""),"aria-pressed":id===tab,onClick:()=>setTab(id)},label,el("b",null,data?String(c):"·"))})),
  el("div",{className:"rv-split"},
   el("section",{className:"rv-box rv-list","aria-label":"Lista de reservas"},
    upcoming&&rows.length?el("div",{className:"rv-nowline"},el("i"),el("span",null,`Ahora · ${nowClock}`),el("em")):null,
    data===null?(err?el("div",{className:"rv-empty"},`No se pudo cargar la lista: ${err}. Reintentando…`):[0,1,2,3].map(i=>el("div",{key:i,className:"rv-skel"}))):
    rows.length===0?el("div",{className:"rv-empty"},qLive?"Nada coincide con la búsqueda.":EMPTY[tab]):
    data.groups.map(g=>el(React.Fragment,{key:g.key},el("div",{className:"rv-day"},g.day),
     g.rows.map(r=>el(Row,{key:r.id,r,sel:!!picked&&picked.id===r.id,flash:flash.has(r.id),onPick:x=>setSel(x.id)}))))),
   picked&&wide?el(Detail,{r:picked,sheet:false,onClose:()=>setSel("none"),onAction}):null)),
  picked&&!wide?el("div",{className:"rv-shade",onClick:()=>setSel("none")}):null,
  picked&&!wide?el(Detail,{r:picked,sheet:true,onClose:()=>setSel("none"),onAction}):null,
  modal&&modal.k==="call"?el(CallModal,{name:modal.x.name,phone:modal.x.phone,onClose:()=>setModal(null),toast}):null,
  modal&&modal.k==="write"?el(WriteModal,{d:modal.x,navigate,onClose:()=>setModal(null)}):null,
  modal&&modal.k==="offer"?el(OfferModal,{r:modal.x,toast,done,onClose:()=>setModal(null)}):null,
  modal&&modal.k==="notify"?el(NotifyModal,{r:modal.x,toast,done,onClose:()=>setModal(null)}):null,
  modal&&modal.k==="cancel"?el(CancelModal,{r:modal.x,toast,done,onClose:()=>setModal(null)}):null,
  toastMsg?el("div",{className:"rv-toast",role:"status"},toastMsg):null);
}

export{ReservationsBoard};
