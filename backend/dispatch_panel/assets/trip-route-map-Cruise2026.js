/*! guard-pin panel_booking_now_guard_test: mapa de la ruta en "Nuevo viaje" (owner 2026-11-07: "debajo de las direcciones un mapa como el de la app mostrando la ruta") - chunk escrito a mano (CLAUDE.md #30), lo carga index-B68rRA9U.js. Línea dorado→blanco por las calles (Mapbox Directions), anillo dorado en la recogida y blanco en el destino, como la app. */
import{r as React,j as jsxRuntime}from"./vendor-react-DprhJQz-.js";
import{m as mapboxgl}from"./vendor-mapbox-ComAnvan.js";
import{N as navyStyle,a as applyNavyGold,r as refineRoads,h as hideTraffic}from"./mapNavyGold-CiIxy5Vj.js";
import{m as getMapboxToken}from"./mapboxToken-DDoCRQix.js";

const h=jsxRuntime.jsx,hs=jsxRuntime.jsxs;
const GOLD="#E8C547";
const DEFAULT_CENTER=[-86.80,33.45];
const EMPTY={type:"FeatureCollection",features:[]};

const CSS=`
.trm{position:relative;height:280px;border-radius:14px;overflow:hidden;border:1px solid rgba(255,255,255,.08);background:#0f1626}
.trm>.trm-canvas{position:absolute;inset:0}
.trm-hint{position:absolute;inset:0;display:grid;place-items:center;pointer-events:none;z-index:2}
.trm-hint span{background:rgba(20,20,26,.88);border:1px solid rgba(255,255,255,.08);border-radius:999px;padding:7px 14px;font:500 12px Inter,system-ui,sans-serif;color:#9a9aa4}
.trm-pill{position:absolute;left:12px;top:12px;z-index:2;background:rgba(20,20,26,.9);border:1px solid rgba(255,255,255,.08);border-radius:999px;padding:5px 12px;font:600 12px Inter,system-ui,sans-serif;color:#fff;pointer-events:none}
.trm-pill b{color:${GOLD}}
.trm-ring{width:18px;height:18px;border-radius:50%;box-sizing:border-box;background:#0f1626;display:grid;place-items:center;box-shadow:0 2px 8px rgba(0,0,0,.5)}
.trm-ring.pick{border:3.5px solid ${GOLD}}
.trm-ring.pick::after{content:"";width:5px;height:5px;border-radius:50%;background:${GOLD}}
.trm-ring.drop{border:3.5px solid #fff}
`;

function ensureStyles(){
 if(typeof document==="undefined")return;
 if(!document.getElementById("trm-mapbox-css")){const l=document.createElement("link");l.id="trm-mapbox-css";l.rel="stylesheet";l.href=new URL("./vendor-mapbox-EidcXNcp.css",import.meta.url).href;document.head.appendChild(l)}
 if(!document.getElementById("trm-css")){const st=document.createElement("style");st.id="trm-css";st.textContent=CSS;document.head.appendChild(st)}
}

function okPoint(p){return p!=null&&Number.isFinite(p.lat)&&Number.isFinite(p.lng)&&Math.abs(p.lat)<=90&&Math.abs(p.lng)<=180&&!(p.lat===0&&p.lng===0)}

async function fetchStreetRoute(p,d,token,signal){
 const url=`https://api.mapbox.com/directions/v5/mapbox/driving/${p.lng},${p.lat};${d.lng},${d.lat}?geometries=geojson&overview=full&access_token=${encodeURIComponent(token)}`;
 const res=await fetch(url,{signal});
 if(!res.ok)throw new Error(`directions ${res.status}`);
 const body=await res.json();
 const route=body&&Array.isArray(body.routes)?body.routes[0]:null;
 const coords=route&&route.geometry&&Array.isArray(route.geometry.coordinates)?route.geometry.coordinates:null;
 if(!coords||coords.length<2)throw new Error("no route");
 return{coords,meters:Number(route.distance)||0,seconds:Number(route.duration)||0};
}

function ringEl(kind){const el=document.createElement("div");el.className=`trm-ring ${kind}`;return el}

