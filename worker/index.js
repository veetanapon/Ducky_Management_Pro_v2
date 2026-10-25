import {pushRequest} from './web-push.js';
async function rpc(env,name,args){const r=await fetch(env.SUPABASE_URL+'/rest/v1/rpc/'+name,{method:'POST',headers:{apikey:env.SUPABASE_SERVICE_ROLE_KEY,Authorization:'Bearer '+env.SUPABASE_SERVICE_ROLE_KEY,'Content-Type':'application/json'},body:JSON.stringify(args),signal:AbortSignal.timeout(20000)});if(!r.ok)throw Error(name+': HTTP '+r.status);const text=await r.text();return text?JSON.parse(text):null}
export default{
 fetch(request,env){return env.ASSETS.fetch(request)},
 async scheduled(event,env,ctx){
  const missing=['SUPABASE_URL','SUPABASE_SERVICE_ROLE_KEY','VAPID_PRIVATE_KEY','VAPID_PUBLIC_KEY','VAPID_SUBJECT'].filter(k=>!env[k]);
  if(missing.length){console.error('Push configuration missing: '+missing.join(', '));return}
  let rows;
  try{rows=await rpc(env,'notification_push_claim',{})}catch(err){console.error('Push claim failed: '+err.message);throw err}
  const summary={claimed:rows.length,accepted:0,failed:0};
  for(const row of rows){let status=0;try{const request=await pushRequest(row.subscription,row.payload,env);const response=await fetch(row.subscription.endpoint,{...request,signal:AbortSignal.timeout(10000)});status=response.status;await response.body?.cancel()}catch(err){console.error('Push request failed',{delivery_id:row.id,error:err.name})}
   if(status>=200&&status<300)summary.accepted++;else{summary.failed++;console.warn('Push rejected',{delivery_id:row.id,status})}
   await rpc(env,'notification_push_ack',{p_id:row.id,p_lease:row.lease,p_status:status});
  }
  // Accepted means the push provider accepted it, not that a banner was displayed.
  console.log('Push delivery summary',summary);
 }
};
