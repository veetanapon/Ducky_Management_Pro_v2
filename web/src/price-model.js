import {dateUTC} from './domain.js';
const dayBefore=d=>{const date=new Date(dateUTC(d));date.setUTCDate(date.getUTCDate()-1);return date.toISOString().slice(0,10)};
export function preparePrices(s){s.priceSets??=[{id:'demo-standard',name:'ราคาตัวอย่างกลาง',species_id:'duck',version:1,is_active:true,is_default:true,scope_type:'system',remark:''}];s.priceBindings??=[];s.prices??=[];for(const p of s.prices){p.price_set_id??='demo-standard';p.display_name??=p.grade;p.sort_order??=0}return s}
export function priceWorkspace(s){preparePrices(s);return structuredClone({can_read:true,can_write:true,sets:s.priceSets,items:s.prices,bindings:s.priceBindings,batches:s.batches.filter(b=>b.species_id==='duck'),housing:[],users:[{id:'demo-user',name:'ผู้ใช้ตัวอย่าง'}]})}
export function priceDemoWrite(s,p){preparePrices(s);let set=s.priceSets.find(x=>x.id===p.id);if(set&&set.version!==p.version)throw Error('VERSION_CONFLICT');if(!set&&(p.action!=='save'||p.version!==0))throw Error('PRICE_SET_NOT_FOUND');
 if(p.action==='save'){
  if(set&&!set.is_active)throw Error('PRICE_SET_ARCHIVED');if(!p.name.trim()||!p.items?.length)throw Error('PRICE_ITEMS_REQUIRED');
  if(s.prices.some(i=>i.price_set_id===p.id&&i.valid_from>p.valid_from))throw Error('PRICE_DATE_BEFORE_LATEST');
  const grades=p.items.map(i=>i.grade.trim().toLowerCase());if(new Set(grades).size!==grades.length)throw Error('DUPLICATE_PRICE_ITEM');if(p.items.some(i=>!i.grade.trim()||!Number.isFinite(i.price)||i.price<0))throw Error('INVALID_PRICE_ITEM');
  if(p.is_default&&p.scope_type!=='system')throw Error('DEFAULT_MUST_BE_SYSTEM');
  if(p.is_default)for(const x of s.priceSets)if(x.is_default&&x.id!==p.id){x.is_default=false;x.version++}
  const meta={name:p.name.trim(),scope_type:p.scope_type,remark:p.remark||'',is_default:p.is_default,is_active:true,species_id:'duck'};
  if(set)Object.assign(set,meta,{version:set.version+1});else{s.priceSets.push(set={id:p.id,...meta,version:1})}
  s.prices=s.prices.filter(i=>i.price_set_id!==p.id||i.valid_from!==p.valid_from);
  for(const i of s.prices)if(i.price_set_id===p.id&&i.valid_from<p.valid_from&&(!i.valid_to||i.valid_to>=p.valid_from))i.valid_to=dayBefore(p.valid_from);
  for(const [index,i]of p.items.entries())s.prices.push({...i,id:crypto.randomUUID(),price_set_id:p.id,grade:i.grade.trim(),display_name:i.display_name.trim()||i.grade.trim(),sort_order:index,valid_from:p.valid_from,valid_to:null});
 }else if(p.action==='archive'){set.is_active=false;set.is_default=false;set.version++;for(const b of s.priceBindings)if(b.price_set_id===p.id&&b.is_active){b.is_active=false;b.version++;b.ended_at=new Date().toISOString()}}
 else if(p.action==='restore'){set.is_active=true;set.version++}
 else if(p.action==='bind'){
  if(!set.is_active)throw Error('PRICE_SET_ARCHIVED');if(!p.targets?.length)throw Error('TARGET_REQUIRED');
  for(const t of p.targets){if(t.type==='batch'&&!s.batches.some(b=>b.id===t.id&&b.species_id==='duck'&&b.status==='active'))throw Error('INVALID_DUCK_BATCH');const old=s.priceBindings.find(b=>b.target_type===t.type&&b.target_id===t.id&&b.is_active);if((old?.id||null)!==t.expected_id||(old?.version||0)!==t.expected_version)throw Error('BINDING_CHANGED');if(old&&old.price_set_id!==p.id&&!p.replace_existing)throw Error('TARGET_ALREADY_BOUND');
   if(!old||old.price_set_id!==p.id){if(old){old.is_active=false;old.version++;old.ended_at=new Date().toISOString();s.priceSets.find(x=>x.id===old.price_set_id).version++}s.priceBindings.push({id:crypto.randomUUID(),price_set_id:p.id,target_type:t.type,target_id:t.id,is_active:true,version:1,created_at:new Date().toISOString()})}
  }set.version++;
 }else if(p.action==='unbind'){const b=s.priceBindings.find(b=>b.id===p.binding_id&&b.price_set_id===p.id&&b.is_active&&b.version===p.binding_version);if(!b)throw Error('BINDING_CHANGED');b.is_active=false;b.version++;b.ended_at=new Date().toISOString();set.version++}
 else throw Error('INVALID_PRICE_ACTION');return set;
}
export function priceDemoResolve(s,batchId,date){preparePrices(s);const batch=s.batches.find(b=>b.id===batchId);if(!batch||batch.species_id!=='duck')throw Error('INVALID_DUCK_BATCH');let set,source;for(const [type,id]of [['batch',batchId],['housing',batch.housing_id],['user',batch.owner_user_id],['user','demo-user']]){if(!id)continue;const bind=s.priceBindings.find(b=>b.is_active&&b.target_type===type&&b.target_id===id);if(bind){set=s.priceSets.find(x=>x.id===bind.price_set_id&&x.is_active);if(set){source=type;break}}}if(!set){set=s.priceSets.find(x=>x.is_active&&x.is_default);source='default'}return{price_set:set||null,source,items:s.prices.filter(i=>i.price_set_id===set?.id&&i.valid_from<=date&&(!i.valid_to||i.valid_to>=date)).sort((a,b)=>a.sort_order-b.sort_order)}}
