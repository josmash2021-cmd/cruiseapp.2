/*! guard-pin panel_support_inbox: Soporte estilo Lyft (dueño 2026-11-16, dibujo https://claude.ai/artifact/TjCu3xTTJmcDPvH4VgQV1K) - chunk escrito a mano, sin fuente React (CLAUDE.md #30). Bandeja + conversación + contexto en una sola página. Lista: GET /admin/support/inbox (otra vez con cada cambio de Firestore support_chats y cada 15 s). Mensajes: Firestore support_chats/chat_{id}/messages + GET /support/chats/{id}/messages/dispatch (los marca leídos). Responder = POST /messages/dispatch; foto = POST /attachments/dispatch; nota interna = /admin/support/chats/{id}/notes (nunca le llega a la persona). Si este chunk falla se ve el Soporte de antes. */
import{r as React,j as J,y as useNavigate}from"./vendor-react-DprhJQz-.js";
import{W as apiGet,L as apiPost,a8 as apiPatch,a6 as apiDelete,e as fsDb,al as apiBase,aY as authHeaders}from"./index-CuQT_62K.js";
import{m as onSnapshot,q as fsQuery,n as fsOrderBy,d as fsCollection,j as fsDoc}from"./vendor-firebase-BR3GpBd7.js";
import{Modal,CallModal,OfferModal,PayModal,ensureCss as ensureProfileCss}from"./user-profile-Cruise2026.js";

function el(type,props,...kids){
 const p=Object.assign({},props||{});const key=p.key;delete p.key;
 const c=kids.filter(k=>k!==undefined);
 if(c.length===1)p.children=c[0];else if(c.length>1)p.children=c;
 return c.length>1?J.jsxs(type,p,key):J.jsx(type,p,key);
}

