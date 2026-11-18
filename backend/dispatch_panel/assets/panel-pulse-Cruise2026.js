/*! guard-pin panel_pulse: menú con contadores en vivo + los DOS únicos avisos agrupados (dueño 2026-11-16, dibujo https://claude.ai/artifact/MSML67sC6y5MHc4kNF2rxQ) - chunk escrito a mano, sin fuente React (CLAUDE.md #30). Un solo poll a GET /admin/panel/pulse (10 s visible / 20 s oculta). Avisan SOLO soporte (gente esperando a una persona) y viajes sin conductor; cada uno es UN aviso que cuenta (100 mensajes = "100 personas esperan"). Suena una vez: de 0 a 1 o cuando alguien pasa de 5 min, máximo 1 vez por minuto. Cerrarlo = 5 min sin volver salvo que alguien pase de 5 min. En Soporte no sale el de soporte; en Viajes no sale el de viajes. */
import{r as React,j as J,y as useNavigate}from"./vendor-react-DprhJQz-.js";
import{W as apiGet,L as apiPost,aA as useVerificationQueue}from"./index-CuQT_62K.js";

function el(type,props,...kids){
 const p=Object.assign({},props||{});const key=p.key;delete p.key;
 const c=kids.filter(k=>k!==undefined);
 if(c.length===1)p.children=c[0];else if(c.length>1)p.children=c;
 return c.length>1?J.jsxs(type,p,key):J.jsx(type,p,key);
}

