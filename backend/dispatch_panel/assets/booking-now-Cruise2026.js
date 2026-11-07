/*! guard-pin panel_booking_now_guard_test: "Pidiendo ahora" (owner 2026-11-07, dibujo https://claude.ai/artifact/3JUCi2rj3pLnXiYArMAzYA) - chunk escrito a mano, sin fuente React (CLAUDE.md #30); lo cargan la ruta /pidiendo-ahora y el número del menú en index-CuQT_62K.js. Solo quien escribió o eligió una dirección sale en la lista y el mapa; con la app abierta es un número, nunca un punto. */
import{r as React,j as jsxRuntime,y as useNavigate}from"./vendor-react-DprhJQz-.js";
import{m as mapboxgl}from"./vendor-mapbox-ComAnvan.js";
import{W as apiGet,L as apiPost}from"./index-CuQT_62K.js";
import{N as navyStyle,a as applyNavyGold,r as refineRoads,h as hideTraffic}from"./mapNavyGold-CiIxy5Vj.js";
import{m as getMapboxToken}from"./mapboxToken-DDoCRQix.js";

const h=jsxRuntime.jsx,hs=jsxRuntime.jsxs;
const GOLD="#E8C547",GREEN="#22C55E";
const POLL_MS=3000;
const LEAVE_MS=450;
const DEFAULT_CENTER=[-86.80,33.45];

