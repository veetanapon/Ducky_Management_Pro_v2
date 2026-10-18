const CACHE='ducky-v2-shell-29';
// The build step replaces this list with all hashed JS, CSS and font assets.
const PRECACHE=/*__PRECACHE__*/['./','./index.html','./config.js','./manifest.webmanifest','./icon-192.png','./icon-512.png'];
self.addEventListener('install',e=>e.waitUntil(caches.open(CACHE).then(c=>c.addAll(PRECACHE))));
self.addEventListener('activate',e=>e.waitUntil(caches.keys().then(keys=>Promise.all(keys.filter(k=>k.startsWith('ducky-v2-shell-')&&k!==CACHE).map(k=>caches.delete(k)))).then(()=>self.clients.claim())));
self.addEventListener('message',e=>{if(e.data==='SKIP_WAITING')self.skipWaiting()});
self.addEventListener('fetch',e=>{const u=new URL(e.request.url);if(e.request.method!=='GET'||u.origin!==self.location.origin)return;
 if(e.request.mode==='navigate'){e.respondWith(fetch(e.request).catch(()=>caches.match('./index.html')));return}
 if(u.pathname.endsWith('/config.js')){e.respondWith(fetch(e.request).then(async r=>{if(r.ok){const c=await caches.open(CACHE);await c.put(e.request,r.clone())}return r}).catch(()=>caches.match(e.request)));return}
 if(/\/(assets\/|icon-)|manifest\.webmanifest$|farm-logo\.png$/.test(u.pathname))e.respondWith(caches.match(e.request).then(r=>r||fetch(e.request).then(r=>{if(r.ok){const copy=r.clone();caches.open(CACHE).then(c=>c.put(e.request,copy))}return r})));
});
self.addEventListener('push',e=>{let d={};try{d=e.data.json()}catch{}e.waitUntil(self.registration.showNotification(d.title||'Ducky',{body:d.body||'มีรายการใหม่ กรุณาเปิดแอป',icon:'./icon-192.png',badge:'./icon-192.png',tag:d.id||'ducky',data:{route:d.route||'#farm',batch_id:d.batch_id}}))});
self.addEventListener('notificationclick',e=>{e.notification.close();const u=new URL('./',self.registration.scope);u.hash=String(e.notification.data?.route||'#farm').replace(/^#/,'');e.waitUntil(clients.matchAll({type:'window',includeUncontrolled:true}).then(async list=>{const client=list.find(c=>new URL(c.url).origin===u.origin);if(client){await client.focus();client.postMessage({type:'OPEN_NOTICE',route:u.hash,batch_id:e.notification.data?.batch_id})}else{if(e.notification.data?.batch_id)u.searchParams.set('notice_batch',e.notification.data.batch_id);await clients.openWindow(u.href)}}))});