const CSS=`
.cp-cnt{margin-left:auto;min-width:20px;height:20px;padding:0 6px;border-radius:999px;font-size:11px;font-weight:800;display:inline-grid;place-items:center;box-sizing:border-box;flex:none;white-space:nowrap;font-family:inherit}
.cp-cnt.hot{background:#FF6B57;color:#14141A;animation:cp-ping 1.8s ease-out infinite}
.cp-cnt.gold{background:rgba(232,197,71,.16);color:#E8C547}
.cp-cnt.grey{background:#262630;color:rgba(244,244,245,.8);font-weight:700}
.cp-cnt.bump{animation:cp-bump .45s cubic-bezier(.3,1.6,.5,1),cp-ping 1.8s ease-out .45s infinite}
.cp-live{margin-left:auto;width:8px;height:8px;border-radius:50%;background:#3DD68C;flex:none;animation:cp-live 2s ease-out infinite}
.cp-dot{position:absolute;top:5px;right:12px;width:9px;height:9px;border-radius:50%;border:2px solid #0B0B0F;box-sizing:content-box}
.cp-dot.hot{background:#FF6B57}.cp-dot.gold{background:#E8C547}.cp-dot.live{background:#3DD68C}
.cp-gdot{width:8px;height:8px;border-radius:50%;background:#FF6B57;display:inline-block;margin-left:8px;vertical-align:middle}
@keyframes cp-ping{0%{box-shadow:0 0 0 0 rgba(255,107,87,.55)}70%{box-shadow:0 0 0 7px rgba(255,107,87,0)}100%{box-shadow:0 0 0 0 rgba(255,107,87,0)}}
@keyframes cp-live{0%{box-shadow:0 0 0 0 rgba(61,214,140,.6)}70%{box-shadow:0 0 0 7px rgba(61,214,140,0)}100%{box-shadow:0 0 0 0 rgba(61,214,140,0)}}
@keyframes cp-bump{0%{transform:scale(1)}45%{transform:scale(1.35)}100%{transform:scale(1)}}
.cp-hbtn{width:30px;height:30px;border-radius:9px;border:0;background:transparent;color:rgba(244,244,245,.65);display:grid;place-items:center;cursor:pointer;position:relative;flex:none}
.cp-hbtn:hover{background:rgba(255,255,255,.06);color:#fff}
.cp-hbtn.on{color:#E8C547}
.cp-hbtn .n{position:absolute;top:-4px;right:-5px;min-width:17px;height:17px;padding:0 4px;border-radius:999px;background:#FF6B57;color:#14141A;font-size:10px;font-weight:800;display:grid;place-items:center;box-sizing:border-box;border:2px solid #0B0B0F}
.cp-feed{position:fixed;z-index:70;width:340px;max-width:calc(100vw - 24px);background:#1C1C24;border:1px solid rgba(255,255,255,.1);border-radius:16px;box-shadow:0 18px 44px rgba(0,0,0,.55);padding:10px;color:#F4F4F5;font-family:inherit}
.cp-feed h4{margin:4px 6px 8px;font-size:14px;font-weight:700}
.cp-fi{display:flex;gap:10px;align-items:flex-start;width:100%;padding:9px 8px;border:0;border-radius:10px;background:transparent;color:#F4F4F5;text-align:left;cursor:pointer;font-family:inherit}
.cp-fi:hover{background:rgba(255,255,255,.05)}
.cp-fi b{font-size:13px;font-weight:600;display:block}.cp-fi small{font-size:12px;color:rgba(244,244,245,.55)}
.cp-w{width:30px;height:30px;border-radius:9px;display:grid;place-items:center;flex:none}
.cp-w.hot{background:rgba(255,107,87,.16);color:#FF8A7A}.cp-w.gold{background:rgba(232,197,71,.14);color:#E8C547}.cp-w.blue{background:rgba(127,209,255,.14);color:#8FD7FF}.cp-w.grey{background:#262630;color:rgba(244,244,245,.75)}
.cp-sep{height:1px;background:rgba(255,255,255,.08);margin:8px 6px}
.cp-push{padding:6px 8px 4px;display:flex;flex-direction:column;gap:6px}
.cp-push b{font-size:13px;font-weight:700}.cp-push small{font-size:12px;color:rgba(244,244,245,.6);line-height:1.45}
.cp-push .row{display:flex;gap:8px;flex-wrap:wrap;margin-top:2px}
.cp-pbtn{height:32px;padding:0 14px;border-radius:999px;border:0;background:#E8C547;color:#14141A;font-family:inherit;font-size:12.5px;font-weight:700;cursor:pointer}
.cp-pbtn.ghost{background:transparent;border:1px solid rgba(255,255,255,.16);color:#F4F4F5}
.cp-pbtn:disabled{opacity:.5;cursor:default}
.cp-pmsg{font-size:12px;color:#E8C547}
.cp-toasts{position:fixed;top:16px;right:18px;z-index:80;display:flex;flex-direction:column;gap:10px;pointer-events:none}
.cp-toast{pointer-events:auto;width:370px;max-width:calc(100vw - 24px);background:rgba(28,28,36,.97);border:1px solid rgba(255,255,255,.1);border-radius:16px;box-shadow:0 16px 40px rgba(0,0,0,.55);overflow:hidden;color:#F4F4F5;font-family:inherit;animation:cp-in .34s cubic-bezier(.2,.9,.3,1.15)}
.cp-toast.pulse{animation:cp-pulse .45s cubic-bezier(.3,1.5,.5,1)}
@keyframes cp-in{from{transform:translateX(120%);opacity:0}to{transform:none;opacity:1}}
@keyframes cp-pulse{0%{transform:scale(1)}40%{transform:scale(1.035)}100%{transform:scale(1)}}
.cp-toast .in{display:flex;gap:12px;align-items:flex-start;padding:14px 10px 12px 14px}
.cp-toast .tw{width:38px;height:38px;border-radius:11px;display:grid;place-items:center;flex:none;background:rgba(255,107,87,.16);color:#FF8A7A}
.cp-toast .tn{display:inline-grid;place-items:center;min-width:24px;height:21px;padding:0 6px;border-radius:999px;background:#FF6B57;color:#14141A;font-size:11.5px;font-weight:800;margin-right:7px;box-sizing:border-box}
.cp-toast b.t{font-size:14px;font-weight:700;display:flex;align-items:center}
.cp-toast small{font-size:12.5px;color:rgba(244,244,245,.62);display:block;margin-top:3px}
.cp-toast .go{margin-top:9px;height:31px;padding:0 13px;border-radius:999px;border:0;background:#E8C547;color:#14141A;font-family:inherit;font-size:12.5px;font-weight:700;cursor:pointer}
.cp-toast .x{width:28px;height:28px;border-radius:50%;border:0;background:transparent;color:rgba(244,244,245,.6);display:grid;place-items:center;cursor:pointer;flex:none}
.cp-toast .x:hover{background:rgba(255,255,255,.06);color:#fff}
.cp-toast .bar{height:3px;background:#FF6B57;transform-origin:left;animation:cp-drain 8s linear forwards}
@keyframes cp-drain{from{transform:scaleX(1)}to{transform:scaleX(0)}}
@media (prefers-reduced-motion:reduce){.cp-cnt.hot,.cp-cnt.bump,.cp-live,.cp-toast,.cp-toast.pulse{animation:none}}
`;
function ensureCss(){if(typeof document==="undefined"||document.getElementById("cp-css"))return;const s=document.createElement("style");s.id="cp-css";s.textContent=CSS;document.head.appendChild(s)}