const CSS=`
.si-wrap{container-type:inline-size;container-name:si;width:100%}
html.si-full main>.max-w-\\[1400px\\]{max-width:none;padding:0}
html.si-full .si-page{border:0;border-radius:0}
.si-page{position:relative;display:flex;height:calc(100dvh - 5.5rem);min-height:520px;background:#14141A;color:#F4F4F5;border:1px solid rgba(255,255,255,.06);border-radius:18px;overflow:hidden;font-family:inherit}
@media(min-width:768px){.si-page{height:calc(100dvh - 3rem)}}
.si-col{display:flex;flex-direction:column;min-width:0;min-height:0}
.si-inbox{width:320px;flex:none;border-right:1px solid rgba(255,255,255,.06);padding:18px 14px 0;gap:12px}
.si-ctx{width:320px;flex:none;border-left:1px solid rgba(255,255,255,.06);padding:18px 16px;gap:14px;overflow-y:auto}
.si-chat{flex:1;min-width:0}
.si-h2{margin:0;font-size:20px;font-weight:800;color:#fff}
.si-search{display:flex;align-items:center;gap:8px;height:38px;padding:0 12px;border-radius:999px;background:#1C1C24;border:1px solid rgba(255,255,255,.1);color:rgba(255,255,255,.55)}
.si-search input{flex:1;min-width:0;background:transparent;border:0;outline:0;color:#F4F4F5;font-family:inherit;font-size:13px;font-weight:500}
.si-search input::placeholder{color:rgba(255,255,255,.55)}
.si-chips{display:flex;flex-wrap:wrap;gap:6px}
.si-seg{display:flex;gap:2px;padding:4px;border-radius:999px;background:#1C1C24;border:1px solid rgba(255,255,255,.08)}
.si-seg button{flex:1 1 auto;height:32px;padding:0 8px;border:0;border-radius:999px;background:transparent;color:rgba(255,255,255,.62);font-family:inherit;font-size:12px;font-weight:700;cursor:pointer;display:inline-flex;align-items:center;justify-content:center;gap:5px;min-width:0;white-space:nowrap}
.si-seg button.on{background:#2A2A35;color:#fff}
.si-seg b{font-weight:800;color:#E8C547}
.si-chip{height:30px;padding:0 11px;border-radius:999px;border:1px solid rgba(255,255,255,.14);background:transparent;color:rgba(255,255,255,.7);font-family:inherit;font-size:12px;font-weight:600;cursor:pointer;display:inline-flex;align-items:center;gap:6px}
.si-chip.on{background:#E8C547;border-color:#E8C547;color:#14141A}
.si-chip b{font-weight:800}
.si-list{display:flex;flex-direction:column;gap:2px;overflow-y:auto;flex:1;min-height:0;padding-bottom:14px}
.si-item{display:grid;grid-template-columns:40px minmax(0,1fr) auto;gap:8px;align-items:start;padding:10px 8px;border-radius:14px;border:0;background:transparent;color:#F4F4F5;text-align:left;cursor:pointer;font-family:inherit;width:100%}
.si-item:hover{background:rgba(255,255,255,.04)}
.si-item.on{background:#1C1C24}
.si-av{position:relative;width:40px;height:40px;border-radius:50%;display:grid;place-items:center;font-weight:800;font-size:13px;background:rgba(232,197,71,.16);color:#E8C547;flex:none;overflow:hidden}
.si-av.drv{background:rgba(127,209,255,.14);color:#7FD1FF}
.si-av img{width:100%;height:100%;object-fit:cover;max-width:none}
.si-av img.face{position:absolute;height:auto;object-fit:fill}
.si-nm{font-size:14px;font-weight:700;color:#fff;display:flex;gap:6px;align-items:center;min-width:0}
.si-nm>span:first-child{overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.si-role{font-size:10px;font-weight:800;letter-spacing:.3px;padding:1px 5px;border-radius:5px;background:#2A2A35;color:rgba(255,255,255,.75);flex:none}
.si-prev{font-size:12.5px;color:rgba(255,255,255,.6);white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.si-time{font-size:11.5px;color:rgba(255,255,255,.5);white-space:nowrap;text-align:right;display:flex;flex-direction:column;gap:4px;align-items:flex-end}
.si-wait{font-size:11px;font-weight:700;color:#FF9A7A}
.si-dot{width:9px;height:9px;border-radius:50%;background:#E8C547}
.si-empty{font-size:13px;color:rgba(255,255,255,.55);padding:18px 10px;text-align:center;line-height:1.5}
.si-banner{display:flex;align-items:center;gap:8px;flex-wrap:wrap;font-size:12px;color:#FFB59E;background:rgba(255,154,122,.08);border:1px solid rgba(255,154,122,.3);border-radius:12px;padding:8px 10px}
.si-chead{display:flex;align-items:center;flex-wrap:wrap;gap:10px 12px;padding:14px 20px;border-bottom:1px solid rgba(255,255,255,.06)}
.si-ident{display:flex;align-items:center;gap:12px;flex:1 1 300px;min-width:0}
.si-narrowonly{display:none}
.si-hbtns{display:flex;gap:8px;flex-wrap:wrap;align-items:center}
.si-st{height:24px;padding:0 9px;border-radius:999px;font-size:11.5px;font-weight:700;display:inline-flex;align-items:center;white-space:nowrap}
.si-st.person{background:rgba(232,197,71,.14);color:#E8C547}
.si-st.bot{background:#2A2A35;color:rgba(255,255,255,.75)}
.si-btn{height:36px;padding:0 14px;border-radius:999px;border:1px solid rgba(255,255,255,.16);background:transparent;color:#F4F4F5;font-family:inherit;font-size:13px;font-weight:600;cursor:pointer;white-space:nowrap}
.si-btn:hover{border-color:rgba(255,255,255,.3)}
.si-btn:disabled{opacity:.45;cursor:default}
.si-btn.gold{background:#E8C547;border-color:#E8C547;color:#14141A;font-weight:700}
.si-btn.sm{height:30px;padding:0 11px;font-size:12px}
.si-btn.icon{width:36px;padding:0;display:grid;place-items:center}
.si-msgs{flex:1;overflow-y:auto;padding:18px 22px;display:flex;flex-direction:column;gap:10px;min-height:0}
.si-day{align-self:center;font-size:11.5px;font-weight:700;color:rgba(255,255,255,.55);background:#1C1C24;border-radius:999px;padding:3px 10px}
.si-sys{align-self:center;font-size:12px;color:rgba(255,255,255,.55);text-align:center;max-width:80%}
.si-row{display:flex;flex-direction:column;gap:3px;max-width:66%}
.si-row.me{align-self:flex-end;align-items:flex-end}
.si-row.them{align-self:flex-start}
.si-who{font-size:11px;color:rgba(255,255,255,.5);font-weight:600}
.si-bub{padding:10px 13px;border-radius:16px;font-size:14px;line-height:1.4;white-space:pre-wrap;overflow-wrap:anywhere}
.si-row.them .si-bub{background:#23232D;color:#F4F4F5;border-bottom-left-radius:5px}
.si-row.me .si-bub{background:#E8C547;color:#14141A;border-bottom-right-radius:5px}
.si-row.bot .si-bub{background:#1C1C24;border:1px solid rgba(255,255,255,.1);color:#F4F4F5}
.si-row.note .si-bub{background:rgba(232,197,71,.08);border:1px dashed rgba(232,197,71,.6);color:#F4E2A3}
.si-row.fail .si-bub{opacity:.6}
.si-meta{font-size:11px;color:rgba(255,255,255,.45)}
.si-meta button{border:0;background:transparent;color:#E8C547;font-family:inherit;font-size:11px;font-weight:700;cursor:pointer;padding:0;margin-left:6px}
.si-typing{font-size:12px;color:rgba(255,255,255,.55);font-style:italic}
.si-att{display:block;width:224px;max-width:100%;border-radius:12px;overflow:hidden;border:1px solid rgba(255,255,255,.1);background:#1C1C24}
.si-att img{display:block;width:100%;height:auto}
.si-att.doc{display:flex;gap:10px;align-items:center;padding:10px 12px;color:#F4F4F5;text-decoration:none;font-size:13px;font-weight:600}
.si-att.miss{padding:22px 12px;text-align:center;font-size:12px;color:rgba(255,255,255,.5)}
.si-composer{border-top:1px solid rgba(255,255,255,.06);padding:12px 20px 16px;display:flex;flex-direction:column;gap:10px}
.si-tabs{display:flex;gap:6px}
.si-tab{height:30px;padding:0 12px;border-radius:999px;border:0;background:transparent;color:rgba(255,255,255,.6);font-family:inherit;font-size:12.5px;font-weight:600;cursor:pointer}
.si-tab.on{background:#23232D;color:#fff}
.si-tab.note.on{background:rgba(232,197,71,.14);color:#E8C547}
.si-quick{display:flex;flex-wrap:wrap;gap:6px}
.si-q{height:28px;padding:0 10px;border-radius:999px;border:1px solid rgba(255,255,255,.12);background:transparent;color:rgba(255,255,255,.75);font-family:inherit;font-size:12px;font-weight:500;cursor:pointer}
.si-q:hover{border-color:rgba(255,255,255,.3)}
.si-box{display:flex;gap:10px;align-items:flex-end}
.si-box textarea{flex:1;min-width:0;min-height:44px;max-height:140px;resize:none;border-radius:14px;border:1px solid rgba(255,255,255,.12);background:#1C1C24;color:#F4F4F5;padding:11px 13px;font-family:inherit;font-size:14px;font-weight:500;box-sizing:border-box;outline:0}
.si-box textarea:focus{border-color:rgba(232,197,71,.5)}
.si-box textarea.note{border-color:rgba(232,197,71,.5);background:rgba(232,197,71,.05)}
.si-ib{width:44px;height:44px;border-radius:50%;border:1px solid rgba(255,255,255,.14);background:transparent;color:#fff;display:grid;place-items:center;cursor:pointer;flex:none}
.si-ib:disabled{opacity:.35;cursor:default}
.si-send{width:44px;height:44px;border-radius:50%;border:0;background:#E8C547;color:#14141A;display:grid;place-items:center;cursor:pointer;flex:none}
.si-send:disabled{opacity:.5;cursor:default}
.si-hint{font-size:11.5px;color:rgba(255,255,255,.5)}
.si-card{background:#1C1C24;border:1px solid rgba(255,255,255,.06);border-radius:16px;padding:14px;display:flex;flex-direction:column;gap:8px}
.si-h3{margin:0;font-size:13.5px;font-weight:700;color:#fff;display:flex;justify-content:space-between;align-items:center;gap:8px}
.si-kv{display:flex;justify-content:space-between;gap:10px;font-size:12.5px}
.si-kv span{color:rgba(255,255,255,.55);white-space:nowrap}
.si-kv b{font-weight:600;color:#fff;text-align:right;min-width:0;overflow-wrap:anywhere}
.si-kv.click{cursor:pointer;border-radius:8px}
.si-kv.click:hover b{color:#E8C547}
.si-link{border:0;background:transparent;color:#E8C547;font-family:inherit;font-size:12.5px;font-weight:600;cursor:pointer;padding:0}
.si-link:disabled{opacity:.4;cursor:default}
.si-trip{display:flex;flex-direction:column;gap:3px;font-size:12.5px;color:rgba(255,255,255,.7)}
.si-trip b{color:#fff;font-size:13px}
.si-gold{color:#E8C547 !important}
.si-acts{display:flex;flex-wrap:wrap;gap:6px}
.si-skel{border-radius:12px;background:linear-gradient(90deg,#1C1C24,#23232D,#1C1C24);background-size:200% 100%;animation:si-sk 1.2s infinite linear}
@keyframes si-sk{to{background-position:-200% 0}}
.si-center{flex:1;display:grid;place-items:center;text-align:center;padding:24px;color:rgba(255,255,255,.55);font-size:13.5px;line-height:1.6}
.si-center b{display:block;color:#fff;font-size:16px;margin-bottom:4px}
.si-toast{position:absolute;left:50%;bottom:22px;transform:translateX(-50%);background:#F4F4F5;color:#14141A;border-radius:12px;padding:10px 14px;font-family:inherit;font-size:13px;font-weight:600;box-shadow:0 10px 26px rgba(0,0,0,.45);display:flex;gap:10px;align-items:center;z-index:30;max-width:calc(100% - 32px)}
.si-toast button{border:0;background:transparent;font-family:inherit;font-size:13px;font-weight:700;cursor:pointer}
.si-menu{position:absolute;right:20px;top:58px;z-index:20;background:#1C1C24;border:1px solid rgba(255,255,255,.12);border-radius:14px;padding:6px;display:flex;flex-direction:column;min-width:220px;box-shadow:0 14px 30px rgba(0,0,0,.5)}
.si-menu button{border:0;background:transparent;color:#F4F4F5;text-align:left;padding:9px 10px;border-radius:9px;font-family:inherit;font-size:13px;font-weight:600;cursor:pointer}
.si-menu button:hover{background:rgba(255,255,255,.06)}
.si-menu button.danger{color:#FF8A80}
.si-btn.si-back{display:none}
.si-ctxbtn{display:none}
.si-pick{display:flex;flex-direction:column;gap:4px;max-height:260px;overflow-y:auto}
.si-pick button{display:flex;flex-direction:column;gap:2px;text-align:left;padding:9px 11px;border-radius:11px;border:1px solid rgba(255,255,255,.08);background:transparent;color:#F4F4F5;font-family:inherit;font-size:13.5px;font-weight:600;cursor:pointer}
.si-pick button.on{border-color:#E8C547;background:rgba(232,197,71,.08)}
.si-pick small{font-size:12px;font-weight:500;color:rgba(255,255,255,.55)}
.si-field{width:100%;box-sizing:border-box;border-radius:12px;border:1px solid rgba(255,255,255,.12);background:#1C1C24;color:#F4F4F5;padding:10px 12px;font-family:inherit;font-size:14px;font-weight:500;outline:0}
.si-field:focus{border-color:rgba(232,197,71,.5)}
textarea.si-field{min-height:96px;resize:vertical}
@container si (max-width:1180px){
 .si-ctx{position:absolute;right:0;top:0;bottom:0;z-index:15;background:#14141A;box-shadow:-18px 0 40px rgba(0,0,0,.45);display:none}
 .si-page.show-ctx .si-ctx{display:flex}
 .si-ctxbtn{display:inline-block}
}
@container si (max-width:760px){
 .si-inbox{width:auto;flex:1}
 .si-page.has-chat .si-inbox{display:none}
 .si-page:not(.has-chat) .si-chat{display:none}
 .si-btn.si-back{display:grid}
 .si-ident{flex-basis:100%}
 .si-hbtns .si-btn{height:32px;padding:0 11px;font-size:12.5px}
 .si-hbtns .si-btn.icon{width:32px;padding:0}
 .si-btn.si-wideonly{display:none}
 .si-menu button.si-narrowonly{display:block}
 .si-chead{padding:12px 14px}
 .si-msgs{padding:14px}
 .si-composer{padding:10px 14px 14px}
 .si-quick{flex-wrap:nowrap;overflow-x:auto;max-width:100%;scrollbar-width:none}
 .si-q{flex:none}
 .si-row{max-width:86%}
 .si-ctx{width:min(320px,100%)}
}
`;
function ensureCss(){if(typeof document==="undefined"||document.getElementById("si-css"))return;const s=document.createElement("style");s.id="si-css";s.textContent=CSS;document.head.appendChild(s)}

