/*! guard-pin panel_riders_list: Pasajeros = UNA tabla (dueño 2026-11-18, dibujo https://claude.ai/artifact/3PRGKiMqbLtYVhYC8DdG5H, mesa "Pasajeros") - chunk escrito a mano, sin fuente React (CLAUDE.md #30). Reemplaza las tarjetas grandes de PeopleGridScreen (index-azyIyM-i.js) para el rol pasajero. Datos: GET /admin/people/riders (filtra, ordena y pagina el servidor; pestañas con el mismo sentido de antes, «Todos» sin cuentas eliminadas #82; la zona sale de la dirección de un viaje, nunca de un punto GPS #67). Se vuelve a pedir cada 30 s con la pestaña a la vista. Tocar una fila abre la ficha. ⋯ = ficha, llamar, escribir por soporte, crear viaje, su último viaje, desactivar/bloquear (en la ficha). Agregar = la misma función de alta de la página de antes (users-DWu98l86.js). Bajo ~760 px de ancho cada pasajero es una tarjeta. Si este chunk falla se ve la página de antes. */
import{r as React,j as J,y as useNavigate}from"./vendor-react-DprhJQz-.js";
import{W as apiGet,L as apiPost}from"./index-CuQT_62K.js";
import{Modal,CallModal,ensureCss as ensureProfileCss}from"./user-profile-Cruise2026.js";

function el(type,props,...kids){
 const p=Object.assign({},props||{});const key=p.key;delete p.key;
 const c=kids.filter(k=>k!==undefined);
 if(c.length===1)p.children=c[0];else if(c.length>1)p.children=c;
 return c.length>1?J.jsxs(type,p,key):J.jsx(type,p,key);
}