// ── One shared poll ───────────────────────────────────────────────────────
const P={data:null,subs:new Set,timer:null,users:0,busy:false};
function emit(){for(const f of P.subs)f(P.data)}
async function poll(){
 clearTimeout(P.timer);P.timer=null;
 if(P.users<=0||P.busy)return;
 P.busy=true;
 try{const d=await apiGet("/admin/panel/pulse",{retry:{maxAttempts:1},timeoutMs:8e3});if(d&&d.support){P.data=d;emit()}}catch{}
 finally{P.busy=false;if(P.users>0)P.timer=setTimeout(poll,document.visibilityState==="visible"?1e4:2e4)}
}
if(typeof document!=="undefined")document.addEventListener("visibilitychange",()=>{if(document.visibilityState==="visible"&&P.users>0)poll()});
function usePulse(){
 const[d,setD]=React.useState(P.data);
 React.useEffect(()=>{ensureCss();P.subs.add(setD);P.users++;if(P.users===1||!P.data)poll();else setD(P.data);return()=>{P.subs.delete(setD);P.users--;if(P.users<=0){clearTimeout(P.timer);P.timer=null}}},[]);
 return d;
}
function useTick(ms){const[,s]=React.useState(0);React.useEffect(()=>{const i=setInterval(()=>s(x=>x+1),ms);return()=>clearInterval(i)},[ms])}
const ago=iso=>{const t=Date.parse(iso||"");return isFinite(t)?Math.max(0,Date.now()-t):0};
const mins=ms=>Math.max(1,Math.floor(ms/6e4));
const clock=ms=>{const s=Math.floor(ms/1e3);if(s>=3600)return`${Math.floor(s/3600)} h ${Math.floor(s%3600/60)} min`;return`${Math.floor(s/60)}:${String(s%60).padStart(2,"0")}`};
const money=v=>"$"+Number(v||0).toLocaleString("en-US",{minimumFractionDigits:2,maximumFractionDigits:2});

// ── Menu counts ───────────────────────────────────────────────────────────
function countFor(id,d){
 if(!d)return null;
 switch(id){
  case"viajes":return d.unassigned.n>0?{n:d.unassigned.n,tone:"hot",title:"Viajes sin conductor"}:null;
  case"soporte":return d.support.n>0?{n:d.support.n,tone:"hot",title:"Esperan respuesta"}:null;
  case"reservas":return d.reservations_open>0?{n:d.reservations_open,tone:"gold",title:"Reservas sin conductor en 24 h"}:null;
  case"drivers":return d.drivers.online>0?{n:d.drivers.online,label:`${d.drivers.online} en línea`,tone:"grey",title:"Conductores en línea"}:null;
  case"pagos":return d.payouts_failed.n>0?{n:d.payouts_failed.n,tone:"hot",title:"Pagos que fallaron"}:null;
  default:return null;
 }
}
function Count({c,rail,bumpKey}){
 const prev=React.useRef(c?c.n:0),[bump,setBump]=React.useState(false);
 React.useEffect(()=>{const n=c?c.n:0;if(n>prev.current){setBump(true);const t=setTimeout(()=>setBump(false),480);prev.current=n;return()=>clearTimeout(t)}prev.current=n},[c&&c.n,bumpKey]);// eslint-disable-line
 if(!c)return null;
 if(rail)return el("span",{className:`cp-dot ${c.tone==="grey"?"gold":c.tone}`,title:`${c.title}: ${c.n}`,"aria-label":`${c.title}: ${c.n}`,style:c.tone==="grey"?{display:"none"}:undefined});
 return el("span",{className:`cp-cnt ${c.tone}${bump?" bump":""}`,title:c.title},c.label||String(c.n));
}
function VerifCount({rail}){
 const q=useVerificationQueue();
 const n=q&&!q.loading&&!q.error&&Array.isArray(q.rows)?q.rows.filter(r=>r.status==="pending").length:0;// solo las que esperan revisión (434 → 213, 2026-11-18)
 return n>0?el(Count,{c:{n,tone:"grey",title:"Verificaciones pendientes"},rail}):null;
}
function PulseBadge({id,rail}){
 const d=usePulse();
 if(id==="mapa")return rail?el("span",{className:"cp-dot live",title:"En vivo"}):el("span",{className:"cp-live",title:"En vivo","aria-label":"En vivo"});
 if(id==="verificacion")return el(VerifCount,{rail});
 return el(Count,{c:countFor(id,d),rail});
}
function PulseDot({id}){
 const d=usePulse();const c=countFor(id,d);
 return c&&c.tone==="hot"?el("span",{className:"cp-gdot",title:`${c.title}: ${c.n}`,"aria-label":`${c.title}: ${c.n}`}):null;
}

