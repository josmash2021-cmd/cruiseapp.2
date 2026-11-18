/*! guard-pin panel_drivers_list: Conductores estilo Lyft (dueño 2026-11-18, dibujo aprobado https://claude.ai/artifact/3PRGKiMqbLtYVhYC8DdG5H) - chunk escrito a mano, sin fuente React (CLAUDE.md #30). Franja "Ahora", las 4 etapas para empezar a manejar (son el filtro), chips y una tabla (bajo ~760 px de ancho de la página cada conductor es una tarjeta). Datos: GET /admin/people/drivers cada 15 s con la página a la vista. Fila = ficha; "⋯" usa los diálogos de la ficha (user-profile-Cruise2026.js), el mismo interruptor En línea de la tarjeta vieja (POST /admin/drivers/{id}/presence) y el chat de soporte. Si este chunk falla se ve la página de antes. */
import{r as React,j as J,y as useNavigate}from"./vendor-react-DprhJQz-.js";
import{W as apiGet,L as apiPost}from"./index-CuQT_62K.js";
import{Modal,CallModal,OfferModal,PayModal,ensureCss as ensureProfileCss}from"./user-profile-Cruise2026.js";
import{a as createPerson}from"./users-DWu98l86.js";

function el(type,props,...kids){
 const p=Object.assign({},props||{});const key=p.key;delete p.key;
 const c=kids.filter(k=>k!==undefined);
 if(c.length===1)p.children=c[0];else if(c.length>1)p.children=c;
 return c.length>1?J.jsxs(type,p,key):J.jsx(type,p,key);
}