const CSS=`
.rl-page{display:flex;flex-direction:column;gap:20px;color:#F4F4F5;min-width:0;container:rl/inline-size}
.rl-top{display:flex;align-items:flex-end;gap:12px;flex-wrap:wrap}
.rl-top h1{margin:0;font-size:28px;font-weight:800;line-height:1.15;letter-spacing:-.01em}
.rl-top p{margin:4px 0 0;font-size:14px;color:#A1A1AA}
.rl-search{display:flex;align-items:center;gap:8px;height:38px;padding:0 14px;border-radius:999px;background:#1C1C24;border:1px solid rgba(255,255,255,.1);width:320px;max-width:100%;box-sizing:border-box;color:#A1A1AA}
.rl-search input{flex:1;min-width:0;background:transparent;border:0;outline:0;color:#F4F4F5;font-family:inherit;font-size:13px}
.rl-new{height:38px;padding:0 16px;border-radius:999px;border:1px solid #E8C547;background:#E8C547;color:#14141A;font-family:inherit;font-size:13px;font-weight:700;cursor:pointer;white-space:nowrap}
.rl-tiles{display:grid;grid-template-columns:repeat(4,minmax(0,1fr));gap:14px}
.rl-tile{background:#16161C;border:1px solid rgba(255,255,255,.06);border-radius:18px;padding:16px 18px;display:flex;flex-direction:column;gap:4px;text-align:left;font-family:inherit;color:#F4F4F5;min-width:0}
button.rl-tile{cursor:pointer}button.rl-tile:hover{border-color:rgba(255,255,255,.14)}
.rl-tile .k{font-size:12.5px;font-weight:600;color:#A1A1AA}
.rl-tile .n{font-size:30px;font-weight:800;line-height:1.15}
.rl-tile .s{font-size:12.5px;color:#A1A1AA;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.rl-tile .s a,.rl-link{color:#E8C547;font-weight:600;text-decoration:none;background:none;border:0;padding:0;font:inherit;cursor:pointer}
.rl-tabs,.rl-chips{display:flex;gap:8px;flex-wrap:wrap;align-items:center}
.rl-chips{gap:6px}
.rl-tab{height:36px;padding:0 14px;border-radius:999px;border:1px solid rgba(255,255,255,.12);background:transparent;color:#C9C9D0;font-family:inherit;font-size:13px;font-weight:600;cursor:pointer;display:inline-flex;align-items:center;gap:8px;white-space:nowrap}
.rl-tab b{font-weight:800}
.rl-tab.on{background:#E8C547;border-color:#E8C547;color:#14141A}
.rl-chip{height:34px;padding:0 13px;border-radius:999px;border:1px solid rgba(255,255,255,.12);background:transparent;color:#C9C9D0;font-family:inherit;font-size:12.5px;font-weight:600;cursor:pointer;white-space:nowrap}
.rl-chip.on{background:#262630;border-color:#262630;color:#fff}
select.rl-chip{appearance:none;-webkit-appearance:none;padding-right:28px;background-image:linear-gradient(45deg,transparent 50%,#C9C9D0 50%),linear-gradient(135deg,#C9C9D0 50%,transparent 50%);background-position:calc(100% - 15px) 15px,calc(100% - 10px) 15px;background-size:5px 5px;background-repeat:no-repeat}
select.rl-chip.on{background-color:#262630}
select.rl-chip option{background:#1E1E26;color:#F4F4F5}
.rl-sep{width:1px;height:22px;background:rgba(255,255,255,.1);margin:0 4px}
.rl-box{background:#16161C;border:1px solid rgba(255,255,255,.06);border-radius:18px;overflow-x:auto;padding-bottom:6px}
.rl-grid{min-width:1130px}
.rl-tr{display:grid;grid-template-columns:minmax(210px,1.7fr) 138px 132px 58px 128px 150px 116px 104px 92px 36px;gap:12px;align-items:center;padding:11px 18px;border-top:1px solid rgba(255,255,255,.05);font-size:13.5px;cursor:pointer}
.rl-tr:hover,.rl-tr:focus-visible{background:#1B1B22;outline:0}
.rl-tr.head{cursor:default;font-size:11.5px;letter-spacing:.06em;font-weight:700;color:#A1A1AA;border-top:0;padding-top:14px;padding-bottom:10px;text-transform:uppercase}
.rl-tr.head:hover{background:transparent}
.rl-who{display:flex;align-items:center;gap:11px;min-width:0}
.rl-av{width:36px;height:36px;border-radius:50%;display:inline-flex;align-items:center;justify-content:center;font-size:12.5px;font-weight:700;flex:none;color:#14141A;overflow:hidden;background:#26262E}
.rl-av img{width:100%;height:100%;object-fit:cover;display:block}
.rl-name{display:flex;align-items:center;gap:7px;min-width:0}
.rl-name b{font-weight:600;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;min-width:0}
.rl-mut{color:#A1A1AA}
.rl-sm{font-size:12px}
.rl-gold{color:#E8C547}
.rl-cut{overflow:hidden;text-overflow:ellipsis;white-space:nowrap;min-width:0}
.rl-pill{display:inline-flex;align-items:center;gap:6px;height:24px;padding:0 10px;border-radius:999px;font-size:12px;font-weight:700;white-space:nowrap}
.rl-pill.live{height:20px;font-size:11px;padding:0 7px}
.p-green{background:rgba(61,214,140,.13);color:#5FE3A1}
.p-gold{background:rgba(232,197,71,.14);color:#E8C547}
.p-gray{background:rgba(255,255,255,.07);color:#B9B9C1}
.p-red{background:rgba(229,72,77,.15);color:#FF9496}
.p-blue{background:rgba(96,165,250,.15);color:#93C5FD}
.rl-dots{width:32px;height:32px;border-radius:50%;border:0;background:transparent;color:#C9C9D0;display:inline-flex;align-items:center;justify-content:center;cursor:pointer;font-family:inherit;font-size:18px}
.rl-dots:hover,.rl-dots[aria-expanded=true]{background:#262630;color:#fff}
.rl-menu{position:fixed;z-index:60;width:240px;padding:6px;background:#1E1E26;border:1px solid rgba(255,255,255,.1);border-radius:16px;box-shadow:0 18px 40px rgba(0,0,0,.45);box-sizing:border-box}
.rl-mi{display:flex;align-items:center;gap:10px;height:36px;padding:0 12px;border-radius:10px;font-size:13.5px;color:#F4F4F5;background:transparent;border:0;font-family:inherit;width:100%;text-align:left;cursor:pointer}
.rl-mi:hover,.rl-mi:focus-visible{background:#262630;outline:0}
.rl-mi.red{color:#FF9496}
.rl-mi:disabled{opacity:.45;cursor:default}
.rl-mhr{height:1px;background:rgba(255,255,255,.08);margin:4px 6px}
.rl-foot{display:flex;align-items:center;gap:12px;padding:14px 18px 8px;border-top:1px solid rgba(255,255,255,.05)}
.rl-pg{width:38px;height:38px;border-radius:999px;border:1px solid rgba(255,255,255,.14);background:#1E1E26;color:#F4F4F5;font-family:inherit;font-size:16px;cursor:pointer}
.rl-pg:disabled{opacity:.4;cursor:default}
.rl-empty{padding:30px 18px;color:#A1A1AA;font-size:14px}
.rl-skel{height:46px;margin:6px 18px;border-radius:10px;background:linear-gradient(90deg,#1C1C24,#23232D,#1C1C24);background-size:200% 100%;animation:rl-sk 1.2s infinite linear}
@keyframes rl-sk{to{background-position:-200% 0}}
.rl-toast{position:fixed;left:50%;bottom:28px;transform:translateX(-50%);z-index:70;background:#1E1E26;border:1px solid rgba(255,255,255,.12);color:#F4F4F5;padding:12px 18px;border-radius:14px;font-size:13.5px;box-shadow:0 12px 30px rgba(0,0,0,.4);max-width:min(560px,calc(100vw - 32px))}
.rl-form{display:flex;flex-direction:column;gap:12px}
.rl-form label{display:flex;flex-direction:column;gap:6px;font-size:12.5px;font-weight:600;color:#A1A1AA}
.rl-in{height:40px;padding:0 12px;border-radius:10px;border:1px solid rgba(255,255,255,.12);background:#1C1C24;color:#F4F4F5;font-family:inherit;font-size:14px;outline:0}
.rl-in:focus{border-color:#E8C547}
.rl-in.bad{border-color:#E5484D}
.rl-zonephone{display:none}
@media (prefers-reduced-motion:reduce){.rl-skel{animation:none}}
@container rl (max-width:900px){.rl-tiles{grid-template-columns:repeat(2,minmax(0,1fr))}}
@container rl (max-width:760px){
 .rl-search{width:100%}
 .rl-grid{min-width:0}
 .rl-tr.head{display:none}
 .rl-tr{grid-template-columns:minmax(0,1fr) auto auto;grid-template-areas:"who ver dots" "zone zone zone" "last last last" "pay app app";row-gap:7px;padding:14px 16px}
 .c-who{grid-area:who}.c-ver{grid-area:ver}.c-dots{grid-area:dots}.c-zone{grid-area:zone}.c-last{grid-area:last}.c-pay{grid-area:pay}.c-app{grid-area:app;text-align:right}
 .c-phone,.c-trips,.c-act{display:none}
 .rl-zonephone{display:inline}
}
`;
function ensureCss(){if(typeof document==="undefined"||document.getElementById("rl-css"))return;const s=document.createElement("style");s.id="rl-css";s.textContent=CSS;document.head.appendChild(s)}