// ── Sound: a short chime, only when something red starts or waits 5 min ──
const SOUND_KEY="cruise-panel-sound";
let audioCtx=null,lastSoundAt=0;
function soundOn(){try{return localStorage.getItem(SOUND_KEY)!=="0"}catch{return true}}
function unlockAudio(){try{const C=window.AudioContext||window.webkitAudioContext;if(!C)return;if(!audioCtx)audioCtx=new C();if(audioCtx.state==="suspended")audioCtx.resume()}catch{}}
if(typeof window!=="undefined"){window.addEventListener("pointerdown",unlockAudio,{passive:true});window.addEventListener("keydown",unlockAudio)}
function chime(){
 if(!soundOn()||!audioCtx||audioCtx.state!=="running")return;
 const now=Date.now();if(now-lastSoundAt<6e4)return;lastSoundAt=now;
 try{const t=audioCtx.currentTime;[[880,0],[1320,.14]].forEach(([f,d])=>{const o=audioCtx.createOscillator(),g=audioCtx.createGain();o.type="sine";o.frequency.value=f;g.gain.setValueAtTime(0,t+d);g.gain.linearRampToValueAtTime(.18,t+d+.02);g.gain.exponentialRampToValueAtTime(.0001,t+d+.32);o.connect(g).connect(audioCtx.destination);o.start(t+d);o.stop(t+d+.34)})}catch{}
}

