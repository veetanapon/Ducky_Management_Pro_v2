import {addDays,daysBetween,dateUTC,thaiDate,money} from './domain.js';
const esc=x=>String(x??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
export const calendarSettings={warningDays:7,criticalDays:3};
export function paymentState(order,today,settings=calendarSettings){
 const due=addDays(order.order_date,order.credit_days),days=daysBetween(today,due);
 const known=order.outstanding!=null||order.paid_total!=null;
 const outstanding=known?Math.max(0,Number(order.outstanding??(order.total-Number(order.paid_total)))):null;
 if(known&&outstanding<=0)return{tone:'paid',label:'ปิดแล้ว',due,days,outstanding};
 if(!known)return{tone:'unknown',label:'ยังไม่ทราบยอดชำระ',due,days,outstanding};
 if(days<0)return{tone:'red',label:`เลยดีล ${-days} วัน`,due,days,outstanding};
 if(days===0)return{tone:'red',label:'ครบดีลวันนี้',due,days,outstanding};
 return{tone:days<=settings.criticalDays?'red':days<=settings.warningDays?'yellow':'green',label:`อีก ${days} วัน`,due,days,outstanding};
}
// Inclusive intervals. A stable lane per lot prevents crossings when a bar wraps weeks.
export function calendarModel(month,orders){
 const first=month+'-01';dateUTC(first);const start=new Date(dateUTC(first));start.setUTCDate(start.getUTCDate()-start.getUTCDay());
 const gridStart=start.toISOString().slice(0,10),gridEnd=addDays(gridStart,41);
 const visible=orders.map(o=>({...o,due:addDays(o.order_date,o.credit_days)})).filter(o=>o.order_date<=gridEnd&&o.due>=gridStart).sort((a,b)=>a.order_date.localeCompare(b.order_date)||String(a.id).localeCompare(String(b.id)));
 const ends=[];for(const o of visible){let lane=ends.findIndex(e=>e<o.order_date);if(lane<0)lane=ends.length;o.lane=lane;ends[lane]=o.due;}
 const weeks=Array.from({length:6},(_,i)=>{const from=addDays(gridStart,i*7),to=addDays(from,6);const bars=visible.filter(o=>o.order_date<=to&&o.due>=from).map(o=>{const a=o.order_date<from?from:o.order_date,b=o.due>to?to:o.due;return{...o,column:daysBetween(from,a)+1,span:daysBetween(a,b)+1,continuesBefore:o.order_date<from,continuesAfter:o.due>to}});return{from,to,days:Array.from({length:7},(_,j)=>addDays(from,j)),bars,lanes:Math.max(0,...bars.map(b=>b.lane+1))}});
 return{gridStart,gridEnd,weeks};
}
export function renderFeedCalendar({month,orders,today,selected,settings=calendarSettings}){
 const model=calendarModel(month,orders);
 const weekHtml=model.weeks.map(w=>`<div class="range-week"><div class="range-days">${w.days.map(d=>`<div class="range-day ${d.slice(0,7)!==month?'adjacent':''} ${d===today?'today':''}" data-date="${d}" aria-label="${thaiDate(d)}"><span>${Number(d.slice(-2))}${d.slice(-2)==='01'?` <small>${dateUTC(d).toLocaleDateString('th-TH',{month:'short',timeZone:'UTC'})}</small>`:''}</span></div>`).join('')}</div><div class="range-bars">${w.bars.map(o=>{const s=paymentState(o,today,settings),text=`ล็อต ${thaiDate(o.order_date)} → ${thaiDate(o.due)} · ${o.feed_name} · ${s.label}${s.outstanding==null?'':` · ค้าง ${money(s.outstanding)} บาท`}`;return `<button class="range-bar ${s.tone} ${o.continuesBefore?'continues-before':''} ${o.continuesAfter?'continues-after':''} ${o.id===selected?'chosen':''}" data-order="${esc(o.id)}" style="--start:${o.column};--span:${o.span};--lane:${o.lane+1}" title="${esc(text)}" aria-label="${esc(text)}"><span class="range-bar-label">${o.continuesBefore?'‹ ':''}ล็อต ${thaiDate(o.order_date)} <span class="bar-due">→ ${thaiDate(o.due)} · ${s.label}</span>${o.continuesAfter?' ›':''}</span></button>`}).join('')}</div></div>`).join('');
 return `<div class="calendar-tools"><button id="prevMonth" aria-label="เดือนก่อน">←</button><b>${dateUTC(month+'-01').toLocaleDateString('th-TH',{month:'long',year:'numeric',timeZone:'UTC'})}</b><button id="nextMonth" aria-label="เดือนถัดไป">→</button></div><div class="calendar-actions"><button id="lotMonth">ไปเดือนที่สั่งล็อตนี้</button><button id="currentMonth">เดือนปัจจุบัน</button></div><div class="calendar-legend"><span class="green">ห่างดีล &gt; ${settings.warningDays} วัน</span><span class="yellow">ใกล้ดีล ${settings.criticalDays+1}–${settings.warningDays} วัน</span><span class="red">≤ ${settings.criticalDays} วัน / เกินดีล</span><span class="paid">ปิดแล้ว</span></div><div class="range-calendar-scroll"><div class="range-calendar"><div class="range-weekdays">${['อา','จ','อ','พ','พฤ','ศ','ส'].map(d=>`<span>${d}</span>`).join('')}</div>${weekHtml}</div></div><p class="muted calendar-footnote">แถบ = วันสั่งถึงวันครบดีล (รวมวันต้น–ปลาย) · ลูกศร = ต่อจาก/ไปสัปดาห์อื่น · แตะแถบเพื่อดูรายละเอียด<br>สีอิงวันที่ ${thaiDate(today)} และยอดค้าง ไม่ได้แปลว่าจ่ายแล้วเพียงเพราะเลยวันสั่ง</p>`;
}
