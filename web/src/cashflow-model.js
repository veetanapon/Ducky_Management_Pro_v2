import {dateUTC,daysBetween} from './domain.js';

export const shift=(d,n)=>{const x=dateUTC(d);x.setUTCDate(x.getUTCDate()+n);return x.toISOString().slice(0,10)};
export const weekStart=(d,day=0)=>shift(d,-((dateUTC(d).getUTCDay()-Number(day)+7)%7));
const n=v=>Number(v)||0,round=v=>Math.round((v+Number.EPSILON)*100)/100;
const median=arr=>{const a=[...arr].sort((a,b)=>a-b);return a.length?a.length%2?a[(a.length-1)/2]:(a[a.length/2-1]+a[a.length/2])/2:null};
export const productKey=o=>JSON.stringify([String(o.feed_name||'').trim(),o.unit||'หน่วย',n(o.kg_per_unit)||null]);
export function oldestUnpaid(data,today){return(data.orders||[]).filter(o=>o.is_visible!==false&&n(o.outstanding)>0&&o.order_date<=today).map(o=>o.order_date).sort()[0]||today}
export function defaultPlan(data,today){return{settings:{start:oldestUnpaid(data,today),end:shift(today,34),batchId:null,feedCycle:11,batchSettings:{},opening:null,incomeDay:4,weeklyIncome:null,weeklyExpense:0,expenseDay:4,autoIncome:true,autoFood:true},entries:[]}}
export function validatePlan(doc,today){const s=doc.settings;if(s.walletPlan){if(!Array.isArray(s.walletPlan)||s.walletPlan.length>1000)throw Error('รายการกระเป๋าจำลองเกิน 1000');for(const e of s.walletPlan){dateUTC(e.date);if(!/^(batch|wallet):.+$/.test(e.account)||!Number.isFinite(e.amount)||Math.abs(e.amount)>1e12)throw Error('ตรวจรายการกระเป๋าจำลอง');}}if(s.feedCycle!=null&&(!Number.isInteger(Number(s.feedCycle))||s.feedCycle<4||s.feedCycle>365))throw Error('รอบสั่งอาหารต้องอยู่ระหว่าง 4–365 วัน');if(daysBetween(s.start,s.end)<0||daysBetween(s.start,s.end)>365)throw Error('เลือกช่วงไม่เกิน 366 วัน และวันสิ้นสุดต้องไม่ก่อนวันเริ่ม');for(const k of ['opening','weeklyIncome','weeklyExpense'])if(s[k]!==null&&(!Number.isFinite(Number(s[k]))||(k!=='opening'&&s[k]<0)))throw Error('ตรวจยอดเงินให้ถูกต้อง');for(const k of ['incomeDay','expenseDay'])if(!Number.isInteger(+s[k])||s[k]<0||s[k]>6)throw Error('ตรวจวันประจำสัปดาห์');if(doc.entries.length>1000)throw Error('รายการในแผนเกิน 1,000 รายการ');const ids=new Set();for(const e of doc.entries){dateUTC(e.date);if(!e.id||ids.has(e.id))throw Error('รายการซ้ำ');ids.add(e.id);if(!['income','expense','payment','order'].includes(e.kind)||!['actual','planned'].includes(e.status)||!Number.isFinite(+e.amount)||e.amount<0||e.amount>1e12)throw Error('ตรวจชนิดและจำนวนเงิน');if(e.status==='actual'&&e.date>today)throw Error('ยอดจริงต้องเป็นวันนี้หรือวันที่ผ่านมา');if(e.kind==='order'){if(!(e.quantity>0)||!(e.cycle>=1&&e.cycle<=365)||!(e.credit>=0&&e.credit<=3650))throw Error('ตรวจจำนวนอาหาร รอบสั่ง และเครดิต');dateUTC(e.due);if(e.due<e.date)throw Error('วันจ่ายต้องไม่ก่อนวันสั่ง')}}return doc}
export function incomeBasis(data,today,day=0){const end=shift(weekStart(today,day),-1),from=shift(end,-27),rows=(data.cash||[]).filter(c=>c.kind==='receipt'&&n(c.amount)>0&&c.cash_date>=from&&c.cash_date<=end);return{amount:rows.length?round(rows.reduce((v,c)=>v+n(c.amount),0)/4):null,from,to:end,count:rows.length}}
// One procurement schedule for the central feed bills, not one per product name.
export function foodBasis(data,today,cycleOverride=11){
 const orders=(data.orders||[]).filter(o=>o.is_visible!==false&&o.order_date>=shift(today,-60)&&o.order_date<=today&&n(o.quantity)>0).sort((a,b)=>a.order_date.localeCompare(b.order_date)||a.id.localeCompare(b.id));
 if(!orders.length)return [];
 const dates=[...new Set(orders.map(o=>o.order_date))].slice(-5),last=orders.at(-1),latest=orders.filter(o=>o.order_date===last.order_date),units=new Set(latest.map(o=>o.unit||'หน่วย'));
 const intervals=dates.slice(1).map((d,i)=>daysBetween(dates[i],d));
 const observed=median(intervals),cycle=cycleOverride?Number(cycleOverride):observed?Math.round(observed):null;
 // Mixed units cannot be summed into a fictitious quantity.
 const comparable=dates.map(d=>orders.filter(o=>o.order_date===d)).filter(rows=>rows.every(o=>(o.unit||'หน่วย')===(last.unit||'หน่วย')));
 const quantity=units.size===1?median(comparable.map(rows=>rows.reduce((v,o)=>v+n(o.quantity),0))):null;
 const amount=median(comparable.map(rows=>rows.reduce((v,o)=>v+n(o.total),0)));
 return [{key:'central-procurement',lastId:last.id,name:'รอบสั่งอาหารกลาง',unit:last.unit,quantity,price:quantity?amount/quantity:0,cycle,observedCycle:observed,credit:n(last.credit_days),last:last.order_date,rounds:dates.length,first:cycle?shift(last.order_date,cycle):null}];
}
export function plannerData(data,batchId){
 const orders=(data.orders||[]).filter(o=>o.is_visible!==false),ids=new Set(orders.map(o=>o.id));
 const validBatch=(data.batches||[]).some(b=>b.id===batchId&&b.species_id==='duck');
 const hiddenCash=new Set((data.payments||[]).filter(p=>!ids.has(p.order_id)).map(p=>p.cash_id));
 return {...data,orders,cash:validBatch?(data.cash||[]).filter(c=>c.batch_id===batchId&&!hiddenCash.has(c.id)):[],payments:(data.payments||[]).filter(p=>p.batch_id===batchId&&ids.has(p.order_id))};
}
export function cashflow(data,doc,today){validatePlan(doc,today);const original=data,s=doc.settings,batchId=(data.batches||[]).some(b=>b.id===s.batchId&&b.species_id==='duck')?s.batchId:null;data=plannerData(data,batchId);const hiddenIds=new Set((original.orders||[]).filter(o=>o.is_visible===false).map(o=>o.id));const activeEntries=doc.entries.filter(e=>!hiddenIds.has(e.order_id)&&!hiddenIds.has(e.source_order_id)&&!hiddenIds.has(e.id.replace(/^(order:|due:)/,''))&&e.batch_id===batchId&&batchId&& !e.id.startsWith('food:') && !(e.source_order_id&&(original.orders||[]).some(o=>o.id===e.source_order_id&&o.is_visible===false)));const manual=new Map(activeEntries.map(e=>[e.id,e])),rows=[],used=new Set(),warnings=[];
 const put=e=>{e.batch_id=batchId;const override=manual.get(e.id);if(override){used.add(e.id);e={...e,...override,origin:'manual'}}if(!e.excluded)rows.push(e);return e};
 const orders=data.orders||[],payments=data.payments||[];
 for(const c of data.cash||[]){if(c.kind==='savings_transfer'&&c.reference_id&&(data.cash||[]).filter(x=>x.kind==='savings_transfer'&&x.reference_id===c.reference_id).reduce((v,x)=>v+n(x.amount),0)===0)continue;const p=payments.find(p=>p.cash_id===c.id);put({id:'cash:'+c.id,date:c.cash_date,kind:c.amount>=0?'income':c.kind==='feed_payment'?'payment':'expense',amount:Math.abs(n(c.amount)),status:c.cash_date<=today?'actual':'planned',title:c.note||c.kind,origin:'ledger',batch_id:c.batch_id,order_id:p?.order_id||c.order_id||null,cash_kind:c.kind,reference_id:c.reference_id,locked:true})}
 for(const o of orders)put({id:'order:'+o.id,date:o.order_date,kind:'order',amount:n(o.total),quantity:n(o.quantity),unit:o.unit,title:o.feed_name,status:o.order_date<=today?'actual':'planned',origin:'ledger',locked:true});
 const income=incomeBasis(data,today,s.incomeDay),weekly=s.weeklyIncome===null?income.amount:n(s.weeklyIncome);
 if(batchId&&s.autoIncome&&weekly===null)warnings.push('ไม่มีประวัติเงินรับใน 4 สัปดาห์เต็มล่าสุด กรุณากำหนดเงินรับรายสัปดาห์เอง');
 const autoFrom=shift(today,1);
 for(let d=today;d<=s.end;d=shift(d,1)){const day=dateUTC(d).getUTCDay();if(batchId&&s.autoIncome&&weekly!==null&&day===n(s.incomeDay)&&!(data.cash||[]).some(c=>c.cash_date===d&&c.kind==='receipt'))put({id:'income:'+d,date:d,kind:'income',amount:weekly,status:'planned',title:'เงินรับรายสัปดาห์',origin:'auto'})}

 const basis=foodBasis(data,today,s.feedCycle??11);
 if(!batchId)warnings.push('เลือกลอตเป็ดก่อนคำนวณเงินเข้าและสร้างแผน');
 const parked=doc.entries.filter(e=>!e.batch_id||e.id.startsWith('food:')).length;
 if(parked)warnings.push('พักรายการจากแผนเก่า '+parked+' รายการที่ไม่ระบุล็อตหรือมาจากรอบอาหารเดิม ไม่ได้นำมารวม');
 if(batchId&&s.autoFood)for(const f of basis){
  if(!f.cycle||f.cycle<4||!f.quantity){warnings.push('ประวัติรอบอาหารไม่ชัดเจนหรือหน่วยต่างกัน กรุณากำหนดรอบ/วันสั่งเอง');continue}
  // Honor already-entered future real orders; no replacement forecast alongside them.
  const latestBooked=data.orders.filter(o=>o.order_date>today).map(o=>o.order_date).sort().at(-1);
  let next=latestBooked?shift(latestBooked,f.cycle):f.first;
  if(next<=today){warnings.push('รอบสั่งตามประวัติถึงกำหนดแล้ว ตรวจวันสั่งถัดไปก่อนใช้แผน');next=shift(today,1)}
  const explicit=activeEntries.filter(e=>e.kind==='order'&&!e.excluded&&!e.id.startsWith('food2:')&&e.date>=today).sort((a,b)=>a.date.localeCompare(b.date));
  for(let i=0;i<367&&next<=s.end;i++){
   const chosen=explicit.find(e=>Math.abs(daysBetween(next,e.date))<f.cycle);
   if(chosen){next=shift(chosen.date,Number(chosen.cycle)||f.cycle);continue}
   const id='food2:'+f.lastId+':'+i,base={id,date:next,kind:'order',amount:round(f.quantity*f.price),quantity:f.quantity,unit:f.unit,title:f.name,cycle:f.cycle,credit:f.credit,due:shift(next,f.credit),status:'planned',origin:'auto',basis:f.key,source_order_id:f.lastId};
   const e=put(base);next=shift(e.date,n(e.cycle)||f.cycle);
  }
 }
 // Obsolete generated overrides never turn into extra orders after new history arrives.
 for(const e of activeEntries)if(!used.has(e.id)&&!rows.some(r=>r.id===e.id)&&! /^(food2:|food:|cash:|order:|due:|pay:)/.test(e.id)){if(e.excluded)continue;rows.push({...e,origin:'manual'})}
 // Only explicit manual payments are kept. Never schedule residual bill payments.
 for(const e of activeEntries)if(!e.excluded&&(e.id.startsWith('due:')||e.id.startsWith('pay:')))rows.push({...e,origin:'manual'});
 for(const e of s.walletPlan||[])if(e.account==='batch:'+batchId)rows.push({id:'walletplan:'+e.id,date:e.date,kind:e.amount>=0?'income':'expense',amount:Math.abs(e.amount),title:e.note,status:'planned',origin:'walletplan',locked:true,batch_id:batchId});
 // Presentation cycle is separate from actual cash date. Explicit choices always win.
 const receiptDays=[...new Set(rows.filter(e=>e.kind==='income'&&e.cash_kind==='receipt').map(e=>e.date))].sort();
 for(const e of rows){
  e.displayDate=e.date;
  if(e.kind==='income'){
   const chosen=s.receiptRounds?.[e.id];
   if(chosen){dateUTC(chosen);e.displayDate=chosen;e.roundSource='เลือกเอง'}
   else if(e.cash_kind==='external_contribution'){
    const same=rows.find(r=>r.cash_kind==='receipt'&&r.reference_id&&r.reference_id===e.reference_id);
    const before=receiptDays.filter(d=>d<=e.date&&daysBetween(d,e.date)<=6).at(-1);
    if(same||before){e.displayDate=same?.date||before;e.roundSource=same?'อ้างอิงบิลเดียวกัน':'รอบรับเงินก่อนหน้า (ตรวจแก้ได้)'}
   }
  }
  if(e.kind==='payment'){
   const order=orders.find(o=>o.id===e.order_id)||rows.find(o=>o.kind==='order'&&o.id===e.order_id);
   e.paymentFor=order?{id:order.id,name:order.feed_name||order.title,date:order.order_date||order.date}:null;
  }
 }
 const opening=s.opening===null?round((data.cash||[]).filter(c=>c.cash_date<s.start).reduce((v,c)=>v+n(c.amount),0)+rows.filter(e=>e.date<s.start&&e.origin!=='ledger'&&e.kind!=='order').reduce((v,e)=>v+(e.kind==='income'?1:-1)*n(e.amount),0)):n(s.opening);
 const selected=rows.filter(e=>e.date>=s.start&&e.date<=s.end).sort((a,b)=>a.date.localeCompare(b.date)||a.id.localeCompare(b.id));
 const weeks=[];let balance=opening,min=opening;for(let start=weekStart(s.start,s.incomeDay);start<=s.end;start=shift(start,7)){const from=start<s.start?s.start:start,to=shift(start,6)>s.end?s.end:shift(start,6),entries=selected.filter(e=>e.date>=from&&e.date<=to);const w={start,from,to,opening:balance,income:0,outgoing:0,orders:0,actualIncome:0,plannedIncome:0,actualOut:0,plannedOut:0,entries};for(let d=from;d<=to;d=shift(d,1)){const daily=entries.filter(e=>e.date===d);let delta=0;for(const e of daily){if(e.kind==='order'){w.orders+=n(e.amount);continue}const incoming=e.kind==='income';w[incoming?'income':'outgoing']+=n(e.amount);w[(e.status==='actual'?'actual':'planned')+(incoming?'Income':'Out')]+=n(e.amount);delta+=(incoming?1:-1)*n(e.amount)}balance=round(balance+delta);min=Math.min(min,balance)}w.closing=balance;weeks.push(w)}
 if(selected.some(e=>e.status==='planned'&&e.date<today))warnings.push('มีแผนในอดีตที่ยังไม่ได้ยืนยันยอดจริง กรุณาตรวจหรือยกเลิก');
 if(selected.some(e=>e.kind==='payment'&&e.origin!=='ledger'&&e.order_id&&selected.some(r=>r.kind==='payment'&&r.origin==='ledger'&&r.order_id===e.order_id&&r.date===e.date)))warnings.push('มีรายการจ่ายในแผนตรงวันและบิลกับยอดจ่ายจริง ตรวจและยกเลิกแถวแผนที่ซ้ำเพื่อไม่หักยอดรวมแผนสองครั้ง');
 if(selected.some(e=>e.stale))warnings.push('มีรายการกำหนดเองจากรอบข้อมูลก่อนหน้า ตรวจคู่กับบิลหรือบัญชีจริงและยกเลิกแถวที่ซ้ำ');
 const calendarWeeks=[];for(let start=weekStart(s.start,0);start<=s.end;start=shift(start,7)){const from=start<s.start?s.start:start,to=shift(start,6)>s.end?s.end:shift(start,6),entries=rows.filter(e=>e.displayDate>=from&&e.displayDate<=to);calendarWeeks.push({start,from,to,entries,income:round(entries.filter(e=>e.kind==='income').reduce((v,e)=>v+e.amount,0))})}
 const dailyBalances={};let projected=opening,actual=s.opening===null?round((data.cash||[]).filter(c=>c.cash_date<s.start&&c.cash_date<=today).reduce((v,c)=>v+n(c.amount),0)+rows.filter(e=>e.date<s.start&&e.origin!=='ledger'&&e.status==='actual'&&e.kind!=='order').reduce((v,e)=>v+(e.kind==='income'?1:-1)*n(e.amount),0)):n(s.opening);
 for(let d=s.start;d<=s.end;d=shift(d,1)){const before=actual,projectedBefore=projected;for(const e of selected.filter(e=>e.date===d&&e.kind!=='order')){const delta=(e.kind==='income'?1:-1)*e.amount;projected=round(projected+delta);if(e.status==='actual'&&e.date<=today)actual=round(actual+delta)}const paymentRows=selected.filter(e=>e.date===d&&e.kind==='payment');dailyBalances[d]={before,actual,projectedBefore,projected,foodPaid:round(paymentRows.filter(e=>e.origin==='ledger'&&e.status==='actual').reduce((v,e)=>v+e.amount,0)),foodPlanned:round(paymentRows.filter(e=>e.origin!=='ledger').reduce((v,e)=>v+e.amount,0)),foodPaidCount:paymentRows.filter(e=>e.origin==='ledger'&&e.status==='actual').length};}
 const roundFor=d=>{const from=weekStart(d,s.incomeDay),to=shift(from,6),entries=rows.filter(e=>e.displayDate>=from&&e.displayDate<=to);return {from,to,entries,income:round(entries.filter(e=>e.kind==='income').reduce((v,e)=>v+e.amount,0))}};
 return{rows:selected,allRows:rows,calendarWeeks,dailyBalances,roundFor,weeks,opening,closing:balance,min,income,basis,warnings:[...new Set(warnings)],totalIn:round(weeks.reduce((v,w)=>v+w.income,0)),totalOut:round(weeks.reduce((v,w)=>v+w.outgoing,0))};
}