const CSS=`
.bn-page{display:flex;flex-direction:column;gap:14px;min-width:0}
.bn-top{display:flex;flex-wrap:wrap;align-items:center;gap:12px}
.bn-title{font-size:24px;font-weight:600;color:#fff;margin:0}
.bn-live{display:inline-flex;align-items:center;gap:7px;font-size:12px;color:${GREEN};font-weight:600;background:rgba(34,197,94,.1);border:1px solid rgba(34,197,94,.3);padding:3px 10px;border-radius:999px}
.bn-live i{width:7px;height:7px;border-radius:50%;background:${GREEN};animation:bn-blink 1.6s ease-in-out infinite}
.bn-live.off{color:#e57373;background:rgba(229,115,115,.1);border-color:rgba(229,115,115,.3)}
.bn-live.off i{background:#e57373;animation:none}
.bn-counts{margin-left:auto;display:flex;flex-wrap:wrap;gap:8px}
.bn-cnt{background:#1c1c24;border:1px solid rgba(255,255,255,.08);border-radius:12px;padding:6px 12px;font-size:12px;color:#9a9aa4}
.bn-cnt b{color:#fff;font-size:15px;margin-right:5px}
.bn-cnt.g b{color:${GOLD}}
.bn-body{display:grid;grid-template-columns:minmax(330px,430px) minmax(0,1fr);gap:14px;height:calc(100vh - 190px);min-height:520px}
.bn-list{display:flex;flex-direction:column;gap:10px;overflow-y:auto;padding-right:4px;min-width:0}
.bn-map{position:relative;border-radius:16px;overflow:hidden;border:1px solid rgba(255,255,255,.08);background:#0f1626;min-height:340px}
.bn-map>.bn-canvas{position:absolute;inset:0}
.bn-legend{position:absolute;left:12px;bottom:28px;z-index:2;background:rgba(28,28,36,.92);border:1px solid rgba(255,255,255,.08);border-radius:12px;padding:8px 12px;font-size:11px;color:#9a9aa4;display:grid;gap:4px;pointer-events:none}
.bn-legend span{display:flex;align-items:center;gap:7px}
.bn-card{background:#1c1c24;border:1px solid rgba(255,255,255,.08);border-radius:16px;padding:12px 14px;display:grid;gap:9px;cursor:pointer;transition:border-color .2s,box-shadow .2s,background .35s;animation:bn-in .7s cubic-bezier(.22,1,.36,1) both}
.bn-card:hover{border-color:rgba(232,197,71,.3)}
.bn-card.sel{border-color:rgba(232,197,71,.55);box-shadow:0 0 0 1px rgba(232,197,71,.25) inset}
.bn-card.won{border-color:rgba(34,197,94,.5);background:linear-gradient(0deg,rgba(34,197,94,.06),rgba(34,197,94,.06)),#1c1c24}
.bn-card.leaving{animation:bn-out ${LEAVE_MS}ms ease-in both;pointer-events:none}
.bn-who{display:flex;align-items:center;gap:10px;min-width:0}
.bn-av{width:34px;height:34px;border-radius:50%;background:#23232d;display:grid;place-items:center;font-size:12px;font-weight:700;color:#d6d6dc;flex:none;overflow:hidden}
.bn-av img{width:100%;height:100%;object-fit:cover}
.bn-nm{font-weight:600;font-size:13.5px;color:#fff;display:flex;align-items:center;gap:6px;min-width:0}
.bn-nm>span:first-child{overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.bn-sub{font-size:11.5px;color:#9a9aa4}
.bn-test{font-size:9.5px;font-weight:700;letter-spacing:.4px;color:${GOLD};border:1px solid rgba(232,197,71,.45);border-radius:999px;padding:1px 6px;flex:none}
.bn-ago{margin-left:auto;font-size:11px;color:#7a7a84;text-align:right;flex:none;line-height:1.35}
.bn-steps{display:flex;align-items:center;gap:6px;font-size:11px;color:#7a7a84}
.bn-st{display:inline-flex;align-items:center;gap:5px;white-space:nowrap}
.bn-st i{width:8px;height:8px;border-radius:50%;border:1.5px solid #7a7a84}
.bn-st.done{color:#e6e6ea}.bn-st.done i{background:${GOLD};border-color:${GOLD}}
.bn-st.now{color:${GOLD};font-weight:600}.bn-st.now i{border-color:${GOLD};box-shadow:0 0 0 3px rgba(232,197,71,.2)}
.bn-dash{flex:1;height:1px;background:rgba(255,255,255,.12);max-width:26px}
.bn-dash.done{background:#c9a83a}
.bn-rt{display:grid;grid-template-columns:14px minmax(0,1fr);gap:3px 9px;font-size:12.5px;align-items:center;color:#e6e6ea}
.bn-rt>span{min-width:0;overflow-wrap:anywhere}
.bn-rg{width:12px;height:12px;border-radius:50%;border:2.5px solid ${GOLD};display:grid;place-items:center}
.bn-rg::after{content:"";width:4px;height:4px;border-radius:50%;background:${GOLD}}
.bn-rw{width:12px;height:12px;border-radius:50%;border:2.5px solid #fff}
.bn-rn{width:12px;height:12px;border-radius:50%;border:2px dashed #7a7a84}
.bn-vl{width:2px;height:8px;margin-left:5px;background:linear-gradient(${GOLD},#fff)}
.bn-vl.off{background:rgba(255,255,255,.12)}
.bn-wait{color:#7a7a84;font-style:italic}
.bn-typing{display:inline-flex;gap:3px;vertical-align:middle;margin-left:4px}
.bn-typing i{width:4px;height:4px;border-radius:50%;background:${GOLD};animation:bn-dot 1.2s infinite}
.bn-typing i:nth-child(2){animation-delay:.15s}.bn-typing i:nth-child(3){animation-delay:.3s}
.bn-acts{display:flex;flex-wrap:wrap;gap:6px}
.bn-b{height:30px;padding:0 12px;border-radius:9px;font-size:12px;font-weight:600;display:inline-flex;align-items:center;gap:6px;border:1px solid rgba(255,255,255,.1);color:#e6e6ea;background:transparent;cursor:pointer;text-decoration:none;font-family:inherit}
.bn-b:hover{background:rgba(255,255,255,.05)}
.bn-b.p{background:${GOLD};border-color:${GOLD};color:#111}
.bn-b.p:hover{background:#f0d060}
.bn-b:disabled{opacity:.5;cursor:default}
.bn-won{font-size:12.5px;color:${GREEN};font-weight:600}
.bn-more{font-size:12px;color:#9a9aa4;background:#101014;border:1px dashed rgba(255,255,255,.1);border-radius:12px;padding:9px 12px}
.bn-empty{display:grid;place-items:center;text-align:center;gap:6px;padding:40px 16px;color:#9a9aa4;font-size:13px;background:#1c1c24;border:1px solid rgba(255,255,255,.08);border-radius:16px}
.bn-empty b{color:#fff;font-size:14px}
.bn-err{font-size:12px;color:#e57373}
.bn-pin{display:grid;justify-items:center;cursor:pointer}
.bn-pin .bn-tag{background:#1c1c24;border:1px solid rgba(232,197,71,.4);border-radius:999px;padding:3px 9px 3px 4px;font:600 11.5px Inter,system-ui,sans-serif;color:#fff;display:flex;align-items:center;gap:6px;white-space:nowrap;box-shadow:0 4px 14px rgba(0,0,0,.45);transition:background .2s,color .2s}
.bn-pin .bn-tag b{width:20px;height:20px;border-radius:50%;background:#23232d;display:grid;place-items:center;font-size:9.5px}
.bn-pin.sel .bn-tag{background:${GOLD};color:#111;border-color:${GOLD}}
.bn-pin.sel .bn-tag b{background:rgba(0,0,0,.15)}
.bn-pin .bn-stem{width:2px;height:10px;background:${GOLD}}
.bn-pin .bn-dot{width:12px;height:12px;border-radius:50%;background:${GOLD};border:2.5px solid #0f1626;position:relative}
.bn-pin .bn-dot::after{content:"";position:absolute;inset:-9px;border-radius:50%;border:2px solid ${GOLD};animation:bn-ping 2.2s ease-out infinite}
.bn-pin.won .bn-tag{border-color:${GREEN}}
.bn-pin.won .bn-stem,.bn-pin.won .bn-dot{background:${GREEN}}
.bn-pin.won .bn-dot::after{border-color:${GREEN}}
.bn-dest{width:14px;height:14px;border-radius:50%;border:3px solid #fff;background:#0f1626}
.bn-modal{position:fixed;inset:0;z-index:60;background:rgba(0,0,0,.6);display:grid;place-items:center;padding:16px}
.bn-dlg{width:min(460px,100%);background:#1c1c24;border:1px solid rgba(255,255,255,.1);border-radius:16px;padding:18px;display:grid;gap:12px;box-shadow:0 20px 60px rgba(0,0,0,.5)}
.bn-dlg h3{margin:0;font-size:15px;color:#fff}
.bn-dlg p{margin:0;font-size:12.5px;color:#9a9aa4}
.bn-dlg textarea{width:100%;min-height:110px;resize:vertical;background:#101014;border:1px solid rgba(255,255,255,.1);border-radius:12px;padding:10px 12px;color:#fff;font:13px/1.45 Inter,system-ui,sans-serif;box-sizing:border-box}
.bn-dlg textarea:focus{outline:none;border-color:rgba(232,197,71,.6)}
.bn-chips{display:flex;flex-wrap:wrap;gap:6px}
.bn-chip{font-size:11.5px;color:#d6d6dc;background:#23232d;border:1px solid rgba(255,255,255,.08);border-radius:999px;padding:4px 10px;cursor:pointer;font-family:inherit}
.bn-chip:hover{border-color:rgba(232,197,71,.45)}
.bn-row{display:flex;justify-content:flex-end;gap:8px}
@keyframes bn-blink{50%{opacity:.25}}
@keyframes bn-dot{0%,60%,100%{opacity:.25;transform:none}30%{opacity:1;transform:translateY(-2px)}}
@keyframes bn-ping{0%{opacity:.7;transform:scale(.9)}100%{opacity:0;transform:scale(1.35)}}
@keyframes bn-in{from{opacity:0;transform:translateY(-10px)}to{opacity:1;transform:none}}
@keyframes bn-out{to{opacity:0;transform:translateY(-6px) scale(.98)}}
@media (max-width:980px){.bn-body{grid-template-columns:minmax(0,1fr);height:auto}.bn-map{order:-1;height:340px}.bn-list{overflow:visible}}
`;