const TABS=[["todos","Todos"],["verificados","Verificados"],["por_verificar","Por verificar"],["bloqueados","Bloqueados"],["desactivados","Desactivados"],["eliminados","Eliminados"]];
const MARKETS=[["all","Todos los estados"],["AL","Alabama"],["FL","Florida"]];
const APPS=[["","App: todas"],["ios","App: iOS"],["android","App: Android"],["web","App: Web"]];
const PAYS=[["","Pago: todos"],["con","Pago: con tarjeta"],["sin","Pago: sin método"]];
const ACTS=[["","Actividad: cualquiera"],["7d","Activos: 7 días"],["30d","Activos: 30 días"]];
const SORTS=[["recientes","Orden: más recientes"],["actividad","Orden: última actividad"],["viajes","Orden: más viajes"],["nombre","Orden: nombre A–Z"]];
const SIZES=[25,50,100];
const VERIF={approved:["Verificada","p-green"],pending:["Por verificar","p-gold"],no_docs:["Sin documentos","p-gray"],rejected:["Rechazada","p-red"],waitlist:["Lista de espera","p-blue"]};
const ACCOUNT={blocked:["Bloqueada","p-red"],deactivated:["Desactivada","p-gray"],deleted:["Eliminada","p-gray"]};
const MON=["ene","feb","mar","abr","may","jun","jul","ago","sep","oct","nov","dic"];
const HUES=["#F9A8D4","#FCA5A5","#93C5FD","#A5F3FC","#BEF264","#FDBA74","#C4B5FD","#FCD34D","#FDE68A","#86EFAC"];
const VIEW_KEY="cruise-riders-view";
const DEF={tab:"todos",state:"all",app:"",pay:"",active:"",sort:"recientes",size:25,page:1,q:""};
const memo={key:null,data:null};

function readView(){try{const v=JSON.parse(sessionStorage.getItem(VIEW_KEY)||"null");if(!v||typeof v!=="object")return DEF;const pick=(k,list)=>list.some(x=>x[0]===v[k])?v[k]:DEF[k];return{tab:pick("tab",TABS),state:pick("state",MARKETS),app:pick("app",APPS),pay:pick("pay",PAYS),active:pick("active",ACTS),sort:pick("sort",SORTS),size:SIZES.includes(v.size)?v.size:25,page:Number.isSafeInteger(v.page)&&v.page>0?v.page:1,q:typeof v.q==="string"?v.q.slice(0,120):""}}catch{return DEF}}
function saveView(v){try{sessionStorage.setItem(VIEW_KEY,JSON.stringify(v))}catch{}}