// ── Formatting (Miami time, 24 h, like the rest of the panel) ─────────────
const TZ="America/New_York";
const MES=["ene","feb","mar","abr","may","jun","jul","ago","sep","oct","nov","dic"];
const ATT="||ATT||";
function toDate(v){if(!v)return null;if(v instanceof Date)return isNaN(v.getTime())?null:v;if(typeof v.toDate==="function"){try{return v.toDate()}catch{return null}}if(typeof v==="object"&&typeof v.seconds==="number")return new Date(v.seconds*1e3);const d=new Date(v);return isNaN(d.getTime())?null:d}
function zp(d){return Object.fromEntries(new Intl.DateTimeFormat("en-US",{timeZone:TZ,year:"numeric",month:"numeric",day:"numeric",hour:"2-digit",minute:"2-digit",hourCycle:"h23"}).formatToParts(d).map(x=>[x.type,x.value]))}
function dayKey(d){const p=zp(d);return`${p.year}-${p.month}-${p.day}`}
function hm(v){const d=toDate(v);if(!d)return"";const p=zp(d);return`${p.hour==="24"?"00":p.hour}:${p.minute}`}
function dayLabel(d){const now=new Date();if(dayKey(d)===dayKey(now))return"Hoy";if(dayKey(d)===dayKey(new Date(now.getTime()-864e5)))return"Ayer";const p=zp(d);return`${+p.day} ${MES[+p.month-1]}${+p.year!==+zp(now).year?" "+p.year:""}`}
function listTime(v){const d=toDate(v);if(!d)return"";const l=dayLabel(d);return l==="Hoy"?hm(d):l}
function dateShort(v){const d=toDate(v);if(!d)return"—";const p=zp(d);return`${+p.day} ${MES[+p.month-1]}`}
function dateTime(v){const d=toDate(v);if(!d)return"—";return`${dateShort(d)} · ${hm(d)}`}
function ago(v){const d=toDate(v);if(!d)return"—";const m=Math.round((Date.now()-d.getTime())/6e4);if(m<1)return"ahora";if(m<60)return`hace ${m} min`;const h=Math.round(m/60);if(h<24)return`hace ${h} h`;return`hace ${Math.round(h/24)} d`}
function waitText(v){const d=toDate(v);if(!d)return"";const m=Math.max(0,Math.floor((Date.now()-d.getTime())/6e4));if(m<60)return`Espera ${Math.max(1,m)} min`;const h=Math.floor(m/60);return h<24?`Espera ${h} h${m%60?" "+(m%60)+" min":""}`:`Espera ${Math.floor(h/24)} d`}
const money=v=>v==null||!isFinite(Number(v))?"—":"$"+Number(v).toLocaleString("en-US",{minimumFractionDigits:2,maximumFractionDigits:2});
const phoneFmt=p=>{const d=String(p||"").replace(/\D/g,"");return d.length===11&&d[0]==="1"?`+1 (${d.slice(1,4)}) ${d.slice(4,7)}-${d.slice(7)}`:d.length===10?`(${d.slice(0,3)}) ${d.slice(3,6)}-${d.slice(6)}`:String(p||"")};
const short=a=>{const s=String(a||"").trim();return s?s.split(",")[0]:"—"};
const fold=s=>String(s||"").normalize("NFD").replace(/[̀-ͯ]/g,"").toLowerCase();
function initials(n){const p=String(n||"").trim().split(/\s+/).filter(Boolean);return((p[0]||"?")[0]+(p.length>1?p[p.length-1][0]:"")).toUpperCase()}
function firstOf(n){return String(n||"").trim().split(/\s+/)[0]||""}
function shortName(n){const p=String(n||"").trim().split(/\s+/).filter(Boolean);return p.length>1?`${p[0]} ${p[1][0]}.`:(p[0]||"")}
const TIERS={sedan:"Standard",standard:"Standard",comfort:"Comfort",premium:"Premium",vip:"VIP",suv:"SUV",suv_xl:"SUV XL",xl:"XL",electric:"Electric",black:"Black"};
const tier=v=>v?TIERS[String(v).toLowerCase()]||String(v).replace(/_/g," ").replace(/\b\w/g,c=>c.toUpperCase()):"";
const TRIP_ST={requested:"Buscando conductor",accepted:"Conductor asignado",driver_en_route:"Yendo a recoger",arrived:"En la recogida",in_trip:"En viaje",completed:"Terminado",cancelled:"Cancelado",canceled:"Cancelado",scheduled:"Reserva sin conductor",scheduled_accepted:"Reserva confirmada",scheduled_active:"Reserva por empezar"};
const tripSt=s=>TRIP_ST[s]||String(s||"—");
const LANG={es:"Español",en:"Inglés"};
function appLabel(u){const os=String(u.platform||"").toLowerCase();const dev=os==="ios"?"iPhone":os==="android"?"Android":os==="web"?"Web":(u.platform||"");return[dev,u.app_version||""].filter(Boolean).join(" · ")||"—"}
const roleLabel=r=>r==="driver"?"Conductor":"Pasajero";
const isUserRole=r=>r==="rider"||r==="driver"||r==="user";
function previewOf(c){const raw=String(c.last_message||"");const t=raw.startsWith(ATT)?(raw.split("?")[0].toLowerCase().endsWith(".pdf")?"📄 Documento":"📷 Foto"):raw.replace(/\s+/g," ");if(!t)return c.subject||"Sin mensajes";if(c.last_sender_role==="dispatch")return`Tú: ${t}`;if(c.last_sender_role==="bot")return`Robot: ${t}`;if(c.last_sender_role==="system")return t;return t}
const FILTERS=[["wait","Esperan respuesta"],["person","Con una persona"],["bot","Con el robot"],["all","Todos"],["closed","Cerrados"]];
function inFilter(c,f){const open=c.status!=="closed";if(f==="closed")return!open;if(!open)return false;if(f==="wait")return c.waiting;if(f==="person")return c.with_person;if(f==="bot")return!c.with_person;return true}
const QUICK={es:["Ya lo reviso y te escribo","¿Me pasas el número de viaje?","Te llamo ahora mismo"],en:["I'm checking and will write back","Can you send me the trip number?","I'll call you right now"]};

// Kept across route changes (/soporte ↔ /soporte/chat/:id): no flash, same filter.
const memo={inbox:null,filter:null,search:"",role:null};
const ROLES=[["all","Todos"],["rider","Pasajeros"],["driver","Conductores"]];
const inRole=(c,r)=>r==="all"||(r==="driver"?c.user_role==="driver":c.user_role!=="driver");

