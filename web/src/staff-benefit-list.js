import {esc} from './feed-ui.js';
import {money} from './domain.js';
import {thaiMonth} from './staff-month-wheel.js';

const periodFor=(p,m)=>p.cycle==='monthly'?m:p.cycle==='yearly'?m.slice(0,4):'once';
export const benefitPeriodLabel=p=>p==='once'?'ครั้งเดียว':p.length===4?'ปี '+(Number(p)+543):thaiMonth(p);

// Per-policy balances for the selected month, year or one-time grant.
export function benefitRows(doc,people,policies,farms,farm,month,today){
 const periods=new Map(policies.map(p=>[p.id,periodFor(p,month)])),balances=new Map();
 for(const entry of doc.ledger){
  if(periods.get(entry.policy)!==entry.period||!periods.has(entry.policy))continue;
  if(!balances.has(entry.employee))balances.set(entry.employee,new Map());
  const byPolicy=balances.get(entry.employee);
  byPolicy.set(entry.policy,(byPolicy.get(entry.policy)||0)+Number(entry.amount));
 }
 const farmName=farms.find(f=>f.id===farm)?.name||'—';
 const cutoff=today.startsWith(month)?today:month+'-31';
 return people.map(e=>{
  const inScope=(e.assignments||[]).filter(a=>a.farm===farm&&(!a.start||a.start<=cutoff)&&(!a.end||a.end>=month+'-01')).sort((a,b)=>(b.start||'').localeCompare(a.start||''));
  const name=[e.first_name,e.last_name].filter(Boolean).join(' '),unit=inScope.length?farmName:'—',role=inScope.length?(inScope[0].role||e.role||'—'):'—';
  return {id:e.id,code:e.code||'',name,unit,role,index:[name,e.code,e.nickname,unit,role].filter(Boolean).join(' ').toLowerCase(),benefits:policies.map(p=>({id:p.id,name:p.name,unit:p.unit,period:periods.get(p.id),balance:Math.round((balances.get(e.id)?.get(p.id)||0)*100)/100}))};
 });
}
export function benefitList(rows){
 return `<section class="staff-results"><header class="staff-results-head"><h3>สิทธิคงเหลือรายคน</h3><input id="benefitSearch" type="search" aria-controls="benefitRows" aria-label="ค้นหาพนักงาน" placeholder="ค้นหาชื่อ รหัส สังกัด หรือหน้าที่"></header><div class="table-scroll staff-benefit-matrix"><table id="benefitRows"><thead><tr><th scope="col">พนักงาน</th><th scope="col">สังกัด / หน้าที่</th><th scope="col">สวัสดิการ (คงเหลือ)</th></tr></thead><tbody>${rows.map(r=>`<tr data-benefit-person="${esc(r.id)}" data-find="${esc(r.index)}"><td><strong>${esc(r.name)}</strong><small>${esc(r.code)}</small></td><td>${esc(r.unit)}<small>${esc(r.role)}</small></td><td><div class="benefit-links">${r.benefits.map(p=>`<button type="button" aria-haspopup="dialog" data-pay="${esc(r.id)}" data-policy="${esc(p.id)}" data-period="${esc(p.period)}">${esc(p.name)} (${money(p.balance)} ${esc(p.unit)})</button>`).join('')||'—'}</div></td></tr>`).join('')}<tr id="benefitEmpty" ${rows.length?'hidden':''}><td colspan="3">ไม่พบพนักงาน</td></tr></tbody></table></div></section>`;
}
export function benefitSummary(e,p,period,balance){
 return `<div class="benefit-summary"><p>${esc([e.first_name,e.last_name].filter(Boolean).join(' '))} · ${esc(e.code)} · ${esc(benefitPeriodLabel(period))}</p><strong>คงเหลือ ${money(balance)} ${esc(p.unit)}</strong></div>`;
}