function injectCss(){if(typeof document==="undefined"||document.getElementById("bn-css"))return;const el=document.createElement("style");el.id="bn-css";el.textContent=CSS;document.head.appendChild(el)}

function initials(r){const a=String(r.first_name??"").trim(),b=String(r.last_name??"").trim();const s=((a[0]??"")+(b[0]??"")).toUpperCase();return s||String(r.name??"?").trim().slice(0,2).toUpperCase()||"?"}
function shortName(r){const a=String(r.first_name??"").trim(),b=String(r.last_name??"").trim();return a?(b?`${a} ${b[0]}.`:a):String(r.name??"")}
function fmtPhone(p){const d=String(p??"").replace(/\D/g,"");const t=d.length===11&&d[0]==="1"?d.slice(1):d;return t.length===10?`(${t.slice(0,3)}) ${t.slice(3,6)}-${t.slice(6)}`:String(p??"")}
function ago(sec){if(!Number.isFinite(sec)||sec<5)return"ahora";if(sec<60)return`hace ${Math.floor(sec)} s`;const m=Math.floor(sec/60);return m<60?`hace ${m} min`:`hace ${Math.floor(m/60)} h`}
function building(sec){if(!Number.isFinite(sec))return"";if(sec<60)return`armando hace ${Math.max(1,Math.floor(sec))} s`;const m=Math.floor(sec/60);return m<60?`armando hace ${m} min`:`armando hace ${Math.floor(m/60)} h`}
function secondsSince(iso,nowMs){const t=Date.parse(iso??"");return Number.isFinite(t)?Math.max(0,(nowMs-t)/1000):NaN}
function lowerFirstLetter(q){const i=q.search(/\p{L}/u);return i<0?q:q.slice(0,i)+q[i].toLowerCase()+q.slice(i+1)}
function hasPoint(p){return p!=null&&Number.isFinite(p.lat)&&Number.isFinite(p.lng)}

