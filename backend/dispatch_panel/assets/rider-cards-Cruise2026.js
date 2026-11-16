/*! guard-pin panel_rider_cards: "Agregar tarjeta" de un pasajero desde el panel + elegir la tarjeta del viaje (dueño 2026-11-15, dibujo https://claude.ai/artifact/9ajBYu169bo3u3ovcTSf3u) - chunk escrito a mano (CLAUDE.md #30). El número va del navegador a Stripe (Stripe.js, recuadro de Stripe): nunca pasa por nuestro servidor. Lo cargan index-azyIyM-i.js (ficha) e index-B68rRA9U.js (Nuevo viaje). */
import{r as React,j as jsxRuntime}from"./vendor-react-DprhJQz-.js";
import{L as apiPost}from"./index-CuQT_62K.js";

const h=jsxRuntime.jsx,hs=jsxRuntime.jsxs;
const GOLD="#E8C547";
const CARD_TYPES=new Set(["stripe_card","apple_pay","google_pay"]);

let stripeLoad=null;
function loadStripeJs(){
 if(typeof window!=="undefined"&&window.Stripe)return Promise.resolve(window.Stripe);
 if(stripeLoad)return stripeLoad;
 stripeLoad=new Promise((resolve,reject)=>{
  const s=document.createElement("script");s.src="https://js.stripe.com/v3/";s.async=true;
  s.onload=()=>window.Stripe?resolve(window.Stripe):reject(new Error("Stripe no cargó"));
  s.onerror=()=>{stripeLoad=null;reject(new Error("No se pudo cargar Stripe. Revisa tu conexión."))};
  document.head.appendChild(s)});
 return stripeLoad}

function errText(err,fallback){const m=err&&typeof err.message==="string"?err.message:"";return m!==""?m:fallback}

export function cardLabel(m){
 const n=String((m&&m.display_name)||"");
 if(m&&m.method_type==="apple_pay")return"Apple Pay";
 if(m&&m.method_type==="google_pay")return"Google Pay";
 const mm=n.match(/^(.*?)\s+ending in\s+(\d{4})$/i);
 return mm?`${mm[1]} •••• ${mm[2]}`:(n||"Tarjeta")}

function firstName(p){
 if(!p||typeof p!=="object")return"";
 const f=p.firstName??p.first_name??"";
 if(typeof f==="string"&&f.trim()!=="")return f.trim();
 const n=p.name??p.fullName??p.displayName??"";
 return typeof n==="string"?n.trim().split(/\s+/)[0]||"":""}

function ensureStyles(){
 if(document.getElementById("rc-css"))return;
 const st=document.createElement("style");st.id="rc-css";
 st.textContent=`
.rc-ov{position:fixed;inset:0;z-index:1000;background:rgba(5,5,8,.72);display:flex;align-items:center;justify-content:center;padding:20px;box-sizing:border-box}
.rc-dlg{width:100%;max-width:520px;max-height:calc(100dvh - 40px);overflow:auto;box-sizing:border-box;background:#1A1A21;border:1px solid rgba(255,255,255,.08);border-radius:22px;padding:24px;display:flex;flex-direction:column;gap:14px;color:#F4F4F5;box-shadow:0 30px 80px rgba(0,0,0,.55)}
.rc-hd{display:flex;align-items:flex-start;justify-content:space-between;gap:12px}
.rc-hd h3{margin:0;font-size:19px;font-weight:700}
.rc-sub{font-size:13px;color:#A1A1AA;margin-top:4px}
.rc-x{width:36px;height:36px;flex:none;border-radius:50%;border:1px solid rgba(255,255,255,.14);background:transparent;color:#F4F4F5;font-size:18px;cursor:pointer}
.rc-lbl{display:flex;flex-direction:column;gap:6px;font-size:13px;color:#A1A1AA}
.rc-in{height:46px;box-sizing:border-box;border-radius:12px;border:1px solid rgba(255,255,255,.12);background:#111116;color:#F4F4F5;padding:0 14px;font:500 15px Inter,system-ui,sans-serif}
.rc-card{min-height:50px;box-sizing:border-box;border-radius:12px;border:1.5px solid ${GOLD};background:#111116;padding:15px 14px}
.rc-hint{font-size:11.5px;color:#8B8B96}
.rc-chk{display:flex;align-items:flex-start;gap:10px;font-size:14px;line-height:1.4;cursor:pointer}
.rc-chk input{width:18px;height:18px;margin-top:1px;accent-color:${GOLD};flex:none}
.rc-note{display:flex;gap:10px;align-items:flex-start;background:rgba(232,197,71,.07);border:1px solid rgba(232,197,71,.25);border-radius:12px;padding:12px 14px;font-size:13px;line-height:1.45;color:#E6E6EA}
.rc-err{background:rgba(248,113,113,.1);border:1px solid rgba(248,113,113,.4);border-radius:12px;padding:10px 12px;font-size:13px;color:#FCA5A5}
.rc-row{display:flex;justify-content:flex-end;gap:10px;flex-wrap:wrap}
.rc-b{height:44px;padding:0 18px;border-radius:12px;border:1px solid rgba(255,255,255,.14);background:transparent;color:#F4F4F5;font:600 14px Inter,system-ui,sans-serif;cursor:pointer}
.rc-b.p{border:0;background:${GOLD};color:#111;font-weight:700}
.rc-b:disabled{opacity:.45;cursor:default}
.rc-add{height:36px;padding:0 14px;border-radius:10px;border:1px solid rgba(232,197,71,.45);background:rgba(232,197,71,.1);color:${GOLD};font:700 13px Inter,system-ui,sans-serif;cursor:pointer;white-space:nowrap}
.rc-add.dash{border:1px dashed rgba(255,255,255,.22);background:transparent;color:#F4F4F5}
.rc-list{display:flex;flex-direction:column;gap:8px}
.rc-opt{display:flex;align-items:center;gap:12px;background:#111116;border:1px solid rgba(255,255,255,.1);border-radius:14px;padding:12px 14px;cursor:pointer}
.rc-opt.on{border:1.5px solid ${GOLD}}
.rc-opt input{width:18px;height:18px;accent-color:${GOLD};flex:none}
.rc-opt b{font-size:14.5px;font-weight:600;display:block}
.rc-opt small{font-size:12px;color:#A1A1AA}
.rc-sum{display:flex;flex-direction:column;gap:3px;background:rgba(232,197,71,.07);border:1px solid rgba(232,197,71,.25);border-radius:12px;padding:11px 14px}
.rc-sum b{font-size:13.5px;color:${GOLD};font-weight:600}
.rc-sum span{font-size:12.5px;color:#E6E6EA}
`;
 document.head.appendChild(st)}