const CSS=`
.dl-page{container-type:inline-size;container-name:dl;display:flex;flex-direction:column;gap:18px;color:#F4F4F5;min-width:0}
.dl-top{display:flex;align-items:flex-end;gap:12px;flex-wrap:wrap}
.dl-top h1{margin:0;font-size:28px;font-weight:800;line-height:1.15;letter-spacing:-.01em}
.dl-top p{margin:4px 0 0;font-size:14px;color:rgba(244,244,245,.6)}
.dl-search{display:flex;align-items:center;gap:8px;height:38px;padding:0 14px;border-radius:999px;background:#1C1C24;border:1px solid rgba(255,255,255,.1);width:320px;max-width:100%;color:rgba(244,244,245,.55);box-sizing:border-box}
.dl-search input{flex:1;min-width:0;background:transparent;border:0;outline:0;color:#F4F4F5;font-family:inherit;font-size:13px}
.dl-new{height:40px;padding:0 18px;border-radius:999px;border:0;background:#E8C547;color:#14141A;font-family:inherit;font-size:14px;font-weight:700;cursor:pointer;white-space:nowrap}
.dl-box{background:#16161C;border:1px solid rgba(255,255,255,.06);border-radius:18px}
.dl-now{padding:14px 18px;display:flex;align-items:center;gap:22px;flex-wrap:wrap}
.dl-now .lab{font-size:11.5px;letter-spacing:.09em;font-weight:800;color:rgba(244,244,245,.6)}
.dl-now .big{font-size:22px;font-weight:800}
.dl-now .it{display:flex;align-items:center;gap:8px;font-size:13.5px}
.dl-now .sep{width:1px;height:26px;background:rgba(255,255,255,.08)}
.dl-map{margin-left:auto;font-size:13.5px;font-weight:700;color:#E8C547;cursor:pointer;background:none;border:0;font-family:inherit;padding:0}
.dl-dot{width:9px;height:9px;border-radius:50%;flex:none;display:inline-block}
.dl-cap{font-size:11.5px;letter-spacing:.09em;font-weight:800;color:rgba(244,244,245,.6)}
.dl-stages{display:flex;gap:10px;flex-wrap:wrap;align-items:stretch}
.dl-stage{flex:1 1 170px;min-width:0;text-align:left;padding:14px 16px;border-radius:14px;border:1px solid rgba(255,255,255,.08);background:#1B1B22;color:#F4F4F5;font-family:inherit;cursor:pointer;display:flex;flex-direction:column;gap:6px}
.dl-stage:hover{background:#202029}
.dl-stage.on{border-color:#E8C547;background:#221F14}
.dl-stage.hot{border-color:rgba(229,72,77,.45)}
.dl-stage.on.hot{border-color:#E8C547}
.dl-stage .t{font-size:12.5px;font-weight:600;color:rgba(244,244,245,.6)}
.dl-stage.on .t{color:#E8C547;font-weight:700}
.dl-stage .n{font-size:24px;font-weight:800}
.dl-stage .s{font-size:12px;color:rgba(244,244,245,.6)}
.dl-bar{height:6px;border-radius:99px;background:#26262E;overflow:hidden;display:block}
.dl-bar i{display:block;height:100%}
.dl-chips{display:flex;gap:6px;flex-wrap:wrap;align-items:center}
.dl-chip{height:34px;padding:0 13px;border-radius:999px;border:1px solid rgba(255,255,255,.12);background:transparent;color:rgba(244,244,245,.75);font-family:inherit;font-size:12.5px;font-weight:600;cursor:pointer;display:inline-flex;align-items:center;gap:6px;white-space:nowrap}
.dl-chip b{font-weight:800}
.dl-chip.on{background:#262630;border-color:#262630;color:#fff}
.dl-chip select{appearance:none;-webkit-appearance:none;background:transparent;border:0;color:inherit;font:inherit;cursor:pointer;outline:0;padding-right:2px}
.dl-chip select option{background:#1C1C24;color:#fff}
.dl-vsep{width:1px;height:22px;background:rgba(255,255,255,.1);margin:0 4px}
.dl-grow{flex-grow:1}
.dl-scroll{overflow-x:auto;padding-bottom:6px}
.dl-grid{min-width:1130px}
.dl-tr{display:grid;grid-template-columns:minmax(200px,1.5fr) 178px minmax(190px,1.4fr) 140px 124px 128px 86px 112px 36px;gap:12px;align-items:center;padding:11px 18px;border-top:1px solid rgba(255,255,255,.05);font-size:13.5px;color:#F4F4F5;cursor:pointer;outline:0}
.dl-tr:hover,.dl-tr:focus-visible{background:#1B1B22}
.dl-tr.th{font-size:11.5px;letter-spacing:.06em;font-weight:700;color:rgba(244,244,245,.6);border-top:0;padding-top:14px;padding-bottom:10px;cursor:default;background:transparent}
.dl-tr.open{background:#1B1B22}
.dl-who{display:flex;align-items:center;gap:11px;min-width:0}
.dl-av{width:36px;height:36px;border-radius:50%;display:inline-flex;align-items:center;justify-content:center;font-size:12.5px;font-weight:700;flex:none;color:#14141A;overflow:hidden;background:#3A3A44}
.dl-av img{width:100%;height:100%;object-fit:cover;display:block}
.dl-cut{overflow:hidden;text-overflow:ellipsis;white-space:nowrap;min-width:0}
.dl-mut{color:rgba(244,244,245,.6)}
.dl-sm{font-size:12px}
.dl-b{font-weight:700}
.dl-gold{color:#E8C547}
.dl-col{display:flex;flex-direction:column;gap:3px;min-width:0;align-items:flex-start}
.dl-pill{display:inline-flex;align-items:center;gap:6px;height:24px;padding:0 10px;border-radius:999px;font-size:12px;font-weight:700;white-space:nowrap;max-width:100%}
.p-g{background:rgba(61,214,140,.13);color:#5FE3A1}
.p-b{background:rgba(96,165,250,.15);color:#93C5FD}
.p-y{background:rgba(232,197,71,.14);color:#E8C547}
.p-r{background:rgba(229,72,77,.15);color:#FF9496}
.p-x{background:rgba(255,255,255,.07);color:#B9B9C1}
.dl-tier{display:inline-flex;align-items:center;height:20px;padding:0 7px;border-radius:6px;background:#262630;font-size:11px;font-weight:700;color:#fff;white-space:nowrap}
.dl-tiers{display:flex;gap:5px;flex-wrap:wrap}
.dl-plate{display:inline-flex;align-items:center;height:20px;padding:0 6px;border-radius:4px;background:#F4F4F5;color:#14141A;font-size:11px;font-weight:800;letter-spacing:.05em}
.dl-dots{width:32px;height:32px;border-radius:50%;border:0;background:transparent;color:#C9C9D0;display:inline-flex;align-items:center;justify-content:center;cursor:pointer;font-family:inherit;font-size:18px}
.dl-dots:hover,.dl-dots.on{background:#262630;color:#fff}
.dl-menu{position:fixed;z-index:70;width:240px;padding:6px;background:#1E1E26;border:1px solid rgba(255,255,255,.1);border-radius:16px;box-shadow:0 18px 40px rgba(0,0,0,.45);box-sizing:border-box}
.dl-mi{display:flex;align-items:center;gap:10px;min-height:36px;padding:6px 12px;border-radius:10px;font-size:13.5px;color:#F4F4F5;background:transparent;border:0;font-family:inherit;width:100%;text-align:left;cursor:pointer;box-sizing:border-box}
.dl-mi:hover{background:#262630}
.dl-mi[disabled]{opacity:.45;cursor:default;background:transparent}
.dl-mi.red{color:#FF9496}
.dl-mi small{margin-left:auto;color:rgba(244,244,245,.55);font-size:11.5px}
.dl-hr{height:1px;background:rgba(255,255,255,.08);margin:4px 6px}
.dl-foot{display:flex;align-items:center;gap:12px;padding:14px 18px 8px;border-top:1px solid rgba(255,255,255,.05);flex-wrap:wrap}
.dl-pg{height:38px;width:38px;border-radius:999px;border:1px solid rgba(255,255,255,.14);background:#1E1E26;color:#F4F4F5;font-family:inherit;font-size:16px;font-weight:600;cursor:pointer}
.dl-pg[disabled]{opacity:.4;cursor:default}
.dl-empty{padding:30px 18px;color:rgba(244,244,245,.6);font-size:14px}
.dl-skel{height:46px;margin:6px 18px;border-radius:10px;background:linear-gradient(90deg,#1C1C24,#23232D,#1C1C24);background-size:200% 100%;animation:dl-sk 1.2s infinite linear}
@keyframes dl-sk{to{background-position:-200% 0}}
@media (prefers-reduced-motion:reduce){.dl-skel{animation:none}}
.dl-toast{position:fixed;left:50%;bottom:28px;transform:translateX(-50%);z-index:80;background:#F4F4F5;color:#14141A;font-size:13.5px;font-weight:600;padding:12px 18px;border-radius:14px;box-shadow:0 12px 30px rgba(0,0,0,.4);max-width:calc(100vw - 32px)}
.dl-form{display:flex;flex-direction:column;gap:12px}
.dl-form label{display:flex;flex-direction:column;gap:6px;font-size:12.5px;font-weight:600;color:rgba(255,255,255,.7)}
.dl-in{height:40px;box-sizing:border-box;background:#14141A;border:1px solid rgba(255,255,255,.12);border-radius:12px;color:#fff;padding:0 12px;font-family:inherit;font-size:13.5px;outline:0}
.dl-in:focus{border-color:#E8C547}
.dl-in.bad{border-color:#E5484D}
.dl-two{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:12px}
@container dl (max-width:760px){
 .dl-top h1{font-size:24px}
 .dl-search{width:100%}
 .dl-now{gap:12px 16px}
 .dl-now .sep{display:none}
 .dl-map{margin-left:0}
 .dl-scroll{overflow-x:visible}
 .dl-grid{min-width:0}
 .dl-tr.th{display:none}
 .dl-tr{grid-template-columns:minmax(0,1fr) auto;grid-template-areas:"who more" "now now" "car car" "tiers tiers" "zone week" "app acc";row-gap:8px;padding:14px 16px}
 .c-who{grid-area:who}.c-more{grid-area:more}.c-now{grid-area:now}.c-car{grid-area:car}.c-tiers{grid-area:tiers}.c-zone{grid-area:zone}.c-week{grid-area:week;text-align:right;align-items:flex-end}.c-app{grid-area:app}.c-acc{grid-area:acc;text-align:right}
 .dl-two{grid-template-columns:minmax(0,1fr)}
}
`;
function ensureCss(){if(typeof document==="undefined"||document.getElementById("dl-css"))return;const s=document.createElement("style");s.id="dl-css";s.textContent=CSS;document.head.appendChild(s)}