// ── Data ──────────────────────────────────────────────────────────────────
function useInbox(){
 const[data,setData]=React.useState(memo.inbox),[err,setErr]=React.useState(null);
 const busy=React.useRef(false),again=React.useRef(false);
 const load=React.useCallback(async()=>{if(busy.current){again.current=true;return}busy.current=true;try{do{again.current=false;const d=await apiGet("/admin/support/inbox",{retry:{maxAttempts:1}});if(d&&Array.isArray(d.chats)){memo.inbox=d;setData(d);setErr(null)}}while(again.current)}catch(e){setErr(e instanceof Error?e.message:String(e))}finally{busy.current=false}},[]);
 React.useEffect(()=>{load();let t=null;const unsub=onSnapshot(fsCollection(fsDb,"support_chats"),()=>{clearTimeout(t);t=setTimeout(load,600)},()=>{});const iv=setInterval(()=>{if(document.visibilityState==="visible")load()},15e3);return()=>{clearTimeout(t);clearInterval(iv);try{unsub()}catch{}}},[load]);
 return{data,err,reload:load};
}
function useTick(ms){const[,s]=React.useState(0);React.useEffect(()=>{const i=setInterval(()=>s(x=>x+1),ms);return()=>clearInterval(i)},[ms])}
function useBotStatus(){
 const[st,setSt]=React.useState(null);
 const load=React.useCallback(()=>apiGet("/support/bot-status",{retry:{maxAttempts:1}}).then(setSt).catch(()=>{}),[]);
 React.useEffect(()=>{load();const i=setInterval(load,6e4);return()=>clearInterval(i)},[load]);
 return[st,load];
}
function fsMsg(d){const role=String(d.senderRole||"");return{id:Number(d.msgId),role,name:String(d.senderName||""),text:String(d.message||""),read:d.isRead===true,at:toDate(d.createdAt)}}
function restMsg(m){return{id:Number(m.id),role:String(m.sender_role||""),name:String(m.sender_name||""),text:String(m.message||""),read:m.is_read===true,at:toDate(m.created_at)}}
function useMessages(chatId){
 const[fs,setFs]=React.useState(null),[rest,setRest]=React.useState(null),[echo,setEcho]=React.useState([]);
 const seen=React.useRef(new Set()),markT=React.useRef(null);
 const markRead=React.useCallback(()=>{clearTimeout(markT.current);markT.current=setTimeout(()=>{apiGet(`/support/chats/${chatId}/messages/dispatch`,{retry:{maxAttempts:1}}).then(d=>{if(Array.isArray(d))setRest(d.map(restMsg))}).catch(()=>{})},900)},[chatId]);
 React.useEffect(()=>{setFs(null);setRest(null);setEcho([]);seen.current=new Set();let off=false;
  apiGet(`/support/chats/${chatId}/messages/dispatch`,{retry:{maxAttempts:1}}).then(d=>{if(!off&&Array.isArray(d))setRest(d.map(restMsg))}).catch(()=>{if(!off)setRest([])});
  const unsub=onSnapshot(fsQuery(fsCollection(fsDb,"support_chats",`chat_${chatId}`,"messages"),fsOrderBy("createdAt","asc")),s=>{if(off)return;const list=s.docs.map(x=>fsMsg(x.data())).filter(m=>Number.isFinite(m.id));
   const fresh=list.some(m=>isUserRole(m.role)&&!seen.current.has(m.id));const first=seen.current.size===0;list.forEach(m=>seen.current.add(m.id));setFs(list);if(fresh&&!first&&document.visibilityState==="visible")markRead()},()=>{if(!off)setFs([])});
  return()=>{off=true;clearTimeout(markT.current);try{unsub()}catch{}}},[chatId,markRead]);
 const messages=React.useMemo(()=>{const by=new Map();for(const m of rest||[])by.set(m.id,m);for(const m of fs||[]){const o=by.get(m.id);by.set(m.id,o?{...o,...m,at:m.at||o.at,read:m.read||o.read}:m)}const ids=new Set(by.keys());const list=[...by.values(),...echo.filter(e=>!(e.realId&&ids.has(e.realId)))];list.sort((a,b)=>((a.at&&a.at.getTime())||Date.now())-((b.at&&b.at.getTime())||Date.now()));return list},[fs,rest,echo]);
 return{messages,loading:fs===null&&rest===null,setEcho};
}
function useContext(chatId){
 const[ctx,setCtx]=React.useState(null),[tick,setTick]=React.useState(0);
 React.useEffect(()=>{let off=false;setCtx(null);apiGet(`/admin/support/chats/${chatId}/context`,{retry:{maxAttempts:1}}).then(d=>{if(!off)setCtx(d)}).catch(()=>{if(!off)setCtx({failed:true,notes:[],past_chats:[],recent:[]})});return()=>{off=true}},[chatId,tick]);
 return[ctx,setCtx,()=>setTick(t=>t+1)];
}
function useUserTyping(chatId){
 const[st,setSt]=React.useState(null);useTick(2e3);
 React.useEffect(()=>{setSt(null);const unsub=onSnapshot(fsDoc(fsDb,"support_chats",String(chatId)),s=>{const d=s.exists()?s.data():null;setSt(d?{on:d.user_typing===true,at:toDate(d.typing_updated_at)}:null)},()=>{});return()=>{try{unsub()}catch{}}},[chatId]);
 return!!(st&&st.on&&st.at&&Date.now()-st.at.getTime()<1e4);
}
const signed=new Map();
function signedUrl(chatId,key){const k=`${chatId}:${key}`;if(!signed.has(k))signed.set(k,apiGet(`/support/chats/${chatId}/attachment-url?key=${encodeURIComponent(key)}`,{retry:{maxAttempts:1}}).then(d=>d&&d.signed_url||null).catch(()=>null));return signed.get(k)}
async function uploadAttachment(chatId,file){const h=await authHeaders();delete h["Content-Type"];const fd=new FormData();fd.append("file",file);const res=await fetch(`${apiBase}/support/chats/${chatId}/attachments/dispatch`,{credentials:"same-origin",method:"POST",headers:h,body:fd});const txt=await res.text();let body=null;try{body=txt?JSON.parse(txt):null}catch{}if(res.status>=200&&res.status<300)return body;throw new Error(body&&typeof body.detail==="string"?body.detail:`No se pudo subir (${res.status})`)}

// ── Small pieces ──────────────────────────────────────────────────────────
// Where to put the photo so its face fills the circle (face about 45 % of
// the circle, a little above the middle). face = {cx, cy, s, ar} from the
// server (services/photo_face.py, YuNet); without it the photo stays centred.
function faceBox(f){if(!f||!(f.s>0)||!(f.ar>0))return null;let k=1/(f.s*2.2);k=Math.min(8,Math.max(k,1,1/f.ar));const H=k*f.ar;const left=Math.min(0,Math.max(1-k,0.5-f.cx*k)),top=Math.min(0,Math.max(1-H,0.46-f.cy*H));return{width:`${k*100}%`,left:`${left*100}%`,top:`${top*100}%`}}
function Avatar({name,role,photo,face,size}){const[bad,setBad]=React.useState(false);React.useEffect(()=>setBad(false),[photo]);const st=size?{width:size,height:size}:undefined;const box=faceBox(face);return el("span",{className:role==="driver"?"si-av drv":"si-av",style:st},photo&&!bad?el("img",{src:photo,alt:"",className:box?"face":undefined,style:box||undefined,onError:()=>setBad(true)}):initials(name))}
const Ico={
 search:()=>el("svg",{width:15,height:15,viewBox:"0 0 24 24",fill:"none",stroke:"currentColor",strokeWidth:2,strokeLinecap:"round","aria-hidden":"true"},el("path",{d:"M11 18a7 7 0 1 0 0-14 7 7 0 0 0 0 14zM20 20l-4-4"})),
 clip:()=>el("svg",{width:18,height:18,viewBox:"0 0 24 24",fill:"none",stroke:"currentColor",strokeWidth:2,strokeLinecap:"round",strokeLinejoin:"round","aria-hidden":"true"},el("path",{d:"M21 12.5 12.6 21a6 6 0 0 1-8.5-8.5l8.5-8.5a4 4 0 0 1 5.7 5.7l-8.5 8.5a2 2 0 0 1-2.8-2.8l7.8-7.8"})),
 send:()=>el("svg",{width:18,height:18,viewBox:"0 0 24 24",fill:"none",stroke:"currentColor",strokeWidth:2.2,strokeLinecap:"round",strokeLinejoin:"round","aria-hidden":"true"},el("path",{d:"M21 3 10 14M21 3l-7 18-4-7-7-4z"})),
 back:()=>el("svg",{width:18,height:18,viewBox:"0 0 24 24",fill:"none",stroke:"currentColor",strokeWidth:2.2,strokeLinecap:"round",strokeLinejoin:"round","aria-hidden":"true"},el("path",{d:"M15 18l-6-6 6-6"})),
 more:()=>el("svg",{width:18,height:18,viewBox:"0 0 24 24",fill:"currentColor","aria-hidden":"true"},el("circle",{cx:5,cy:12,r:1.8}),el("circle",{cx:12,cy:12,r:1.8}),el("circle",{cx:19,cy:12,r:1.8})),
 doc:()=>el("svg",{width:22,height:22,viewBox:"0 0 24 24",fill:"none",stroke:"#E8C547",strokeWidth:1.8,strokeLinecap:"round",strokeLinejoin:"round","aria-hidden":"true"},el("path",{d:"M14 3H7a2 2 0 0 0-2 2v14a2 2 0 0 0 2 2h10a2 2 0 0 0 2-2V8zM14 3v5h5"})),
};
function Attachment({chatId,raw}){
 const key=raw.slice(ATT.length).trim();const[url,setUrl]=React.useState(undefined);
 React.useEffect(()=>{if(!key){setUrl(null);return}let off=false;signedUrl(chatId,key).then(u=>{if(!off)setUrl(u)});return()=>{off=true}},[chatId,key]);
 if(url===undefined)return el("div",{className:"si-att si-skel",style:{height:120}});
 if(!url)return el("div",{className:"si-att miss"},"Adjunto no disponible");
 if(key.split("?")[0].toLowerCase().endsWith(".pdf"))return el("a",{className:"si-att doc",href:url,target:"_blank",rel:"noreferrer"},el(Ico.doc),"Documento PDF");
 return el("a",{className:"si-att",href:url,target:"_blank",rel:"noreferrer"},el("img",{src:url,alt:"Foto adjunta",loading:"lazy"}));
}

