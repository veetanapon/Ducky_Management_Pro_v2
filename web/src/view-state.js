// Keep in-progress filters, inline forms and expanded details across data refreshes.
export function captureView(root=document.querySelector('main')){if(!root)return()=>{};const fields=[...root.querySelectorAll('input[id],input[name],select[id],select[name],textarea[id],textarea[name]')].filter(e=>!e.readOnly&&e.type!=='file').map(e=>({id:e.id,name:e.name,value:e.value,checked:e.checked,focus:e===document.activeElement,start:e.selectionStart,end:e.selectionEnd}));const details=[...root.querySelectorAll('details')].map(e=>({id:e.id,title:e.querySelector('summary')?.textContent,open:e.open}));return()=>{const current=document.querySelector('main');if(!current)return;for(const f of fields){const el=f.id?document.getElementById(f.id):[...current.querySelectorAll('[name]')].find(e=>e.name===f.name);if(!el)continue;if(el.tagName!=='SELECT'||[...el.options].some(o=>o.value===f.value))el.value=f.value;if(['checkbox','radio'].includes(el.type))el.checked=f.checked;if(f.focus){el.focus({preventScroll:true});if(f.start!=null&&el.setSelectionRange)try{el.setSelectionRange(f.start,f.end)}catch{}}}for(const d of details){const el=d.id?document.getElementById(d.id):[...current.querySelectorAll('details')].find(e=>e.querySelector('summary')?.textContent===d.title);if(el)el.open=d.open}}}

// Restore nested scrollers after an in-place redraw without restoring stale form values.
export function captureScroll(root){const page={x:window.scrollX,y:window.scrollY},selectors=['.zone','.central-lot-scroll','.table-scroll','.cf-board','.cf-inspector'],positions=selectors.map(selector=>({selector,values:[...root.querySelectorAll(selector)].map(el=>[el.scrollLeft,el.scrollTop])}));return()=>requestAnimationFrame(()=>{if(!root.isConnected)return;for(const {selector,values}of positions)root.querySelectorAll(selector).forEach((el,i)=>{if(values[i]){el.scrollLeft=values[i][0];el.scrollTop=values[i][1]}});window.scrollTo(page.x,page.y)})}

// Restore synchronously, before paint, so explicit navigation (Today) still wins.
// Do not restore field values: the redraw may contain newly saved settings.
export function capturePlannerView(root){
 const page=[window.scrollX,window.scrollY];
 const scrollers=['.cf-board','.cf-inspector','.cf-wallet-grid'].map(selector=>({selector,x:root.querySelector(selector)?.scrollLeft||0,y:root.querySelector(selector)?.scrollTop||0}));
 const details=[...root.querySelectorAll('details')].map(el=>({title:el.dataset.viewKey||el.querySelector('summary')?.textContent,open:el.open}));
 const active=document.activeElement;
 const attributes=['id','data-wallet-toggle','data-income-date','data-event','data-date','data-cf-edit','data-cf-round','data-add','name'];
 const key=root.contains(active)?attributes.find(attr=>active.hasAttribute(attr)):null;
 const value=key?active.getAttribute(key):null;
 return()=>{
  if(!root.isConnected)return;
  for(const saved of details){const el=[...root.querySelectorAll('details')].find(el=>(el.dataset.viewKey||el.querySelector('summary')?.textContent)===saved.title);if(el)el.open=saved.open;}
  if(key&&!document.querySelector('dialog[open]')){
   const target=[...root.querySelectorAll('['+key+']')].find(el=>el.getAttribute(key)===value);
   target?.focus({preventScroll:true});
  }
  for(const saved of scrollers){const el=root.querySelector(saved.selector);if(el){el.scrollLeft=saved.x;el.scrollTop=saved.y;}}
  window.scrollTo(page[0],page[1]);
 };
}