const STAGES=[
 ["faltan_docs","1 · Faltan documentos","Se registraron y no terminaron","#6B6B75"],
 ["en_revision","2 · Esperan revisión",null,"#E5484D"],
 ["lista_espera","3 · Lista de espera","Esperan un cupo para empezar","#60A5FA"],
 ["aprobados","4 · Aprobados","Pueden conectarse y manejar","#E8C547"]];
const STAGE_NAME={faltan_docs:"con documentos por subir",en_revision:"esperando revisión",lista_espera:"en lista de espera",aprobados:"aprobados"};
const LISTS=[["todos","Todos"],["en_linea","En línea"],["bloqueados","Bloqueados"],["desactivados","Desactivados"],["eliminados","Eliminados"]];
const LIST_NAME={todos:"conductores",en_linea:"en línea",bloqueados:"bloqueados",desactivados:"desactivados",eliminados:"eliminados"};
const MARKETS=[["all","Todos los estados"],["AL","Alabama"],["FL","Florida"]];
const TIERS=[["","Categoría: todas"],["standard","Standard"],["compact","Compact"],["electric_pro","Electric Pro"],["premium","Premium"],["vip","VIP"],["none","Sin vehículo"]];
const SORTS=[["en_linea","Orden: en línea primero"],["nombre","Orden: nombre"],["recientes","Orden: más recientes"],["ganancias","Orden: más ganancias"]];
const AV_BG=["#FCD34D","#FDBA74","#A5F3FC","#C4B5FD","#86EFAC","#F9A8D4","#FCA5A5","#FDE68A","#BEF264","#93C5FD"];
const VIEW_KEY="cruise-drivers-view";

const memo={view:null,data:new Map()};
function readView(){
 if(memo.view)return memo.view;
 const d={stage:"aprobados",list:"todos",state:"all",tier:"",sort:"en_linea",q:"",page:1};
 try{const v=JSON.parse(sessionStorage.getItem(VIEW_KEY)||"null");if(v&&typeof v==="object"){
  if(v.stage===null||STAGES.some(s=>s[0]===v.stage))d.stage=v.stage;
  if(LISTS.some(s=>s[0]===v.list))d.list=v.list;
  if(MARKETS.some(s=>s[0]===v.state))d.state=v.state;
  if(TIERS.some(s=>s[0]===v.tier))d.tier=v.tier;
  if(SORTS.some(s=>s[0]===v.sort))d.sort=v.sort;
  if(typeof v.q==="string")d.q=v.q.slice(0,80);
 }}catch{}
 return d;
}
function saveView(v){memo.view=v;try{sessionStorage.setItem(VIEW_KEY,JSON.stringify({stage:v.stage,list:v.list,state:v.state,tier:v.tier,sort:v.sort,q:v.q}))}catch{}}
const keyOf=v=>[v.stage||"",v.list,v.state,v.tier,v.sort,v.q.trim(),v.page].join("|");

