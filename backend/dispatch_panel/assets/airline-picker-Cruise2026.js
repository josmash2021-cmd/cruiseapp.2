/*! guard-pin panel_airline_picker: "Nuevo viaje" elige la aerolínea cuando la recogida o el destino es un aeropuerto (dueño 2026-11-16, dibujo https://claude.ai/artifact/12bW7EawfQaPz7JW247WPy) - chunk escrito a mano (CLAUDE.md #30); lo monta CreateTripScreen (index-B68rRA9U.js) debajo del mapa de la ruta. Logos de /static/airlines (los mismos del app); la terminal solo cuando está confirmada. El viaje se guarda con airport_end + airline (POST /admin/trips): solo cambian las palabras, nunca el precio. */
import{r as React,j as J}from"./vendor-react-DprhJQz-.js";
import{W as apiGet}from"./index-CuQT_62K.js";

function el(type,props,...kids){
 const p=Object.assign({},props||{});const key=p.key;delete p.key;
 const c=kids.filter(k=>k!==undefined);
 if(c.length===1)p.children=c[0];else if(c.length>1)p.children=c;
 return c.length>1?J.jsxs(type,p,key):J.jsx(type,p,key);
}

const CSS=`
.ap-box{display:flex;flex-direction:column;gap:12px;border:1px solid rgba(232,197,71,.25);background:rgba(232,197,71,.04);border-radius:14px;padding:14px}
.ap-head{display:flex;flex-wrap:wrap;align-items:center;gap:8px;justify-content:space-between}
.ap-head b{font:700 14px Inter,system-ui,sans-serif;color:#fff}
.ap-head span{font:500 12.5px Inter,system-ui,sans-serif;color:rgba(255,255,255,.6)}
.ap-tag{height:24px;padding:0 9px;border-radius:999px;background:rgba(232,197,71,.14);color:#E8C547;font:700 11.5px Inter,system-ui,sans-serif;display:inline-flex;align-items:center}
.ap-grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(140px,1fr));gap:8px}
.ap-tile{display:flex;align-items:center;gap:9px;padding:9px;border-radius:12px;border:1px solid rgba(255,255,255,.1);background:#14141A;color:#F4F4F5;font:600 12.5px Inter,system-ui,sans-serif;cursor:pointer;text-align:left;min-width:0}
.ap-tile:hover{border-color:rgba(255,255,255,.25)}
.ap-tile.on{border-color:#E8C547;background:rgba(232,197,71,.08)}
.ap-tile img,.ap-tile i{width:30px;height:30px;border-radius:8px;background:#fff;object-fit:cover;flex:none}
.ap-tile i{display:grid;place-items:center;background:#23232D;color:#fff;font-style:normal}
.ap-tile span{display:flex;flex-direction:column;min-width:0}
.ap-tile small{font:500 11px Inter,system-ui,sans-serif;color:rgba(255,255,255,.55)}
.ap-note{font:500 12.5px Inter,system-ui,sans-serif;color:rgba(255,255,255,.72);background:#14141A;border-radius:10px;padding:9px 11px}
.ap-note b{color:#fff}
`;
function ensureCss(){if(typeof document==="undefined"||document.getElementById("ap-css"))return;const s=document.createElement("style");s.id="ap-css";s.textContent=CSS;document.head.appendChild(s)}

const cache=new Map();
function nearAirport(p){
 if(!p)return Promise.resolve(false);
 const key=`${p.lat.toFixed(4)},${p.lng.toFixed(4)}`;
 if(!cache.has(key))cache.set(key,apiGet("/admin/airports/near",{query:{lat:p.lat,lng:p.lng},retry:{maxAttempts:1}}).then(r=>r&&r.airport?r.airport:false).catch(()=>{cache.delete(key);return false}));
 return cache.get(key);
}

function AirlinePicker({pickup,dropoff,value,onChange}){
 ensureCss();
 const[air,setAir]=React.useState({pickup:false,dropoff:false});
 const pk=pickup?`${pickup.lat},${pickup.lng}`:"",dk=dropoff?`${dropoff.lat},${dropoff.lng}`:"";
 React.useEffect(()=>{let alive=true;Promise.all([nearAirport(pickup),nearAirport(dropoff)]).then(([p,d])=>{if(alive)setAir({pickup:p,dropoff:d})});return()=>{alive=false}},[pk,dk]);
 // The destination wins when both ends are airports.
 const end=air.dropoff?"dropoff":air.pickup?"pickup":null;
 const a=end?air[end]:null;
 React.useEffect(()=>{if(value&&(!a||value.end!==end||!a.airlines.some(x=>x.name===value.airline)))onChange(null)},[end,a&&a.code]);
 if(!a)return null;
 const pick=value&&value.end===end?value.airline:null;
 const chosen=pick?a.airlines.find(x=>x.name===pick):null;
 const shows=`${a.code} · ${(chosen&&chosen.terminal)||a.short_name}${pick?` — ${pick}`:""}`;
 return el("div",{className:"ap-box"},
  el("div",{className:"ap-head"},el("div",null,el("b",null,"¿Con qué aerolínea vuela?"),el("br",null),el("span",null,a.name)),el("span",{className:"ap-tag"},end==="dropoff"?"Salidas":"Llegadas")),
  el("div",{className:"ap-grid"},a.airlines.map(x=>el("button",{key:x.name,type:"button","aria-pressed":pick===x.name,className:pick===x.name?"ap-tile on":"ap-tile",onClick:()=>onChange(pick===x.name?null:{end,airline:x.name})},
   x.logo?el("img",{src:x.logo,alt:""}):el("i",null,"✈"),
   el("span",null,x.name,el("small",null,x.terminal||"Terminal sin confirmar"))))),
  el("div",{className:"ap-note"},"El conductor verá: ",el("b",null,shows),chosen&&!chosen.terminal?" (la terminal no está confirmada, así que no se la decimos).":pick?".":" — elige la aerolínea para que la vea."));
}

export{AirlinePicker};