function arc(a,b,n=24){const[x1,y1]=[a.lng,a.lat],[x2,y2]=[b.lng,b.lat];const mx=(x1+x2)/2,my=(y1+y2)/2,dx=x2-x1,dy=y2-y1;const cx=mx-dy*.18,cy=my+dx*.18;const pts=[];for(let i=0;i<=n;i++){const t=i/n,u=1-t;pts.push([u*u*x1+2*u*t*cx+t*t*x2,u*u*y1+2*u*t*cy+t*t*y2])}return pts}

function useBookingNow(){
 const[state,setState]=React.useState({loading:true,error:null,data:null,offset:0});
 React.useEffect(()=>{let alive=true,timer=null,inflight=false;
  const load=async()=>{inflight=true;try{const data=await apiGet("/admin/riders/booking-now",{retry:{maxAttempts:1},timeoutMs:9000});if(!alive)return;const offset=Date.parse(data?.now??"")-Date.now();setState({loading:false,error:null,data,offset:Number.isFinite(offset)?offset:0})}catch(err){if(!alive)return;setState(s=>({...s,loading:false,error:err instanceof Error?err.message:String(err)}))}finally{inflight=false;if(alive){clearTimeout(timer);timer=setTimeout(tick,POLL_MS)}}};
  const tick=()=>{if(document.visibilityState==="visible")load();else timer=setTimeout(tick,POLL_MS)};
  const onVis=()=>{if(document.visibilityState==="visible"&&!inflight){clearTimeout(timer);load()}};
  load();document.addEventListener("visibilitychange",onVis);
  return()=>{alive=false;clearTimeout(timer);document.removeEventListener("visibilitychange",onVis)}},[]);
 return state;
}

function useClock(offset){const[now,setNow]=React.useState(()=>Date.now()+offset);React.useEffect(()=>{setNow(Date.now()+offset);const t=setInterval(()=>setNow(Date.now()+offset),1000);return()=>clearInterval(t)},[offset]);return now}

/* A card that leaves (the rider closed the app, or asked for the ride) fades
   out in its own place instead of vanishing. */
function useWithLeaving(list){
 const[leaving,setLeaving]=React.useState([]);
 const last=React.useRef([]),timers=React.useRef([]);
 React.useEffect(()=>{const ids=new Set(list.map(r=>r.id));const gone=last.current.map((r,i)=>({r,i})).filter(x=>!ids.has(x.r.id));last.current=list;
  if(gone.length){setLeaving(l=>[...l.filter(x=>!ids.has(x.r.id)&&!gone.some(g=>g.r.id===x.r.id)),...gone]);
   timers.current.push(setTimeout(()=>setLeaving(l=>l.filter(x=>!gone.some(g=>g.r.id===x.r.id))),LEAVE_MS))}
  else setLeaving(l=>l.some(x=>ids.has(x.r.id))?l.filter(x=>!ids.has(x.r.id)):l)},[list]);
 React.useEffect(()=>()=>{for(const t of timers.current)clearTimeout(t)},[]);
 const out=list.map(r=>({r,leaving:false}));
 for(const x of leaving.slice().sort((a,b)=>a.i-b.i))out.splice(Math.min(x.i,out.length),0,{r:x.r,leaving:true});
 return out;
}