const money=v=>"$"+Number(v||0).toLocaleString("en-US",{minimumFractionDigits:2,maximumFractionDigits:2});
function span(iso){const t=Date.parse(iso||"");if(!isFinite(t))return"";const m=Math.max(0,Math.round((Date.now()-t)/6e4));if(m<1)return"menos de 1 min";if(m<60)return`${m} min`;const h=Math.floor(m/60);if(h<24){const r=m%60;return r&&h<5?`${h} h ${r} min`:`${h} h`}const d=Math.round(h/24);return d===1?"1 día":`${d} días`}
const initials=n=>String(n||"").split(/\s+/).filter(Boolean).slice(0,2).map(w=>w[0].toUpperCase()).join("")||"·";
const avBg=id=>AV_BG[Math.abs(Number(id)||0)%AV_BG.length];
const plat=p=>p==="ios"?"iOS":p==="android"?"Android":p==="web"?"Web":p?String(p):"";

function nowCell(r){
 const acct=r.account;
 if(acct==="blocked")return[["Bloqueado","p-r"],"Cuenta bloqueada"];
 if(acct==="deactivated")return[["Desactivado","p-x"],"Cuenta desactivada"];
 if(acct==="deleted"||acct==="pending_deletion")return[["Eliminado","p-x"],"Cuenta eliminada"];
 const lv=r.live||{},t=lv.trip;
 const who=t&&t.rider?t.rider:"su pasajero";
 switch(lv.state){
  case"en_viaje":return[["● En viaje","p-g"],t&&t.eta_min!=null?`Deja a ${who} en ${t.eta_min} min`:`Lleva a ${who}`];
  case"yendo":return[["● Yendo a recoger","p-b"],t&&t.eta_min!=null?`Recoge a ${who} en ${t.eta_min} min`:`Va por ${who}`];
  case"en_recogida":return[["● En la recogida","p-b"],t&&t.since?`Espera a ${who} · ${span(t.since)}`:`Espera a ${who}`];
  case"libre":return[["● Libre","p-y"],lv.online_since?`En línea desde hace ${span(lv.online_since)}`:"En línea"];
  case"sin_senal":return[["● Sin señal","p-x"],(lv.last_seen?`Último dato hace ${span(lv.last_seen)}`:"Sin datos de su app")+(t?" · en un viaje":"")];
 }
 if(r.stage==="faltan_docs")return[["Faltan documentos","p-x"],r.verification==="rejected"?"Rechazado: debe volver a enviarlos":"No terminó de registrarse"];
 if(r.stage==="en_revision")return[["Espera revisión","p-r"],"Subió todos sus documentos"];
 if(r.stage==="lista_espera")return[["Lista de espera","p-b"],"Espera un cupo"];
 return[["○ Desconectado","p-x"],lv.last_seen?`Hace ${span(lv.last_seen)}`:"Nunca se conectó"];
}

function Avatar({r}){
 const[bad,setBad]=React.useState(false);
 return el("span",{className:"dl-av",style:r.photo_url&&!bad?undefined:{background:avBg(r.id)}},
  r.photo_url&&!bad?el("img",{src:r.photo_url,alt:"",loading:"lazy",onError:()=>setBad(true)}):initials(r.name));
}

// "Escribir": the open support chat if there is one, else a first message
// (the same steps as the Mapa en vivo and the ficha).
function WriteModal({d,onClose,navigate}){
 const[chat,setChat]=React.useState(undefined),[text,setText]=React.useState(""),[busy,setBusy]=React.useState(false),[err,setErr]=React.useState(null);
 React.useEffect(()=>{let off=false;apiGet(`/admin/users/${d.id}/support-chat`,{retry:{maxAttempts:1}}).then(r=>{if(off)return;if(r&&r.chat_id){navigate(`/soporte/chat/${r.chat_id}`);onClose()}else setChat(null)}).catch(()=>{if(!off)setChat(null)});return()=>{off=true}},[d.id]);// eslint-disable-line
 const send=async()=>{const message=text.trim();if(!message||busy)return;setBusy(true);setErr(null);
  let persona=null;try{const v=JSON.parse(localStorage.getItem("si-persona-last")||"null");if(v&&typeof v.kind==="string")persona={kind:v.kind,name:v.kind==="name"?v.name:null}}catch{}
  try{const r=await apiPost(`/admin/users/${d.id}/support-chat`,persona?{message,persona}:{message},{retry:{maxAttempts:1}});navigate(`/soporte/chat/${r.chat_id}`);onClose()}catch(e){setBusy(false);setErr(e instanceof Error?e.message:String(e))}};
 const first=String(d.name||"").split(/\s+/)[0];
 return el(Modal,{title:`Escribirle a ${d.short}`,sub:"Le llega como un mensaje de Soporte en su app, con aviso.",onClose,width:480},
  chat===undefined?el("div",{className:"up-muted"},"Buscando su chat…"):
  el("textarea",{className:"up-text",autoFocus:true,value:text,maxLength:2000,placeholder:`Hola ${first}, `,onChange:e=>setText(e.target.value)}),
  err?el("div",{className:"up-err"},err):null,
  el("footer",null,el("button",{type:"button",className:"up-btn",onClick:onClose},"Cancelar"),el("button",{type:"button",className:"up-btn gold",disabled:chat===undefined||!text.trim()||busy,onClick:send},busy?"Enviando…":"Enviar")));
}

