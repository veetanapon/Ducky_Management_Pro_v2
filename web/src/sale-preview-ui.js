import {receiptHTML} from './workspace-tools.js';
import {downloadReceipt} from './receipt-download.js';
import {buildSalePreview} from './sale-preview-model.js';

export function mountSalePreview({dialog:d,form,batch,read,db,toast,initialItems=[]}) {
  const button=document.createElement('button');button.type='button';button.textContent='ดูตัวอย่างบิล / ทำบิลส่งลูกค้า';
  form.querySelector('[type=submit]').before(button);
  const extras=document.createElement('details');extras.className='sale-preview-extras';
  extras.innerHTML='<summary>เพิ่มรายการเล้าอื่น เฉพาะบิลส่งลูกค้า</summary><p class="muted">รายการส่วนนี้รวมบนใบแจ้งยอดเท่านั้น ไม่ตัดคลัง ไม่บันทึกยอดขายหรือเงินรับของเล้านี้ เมื่อบันทึกบิล จะเก็บรายการส่วนนี้แนบไว้เพื่อเปิดดูและรวมบิลภายหลัง</p><form class="external-preview-form"><div data-extra-lines></div><button type="button" data-add-extra>เพิ่มรายการเล้าอื่น</button></form>';
  form.after(extras);
  const externalForm=extras.querySelector('form');externalForm.onsubmit=e=>e.preventDefault();
  const input=(label,key,step='0.01')=>`<label>${label}<input data-key="${key}" type="number" min="0" step="${step}" value="0" required></label>`;
  const reset=()=>{extras.querySelector('[data-extra-lines]').replaceChildren()};
  form.elements.sale_type.addEventListener('change',reset);
  const externalOnly=document.createElement('button');externalOnly.type='button';externalOnly.textContent='สร้างบิลเฉพาะรายการเล้าอื่น';
  button.before(externalOnly);
  externalOnly.onclick=()=>{
    form.querySelector('#saleLines')?.replaceChildren();
    extras.open=true;
    if(!extras.querySelector('.external-preview-line'))addExtra();
    read();
  };
  const addExtra=(values={})=>{
    const egg=form.elements.sale_type.value==='egg',line=document.createElement('fieldset');line.className='external-preview-line';
    line.innerHTML=`<legend>รายการเล้าอื่น</legend><label>ชื่อรายการ<input data-key="display_name" maxlength="200" required placeholder="เช่น ไข่เป็ด เบอร์ 23"></label><div class="${egg?'equal-three':'equal-two'}">${egg?input('ตั้ง','stacks','1')+input('แผง','trays','1')+input('ฟอง','pieces','1'):input(form.elements.sale_type.value==='fish'?'น้ำหนัก (กก.)':'จำนวน (ตัว)','qty',form.elements.sale_type.value==='fish'?'0.01':'1')}</div><div class="equal-three">${input(egg?'ราคาต่อฟอง':'ราคาต่อหน่วย','unit_price')}${input('ส่วนลด (บาท)','discount')}<label>ยอดเหมารายการ (ถ้ามี)<input data-key="line_total" type="number" min="0" step="0.01"></label></div><button type="button">ลบรายการ</button>`;
    line.querySelector('button').onclick=()=>line.remove();extras.querySelector('[data-extra-lines]').append(line);for(const input of line.querySelectorAll('[data-key]'))if(values[input.dataset.key]!=null)input.value=values[input.dataset.key];
  };
  extras.querySelector('[data-add-extra]').onclick=()=>addExtra();
  initialItems.forEach(addExtra);
  if(initialItems.length)extras.open=true;
  const getItems=()=>{
    if(!externalForm.checkValidity()){extras.open=true;externalForm.reportValidity();throw Error('กรอกรายการเล้าอื่นให้ครบ')}
    const extra=[...extras.querySelectorAll('.external-preview-line')].map(row=>Object.fromEntries([...row.querySelectorAll('[data-key]')].map(x=>[x.dataset.key,x.value])));
    if(extra.length){const {values,items}=read();buildSalePreview(values,items,extra)}
    return extra;
  };
  button.onclick=()=>{
    try {
      if(!form.reportValidity())return;
      if(!externalForm.checkValidity()){extras.open=true;externalForm.reportValidity();return}
      const {values,items}=read();
      const extra=[...extras.querySelectorAll('.external-preview-line')].map(row=>Object.fromEntries([...row.querySelectorAll('[data-key]')].map(x=>[x.dataset.key,x.value])));
      const result=buildSalePreview(values,items,extra),pane=document.createElement('section');pane.className='sale-preview-pane';
      const money=n=>n.toLocaleString('th-TH',{minimumFractionDigits:2,maximumFractionDigits:2});
      pane.innerHTML=`<div class="sale-preview-controls"><button type="button" data-back>กลับไปแก้รายการ</button><p>ยังไม่ได้บันทึกยอดขาย · เล้านี้ ${money(result.ownTotal)} บาท${extra.length?' · เล้าอื่น '+money(result.extraTotal)+' บาท':''}</p><p class="muted">ใบแจ้งยอดนี้ไม่ใช่หลักฐานรับเงิน เมื่อยืนยัน จะบันทึกยอดขายเฉพาะเล้านี้ และเก็บรายการเล้าอื่นแนบเอกสาร</p><div class="section-actions"><button type="button" data-print>พิมพ์ / PDF</button><button type="button" data-download>บันทึก / แชร์รูป PNG</button></div><label class="receipt-image-option"><input type="checkbox" data-qr>แสดง QR / รูปเพิ่มเติมท้ายบิล</label></div>${receiptHTML([result.sale],result.items,batch)}`;
      const hidden=[...d.children].filter(x=>x.tagName!=='HEADER').map(x=>[x,x.hidden]);hidden.forEach(([x])=>x.hidden=true);
      const scroll=d.scrollTop;d.append(pane);d.classList.add('show-sale-preview');d.scrollTop=0;
      const back=()=>{pane.remove();hidden.forEach(([x,h])=>x.hidden=h);d.classList.remove('show-sale-preview');d.removeEventListener('cancel',cancel);d.scrollTop=scroll;button.focus({preventScroll:true})};
      const cancel=e=>{e.preventDefault();back()};d.addEventListener('cancel',cancel);
      pane.querySelector('[data-back]').onclick=back;pane.querySelector('[data-print]').onclick=()=>window.print();
      pane.querySelector('[data-download]').onclick=async e=>{const target=e.currentTarget;target.disabled=true;try{await downloadReceipt([result.sale],result.items,batch,pane.querySelector('.receipt-extra-image')?.src||null)}catch(err){toast(err.message)}finally{target.disabled=false}};
      pane.querySelector('[data-qr]').onchange=async e=>{const target=e.currentTarget;pane.querySelector('.receipt-extra-image')?.remove();if(!target.checked)return;target.disabled=true;try{const image=await db.getImage('payment_qr',batch.id);if(image.data&&pane.isConnected){const img=document.createElement('img');img.className='receipt-extra-image';img.alt='รูปเพิ่มเติมสำหรับชำระเงิน';img.src=image.data;const article=pane.querySelector('.print-bill');article.insertBefore(img,article.querySelector('.receipt-thanks'))}}catch(err){toast(err.message)}finally{target.disabled=false}};
    }catch(err){toast(err.message)}
  };
  return {getItems};
}
