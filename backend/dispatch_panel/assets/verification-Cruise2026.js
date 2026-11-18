/*! guard-pin panel_verification_queue: Verificación estilo Lyft (dueño 2026-11-18, dibujo https://claude.ai/artifact/3PRGKiMqbLtYVhYC8DdG5H) - chunk escrito a mano, sin fuente React (CLAUDE.md #30). Cola a la izquierda (más viejos primero, rojo > 24 h, dorado > 12 h) y la persona a la derecha: documentos con su estado real, el documento grande, selfie al lado de la licencia, "Revisa" (solo en pantalla), lo que escribió en la app, vehículos, y abajo Rechazar… / Lista de espera / Aprobar; al decidir pasa sola a la siguiente. Datos: la MISMA cola en vivo de la página de antes (aA = Firestore verifications/clients/drivers + GET /admin/verifications), GET /admin/users/{id} por persona y GET /admin/face-checks/pending. Las decisiones son las MISMAS llamadas de index-jhlVlbS1.js (copiadas abajo tal cual: /auth/dispatch-approve|reject|waitlist|unwaitlist para conductores, PATCH /admin/verifications/{id} para pasajeros, el espejo Firestore). Si este chunk falla se ve la página de antes (VerificacionScreen). */
import{r as React,j as J,y as useNavigate}from"./vendor-react-DprhJQz-.js";
import{aw as ee,Y as Ge,L as B,G as V,X as fe,a8 as ge,e as U,ak as A,ax as je,ay as Ye,az as Xe,al as Q,ao as O,ap as F,aq as Qe,F as y,W as Ze,aA as qe}from"./index-CuQT_62K.js";
import{h as K,j as E,x as ra,e as G,f as la,d as oa,r as ca}from"./vendor-firebase-BR3GpBd7.js";
import{j as da,e as ua,h as pa,f as fa,approveFaceCheck,rejectFaceCheck}from"./users-DWu98l86.js";
import{u as ma}from"./ReAuthDialog-Dt3690jy.js";
import{Modal,CallModal,ensureCss as ensureProfileCss}from"./user-profile-Cruise2026.js";