const money=v=>"$"+Number(v||0).toLocaleString("en-US",{minimumFractionDigits:2,maximumFractionDigits:2});
function phoneFmt(p){const d=String(p||"").replace(/\D/g,"");const t=d.length===11&&d[0]==="1"?d.slice(1):d;return t.length===10?`(${t.slice(0,3)}) ${t.slice(3,6)}-${t.slice(6)}`:String(p||"")}
function initials(r){const a=(r.first_name||r.name||"").trim()[0]||"",b=(r.last_name||"").trim()[0]||"";return(a+b).toUpperCase()||"·"}
// Dates the panel shows outside a trip's own zone are in Miami time (CLAUDE.md #68).
function dayOf(iso){const t=Date.parse(iso||"");if(!isFinite(t))return"";try{const parts=new Intl.DateTimeFormat("en-US",{timeZone:"America/New_York",year:"numeric",month:"numeric",day:"numeric"}).formatToParts(new Date(t));const g=k=>Number((parts.find(p=>p.type===k)||{}).value);const y=g("year");return`${g("day")} ${MON[g("month")-1]}${y!==new Date().getFullYear()?` ${y}`:""}`}catch{return""}}
function agoText(iso){const t=Date.parse(iso||"");if(!isFinite(t))return"Sin dato";const m=Math.floor((Date.now()-t)/6e4);if(m<2)return"ahora";if(m<60)return`hace ${m} min`;const h=Math.floor(m/60);if(h<24)return`hace ${h} h`;const d=Math.floor(h/24);return d===1?"hace 1 día":d<45?`hace ${d} días`:`el ${dayOf(iso)}`}
function appText(a){if(!a||!a.platform)return"—";const p={ios:"iOS",android:"Android",web:"Web"}[a.platform]||a.platform;return a.build&&a.platform!=="web"?`${p} · ${a.build}`:p}
const plural=(n,one,many)=>`${n} ${n===1?one:many}`;

function Avatar({r}){const[bad,setBad]=React.useState(false);return el("span",{className:"rl-av",style:r.photo&&!bad?undefined:{background:HUES[Math.abs(r.id)%HUES.length]},"aria-hidden":"true"},r.photo&&!bad?el("img",{src:r.photo,alt:"",loading:"lazy",onError:()=>setBad(true)}):initials(r))}

function WriteModal({r,onClose,navigate}){
 const[chat,setChat]=React.useState(undefined),[text,setText]=React.useState(""),[busy,setBusy]=React.useState(false),[err,setErr]=React.useState(null);
 React.useEffect(()=>{let off=false;apiGet(`/admin/users/${r.id}/support-chat`,{retry:{maxAttempts:1}}).then(x=>{if(off)return;if(x&&x.chat_id){navigate(`/soporte/chat/${x.chat_id}`);onClose()}else setChat(null)}).catch(()=>{if(!off)setChat(null)});return()=>{off=true}},[r.id]);// eslint-disable-line
 const send=async()=>{const message=text.trim();if(!message||busy)return;setBusy(true);setErr(null);
  let persona=null;try{const v=JSON.parse(localStorage.getItem("si-persona-last")||"null");if(v&&typeof v.kind==="string")persona={kind:v.kind,name:v.kind==="name"?v.name:null}}catch{}
  try{const x=await apiPost(`/admin/users/${r.id}/support-chat`,persona?{message,persona}:{message},{retry:{maxAttempts:1}});navigate(`/soporte/chat/${x.chat_id}`);onClose()}catch(e){setBusy(false);setErr(e instanceof Error?e.message:String(e))}};
 const first=String(r.first_name||r.name||"").split(/\s+/)[0];
 return el(Modal,{title:`Escribirle a ${r.short}`,sub:"Le llega como un mensaje de Soporte en su app, con aviso.",onClose,width:480},
  chat===undefined?el("div",{className:"up-muted"},"Buscando su chat…"):
  el("textarea",{className:"up-text",autoFocus:true,value:text,maxLength:2000,placeholder:`Hola ${first}, `,onChange:e=>setText(e.target.value)}),
  err?el("div",{className:"up-err"},err):null,
  el("footer",null,el("button",{type:"button",className:"up-btn",onClick:onClose},"Cancelar"),el("button",{type:"button",className:"up-btn gold",disabled:chat===undefined||!text.trim()||busy,onClick:send},busy?"Enviando…":"Enviar")));
}