function Steps({rider}){
 const st=rider.stage;
 const pickup=st==="pickup"||st==="dropoff",dropoff=st==="dropoff";
 const mid=st==="typing"?"Escribiendo":"Recogida";
 return hs("div",{className:"bn-steps",children:[
  hs("span",{className:"bn-st done",children:[h("i",{}),"App abierta"]}),
  h("span",{className:`bn-dash${pickup||st==="typing"?" done":""}`}),
  hs("span",{className:`bn-st ${pickup&&!dropoff?"now":pickup?"done":"now"}`,children:[h("i",{}),mid]}),
  h("span",{className:`bn-dash${dropoff?" done":""}`}),
  hs("span",{className:`bn-st${dropoff?" now":""}`,children:[h("i",{}),"Destino"]})]});
}

function Typing({text}){return hs("span",{className:"bn-wait",children:[text,hs("span",{className:"bn-typing",children:[h("i",{}),h("i",{}),h("i",{})]})]})}

function Route({rider}){
 const{stage,typing,pickup,dropoff}=rider;
 if(stage==="typing")return hs("div",{className:"bn-rt",children:[h("span",{className:"bn-rn"}),h(Typing,{text:typing==="dropoff"?"Escribiendo el destino":"Escribiendo la recogida"})]});
 const pick=pickup?.address||(hasPoint(pickup)?`${pickup.lat.toFixed(5)}, ${pickup.lng.toFixed(5)}`:"Recogida elegida");
 let second;
 if(stage==="dropoff")second=h("span",{children:dropoff?.address||(hasPoint(dropoff)?`${dropoff.lat.toFixed(5)}, ${dropoff.lng.toFixed(5)}`:"Ya eligió el destino")});
 else second=h(Typing,{text:typing==="dropoff"?"Escribiendo el destino":"Eligiendo el destino"});
 return hs("div",{className:"bn-rt",children:[h("span",{className:"bn-rg"}),h("span",{children:pick}),h("span",{className:`bn-vl${stage==="dropoff"?"":" off"}`}),h("span",{}),h("span",{className:stage==="dropoff"?"bn-rw":"bn-rn"}),second]});
}

function Card({rider,leaving,selected,nowMs,onSelect,onCreate,onChat,onProfile,onTrip}){
 const trip=rider.trip;
 const cls=`bn-card${selected?" sel":""}${trip?" won":""}${leaving?" leaving":""}`;
 const stop=fn=>e=>{e.stopPropagation();fn()};
 const reserved=trip&&String(trip.status??"").startsWith("scheduled");
 return hs("div",{className:cls,onClick:()=>onSelect(rider.id),children:[
  hs("div",{className:"bn-who",children:[
   h("div",{className:"bn-av",children:rider.photo_url?h("img",{src:rider.photo_url,alt:""}):initials(rider)}),
   hs("div",{style:{minWidth:0},children:[
    hs("div",{className:"bn-nm",children:[h("span",{children:rider.name}),rider.is_test?h("span",{className:"bn-test",children:"PRUEBA"}):null]}),
    h("div",{className:"bn-sub",children:[rider.rating?`★ ${Number(rider.rating).toFixed(1)}`:null,`${rider.trips} ${rider.trips===1?"viaje":"viajes"}`,rider.phone&&!trip?fmtPhone(rider.phone):null].filter(Boolean).join(" · ")})]}),
   hs("div",{className:"bn-ago",children:[ago(secondsSince(trip?trip.created_at:rider.last_at,nowMs)),trip?null:h("br",{}),trip?null:building(secondsSince(rider.started_at,nowMs))]})]}),
  trip?h("div",{className:"bn-won",children:reserved?`✓ Reservó el viaje #${trip.id}`:`✓ Pidió el viaje #${trip.id} · buscando conductor`}):h(Steps,{rider}),
  trip?null:h(Route,{rider}),
  h("div",{className:"bn-acts",children:trip?[h("button",{type:"button",className:"bn-b",onClick:stop(()=>onTrip(trip.id)),children:`Abrir viaje #${trip.id}`},"t")]:[
   rider.stage!=="typing"?h("button",{type:"button",className:"bn-b p",onClick:stop(()=>onCreate(rider)),children:"Crear viaje"},"c"):null,
   h("button",{type:"button",className:`bn-b${rider.stage==="typing"?" p":""}`,onClick:stop(()=>onChat(rider)),children:"Chatear"},"m"),
   rider.phone?h("a",{className:"bn-b",href:`tel:${String(rider.phone).replace(/[^\d+]/g,"")}`,onClick:e=>e.stopPropagation(),children:"Llamar"},"l"):null,
   h("button",{type:"button",className:"bn-b",onClick:stop(()=>onProfile(rider)),children:"Ver perfil"},"p")]})]});
}