// "+ Agregar conductor": the old page's create flow (users-DWu98l86.js),
// same fields, same call.
function AddModal({onClose,onDone,toast}){
 const[f,setF]=React.useState({first:"",last:"",phone:"",tier:"",plate:""}),[bad,setBad]=React.useState({}),[busy,setBusy]=React.useState(false),[err,setErr]=React.useState(null);
 const set=k=>e=>setF(x=>Object.assign({},x,{[k]:e.target.value}));
 const save=async()=>{if(busy)return;const b={};if(!f.first.trim())b.first=1;if(!f.last.trim())b.last=1;if(!f.phone.trim())b.phone=1;setBad(b);if(Object.keys(b).length)return;
  setBusy(true);setErr(null);const name=`${f.first.trim()} ${f.last.trim()}`.trim();
  try{const r=await createPerson("driver",{firstName:f.first.trim(),lastName:f.last.trim(),phone:f.phone.trim(),email:null,vehicleType:f.tier||null,vehiclePlate:f.plate.trim()||null});
   const w=r&&Array.isArray(r.warnings)?r.warnings:[];toast(w.length?`${name} registrado — ${w.join(" · ")}`:`${name} registrado`);onDone();onClose()}
  catch(e){setBusy(false);setErr(e instanceof Error?e.message:String(e))}};
 const inp=(k,label,extra)=>el("label",null,label,el("input",Object.assign({className:"dl-in"+(bad[k]?" bad":""),value:f[k],onChange:set(k)},extra||{})));
 return el(Modal,{title:"Agregar conductor",sub:"Queda registrado y sigue con sus documentos en la app.",onClose,width:520},
  el("form",{className:"dl-form",onSubmit:e=>{e.preventDefault();save()}},
   el("div",{className:"dl-two"},inp("first","Nombre",{autoFocus:true,autoComplete:"off"}),inp("last","Apellido",{autoComplete:"off"})),
   inp("phone","Teléfono",{inputMode:"tel",autoComplete:"off"}),
   el("div",{className:"dl-two"},
    el("label",null,"Categoría del vehículo (opcional)",el("select",{className:"dl-in",value:f.tier,onChange:set("tier")},[el("option",{key:"",value:""},"Sin definir")].concat(TIERS.filter(t=>t[0]&&t[0]!=="none").map(([v,l])=>el("option",{key:v,value:v},l))))),
    inp("plate","Placa (opcional)",{autoComplete:"off"})),
   el("button",{type:"submit",style:{display:"none"},"aria-hidden":"true",tabIndex:-1})),
  err?el("div",{className:"up-err"},err):null,
  el("footer",null,el("button",{type:"button",className:"up-btn",onClick:onClose,disabled:busy},"Cancelar"),el("button",{type:"button",className:"up-btn gold",onClick:save,disabled:busy},busy?"Guardando…":"Guardar conductor")));
}

function RowMenu({r,at,onClose,act}){
 const ref=React.useRef(null);
 React.useEffect(()=>{
  const down=e=>{if(ref.current&&!ref.current.contains(e.target))onClose()};
  const key=e=>{if(e.key==="Escape")onClose()};
  const away=()=>onClose();
  document.addEventListener("mousedown",down);document.addEventListener("keydown",key);window.addEventListener("resize",away);window.addEventListener("scroll",away,true);
  return()=>{document.removeEventListener("mousedown",down);document.removeEventListener("keydown",key);window.removeEventListener("resize",away);window.removeEventListener("scroll",away,true)}},[onClose]);
 const lv=r.live||{},online=lv.state&&lv.state!=="desconectado";
 const items=[el("button",{key:"f",type:"button",className:"dl-mi",onClick:()=>act("ficha",r)},"Ver ficha"),
  el("button",{key:"c",type:"button",className:"dl-mi",onClick:()=>act("call",r)},"Llamar"),
  el("button",{key:"w",type:"button",className:"dl-mi",onClick:()=>act("write",r)},"Escribir por soporte")];
 if(r.presence_switch&&!(lv.trip))items.push(el("button",{key:"o",type:"button",className:"dl-mi",onClick:()=>act("offer",r)},"Ofrecerle un viaje"));
 if(online)items.push(el("button",{key:"m",type:"button",className:"dl-mi",onClick:()=>act("map",r)},"Ver en el mapa"));
 if(lv.trip)items.push(el("button",{key:"t",type:"button",className:"dl-mi",onClick:()=>act("trip",r)},`Abrir su viaje #${lv.trip.id}`));
 if(r.pending_balance>0)items.push(el("button",{key:"p",type:"button",className:"dl-mi",onClick:()=>act("pay",r)},"Pagar ahora",el("small",null,money(r.pending_balance))));
 const tail=[];
 if(r.presence_switch){
  if(lv.online)tail.push(el("button",{key:"off",type:"button",className:"dl-mi",onClick:()=>act("presence_off",r)},"Sacarlo de línea"));
  else tail.push(el("button",{key:"on",type:"button",className:"dl-mi",disabled:r.go_online_disabled,onClick:()=>act("presence_on",r)},"Ponerlo en línea",r.go_online_disabled?el("small",null,"GO desactivado"):undefined));
 }
 tail.push(el("button",{key:"b",type:"button",className:"dl-mi red",onClick:()=>act("account",r)},"Desactivar o bloquear…"));
 const h=items.length*38+tail.length*38+30;
 const top=at.bottom+6+h>window.innerHeight-8?Math.max(8,at.top-6-h):at.bottom+6;
 const left=Math.max(8,Math.min(at.right-240,window.innerWidth-248));
 return el("div",{ref,className:"dl-menu",role:"menu",style:{top,left},onClick:e=>e.stopPropagation()},...items,el("div",{className:"dl-hr"}),...tail);
}

