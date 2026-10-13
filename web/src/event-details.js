import {thaiDate,dateUTC} from './domain.js';
import {eventTypes} from './farm-model.js';
const esc=v=>String(v??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
const fmt=n=>Number(n).toLocaleString('th-TH',{maximumFractionDigits:2});
const present=v=>v!==null&&v!==undefined&&v!=='';
function range(e){const f=e.factors||{},valid=v=>{try{dateUTC(v);return v}catch{return null}};return {start:valid(f.series_start)||valid(f.range_start)||valid(f.start_date)||valid(e.start_date),end:valid(f.series_end)||valid(f.range_end)||valid(f.end_date)||valid(e.end_date)||valid(e.start_date)}};
export function eventReadableDetails(e,movements=[],expenses=[]){
 const f=e.factors||{},rows=[],period=range(e),multi=period.start!==period.end;
 const medical=['injection','medicine','vitamin','premix'].includes(e.event_type);
 const put=(label,v)=>{if(present(v))rows.push([label,String(v)])};
 if(medical){
  put({injection:'ยา / วัคซีน',medicine:'ยา',vitamin:'วิตามิน',premix:'พรีมิกส์'}[e.event_type],f.medicine_name||f.item_name);
  if(present(f.method))put('วิธีให้',({water:'ผสมน้ำ',feed:'ผสมอาหาร',oral:'ป้อนกิน',spray:'พ่น',injection:'ฉีด',topical:'ทาภายนอก',other:'อื่น ๆ'})[f.method]||f.method);
  if(Number(f.bird_count)>0)put('จำนวนสัตว์ที่ได้รับ',fmt(f.bird_count)+' ตัว');
  const q=f.entered_quantity??f.quantity,u=f.entered_unit||f.unit;
  if(present(q))put('ปริมาณที่ใช้',fmt(q)+(u?' '+u:''));
  if(present(f.purchase_quantity)&&f.purchase_unit&&f.purchase_unit!==u)put('เทียบหน่วยซื้อ',fmt(f.purchase_quantity)+' '+f.purchase_unit);
 }
 if(e.event_type==='rain'&&f.rain_level&&f.rain_level!=='none')put('ระดับฝน',({light:'ฝนเบา',moderate:'ฝนปานกลาง',heavy:'ฝนหนัก'})[f.rain_level]||f.rain_level);
 if(['rain','heat'].includes(e.event_type)&&present(f.temperature))put('อุณหภูมิ',fmt(f.temperature)+' °C');
 if(e.event_type==='feed_swap'){
  put('อาหารก่อนเปลี่ยน',f.old_feed_name);put('อาหารหลังเปลี่ยน',f.new_feed_name);put('รายละเอียดการเปลี่ยนอาหาร',f.feed_change);
 }
 const costs=new Map();
 const names={medicine:'ค่ายา',vitamin:'ค่าวิตามิน',vaccine:'ค่าวัคซีน',labor:'ค่าแรง',other:'ค่าใช้จ่ายอื่น',legacy_event:'ค่าใช้จ่ายเหตุการณ์',supply:'ค่าปัจจัยจากคลัง',inventory:'ค่าปัจจัยจากคลัง'};
 for(const c of expenses){if(Number(c.amount)>0){const label=names[c.category]||'ค่าใช้จ่ายอื่น';costs.set(label,(costs.get(label)||0)+Number(c.amount));}}
 const total=[...costs.values()].reduce((a,b)=>a+b,0);
 if(multi&&total>0){const mode=f.cost_mode||(present(f.distribute_cost)?([true,1,'1'].includes(f.distribute_cost)?'total':'daily'):null);if(mode)put('วิธีคิดต้นทุน',mode==='daily'?'คิดค่าใช้จ่ายแยกแต่ละวัน':'แบ่งค่าใช้จ่ายรวมตลอดช่วง');}
 const linked=movements.filter(m=>m.event_id===e.id||(e.sale_id&&m.sale_id===e.sale_id));
 const kinds={death:['death'],add:['add'],duck_cull:['sale'],close_sale:['sale']};
 let count=null;
 if(kinds[e.event_type]){const relevant=linked.filter(m=>kinds[e.event_type].includes(m.kind));if(relevant.length)count=relevant.reduce((n,m)=>n+Number(m.qty),0);else{const fallback=f.qty??f.death_qty??f.dead_qty??f.animal_count;if(present(fallback)&&Number.isFinite(Number(fallback)))count=Number(fallback);}}
 const countLabel={death:'จำนวนสัตว์ตาย',add:'จำนวนสัตว์ที่เพิ่ม',duck_cull:'จำนวนสัตว์ที่คัดขาย',close_sale:'จำนวนสัตว์ที่ขาย'}[e.event_type];
 return {period,multi,rows,costs:[...costs].map(([k,v])=>[k,fmt(v)+' บาท']),total,count,countLabel,showDetails:e.event_type!=='death'&&(rows.length>0||total>0)};
}
export function renderEventCard(e,movements=[],expenses=[]){const v=eventReadableDetails(e,movements,expenses);const grid=rows=>`<div class="event-detail-grid">${rows.map(([k,x])=>`<div><strong>${esc(k)}</strong><span>${esc(x)}</span></div>`).join('')}</div>`;const severity=({normal:'ปกติ',light:'เล็กน้อย',mild:'เล็กน้อย',moderate:'ปานกลาง',high:'รุนแรง',severe:'รุนแรง'})[e.severity]||(typeof e.severity==='string'&&/[ก-๙]/.test(e.severity)?e.severity:null);
 return `<article class="event-card"><header class="event-card-heading"><h3>${esc(e.title)}</h3><small>${esc(eventTypes[e.event_type]||'เหตุการณ์อื่น')}${severity?' • '+esc(severity):''}</small></header><p class="event-card-date">${v.multi?'ช่วงวันที่':'วันที่'} ${thaiDate(v.period.start)}${v.multi?' – '+thaiDate(v.period.end):''}</p>${v.countLabel?`<p class="event-animal-count"><span>${esc(v.countLabel)}</span><strong>${v.count===null?'ยังไม่มีข้อมูลจำนวน':fmt(v.count)+' ตัว'}</strong></p>`:''}${e.details?`<p class="event-card-note">${esc(e.details)}</p>`:''}${v.showDetails?`<details class="event-readable-details"><summary>ปัจจัยและค่าใช้จ่าย</summary>${v.rows.length?grid(v.rows):''}${v.total>0?`<h4>ค่าใช้จ่ายของวันนี้</h4>${grid([...v.costs,['รวมค่าใช้จ่าย',fmt(v.total)+' บาท']])}`:''}</details>`:''}${e.sale_id?`<button data-bill="${esc(e.sale_id)}">ดูบิลขายที่เชื่อมกัน</button>`:''}</article>`;
}