function ChatModal({rider,onClose,onOpenChat}){
 const first=String(rider.first_name??"").trim();
 const[text,setText]=React.useState(first?`Hola ${first}, `:"Hola, ");
 const[sending,setSending]=React.useState(false),[error,setError]=React.useState(null);
 const ref=React.useRef(null);
 React.useEffect(()=>{const el=ref.current;if(el){el.focus();el.setSelectionRange(el.value.length,el.value.length)}const esc=e=>{if(e.key==="Escape")onClose()};window.addEventListener("keydown",esc);return()=>window.removeEventListener("keydown",esc)},[]);
 const quick=["¿Te ayudamos a pedir tu viaje?","Tenemos conductores cerca de ti ahora mismo.","Si tienes alguna duda con el precio, escríbenos aquí."];
 const send=async()=>{const message=text.trim();if(!message||sending)return;setSending(true);setError(null);try{const res=await apiPost(`/admin/users/${rider.id}/support-chat`,{message},{retry:{maxAttempts:1}});onOpenChat(res.chat_id)}catch(err){setSending(false);setError(err instanceof Error?err.message:String(err))}};
 return h("div",{className:"bn-modal",onMouseDown:e=>{if(e.target===e.currentTarget)onClose()},children:hs("div",{className:"bn-dlg",role:"dialog","aria-modal":"true",children:[
  h("h3",{children:`Escribirle a ${shortName(rider)}`}),
  h("p",{children:"Le llega al chat de soporte de su app, con una burbuja en la pantalla donde esté. El asistente automático no le responde mientras hablas tú."}),
  h("textarea",{ref,value:text,onChange:e=>setText(e.target.value),onKeyDown:e=>{if(e.key==="Enter"&&(e.ctrlKey||e.metaKey))send()},maxLength:2000}),
  h("div",{className:"bn-chips",children:quick.map(q=>h("button",{type:"button",className:"bn-chip",onClick:()=>setText(t=>{const base=t.trimEnd();return base.endsWith(",")?`${base} ${lowerFirstLetter(q)}`:`${base} ${q}`}),children:q},q))}),
  error?h("div",{className:"bn-err",children:error}):null,
  hs("div",{className:"bn-row",children:[h("button",{type:"button",className:"bn-b",onClick:onClose,children:"Cancelar"}),h("button",{type:"button",className:"bn-b p",disabled:sending||!text.trim(),onClick:send,children:sending?"Enviando…":"Enviar y abrir el chat"})]})]})});
}

