export const emptyStaff=()=>({employees:[],policies:[],ledger:[]});
export function staffBalance(doc,employee,policy,period){return doc.ledger.filter(r=>r.employee===employee&&r.policy===policy&&r.period===period).reduce((n,r)=>n+Number(r.amount),0)}
export function validateStaff(doc){
 for(const k of ['employees','policies','ledger']){if(!Array.isArray(doc[k]))throw Error('INVALID_DOCUMENT');const ids=new Set();for(const r of doc[k]){if(!r.id||ids.has(r.id))throw Error('DUPLICATE_ID');ids.add(r.id)}}
 const codes=new Set();for(const e of doc.employees){if(!e.first_name?.trim()||!e.last_name?.trim()||(e.code&&codes.has(e.code)))throw Error('ชื่อ นามสกุล และรหัสพนักงานต้องครบและไม่ซ้ำ');codes.add(e.code);}
 const grants=new Set(),totals=new Map();for(const r of doc.ledger){const e=doc.employees.find(e=>e.id===r.employee),p=doc.policies.find(p=>p.id===r.policy);if(!e||!p||!Number.isFinite(r.amount)||r.amount===0)throw Error('INVALID_LEDGER');const key=[r.employee,r.policy,r.period].join(':');if(r.kind==='grant'){if(grants.has(key)||r.amount<=0)throw Error('รอบนี้ให้สิทธิแล้ว');grants.add(key)}totals.set(key,(totals.get(key)||0)+r.amount);if(totals.get(key)<-0.000001)throw Error('ยอดสิทธิไม่พอ');}
 return doc;
}

export function nextEmployeeCode(employees,start){if(!/^\d{4}-\d{2}-\d{2}$/.test(start)||!Number.isFinite(Date.parse(start)))throw Error('ระบุวันเริ่มงาน');const prefix=String((Number(start.slice(0,4))+543)%100).padStart(2,'0');const max=Math.max(0,...employees.filter(e=>new RegExp('^'+prefix+'[0-9]{3}$').test(e.code)).map(e=>Number(e.code.slice(2))));if(max>=999)throw Error('รหัสพนักงานปีนี้ครบ 999 คนแล้ว');return prefix+String(max+1).padStart(3,'0')}
export function assignEmployeeCodes(document,old){const next=structuredClone(document),pool=[...(old?.employees||[])];for(const e of next.employees){const prior=old?.employees.find(x=>x.id===e.id);e.code=prior?prior.code:nextEmployeeCode(pool,e.start);if(!prior)pool.push(e)}return next}