// ── Notices on this phone (Web Push, services/panel_push.py) ─────────────
// iOS only lets a web app ask once it was added to the Home Screen and
// opened from its icon; the permission must be asked inside the tap.
function b64ToU8(s){const p="=".repeat((4-s.length%4)%4);const b=atob((s+p).replace(/-/g,"+").replace(/_/g,"/"));const u=new Uint8Array(b.length);for(let i=0;i<b.length;i++)u[i]=b.charCodeAt(i);return u}
function pushSupport(){try{const ios=/iP(hone|ad|od)/.test(navigator.userAgent)||(navigator.platform==="MacIntel"&&navigator.maxTouchPoints>1);const standalone=(window.matchMedia&&window.matchMedia("(display-mode: standalone)").matches)||navigator.standalone===true;if(!("serviceWorker"in navigator)||!("PushManager"in window)||!("Notification"in window))return ios&&!standalone?"install":"none";return"ok"}catch{return"none"}}
function deviceLabel(){const u=navigator.userAgent||"";return/iPhone/.test(u)?"iPhone":/iPad/.test(u)?"iPad":/Android/.test(u)?"Android":/Mac/.test(u)?"Mac":/Windows/.test(u)?"Windows":"Navegador"}
const errText=e=>e instanceof Error?e.message:String(e);
function PushControl(){
 const[st,setSt]=React.useState("checking"),[msg,setMsg]=React.useState(null),sub=React.useRef(null);
 React.useEffect(()=>{let off=false;(async()=>{const s=pushSupport();if(s!=="ok"){setSt(s);return}if(Notification.permission==="denied"){setSt("denied");return}
  try{const reg=await navigator.serviceWorker.getRegistration("/panel/");const ps=reg&&reg.pushManager?await reg.pushManager.getSubscription():null;if(off)return;sub.current=ps;setSt(ps?"on":"off")}catch{if(!off)setSt("off")}})();return()=>{off=true}},[]);
 const turnOn=async()=>{setMsg(null);let perm="default";try{perm=await Notification.requestPermission()}catch{}
  if(perm!=="granted"){setSt(perm==="denied"?"denied":"off");return}
  setSt("busy");
  try{const reg=await navigator.serviceWorker.register("/panel/push-sw.js",{scope:"/panel/"});await navigator.serviceWorker.ready;
   const k=await apiGet("/admin/panel/push/key",{retry:{maxAttempts:1}});
   let ps=await reg.pushManager.getSubscription();
   if(!ps)ps=await reg.pushManager.subscribe({userVisibleOnly:!0,applicationServerKey:b64ToU8(k.public_key)});
   await apiPost("/admin/panel/push/subscribe",{subscription:ps.toJSON(),label:deviceLabel()},{retry:{maxAttempts:1}});
   sub.current=ps;setSt("on");setMsg("Listo. Te llega un aviso de prueba.");
   apiPost("/admin/panel/push/test",{endpoint:ps.endpoint},{retry:{maxAttempts:1}}).catch(()=>{})
  }catch(e){setSt("off");setMsg(`No se pudo activar: ${errText(e)}`)}};
 const test=async()=>{setMsg(null);try{await apiPost("/admin/panel/push/test",{endpoint:sub.current.endpoint},{retry:{maxAttempts:1}});setMsg("Enviado. Llega en unos segundos.")}catch(e){setMsg(`No llegó: ${errText(e)}`)}};
 const turnOff=async()=>{setMsg(null);const ps=sub.current;try{if(ps){await apiPost("/admin/panel/push/unsubscribe",{endpoint:ps.endpoint},{retry:{maxAttempts:1}}).catch(()=>{});await ps.unsubscribe()}}catch{}sub.current=null;setSt("off")};
 if(st==="checking")return null;
 const T={
  off:["Avisos en este teléfono","Soporte y viajes sin conductor, aunque el teléfono esté bloqueado."],
  busy:["Activando…","Acepta el permiso si el teléfono lo pide."],
  on:["Avisos activados en este teléfono","Llegan como notificación, uno por tipo, con el número."],
  denied:["El teléfono bloqueó los avisos","Actívalos en Ajustes › Notificaciones › Dispatch y vuelve a abrir el panel."],
  install:["Para recibir avisos en el iPhone","En Safari: Compartir › Agregar a pantalla de inicio. Ábrelo desde ese ícono y toca Activar aquí."],
  none:["Este navegador no recibe avisos","En el iPhone usa Safari agregado a la pantalla de inicio; en la computadora, Chrome o Edge."],
 }[st];
 return el("div",{className:"cp-push"},el("b",null,T[0]),el("small",null,T[1]),
  st==="off"?el("div",{className:"row"},el("button",{type:"button",className:"cp-pbtn",onClick:turnOn},"Activar")):null,
  st==="on"?el("div",{className:"row"},el("button",{type:"button",className:"cp-pbtn",onClick:test},"Probar"),el("button",{type:"button",className:"cp-pbtn ghost",onClick:turnOff},"Apagar")):null,
  msg?el("span",{className:"cp-pmsg",role:"status"},msg):null);
}