// ── Inbox ─────────────────────────────────────────────────────────────────
function Inbox({data,err,chatId,filter,setFilter,role,setRole,search,setSearch,onPick,onWrite,onDeleteClosed,bot,onBot}){
 useTick(3e4);
 const all=data?data.chats:[];
 const roleCount=r=>all.filter(c=>c.status!=="closed"&&inRole(c,r)).length;
 const chats=all.filter(c=>inRole(c,role));
 const[tripUsers,setTripUsers]=React.useState(null);
 React.useEffect(()=>{const q=search.trim().replace(/^#/,"");if(!/^\d{2,9}$/.test(q)){setTripUsers(null);return}let off=false;const t=setTimeout(()=>{apiGet("/admin/home/search",{query:{q},retry:{maxAttempts:1}}).then(d=>{if(off)return;const ids=new Set();for(const r of(d&&d.results)||[])if(r.kind==="trip"){if(r.rider_id)ids.add(r.rider_id);if(r.driver_id)ids.add(r.driver_id)}setTripUsers(ids)}).catch(()=>{})},350);return()=>{off=true;clearTimeout(t)}},[search]);
 const match=c=>{const q=search.trim();if(!q)return true;const n=q.replace(/^#/,"");if(/^\d+$/.test(n)){if(String(c.id)===n||String(c.user_id)===n)return true;if(n.length>=3&&String(c.user_phone||"").replace(/\D/g,"").includes(n))return true;return!!(tripUsers&&tripUsers.has(c.user_id))}return fold(c.user_name).includes(fold(q))};
 const counts=Object.fromEntries(FILTERS.map(([f])=>[f,chats.filter(c=>inFilter(c,f)).length]));
 const list=chats.filter(c=>inFilter(c,filter)&&match(c));
 if(filter==="wait")list.sort((a,b)=>(toDate(a.waiting_since)||0)-(toDate(b.waiting_since)||0));
 else list.sort((a,b)=>((toDate(b.last_message_at||b.updated_at)||0)-(toDate(a.last_message_at||a.updated_at)||0)));
 const botWaiting=bot&&Array.isArray(bot.waiting_on_answer)?bot.waiting_on_answer.length:0;
 return el("div",{className:"si-col si-inbox"},
  el("div",{style:{display:"flex",justifyContent:"space-between",alignItems:"center"}},el("h1",{className:"si-h2"},"Soporte"),el("button",{type:"button",className:"si-btn",onClick:onWrite},"+ Escribir")),
  el("div",{className:"si-seg",role:"tablist","aria-label":"Pasajeros o conductores"},ROLES.map(([r,label])=>el("button",{type:"button",key:r,role:"tab","aria-selected":r===role,className:r===role?"on":"",onClick:()=>setRole(r)},label,el("b",null,String(roleCount(r)))))),
  el("label",{className:"si-search"},el(Ico.search),el("input",{type:"search",value:search,placeholder:"Buscar nombre, teléfono o viaje #","aria-label":"Buscar",onChange:e=>setSearch(e.target.value)})),
  el("div",{className:"si-chips"},FILTERS.map(([f,label])=>el("button",{type:"button",key:f,className:f===filter?"si-chip on":"si-chip",onClick:()=>setFilter(f)},label,el("b",null,String(counts[f]||0))))),
  botWaiting>0?el("div",{className:"si-banner"},`El robot no ha contestado ${botWaiting} chat${botWaiting===1?"":"s"}.`,el("button",{type:"button",className:"si-btn sm",onClick:onBot},"Reactivar robot")):null,
  el("div",{className:"si-list"},
   data===null?(err?el("div",{className:"si-empty"},`No se pudo cargar la bandeja: ${err}`):[0,1,2,3].map(i=>el("div",{key:i,className:"si-skel",style:{height:58,margin:"2px 0"}}))):
   list.length===0?el("div",{className:"si-empty"},search.trim()?"Nada coincide con la búsqueda.":filter==="wait"?(role==="rider"?"Ningún pasajero espera respuesta ahora.":role==="driver"?"Ningún conductor espera respuesta ahora.":"Nadie espera respuesta ahora."):filter==="closed"?"No hay chats cerrados en los últimos 30 días.":"No hay chats aquí."):
   list.map(c=>el("button",{type:"button",key:c.id,className:c.id===chatId?"si-item on":"si-item",onClick:()=>onPick(c.id)},
    el(Avatar,{name:c.user_name,role:c.user_role,photo:c.user_photo,face:c.user_photo_face}),
    el("span",{style:{display:"flex",flexDirection:"column",gap:3,minWidth:0}},
     el("span",{className:"si-nm"},el("span",null,c.user_name),el("span",{className:"si-role"},roleLabel(c.user_role))),
     el("span",{className:"si-prev"},previewOf(c))),
    el("span",{className:"si-time"},listTime(c.last_message_at||c.updated_at),
     c.waiting&&c.waiting_since?el("span",{className:"si-wait"},waitText(c.waiting_since)):null,
     c.unread>0&&c.id!==chatId?el("span",{className:"si-dot","aria-label":`${c.unread} sin leer`}):null))),
   filter==="closed"&&counts.closed>0?el("div",{style:{padding:"10px 4px"}},el("button",{type:"button",className:"si-link",onClick:onDeleteClosed},"Borrar todos los chats cerrados")):null));
}

// ── Conversation ──────────────────────────────────────────────────────────
function Conversation({chatId,row,ctx,setCtx,reloadCtx,navigate,toast,onClosed,onBack,onToggleCtx,openModal,reloadInbox}){
 const{messages,loading,setEcho}=useMessages(chatId);
 const typing=useUserTyping(chatId);
 const[mode,setMode]=React.useState("reply"),[draft,setDraft]=React.useState(""),[sending,setSending]=React.useState(false),[menu,setMenu]=React.useState(false),[closing,setClosing]=React.useState(false);
 const endRef=React.useRef(null),fileRef=React.useRef(null),taRef=React.useRef(null),typT=React.useRef(null),typAt=React.useRef(0);
 const person=ctx&&ctx.person;
 const name=(row&&row.user_name)||(person?`${person.first_name||""} ${person.last_name||""}`.trim():"")||"—";
 const role=(row&&row.user_role)||(person&&person.role)||"rider";
 const userId=(row&&row.user_id)||(person&&person.id)||null;
 const status=(row&&row.status)||(ctx&&ctx.chat&&ctx.chat.status)||"open";
 const closed=status==="closed";
 const withPerson=row?row.with_person:!!(ctx&&ctx.chat&&ctx.chat.with_person);
 const locale=String((ctx&&ctx.chat&&ctx.chat.locale)||(person&&person.locale)||"es").toLowerCase().startsWith("en")?"en":"es";
 const first=firstOf(name);
 React.useEffect(()=>{setMode("reply");setDraft("");setMenu(false)},[chatId]);
 const notes=(ctx&&Array.isArray(ctx.notes)?ctx.notes:[]).map(n=>({id:`n${n.id||n.at}`,role:"note",text:String(n.text||""),at:toDate(n.at)}));
 const items=React.useMemo(()=>{const all=[...messages,...notes];all.sort((a,b)=>((a.at&&a.at.getTime())||Date.now())-((b.at&&b.at.getTime())||Date.now()));return all},[messages,ctx]);// eslint-disable-line
 const lastKey=items.length?`${items[items.length-1].id}:${items.length}`:"";
 React.useEffect(()=>{const e=endRef.current;if(e)e.scrollIntoView({block:"end"})},[lastKey,typing]);
 const stopTyping=()=>{clearTimeout(typT.current);typT.current=null;if(typAt.current){typAt.current=0;apiPost(`/support/chats/${chatId}/dispatch-typing`,{typing:false},{retry:{maxAttempts:1}}).catch(()=>{})}};
 React.useEffect(()=>()=>stopTyping(),[chatId]);// eslint-disable-line
 const onType=v=>{setDraft(v);const ta=taRef.current;if(ta){ta.style.height="auto";ta.style.height=Math.min(140,ta.scrollHeight)+"px"}if(mode!=="reply"||closed)return;if(!v.trim()){stopTyping();return}const now=Date.now();if(now-typAt.current>4e3){typAt.current=now;apiPost(`/support/chats/${chatId}/dispatch-typing`,{typing:true},{retry:{maxAttempts:1}}).catch(()=>{})}clearTimeout(typT.current);typT.current=setTimeout(stopTyping,3e3)};
 const resetBox=()=>{setDraft("");const ta=taRef.current;if(ta)ta.style.height="auto"};
 const sendText=async(text,tempId)=>{const id=tempId||`e${Date.now()}`;setEcho(es=>[...es.filter(e=>e.id!==id),{id,role:"dispatch",text,at:new Date(),pending:true}]);try{const m=await apiPost(`/support/chats/${chatId}/messages/dispatch`,{message:text},{retry:{maxAttempts:1}});setEcho(es=>es.map(e=>e.id===id?{...e,pending:false,realId:Number(m&&m.id),read:false}:e));reloadInbox()}catch(e){setEcho(es=>es.map(x=>x.id===id?{...x,pending:false,failed:true}:x))}};
 const send=async()=>{const text=draft.trim();if(!text||sending)return;
  if(mode==="note"){setSending(true);try{const d=await apiPost(`/admin/support/chats/${chatId}/notes`,{text},{retry:{maxAttempts:1}});setCtx(c=>c?{...c,notes:d.notes||[]}:c);resetBox()}catch(e){toast(`No se guardó la nota: ${e instanceof Error?e.message:e}`)}setSending(false);return}
  stopTyping();
  if(closed){if(!userId)return;setSending(true);try{const r=await apiPost(`/admin/users/${userId}/support-chat`,{message:text},{retry:{maxAttempts:1}});resetBox();navigate(`/soporte/chat/${r.chat_id}`)}catch(e){toast(`No se envió: ${e instanceof Error?e.message:e}`)}setSending(false);return}
  resetBox();sendText(text)};
 const onKey=e=>{if(e.key==="Enter"&&!e.shiftKey&&!e.nativeEvent.isComposing){e.preventDefault();send()}};
 const onFile=async e=>{const f=e.target.files&&e.target.files[0];e.target.value="";if(!f)return;const id=`f${Date.now()}`;setEcho(es=>[...es,{id,role:"dispatch",text:`📎 ${f.name}`,at:new Date(),pending:true,upload:true}]);try{const m=await uploadAttachment(chatId,f);setEcho(es=>es.map(x=>x.id===id?{...x,pending:false,realId:Number(m&&m.id),text:m&&m.message||x.text}:x));reloadInbox()}catch(err){setEcho(es=>es.filter(x=>x.id!==id));toast(err instanceof Error?err.message:String(err))}};
 const close=async()=>{if(closing)return;setClosing(true);try{await apiPatch(`/support/chats/${chatId}/close`,undefined,{retry:{maxAttempts:1}});toast(`Chat cerrado. Si ${first||"la persona"} escribe otra vez, se abre uno nuevo.`);onClosed()}catch(e){toast(`No se pudo cerrar: ${e instanceof Error?e.message:e}`)}setClosing(false)};
 const connect=async kind=>{setMenu(false);try{await apiPost(`/support/chats/${chatId}/${kind==="agent"?"connect-agent":"connect-supervisor"}`,{},{retry:{maxAttempts:1}});toast(kind==="agent"?"Entraste al chat como agente.":"Entraste al chat como supervisor.");reloadInbox();reloadCtx()}catch(e){toast(`No se pudo: ${e instanceof Error?e.message:e}`)}};
 const sub=[roleLabel(role),userId?`#${userId}`:null,person&&person.place].filter(Boolean).join(" · ");
 const stCls=closed?"si-st bot":withPerson?"si-st person":"si-st bot";
 const stText=closed?"Cerrado":withPerson?"Con una persona":"Con el robot";
 let lastDay=null;
 const rows=[];
 for(const m of items){
  const d=m.at||new Date();const k=dayKey(d);if(k!==lastDay){lastDay=k;rows.push(el("span",{className:"si-day",key:`d${k}`},dayLabel(d)))}
  if(m.role==="system"){rows.push(el("span",{className:"si-sys",key:`m${m.id}`},`${m.text} · ${hm(d)}`));continue}
  const att=m.text.startsWith(ATT);
  const body=att?el(Attachment,{chatId,raw:m.text}):el("div",{className:"si-bub"},m.text);
  if(m.role==="note"){rows.push(el("div",{className:"si-row me note",key:m.id},el("span",{className:"si-who"},"Nota interna"),el("div",{className:"si-bub"},m.text),el("span",{className:"si-meta"},`Solo el equipo la ve · ${hm(d)}`)));continue}
  if(m.role==="dispatch"){const meta=m.failed?el("span",{className:"si-meta"},"No se envió",el("button",{type:"button",onClick:()=>sendText(m.text,m.id)},"Reintentar")):el("span",{className:"si-meta"},m.pending?(m.upload?"Subiendo…":"Enviando…"):`${hm(d)} · ${m.read?"Visto":"Enviado"}`);
   rows.push(el("div",{className:m.failed?"si-row me fail":"si-row me",key:`m${m.id}`},el("span",{className:"si-who"},"Tú · Soporte"),m.upload&&m.pending?el("div",{className:"si-bub"},m.text):body,meta));continue}
  if(m.role==="bot"){rows.push(el("div",{className:"si-row them bot",key:`m${m.id}`},el("span",{className:"si-who"},"Robot"),body,el("span",{className:"si-meta"},hm(d))));continue}
  rows.push(el("div",{className:"si-row them",key:`m${m.id}`},el("span",{className:"si-who"},first||m.name||"Usuario"),body,el("span",{className:"si-meta"},hm(d))));
 }
 const quick=QUICK[locale];
 const hint=mode==="note"?"Solo la ve el equipo de soporte.":closed?`Este chat está cerrado: lo que escribas le abre uno nuevo a ${first||"la persona"}.`:`Le llega como notificación y en la burbuja de soporte de su app.${locale==="en"?" Su app está en inglés: escríbele en inglés.":""}`;
 return el("div",{className:"si-col si-chat",style:{position:"relative"}},
  el("div",{className:"si-chead"},
   el("div",{className:"si-ident"},
    el("button",{type:"button",className:"si-btn icon si-back","aria-label":"Volver a la bandeja",onClick:onBack},el(Ico.back)),
    el(Avatar,{name,role,photo:(row&&row.user_photo)||(person&&person.photo_url),face:(row&&row.user_photo_face)||(person&&person.photo_face)}),
    el("div",{style:{display:"flex",flexDirection:"column",gap:2,flex:1,minWidth:0}},
     el("div",{style:{display:"flex",gap:8,alignItems:"center",minWidth:0}},el("b",{style:{fontSize:16,overflow:"hidden",textOverflow:"ellipsis",whiteSpace:"nowrap",minWidth:0}},name),el("span",{className:stCls},stText)),
     el("span",{style:{fontSize:12.5,color:"rgba(255,255,255,.55)",overflow:"hidden",textOverflow:"ellipsis",whiteSpace:"nowrap"}},sub))),
   el("div",{className:"si-hbtns"},
   el("button",{type:"button",className:"si-btn",onClick:()=>openModal("call")},"Llamar"),
   el("button",{type:"button",className:"si-btn",disabled:!userId,onClick:()=>navigate(`/personas/${role==="driver"?"driver":"rider"}/sql_${userId}`)},"Ver ficha"),
   closed?null:el("button",{type:"button",className:"si-btn si-wideonly",disabled:closing,onClick:close},closing?"Cerrando…":"Cerrar chat"),
   el("button",{type:"button",className:"si-btn si-ctxbtn",onClick:onToggleCtx},"Contexto"),
   el("button",{type:"button",className:"si-btn icon","aria-label":"Más opciones",onClick:()=>setMenu(v=>!v)},el(Ico.more)))),
  menu?el("div",{className:"si-menu",onMouseLeave:()=>setMenu(false)},
   !closed?el("button",{type:"button",className:"si-narrowonly",onClick:()=>{setMenu(false);close()}},"Cerrar chat"):null,
   !closed&&!withPerson?el("button",{type:"button",onClick:()=>connect("agent")},"Entrar como agente"):null,
   !closed?el("button",{type:"button",onClick:()=>connect("supervisor")},"Entrar como supervisor"):null,
   el("button",{type:"button",className:"danger",onClick:()=>{setMenu(false);openModal("delete")}},"Eliminar chat")):null,
  el("div",{className:"si-msgs"},
   loading?[0,1,2].map(i=>el("div",{key:i,className:"si-skel",style:{height:44,width:i===1?"40%":"55%",alignSelf:i===1?"flex-end":"flex-start"}})):
   rows.length===0?el("div",{className:"si-center"},el("div",null,el("b",null,"Sin mensajes todavía"),"Escríbele abajo: le llega con aviso.")):rows,
   typing&&!closed?el("span",{className:"si-typing"},`${first||"La persona"} está escribiendo…`):null,
   el("div",{ref:endRef})),
  el("div",{className:"si-composer"},
   el("div",{style:{display:"flex",justifyContent:"space-between",alignItems:"center",gap:10,flexWrap:"wrap"}},
    el("div",{className:"si-tabs"},
     el("button",{type:"button",className:mode==="reply"?"si-tab on":"si-tab",onClick:()=>setMode("reply")},"Responder"),
     el("button",{type:"button",className:mode==="note"?"si-tab note on":"si-tab note",onClick:()=>{stopTyping();setMode("note")}},"Nota interna")),
    mode==="reply"?el("div",{className:"si-quick"},quick.map(q=>el("button",{type:"button",key:q,className:"si-q",onClick:()=>{onType(q);const ta=taRef.current;if(ta)ta.focus()}},q))):null),
   el("div",{className:"si-box"},
    el("button",{type:"button",className:"si-ib","aria-label":"Adjuntar foto o PDF",title:"Adjuntar foto o PDF",disabled:mode!=="reply"||closed,onClick:()=>fileRef.current&&fileRef.current.click()},el(Ico.clip)),
    el("input",{ref:fileRef,type:"file",accept:"image/*,application/pdf",style:{display:"none"},onChange:onFile}),
    el("textarea",{ref:taRef,rows:1,className:mode==="note"?"note":"","aria-label":mode==="note"?"Nota interna":"Mensaje",placeholder:mode==="note"?`Nota para el equipo (${first||"la persona"} no la ve)…`:`Escribe a ${first||"la persona"}…`,value:draft,maxLength:2000,onChange:e=>onType(e.target.value),onKeyDown:onKey}),
    el("button",{type:"button",className:"si-send","aria-label":mode==="note"?"Guardar nota":"Enviar",disabled:!draft.trim()||sending,onClick:send},el(Ico.send))),
   el("span",{className:"si-hint"},hint)));
}

// ── Context ───────────────────────────────────────────────────────────────
function ContextPanel({ctx,row,navigate,openModal}){
 if(!ctx)return el("div",{className:"si-col si-ctx"},[0,1,2].map(i=>el("div",{key:i,className:"si-skel",style:{height:i?110:170}})));
 const p=ctx.person;
 if(!p)return el("div",{className:"si-col si-ctx"},el("div",{className:"si-card"},el("div",{className:"si-empty"},ctx.failed?"No se pudo cargar el contexto.":"Esta cuenta ya no existe.")));
 const name=`${p.first_name||""} ${p.last_name||""}`.trim()||(row&&row.user_name)||"—";
 const isDriver=p.role==="driver";
 const cur=ctx.current,next=ctx.next,recent=ctx.recent||[];
 const veh=p.vehicle||{};
 const roleLong=[roleLabel(p.role),`#${p.id}`,isDriver?tier(veh.vehicle_type):null].filter(Boolean).join(" · ");
 const nowText=cur?`${tripSt(cur.status)} · viaje #${cur.id}`:isDriver?(p.is_online?"En línea · sin viaje":`Desconectado · ${ago(p.last_active_at)}`):next?`Reserva ${dateTime(next.scheduled_at)}`:"Sin viaje";
 const openTrip=id=>navigate(`/viajes/viaje/sql_${id}`);
 const other=t=>isDriver?(t.rider_name?`Pasajero: ${shortName(t.rider_name)}`:""):(t.driver_name?`Conductor: ${shortName(t.driver_name)}`:"Sin conductor todavía");
 let tripCard;
 if(cur)tripCard=[`Viaje #${cur.id} · ${tripSt(cur.status)}`,`${short(cur.pickup_address)} → ${short(cur.dropoff_address)}`,other(cur),cur.id];
 else if(next)tripCard=[`Reserva #${next.id} · ${dateTime(next.scheduled_at)}`,`${short(next.pickup_address)} → ${short(next.dropoff_address)}`,other(next),next.id];
 else if(recent[0])tripCard=["Sin viaje en curso",`Último: ${dateTime(recent[0].completed_at||recent[0].updated_at||recent[0].created_at)}`,`${short(recent[0].pickup_address)} → ${short(recent[0].dropoff_address)}`,recent[0].id];
 else tripCard=["Sin viaje en curso","Todavía no tiene viajes.","",null];
 const pending=Number(ctx.stats&&ctx.stats.pending_balance)||0;
 const actions=isDriver?
  (cur?[["Abrir viaje",()=>openTrip(cur.id)],["Ver en el mapa",()=>navigate("/mapa")],["Pagar ahora",()=>openModal("pay"),!(pending>0)]]:
   [["Ofrecer viaje",()=>openModal("offer")],["Pagar ahora",()=>openModal("pay"),!(pending>0)],p.is_online?["Ver en el mapa",()=>navigate("/mapa")]:null]):
  [["Crear viaje",()=>navigate("/viajes/nuevo",{state:{bookingPrefill:{rider:{id:p.id,first_name:p.first_name||"",last_name:p.last_name||"",phone:p.phone||"",photo_url:p.photo_url||null},pickup:null,dropoff:null}}})],next?["Ver reserva",()=>openTrip(next.id)]:null,["Llamar",()=>openModal("call")]];
 const past=ctx.past_chats||[];
 const PAST_ST={open:"Abierto",closed:"Cerrado"};
 return el("div",{className:"si-col si-ctx"},
  el("div",{className:"si-card"},
   el("div",{style:{display:"flex",gap:10,alignItems:"center"}},el(Avatar,{name,role:p.role,photo:p.photo_url,face:p.photo_face}),el("div",{style:{display:"flex",flexDirection:"column",minWidth:0}},el("b",{style:{fontSize:15}},name),el("span",{style:{fontSize:12,color:"rgba(255,255,255,.55)"}},roleLong))),
   el("div",{className:"si-kv"},el("span",null,"Calificación"),el("b",null,p.rating!=null?`★ ${Number(p.rating).toFixed(1)}`:"—")),
   el("div",{className:"si-kv"},el("span",null,"Teléfono"),el("b",null,p.phone?phoneFmt(p.phone):"—")),
   el("div",{className:"si-kv"},el("span",null,"App"),el("b",null,appLabel(p))),
   el("div",{className:"si-kv"},el("span",null,"Idioma"),el("b",null,LANG[String(p.locale||"").slice(0,2).toLowerCase()]||(p.locale||"—"))),
   el("div",{className:"si-kv"},el("span",null,"Ahora"),el("b",{className:"si-gold"},nowText))),
  el("div",{className:"si-card"},
   el("h3",{className:"si-h3"},cur?"Viaje actual":next?"Próxima reserva":"Viaje actual",el("button",{type:"button",className:"si-link",disabled:!tripCard[3],onClick:()=>tripCard[3]&&openTrip(tripCard[3])},"Abrir")),
   el("div",{className:"si-trip"},el("b",null,tripCard[0]),tripCard[1]?el("span",null,tripCard[1]):null,tripCard[2]?el("span",null,tripCard[2]):null)),
  el("div",{className:"si-card"},
   el("h3",{className:"si-h3"},"Últimos viajes"),
   recent.length===0?el("div",{className:"si-kv"},el("span",null,"—"),el("b",null,"Sin viajes terminados")):
   recent.map(t=>el("div",{className:"si-kv click",key:t.id,role:"button",tabIndex:0,onClick:()=>openTrip(t.id),onKeyDown:e=>{if(e.key==="Enter")openTrip(t.id)}},el("span",null,dateShort(t.completed_at||t.updated_at||t.created_at)),el("b",null,`${money(isDriver&&t.driver_earnings!=null?t.driver_earnings:t.fare)} · ${tripSt(t.status)}`)))),
  el("div",{className:"si-card"},
   el("h3",{className:"si-h3"},"Acciones"),
   el("div",{className:"si-acts"},actions.filter(Boolean).map(([label,go,off])=>el("button",{type:"button",key:label,className:"si-btn",disabled:!!off,title:off?"No tiene saldo pendiente":undefined,onClick:go},label)))),
  el("div",{className:"si-card"},
   el("h3",{className:"si-h3"},"Chats anteriores"),
   past.length===0?el("div",{className:"si-kv"},el("span",null,"—"),el("b",null,"Primer chat")):
   past.map(c=>el("div",{className:"si-kv click",key:c.id,role:"button",tabIndex:0,onClick:()=>navigate(`/soporte/chat/${c.id}`),onKeyDown:e=>{if(e.key==="Enter")navigate(`/soporte/chat/${c.id}`)}},el("span",null,ago(c.updated_at||c.created_at)),el("b",null,`#${c.id} · ${PAST_ST[c.status]||c.status||"—"}`)))));
}

// ── Write first ───────────────────────────────────────────────────────────
function WriteModal({onClose,navigate}){
 const[q,setQ]=React.useState(""),[res,setRes]=React.useState(null),[pick,setPick]=React.useState(null),[text,setText]=React.useState(""),[busy,setBusy]=React.useState(false),[err,setErr]=React.useState(null);
 React.useEffect(()=>{const s=q.trim();if(s.length<2){setRes(null);return}let off=false;const t=setTimeout(()=>{apiGet("/admin/home/search",{query:{q:s},retry:{maxAttempts:1}}).then(d=>{if(!off)setRes(((d&&d.results)||[]).filter(r=>r.kind==="person"))}).catch(()=>{if(!off)setRes([])})},300);return()=>{off=true;clearTimeout(t)}},[q]);
 const send=async()=>{const message=text.trim();if(!pick||!message||busy)return;setBusy(true);setErr(null);try{const r=await apiPost(`/admin/users/${pick.id}/support-chat`,{message},{retry:{maxAttempts:1}});onClose();navigate(`/soporte/chat/${r.chat_id}`)}catch(e){setBusy(false);setErr(e instanceof Error?e.message:String(e))}};
 return el(Modal,{title:"Escribir primero",sub:"Busca a un pasajero o conductor. Le llega como mensaje de Soporte con aviso; si ya tiene un chat abierto, va ahí.",onClose,width:520},
  pick?el("div",{className:"si-pick"},el("button",{type:"button",className:"on",onClick:()=>setPick(null)},pick.label,el("small",null,`${pick.sub} · cambiar`))):
  el("div",{style:{display:"flex",flexDirection:"column",gap:8}},
   el("input",{className:"si-field",autoFocus:true,value:q,placeholder:"Nombre, teléfono o correo",onChange:e=>setQ(e.target.value)}),
   res===null?null:res.length===0?el("div",{className:"si-empty"},"Nadie coincide."):
   el("div",{className:"si-pick"},res.map(r=>el("button",{type:"button",key:r.id,onClick:()=>setPick(r)},r.label,el("small",null,r.sub))))),
  pick?el("textarea",{className:"si-field",autoFocus:true,value:text,maxLength:2000,placeholder:`Hola ${firstOf(pick.label)}, `,onChange:e=>setText(e.target.value)}):null,
  err?el("div",{className:"up-err"},err):null,
  el("footer",null,el("button",{type:"button",className:"up-btn",onClick:onClose},"Cancelar"),el("button",{type:"button",className:"up-btn gold",disabled:!pick||!text.trim()||busy,onClick:send},busy?"Enviando…":"Enviar")));
}
function ConfirmModal({title,sub,label,onClose,onYes}){
 const[busy,setBusy]=React.useState(false);
 return el(Modal,{title,sub,onClose,width:440},el("footer",null,el("button",{type:"button",className:"up-btn",onClick:onClose},"Cancelar"),el("button",{type:"button",className:"up-btn gold",disabled:busy,onClick:async()=>{setBusy(true);try{await onYes()}finally{setBusy(false)}}},busy?"…":label)));
}

// ── Page ──────────────────────────────────────────────────────────────────
function SupportInboxScreen({chatId,category}){
 ensureCss();ensureProfileCss();
 const navigate=useNavigate();
 const{data,err,reload}=useInbox();
 const[bot,reloadBot]=useBotStatus();
 const[filter,setFilterState]=React.useState(()=>category==="closed"?"closed":memo.filter);
 const[role,setRoleState]=React.useState(()=>category==="riders"?"rider":category==="drivers"?"driver":memo.role||"all");
 const setRole=r=>{memo.role=r;setRoleState(r)};
 // The whole content area, edge to edge (the panel's 1400 px column and its
 // padding step aside while Soporte is open).
 const wrapRef=React.useRef(null);const[height,setHeight]=React.useState(null);
 React.useLayoutEffect(()=>{const root=document.documentElement;root.classList.add("si-full");const fit=()=>{const w=wrapRef.current;if(!w)return;const top=w.getBoundingClientRect().top;setHeight(Math.max(520,Math.round(window.innerHeight-Math.max(0,top))))};fit();window.addEventListener("resize",fit);return()=>{window.removeEventListener("resize",fit);root.classList.remove("si-full")}},[]);
 const[search,setSearchState]=React.useState(memo.search);
 const[showCtx,setShowCtx]=React.useState(false);
 const[modal,setModal]=React.useState(null);
 const[toastMsg,setToast]=React.useState(null);
 const toastT=React.useRef(null);
 const toast=React.useCallback(m=>{setToast(m);clearTimeout(toastT.current);toastT.current=setTimeout(()=>setToast(null),5e3)},[]);
 React.useEffect(()=>()=>clearTimeout(toastT.current),[]);
 const setFilter=f=>{memo.filter=f;setFilterState(f)};
 const setSearch=s=>{memo.search=s;setSearchState(s)};
 // First look: start on "Esperan respuesta" when someone waits, else Todos.
 React.useEffect(()=>{if(!filter&&data){const f=data.chats.some(c=>inRole(c,role)&&inFilter(c,"wait"))?"wait":"all";setFilter(f)}},[data,filter,role]);// eslint-disable-line
 const row=data&&chatId?data.chats.find(c=>c.id===chatId)||null:null;
 const[ctx,setCtx,reloadCtx]=useContext(chatId||0);
 React.useEffect(()=>{setShowCtx(false);setModal(null)},[chatId]);
 const p=ctx&&ctx.person;
 const pname=p?`${p.first_name||""} ${p.last_name||""}`.trim():(row&&row.user_name)||"";
 const pick=id=>navigate(`/soporte/chat/${id}`);
 const deleteClosed=async()=>{try{const r=await apiDelete("/support/chats/closed",{retry:{maxAttempts:1}});toast(`${(r&&r.deleted)||0} chats cerrados borrados.`);reload()}catch(e){toast(`No se pudieron borrar: ${e instanceof Error?e.message:e}`)}};
 const reactivateBot=async()=>{try{const r=await apiPost("/support/bot-reactivate",{},{retry:{maxAttempts:1}});toast(`Robot reactivado — ${((r&&r.reactivated)||[]).length} chat(s) atendidos.`);reloadBot()}catch{toast("No se pudo reactivar el robot.")}};
 const cls=["si-page",chatId?"has-chat":"",showCtx?"show-ctx":""].filter(Boolean).join(" ");
 return el("div",{className:"si-wrap",ref:wrapRef},el("div",{className:cls,style:height?{height}:undefined},
  el(Inbox,{data,err,chatId,filter:filter||"all",setFilter,role,setRole,search,setSearch,onPick:pick,onWrite:()=>setModal("write"),onDeleteClosed:()=>setModal("delete-closed"),bot,onBot:reactivateBot}),
  chatId?el(Conversation,{key:chatId,chatId,row,ctx,setCtx,reloadCtx,navigate,toast,reloadInbox:reload,onClosed:()=>{reload();reloadCtx()},onBack:()=>navigate("/soporte"),onToggleCtx:()=>setShowCtx(v=>!v),openModal:setModal}):
   el("div",{className:"si-col si-chat"},el("div",{className:"si-center"},el("div",null,el("b",null,"Elige una conversación"),"O escríbele primero a un pasajero o conductor con + Escribir."))),
  chatId?el(ContextPanel,{ctx,row,navigate,openModal:setModal}):null,
  modal==="write"?el(WriteModal,{onClose:()=>setModal(null),navigate}):null,
  modal==="call"?el(CallModal,{name:pname||"esta persona",phone:p&&p.phone||(row&&row.user_phone)||"",onClose:()=>setModal(null),toast}):null,
  modal==="offer"&&p?el(OfferModal,{driverId:p.id,name:firstOf(pname),onClose:()=>setModal(null),toast}):null,
  modal==="pay"&&p?el(PayModal,{driverId:p.id,name:firstOf(pname),amount:Number(ctx.stats&&ctx.stats.pending_balance)||0,onClose:()=>setModal(null),onDone:reloadCtx,toast}):null,
  modal==="delete"&&chatId?el(ConfirmModal,{title:`Eliminar el chat #${chatId}`,sub:"Se borra la conversación del panel y de la app. No se puede deshacer.",label:"Eliminar",onClose:()=>setModal(null),onYes:async()=>{try{await apiDelete(`/support/chats/${chatId}`,{retry:{maxAttempts:1}});setModal(null);reload();navigate("/soporte")}catch(e){toast(`No se pudo eliminar: ${e instanceof Error?e.message:e}`)}}}):null,
  modal==="delete-closed"?el(ConfirmModal,{title:"Borrar todos los chats cerrados",sub:"Se borran del panel y de la app. No se puede deshacer.",label:"Borrar",onClose:()=>setModal(null),onYes:async()=>{setModal(null);await deleteClosed()}}):null,
  toastMsg?el("div",{className:"si-toast",role:"status"},el("span",null,toastMsg),el("button",{type:"button","aria-label":"Cerrar",onClick:()=>setToast(null)},"✕")):null));
}

export{SupportInboxScreen};