function Row({r,open,onMenu,onOpen}){
 const[[label,pill],sub]=nowCell(r);
 const v=r.vehicle;
 const week=r.week||{trips:0,earnings:0};
 const acc=r.acceptance==null?null:Math.round(r.acceptance*100);
 const app=r.app||{};
 const appText=[plat(app.platform),app.build!=null?String(app.build):""].filter(Boolean).join(" · ")||"—";
 return el("div",{role:"row",tabIndex:0,className:"dl-tr"+(open?" open":""),onClick:onOpen,onKeyDown:e=>{if(e.key==="Enter"&&e.target===e.currentTarget)onOpen()}},
  el("div",{className:"dl-who c-who",role:"cell"},el(Avatar,{r}),
   el("div",{style:{minWidth:0}},el("div",{className:"dl-cut",style:{fontWeight:600}},r.name),el("div",{className:"dl-mut dl-sm"},`${r.rating!=null?`★ ${Number(r.rating).toFixed(2)} · `:""}#${r.id}`))),
  el("div",{className:"dl-col c-now",role:"cell"},el("span",{className:`dl-pill ${pill}`},label),el("span",{className:"dl-mut dl-cut dl-sm",style:{maxWidth:"100%"}},sub)),
  el("div",{className:"dl-col c-car",role:"cell",style:{gap:4}},
   v?el("span",{className:"dl-cut",style:{maxWidth:"100%"}},[v.make,v.model,v.year].filter(Boolean).join(" ")+(v.color?` · ${v.color}`:"")):el("span",{className:"dl-mut"},"Sin vehículo"),
   v&&v.plate?el("span",{className:"dl-plate"},v.plate):null),
  el("div",{className:"dl-tiers c-tiers",role:"cell"},(r.tiers||[]).length?r.tiers.map(t=>el("span",{key:t,className:"dl-tier"},t)):el("span",{className:"dl-mut"},"—")),
  el("div",{className:"dl-cut c-zone"+(r.zone?"":" dl-mut"),role:"cell"},r.zone||"Sin zona"),
  el("div",{className:"dl-col c-week",role:"cell"},el("span",{className:"dl-b"},money(week.earnings)),el("span",{className:"dl-mut dl-sm"},week.trips===1?"1 viaje":`${week.trips} viajes`)),
  el("div",{className:"c-acc dl-b"+(acc==null?" dl-mut":acc<80?" dl-gold":""),role:"cell"},acc==null?"—":`${acc}%`),
  el("div",{className:"dl-cut c-app"+(app.old?" dl-gold":""),role:"cell"},appText+(app.old?" · vieja":"")),
  el("div",{className:"c-more",role:"cell",style:{justifySelf:"end"}},el("button",{type:"button",className:"dl-dots"+(open?" on":""),"aria-label":`Más acciones para ${r.name}`,"aria-haspopup":"menu","aria-expanded":open,onClick:e=>{e.stopPropagation();onMenu(e.currentTarget.getBoundingClientRect())}},"⋯")));
}

