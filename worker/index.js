import {pushRequest} from './web-push.js';
async function rpc(env,name,args){const r=await fetch(env.SUPABASE_URL+'/rest/v1/rpc/'+name,{method:'POST',headers:{apikey:env.SUPABASE_SERVICE_ROLE_KEY,Authorization:'Bearer '+env.SUPABASE_SERVICE_ROLE_KEY,'Content-Type':'application/json'},body:JSON.stringify(args),signal:AbortSignal.timeout(20000)});if(!r.ok)throw Error(name+': HTTP '+r.status);const text=await r.text();return text?JSON.parse(text):null}
export default{
 fetch(request,env){return env.ASSETS.fetch(request)},
 async scheduled(event,env,ctx){if(!env.SUPABASE_URL||!env.SUPABASE_SERVICE_ROLE_KEY||!env.VAPID_PRIVATE_KEY||!env.VAPID_PUBLIC_KEY||!env.VAPID_SUBJECT){console.warn('Push is not configured; set Worker secrets listed in UPDATE_0150_TH.md');return}
 const rows=await rpc(env,'notification_push_claim',{});for(const row of rows){let status=0;try{const request=await pushRequest(row.subscription,row.payload,env);const response=await fetch(row.subscription.endpoint,{...request,signal:AbortSignal.timeout(10000)});status=response.status;await response.body?.cancel()}catch{status=0}await rpc(env,'notification_push_ack',{p_id:row.id,p_lease:row.lease,p_status:status})}
 }
};