// "+ Agregar pasajero": the old page's own sign-up (users-DWu98l86.js `a`):
// the Firestore card plus the account on the server, same warnings.
function AddModal({onClose,onDone}){
 const[f,setF]=React.useState({firstName:"",lastName:"",phone:"",email:""}),[bad,setBad]=React.useState({}),[busy,setBusy]=React.useState(false),[err,setErr]=React.useState(null);
 const set=k=>e=>setF(o=>({...o,[k]:e.target.value}));
 const save=async e=>{if(e)e.preventDefault();if(busy)return;const b={};if(!f.firstName.trim())b.firstName=1;if(!f.lastName.trim())b.lastName=1;if(!f.phone.trim())b.phone=1;setBad(b);if(Object.keys(b).length)return;
  setBusy(true);setErr(null);
  try{const mod=await import("./users-DWu98l86.js");const res=await mod.a("rider",{firstName:f.firstName.trim(),lastName:f.lastName.trim(),phone:f.phone.trim(),email:f.email.trim()!==""?f.email.trim():null,vehicleType:null,vehiclePlate:null});
   const name=`${f.firstName.trim()} ${f.lastName.trim()}`.trim();const w=res&&Array.isArray(res.warnings)?res.warnings:[];onDone(w.length?`${name} registrado — ${w.join(" · ")}`:`${name} registrado`)}
  catch(x){setBusy(false);setErr(x instanceof Error?x.message:String(x))}};
 const field=(k,label,extra)=>el("label",{key:k},label,el("input",Object.assign({className:bad[k]?"rl-in bad":"rl-in",value:f[k],onChange:set(k),"aria-invalid":bad[k]?"true":undefined},extra||{})));
 return el(Modal,{title:"Agregar pasajero",sub:"Se crea su cuenta. Entra con su teléfono.",onClose,width:440},
  el("form",{className:"rl-form",onSubmit:save},
   field("firstName","Nombre",{autoFocus:true,autoComplete:"off"}),field("lastName","Apellido",{autoComplete:"off"}),
   field("phone","Teléfono",{inputMode:"tel",autoComplete:"off"}),field("email","Correo (opcional)",{inputMode:"email",autoComplete:"off"}),
   el("button",{type:"submit",hidden:true,tabIndex:-1,"aria-hidden":"true"})),
  err?el("div",{className:"up-err"},err):null,
  el("footer",null,el("button",{type:"button",className:"up-btn",onClick:onClose,disabled:busy},"Cancelar"),el("button",{type:"button",className:"up-btn gold",onClick:()=>save(),disabled:busy},busy?"Guardando…":"Guardar pasajero")));
}

function RowMenu({menu,onClose,act}){
 const ref=React.useRef(null);
 React.useEffect(()=>{const away=e=>{if(ref.current&&!ref.current.contains(e.target)&&!(menu.anchor&&menu.anchor.contains(e.target)))onClose()};const key=e=>{if(e.key==="Escape")onClose()};const gone=()=>onClose();
  document.addEventListener("mousedown",away);document.addEventListener("keydown",key);window.addEventListener("resize",gone);window.addEventListener("scroll",gone,true);
  const first=ref.current&&ref.current.querySelector("button");if(first)first.focus();
  return()=>{document.removeEventListener("mousedown",away);document.removeEventListener("keydown",key);window.removeEventListener("resize",gone);window.removeEventListener("scroll",gone,true)}},[menu,onClose]);
 const r=menu.row,trip=r.live?r.live.id:r.last?r.last.id:null;
 const item=(label,fn,opts)=>el("button",{type:"button",role:"menuitem",className:opts&&opts.red?"rl-mi red":"rl-mi",disabled:opts&&opts.disabled,onClick:()=>{onClose();fn()}},label);
 return el("div",{ref,className:"rl-menu",role:"menu","aria-label":`Acciones de ${r.short}`,style:{top:menu.top,left:menu.left}},
  item("Ver ficha",()=>act("open",r)),
  item("Llamar",()=>act("call",r),{disabled:!r.phone}),
  item("Escribir por soporte",()=>act("write",r)),
  item("Crear viaje",()=>act("book",r),{disabled:r.account!=="active"}),
  item(r.live?"Ver su viaje de ahora":"Ver su último viaje",()=>act("trip",r),{disabled:!trip}),
  el("div",{className:"rl-mhr",role:"separator"}),
  item("Desactivar o bloquear…",()=>act("account",r),{red:true}));
}

