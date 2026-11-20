import {esc} from './feed-ui.js';

export function employeeTable(people, ids, farms, farm, today){
 const farmNames=new Map(farms.map(f=>[f.id,f.name]));
 const rows=people.map(p=>{
  const list=(p.assignments||[]).filter(a=>!farm||a.farm===farm).sort((a,b)=>String(b.start||'').localeCompare(String(a.start||'')));
  const assignment=list.find(a=>(!a.start||a.start<=today)&&(!a.end||a.end>=today));
  const unit=assignment?farmNames.get(assignment.farm)||'ไม่ระบุสังกัด':'ไม่มีสังกัดในวันนี้';
  const role=assignment?.role||p.role||'—';
  const name=[p.first_name,p.last_name].filter(Boolean).join(' ');
  return `<tr data-person-name="${esc([p.code,name,p.nickname,unit,role].filter(Boolean).join(' ').toLowerCase())}">
   <td><input type="checkbox" name="employees" aria-label="เลือก ${esc(name)} ${esc(p.code||'')}" value="${esc(p.id)}" ${ids.includes(p.id)?'checked':''}></td>
   <td><strong>${esc(name||'ไม่ระบุชื่อ')}</strong><small>${esc(p.code||'—')}</small></td><td>${esc(unit)}</td><td>${esc(role)}</td></tr>`;
 }).join('');
 return `<section class="wf-picker"><div class="wf-picker-head"><strong>พนักงาน</strong><small data-selection role="status"></small></div>
 <input data-find-people type="search" aria-label="ค้นหาพนักงาน" placeholder="ค้นหาชื่อ รหัส สังกัด หรือหน้าที่">
 <div class="wf-roster-scroll"><table aria-label="เลือกพนักงาน"><colgroup><col class="wf-tick"><col style="width:40%"><col><col></colgroup><thead><tr><th><input type="checkbox" data-visible aria-label="เลือกทุกคนในผลค้นหา" title="เลือกทุกคนในผลค้นหา"></th><th scope="col">ชื่อ / รหัส</th><th scope="col">สังกัด</th><th scope="col">หน้าที่</th></tr></thead>
 <tbody>${rows}<tr data-empty hidden><td colspan="4">ไม่พบพนักงาน</td></tr></tbody></table></div></section>`;
}
export function wireTable(d){
 const root=d.querySelector('.wf-picker'),all=root.querySelector('[data-visible]'),search=root.querySelector('[data-find-people]'),rows=[...root.querySelectorAll('[data-person-name]')];
 const box=r=>r.querySelector('input');
 function sync(){
  const terms=search.value.trim().toLowerCase().split(/\s+/);
  rows.forEach(r=>{r.hidden=!terms.every(t=>r.dataset.personName.includes(t));r.classList.toggle('is-picked',box(r).checked)});
  const visible=rows.filter(r=>!r.hidden),count=visible.filter(r=>box(r).checked).length;
  all.disabled=!visible.length;all.checked=!!visible.length&&visible.length===count;all.indeterminate=count>0&&count<visible.length;
  root.querySelector('[data-empty]').hidden=!!visible.length;
  root.querySelector('[data-selection]').textContent='เลือก '+rows.filter(r=>box(r).checked).length+' / '+rows.length+' คน';
 }
 search.oninput=sync;root.onchange=e=>{if(e.target===all)rows.filter(r=>!r.hidden).forEach(r=>box(r).checked=all.checked);sync()};
 root.querySelector('tbody').onclick=e=>{const r=e.target.closest('tr[data-person-name]');if(r&&e.target!==box(r)){box(r).click()}};
 d.classList.add('wf-edit-dialog');sync();
}
