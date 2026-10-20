import {batchAllowed,moduleAllowed,featureAllowed} from './permissions.js';
export async function equipmentRequest(ctx,batch,action='list',payload={}){
 const s=ctx.data;if(!s.batches.some(b=>b.id===batch)||!moduleAllowed(s,'farm')||!batchAllowed(s,batch,'farm'))throw Error('ไม่มีสิทธิ์เข้าถึงเล้านี้');
 if(ctx.db.live){if(!navigator.onLine)throw Error('ต้องออนไลน์เพื่ออ่านหรือแก้ไขรายการอุปกรณ์');try{return await ctx.db.rpc('twin_equipment_manage',{p_batch:batch,p_action:action,p_data:payload});}catch(e){if(e.code==='PGRST202'||e.code==='42883')throw Error('ยังไม่ได้ติดตั้งฐานข้อมูลอุปกรณ์: โปรดติดตั้ง 031_twin_equipment.sql');throw e;}}
 const canWrite=featureAllowed(s,'farm.batches',true)&&(s.context?.is_admin||s.context?.farm_write_ids?.includes(batch));if(action!=='list'&&!canWrite)throw Error('ไม่มีสิทธิ์แก้ไข');
 const key='ducky-twin-equipment-demo-v1';let db;try{db=JSON.parse(localStorage.getItem(key))}catch{}db||={bindings:{},houses:[],items:[]};let housingId=db.bindings[batch]||s.batches.find(b=>b.id===batch)?.housing_id||null;
 if(action==='create_housing'){if(housingId)throw Error('ล็อตนี้มีเล้าแล้ว');if(!payload.name?.trim())throw Error('ระบุชื่อเล้า');housingId=crypto.randomUUID();db.houses.push({id:housingId,name:payload.name.trim()});db.bindings[batch]=housingId;}
 else if(action==='bind_housing'){if(!db.houses.some(h=>h.id===payload.housing_id))throw Error('ไม่พบเล้า');housingId=payload.housing_id;db.bindings[batch]=housingId;}
 else if(['save','delete'].includes(action)){if(!housingId)throw Error('เลือกเล้าก่อน');const row=db.items.find(x=>x.id===payload.id&&x.housing_id===housingId);if(payload.id&&(!row||row.version!==payload.version))throw Error('ข้อมูลถูกแก้ไขแล้ว กรุณาโหลดใหม่');if(action==='delete')db.items=db.items.filter(x=>x!==row);else{if(!payload.name?.trim())throw Error('ระบุชื่ออุปกรณ์');const next={...payload,name:payload.name.trim(),id:row?.id||crypto.randomUUID(),housing_id:housingId,version:(row?.version||0)+1};if(row)Object.assign(row,next);else db.items.push(next);}}
 else if(action!=='list')throw Error('คำสั่งไม่ถูกต้อง');
 localStorage.setItem(key,JSON.stringify(db));return{housingId,housingName:db.houses.find(h=>h.id===housingId)?.name||'เล้าที่ผูกกับล็อต',canWrite,items:db.items.filter(x=>x.housing_id===housingId),housingOptions:db.houses,demo:true};
}