function AddCardModal({riderId,person,onClose,onSaved}){
 ensureStyles();
 const mountRef=React.useRef(null),stripeRef=React.useRef(null),cardRef=React.useRef(null),setupRef=React.useRef(null);
 const first=firstName(person);
 const[ready,setReady]=React.useState(false),[name,setName]=React.useState(()=>{const f=firstName(person);const l=person&&(person.lastName??person.last_name);return[f,typeof l==="string"?l:""].join(" ").trim()});
 const[makeDefault,setMakeDefault]=React.useState(true),[consent,setConsent]=React.useState(false),[complete,setComplete]=React.useState(false);
 const[saving,setSaving]=React.useState(false),[error,setError]=React.useState(null);
 React.useEffect(()=>{let alive=true;
  (async()=>{try{
   const setup=await apiPost(`/admin/users/${riderId}/card-setup`,{},{retry:{maxAttempts:1}});
   if(!setup||typeof setup.client_secret!=="string"||typeof setup.publishable_key!=="string")throw new Error("El servidor no abrió el formulario de tarjeta.");
   const Stripe=await loadStripeJs();if(!alive)return;
   const stripe=Stripe(setup.publishable_key);
   const card=stripe.elements().create("card",{hidePostalCode:false,disableLink:true,style:{base:{color:"#F4F4F5",fontFamily:"Inter, system-ui, sans-serif",fontSize:"16px",iconColor:GOLD,"::placeholder":{color:"#8B8B96"}},invalid:{color:"#FCA5A5",iconColor:"#FCA5A5"}}});
   if(!mountRef.current)return;
   card.mount(mountRef.current);
   card.on("change",ev=>{setComplete(!!ev.complete);setError(ev.error?ev.error.message:null)});
   stripeRef.current=stripe;cardRef.current=card;setupRef.current=setup;setReady(true);
  }catch(err){if(alive)setError(errText(err,"No se pudo abrir el formulario de tarjeta."))}})();
  return()=>{alive=false;try{cardRef.current&&cardRef.current.destroy()}catch{}}},[riderId]);
 const canSave=ready&&complete&&consent&&!saving;
 const save=async()=>{
  if(!canSave)return;setSaving(true);setError(null);
  try{
   const r=await stripeRef.current.confirmCardSetup(setupRef.current.client_secret,{payment_method:{card:cardRef.current,billing_details:{name:name.trim()||void 0}}});
   if(r.error){setError(r.error.message||"La tarjeta no se pudo guardar.");setSaving(false);return}
   const saved=await apiPost(`/admin/users/${riderId}/card-confirm`,{setup_intent_id:r.setupIntent.id,set_default:makeDefault,consent:true},{retry:{maxAttempts:1}});
   onSaved&&onSaved(saved);onClose();
  }catch(err){setError(errText(err,"La tarjeta no se pudo guardar."));setSaving(false)}};
 return h("div",{className:"rc-ov",onClick:e=>{if(e.target===e.currentTarget&&!saving)onClose()},children:
  hs("div",{className:"rc-dlg",role:"dialog","aria-modal":"true","aria-label":"Agregar tarjeta",children:[
   hs("div",{className:"rc-hd",children:[
    hs("div",{children:[h("h3",{children:first?`Agregar tarjeta a ${first}`:"Agregar tarjeta"}),h("div",{className:"rc-sub",children:"La verá en su app y podrás cobrarle sus viajes."})]}),
    h("button",{type:"button",className:"rc-x","aria-label":"Cerrar",disabled:saving,onClick:onClose,children:"×"})]}),
   hs("label",{className:"rc-lbl",children:["Nombre en la tarjeta",h("input",{className:"rc-in",value:name,onChange:e=>setName(e.target.value),autoComplete:"off"})]}),
   hs("div",{className:"rc-lbl",children:[h("span",{children:"Tarjeta"}),hs("div",{className:"rc-card",children:[ready?null:h("span",{className:"rc-hint",children:"Abriendo el recuadro de Stripe…"}),h("div",{ref:mountRef})]}),h("span",{className:"rc-hint",children:"Este recuadro es de Stripe: número, vencimiento, CVC y código postal."})]}),
   hs("label",{className:"rc-chk",children:[h("input",{type:"checkbox",checked:makeDefault,onChange:e=>setMakeDefault(e.target.checked)}),"Que sea su tarjeta predeterminada"]}),
   hs("label",{className:"rc-chk",children:[h("input",{type:"checkbox",checked:consent,onChange:e=>setConsent(e.target.checked)}),`${first||"La pasajera"} autorizó por teléfono guardar esta tarjeta y cobrarle sus viajes`]}),
   h("div",{className:"rc-note",children:"El número va directo de tu navegador a Stripe: Cruise nunca lo ve ni lo guarda. Pídelo por teléfono, nunca por el chat."}),
   error?h("div",{className:"rc-err",role:"alert",children:error}):null,
   hs("div",{className:"rc-row",children:[
    h("button",{type:"button",className:"rc-b",disabled:saving,onClick:onClose,children:"Cancelar"}),
    h("button",{type:"button",className:"rc-b p",disabled:!canSave,onClick:save,children:saving?"Guardando…":"Guardar tarjeta"})]})]})});
}