// ── Copied VERBATIM from index-jhlVlbS1.js (the old Verificación page):
// lookup of the request, the verdict calls + Firestore mirror, the photo
// URL resolver and the document helpers. Keep in step with that chunk.
async function ha(e){const t=await K(E(U,"verifications",e));if(t.exists())return{data:t.data()??{},sourceCollection:"verifications"};const s=await K(E(U,"drivers",e));if(s.exists()){const n=s.data()??{};return{data:{role:"driver",userId:A(n.sqliteId)??0,firstName:n.firstName??n.first_name,lastName:n.lastName??n.last_name,email:n.email,phone:n.phone,profilePhotoUrl:n.profilePhotoUrl??n.photoUrl??n.photo_url},sourceCollection:"drivers"}}const i=await K(E(U,"clients",e));if(i.exists()){const n=i.data()??{};return{data:{role:"rider",userId:A(n.sqliteId)??0,firstName:n.firstName??n.first_name,lastName:n.lastName??n.last_name,email:n.email,phone:n.phone,profilePhotoUrl:n.profilePhotoUrl??n.photoUrl??n.photo_url},sourceCollection:"clients"}}return null}function xa(e,t){const s=A(t.userId)??0;if(s>0)return s;const i=/^sql_(\d+)$/.exec(e);return i!==null?A(i[1])??0:0}async function se(e){const{docId:t,userId:s,role:i,action:n}=e,r=e.reason??"",c=n==="approve",f=n==="approve"?"approved":n==="reject"?"rejected":n==="unwaitlist"?"pending":"waitlist",m={status:f,driver_status:f,approvalStatus:f,verificationStatus:f,isVerified:c,isApproved:c,reason:n==="reject"?r:null,verificationReason:n==="reject"?r:null,reviewedAt:G(),updated_at:G(),lastUpdated:G()},x=e.identity??{},u=p=>{const h=x[p];return typeof h=="string"&&h!==""?h:null},v=ra(U);if(s>0&&v.set(E(U,"verifications",`sql_${s}`),{...m,userId:s,...i!==""?{role:i}:{},...u("firstName")!==null?{firstName:u("firstName")}:{},...u("lastName")!==null?{lastName:u("lastName")}:{},...u("email")!==null?{email:u("email")}:{},...u("phone")!==null?{phone:u("phone")}:{}},{merge:!0}),t!==`sql_${s}`&&e.identitySourceCollection!==void 0)if(e.identitySourceCollection==="verifications")v.set(E(U,"verifications",t),{...m,...s>0?{userId:s}:{},...i!==""?{role:i}:{}},{merge:!0});else{const{status:p,...h}=m;v.set(E(U,e.identitySourceCollection,t),h,{merge:!0})}try{return await v.commit(),[]}catch(p){return[`El veredicto SÍ quedó aplicado en el servidor, pero no se pudo actualizar la ficha en Firestore: ${p}`]}}async function va(e,t,s=""){const i=/^sql_(\d+)$/.exec(e),n=i!==null?A(i[1])??0:0;return n<=0?null:(t==="waitlist"?await B(`/auth/dispatch-waitlist/${n}`):t==="unwaitlist"?await B(`/auth/dispatch-unwaitlist/${n}`):await ge(`/admin/verifications/${n}`,{action:t,reason:s}),ee.invalidate(),se({docId:e,userId:n,role:"",action:t,reason:s}))}async function ga(e,t,s,i=""){const n=typeof t.data.role=="string"?t.data.role:"rider",r=await se({docId:e,userId:0,role:n,action:s,reason:i,identity:t.data,identitySourceCollection:t.sourceCollection});if(r.length>0)throw new Error(r[0]);return["Registro sin id de backend: el veredicto solo se escribió en Firestore; el servidor no pudo enterarse."]}async function ne(e,t,s){const i=await ha(e);if(i===null){const f=await va(e,t,s);if(f!==null)return f;throw new fe(0,`No se encontró la solicitud ${e} ni una cuenta de backend para ella.`)}const n=i.data,r=typeof n.role=="string"?n.role:"rider",c=xa(e,n);if(c<=0)return ga(e,i,t,s);if(r==="driver")t==="approve"?await B(`/auth/dispatch-approve/${c}`):t==="waitlist"?await B(`/auth/dispatch-waitlist/${c}`):t==="unwaitlist"?await B(`/auth/dispatch-unwaitlist/${c}`):await B(`/auth/dispatch-reject/${c}`,{reason:s});else{if(t==="waitlist"||t==="unwaitlist")throw new fe(0,"La lista de espera solo aplica a drivers.");await ge(`/admin/verifications/${c}`,{action:t,reason:s})}return ee.invalidate(),se({docId:e,userId:c,role:r,action:t,reason:s,identity:n,identitySourceCollection:i.sourceCollection})}async function Se(e){try{return await ne(e,"approve","")}catch(t){throw V("No se pudo aprobar la verificación. Reintenta.",()=>void Se(e)),t}}async function ke(e,t){try{return await ne(e,"reject",t)}catch(s){throw V("No se pudo rechazar la verificación. Reintenta.",()=>void ke(e,t)),s}}async function Ce(e){try{return await ne(e,"waitlist","")}catch(t){throw V("No se pudo pasar a lista de espera. Reintenta.",()=>void Ce(e)),t}}async function unwaitlistMut(e){try{return await ne(e,"unwaitlist","")}catch(t){throw V("No se pudo quitar de la lista de espera. Reintenta.",()=>void unwaitlistMut(e)),t}}async function ja(){await Promise.all([ee.invalidate(),Ge.invalidate()])}async function ba(){await B("/admin/backfill-approved")}const ya={all:"Todos",pending:"Pendientes",approved:"Aprobados",rejected:"Rechazados",waitlist:"Lista de espera"},Na={"":"Todos",rider:"Riders",driver:"Drivers"};function wa(e,t){return t===""?[...e]:e.filter(s=>s.role===t)}function Sa(e){let t=0,s=0,i=0,n=0;for(const r of e)r.status==="pending"?t++:r.status==="approved"?s++:r.status==="rejected"?i++:r.status==="waitlist"&&n++;return{all:e.length,pending:t,approved:s,rejected:i,waitlist:n}}function ka(e,t,s){let i=e;t!=="all"&&(i=i.filter(r=>r.status===t));const n=s.trim().toLowerCase();return n!==""&&(i=i.filter(r=>{var c;return je(r).toLowerCase().includes(n)||r.phone.includes(n)||(((c=r.email)==null?void 0:c.toLowerCase().includes(n))??!1)})),[...i]}function Re(e){return e==="driver"?"Driver":"Rider"}function L(e){switch(e){case"license":case"driver_license":case"drivers_license":return"Licencia de conducir";case"passport":return"Pasaporte";case"id_card":return"Identificación oficial";case"insurance":return"Seguro del auto";case"registration":case"vehicle_registration":return"Registro del vehículo";case"vehicle_inspection":return"Inspección del vehículo";case"background_check":return"Chequeo de antecedentes";case"profile_photo":return"Foto de perfil";default:{const t=e.replaceAll("_"," ").trim();return t===""?"Documento":t}}}function D(e){const t=je(e);return t!==""?t:e.phone!==""?e.phone:e.email!==null&&e.email!==""?e.email:`Sin nombre · ${e.docId}`}function Ca(e){const t=e.userId>0?`sql_${e.userId}`:e.docId;return`/personas/${e.role}/${t}`}function Ra(e){if(!Ye(e))return null;if(Xe(e))return`Solo en el backend · #${e.userId}`;const t=e.userId>0?` · backend #${e.userId}`:" · sin id de backend";return`Sin solicitud · ${e.sourceCollection}/${e.docId}${t}`}function Ia(e){const t=e.substring(5),s=t.indexOf("/");if(s<=0)return e;const i=t.substring(0,s),n=encodeURIComponent(t.substring(s+1));return`https://firebasestorage.googleapis.com/v0/b/${i}/o/${n}?alt=media`}function Pa(e){if(e==="")return e;if(e.startsWith("gs://"))return Ia(e);if(e.startsWith("https://"))return e;if(e.startsWith("http://")){try{const t=new URL(e),s=t.hostname;if(s==="localhost"||s==="127.0.0.1"||s==="10.0.2.2"||s.startsWith("192.168.")||s.startsWith("172.")||/^10\.\d+\./.test(s))return`${Q}${t.pathname}${t.search}`}catch{}return e}return`${Q}${e}`}function S(e){return e.startsWith("gs://")||e.startsWith("http://")||e.startsWith("https://")?Pa(e):`${Q}${e}`}function $e(e){return S(e)}function ie(e){const t=[];return e.profilePhotoUrl!==null&&t.push(S(e.profilePhotoUrl)),e.selfieUrl!==null&&t.push(S(e.selfieUrl)),t}function Ua(e){return/\.(mp4|webm|mov)(\?|#|$)/i.test(e)}function _a(e){const t=[];return e.licenseFrontUrl!==null&&t.push({label:"Licencia (frente)",url:S(e.licenseFrontUrl)}),e.licenseBackUrl!==null&&t.push({label:"Licencia (atrás)",url:S(e.licenseBackUrl)}),e.insuranceUrl!==null&&t.push({label:"Seguro del auto",url:S(e.insuranceUrl)}),e.registrationUrl!==null&&t.push({label:"Tarjeta de circulación",url:S(e.registrationUrl)}),e.idPhotoUrl!==null&&e.licenseFrontUrl===null&&t.push({label:`Documento ${L(e.idDocumentType)}`,url:S(e.idPhotoUrl)}),e.selfieUrl!==null&&t.push({label:"Selfie biométrica",url:S(e.selfieUrl)}),t}function za(e){return e.verificationVideoUrl!==null?S(e.verificationVideoUrl):null}function Ea(e){const t=i=>{const n=e[i];if(n==null)return null;const r=String(n).trim();return r===""?null:r};return{car:[t("year"),t("make"),t("model")].filter(i=>i!==null).join(" "),type:t("type"),color:t("color"),plate:t("plate")}}function La(e){return e.ssnMasked!==null&&e.ssnMasked!==""?e.ssnMasked:e.ssnLast4!==null&&e.ssnLast4!==""?`***-**-${e.ssnLast4}`:"***-**-****"}function Va(e){return O(e.ssn)??O(e.ssn_full)}function Da(e){return e.trim()===""?"Ingrese un motivo de rechazo":null}function Ta(e,t){return e.filter(s=>s.userId>0&&!t.has(s.userId)).map(s=>s.id)}function Fa(e,t){return t===e?`${t} ficha${t===1?"":"s"} huérfana${t===1?"":"s"} eliminada${t===1?"":"s"}`:`Se eliminaron ${t} de ${e}; el resto falló`}function Ba(e){return{id:A(e.id)??0,docType:F(e.doc_type),status:O(e.status)??"pending",filePath:O(e.file_path),vehicleId:A(e.vehicle_id)}}function Oa(e){const t=F(e.year),s=F(e.make),i=F(e.model);return{id:A(e.id)??0,label:[t,s,i].filter(n=>n.trim()!=="").join(" ").trim(),plate:F(e.plate),approvalStatus:O(e.approval_status)??"pending",isActive:e.is_active===!0}}function Wa(e){return e.filter(t=>t.vehicleId===null)}function Ha(e,t){return e.filter(s=>s.vehicleId===t)}const Ma=new Set(["drivers_license","driver_license","license"]),Ka=new Set(["insurance"]),Ga=new Set(["registration","vehicle_registration"]);function re(e,t){const s=t.docType.toLowerCase().replace(/[\s-]/g,"_"),i=[];Ma.has(s)?(e.licenseFrontUrl!==null&&i.push({label:"Licencia (frente)",url:S(e.licenseFrontUrl)}),e.licenseBackUrl!==null&&i.push({label:"Licencia (atrás)",url:S(e.licenseBackUrl)})):Ka.has(s)?e.insuranceUrl!==null&&i.push({label:"Seguro del auto",url:S(e.insuranceUrl)}):Ga.has(s)&&e.registrationUrl!==null&&i.push({label:"Tarjeta de circulación",url:S(e.registrationUrl)});const n=t.filePath!==null&&t.filePath!==""?$e(t.filePath):null;return n!==null&&!i.some(r=>r.url===n)&&i.push({label:L(t.docType),url:n}),i}function Ya(e,t){const s=new Set;for(const i of t)for(const n of re(e,i))s.add(n.url);return s}async function it(){const e=await Ze("/admin/users",{query:{limit:500}}),t=new Set;if(Array.isArray(e))for(const i of e){const n=A(i.id);n!==null&&t.add(n)}if(t.size===0)throw new Error("El backend devolvió 0 usuarios; no se limpia nada.");const s=await la(oa(U,"verifications"));return Ta(s.docs.map(i=>({id:i.id,userId:A(i.data().userId)??0})),t)}async function rt(e){return(await Promise.allSettled(e.map(s=>ca(E(U,"verifications",s))))).filter(s=>s.status==="fulfilled").length}

function el(type,props,...kids){
 const p=Object.assign({},props||{});const key=p.key;delete p.key;
 const c=kids.filter(k=>k!==undefined);
 if(c.length===1)p.children=c[0];else if(c.length>1)p.children=c;
 return c.length>1?J.jsxs(type,p,key):J.jsx(type,p,key);
}

const CSS=`
.vq-page{display:flex;flex-direction:column;gap:18px;color:#F4F4F5;min-width:0;font-family:Inter,system-ui,-apple-system,Segoe UI,sans-serif}
.vq-top{display:flex;align-items:flex-end;gap:12px;flex-wrap:wrap}
.vq-top h1{margin:0;font-size:28px;font-weight:800;line-height:1.15;letter-spacing:-.01em}
.vq-sub{margin-top:4px;font-size:14px;color:#A1A1AA}
.vq-sub b{color:#FF9496;font-weight:700}
.vq-search{display:flex;align-items:center;gap:8px;height:38px;padding:0 14px;border-radius:999px;background:#1C1C24;border:1px solid rgba(255,255,255,.1);width:300px;max-width:100%;box-sizing:border-box;color:#A1A1AA}
.vq-search input{flex:1;min-width:0;background:transparent;border:0;outline:0;color:#F4F4F5;font-family:inherit;font-size:13px}
.vq-btn{height:38px;padding:0 15px;border-radius:999px;border:1px solid rgba(255,255,255,.14);background:#1E1E26;color:#F4F4F5;font-family:inherit;font-size:13px;font-weight:600;display:inline-flex;align-items:center;justify-content:center;gap:8px;cursor:pointer;white-space:nowrap;box-sizing:border-box;text-decoration:none}
.vq-btn:hover{background:#262630}
.vq-btn[disabled]{opacity:.45;cursor:default}
.vq-btn.sm{height:34px;padding:0 13px}
.vq-btn.big{height:44px}
.vq-btn.gold{background:#E8C547;border-color:#E8C547;color:#14141A;font-weight:700}
.vq-btn.gold:hover{background:#F2D46A}
.vq-btn.red{color:#FF9496;border-color:rgba(229,72,77,.4);background:transparent}
.vq-btn.red:hover{background:rgba(229,72,77,.1)}
.vq-btn.icon{width:34px;height:34px;padding:0}
.up-btn.vq-red{color:#FF9496;border-color:rgba(229,72,77,.45)}
.vq-tabs-row{display:flex;gap:10px 16px;flex-wrap:wrap;align-items:center;justify-content:space-between}
.vq-tabs{display:flex;gap:8px;flex-wrap:wrap;align-items:center}
.vq-tab{height:36px;padding:0 14px;border-radius:999px;border:1px solid rgba(255,255,255,.12);background:transparent;color:#C9C9D0;font-family:inherit;font-size:13px;font-weight:600;display:inline-flex;align-items:center;gap:8px;cursor:pointer;white-space:nowrap}
.vq-tab b{font-weight:800}
.vq-tab.on{background:#E8C547;border-color:#E8C547;color:#14141A}
.vq-tab.hot:not(.on) b{color:#FF8A7A}
.vq-chip{height:34px;padding:0 13px;border-radius:999px;border:1px solid rgba(255,255,255,.12);background:transparent;color:#C9C9D0;font-family:inherit;font-size:12.5px;font-weight:600;cursor:pointer;display:inline-flex;align-items:center;gap:6px;white-space:nowrap}
.vq-chip b{font-weight:800}
.vq-chip.on{background:#262630;border-color:#262630;color:#fff}
.vq-cols{display:flex;gap:18px;align-items:flex-start}
.vq-box{background:#16161C;border:1px solid rgba(255,255,255,.06);border-radius:18px}
.vq-queue{flex:0 0 360px;max-width:380px;min-width:0;overflow:hidden}
.vq-rwrap{flex:1 1 auto;min-width:0;display:flex;flex-direction:column}
.vq-review{min-width:0;padding:20px;display:flex;flex-direction:column;gap:16px;box-sizing:border-box}
.vq-narrow .vq-cols{flex-direction:column;align-items:stretch}
.vq-narrow .vq-queue{flex:1 1 auto;max-width:none;width:100%}
.vq-narrow .vq-review{padding:16px}
.vq-hide{display:none!important}
.vq-qhead{display:flex;align-items:center;gap:8px;padding:12px 14px}
.vq-cap{font-size:11.5px;letter-spacing:.09em;font-weight:800;color:#A1A1AA}
.vq-q{display:flex;gap:11px;align-items:center;padding:12px 14px;border:0;border-top:1px solid rgba(255,255,255,.05);text-align:left;background:transparent;width:100%;color:#F4F4F5;font-family:inherit;cursor:pointer;box-sizing:border-box}
.vq-q:hover{background:#1B1B22}
.vq-q.on{background:#1D1B15;box-shadow:inset 3px 0 0 #E8C547}
.vq-av{width:38px;height:38px;border-radius:50%;flex:none;overflow:hidden;background:#2A2618;display:inline-flex;align-items:center;justify-content:center;font-size:12.5px;font-weight:700;color:#E8C547}
.vq-av img{width:100%;height:100%;object-fit:cover;display:block}
.vq-av.lg{width:46px;height:46px;font-size:14px}
.vq-cut{overflow:hidden;text-overflow:ellipsis;white-space:nowrap;min-width:0}
.vq-mut{color:#A1A1AA}
.vq-pill{display:inline-flex;align-items:center;gap:6px;height:24px;padding:0 10px;border-radius:999px;font-size:12px;font-weight:700;white-space:nowrap;flex:none}
.vq-pill.sm{height:22px;font-size:11.5px;padding:0 9px}
.vq-pill.red{background:rgba(229,72,77,.15);color:#FF9496}
.vq-pill.gold{background:rgba(232,197,71,.14);color:#E8C547}
.vq-pill.green{background:rgba(61,214,140,.13);color:#5FE3A1}
.vq-pill.blue{background:rgba(96,165,250,.15);color:#93C5FD}
.vq-pill.gray{background:rgba(255,255,255,.07);color:#B9B9C1}
.vq-t-gold{color:#E8C547}.vq-t-green{color:#5FE3A1}.vq-t-red{color:#FF9496}
.vq-head{display:flex;align-items:center;gap:12px;flex-wrap:wrap}
.vq-docs{display:flex;gap:8px;flex-wrap:wrap}
.vq-doc{flex:1 1 96px;max-width:170px;min-width:0;display:flex;flex-direction:column;gap:6px;padding:8px;border-radius:12px;border:1px solid rgba(255,255,255,.08);background:#1B1B22;color:#F4F4F5;font-family:inherit;cursor:pointer;text-align:left;box-sizing:border-box}
.vq-doc:hover{background:#212129}
.vq-doc.on{border-color:#E8C547;background:#221F14}
.vq-dl{font-size:12px;font-weight:600;line-height:1.25;overflow-wrap:anywhere}
.vq-thumb{height:52px;border-radius:8px;background:#26262E;display:flex;align-items:center;justify-content:center;color:#6B6B75;overflow:hidden}
.vq-thumb img{width:100%;height:100%;object-fit:cover;display:block}
.vq-two{display:flex;gap:16px;flex-wrap:wrap;align-items:flex-start}
.vq-main{flex:999 1 380px;min-width:0;display:flex;flex-direction:column;gap:8px}
.vq-side{flex:1 1 240px;min-width:0;display:flex;flex-direction:column;gap:14px}
.vq-stage{height:320px;border-radius:14px;background:#0C0C10;border:1px solid rgba(255,255,255,.06);display:flex;align-items:center;justify-content:center;position:relative;overflow:hidden}
.vq-stage img{max-width:100%;max-height:100%;object-fit:contain;transition:transform .18s ease}
.vq-stage video{max-width:100%;max-height:100%;background:#000}
.vq-stage-tools{position:absolute;right:10px;bottom:10px;display:flex;gap:6px}
.vq-cap-row{display:flex;align-items:center;gap:8px;flex-wrap:wrap;font-size:12.5px}
.vq-cap-row>span:first-child{flex:1 1 220px;min-width:0}
.vq-narrow .vq-bar>span:first-child{flex-basis:100%!important}
.vq-narrow .vq-bar>button{flex:1 1 auto}
.vq-cmp{display:flex;gap:10px}
.vq-cmp button{flex:1 1 0;min-width:0;display:flex;flex-direction:column;align-items:center;gap:6px;background:none;border:0;color:inherit;font-family:inherit;cursor:pointer;padding:0}
.vq-cmp .ph{width:100%;max-width:130px;aspect-ratio:1;border-radius:14px;background:#26262E;overflow:hidden;display:block}
.vq-cmp .ph img{width:100%;height:100%;object-fit:cover;display:block}
.vq-cmp .ph.doc img{object-fit:contain}
.vq-ck{display:flex;align-items:center;gap:10px;font-size:13.5px;padding:6px 0;cursor:pointer}
.vq-ck input{width:18px;height:18px;accent-color:#E8C547;margin:0;flex:none}
.vq-kvs{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));column-gap:24px}
.vq-narrow .vq-kvs{grid-template-columns:minmax(0,1fr)}
.vq-kv{display:grid;grid-template-columns:130px minmax(0,1fr);gap:10px;font-size:13.5px;padding:7px 0;border-top:1px solid rgba(255,255,255,.05);align-items:center}
.vq-kv>span:last-child{overflow-wrap:anywhere;min-width:0}
.vq-veh{display:flex;align-items:center;gap:10px;flex-wrap:wrap;padding:10px 12px;border-radius:12px;background:#1B1B22;border:1px solid rgba(255,255,255,.06)}
.vq-veh.on{border-color:rgba(232,197,71,.45)}
.vq-plate{display:inline-flex;align-items:center;height:20px;padding:0 6px;border-radius:4px;background:#F4F4F5;color:#14141A;font-size:11px;font-weight:800;letter-spacing:.05em}
.vq-bar{display:flex;align-items:center;gap:10px;flex-wrap:wrap;padding-top:14px;border-top:1px solid rgba(255,255,255,.06)}
.vq-note{padding:10px 12px;border-radius:12px;font-size:13px;line-height:1.4}
.vq-note.warn{background:rgba(232,197,71,.1);color:#E8C547;border:1px solid rgba(232,197,71,.25)}
.vq-note.err{background:rgba(229,72,77,.1);color:#FFB4B6;border:1px solid rgba(229,72,77,.25)}
.vq-menu{position:absolute;right:0;top:44px;width:270px;padding:6px;background:#1E1E26;border:1px solid rgba(255,255,255,.1);border-radius:14px;box-shadow:0 18px 40px rgba(0,0,0,.45);z-index:20}
.vq-mi{display:flex;flex-direction:column;align-items:flex-start;gap:2px;width:100%;padding:9px 12px;border-radius:10px;border:0;background:transparent;color:#F4F4F5;font-family:inherit;font-size:13.5px;font-weight:600;cursor:pointer;text-align:left}
.vq-mi small{font-size:11.5px;font-weight:500;color:#A1A1AA}
.vq-mi:hover{background:#262630}
.vq-mi[disabled]{opacity:.5;cursor:default}
.vq-skel{height:58px;margin:6px 14px;border-radius:10px;background:#1C1C24}
.vq-empty{padding:30px 18px;color:#A1A1AA;font-size:14px;text-align:center;line-height:1.45}
.vq-empty b{display:block;color:#F4F4F5;font-size:15px;margin-bottom:4px}
.vq-reasons{display:flex;gap:6px;flex-wrap:wrap}
.vq-light{width:100%;max-height:70vh;object-fit:contain;border-radius:10px;background:#000;display:block}
.vq-ssn{font-family:ui-monospace,Menlo,Consolas,monospace;letter-spacing:.08em}
.vq-link{background:none;border:0;padding:0;color:#E8C547;font-family:inherit;font-size:12.5px;font-weight:700;cursor:pointer}
`;
function vqCss(){if(typeof document==="undefined"||document.getElementById("vq-css"))return;const s=document.createElement("style");s.id="vq-css";s.textContent=CSS;document.head.appendChild(s)}

// ── Small helpers ─────────────────────────────────────────────────────
const VQ_DOW={Sun:"dom",Mon:"lun",Tue:"mar",Wed:"mié",Thu:"jue",Fri:"vie",Sat:"sáb"};
const VQ_MES=["ene","feb","mar","abr","may","jun","jul","ago","sep","oct","nov","dic"];
function vqDate(v){if(v==null||v==="")return null;const d=v instanceof Date?v:new Date(v);return Number.isNaN(d.getTime())?null:d}
// "lun 17 nov · 2:41 AM", Miami time, 12 h (owner: "la hora no sea 24h si no 12").
function vqWhen(v){const d=vqDate(v);if(d===null)return"sin fecha";try{const p=Object.fromEntries(new Intl.DateTimeFormat("en-US",{timeZone:"America/New_York",weekday:"short",month:"numeric",day:"numeric",hour:"numeric",minute:"2-digit",hour12:!0}).formatToParts(d).map(x=>[x.type,x.value]));return`${VQ_DOW[p.weekday]||""} ${p.day} ${VQ_MES[(+p.month)-1]||""} · ${p.hour}:${p.minute} ${p.dayPeriod}`.trim()}catch{return d.toLocaleString()}}
function vqAge(v){const d=vqDate(v);return d===null?null:Math.max(0,Date.now()-d.getTime())}
function vqAgeTxt(ms){if(ms===null)return"—";const m=Math.floor(ms/6e4);if(m<60)return`${Math.max(1,m)} min`;const h=Math.floor(m/60);if(h<24)return`${h} h`;const d=Math.floor(h/24);return`${d} día${d===1?"":"s"}`}
function vqTone(ms){if(ms===null)return"gray";const h=ms/36e5;return h>24?"red":h>12?"gold":"gray"}
function vqTs(v,dflt){const d=vqDate(v);return d===null?dflt:d.getTime()}
function vqPhone(p){const d=String(p||"").replace(/\D/g,"");return d.length===11&&d[0]==="1"?`+1 (${d.slice(1,4)}) ${d.slice(4,7)}-${d.slice(7)}`:d.length===10?`(${d.slice(0,3)}) ${d.slice(3,6)}-${d.slice(6)}`:String(p||"")}
function vqInitials(n){const w=String(n||"").trim().split(/\s+/).filter(x=>/^\p{L}/u.test(x));if(w.length===0)return"?";return(w[0][0]+(w.length>1?w[w.length-1][0]:"")).toUpperCase()}
function vqRole(r){return r==="driver"?"Conductor":"Pasajero"}
function vqMsg(x){return x instanceof Error?x.message:String(x)}
function vqDob(s){if(!s)return"—";const t=String(s).trim();let y=null,mo=null,da2=null,m;if(m=/^(\d{4})-(\d{1,2})-(\d{1,2})/.exec(t))[y,mo,da2]=[+m[1],+m[2],+m[3]];else if(m=/^(\d{1,2})\/(\d{1,2})\/(\d{4})$/.exec(t))[y,mo,da2]=[+m[3],+m[1],+m[2]];if(y===null)return t;const now=new Date();let age=now.getFullYear()-y;if(now.getMonth()+1<mo||(now.getMonth()+1===mo&&now.getDate()<da2))age--;return`${da2} ${VQ_MES[mo-1]||""} ${y}${age>0&&age<120?` · ${age} años`:""}`}
const VQ_STATUS={pending:["gold","Por revisar"],waitlist:["blue","Lista de espera"],approved:["green","Aprobado"],rejected:["red","Rechazado"]};
function vqIsVideo(u){return typeof u==="string"&&Ua(u)}

// Driver: the six uploads the app asks for. Rider: the ID document.
function vqSummary(r){if(r.role!=="driver")return L(r.idDocumentType);const n=[r.licenseFrontUrl,r.licenseBackUrl,r.insuranceUrl,r.registrationUrl,r.selfieUrl,r.verificationVideoUrl].filter(x=>x!==null&&x!==void 0&&x!=="").length;return`${n} de 6 documentos`}

const VQ_LABEL={selfie:"Selfie biométrica",biometric_video:"Video de verificación",id_document:"Identificación oficial",profile_photo:"Foto de perfil",registration:"Registro del vehículo",vehicle_registration:"Registro del vehículo"};
function vqDocLabel(t){const s=String(t||"").toLowerCase().replace(/[\s-]/g,"_");return VQ_LABEL[s]||L(t)}
function vqTidy(l){return l==="Tarjeta de circulación"?"Registro del vehículo":l}
function vqGroup(t,label){const s=String(t||"").toLowerCase().replace(/[\s-]/g,"_"),l=String(label||"");
 if(s.includes("licen")||l.startsWith("Licencia"))return"license";
 if(s==="insurance"||l.startsWith("Seguro"))return"insurance";
 if(s==="registration"||s==="vehicle_registration"||l.includes("circulaci")||l.startsWith("Registro del veh"))return"registration";
 if(s==="selfie"||l.startsWith("Selfie"))return"selfie";
 if(s==="biometric_video"||s.includes("video")||l.startsWith("Video"))return"video";
 if(s==="profile_photo"||l.startsWith("Foto de perfil"))return"profile";
 if(s==="id_document"||s==="id_card"||s==="passport"||l.startsWith("Documento")||l.startsWith("Identificaci")||l.startsWith("Pasaporte"))return"id";
 return"other"}
const VQ_RANK={license:0,id:1,insurance:2,registration:3,selfie:4,video:5,profile:6,other:7};

// The strip of documents: the server rows (with their real state) when the
// account has a backend id, plus every photo of the request they don't
// cover; a document the app asks for and nobody uploaded shows as "Falta".
// Daily selfies (selfie_check) live in their own tab, never here.
function vqTiles(req,det){
 const out=[],seen=new Set();
 const push=t=>{let k=`${t.group}:${t.label}`;if(seen.has(k))k+=`:${out.length}`;seen.add(k);out.push({...t,key:k})};
 if(det){
  const multi=det.vehicles.length>1;
  for(const d of det.documents){
   if(String(d.docType).toLowerCase()==="selfie_check")continue;
   const v=d.vehicleId!==null?det.vehicles.find(x=>x.id===d.vehicleId):null;
   const sfx=v&&multi?` · ${v.label||"Vehículo"}`:"";
   const urls=re(req,d);
   if(urls.length===0)push({group:vqGroup(d.docType,""),label:vqDocLabel(d.docType)+sfx,url:null,doc:d});
   else for(const u of urls)push({group:vqGroup(d.docType,u.label),label:vqTidy(u.label===L(d.docType)?vqDocLabel(d.docType):u.label)+sfx,url:u.url,doc:d});
  }
  const covered=Ya(req,det.documents);
  for(const p of _a(req))if(!covered.has(p.url)&&!out.some(t=>t.url===p.url))push({group:vqGroup("",p.label),label:vqTidy(p.label),url:p.url,doc:null});
 }else for(const p of _a(req))push({group:vqGroup("",p.label),label:vqTidy(p.label),url:p.url,doc:null});
 const vid=za(req);if(vid!==null&&!out.some(t=>t.url===vid))push({group:"video",label:"Video de verificación",url:vid,doc:null});
 if(req.profilePhotoUrl!==null&&!out.some(t=>t.group==="profile"))push({group:"profile",label:"Foto de perfil",url:ie(req)[0],doc:null});
 const need=req.role==="driver"?[["license","Licencia de conducir"],["insurance","Seguro del auto"],["registration","Registro del vehículo"],["selfie","Selfie biométrica"],["video","Video de verificación"]]:[["id","Identificación oficial"],["selfie","Selfie biométrica"]];
 for(const[g,l]of need){const has=out.some(t=>(t.group===g||(g==="id"&&t.group==="license"))&&(t.url!==null||t.doc!==null));if(!has)push({group:g,label:l,url:null,doc:null,missing:!0})}
 out.sort((a,b)=>VQ_RANK[a.group]-VQ_RANK[b.group]);
 return out;
}
function vqTileState(t,selected){
 if(t.missing)return["vq-t-red","Falta"];
 if(t.doc===null)return["vq-mut","Foto"];
 const s=t.doc.status;
 if(s==="approved")return["vq-t-green","✓ Aprobado"];
 if(s==="rejected")return["vq-t-red","Rechazado"];
 return selected?["vq-t-gold","Revisando"]:["vq-mut","Sin revisar"];
}

const ICON={
 card:"M3 6h18v12H3zM7 10h4M7 14h6M15 10h2",
 page:"M6 3h9l4 4v14H6zM14 3v5h5M9 13h7M9 17h5",
 face:"M12 12a4 4 0 1 0 0-8 4 4 0 0 0 0 8zM4 21a8 8 0 0 1 16 0",
 video:"M4 6h12v12H4zM16 10l5-3v10l-5-3",
 search:"M11 18a7 7 0 1 0 0-14 7 7 0 0 0 0 14zM20 20l-4-4",
};
function Svg({d,size}){return el("svg",{"aria-hidden":"true",width:size||22,height:size||22,viewBox:"0 0 24 24",fill:"none",stroke:"currentColor",strokeWidth:1.7,strokeLinecap:"round",strokeLinejoin:"round"},el("path",{d}))}
function vqTileIcon(g){return g==="license"||g==="id"?ICON.card:g==="selfie"||g==="profile"?ICON.face:g==="video"?ICON.video:ICON.page}

function VqAvatar({urls,name,big}){
 const list=urls||[];const k=list.join("|");const[i,setI]=React.useState(0);
 React.useEffect(()=>setI(0),[k]);
 const u=list[i];
 return el("span",{className:"vq-av"+(big?" lg":"")},u?el("img",{src:u,alt:"",onError:()=>setI(n=>n+1)}):vqInitials(name));
}

// ── Dialogs (the profile chunk's Modal, so they look like the rest) ──
function ConfirmBox({title,message,confirmLabel,danger,busy,onCancel,onConfirm}){
 return el(Modal,{title,onClose:onCancel,width:460},
  el("div",{style:{fontSize:14,lineHeight:1.45,color:"rgba(255,255,255,.78)"}},message),
  el("footer",null,
   el("button",{type:"button",className:"up-btn",onClick:onCancel,disabled:busy},"Cancelar"),
   el("button",{type:"button",className:danger?"up-btn vq-red":"up-btn gold",onClick:onConfirm,disabled:busy},busy?"Un momento…":confirmLabel)));
}
const VQ_REASONS=["La foto está borrosa o cortada","El documento está vencido","El nombre no coincide con la cuenta","La cara no coincide con la selfie","Falta un documento"];
function ReasonBox({title,message,required,confirmLabel,busy,chips,onClose,onConfirm}){
 const[text,setText]=React.useState(""),[err,setErr]=React.useState(null);
 const go=()=>{if(required){const e=Da(text);if(e!==null){setErr("Escribe el motivo del rechazo");return}}onConfirm(text)};
 return el(Modal,{title,sub:message,onClose,width:520},
  chips?el("div",{className:"vq-reasons"},VQ_REASONS.map(r=>el("button",{key:r,type:"button",className:"vq-chip",onClick:()=>{setText(r);setErr(null)}},r))):null,
  el("textarea",{className:"up-text",autoFocus:!0,rows:3,maxLength:500,value:text,placeholder:required?"Motivo del rechazo (lo ve la persona en su app)":"Razón (opcional)",onChange:e=>{setText(e.target.value);err!==null&&setErr(null)}}),
  err?el("div",{className:"up-err"},err):null,
  el("footer",null,
   el("button",{type:"button",className:"up-btn",onClick:onClose,disabled:busy},"Cancelar"),
   el("button",{type:"button",className:"up-btn vq-red",onClick:go,disabled:busy},busy?"Un momento…":confirmLabel)));
}
function Lightbox({media,onClose}){
 return el(Modal,{title:media.label,onClose,width:980},
  vqIsVideo(media.url)?el("video",{className:"vq-light",src:media.url,controls:!0,autoPlay:!0}):el("img",{className:"vq-light",src:media.url,alt:media.label}),
  el("footer",null,el("a",{className:"up-btn",href:media.url,target:"_blank",rel:"noreferrer",style:{textDecoration:"none"}},"Abrir original")));
}
// "Escribir": the open support chat if there is one, else a first message
// (same as the fleet map and the ficha — rule #86).
function WriteBox({id,name,onClose,navigate}){
 const[chat,setChat]=React.useState(void 0),[text,setText]=React.useState(""),[busy,setBusy]=React.useState(!1),[err,setErr]=React.useState(null);
 React.useEffect(()=>{let off=!1;Ze(`/admin/users/${id}/support-chat`,{retry:{maxAttempts:1}}).then(r=>{if(off)return;if(r&&r.chat_id){navigate(`/soporte/chat/${r.chat_id}`);onClose()}else setChat(null)}).catch(()=>{if(!off)setChat(null)});return()=>{off=!0}},[id]);// eslint-disable-line
 const send=async()=>{const message=text.trim();if(!message||busy)return;setBusy(!0);setErr(null);
  let persona=null;try{const v=JSON.parse(localStorage.getItem("si-persona-last")||"null");if(v&&typeof v.kind==="string")persona={kind:v.kind,name:v.kind==="name"?v.name:null}}catch{}
  try{const r=await B(`/admin/users/${id}/support-chat`,persona?{message,persona}:{message},{retry:{maxAttempts:1}});navigate(`/soporte/chat/${r.chat_id}`);onClose()}catch(e){setBusy(!1);setErr(vqMsg(e))}};
 const first=String(name||"").split(/\s+/)[0];
 return el(Modal,{title:`Escribirle a ${name}`,sub:"Le llega como un mensaje de Soporte en su app, con aviso.",onClose,width:480},
  chat===void 0?el("div",{className:"up-muted"},"Buscando su chat…"):
  el("textarea",{className:"up-text",autoFocus:!0,value:text,maxLength:2e3,placeholder:`Hola ${first}, `,onChange:e=>setText(e.target.value)}),
  err?el("div",{className:"up-err"},err):null,
  el("footer",null,el("button",{type:"button",className:"up-btn",onClick:onClose},"Cancelar"),el("button",{type:"button",className:"up-btn gold",disabled:chat===void 0||!text.trim()||busy,onClick:send},busy?"Enviando…":"Enviar")));
}

// ── The document on the big stage ─────────────────────────────────────
function Stage({tile,onOpen}){
 const[zoom,setZoom]=React.useState(1),[rot,setRot]=React.useState(0),[broken,setBroken]=React.useState(!1);
 const url=tile?tile.url:null;
 React.useEffect(()=>{setZoom(1);setRot(0);setBroken(!1)},[url]);
 if(!tile)return el("div",{className:"vq-stage"},el("span",{className:"vq-mut",style:{fontSize:13}},"No hay documentos"));
 if(url===null)return el("div",{className:"vq-stage"},el("span",{className:"vq-mut",style:{fontSize:13.5,textAlign:"center",padding:16}},tile.missing?"Todavía no subió este documento.":"Este documento no tiene archivo."));
 const vid=vqIsVideo(url);
 return el("div",{className:"vq-stage"},
  vid?el("video",{key:url,src:url,controls:!0,preload:"metadata"}):
  broken?el("span",{className:"vq-mut",style:{fontSize:13}},"Foto no disponible"):
  el("img",{key:url,src:url,alt:tile.label,onError:()=>setBroken(!0),style:{transform:`scale(${zoom}) rotate(${rot}deg)`}}),
  el("div",{className:"vq-stage-tools"},
   vid?null:el("button",{type:"button",className:"vq-btn icon","aria-label":"Alejar",disabled:zoom<=1,onClick:()=>setZoom(z=>Math.max(1,z-.5))},"−"),
   vid?null:el("button",{type:"button",className:"vq-btn icon","aria-label":"Acercar",disabled:zoom>=4,onClick:()=>setZoom(z=>Math.min(4,z+.5))},"+"),
   vid?null:el("button",{type:"button",className:"vq-btn icon","aria-label":"Girar",onClick:()=>setRot(r=>(r+90)%360)},"⟳"),
   el("button",{type:"button",className:"vq-btn sm",onClick:()=>onOpen({label:tile.label,url})},"Abrir grande")));
}

// ── One person's review (KYC) ─────────────────────────────────────────
function Review({req,narrow,onBack,onDecided,onModal}){
 const nav=useNavigate();
 const isSuper=Qe(R=>R.role==="superadmin");
 const{requestReAuth:askReAuth,reAuthDialog:reAuthEl}=ma();
 const[det,setDet]=React.useState(null),[detErr,setDetErr]=React.useState(null);
 const[tileKey,setTileKey]=React.useState(null);
 const[checks,setChecks]=React.useState([!1,!1,!1,!1]);
 const[busy,setBusy]=React.useState(null);
 const[confirm,setConfirm]=React.useState(null);
 const[rejectOpen,setRejectOpen]=React.useState(!1);
 const[docReject,setDocReject]=React.useState(null);
 const[light,setLight]=React.useState(null);
 const[ssn,setSsn]=React.useState({shown:!1,full:req.ssnFull,busy:!1});
 const load=React.useCallback(async()=>{if(!(req.userId>0))return;setDetErr(null);try{
   const d=await ua(req.userId);
   const docs=Array.isArray(d.documents)?d.documents.map(x=>({...Ba(x),createdAt:x.created_at||null,rejectionReason:x.rejection_reason||null})):[];
   setDet({documents:docs,vehicles:Array.isArray(d.vehicles)?d.vehicles.map(Oa):[],ssnMasked:d.ssn_masked||null,ssnProvided:!!d.ssn_provided,licenseFront:d.license_front_url||null});
  }catch(x){setDetErr(vqMsg(x))}},[req.userId]);
 React.useEffect(()=>{load()},[load]);
 const tiles=React.useMemo(()=>vqTiles(req,det),[req,det]);
 React.useEffect(()=>{if(tileKey!==null&&tiles.some(t=>t.key===tileKey))return;const t=tiles.find(t=>t.url!==null&&t.doc!==null&&t.doc.status==="pending")||tiles.find(t=>t.url!==null)||tiles[0];setTileKey(t?t.key:null)},[tiles,tileKey]);
 const tile=tiles.find(t=>t.key===tileKey)||null;
 const j=D(req),pending=req.status==="pending",canDecide=pending||req.status==="waitlist",isDriver=req.role==="driver";
 const ms=vqAge(req.submittedAt),st=VQ_STATUS[req.status]||VQ_STATUS.pending;
 const city=[req.driveCity,req.driveState].filter(x=>x!==null&&x!==void 0&&x!=="").join(", ");
 const selfie=(tiles.find(t=>t.group==="selfie"&&t.url!==null&&!vqIsVideo(t.url))||{}).url||null;
 const idPhoto=(tiles.find(t=>(t.group==="license"||t.group==="id")&&t.url!==null&&!t.label.includes("atrás"))||{}).url||(det&&det.licenseFront?S(det.licenseFront):null);
 const warn=Ra(req);

 const decide=async(kind,fn,ok)=>{setBusy(kind);let done=!1;try{const w=await fn();w&&w.length>0?y.error(`${ok} · ${w.join(" · ")}`):y.success(ok);done=!0}catch{}finally{setBusy(null);setConfirm(null);setRejectOpen(!1)}if(done)onDecided(req.docId)};
 const docAct=async(id,action,reason="")=>{setBusy(`d-${id}`);try{await pa(id,action,reason);await load();y.success(action==="approve"?"Documento aprobado":"Documento rechazado");setDocReject(null)}catch{V("No se pudo actualizar el documento. Reintenta.",()=>void docAct(id,action,reason))}finally{setBusy(null)}};
 const vehAct=async(id,action,reason="")=>{setBusy(`v-${id}`);try{await fa(id,action,reason);await load();y.success(action==="approve"?"Vehículo aprobado":"Vehículo rechazado");setDocReject(null)}catch{V("No se pudo actualizar el vehículo. Reintenta.",()=>void vehAct(id,action,reason))}finally{setBusy(null)}};
 const ssnProvided=req.ssnProvided||req.ssnFull!==null||req.ssnLast4!==null||(det!==null&&det.ssnProvided);
 const toggleSsn=async()=>{if(ssn.shown){setSsn(s=>({...s,shown:!1}));return}if(ssn.full){setSsn(s=>({...s,shown:!0}));return}
  if(!await askReAuth(`Vas a ver el número de seguro social completo de ${j}.`))return;
  setSsn(s=>({...s,busy:!0}));try{const R=await da(req.userId),v=Va(R);v!==null&&v!==""?setSsn({shown:!0,full:v,busy:!1}):(y.info("El servidor no devolvió un SSN completo."),setSsn(s=>({...s,busy:!1})))}catch{V("No se pudo cargar el SSN. Reintenta.",()=>void toggleSsn());setSsn(s=>({...s,busy:!1}))}};
 const ssnText=ssn.shown&&ssn.full?ssn.full:(det&&det.ssnMasked)||La(req);
 const veh=req.vehicle!==null?Ea(req.vehicle):null;

 const kv=(label,value,key)=>el("div",{className:"vq-kv",key:key||label},el("span",{className:"vq-mut"},label),el("span",null,value));
 const kvs=[
  kv("Nombre",j),
  kv("Nacimiento",vqDob(req.dateOfBirth)),
  kv("Teléfono",req.phone!==""?vqPhone(req.phone):"No registrado"),
  kv("Correo",req.email||"No registrado"),
  isDriver?kv("Ciudad de trabajo",city||"—"):kv("Documento",L(req.idDocumentType)),
  isDriver?kv("Seguro social",ssnProvided?el("span",{style:{display:"inline-flex",alignItems:"center",gap:10,flexWrap:"wrap"}},el("span",{className:"vq-ssn"},ssnText),isSuper&&req.userId>0?el("button",{type:"button",className:"vq-link",disabled:ssn.busy,onClick:()=>void toggleSsn()},ssn.busy?"Cargando…":ssn.shown?"Ocultar":"Mostrar"):null,ssn.shown&&ssn.full?el("button",{type:"button",className:"vq-link",onClick:()=>{try{navigator.clipboard.writeText(ssn.full).then(()=>y.success("SSN copiado"),()=>{})}catch{}}},"Copiar"):null):"No proporcionado"):null,
  veh!==null&&veh.car!==""?kv("Vehículo",[veh.car,veh.color].filter(Boolean).join(" · ")):null,
  veh!==null&&(veh.plate||veh.type)?kv("Placa",[veh.plate,veh.type].filter(Boolean).join(" · ")):null,
  kv("ID de usuario",req.userId>0?`#${req.userId}`:"Sin id de backend"),
  kv("Enviado",vqWhen(req.submittedAt)),
 ].filter(Boolean);

 const docBusy=tile&&tile.doc&&busy===`d-${tile.doc.id}`;
 return el("section",{className:"vq-box vq-review"},
  narrow?el("div",null,el("button",{type:"button",className:"vq-btn sm",onClick:onBack},"‹ Volver a la cola")):null,
  el("div",{className:"vq-head"},
   el(VqAvatar,{urls:ie(req),name:j,big:!0}),
   el("div",{style:{flex:"1 1 220px",minWidth:0}},
    el("div",{style:{display:"flex",alignItems:"center",gap:8,flexWrap:"wrap"}},
     el("span",{style:{fontSize:19,fontWeight:800}},j),
     el("span",{className:`vq-pill ${isDriver?"blue":"gray"}`},vqRole(req.role)),
     pending?el("span",{className:`vq-pill ${vqTone(ms)}`},`Espera ${vqAgeTxt(ms)}`):el("span",{className:`vq-pill ${st[0]}`},st[1])),
    el("div",{className:"vq-mut",style:{fontSize:13,marginTop:3}},[req.userId>0?`#${req.userId}`:null,city||null,`envió sus documentos el ${vqWhen(req.submittedAt)}`].filter(Boolean).join(" · "))),
   el("button",{type:"button",className:"vq-btn sm",onClick:()=>nav(Ca(req))},"Ver ficha"),
   el("button",{type:"button",className:"vq-btn sm",disabled:req.phone==="",onClick:()=>onModal({kind:"call",name:j,phone:req.phone})},"Llamar"),
   el("button",{type:"button",className:"vq-btn sm",onClick:()=>req.userId>0?onModal({kind:"write",id:req.userId,name:j}):y.error("Este usuario no tiene id de backend.")},"Escribir")),
  warn!==null?el("div",{className:"vq-note warn"},warn):null,
  detErr!==null?el("div",{className:"vq-note err",style:{display:"flex",alignItems:"center",gap:10,flexWrap:"wrap"}},el("span",{style:{flex:"1 1 200px"}},"No se pudieron cargar los documentos del servidor."),el("button",{type:"button",className:"vq-btn sm",onClick:()=>void load()},"Reintentar")):null,
  el("div",{className:"vq-docs"},tiles.map(t=>{const[c,txt]=vqTileState(t,t.key===tileKey);return el("button",{key:t.key,type:"button",className:"vq-doc"+(t.key===tileKey?" on":""),onClick:()=>setTileKey(t.key)},
   el("span",{className:"vq-thumb"},t.url!==null&&!vqIsVideo(t.url)?el("img",{src:t.url,alt:"",loading:"lazy",onError:e=>{e.currentTarget.style.display="none"}}):el(Svg,{d:vqTileIcon(t.group),size:26})),
   el("span",{className:"vq-dl"},t.label),
   el("span",{className:c,style:{fontSize:11.5,fontWeight:700}},det===null&&req.userId>0&&!t.missing&&t.doc===null?"…":txt))})),
  el("div",{className:"vq-two"},
   el("div",{className:"vq-main"},
    el(Stage,{tile,onOpen:setLight}),
    tile?el("div",{className:"vq-cap-row"},
     el("span",{className:"vq-mut"},tile.label+(tile.doc&&tile.doc.createdAt?` · subida el ${vqWhen(tile.doc.createdAt)}`:"")),
     tile.doc&&tile.doc.id>0&&tile.doc.status!=="approved"?el("button",{type:"button",className:"vq-btn sm",disabled:busy!==null,onClick:()=>void docAct(tile.doc.id,"approve")},docBusy?"Un momento…":"Aprobar documento"):null,
     tile.doc&&tile.doc.id>0&&tile.doc.status!=="rejected"?el("button",{type:"button",className:"vq-btn sm red",disabled:busy!==null,onClick:()=>setDocReject({kind:"doc",id:tile.doc.id,label:tile.label})},"Rechazar documento…"):null):null,
    tile&&tile.doc&&tile.doc.status==="rejected"&&tile.doc.rejectionReason?el("div",{className:"vq-note err"},`Motivo: ${tile.doc.rejectionReason}`):null),
   el("div",{className:"vq-side"},
    selfie!==null&&idPhoto!==null?el("div",{style:{display:"flex",flexDirection:"column",gap:8}},
     el("div",{className:"vq-cap"},"¿ES LA MISMA PERSONA?"),
     el("div",{className:"vq-cmp"},
      el("button",{type:"button",onClick:()=>setLight({label:"Selfie biométrica",url:selfie})},el("span",{className:"ph"},el("img",{src:selfie,alt:"Selfie"})),el("span",{className:"vq-mut",style:{fontSize:12}},"Selfie")),
      el("button",{type:"button",onClick:()=>setLight({label:"Foto del documento",url:idPhoto})},el("span",{className:"ph doc"},el("img",{src:idPhoto,alt:"Documento"})),el("span",{className:"vq-mut",style:{fontSize:12}},isDriver?"Foto de la licencia":"Foto del documento")))):null,
    el("div",{style:{display:"flex",flexDirection:"column"}},
     el("div",{className:"vq-cap",style:{marginBottom:4}},"REVISA"),
     ["Se lee bien y no está cortada","El nombre es el de la cuenta","No está vencida","La cara es la de la selfie"].map((t,i)=>el("label",{key:t,className:"vq-ck"},el("input",{type:"checkbox",checked:checks[i],onChange:()=>setChecks(c=>c.map((v,k)=>k===i?!v:v))}),t))))),
  el("div",{style:{display:"flex",flexDirection:"column"}},
   el("div",{className:"vq-cap",style:{marginBottom:4}},"LO QUE ESCRIBIÓ EN LA APP"),
   el("div",{className:"vq-kvs"},kvs)),
  det!==null&&det.vehicles.length>0?el("div",{style:{display:"flex",flexDirection:"column",gap:8}},
   el("div",{className:"vq-cap"},det.vehicles.length===1?"VEHÍCULO":"VEHÍCULOS"),
   det.vehicles.map(v=>{const vs=VQ_STATUS[v.approvalStatus]||VQ_STATUS.pending,vb=busy===`v-${v.id}`;return el("div",{key:v.id,className:"vq-veh"+(v.isActive?" on":"")},
    el("span",{style:{fontSize:14,fontWeight:700,flex:"1 1 160px",minWidth:0}},v.label||"Vehículo"),
    v.isActive?el("span",{className:"vq-pill sm gold"},"EN USO"):null,
    v.plate!==""?el("span",{className:"vq-plate"},v.plate.toUpperCase()):null,
    el("span",{className:`vq-pill sm ${vs[0]}`},vs[1]),
    v.id>0&&v.approvalStatus!=="approved"?el("button",{type:"button",className:"vq-btn sm",disabled:busy!==null,onClick:()=>void vehAct(v.id,"approve")},vb?"Un momento…":"Aprobar vehículo"):null,
    v.id>0&&v.approvalStatus!=="approved"?el("button",{type:"button",className:"vq-btn sm red",disabled:busy!==null,onClick:()=>setDocReject({kind:"vehicle",id:v.id,label:v.label||"Vehículo"})},"Rechazar…"):null)})):null,
  !pending&&(req.reason||req.reviewedAt)?el("div",{className:req.status==="rejected"?"vq-note err":"vq-note warn"},
   req.reason?`Motivo del rechazo: ${req.reason}`:null,
   req.reason&&req.reviewedAt?" · ":null,
   req.reviewedAt?`Revisada el ${vqWhen(req.reviewedAt)}`:null):null,
  canDecide?el("div",{className:"vq-bar"},
   el("span",{className:"vq-mut",style:{fontSize:12.5,flex:"1 1 220px"}},"Al decidir, pasa sola a la siguiente persona."),
   el("button",{type:"button",className:"vq-btn big red",disabled:busy!==null,onClick:()=>setRejectOpen(!0)},busy==="reject"?"Rechazando…":"Rechazar…"),
   isDriver&&pending?el("button",{type:"button",className:"vq-btn big",disabled:busy!==null,title:"Ni aprobar ni rechazar: la verificación queda en pausa",onClick:()=>setConfirm("waitlist")},busy==="waitlist"?"Un momento…":"Lista de espera"):null,
   isDriver&&req.status==="waitlist"?el("button",{type:"button",className:"vq-btn big",disabled:busy!==null,title:"La cuenta vuelve a pendiente y puede resubir documentos",onClick:()=>setConfirm("unwaitlist")},busy==="unwaitlist"?"Un momento…":"Quitar de lista de espera"):null,
   el("button",{type:"button",className:"vq-btn big gold",style:{padding:"0 24px"},disabled:busy!==null,onClick:()=>setConfirm("approve")},busy==="approve"?"Aprobando…":"Aprobar")):null,
  confirm==="approve"?el(ConfirmBox,{title:"Aprobar verificación",message:`¿Aprobar la verificación de identidad de ${j}?`,confirmLabel:"Aprobar",busy:busy==="approve",onCancel:()=>setConfirm(null),onConfirm:()=>void decide("approve",()=>Se(req.docId),`${j} aprobado`)}):null,
  confirm==="waitlist"?el(ConfirmBox,{title:"Lista de espera",message:`¿Pasar a ${j} a la lista de espera? Su verificación queda en pausa — ni aprobada ni rechazada.`,confirmLabel:"Lista de espera",busy:busy==="waitlist",onCancel:()=>setConfirm(null),onConfirm:()=>void decide("waitlist",()=>Ce(req.docId),`${j} en lista de espera`)}):null,
  confirm==="unwaitlist"?el(ConfirmBox,{title:"Quitar de lista de espera",message:`¿Sacar a ${j} de la lista de espera? Su cuenta vuelve a pendiente y podrá resubir documentos.`,confirmLabel:"Quitar de lista de espera",busy:busy==="unwaitlist",onCancel:()=>setConfirm(null),onConfirm:()=>void decide("unwaitlist",()=>unwaitlistMut(req.docId),`${j} fuera de lista de espera`)}):null,
  rejectOpen?el(ReasonBox,{title:"Rechazar verificación",message:`¿Rechazar la verificación de ${j}?`,required:!0,chips:!0,confirmLabel:"Rechazar",busy:busy==="reject",onClose:()=>setRejectOpen(!1),onConfirm:r=>void decide("reject",()=>ke(req.docId,r.trim()),`${j} rechazado`)}):null,
  docReject!==null?el(ReasonBox,{title:docReject.kind==="vehicle"?"Rechazar vehículo":"Rechazar documento",message:`¿Rechazar «${docReject.label}»?`,required:!1,confirmLabel:"Rechazar",busy:busy!==null,onClose:()=>setDocReject(null),onConfirm:r=>{docReject.kind==="vehicle"?vehAct(docReject.id,"reject",r.trim()):docAct(docReject.id,"reject",r.trim())}}):null,
  light!==null?el(Lightbox,{media:light,onClose:()=>setLight(null)}):null,
  reAuthEl||null);
}

// ── Daily selfie (face check) review — same endpoints as the ficha ────
function FaceReview({fc,narrow,onBack,onDecided,onModal}){
 const nav=useNavigate();
 const[det,setDet]=React.useState(null),[busy,setBusy]=React.useState(null),[confirm,setConfirm]=React.useState(!1),[light,setLight]=React.useState(null);
 const[checks,setChecks]=React.useState([!1,!1,!1]);
 React.useEffect(()=>{let off=!1;ua(fc.user_id).then(d=>{if(!off)setDet(d)}).catch(()=>{});return()=>{off=!0}},[fc.user_id]);
 const name=fc.driver_name||`Conductor #${fc.user_id}`;
 const selfie=fc.file_path?S(fc.file_path):null,avatar=fc.photo_url?S(fc.photo_url):null;
 const lic=det&&det.license_front_url?S(det.license_front_url):null;
 const phone=det&&typeof det.phone=="string"?det.phone:"";
 const ms=vqAge(fc.created_at);
 const act=async verb=>{setBusy(verb);let done=!1;try{verb==="approve"?await approveFaceCheck(fc.id):await rejectFaceCheck(fc.id);y.success(verb==="approve"?`Selfie de ${name} aprobada`:`Selfie de ${name} rechazada · se le avisa y queda desconectado`);done=!0}catch(x){V(`No se pudo revisar la selfie: ${vqMsg(x)}`,()=>void act(verb))}finally{setBusy(null);setConfirm(!1)}if(done)onDecided(fc.id)};
 const cmp=(label,url,doc)=>url?el("button",{key:label,type:"button",onClick:()=>setLight({label,url})},el("span",{className:"ph"+(doc?" doc":"")},el("img",{src:url,alt:label})),el("span",{className:"vq-mut",style:{fontSize:12}},label)):null;
 return el("section",{className:"vq-box vq-review"},
  narrow?el("div",null,el("button",{type:"button",className:"vq-btn sm",onClick:onBack},"‹ Volver a la cola")):null,
  el("div",{className:"vq-head"},
   el(VqAvatar,{urls:avatar?[avatar]:[],name,big:!0}),
   el("div",{style:{flex:"1 1 220px",minWidth:0}},
    el("div",{style:{display:"flex",alignItems:"center",gap:8,flexWrap:"wrap"}},el("span",{style:{fontSize:19,fontWeight:800}},name),el("span",{className:"vq-pill blue"},"Conductor"),el("span",{className:`vq-pill ${vqTone(ms)}`},`Espera ${vqAgeTxt(ms)}`)),
    el("div",{className:"vq-mut",style:{fontSize:13,marginTop:3}},`#${fc.user_id} · selfie del día enviada el ${vqWhen(fc.created_at)}`)),
   el("button",{type:"button",className:"vq-btn sm",onClick:()=>nav(`/personas/driver/sql_${fc.user_id}`)},"Ver ficha"),
   el("button",{type:"button",className:"vq-btn sm",disabled:phone==="",onClick:()=>onModal({kind:"call",name,phone})},"Llamar"),
   el("button",{type:"button",className:"vq-btn sm",onClick:()=>onModal({kind:"write",id:fc.user_id,name})},"Escribir")),
  el("div",{className:"vq-two"},
   el("div",{className:"vq-main"},el(Stage,{tile:{key:"fc",label:"Selfie del día",url:selfie,missing:selfie===null},onOpen:setLight})),
   el("div",{className:"vq-side"},
    el("div",{style:{display:"flex",flexDirection:"column",gap:8}},
     el("div",{className:"vq-cap"},"¿ES LA MISMA PERSONA?"),
     el("div",{className:"vq-cmp"},cmp("Foto de perfil",avatar,!1),cmp("Foto de la licencia",lic,!0))),
    el("div",{style:{display:"flex",flexDirection:"column"}},
     el("div",{className:"vq-cap",style:{marginBottom:4}},"REVISA"),
     ["Se ve la cara completa","Es la misma persona del perfil","Cumple la norma de vestimenta"].map((t,i)=>el("label",{key:t,className:"vq-ck"},el("input",{type:"checkbox",checked:checks[i],onChange:()=>setChecks(c=>c.map((v,k)=>k===i?!v:v))}),t))))),
  el("div",{className:"vq-bar"},
   el("span",{className:"vq-mut",style:{fontSize:12.5,flex:"1 1 220px"}},"Al decidir, pasa sola a la siguiente selfie."),
   el("button",{type:"button",className:"vq-btn big red",disabled:busy!==null,onClick:()=>setConfirm(!0)},busy==="reject"?"Rechazando…":"Rechazar y desconectar"),
   el("button",{type:"button",className:"vq-btn big gold",style:{padding:"0 24px"},disabled:busy!==null,onClick:()=>void act("approve")},busy==="approve"?"Aprobando…":"Aprobar")),
  confirm?el(ConfirmBox,{title:"Rechazar selfie",message:`¿Rechazar y desconectar a ${name}? Se le notificará que no cumple las normas de vestimenta.`,confirmLabel:"Rechazar y desconectar",danger:!0,busy:busy==="reject",onCancel:()=>setConfirm(!1),onConfirm:()=>void act("reject")}):null,
  light!==null?el(Lightbox,{media:light,onClose:()=>setLight(null)}):null);
}

// ── The page ──────────────────────────────────────────────────────────
const VQ_TABS=[["pending","Por revisar"],["selfies","Selfies diarias"],["waitlist","Lista de espera"],["approved","Aprobados"],["rejected","Rechazados"],["all","Todos"]];
const VQ_ROLES=[["","Todos"],["rider","Pasajeros"],["driver","Conductores"]];
const VQ_PAGE=50;

function Page({onRetry}){
 vqCss();ensureProfileCss();
 const nav=useNavigate();
 const{rows,loading,error,rosterWarning}=qe();
 const[role,setRole]=React.useState(""),[tab,setTab]=React.useState("pending"),[search,setSearch]=React.useState(""),[limit,setLimit]=React.useState(VQ_PAGE);
 const[sel,setSel]=React.useState(null),[fcSel,setFcSel]=React.useState(null),[open,setOpen]=React.useState(!1);
 const[narrow,setNarrow]=React.useState(!1);const wrapRef=React.useRef(null);
 const[modal,setModal]=React.useState(null);
 const[tools,setTools]=React.useState(!1),[syncing,setSyncing]=React.useState(!1),[backf,setBackf]=React.useState(!1),[cleaning,setCleaning]=React.useState(!1),[orphans,setOrphans]=React.useState(null);
 const toolsRef=React.useRef(null);
 React.useEffect(()=>{const n=wrapRef.current;if(!n||typeof ResizeObserver=="undefined")return;const ro=new ResizeObserver(es=>{const w=es[0]&&es[0].contentRect?es[0].contentRect.width:n.clientWidth;if(w>=40)setNarrow(w<760)});ro.observe(n);return()=>ro.disconnect()},[]);
 React.useEffect(()=>{if(!tools)return;const f=e=>{if(toolsRef.current&&!toolsRef.current.contains(e.target))setTools(!1)};document.addEventListener("mousedown",f);return()=>document.removeEventListener("mousedown",f)},[tools]);
 // Daily selfies: GET /admin/face-checks/pending, again after every verdict and once a minute.
 const[fcs,setFcs]=React.useState(null),[fcErr,setFcErr]=React.useState(null);
 const loadFc=React.useCallback(async()=>{try{const d=await Ze("/admin/face-checks/pending",{retry:{maxAttempts:1}});setFcs(d!==null&&typeof d=="object"&&Array.isArray(d.face_checks)?d.face_checks:[]);setFcErr(null)}catch(x){setFcErr(vqMsg(x))}},[]);
 React.useEffect(()=>{loadFc();const t=setInterval(()=>{if(document.visibilityState==="visible")loadFc()},6e4);return()=>clearInterval(t)},[loadFc]);

 const b=React.useMemo(()=>wa(rows,role),[rows,role]);
 const cnt=React.useMemo(()=>Sa(b),[b]);
 const rc=React.useMemo(()=>({"":rows.length,rider:rows.filter(d=>d.role==="rider").length,driver:rows.filter(d=>d.role==="driver").length}),[rows]);
 const oldestFirst=tab==="pending"||tab==="waitlist";
 const list=React.useMemo(()=>{if(tab==="selfies")return[];const l=ka(b,tab,search);if(oldestFirst)l.sort((x,z)=>vqTs(x.submittedAt,Infinity)-vqTs(z.submittedAt,Infinity));return l},[b,tab,search,oldestFirst]);
 const fcList=React.useMemo(()=>{const q=search.trim().toLowerCase();const l=(fcs||[]).filter(f=>q===""||String(f.driver_name||"").toLowerCase().includes(q)||String(f.user_id).includes(q));return[...l].sort((x,z)=>vqTs(x.created_at,Infinity)-vqTs(z.created_at,Infinity))},[fcs,search]);
 const oldest=React.useMemo(()=>{let m=null;for(const r of b)if(r.status==="pending"){const t=vqTs(r.submittedAt,null);t!==null&&(m===null||t<m)&&(m=t)}return m},[b]);
 React.useEffect(()=>{setLimit(VQ_PAGE)},[tab,role,search]);
 React.useEffect(()=>{setOpen(!1)},[tab]);
 // Keep a selection: on a wide page the first of the queue opens by itself.
 React.useEffect(()=>{if(tab==="selfies")return;if(sel!==null&&list.some(r=>r.docId===sel))return;if(narrow){if(sel!==null){setSel(null);setOpen(!1)}return}setSel(list.length>0?list[0].docId:null)},[list,sel,narrow,tab]);
 React.useEffect(()=>{if(tab!=="selfies")return;if(fcSel!==null&&fcList.some(f=>f.id===fcSel))return;if(narrow){if(fcSel!==null){setFcSel(null);setOpen(!1)}return}setFcSel(fcList.length>0?fcList[0].id:null)},[fcList,fcSel,narrow,tab]);

 const current=tab==="selfies"?null:list.find(r=>r.docId===sel)||null;
 const fcCur=tab==="selfies"?fcList.find(f=>f.id===fcSel)||null:null;
 const decided=React.useCallback(id=>{const i=list.findIndex(r=>r.docId===id),nx=i>=0?list[i+1]||list[i-1]||null:null;setSel(nx?nx.docId:null);if(!nx)setOpen(!1)},[list]);
 const fcDecided=React.useCallback(id=>{const i=fcList.findIndex(f=>f.id===id),nx=i>=0?fcList[i+1]||fcList[i-1]||null:null;setFcSel(nx?nx.id:null);if(!nx)setOpen(!1);loadFc()},[fcList,loadFc]);

 const sync=async()=>{setTools(!1);setSyncing(!0);try{await ja();y.success("Cachés sincronizados · la cola se refresca sola");onRetry()}catch(d){y.error(`No se pudo sincronizar: ${vqMsg(d)}`,{label:"Reintentar",onPress:()=>void sync()})}finally{setSyncing(!1)}};
 const backfill=async()=>{setTools(!1);setBackf(!0);try{await ba();y.success("Backfill lanzado · los conductores aprobados se re-sincronizan")}catch(d){y.error(`No se pudo lanzar el backfill: ${vqMsg(d)}`,{label:"Reintentar",onPress:()=>void backfill()})}finally{setBackf(!1)}};
 const clean=async()=>{setTools(!1);setCleaning(!0);try{const d=await it();d.length===0?y.info("No hay fichas huérfanas: todas apuntan a cuentas existentes."):setOrphans(d)}catch(d){y.error(`No se pudo comprobar el backend: ${vqMsg(d)}`,{label:"Reintentar",onPress:()=>void clean()})}finally{setCleaning(!1)}};
 const cleanGo=async()=>{const d=orphans||[];setCleaning(!0);try{const ok=await rt(d),m=Fa(d.length,ok);ok===d.length?y.success(m):y.error(m);setOrphans(null)}finally{setCleaning(!1)}};

 if(error!==null)return el("div",{className:"vq-page"},
  el("div",{className:"vq-top"},el("div",null,el("h1",null,"Verificación"))),
  el("div",{className:"vq-note err"},`No se pudieron cargar las solicitudes: ${error}`),
  el("div",null,el("button",{type:"button",className:"vq-btn",onClick:onRetry},"Reintentar")));

 const selfiesTab=tab==="selfies";
 const hideQueue=narrow&&open,hideReview=narrow&&!open;
 const qRows=selfiesTab?fcList:list;
 const pos=selfiesTab?fcList.findIndex(f=>f.id===fcSel):list.findIndex(r=>r.docId===sel);
 const searching=search.trim()!=="";
 const empty=selfiesTab?(fcs===null?null:fcErr!==null&&fcs.length===0?["No se pudieron cargar las selfies",fcErr]:searching?["Sin resultados",`Nada coincide con «${search.trim()}»`]:["Sin selfies por revisar","Cuando un conductor mande su selfie del día aparece aquí"]):
  searching?["Sin resultados",`Nada coincide con «${search.trim()}»`]:tab==="pending"?["Sin verificaciones pendientes","Toda solicitud revisada aparece en Aprobados o Rechazados"]:["Sin solicitudes de verificación","Cuando alguien envíe sus documentos aparecerá aquí"];

 const tabCount=k=>k==="selfies"?(fcs===null?"…":fcs.length):k==="all"?cnt.all:cnt[k];
 return el("div",{ref:wrapRef,className:"vq-page"+(narrow?" vq-narrow":"")},
  el("div",{className:"vq-top"},
   el("div",{style:{flex:"1 1 260px",minWidth:0}},
    el("h1",null,"Verificación"),
    el("div",{className:"vq-sub"},selfiesTab?`${fcs?fcs.length:0} selfie${fcs&&fcs.length===1?"":"s"} del día por revisar`:`${cnt.pending} por revisar`,!selfiesTab&&oldest!==null?" · la más vieja espera ":null,!selfiesTab&&oldest!==null?el("b",null,vqAgeTxt(Date.now()-oldest)):null)),
   el("label",{className:"vq-search"},el(Svg,{d:ICON.search,size:16}),el("input",{"aria-label":"Buscar en verificación",placeholder:"Nombre, teléfono o correo",value:search,onChange:e=>setSearch(e.target.value)})),
   el("div",{ref:toolsRef,style:{position:"relative"}},
    el("button",{type:"button",className:"vq-btn","aria-expanded":tools,onClick:()=>setTools(v=>!v)},syncing||backf||cleaning?"Trabajando…":"⋯ Herramientas"),
    tools?el("div",{className:"vq-menu"},
     el("button",{type:"button",className:"vq-mi",disabled:syncing,onClick:()=>void sync()},"Sincronizar",el("small",null,"Recarga los cachés del roster y de veredictos")),
     el("button",{type:"button",className:"vq-mi",disabled:backf,onClick:()=>void backfill()},"Backfill",el("small",null,"Re-sincroniza a los conductores aprobados")),
     el("button",{type:"button",className:"vq-mi",disabled:cleaning,onClick:()=>void clean()},"Limpiar huérfanas",el("small",null,"Borra fichas de cuentas que ya no existen"))):null)),
  rosterWarning!==null&&rosterWarning!==void 0?el("div",{className:"vq-note warn"},rosterWarning):null,
  el("div",{className:"vq-tabs-row"},
   el("div",{className:"vq-tabs"},VQ_TABS.map(([k,l])=>el("button",{key:k,type:"button",className:"vq-tab"+(tab===k?" on":"")+(k==="pending"||k==="selfies"?" hot":""),onClick:()=>setTab(k)},l,el("b",null,String(tabCount(k)))))),
   selfiesTab?null:el("div",{className:"vq-tabs"},VQ_ROLES.map(([k,l])=>el("button",{key:"r"+k,type:"button",className:"vq-chip"+(role===k?" on":""),onClick:()=>setRole(k)},l,el("b",null,String(rc[k])))))),
  el("div",{className:"vq-cols"},
   el("div",{className:"vq-box vq-queue"+(hideQueue?" vq-hide":"")},
    el("div",{className:"vq-qhead"},el("span",{className:"vq-cap",style:{flex:"1 1 auto"}},oldestFirst||selfiesTab?"MÁS VIEJOS PRIMERO":"MÁS RECIENTES PRIMERO"),el("span",{className:"vq-mut",style:{fontSize:12}},qRows.length===0?"":pos>=0?`${pos+1} de ${qRows.length}`:`${qRows.length}`)),
    (selfiesTab?fcs===null:loading)?[0,1,2,3,4].map(i=>el("div",{key:i,className:"vq-skel"})):
    qRows.length===0?el("div",{className:"vq-empty"},empty?el("b",null,empty[0]):null,empty?empty[1]:null):
    selfiesTab?fcList.slice(0,limit).map(f=>{const fms=vqAge(f.created_at),nm=f.driver_name||`Conductor #${f.user_id}`;return el("button",{key:f.id,type:"button",className:"vq-q"+(f.id===fcSel?" on":""),onClick:()=>{setFcSel(f.id);setOpen(!0)}},
      el(VqAvatar,{urls:f.photo_url?[S(f.photo_url)]:[],name:nm}),
      el("span",{style:{flex:"1 1 auto",minWidth:0,display:"flex",flexDirection:"column",gap:3}},el("span",{className:"vq-cut",style:{fontSize:14,fontWeight:600}},nm),el("span",{className:"vq-cut vq-mut",style:{fontSize:12.5}},"Conductor · selfie del día")),
      el("span",{className:`vq-pill sm ${vqTone(fms)}`},vqAgeTxt(fms)))}):
    list.slice(0,limit).map(r=>{const rms=vqAge(r.submittedAt),rs=VQ_STATUS[r.status]||VQ_STATUS.pending;return el("button",{key:r.docId,type:"button",className:"vq-q"+(r.docId===sel?" on":""),onClick:()=>{setSel(r.docId);setOpen(!0)}},
      el(VqAvatar,{urls:ie(r),name:D(r)}),
      el("span",{style:{flex:"1 1 auto",minWidth:0,display:"flex",flexDirection:"column",gap:3}},el("span",{className:"vq-cut",style:{fontSize:14,fontWeight:600}},D(r)),el("span",{className:"vq-cut vq-mut",style:{fontSize:12.5}},`${vqRole(r.role)} · ${vqSummary(r)}`)),
      r.status==="pending"?el("span",{className:`vq-pill sm ${vqTone(rms)}`},vqAgeTxt(rms)):el("span",{className:`vq-pill sm ${rs[0]}`},r.status==="waitlist"?"En espera":rs[1]))}),
    qRows.length>limit?el("div",{style:{padding:"12px 14px",borderTop:"1px solid rgba(255,255,255,.05)"}},el("button",{type:"button",className:"vq-btn",style:{width:"100%"},onClick:()=>setLimit(n=>n+VQ_PAGE)},`Mostrar ${Math.min(VQ_PAGE,qRows.length-limit)} más de ${qRows.length-limit}`)):null),
   el("div",{className:"vq-rwrap"+(hideReview?" vq-hide":"")},selfiesTab?(fcCur?el(FaceReview,{key:"fc"+fcCur.id,fc:fcCur,narrow,onBack:()=>setOpen(!1),onDecided:fcDecided,onModal:setModal}):el("div",{className:"vq-box vq-review"},el("div",{className:"vq-empty"},fcs===null?"Cargando…":"No hay selfies por revisar"))):
    current?el(Review,{key:current.docId,req:current,narrow,onBack:()=>setOpen(!1),onDecided:decided,onModal:setModal}):el("div",{className:"vq-box vq-review"},el("div",{className:"vq-empty"},loading?"Cargando…":"Elige a alguien de la cola")))),
  modal!==null&&modal.kind==="call"?el(CallModal,{name:modal.name,phone:modal.phone,onClose:()=>setModal(null),toast:m=>y.success(m)}):null,
  modal!==null&&modal.kind==="write"?el(WriteBox,{id:modal.id,name:modal.name,onClose:()=>setModal(null),navigate:nav}):null,
  orphans!==null?el(ConfirmBox,{title:`Limpiar ${orphans.length} ficha${orphans.length===1?"":"s"}`,message:"Sus cuentas ya no existen en el backend, así que estas fichas no corresponden a ningún usuario. No se toca ninguna cuenta activa ni ningún perfil.",confirmLabel:"Limpiar",danger:!0,busy:cleaning,onCancel:()=>setOrphans(null),onConfirm:()=>void cleanGo()}):null);
}

function VerificationQueue(){const[k,setK]=React.useState(0);return el(Page,{key:k,onRetry:()=>setK(n=>n+1)})}
export{VerificationQueue};
