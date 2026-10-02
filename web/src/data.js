import {createClient} from '@supabase/supabase-js';
import {demo} from './demo.js';
import {prepareDemo,totals,detail,previewPayment,demoWrite} from './feed-model.js';
export const config=window.DUCKY_CONFIG||{};
export const live=!!(config.supabaseUrl&&config.publishableKey);
if(config.publishableKey?.startsWith('sb_secret_'))throw Error('ห้ามใส่ secret key ใน frontend');
if(config.publishableKey?.split('.').length===3){try{const role=JSON.parse(atob(config.publishableKey.split('.')[1].replace(/-/g,'+').replace(/_/g,'/'))).role;if(role==='service_role')throw Error('PRIVATE_KEY');}catch(e){if(e.message==='PRIVATE_KEY')throw Error('ห้ามใส่ service_role key ใน frontend');}}
export const client=live?createClient(config.supabaseUrl,config.publishableKey,{auth:{flowType:'pkce',persistSession:true,autoRefreshToken:true,detectSessionInUrl:true}}):null;
const key='ducky-v2-demo-01';
let local;try{local=JSON.parse(localStorage.getItem(key))}catch{}local ||= structuredClone(demo);
export let session=null,profile=null;
export async function initialize(){if(!window.DUCKY_CONFIG)throw Error("โหลด config.js ไม่สำเร็จ กรุณาเชื่อมต่ออินเทอร์เน็ตแล้วลองใหม่");if(!live)return;const {data,error}=await client.auth.getSession();if(error)throw error;session=data.session;if(session){const r=await client.from('profiles').select('*').eq('id',session.user.id).single();if(r.error)throw r.error;profile=r.data;}}
export async function login(){const {error}=await client.auth.signInWithOAuth({provider:'google',options:{redirectTo:location.origin+location.pathname}});if(error)throw error;}
export async function logout(){if(client){const {error}=await client.auth.signOut();if(error)throw error;}session=null;profile=null;location.reload()}
export async function load(){if(!live){prepareDemo(local);const result=structuredClone(local);result.orders=local.orders.map(o=>({...o,...totals(local,o)}));result.context={is_admin:true,feed_write:true,farm_write_ids:local.batches.map(b=>b.id),funds:local.batches.map(b=>({id:b.id,name:b.name,can_write:true,balance:local.cash.filter(c=>c.batch_id===b.id).reduce((n,c)=>n+c.amount,0)}))};return result;}if(!session||!profile?.approved)return {batches:[],eggs:[],orders:[],events:[],prices:[],plans:[]};const names={batches:'batches',eggs:'egg_daily',orders:'feed_orders',events:'batch_events',prices:'price_items',plans:'batch_plans',cash:'batch_cash',allocations:'feed_allocations'};const out={};await Promise.all(Object.entries(names).map(async([k,t])=>{const rows=[];for(let start=0;;start+=500){const r=k==='orders'?await client.rpc('get_feed_calendar',{p_offset:start,p_limit:500}):await client.from(t).select('*').order('id').range(start,start+499);if(r.error)throw r.error;rows.push(...r.data);if(r.data.length<500)break;if(start>=9500)throw Error('ข้อมูลเกินขอบเขตรุ่นทดสอบ ต้องเพิ่มตัวกรองฝั่ง server');}out[k]=rows;}));out.context=await rpc('operating_context',{});return out}
function persist(){localStorage.setItem(key,JSON.stringify(local))}
export async function saveEgg(row){if(live){const {error}=await client.rpc('save_egg',{p_batch:row.batch_id,p_date:row.log_date,p_total:row.total,p_broken:row.broken,p_live:row.live_count,p_expected:row.version||0});if(error)throw error;}else{const old=local.eggs.find(x=>x.batch_id===row.batch_id&&x.log_date===row.log_date);if(old&&old.version!==row.version)throw Error('VERSION_CONFLICT');if(old)Object.assign(old,row,{version:old.version+1});else local.eggs.push({...row,id:crypto.randomUUID(),version:1});persist();}}
export async function saveOrder(row){const keys=['id','version','feed_name','supplier_name','order_date','credit_days','quantity','unit','unit_price','kg_per_unit','total','manufacturer_lot','formula','note'];return write('feed_save_order',{p_data:Object.fromEntries(keys.filter(k=>row[k]!==undefined).map(k=>[k,row[k]]))})}
export async function saveEvent(row){if(live){const {error}=await client.from('batch_events').insert(row);if(error)throw error;}else{local.events.push({...row,id:crypto.randomUUID()});persist();}}
export async function savePlan(row){if(live){const {error}=await client.from('batch_plans').insert(row);if(error)throw error;}else{local.plans.push({...row,id:crypto.randomUUID()});persist();}}
export function resetDemo(){if(live)return;local=structuredClone(demo);persist();location.reload()}

export async function rpc(name,args){const r=await client.rpc(name,args);if(r.error)throw r.error;return r.data}
const pendingPrefix=()=>`ducky-pending-${session?.user.id||'demo'}-`;
export function pendingWrites(){const prefix=pendingPrefix();return Object.keys(localStorage).filter(k=>k.startsWith(prefix)).map(k=>({key:k,...JSON.parse(localStorage.getItem(k))}))}
export async function write(name,args){
 if(!live){const copy=structuredClone(local),result=demoWrite(copy,name,args);local=copy;persist();return result}
 if(!navigator.onLine)throw Error('OFFLINE');
 // Persist one immutable request across network failure/reload until acknowledged.
 const identity=JSON.stringify({name,data:args.p_data}),key=pendingPrefix()+identity;
 if(!localStorage.getItem(key)&&pendingWrites().length)throw Error('UNCERTAIN_PENDING');
 const saved=localStorage.getItem(key),request=saved?JSON.parse(saved):{name,args:{...args,p_request:crypto.randomUUID()}};
 localStorage.setItem(key,JSON.stringify(request));
 try{const result=await rpc(request.name,request.args);localStorage.removeItem(key);return result}
 catch(e){if(e.code&&e.code!=='')localStorage.removeItem(key);throw e}
}
export async function retryPending(){for(const p of pendingWrites()){try{await rpc(p.name,p.args);localStorage.removeItem(p.key)}catch(e){if(e.code)localStorage.removeItem(p.key);throw e}}}
export async function feedDetail(id){return live?rpc('feed_detail',{p_order:id}):detail(prepareDemo(local),id)}
export async function paymentPreview(p){return live?rpc('feed_payment_preview',{p_data:p}):previewPayment(prepareDemo(local),p)}
export async function visibility(o,visible){if(live)return rpc('feed_set_visibility',{p_order:o.id,p_visible:visible,p_version:o.version});const row=local.orders.find(x=>x.id===o.id);if(row.version!==o.version)throw Error('VERSION_CONFLICT');row.is_visible=visible;row.version++;persist()}
