// ย้ายชื่อ section ระหว่าง left/right หรือเรียงใหม่ได้ที่นี่ โดยไม่แก้ HTML/CSS รายส่วน
// จอแคบจะเรียงคอลัมน์ left ก่อน right; ไม่ควรใส่ section เดียวซ้ำสองฝั่ง
export const farmLayouts={
 batches:{left:['batch-summary','trends'],right:['pending','week-summary','checks']},
 eggs:{left:['egg-calendar','egg-detail'],right:['egg-summary','egg-factors']},
 sales:{left:['sales'],right:['sale-summary']},
 feed:{left:['feed-stock','feed-history'],right:['feed-pending','feed-trends','feed-returns']},
 events:{left:['events'],right:['event-summary']}
};
export const panelTitles={
 'batch-summary':'ล็อตสัตว์',trends:'แนวโน้ม 28 วัน',pending:'งานรอดำเนินการ','week-summary':'สรุปช่วง 7 วัน',checks:'สิ่งที่ควรตรวจวันนี้',
 'egg-calendar':'ปฏิทินไข่รายวัน','egg-detail':'รายละเอียดวันที่เลือก','egg-summary':'สรุปเดือนที่เลือก','egg-factors':'ปัจจัยร่วมในเดือนนี้',
 sales:'บิลขายของล็อต','sale-summary':'ยอดขายและรอตรวจ','feed-stock':'คลังอาหารของล็อต','feed-history':'ประวัติการกินอาหาร',
 'feed-pending':'รอยืนยันการกินอาหาร','feed-trends':'แนวโน้มอาหาร','feed-returns':'อาหารคืนคลังกลาง',events:'เหตุการณ์และชุดกิจกรรม','event-summary':'สรุปเหตุการณ์'
};
export function arrangeFarmPanels(root,page){const layout=farmLayouts[page],zones=root.querySelectorAll('.farm-workspace>.zone');if(!layout||zones.length!==2)return;const panels=new Map([...root.querySelectorAll('[data-farm-panel]')].map(el=>[el.dataset.farmPanel,el]));for(const[index,side]of ['left','right'].entries())for(const key of layout[side])if(panels.has(key)){zones[index].append(panels.get(key));panels.delete(key)}}