function DriversList(){
 ensureCss();ensureProfileCss();
 const navigate=useNavigate();
 const[view,setViewState]=React.useState(readView);
 const[qText,setQText]=React.useState(view.q);
 const[data,setData]=React.useState(()=>memo.data.get(keyOf(view))||null),[err,setErr]=React.useState(null);
 const[menu,setMenu]=React.useState(null),[modal,setModal]=React.useState(null),[toastMsg,setToastMsg]=React.useState(null);
 const[nonce,setNonce]=React.useState(0);
 const toastTimer=React.useRef(0),pending=React.useRef(new Map());
 const toast=React.useCallback(m=>{setToastMsg(m);clearTimeout(toastTimer.current);toastTimer.current=setTimeout(()=>setToastMsg(null),4e3)},[]);
 React.useEffect(()=>()=>clearTimeout(toastTimer.current),[]);
 const setView=patch=>setViewState(v=>{const n=Object.assign({},v,patch);if(!("page"in patch))n.page=1;saveView(n);return n});
 const reload=React.useCallback(()=>setNonce(n=>n+1),[]);

 // The search waits for the typing to stop.
 React.useEffect(()=>{if(qText===view.q)return;const t=setTimeout(()=>setView({q:qText}),300);return()=>clearTimeout(t)},[qText]);// eslint-disable-line

 React.useEffect(()=>{let off=false,timer=null;const k=keyOf(view);
  const cached=memo.data.get(k);if(cached)setData(cached);
  const load=async()=>{clearTimeout(timer);if(document.visibilityState!=="visible"){timer=setTimeout(load,15e3);return}
   try{const query={list:view.list,state:view.state,sort:view.sort,page:String(view.page)};
    if(view.stage)query.stage=view.stage;if(view.tier)query.tier=view.tier;if(view.q.trim())query.q=view.q.trim();
    const d=await apiGet("/admin/people/drivers",{query,retry:{maxAttempts:1},timeoutMs:12e3});if(off)return;
    if(d&&Array.isArray(d.rows)){memo.data.set(k,d);if(memo.data.size>30)memo.data.delete(memo.data.keys().next().value);setData(d);setErr(null);
     // A "Ponerlo en línea" waits for the app: say so when it never came.
     for(const[id,p]of pending.current){const row=d.rows.find(x=>x.id===id);if(row&&row.live&&row.live.online===p.want){pending.current.delete(id)}else if(Date.now()-p.at>2e4){pending.current.delete(id);if(p.want)toast(`${p.name} no se conectó en 20 s: su app puede estar cerrada o sin señal.`)}}}
   }catch(e){if(!off)setErr(e instanceof Error?e.message:String(e))}
   if(!off)timer=setTimeout(load,pending.current.size?5e3:15e3)};
  load();
  const vis=()=>{if(document.visibilityState==="visible")load()};document.addEventListener("visibilitychange",vis);
  return()=>{off=true;clearTimeout(timer);document.removeEventListener("visibilitychange",vis)}},[keyOf(view),nonce]);// eslint-disable-line

 const presence=async(r,want)=>{
  try{await apiPost(`/admin/drivers/${r.id}/presence`,{online:want},{retry:{maxAttempts:1}});
   if(want){pending.current.set(r.id,{want,at:Date.now(),name:r.short});toast(`Le pedimos a la app de ${r.short} que se conecte.`)}
   else toast(`${r.short} quedó fuera de línea.`);
   reload()}
  catch(e){toast(`No se pudo ${want?"conectar":"desconectar"} a ${r.short}: ${e instanceof Error?e.message:String(e)}`)}};
 const act=(what,r)=>{setMenu(null);
  switch(what){
   case"ficha":navigate(`/personas/driver/sql_${r.id}`);break;
   case"account":navigate(`/personas/driver/sql_${r.id}`,{state:{profileTab:"cuenta"}});break;
   case"map":navigate("/mapa",{state:{driverId:r.id}});break;
   case"trip":navigate(`/viajes/viaje/sql_${r.live.trip.id}`);break;
   case"presence_on":presence(r,true);break;
   case"presence_off":presence(r,false);break;
   default:setModal({kind:what,r});
  }};

 const d=data;
 const strip=d&&d.strip||{online:0,libres:0,yendo:0,en_viaje:0,sin_senal:0};
 const stages=d&&d.stages||{};
 const lists=d&&d.lists||{};
 const stageTotal=STAGES.reduce((s,[id])=>s+((stages[id]||{}).n||0),0)||1;
 const rows=d&&d.rows||[];
 const total=d?d.total:0,page=d?d.page:view.page,pages=d?d.pages:1,size=d?d.page_size:25;
 const from=total?(page-1)*size+1:0,to=Math.min(total,page*size);
 const what=view.stage?STAGE_NAME[view.stage]:LIST_NAME[view.list];
 const searching=view.q.trim()!=="";
 const empty=searching?"Nadie coincide con la búsqueda.":view.stage==="en_revision"?"Nadie espera revisión.":view.list==="en_linea"?"Ningún conductor está en línea ahora.":`No hay conductores ${what}.`;
 const head=el("div",{className:"dl-tr th",role:"row"},...["Conductor","Ahora","Vehículo","Categorías","Zona","Esta semana","Acepta","App",""].map((h,i)=>el("span",{key:i,role:"columnheader"},h)));
 const m=modal&&modal.r;

 return el("div",{className:"dl-page"},
  el("div",{className:"dl-top"},
   el("div",{style:{flex:"1 1 260px",minWidth:0}},el("h1",null,"Conductores"),
    el("p",null,d?`${lists.todos||0} ${lists.todos===1?"cuenta":"cuentas"} · ${(stages.aprobados||{}).n||0} aprobados para manejar`:"Cargando…")),
   el("label",{className:"dl-search"},el("svg",{width:16,height:16,viewBox:"0 0 24 24",fill:"none",stroke:"currentColor",strokeWidth:2,strokeLinecap:"round","aria-hidden":"true"},el("circle",{cx:11,cy:11,r:7}),el("path",{d:"m20 20-4-4"})),
    el("input",{type:"search",value:qText,placeholder:"Nombre, teléfono, placa o #id","aria-label":"Buscar conductores",onChange:e=>setQText(e.target.value)})),
   el("button",{type:"button",className:"dl-new",onClick:()=>setModal({kind:"add"})},"+ Agregar conductor")),

  el("section",{className:"dl-box dl-now","aria-label":"Ahora"},
   el("div",{style:{display:"flex",alignItems:"baseline",gap:8}},el("span",{className:"lab"},"AHORA"),el("span",{className:"big"},String(strip.online)),el("span",{className:"dl-mut",style:{fontSize:13}},"en línea")),
   el("span",{className:"sep"}),
   el("div",{className:"it"},el("span",{className:"dl-dot",style:{background:"#E8C547"}}),el("b",null,String(strip.libres)),strip.libres===1?" libre":" libres"),
   el("div",{className:"it"},el("span",{className:"dl-dot",style:{background:"#60A5FA"}}),el("b",null,String(strip.yendo))," yendo a recoger"),
   el("div",{className:"it"},el("span",{className:"dl-dot",style:{background:"#3DD68C"}}),el("b",null,String(strip.en_viaje))," en viaje"),
   el("div",{className:"it"},el("span",{className:"dl-dot",style:{background:"#6B6B75"}}),el("b",null,String(strip.sin_senal))," sin señal"),
   el("button",{type:"button",className:"dl-map",onClick:()=>navigate("/mapa")},"Ver en el mapa →")),

  el("div",{style:{display:"flex",flexDirection:"column",gap:10}},
   el("div",{className:"dl-cap"},"CAMINO PARA MANEJAR · toca una etapa para ver quiénes están ahí"),
   el("div",{className:"dl-stages"},STAGES.map(([id,title,sub,color])=>{
    const s=stages[id]||{},n=s.n||0,on=view.stage===id,hot=id==="en_revision"&&n>0;
    const subText=id==="en_revision"?(n>0&&s.oldest_at?`La más vieja: hace ${span(s.oldest_at)}`:"Nadie esperando"):sub;
    return el("button",{type:"button",key:id,className:"dl-stage"+(on?" on":"")+(hot?" hot":""),"aria-pressed":on,onClick:()=>setView(on?{stage:null}:{stage:id,list:"todos"})},
     el("span",{className:"t"},title),
     el("span",{className:"n",style:hot&&!on?{color:"#FF9496"}:undefined},d?String(n):"·"),
     el("span",{className:"dl-bar"},el("i",{style:{width:`${Math.max(n?2:0,Math.round(n/stageTotal*100))}%`,background:color}})),
     el("span",{className:"s"},subText))}))),

  el("div",{className:"dl-chips"},
   LISTS.map(([id,label])=>{const on=!view.stage&&view.list===id;return el("button",{type:"button",key:id,className:"dl-chip"+(on?" on":""),"aria-pressed":on,onClick:()=>setView({list:id,stage:null})},label," ",el("b",null,d?String(lists[id]||0):"·"))}),
   el("span",{className:"dl-vsep"}),
   MARKETS.map(([id,label])=>el("button",{type:"button",key:id,className:"dl-chip"+(view.state===id?" on":""),"aria-pressed":view.state===id,onClick:()=>setView({state:id})},label)),
   el("label",{className:"dl-chip"+(view.tier?" on":"")},el("select",{"aria-label":"Categoría",value:view.tier,onChange:e=>setView({tier:e.target.value})},TIERS.map(([v,l])=>el("option",{key:v,value:v},v&&d&&d.tiers?`${l} · ${d.tiers[v]||0}`:l))),"▾"),
   el("span",{className:"dl-grow"}),
   el("label",{className:"dl-chip"},el("select",{"aria-label":"Orden",value:view.sort,onChange:e=>setView({sort:e.target.value})},SORTS.map(([v,l])=>el("option",{key:v,value:v},l))),"▾")),

  el("section",{className:"dl-box","aria-label":"Lista de conductores"},
   el("div",{className:"dl-scroll"},
    el("div",{className:"dl-grid",role:"table"},head,
     d===null?(err?el("div",{className:"dl-empty"},`No se pudo cargar la lista: ${err}`):[0,1,2,3,4].map(i=>el("div",{key:i,className:"dl-skel"}))):
     rows.length===0?el("div",{className:"dl-empty"},empty):
     rows.map(r=>el(Row,{key:r.id,r,open:menu!==null&&menu.r.id===r.id,onOpen:()=>navigate(`/personas/driver/sql_${r.id}`),onMenu:at=>setMenu(menu&&menu.r.id===r.id?null:{r,at})})))),
   d&&total>0?el("div",{className:"dl-foot"},
    el("span",{className:"dl-mut",style:{fontSize:13}},`${from}–${to} de ${total} ${what}`),
    err?el("span",{className:"dl-mut",style:{fontSize:12}},"· sin conexión, reintentando"):null,
    el("span",{className:"dl-grow"}),
    el("button",{type:"button",className:"dl-pg","aria-label":"Página anterior",disabled:page<=1,onClick:()=>setView({page:page-1})},"‹"),
    el("button",{type:"button",className:"dl-pg","aria-label":"Página siguiente",disabled:page>=pages,onClick:()=>setView({page:page+1})},"›")):null),

  menu?el(RowMenu,{r:menu.r,at:menu.at,onClose:()=>setMenu(null),act}):null,
  modal&&modal.kind==="call"?el(CallModal,{name:m.short,phone:m.phone,onClose:()=>setModal(null),toast}):null,
  modal&&modal.kind==="write"?el(WriteModal,{d:m,onClose:()=>setModal(null),navigate}):null,
  modal&&modal.kind==="offer"?el(OfferModal,{driverId:m.id,name:m.short,onClose:()=>setModal(null),toast}):null,
  modal&&modal.kind==="pay"?el(PayModal,{driverId:m.id,name:m.short,amount:m.pending_balance,onClose:()=>setModal(null),onDone:reload,toast}):null,
  modal&&modal.kind==="add"?el(AddModal,{onClose:()=>setModal(null),onDone:()=>setTimeout(reload,1500),toast}):null,
  toastMsg?el("div",{className:"dl-toast",role:"status"},toastMsg):null);
}

export{DriversList};