export function AddRiderCardButton({riderId,person,onSaved,dashed}){
 ensureStyles();
 const[open,setOpen]=React.useState(false);
 if(typeof riderId!=="number"||!(riderId>0))return null;
 return hs(React.Fragment,{children:[
  h("button",{type:"button",className:`rc-add${dashed?" dash":""}`,onClick:e=>{e.stopPropagation();setOpen(true)},children:"+ Agregar tarjeta"}),
  open?h(AddCardModal,{riderId,person,onClose:()=>setOpen(false),onSaved}):null]});
}

export function RiderCardPicker({methods,value,onChange,riderId,person,scheduled,chargeCents,onAdded}){
 ensureStyles();
 const cards=(Array.isArray(methods)?methods:[]).filter(m=>m&&CARD_TYPES.has(m.method_type)&&typeof m.id==="number");
 const picked=cards.find(m=>m.id===value)||null;
 const money=typeof chargeCents==="number"&&chargeCents>0?`$${(chargeCents/100).toFixed(2)}`:null;
 return hs("div",{className:"rc-list",children:[
  h("span",{style:{fontSize:"13px",color:"#A1A1AA"},children:cards.length?"¿Con qué tarjeta?":"No tiene tarjetas guardadas"}),
  cards.length?h("div",{role:"radiogroup","aria-label":"Tarjeta del viaje",className:"rc-list",children:cards.map(m=>hs("label",{className:`rc-opt${m.id===value?" on":""}`,children:[
   h("input",{type:"radio",name:"rc-trip-card",checked:m.id===value,onChange:()=>onChange(m.id)}),
   hs("span",{style:{flex:1,minWidth:0},children:[h("b",{children:cardLabel(m)}),m.is_default?h("small",{children:"Predeterminada"}):null]})]},m.id))}):null,
  h("div",{children:h(AddRiderCardButton,{riderId,person,dashed:true,onSaved:onAdded})}),
  picked&&money?hs("div",{className:"rc-sum",children:[
   h("b",{children:scheduled?`Se cobran ${money} a ${cardLabel(picked)} al terminar el viaje`:`Se retienen ${money} en ${cardLabel(picked)} al crear el viaje`}),
   h("span",{children:scheduled?"Hoy no se cobra nada: es una reserva. La tarjeta queda como su predeterminada.":"Se cobra al terminar el viaje. La tarjeta queda como su predeterminada."})]}):null]});
}