function BookingMap({riders,selectedId,onSelect}){
 const box=React.useRef(null),mapRef=React.useRef(null),markers=React.useRef(new Map()),known=React.useRef(new Set()),touched=React.useRef(0);
 const[ready,setReady]=React.useState(false);
 const token=getMapboxToken();
 React.useEffect(()=>{const el=box.current;if(!el||!token)return;mapboxgl.accessToken=token;
  const map=new mapboxgl.Map({container:el,style:navyStyle,center:DEFAULT_CENTER,zoom:9,bearing:0,pitch:0,maxPitch:0,dragRotate:false,pitchWithRotate:false,touchPitch:false,attributionControl:true});
  mapRef.current=map;map.addControl(new mapboxgl.NavigationControl({showCompass:false}),"top-right");
  const mark=e=>{if(e&&e.originalEvent)touched.current=Date.now()};
  map.on("dragstart",mark);map.on("zoomstart",mark);
  map.on("load",()=>{if(mapRef.current!==map)return;map.resize();applyNavyGold(map);refineRoads(map);hideTraffic(map);
   map.addSource("bn-routes",{type:"geojson",lineMetrics:true,data:{type:"FeatureCollection",features:[]}});
   map.addLayer({id:"bn-route-line",type:"line",source:"bn-routes",layout:{"line-cap":"round","line-join":"round"},paint:{"line-width":["case",["==",["get","sel"],1],5,3.5],"line-opacity":["case",["==",["get","sel"],1],1,.6],"line-gradient":["interpolate",["linear"],["line-progress"],0,GOLD,1,"#FFFFFF"]}});
   setReady(true)});
  const ro=typeof ResizeObserver==="undefined"?null:new ResizeObserver(()=>map.resize());ro?.observe(el);
  return()=>{ro?.disconnect();for(const m of markers.current.values()){m.pin.remove();m.dest?.remove()}markers.current.clear();known.current.clear();mapRef.current=null;setReady(false);map.remove()}},[token]);

 React.useEffect(()=>{const map=mapRef.current;if(!map||!ready)return;
  const live=new Set();const features=[];
  for(const r of riders){if(!hasPoint(r.pickup))continue;live.add(r.id);
   let m=markers.current.get(r.id);
   if(!m){const el=document.createElement("div");el.className="bn-pin";const tag=document.createElement("div");tag.className="bn-tag";const av=document.createElement("b");const nm=document.createElement("span");tag.append(av,nm);const stem=document.createElement("div");stem.className="bn-stem";const dot=document.createElement("div");dot.className="bn-dot";el.append(tag,stem,dot);
    const id=r.id;el.addEventListener("click",ev=>{ev.stopPropagation();onSelect(id)});
    m={el,av,nm,pin:new mapboxgl.Marker({element:el,anchor:"bottom"}).setLngLat([r.pickup.lng,r.pickup.lat]).addTo(map),dest:null};markers.current.set(r.id,m)}
   m.pin.setLngLat([r.pickup.lng,r.pickup.lat]);m.av.textContent=initials(r);m.nm.textContent=shortName(r);
   m.el.classList.toggle("sel",r.id===selectedId);m.el.classList.toggle("won",!!r.trip);m.el.style.zIndex=r.id===selectedId?"3":"1";
   if(hasPoint(r.dropoff)){if(!m.dest){const d=document.createElement("div");d.className="bn-dest";m.dest=new mapboxgl.Marker({element:d,anchor:"center"}).setLngLat([r.dropoff.lng,r.dropoff.lat]).addTo(map)}m.dest.setLngLat([r.dropoff.lng,r.dropoff.lat]);
    features.push({type:"Feature",properties:{sel:r.id===selectedId?1:0},geometry:{type:"LineString",coordinates:arc(r.pickup,r.dropoff)}})}
   else if(m.dest){m.dest.remove();m.dest=null}}
  for(const[id,m]of markers.current)if(!live.has(id)){m.pin.remove();m.dest?.remove();markers.current.delete(id)}
  map.getSource("bn-routes")?.setData({type:"FeatureCollection",features:features.sort((a,b)=>a.properties.sel-b.properties.sel)});
  const fresh=[...live].filter(id=>!known.current.has(id));known.current=live;
  if(fresh.length&&selectedId==null&&Date.now()-touched.current>20000){const b=new mapboxgl.LngLatBounds();for(const r of riders){if(hasPoint(r.pickup))b.extend([r.pickup.lng,r.pickup.lat]);if(hasPoint(r.dropoff))b.extend([r.dropoff.lng,r.dropoff.lat])}
   if(!b.isEmpty())map.fitBounds(b,{padding:{top:80,bottom:80,left:80,right:80},maxZoom:13.5,duration:900})}},[riders,selectedId,ready]);

 React.useEffect(()=>{const map=mapRef.current;if(!map||!ready||selectedId==null)return;const r=riders.find(x=>x.id===selectedId);if(!r||!hasPoint(r.pickup))return;
  if(hasPoint(r.dropoff)){const b=new mapboxgl.LngLatBounds([r.pickup.lng,r.pickup.lat],[r.pickup.lng,r.pickup.lat]);b.extend([r.dropoff.lng,r.dropoff.lat]);map.fitBounds(b,{padding:{top:90,bottom:90,left:90,right:90},maxZoom:14,duration:900})}
  else map.easeTo({center:[r.pickup.lng,r.pickup.lat],zoom:Math.max(map.getZoom(),13.5),duration:900})},[selectedId,ready]);

 return hs("div",{className:"bn-map",children:[h("div",{ref:box,className:"bn-canvas"}),token?null:h("div",{className:"bn-empty",style:{position:"absolute",inset:0,border:0},children:"Mapa no disponible"}),
  hs("div",{className:"bn-legend",children:[hs("span",{children:[h("span",{className:"bn-rg"}),"Recogida que eligió"]}),hs("span",{children:[h("span",{className:"bn-rw"}),"Destino que eligió"]})]})]});
}

