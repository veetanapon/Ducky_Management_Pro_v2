export const emptyStaff=()=>({employees:[],policies:[],ledger:[]});
export function staffBalance(doc,employee,policy,period){return doc.ledger.filter(r=>r.employee===employee&&r.policy===policy&&r.period===period).reduce((n,r)=>n+Number(r.amount),0)}
export function validateStaff(doc){
 for(const k of ['employees','policies','ledger']){if(!Array.isArray(doc[k]))throw Error('INVALID_DOCUMENT');const ids=new Set();for(const r of doc[k]){if(!r.id||ids.has(r.id))throw Error('DUPLICATE_ID');ids.add(r.id)}}
 const codes=new Set();for(const e of doc.employees){if(!e.first_name?.trim()||!e.last_name?.trim()||!e.code?.trim()||codes.has(e.code))throw Error('ชื่อ นามสกุล และรหัสพนักงานต้องครบและไม่ซ้ำ');codes.add(e.code);}
 const grants=new Set(),totals=new Map();for(const r of doc.ledger){const e=doc.employees.find(e=>e.id===r.employee),p=doc.policies.find(p=>p.id===r.policy);if(!e||!p||!Number.isFinite(r.amount)||r.amount===0)throw Error('INVALID_LEDGER');const key=[r.employee,r.policy,r.period].join(':');if(r.kind==='grant'){if(grants.has(key)||r.amount<=0)throw Error('รอบนี้ให้สิทธิแล้ว');grants.add(key)}totals.set(key,(totals.get(key)||0)+r.amount);if(totals.get(key)<-0.000001)throw Error('ยอดสิทธิไม่พอ');}
 return doc;
}