function RidersList(){
 ensureCss();ensureProfileCss();
 const navigate=useNavigate();
 const[view,setViewState]=React.useState(readView);
 const[qText,setQText]=React.useState(view.q);
 const key=JSON.stringify(view);
 const[data,setData]=React.useState(memo.key===key?memo.data:null);
 const[err,setErr]=React.useState(null),[loading,setLoading]=React.useState(memo.key!==key);
 const[menu,setMenu]=React.useState(null),[modal,setModal]=React.useState(null),[toastMsg,setToastMsg]=React.useState(null);
 const[reloadN,setReloadN]=React.useState(0);
 const toastT=React.useRef(0);
 const toast=React.useCallback(m=>{setToastMsg(m);clearTimeout(toastT.current);toastT.current=setTimeout(()=>setToastMsg(null),4e3)},[]);
 React.useEffect(()=>()=>clearTimeout(toastT.current),[]);
 const setView=patch=>setViewState(v=>{const n={...v,...patch};if(!("page"in patch))n.page=1;saveView(n);return n});
 // Search: typed text settles 300 ms before it asks the server.
 React.useEffect(()=>{if(qText===view.q)return;const t=setTimeout(()=>setView({q:qText.trim().slice(0,120)}),300);return()=>clearTimeout(t)},[qText]);// eslint-disable-line
 React.useEffect(()=>{let off=false,timer=null;
  const load=async(first)=>{clearTimeout(timer);if(!first&&document.visibilityState!=="visible"){timer=setTimeout(()=>load(false),3e4);return}
   try{const query={tab:view.tab,state:view.state,sort:view.sort,page:view.page,size:view.size};for(const k of["app","pay","active","q"])if(view[k])query[k]=view[k];
    const d=await apiGet("/admin/people/riders",{query,retry:{maxAttempts:1},timeoutMs:12e3});if(off)return;
    if(d&&Array.isArray(d.rows)){memo.key=key;memo.data=d;setData(d);setErr(null);if(d.page!==view.page)setViewState(v=>{const n={...v,page:d.page};saveView(n);return n})}}
   catch(e){if(!off)setErr(e instanceof Error?e.message:String(e))}
   if(!off){setLoading(false);timer=setTimeout(()=>load(false),3e4)}};
  setLoading(true);load(true);
  const vis=()=>{if(document.visibilityState==="visible")load(false)};document.addEventListener("visibilitychange",vis);
  return()=>{off=true;clearTimeout(timer);document.removeEventListener("visibilitychange",vis)}},[key,reloadN]);// eslint-disable-line

 const act=(what,r)=>{
  if(what==="open")navigate(`/personas/rider/sql_${r.id}`);
  else if(what==="call")setModal({kind:"call",r});
  else if(what==="write")setModal({kind:"write",r});
  else if(what==="book")navigate("/viajes/nuevo",{state:{bookingPrefill:{rider:{id:r.id,first_name:r.first_name,last_name:r.last_name,phone:r.phone,photo_url:r.photo},pickup:null,dropoff:null}}});
  else if(what==="trip"){const id=r.live?r.live.id:r.last?r.last.id:null;if(id)navigate(`/viajes/viaje/sql_${id}`)}
  // Account changes live in the ficha's Cuenta tab (re-auth, reasons, audit).
  else if(what==="account")navigate(`/personas/rider/sql_${r.id}`,{state:{cruiseProfileTab:"cuenta"}});
 };
 const openMenu=(e,r)=>{e.stopPropagation();const b=e.currentTarget;if(menu&&menu.row.id===r.id){setMenu(null);return}
  const rc=b.getBoundingClientRect(),w=240,h=300,vw=window.innerWidth,vh=window.innerHeight;
  const left=Math.max(8,Math.min(rc.right-w,vw-w-8)),top=rc.bottom+6+h>vh?Math.max(8,rc.top-h-6):rc.bottom+6;
  setMenu({row:r,top,left,anchor:b})};
 const closeMenu=React.useCallback(()=>setMenu(null),[]);

 const counts=data&&data.counts||{},tiles=data&&data.tiles||null,rows=data&&data.rows||[];
 const sel=(list,k,cls)=>el("select",{className:view[k]&&view[k]!==DEF[k]?`rl-chip on ${cls||""}`:`rl-chip ${cls||""}`,value:view[k],"aria-label":list[0][1].split(":")[0],onChange:e=>setView({[k]:e.target.value})},list.map(([v,l])=>el("option",{key:v,value:v},l)));
 const live=tiles&&tiles.live;
 const tileLive=live&&live.n>0&&live.first?el("button",{type:"button",className:"rl-tile",onClick:()=>navigate(`/viajes/viaje/sql_${live.first.trip_id}`)},
   el("span",{className:"k"},"En un viaje ahora"),el("span",{className:"n",style:{color:"#5FE3A1"}},String(live.n)),
   el("span",{className:"s"},[live.first.name,live.first.zone].filter(Boolean).join(" · ")+(live.n>1?` y ${live.n-1} más`:""))):
  el("div",{className:"rl-tile"},el("span",{className:"k"},"En un viaje ahora"),el("span",{className:"n",style:{color:"#5FE3A1"}},tiles?"0":"·"),el("span",{className:"s"},tiles?"Nadie en este momento":"…"));
 const sub=data?`${plural(data.total_accounts,"cuenta","cuentas")} · ${plural(data.new_7d,"nueva","nuevas")} esta semana`:"Cargando…";
 const from=data&&data.total?(data.page-1)*data.size+1:0,to=data?Math.min(data.total,data.page*data.size):0;

 const head=el("div",{className:"rl-tr head",role:"row"},...["Pasajero","Teléfono","Zona","Viajes","Último viaje","Pago","Verificación","App","Actividad",""].map((h,i)=>el("span",{key:i,role:"columnheader"},h)));
 const body=data===null?(err?el("div",{className:"rl-empty"},`No se pudo cargar la lista: ${err} `,el("button",{type:"button",className:"rl-link",onClick:()=>setReloadN(n=>n+1)},"Reintentar")):[0,1,2,3,4].map(i=>el("div",{key:i,className:"rl-skel"}))):
  rows.length===0?el("div",{className:"rl-empty"},view.q?`Nadie coincide con «${view.q}».`:`No hay pasajeros en «${(TABS.find(t=>t[0]===view.tab)||TABS[0])[1]}» con estos filtros.`):
  rows.map(r=>{const[vl,vc]=ACCOUNT[r.account]||VERIF[r.verif]||VERIF.pending;
   const last=r.live?[`Ahora · ${money(r.live.fare)}`,`${r.live.from||"—"} → ${r.live.to||"—"}`,""]:r.last?[`${r.last.day} · ${money(r.last.fare)}`,`${r.last.from||"—"} → ${r.last.to||"—"}`,""]:["Sin viajes","","rl-mut"];
   return el("div",{key:r.id,role:"row",tabIndex:0,className:"rl-tr","aria-label":`Abrir la ficha de ${r.name}`,onClick:()=>act("open",r),onKeyDown:e=>{if(e.key==="Enter"&&e.target===e.currentTarget)act("open",r)}},
    el("div",{className:"rl-who c-who",role:"cell"},el(Avatar,{r}),
     el("div",{style:{minWidth:0}},el("div",{className:"rl-name"},el("b",null,r.name),r.live?el("span",{className:"rl-pill live p-green"},"● En viaje"):null),
      el("div",{className:"rl-mut rl-sm rl-cut"},`#${r.id} · desde ${dayOf(r.since)||"—"}`,el("span",{className:"rl-zonephone"},r.phone?` · ${phoneFmt(r.phone)}`:"")))),
    el("div",{className:"rl-cut c-phone",role:"cell"},r.phone?phoneFmt(r.phone):el("span",{className:"rl-mut"},"—")),
    el("div",{className:r.zone?"rl-cut c-zone":"rl-cut rl-mut c-zone",role:"cell"},r.zone||"Sin dato"),
    el("div",{className:"c-trips",role:"cell",style:{fontWeight:700}},String(r.trips)),
    el("div",{className:"c-last",role:"cell",style:{minWidth:0}},el("div",{className:`rl-cut ${last[2]}`},last[0]),last[1]?el("div",{className:"rl-mut rl-sm rl-cut"},last[1]):null),
    el("div",{className:r.pay?"rl-cut c-pay":"rl-cut rl-mut c-pay",role:"cell"},r.pay||"Sin método"),
    el("div",{className:"c-ver",role:"cell"},el("span",{className:`rl-pill ${vc}`},vl)),
    el("div",{className:r.app&&r.app.old?"rl-cut rl-gold c-app":"rl-cut c-app",role:"cell",title:r.app&&r.app.old?"Versión vieja de la app":undefined},appText(r.app)+(r.app&&r.app.old?" · vieja":"")),
    el("div",{className:"rl-mut rl-cut c-act",role:"cell"},agoText(r.active_at)),
    el("div",{className:"c-dots",role:"cell"},el("button",{type:"button",className:"rl-dots","aria-label":`Más acciones para ${r.name}`,"aria-haspopup":"menu","aria-expanded":menu&&menu.row.id===r.id?"true":"false",onClick:e=>openMenu(e,r),onKeyDown:e=>e.stopPropagation()},"⋯")))});

 return el("div",{className:"rl-page"},
  el("div",{className:"rl-top"},
   el("div",{style:{flex:"1 1 260px",minWidth:0}},el("h1",null,"Pasajeros"),el("p",null,sub)),
   el("label",{className:"rl-search"},el("svg",{width:16,height:16,viewBox:"0 0 24 24",fill:"none",stroke:"currentColor",strokeWidth:2,strokeLinecap:"round","aria-hidden":"true"},el("circle",{cx:11,cy:11,r:7}),el("path",{d:"m20 20-4-4"})),
    el("input",{type:"search",value:qText,placeholder:"Nombre, teléfono, correo o #id","aria-label":"Buscar pasajeros",onChange:e=>setQText(e.target.value)})),
   el("button",{type:"button",className:"rl-new",onClick:()=>setModal({kind:"add"})},"+ Agregar pasajero")),
  el("div",{className:"rl-tiles"},
   tileLive,
   el("div",{className:"rl-tile"},el("span",{className:"k"},"Pidieron viaje · 30 días"),el("span",{className:"n"},tiles?String(tiles.asked_30d.n):"·"),el("span",{className:"s"},tiles?`Alabama ${tiles.asked_30d.AL} · Florida ${tiles.asked_30d.FL}`:"…")),
   el("button",{type:"button",className:"rl-tile",onClick:()=>setView({pay:"con",tab:"todos"}),"aria-label":"Ver los que tienen tarjeta guardada"},el("span",{className:"k"},"Con tarjeta guardada"),el("span",{className:"n"},tiles?String(tiles.with_card.n):"·"),el("span",{className:"s"},tiles?`${tiles.with_card.without} todavía sin método de pago`:"…")),
   el("div",{className:"rl-tile"},el("span",{className:"k"},"Por verificar"),el("span",{className:"n",style:{color:"#E8C547"}},tiles?String(tiles.to_verify):"·"),el("span",{className:"s"},"Revisar en ",el("button",{type:"button",className:"rl-link",onClick:()=>navigate("/verificacion")},"Verificación")))),
  el("div",{className:"rl-tabs",role:"group","aria-label":"Pestañas"},
   TABS.map(([id,label])=>el("button",{type:"button",key:id,className:id===view.tab?"rl-tab on":"rl-tab","aria-pressed":id===view.tab,onClick:()=>setView({tab:id})},label,el("b",null,data?String(counts[id]||0):"·")))),
  el("div",{className:"rl-chips"},
   MARKETS.map(([m,label])=>el("button",{type:"button",key:m,className:m===view.state?"rl-chip on":"rl-chip","aria-pressed":m===view.state,onClick:()=>setView({state:m})},label)),
   el("span",{className:"rl-sep","aria-hidden":"true"}),
   sel(APPS,"app"),sel(PAYS,"pay"),sel(ACTS,"active"),
   el("span",{style:{flexGrow:1}}),
   el("select",{className:"rl-chip",value:view.sort,"aria-label":"Orden",onChange:e=>setView({sort:e.target.value})},SORTS.map(([v,l])=>el("option",{key:v,value:v},l)))),
  el("section",{className:"rl-box","aria-label":"Lista de pasajeros","aria-busy":loading?"true":"false"},
   el("div",{className:"rl-grid",role:"table"},head,body,
    data&&data.total>0?el("div",{className:"rl-foot"},
     el("span",{className:"rl-mut",style:{fontSize:13}},`${from}–${to} de ${data.total}`),
     el("span",{style:{flexGrow:1}}),
     el("select",{className:"rl-chip",value:view.size,"aria-label":"Pasajeros por página",onChange:e=>setView({size:Number(e.target.value)})},SIZES.map(n=>el("option",{key:n,value:n},`Mostrar ${n}`))),
     el("button",{type:"button",className:"rl-pg","aria-label":"Página anterior",disabled:data.page<=1,onClick:()=>setView({page:data.page-1})},"‹"),
     el("button",{type:"button",className:"rl-pg","aria-label":"Página siguiente",disabled:data.page>=data.pages,onClick:()=>setView({page:data.page+1})},"›")):null)),
  menu?el(RowMenu,{menu,onClose:closeMenu,act}):null,
  modal&&modal.kind==="call"?el(CallModal,{name:modal.r.name,phone:modal.r.phone,onClose:()=>setModal(null),toast}):null,
  modal&&modal.kind==="write"?el(WriteModal,{r:modal.r,onClose:()=>setModal(null),navigate}):null,
  modal&&modal.kind==="add"?el(AddModal,{onClose:()=>setModal(null),onDone:m=>{setModal(null);toast(m);setReloadN(n=>n+1)}}):null,
  toastMsg?el("div",{className:"rl-toast",role:"status"},toastMsg):null);
}

export{RidersList};