function BookingNowScreen(){
 injectCss();
 const navigate=useNavigate();
 const{loading,error,data,offset}=useBookingNow();
 const nowMs=useClock(offset);
 const[selectedId,setSelectedId]=React.useState(null),[chatFor,setChatFor]=React.useState(null);
 const riders=React.useMemo(()=>Array.isArray(data?.riders)?data.riders:[],[data]);
 const rows=useWithLeaving(riders);
 React.useEffect(()=>{if(selectedId!=null&&!riders.some(r=>r.id===selectedId))setSelectedId(null)},[riders,selectedId]);
 const select=React.useCallback(id=>{setSelectedId(id);const el=document.getElementById(`bn-card-${id}`);el?.scrollIntoView({block:"nearest",behavior:"smooth"})},[]);
 const create=r=>navigate("/viajes/nuevo",{state:{bookingPrefill:{rider:{id:r.id,first_name:r.first_name,last_name:r.last_name,phone:r.phone,photo_url:r.photo_url},pickup:hasPoint(r.pickup)?r.pickup:null,dropoff:hasPoint(r.dropoff)?r.dropoff:null}}});
 const buildingCount=data?.building??0,appOpen=data?.app_open??0,recent=data?.recent_requests??0;
 return hs("div",{className:"bn-page",children:[
  hs("div",{className:"bn-top",children:[
   h("h1",{className:"bn-title",children:"Pidiendo ahora"}),
   hs("span",{className:`bn-live${error?" off":""}`,children:[h("i",{}),error?"Sin conexión":"En vivo"]}),
   hs("div",{className:"bn-counts",children:[
    hs("div",{className:"bn-cnt g",children:[h("b",{children:buildingCount}),"armando un viaje"]}),
    hs("div",{className:"bn-cnt",children:[h("b",{children:appOpen}),"con la app abierta"]}),
    hs("div",{className:"bn-cnt",children:[h("b",{children:recent}),"pidió en los últimos 5 min"]})]})]}),
  error&&data?h("div",{className:"bn-err",children:`No se pudo actualizar: ${error}`}):null,
  hs("div",{className:"bn-body",children:[
   hs("div",{className:"bn-list",children:[
    loading&&!data?h("div",{className:"bn-empty",children:"Cargando…"}):null,
    !loading&&!data&&error?hs("div",{className:"bn-empty",children:[h("b",{children:"No se pudo cargar"}),h("span",{children:error})]}):null,
    data&&rows.length===0?hs("div",{className:"bn-empty",children:[h("b",{children:"Nadie está armando un viaje ahora mismo"}),h("span",{children:"Aquí aparece cada pasajero en cuanto escribe o elige una dirección."})]}):null,
    ...rows.map(({r,leaving})=>h("div",{id:`bn-card-${r.id}`,children:h(Card,{rider:r,leaving,selected:r.id===selectedId,nowMs,onSelect:select,onCreate:create,onChat:setChatFor,onProfile:x=>navigate(`/personas/rider/sql_${x.id}`),onTrip:id=>navigate(`/viajes/viaje/sql_${id}`)})},`${r.id}${leaving?"-out":""}`)),
    data&&appOpen>0?h("div",{className:"bn-more",children:`+ ${appOpen} con la app abierta que no han elegido dirección. Solo los contamos; su ubicación no se muestra.`}):null]}),
   h(BookingMap,{riders,selectedId,onSelect:select})]}),
  chatFor?h(ChatModal,{rider:chatFor,onClose:()=>setChatFor(null),onOpenChat:id=>{setChatFor(null);navigate(`/soporte/chat/${id}`)}}):null]});
}

export{BookingNowScreen,arc as bookingArc,useWithLeaving};
