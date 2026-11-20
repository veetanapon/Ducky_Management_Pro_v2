import {dialog,esc} from './feed-ui.js';
export async function weeklySettings(ctx,l){
 const api=(p_action,p={})=>ctx.db.rpc('weekly_line_admin',{p_link:l.id,p_action,p});
 try{
 const cfg=await api('read'),days=['อาทิตย์','จันทร์','อังคาร','พุธ','พฤหัสบดี','ศุกร์','เสาร์'];
 const check=(k,title,on)=>`<label><input type="checkbox" name="${k}" ${on?'checked':''}> ${title}</label>`;
 const d=dialog('สรุปรายสัปดาห์',`<form><p>บอต ${esc(l.bot_key)} · ${esc(l.name)}</p><label>วันส่งของบอตนี้<select name="dow">${days.map((v,i)=>`<option value="${i}" ${cfg.dow===i?'selected':''}>${v}</option>`).join('')}</select></label>${check('enabled','เปิดส่งสำหรับล็อตนี้',cfg.enabled)}${check('eggs','ไข่ที่เก็บได้',cfg.eggs??true)}${check('feed','อาหารที่กิน',cfg.feed??true)}${check('ship','จำนวนไข่เป็ดที่ส่ง',cfg.ship??true)}<p>แนบกับการบันทึก LIFF ครั้งแรกของวันส่ง ใช้ยอดยืนยันย้อนหลัง 7 วันรวมวันส่ง</p><button>บันทึก</button> ${cfg.enabled&&cfg.last?'<button type="button" data-revise>ส่งฉบับปรับปรุงรอบล่าสุด</button>':''}<p role="status"></p></form>`);
 const f=d.querySelector('form'),msg=f.querySelector('[role=status]');
 async function run(fn){for(const x of f.querySelectorAll('button'))x.disabled=true;try{await fn()}catch(e){msg.textContent=e.message}finally{for(const x of f.querySelectorAll('button'))x.disabled=false}}
 f.onsubmit=e=>{e.preventDefault();run(async()=>{const p={dow:+f.elements.dow.value};for(const k of ['enabled','eggs','feed','ship'])p[k]=f.elements[k].checked;await api('save',p);d.close();ctx.toast('บันทึกการตั้งค่าสรุปแล้ว')})};
 const rev=f.querySelector('[data-revise]'),request=crypto.randomUUID();if(rev)rev.onclick=()=>{if(confirm('ส่งสรุปรอบสิ้นสุด '+new Date(cfg.last+'T12:00:00+07:00').toLocaleDateString('th-TH')+' ไปยังผู้รับของลิงก์นี้ โดยใช้การตั้งค่าที่บันทึกไว้?'))run(async()=>{await api('revise',{request});d.close();ctx.toast('เข้าคิวส่งฉบับปรับปรุงแล้ว')})};
 }catch(e){ctx.toast(e.message)}
}
