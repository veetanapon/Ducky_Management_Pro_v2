// Prepare the file first. Sharing/opening then happens directly from a fresh tap.
export function receiptExportPanel(){
  document.querySelector('#receiptExportDialog')?.close();
  const d=document.createElement('dialog');d.id='receiptExportDialog';d.className='work-dialog receipt-export-dialog';
  d.innerHTML='<header><h2>รูปบิล</h2><button type="button" aria-label="กลับไปหน้าบิล">✕</button></header><p data-export-status role="status">กำลังสร้างรูปบิล…</p><div class="receipt-export-actions" hidden><button type="button" data-share-image>แชร์ / บันทึกรูป</button><a data-save-image>ดาวน์โหลด PNG</a><a data-view-image target="_blank" rel="noopener">เปิดรูปเต็ม</a></div><p class="muted" data-export-help hidden>iPhone / iPad: กดแชร์ แล้วเลือกบันทึกรูปภาพหรือบันทึกไปยังไฟล์ หรือแตะรูปค้างไว้เพื่อใช้เมนูของเครื่อง หากเปิดจาก LINE แล้วเมนูแชร์ไม่รองรับ ให้เปิดเว็บใน Safari</p><img class="receipt-export-image" alt="รูปบิลสำหรับบันทึกหรือแชร์" hidden>';
  document.body.append(d);d.querySelector('header button').onclick=()=>d.close();let url=null;
  d.addEventListener('close',()=>{d.remove();if(url)setTimeout(()=>URL.revokeObjectURL(url),60000)});
  d.showModal();
  const status=d.querySelector('[data-export-status]');
  return {
    async ready(src,name){
      const blob=await (await fetch(src)).blob();
      if(!d.isConnected)return;
      const file=new File([blob],name,{type:'image/png'});url=URL.createObjectURL(file);
      const img=d.querySelector('img');img.src=url;img.hidden=false;
      const save=d.querySelector('[data-save-image]');save.href=url;save.download=name;
      d.querySelector('[data-view-image]').href=url;
      d.querySelector('.receipt-export-actions').hidden=false;d.querySelector('[data-export-help]').hidden=false;
      status.textContent='รูปพร้อมแล้ว เลือกแชร์ บันทึก หรือเปิดรูปเต็มได้เลย';
      const share=d.querySelector('[data-share-image]');
      let canShare=false;try{canShare=!!navigator.share&&!!navigator.canShare?.({files:[file]})}catch{}
      share.hidden=!canShare;
      share.onclick=()=>{
        // No await before share: iOS requires an active user gesture.
        try{
          const result=navigator.share({files:[file]});
          Promise.resolve(result).then(()=>{status.textContent='กลับมาแชร์หรือบันทึกรูปซ้ำได้'},err=>{
            status.textContent=err.name==='AbortError'?'ยกเลิกการแชร์แล้ว รูปบิลยังอยู่ด้านล่าง':'เครื่องนี้เปิดเมนูแชร์ไม่ได้ ลองแตะรูปค้างไว้ หรือกดเปิดรูปเต็ม';
          });
        }catch{status.textContent='เปิดเมนูแชร์ไม่ได้ ลองแตะรูปค้างไว้ หรือกดเปิดรูปเต็ม'}
      };
    },
    error(error){if(d.isConnected)status.textContent='สร้างรูปบิลไม่สำเร็จ: '+error.message+' · ปิดหน้าต่างแล้วลองใหม่ได้'}
  };
}
