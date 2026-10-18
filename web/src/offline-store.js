// User/project-scoped snapshots. No tokens or service credentials are stored here.
let opening;
function db(){return opening||=new Promise((resolve,reject)=>{const r=indexedDB.open('ducky-local-v1',1);r.onupgradeneeded=()=>r.result.createObjectStore('snapshots');r.onsuccess=()=>resolve(r.result);r.onerror=()=>reject(r.error)})}
export async function cacheGet(key){try{const d=await db();return await new Promise((resolve,reject)=>{const r=d.transaction('snapshots').objectStore('snapshots').get(key);r.onsuccess=()=>resolve(r.result);r.onerror=()=>reject(r.error)})}catch{return null}}
export async function cachePut(key,value){try{const d=await db();await new Promise((resolve,reject)=>{const t=d.transaction('snapshots','readwrite');t.objectStore('snapshots').put({at:Date.now(),value},key);t.oncomplete=resolve;t.onerror=()=>reject(t.error)});return true}catch{return false}}
export async function cacheClear(prefix){try{const d=await db();await new Promise((resolve,reject)=>{const t=d.transaction('snapshots','readwrite'),r=t.objectStore('snapshots').openCursor();r.onsuccess=()=>{const c=r.result;if(c){if(String(c.key).startsWith(prefix))c.delete();c.continue()}};t.oncomplete=resolve;t.onerror=()=>reject(t.error)})}catch{}}
export function networkFailure(e){return !e?.code&&(/fetch|network|offline|load failed|timeout/i.test(e?.message||'')||e instanceof TypeError)}
export function queueAllowed(name,args){return name==='farm_manage'&&['egg','feed','feed_multi','event','pending_save'].includes(args.p_data?.action)||name==='supply_manage'&&args.p_data?.action==='use_event'}
export function queueIdentity(name,args){const {p_request,...payload}=args;return JSON.stringify({name,...payload})}
