// DL COMANDA PRO · MODO DEMOSTRACIÓN
// Reemplaza la conexión a la base de datos por datos de ejemplo en memoria, para recorrer la app
// sin crear cuenta. Nada de lo que se haga aquí se guarda.
(function(){
window.__dcDemo=true;
const uid=()=>(crypto.randomUUID?crypto.randomUUID():"d"+Math.random().toString(36).slice(2));
const now=()=>new Date().toISOString();
const hace=min=>new Date(Date.now()-min*60000).toISOString();
const today=()=>new Intl.DateTimeFormat("en-CA",{timeZone:"America/Bogota"}).format(new Date());
const EMP="demo";
function qrFalso(){try{const c=document.createElement("canvas");c.width=c.height=330;const x=c.getContext("2d");x.fillStyle="#fff";x.fillRect(0,0,330,330);x.fillStyle="#000";
  let s=7;const r=()=>(s=(s*9301+49297)%233280)/233280;for(let i=0;i<33;i++)for(let j=0;j<33;j++)if(r()<.5)x.fillRect(i*10,j*10,10,10);
  [[0,0],[230,0],[0,230]].forEach(([a,b])=>{x.fillStyle="#000";x.fillRect(a,b,100,100);x.fillStyle="#fff";x.fillRect(a+10,b+10,80,80);x.fillStyle="#000";x.fillRect(a+25,b+25,50,50);});
  return c.toDataURL("image/png");}catch(e){return "data:image/png;base64,";}}
const PROD=[["Bandeja paisa","Platos fuertes",32000,"cocina"],["Churrasco","Platos fuertes",38000,"cocina"],["Pechuga a la plancha","Platos fuertes",28000,"cocina"],["Hamburguesa de la casa","Platos fuertes",25000,"cocina"],
  ["Empanadas x3","Entradas",9000,"cocina"],["Patacones con hogao","Entradas",12000,"cocina"],["Limonada de coco","Bebidas",9000,"bar"],["Jugo natural","Bebidas",7000,"bar"],["Gaseosa","Bebidas",4000,"bar"],["Cerveza nacional","Bebidas",6000,"bar"],["Tres leches","Postres",8000,"cocina"]];
const db={
  empresas:[{id:EMP,nombre:"Restaurante Demo",nit:"900000000-1",plan:"premium",estaciones:true}],
  mesas:[1,2,3,4,5,6,7,8].map(i=>({id:"m"+i,empresa_id:EMP,nombre:i===8?"Barra":"Mesa "+i,orden:i,activa:true,creado:now()})),
  productos:PROD.map((x,i)=>({id:"p"+i,empresa_id:EMP,nombre:x[0],categoria:x[1],precio:x[2],activo:true,orden:i,creado:now(),estacion:x[3],agotado:false})),
  pedidos:[],pedido_items:[],cobros:[],cajas:[],caja_movs:[],qr_pagos:[],
  personal:[{id:"s1",empresa_id:EMP,usuario:"Juan",rol:"mesero",activo:true,creado:hace(9000)},{id:"s2",empresa_id:EMP,usuario:"Caja",rol:"cocina",permisos:["caja"],activo:true,creado:hace(9000)},
    {id:"s3",empresa_id:EMP,usuario:"Cocina",rol:"cocina",permisos:["cocina"],activo:true,creado:hace(9000)},{id:"s4",empresa_id:EMP,usuario:"Barra",rol:"cocina",permisos:["bar","caja"],activo:true,creado:hace(9000)}],
};
// pedidos de ejemplo en distintos estados
let NUM=0;
function ped(mesa,items,estado,min,extra){const m=db.mesas.find(x=>x.id===mesa);const id=uid();let t=0;
  items.forEach(([pi,c,nota])=>{const p=db.productos[pi];db.pedido_items.push({id:db.pedido_items.length+1,pedido_id:id,producto_id:p.id,nombre:p.nombre,precio:p.precio,cant:c,nota:nota||null});t+=p.precio*c;});
  const est=db.productos[items[0][0]].estacion;
  db.pedidos.push(Object.assign({id,empresa_id:EMP,numero:++NUM,fecha:today(),mesa_id:m.id,mesa:m.nombre,mesero_id:"s1",mesero:"Juan",estado,nota:null,total:t,pagado:false,creado:hace(min),actualizado:hace(Math.max(0,min-6)),estacion:est,
    preparando_en:estado!=="nuevo"?hace(min-2):null,listo_en:estado==="listo"||estado==="entregado"?hace(min-8):null},extra||{}));}
ped("m1",[[0,2,"Sin chicharrón"],[4,1]],"entregado",25);ped("m1",[[6,2]],"entregado",24);
ped("m2",[[1,1],[5,1]],"nuevo",2);ped("m2",[[9,2]],"nuevo",2);
ped("m3",[[3,2,"Término medio"]],"preparando",9);
ped("m4",[[2,1],[10,1]],"listo",14);
ped("m5",[[0,1],[7,1]],"entregado",40);
ped("m6",[[4,2],[8,2]],"entregado",8);
Object.assign(db.mesas.find(x=>x.id==="m6"),{cuenta_en:hace(1),cuenta_propina:true,cuenta_por:"Juan"});
// caja abierta con un cobro
db.cajas.push({id:"cj1",empresa_id:EMP,estado:"abierta",base:150000,conteo_base:{"50000":2,"20000":2,"10000":1},abierta_por:"Caja",abierta_en:hace(300)});
db.cobros.push({caja_id:"cj1",id:"cb1",empresa_id:EMP,fecha:today(),mesa_id:"m7",mesa:"Mesa 7",subtotal:86000,descuento:0,propina:8600,total:94600,metodo:"mixto",recibido:null,cajero:"Caja",pedidos:2,creado:hace(60),
  cobro_pagos:[{metodo:"efectivo",monto:50000,persona:"Persona 1"},{metodo:"transferencia",monto:44600,persona:"Persona 2"}]});
db.qr_pagos.push({id:"q1",empresa_id:EMP,nombre:"Nequi",detalle:"300 000 0000 · Restaurante Demo",img:qrFalso(),orden:0});
const ROLE="dueno";
let session={user:{id:"demo-dueno",email:"demo@dlcompany.co",is_anonymous:false},access_token:"demo"};
const perfil={rol:ROLE,empresa_id:EMP,personal_id:null};
const handlers=[];const emit=(t,ev,row)=>handlers.filter(h=>h.t===t).forEach(h=>{try{h.fn({eventType:ev,new:row});}catch(e){}});window.__emit=emit;
function withItems(p){return {...p,pedido_items:db.pedido_items.filter(i=>i.pedido_id===p.id).map(i=>({...i}))};}
function q(table){
  let filters=[],single=false,op="select",payload=null;
  const b={
    select(){return b;},eq(k,v){filters.push(r=>r[k]===v);return b;},neq(k,v){filters.push(r=>r[k]!==v);return b;},
    or(){filters.push(r=>(!r.pagado&&r.estado!=="cancelado")||r.fecha===today());return b;},
    order(){return b;},limit(){return b;},gte(){return b;},lt(){return b;},lte(){return b;},gt(){return b;},in(){return b;},is(){return b;},not(){return b;},maybeSingle(){single=true;return b;},single(){single=true;return b;},
    insert(d){op="insert";payload=d;return b;},update(d){op="update";payload=d;return b;},delete(){op="delete";return b;},upsert(d){op="insert";payload=d;return b;},
    then(res,rej){
      let data;
      if(table==="perfiles")data=[perfil];
      else{
        const arr=db[table]||(db[table]=[]);
        if(op==="insert"){const r={id:uid(),creado:now(),...payload};arr.push(r);data=[r];}
        else{
          let m=arr.filter(r=>filters.every(f=>f(r)));
          if(op==="update")m.forEach(r=>Object.assign(r,payload));
          if(op==="delete")m.forEach(r=>arr.splice(arr.indexOf(r),1));
          data=m;
        }
        if(table==="pedidos")data=data.map(withItems);
      }
      return Promise.resolve({data:single?(data[0]||null):data,error:null}).then(res,rej);
    }
  };return b;
}
const rpcs={
  mi_rol:()=>ROLE,
  guardar_qr:a=>{if(a.p_id){const q=db.qr_pagos.find(x=>x.id===a.p_id);q.nombre=a.p_nombre;q.detalle=a.p_detalle;if(a.p_img)q.img=a.p_img;return q.id;}const r={id:uid(),empresa_id:EMP,nombre:a.p_nombre,detalle:a.p_detalle,img:a.p_img,orden:db.qr_pagos.length};db.qr_pagos.push(r);return r.id;},
  borrar_qr:a=>{db.qr_pagos=db.qr_pagos.filter(x=>x.id!==a.p_id);},
  mis_permisos:()=>["mesero","cocina","bar","caja"],
  nit_disponible:()=>true,
  crear_pedido:a=>{const m=db.mesas.find(x=>x.id===a.p_mesa);const groups={};
    a.p_items.forEach(it=>{const pr=db.productos.find(x=>x.id===it.pid);const e=db.empresas[0].estaciones?pr.estacion:"cocina";(groups[e]=groups[e]||[]).push([pr,it]);});
    const out=[];["cocina","bar"].filter(e=>groups[e]).forEach(e=>{const num=db.pedidos.filter(p=>p.fecha===today()).length+1;
      const p={id:uid(),empresa_id:EMP,numero:num,fecha:today(),mesa_id:m.id,mesa:m.nombre,mesero_id:perfil.personal_id,mesero:"Dueño",estado:"nuevo",nota:a.p_nota,total:0,pagado:false,creado:now(),actualizado:now(),estacion:e};
      db.pedidos.push(p);let t=0;groups[e].forEach(([pr,it])=>{db.pedido_items.push({id:db.pedido_items.length+1,pedido_id:p.id,producto_id:pr.id,nombre:pr.nombre,precio:pr.precio,cant:it.cant,nota:it.nota});t+=pr.precio*it.cant;});
      p.total=t;out.push({id:p.id,numero:num,estacion:e,total:t});setTimeout(()=>emit("pedidos","INSERT",{...p}),50);});
    return {id:out[0].id,numero:out[0].numero,total:out.reduce((x,y)=>x+y.total,0),pedidos:out};},
  config_estaciones:a=>{db.empresas[0].estaciones=a.p_activar;return null;},
  cambiar_estado:a=>{const p=db.pedidos.find(x=>x.id===a.p_id);p.estado=a.p_estado;p.actualizado=now();if(a.p_estado==="listo")p.listo_en=now();setTimeout(()=>emit("pedidos","UPDATE",{...p}),50);return {ok:true};},
  cobrar_mesa:a=>{let t=0,n=0;const cid=uid();const ps=db.pedidos.filter(p=>p.mesa_id===a.p_mesa&&!p.pagado&&p.estado!=="cancelado");ps.forEach(p=>{p.pagado=true;p.cobro_id=cid;p.metodo=a.p_metodo;p.pagado_en=now();if(p.estado!=="entregado")p.estado="entregado";t+=p.total;n++;});
    const tot=t-(a.p_descuento||0)+(a.p_propina||0);const pg=a.p_pagos||[{metodo:a.p_metodo,monto:tot,recibido:a.p_recibido}];const sum=pg.reduce((x,y)=>x+y.monto,0);if(sum!==tot)throw "Los pagos suman "+sum+" y la cuenta es "+tot;
    const mets=[...new Set(pg.map(x=>x.metodo))];const cj=db.cajas.find(x=>x.estado==="abierta");db.cobros.push({caja_id:cj?cj.id:null,id:cid,empresa_id:EMP,fecha:today(),mesa_id:a.p_mesa,mesa:ps[0].mesa,subtotal:t,descuento:a.p_descuento||0,propina:a.p_propina||0,total:tot,metodo:mets.length>1?"mixto":mets[0],recibido:pg.length===1?pg[0].recibido:null,cajero:"Caja",pedidos:n,creado:now(),cobro_pagos:pg});
    return {ok:true,id:cid,subtotal:t,descuento:a.p_descuento||0,propina:a.p_propina||0,total:tot,pedidos:n};},
  mover_mesa:a=>{const d=db.mesas.find(m=>m.id===a.p_destino);let n=0;db.pedidos.filter(p=>p.mesa_id===a.p_origen&&!p.pagado).forEach(p=>{p.mesa_id=d.id;p.mesa=d.nombre;n++;});return n;},
  pedir_cuenta:a=>{const m=db.mesas.find(x=>x.id===a.p_mesa);m.cuenta_en=now();m.cuenta_propina=a.p_propina;m.cuenta_por="Dueño";setTimeout(()=>emit("mesas","UPDATE",{...m}),50);return {ok:true};},
  anular_cuenta:a=>{const m=db.mesas.find(x=>x.id===a.p_mesa);m.cuenta_en=null;return null;},
  abrir_caja:a=>{const c={id:uid(),empresa_id:EMP,estado:"abierta",base:a.p_base,conteo_base:a.p_conteo||null,abierta_por:"Caja",abierta_en:now()};db.cajas.push(c);return c.id;},
  mov_caja:a=>{const c=db.cajas.find(x=>x.estado==="abierta");db.caja_movs.push({id:db.caja_movs.length+1,caja_id:c.id,tipo:a.p_tipo,monto:a.p_monto,motivo:a.p_motivo,por:"Caja",creado:now()});return null;},
  resumen_caja:a=>{const c=db.cajas.find(x=>x.id===a.p_caja);const cs=db.cobros.filter(x=>x.caja_id===c.id);const pg=k=>cs.reduce((t,x)=>t+(x.cobro_pagos||[]).filter(p=>p.metodo===k).reduce((u,p)=>u+p.monto,0),0);
    const mv=k=>db.caja_movs.filter(m=>m.caja_id===c.id&&m.tipo===k).reduce((t,m)=>t+m.monto,0);
    return {base:c.base,efectivo:pg("efectivo"),tarjeta:pg("tarjeta"),transferencia:pg("transferencia"),entradas:mv("entrada"),salidas:mv("salida"),propinas:cs.reduce((t,x)=>t+x.propina,0),descuentos:0,cobros:cs.length,esperado:c.base+pg("efectivo")+mv("entrada")-mv("salida")};},
  cerrar_caja:a=>{const c=db.cajas.find(x=>x.estado==="abierta");const r=rpcs.resumen_caja({p_caja:c.id});Object.assign(c,r,{estado:"cerrada",contado:a.p_contado,diferencia:a.p_contado-r.esperado,cerrada_en:now(),cerrada_por:"Caja"});return {...r,id:c.id,contado:a.p_contado,diferencia:a.p_contado-r.esperado};},
  es_superadmin:()=>false,
  generar_codigos:a=>Array.from({length:a.p_cant},(_,i)=>`DLC-${a.p_plan==="pro"?"PRO":"PRE"}-${a.p_meses}M-AB${i}D-EFGH`),
  listar_codigos:()=>[{codigo:"DLC-PRO-14M-ABCD-EFGH",plan:"pro",meses:14,nota:"Asadero La 13",creado:now(),usado_en:null,anulado:false},{codigo:"DLC-PRE-1M-ZZZZ-YYYY",plan:"premium",meses:1,nota:null,creado:now(),usado_en:now(),usado_nombre:"Pizzería X",anulado:false}],
  empresas_admin:()=>[{id:"e1",nombre:"Asadero La 13",nit:"900111222-3",creado:now(),cuenta_creada:now(),ultimo_ingreso:now(),plan:"premium",activo:"premium",prueba:true,vence:"2026-11-22",correo:"due@x.co",mesas:7,personal:1,pedidos30:12,compras:0,historial:[]},{id:"e2",nombre:"Pizzería Don Luis",nit:"901222333",creado:"2026-11-10T15:00:00Z",cuenta_creada:"2026-11-10T15:00:00Z",ultimo_ingreso:"2026-11-20T20:00:00Z",plan:"pro",activo:"premium",bono:true,prueba:false,vence:"2028-01-21",plan_desde:"2026-11-21T10:46:00Z",plan_origen:"Código DLC-PRO-14M-MPXG-LVKM",correo:"donluis@gmail.com",mesas:8,personal:3,pedidos30:340,compras:1,historial:[{plan:"pro",meses:14,vence:"2028-01-21",origen:"Código DLC-PRO-14M-MPXG-LVKM",bono:true,fecha:"2026-11-21T10:46:00Z"}]}],
  canjear_codigo:a=>({plan:"pro",meses:14,vence:"2028-01-20",nombre:"Asadero La 13",bono:true,bono_vence:"2026-11-26"}),
  revisar_plan:()=>{const P="premium";const L={premium:{mesas:null,productos:null,usuarios:null,pedidos_dia:null,historial:null,push:true,imprimir:true,dividir:true,caja:true,excel:true,mover:true,estaciones:true,stock:true,soporte:true},
    pro:{mesas:8,productos:80,usuarios:4,pedidos_dia:50,historial:90,push:true,imprimir:true,dividir:true,caja:true,excel:true,mover:true,estaciones:false,stock:false,soporte:false},
    gratis:{mesas:5,productos:20,usuarios:2,pedidos_dia:25,historial:1,push:false,imprimir:false,dividir:false,caja:false,excel:false,mover:false,estaciones:false,stock:false,soporte:false}};
    return {plan:P,contratado:P,bono:false,bono_vence:null,vence:null,prueba:false,limites:L[P],uso:{mesas:db.mesas.length,productos:db.productos.length,usuarios:db.personal.length,pedidos_hoy:3}};},
  guardar_push:()=>null,borrar_push:()=>null,
  crear_personal:a=>{const r={id:uid(),empresa_id:EMP,usuario:a.p_usuario,rol:a.p_rol,permisos:a.p_permisos,activo:true,creado:now()};db.personal.push(r);return {...r,pin:"4821"};},
  editar_personal:a=>{const p=db.personal.find(x=>x.id===a.p_id);if(p)Object.assign(p,{usuario:a.p_usuario,rol:a.p_rol,activo:a.p_activo,permisos:a.p_rol==="cocina"?(a.p_permisos||p.permisos):null});return null;},
  regenerar_pin:()=>"4821",eliminar_personal:a=>{db.personal=db.personal.filter(x=>x.id!==a.p_id);return null;},
  editar_empresa:a=>{Object.assign(db.empresas[0],{nombre:a.p_nombre||db.empresas[0].nombre});return null;},
};
const authCbs=[];
window.supabase={createClient(){return {
  auth:{getSession:async()=>({data:{session}}),onAuthStateChange(cb){authCbs.push(cb);setTimeout(()=>cb("INITIAL_SESSION",session),0);return {data:{subscription:{unsubscribe(){}}}};},
    signInWithPassword:async()=>({error:null}),signInAnonymously:async()=>({error:null}),signOut:async()=>{location.replace(location.pathname);return {error:null};},
    signUp:async()=>({data:{},error:null}),resetPasswordForEmail:async()=>({error:null}),updateUser:async()=>({error:null})},
  from:q,
  rpc:async(fn,a)=>{if(!rpcs[fn])return {data:null,error:null};try{return {data:rpcs[fn](a||{}),error:null};}catch(e){return {data:null,error:{message:String(e)}};}},
  realtime:{setAuth(){}},
  channel(){const ch={on(type,f,fn){handlers.push({t:f.table,fn});return ch;},subscribe(cb){setTimeout(()=>cb("SUBSCRIBED"),20);return ch;}};return ch;},
  removeChannel:async()=>{}
};}};
})();
