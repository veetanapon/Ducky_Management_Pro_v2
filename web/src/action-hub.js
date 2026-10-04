import {icon} from './ui.js';
const esc=s=>String(s??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
export function clearActionHub(){document.querySelector('#moduleActionDock')?.remove();document.querySelector('#actionHubSheet')?.remove()}
// Shared two-level action menu. Pages provide only groups and callbacks.
export function mountActionHub(groups,label='คำสั่งหน้านี้'){
 clearActionHub();groups=groups.filter(g=>g.actions?.length);if(!groups.length)return;
 const dock=document.createElement('div');dock.id='moduleActionDock';dock.innerHTML=`<button class="module-fab glass-surface" aria-label="${esc(label)}" aria-haspopup="dialog">${icon('add')}<span>${esc(label)}</span></button>`;document.body.append(dock);
 const sheet=document.createElement('dialog');sheet.id='actionHubSheet';sheet.className='action-hub-sheet';document.body.append(sheet);
 function draw(group){sheet.innerHTML=`<header>${group?'<button type="button" class="icon-button" aria-label="กลับกลุ่มคำสั่ง">'+icon('left')+'</button>':''}<h2>${esc(group?.title||label)}</h2><button type="button" class="icon-button" aria-label="ปิดคำสั่ง">${icon('close')}</button></header><div class="hub-actions">${(group?group.actions:groups).map((x,i)=>`<button type="button" data-hub="${i}" ${x.disabled?'disabled':''}>${icon(x.icon||'more')}<span>${esc(x.label||x.title)}${x.description?'<small>'+esc(x.description)+'</small>':''}</span>${!group?icon('right'):''}</button>`).join('')}</div>`;sheet.querySelector('[aria-label="ปิดคำสั่ง"]').onclick=()=>sheet.close();sheet.querySelector('[aria-label="กลับกลุ่มคำสั่ง"]')?.addEventListener('click',()=>draw());sheet.querySelectorAll('[data-hub]').forEach(b=>b.onclick=()=>{const i=+b.dataset.hub;if(!group)return draw(groups[i]);sheet.close();group.actions[i].run()})}
 dock.querySelector('button').onclick=()=>{draw(groups.length===1?groups[0]:null);sheet.showModal()};
 sheet.addEventListener('click',e=>{if(e.target===sheet){const r=sheet.getBoundingClientRect();if(e.clientX<r.left||e.clientX>r.right||e.clientY<r.top||e.clientY>r.bottom)sheet.close()}});
}