// ── Header: sound + "Necesita atención" ───────────────────────────────────
const IC={
 bell:"M6 8a6 6 0 0 1 12 0c0 7 3 9 3 9H3s3-2 3-9M10 21h4",
 on:"M11 5 6 9H2v6h4l5 4zM15.5 8.5a5 5 0 0 1 0 7M19 5a10 10 0 0 1 0 14",
 off:"M11 5 6 9H2v6h4l5 4zM22 9l-6 6M16 9l6 6",
 chat:"M21 12a8 8 0 0 1-11.6 7.1L4 20l1-4.6A8 8 0 1 1 21 12z",
 clock:"M12 8v4l3 2M12 21a9 9 0 1 0 0-18 9 9 0 0 0 0 18z",
 cal:"M3 7h18v14H3zM3 11h18M8 3v4M16 3v4",
 wifi:"M2 8.8a15 15 0 0 1 20 0M5 12.6a10 10 0 0 1 14 0M8.5 16.4a5 5 0 0 1 7 0M12 20h.01",
 card:"M3 6h18v13H3zM3 10h18M16 15h2",
 x:"M18 6 6 18M6 6l12 12",
};
const svg=(d,size)=>el("svg",{width:size||17,height:size||17,viewBox:"0 0 24 24",fill:"none",stroke:"currentColor",strokeWidth:2,strokeLinecap:"round",strokeLinejoin:"round","aria-hidden":"true"},el("path",{d}));
function attention(d){
 if(!d)return[];
 const out=[];
 if(d.support.n>0){const f=d.support.first;out.push({k:"sup",tone:"hot",icon:IC.chat,title:d.support.n===1?`${f&&f.name||"Una persona"} espera respuesta`:`${d.support.n} personas esperan respuesta`,sub:`La que más lleva: ${mins(ago(d.support.oldest))} min`,to:d.support.n===1&&f?`/soporte/chat/${f.chat_id}`:"/soporte"})}
 if(d.unassigned.n>0){const f=d.unassigned.first;out.push({k:"una",tone:"hot",icon:IC.clock,title:d.unassigned.n===1&&f?`${f.reservation?"Reserva":"Viaje"} #${f.trip_id} sin conductor`:`${d.unassigned.n} viajes sin conductor`,sub:`El que más lleva: ${clock(ago(d.unassigned.oldest))}`,to:d.unassigned.n===1&&f?`/viajes/viaje/sql_${f.trip_id}`:"/viajes",state:{cruiseTab:"busca"}})}
 if(d.reservations_open>0)out.push({k:"res",tone:"gold",icon:IC.cal,title:`${d.reservations_open} ${d.reservations_open===1?"reserva":"reservas"} sin conductor`,sub:"En las próximas 24 h",to:"/viajes",state:{cruiseTab:"reservas"}});
 if(d.drivers.quiet>0)out.push({k:"sig",tone:"blue",icon:IC.wifi,title:`${d.drivers.quiet} ${d.drivers.quiet===1?"conductor":"conductores"} sin señal`,sub:`De ${d.drivers.online} en línea`,to:"/mapa"});
 if(d.payouts_failed.n>0)out.push({k:"pay",tone:"gold",icon:IC.card,title:`${d.payouts_failed.n} ${d.payouts_failed.n===1?"pago falló":"pagos fallaron"}`,sub:`${money(d.payouts_failed.amount)} sin enviar`,to:"/pagos"});
 return out;
}
function PulseHeader({rail}){
 const d=usePulse();const navigate=useNavigate();useTick(3e4);
 const[open,setOpen]=React.useState(false),[pos,setPos]=React.useState(null),[sound,setSound]=React.useState(soundOn());
 const btn=React.useRef(null);
 const urgent=d?d.support.n+d.unassigned.n:0;
 const toggle=()=>{if(open){setOpen(false);return}const r=btn.current&&btn.current.getBoundingClientRect();setPos(r?{top:r.bottom+8,left:Math.max(12,Math.min(window.innerWidth-352,r.left-8))}:{top:60,left:12});setOpen(true)};
 React.useEffect(()=>{if(!open)return;const k=e=>{if(e.key==="Escape")setOpen(false)};const c=e=>{if(!e.target.closest||!e.target.closest(".cp-feed,.cp-bell"))setOpen(false)};window.addEventListener("keydown",k);window.addEventListener("pointerdown",c);return()=>{window.removeEventListener("keydown",k);window.removeEventListener("pointerdown",c)}},[open]);
 const flip=()=>{const v=!sound;setSound(v);try{localStorage.setItem(SOUND_KEY,v?"1":"0")}catch{}if(v)unlockAudio()};
 const items=attention(d);
 return el("span",{style:{display:"flex",flexDirection:rail?"column":"row",alignItems:"center",gap:2,marginLeft:rail?0:"auto"}},
  rail?null:el("button",{type:"button",className:sound?"cp-hbtn on":"cp-hbtn",onClick:flip,"aria-label":sound?"Silenciar avisos":"Activar sonido de avisos",title:sound?"Sonido de avisos: activado":"Sonido de avisos: apagado"},svg(sound?IC.on:IC.off)),
  el("button",{type:"button",ref:btn,className:"cp-hbtn cp-bell","aria-label":`Necesita atención${urgent?`: ${urgent}`:""}`,"aria-expanded":open,onClick:toggle,title:"Necesita atención"},svg(IC.bell),urgent>0?el("span",{className:"n"},urgent>99?"99+":String(urgent)):null),
  open&&pos?el("div",{className:"cp-feed",role:"dialog","aria-label":"Necesita atención",style:{top:pos.top,left:pos.left}},
   el("h4",null,"Necesita atención"),
   items.length===0?el("div",{style:{padding:"10px 8px 12px",fontSize:13,color:"rgba(244,244,245,.55)"}},"Todo en orden."):
   items.map(it=>el("button",{type:"button",key:it.k,className:"cp-fi",onClick:()=>{setOpen(false);navigate(it.to,it.state?{state:it.state}:undefined)}},el("span",{className:`cp-w ${it.tone}`},svg(it.icon,15)),el("span",null,el("b",null,it.title),el("small",null,it.sub)))),
   rail?el("button",{type:"button",className:"cp-fi",onClick:flip},el("span",{className:"cp-w grey"},svg(sound?IC.on:IC.off,15)),el("span",null,el("b",null,sound?"Sonido activado":"Sonido apagado"),el("small",null,"Toca para cambiarlo"))):null,
   el("div",{className:"cp-sep"}),el(PushControl)):null);
}