function TripRouteMap({pickup,dropoff}){
 ensureStyles();
 const box=React.useRef(null),mapRef=React.useRef(null),pickRef=React.useRef(null),dropRef=React.useRef(null);
 const[ready,setReady]=React.useState(false),[summary,setSummary]=React.useState(null);
 const token=getMapboxToken();
 const p=okPoint(pickup)?{lat:pickup.lat,lng:pickup.lng}:null,d=okPoint(dropoff)?{lat:dropoff.lat,lng:dropoff.lng}:null;
 const pKey=p?`${p.lat.toFixed(6)},${p.lng.toFixed(6)}`:"",dKey=d?`${d.lat.toFixed(6)},${d.lng.toFixed(6)}`:"";

 React.useEffect(()=>{const el=box.current;if(!el||!token)return;mapboxgl.accessToken=token;
  const map=new mapboxgl.Map({container:el,style:navyStyle,center:DEFAULT_CENTER,zoom:9.5,bearing:0,pitch:0,maxPitch:0,dragRotate:false,pitchWithRotate:false,touchPitch:false,attributionControl:true,cooperativeGestures:false});
  mapRef.current=map;map.addControl(new mapboxgl.NavigationControl({showCompass:false}),"top-right");
  map.on("load",()=>{if(mapRef.current!==map)return;map.resize();applyNavyGold(map);refineRoads(map);hideTraffic(map);
   map.addSource("trm-route",{type:"geojson",lineMetrics:true,data:EMPTY});
   const all=(map.getStyle()||{}).layers||[];let lastRoad=-1;all.forEach((l,i)=>{if(l.type==="line"&&/^(road|bridge|tunnel)/.test(l.id))lastRoad=i});const labels=all.find((l,i)=>i>lastRoad&&l.type==="symbol");
   map.addLayer({id:"trm-route-line",type:"line",source:"trm-route",layout:{"line-cap":"round","line-join":"round"},paint:{"line-width":5.5,"line-gradient":["interpolate",["linear"],["line-progress"],0,GOLD,1,"#FFFFFF"]}},labels?labels.id:undefined);
   setReady(true)});
  const ro=typeof ResizeObserver==="undefined"?null:new ResizeObserver(()=>map.resize());ro?.observe(el);
  return()=>{ro?.disconnect();pickRef.current?.remove();dropRef.current?.remove();pickRef.current=null;dropRef.current=null;mapRef.current=null;setReady(false);map.remove()}},[token]);

 React.useEffect(()=>{const map=mapRef.current;if(!map||!ready)return;
  if(p){if(!pickRef.current)pickRef.current=new mapboxgl.Marker({element:ringEl("pick"),anchor:"center"}).setLngLat([p.lng,p.lat]).addTo(map);else pickRef.current.setLngLat([p.lng,p.lat])}
  else if(pickRef.current){pickRef.current.remove();pickRef.current=null}
  if(d){if(!dropRef.current)dropRef.current=new mapboxgl.Marker({element:ringEl("drop"),anchor:"center"}).setLngLat([d.lng,d.lat]).addTo(map);else dropRef.current.setLngLat([d.lng,d.lat])}
  else if(dropRef.current){dropRef.current.remove();dropRef.current=null}
  const src=map.getSource("trm-route");
  setSummary(null);
  if(!p||!d){src?.setData(EMPTY);const one=p||d;if(one)map.easeTo({center:[one.lng,one.lat],zoom:Math.max(map.getZoom(),13.5),duration:800});return}
  const ctrl=new AbortController();
  const draw=(coords,meters,seconds)=>{if(ctrl.signal.aborted||mapRef.current!==map)return;
   src?.setData({type:"Feature",properties:{},geometry:{type:"LineString",coordinates:coords}});
   const b=new mapboxgl.LngLatBounds(coords[0],coords[0]);for(const c of coords)b.extend(c);
   map.fitBounds(b,{padding:{top:56,bottom:40,left:44,right:44},maxZoom:15,duration:900});
   setSummary(meters>0?{miles:meters/1609.34,minutes:Math.max(1,Math.round(seconds/60))}:null)};
  fetchStreetRoute(p,d,token,ctrl.signal).then(r=>draw(r.coords,r.meters,r.seconds)).catch(()=>draw([[p.lng,p.lat],[d.lng,d.lat]],0,0));
  return()=>ctrl.abort()},[pKey,dKey,ready]);

 return hs("div",{className:"trm",children:[
  h("div",{ref:box,className:"trm-canvas"}),
  summary?hs("div",{className:"trm-pill",children:[h("b",{children:`${summary.miles.toFixed(1)} mi`})," · ",`${summary.minutes} min`]}):null,
  !token?h("div",{className:"trm-hint",children:h("span",{children:"Mapa no disponible"})}):!p&&!d?h("div",{className:"trm-hint",children:h("span",{children:"Elige la recogida y el destino para ver la ruta"})}):null]});
}

export{TripRouteMap,fetchStreetRoute,okPoint};
