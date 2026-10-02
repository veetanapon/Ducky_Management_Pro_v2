const CACHE='ducky-v2-shell-04';
self.addEventListener('install',e=>e.waitUntil(caches.open(CACHE).then(c=>c.addAll(['./','./index.html','./manifest.webmanifest','./icon-192.png','./icon-512.png']))));
self.addEventListener('activate',e=>e.waitUntil(caches.keys().then(keys=>Promise.all(keys.filter(k=>k.startsWith('ducky-v2-')&&k!==CACHE).map(k=>caches.delete(k)))).then(()=>self.clients.claim())));
self.addEventListener('message',e=>{if(e.data==='SKIP_WAITING')self.skipWaiting()});
self.addEventListener('fetch',e=>{const u=new URL(e.request.url);if(e.request.method!=='GET'||u.origin!==self.location.origin||u.pathname.endsWith('/config.js'))return;
// Only app shell resources. Auth/API/database data must never enter this cache.
if(e.request.mode==='navigate')e.respondWith(fetch(e.request).catch(()=>caches.match('./index.html')));
else if(/\/(assets\/|icon-)|manifest\.webmanifest$/.test(u.pathname))e.respondWith(caches.match(e.request).then(r=>r||fetch(e.request).then(r=>{if(r.ok){const copy=r.clone();caches.open(CACHE).then(c=>c.put(e.request,copy))}return r})))});
self.addEventListener('push',e=>{let d={};try{d=e.data.json()}catch{}e.waitUntil(self.registration.showNotification(d.title||'Ducky',{body:d.body||'มีรายการใหม่ กรุณาเปิดแอป',icon:'./icon-192.png',data:{route:d.route||'#home'}}))});
self.addEventListener('notificationclick',e=>{e.notification.close();const u=new URL('./',self.registration.scope);u.hash=String(e.notification.data?.route||'#home').replace(/^#/,'');e.waitUntil(clients.openWindow(u.href))});