// ── The two notices ───────────────────────────────────────────────────────
const CLOSED_FOR=5*6e4,LONG_WAIT=5*6e4,SHOW_FOR=8e3;
const baseTitle=typeof document!=="undefined"?document.title.replace(/^\(\d+\+?\)\s*/,""):"Cruise Dispatch";
let favDefault=null,favAlert=null;
function setFavicon(alert){
 try{const link=document.querySelector('link[rel="icon"]');if(!link)return;if(favDefault===null)favDefault=link.href;
  if(!alert){if(link.href!==favDefault)link.href=favDefault;return}
  if(favAlert){link.href=favAlert;return}
  const img=new Image();img.onload=()=>{try{const c=document.createElement("canvas");c.width=c.height=64;const g=c.getContext("2d");g.drawImage(img,0,0,64,64);g.beginPath();g.arc(50,14,13,0,Math.PI*2);g.fillStyle="#FF6B57";g.fill();g.lineWidth=4;g.strokeStyle="#0B0B0F";g.stroke();favAlert=c.toDataURL("image/png");link.href=favAlert}catch{}};img.src=favDefault}catch{}
}
function PulseToasts({path}){
 const d=usePulse();const navigate=useNavigate();useTick(1e3);
 const[shown,setShown]=React.useState({sup:false,una:false}),[pulse,setPulse]=React.useState({sup:0,una:0});
 const mem=React.useRef({sup:{n:null,closed:0,long:false,hide:null},una:{n:null,closed:0,long:false,hide:null}});
 const here=k=>k==="sup"?/^\/soporte/.test(path||""):/^\/viajes\/?$|^\/viajes\/categoria/.test(path||"");
 React.useEffect(()=>{
  if(!d)return;
  const total=d.support.n+d.unassigned.n;
  document.title=total>0?`(${total>99?"99+":total}) ${baseTitle}`:baseTitle;
  setFavicon(total>0);
  const cats=[["sup",d.support],["una",d.unassigned]];
  for(const[k,c]of cats){
   const m=mem.current[k],prev=m.n,n=c.n;
   const long=n>0&&ago(c.oldest)>=LONG_WAIT;
   const crossedLong=long&&!m.long;m.long=long;
   const started=prev!==null&&prev===0&&n>0;
   const more=prev!==null&&n>prev;
   const first=prev===null&&n>0;
   m.n=n;
   if(n===0){m.long=false;if(shown[k])setShown(s=>Object.assign({},s,{[k]:false}));continue}
   if(started||crossedLong)chime();
   const open=(started||more||first||crossedLong)&&!here(k)&&(crossedLong||Date.now()>=m.closed);
   if(open){
    // Already up: the same notice counts and jumps; hidden: it slides in again.
    setPulse(p=>Object.assign({},p,{[k]:shown[k]?p[k]+1:0}));
    setShown(s=>Object.assign({},s,{[k]:true}));
    clearTimeout(m.hide);m.hide=setTimeout(()=>setShown(s=>Object.assign({},s,{[k]:false})),SHOW_FOR);
   }
  }
 },[d]);// eslint-disable-line
 React.useEffect(()=>{for(const k of["sup","una"])if(here(k)&&shown[k])setShown(s=>Object.assign({},s,{[k]:false}))},[path]);// eslint-disable-line
 React.useEffect(()=>()=>{clearTimeout(mem.current.sup.hide);clearTimeout(mem.current.una.hide);document.title=baseTitle;setFavicon(false)},[]);
 if(!d)return null;
 const close=k=>{mem.current[k].closed=Date.now()+CLOSED_FOR;clearTimeout(mem.current[k].hide);setShown(s=>Object.assign({},s,{[k]:false}))};
 const go=(k,to,state)=>{close(k);mem.current[k].closed=0;navigate(to,state?{state}:undefined)};
 const list=[];
 if(shown.sup&&d.support.n>0&&!here("sup")){
  const one=d.support.n===1,f=d.support.first;
  list.push(el("div",{key:`sup-${pulse.sup}`,className:pulse.sup?"cp-toast pulse":"cp-toast",role:"status"},
   el("div",{className:"in"},el("span",{className:"tw"},svg(IC.chat,19)),
    el("span",{style:{flex:1,minWidth:0}},el("b",{className:"t"},one?null:el("span",{className:"tn"},d.support.n>99?"99+":String(d.support.n)),one?`${f&&f.name||"Alguien"} escribió a soporte`:"personas esperan respuesta"),
     el("small",null,one?`Espera hace ${mins(ago(d.support.oldest))} min`:`La que más lleva: ${mins(ago(d.support.oldest))} min`),
     el("button",{type:"button",className:"go",onClick:()=>go("sup",one&&f?`/soporte/chat/${f.chat_id}`:"/soporte")},one?"Responder":"Abrir la bandeja")),
    el("button",{type:"button",className:"x","aria-label":"Cerrar aviso",onClick:()=>close("sup")},svg(IC.x,14))),
   el("div",{className:"bar",key:`b${pulse.sup}`})));
 }
 if(shown.una&&d.unassigned.n>0&&!here("una")){
  const one=d.unassigned.n===1,f=d.unassigned.first;
  list.push(el("div",{key:`una-${pulse.una}`,className:pulse.una?"cp-toast pulse":"cp-toast",role:"status"},
   el("div",{className:"in"},el("span",{className:"tw"},svg(IC.clock,19)),
    el("span",{style:{flex:1,minWidth:0}},el("b",{className:"t"},one?null:el("span",{className:"tn"},d.unassigned.n>99?"99+":String(d.unassigned.n)),one&&f?(f.reservation?`Reserva #${f.trip_id} sin conductor`:`Viaje #${f.trip_id} lleva ${mins(ago(f.since))} min sin conductor`):"viajes sin conductor"),
     el("small",null,one&&f?f.label:`El que más lleva: ${clock(ago(d.unassigned.oldest))}`),
     el("button",{type:"button",className:"go",onClick:()=>go("una",one&&f?`/viajes/viaje/sql_${f.trip_id}`:"/viajes",one?null:{cruiseTab:"busca"})},one?(f&&f.reservation?"Avisar a los conductores":"Despachar"):"Ver los viajes")),
    el("button",{type:"button",className:"x","aria-label":"Cerrar aviso",onClick:()=>close("una")},svg(IC.x,14))),
   el("div",{className:"bar",key:`b${pulse.una}`})));
 }
 return list.length?el("div",{className:"cp-toasts","aria-live":"polite"},list):null;
}

export{PulseBadge,PulseDot,PulseHeader,PulseToasts};
