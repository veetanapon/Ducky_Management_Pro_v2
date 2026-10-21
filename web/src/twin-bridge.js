/** Same-origin integration only. Production permissions remain in Ducky v2. */
export function connectDuckyTwin(frame, {getSnapshot, canOpen, canViewBatch, navigate, selectBatch, onDenied=()=>{}}) {
  if (![getSnapshot,canOpen,canViewBatch,navigate].every(x=>typeof x==='function')) throw new TypeError('Snapshot, permission, batch permission and navigation callbacks are required');
  const routes = new Map([['eggs','#farm/eggs'],['sales','#farm/sales'],['inventory','#farm/feed'],['events','#farm/events'],['analytics','#analytics'],['finance','#finance'],['central','#feed'],['settings','#settings'],['prices','#prices']]);
  let child=null,disposed=false;
  function safeSnapshot(){const input=getSnapshot();if(!input||!Array.isArray(input.batches))throw new TypeError('Invalid snapshot');return {...input,batches:input.batches.filter(b=>canViewBatch(b.id))};}
  function sync(){if(!disposed&&child?.DuckyTwin)child.DuckyTwin.updateSnapshot(safeSnapshot());}
  function action(event){const d=event.detail;if(!d||routes.get(d.action)!==d.route)return;const s=safeSnapshot();const batch=d.batchId?s.batches.find(b=>b.id===d.batchId):null;if(d.batchId&&!batch){onDenied('ไม่มีสิทธิ์เข้าถึงล็อต');return;}const farm=d.route.startsWith('#farm/');if((farm&&!batch)||!canOpen(d.action,batch?.id||null)){onDenied('ไม่มีสิทธิ์ หรือยังไม่ได้เลือกล็อตที่เข้าถึงได้');return;}navigate({route:d.route,batchId:batch?.id||null});}
  function batch(event){const id=event.detail?.batchId;if(id&&safeSnapshot().batches.some(b=>b.id===id)){selectBatch?.(id);sync();}}
  function detach(){if(!child)return;child.removeEventListener('ducky:twin-action',action);child.removeEventListener('ducky:twin-batch-change',batch);child.DuckyTwin?.setBridgeAttached(false);child=null;}
  function attach(){detach();if(disposed)return;try{const candidate=frame.contentWindow;if(candidate.location.href==='about:blank')return;if(candidate.location.origin!==window.location.origin)throw new Error('Twin must be hosted on the same origin');child=candidate;if(!child.DuckyTwin){child=null;return;}child.addEventListener('ducky:twin-action',action);child.addEventListener('ducky:twin-batch-change',batch);child.DuckyTwin.setBridgeAttached(true);sync();}catch(e){detach();onDenied(e.message);}}
  frame.addEventListener('load',attach);attach();return {sync,dispose(){disposed=true;frame.removeEventListener('load',attach);detach();}};
}
