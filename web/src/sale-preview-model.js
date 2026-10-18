const round = n => Math.round((n + Number.EPSILON) * 100) / 100;
export function buildSalePreview(values, ownItems, extraItems = []) {
  const type = values.sale_type, unit = {egg:'ฟอง',duck:'ตัว',fish:'กก.'}[type];
  if (!unit || !values.log_date || !values.buyer?.trim()) throw Error('กรอกวันที่และผู้ซื้อก่อนดูบิล');
  const normalize = (item, index) => {
    const number = key => {
      const n = Number(item[key] || 0);
      if (!Number.isFinite(n) || n < 0) throw Error('จำนวนและราคาต้องเป็นตัวเลขตั้งแต่ 0 ขึ้นไป');
      return n;
    };
    const qty = type === 'egg' ? number('stacks') * 300 + number('trays') * 30 + number('pieces') : number('qty');
    if (qty <= 0 || (type !== 'fish' && !Number.isInteger(qty))) throw Error('กรอกจำนวนขายให้มากกว่า 0 และจำนวนฟอง/ตัวต้องเป็นจำนวนเต็ม');
    const price = number('unit_price'), fixed = item.line_total != null && item.line_total !== '';
    const total = round(fixed ? number('line_total') : qty * price - number('discount'));
    if (total < 0) throw Error('ส่วนลดต้องไม่มากกว่ายอดรายการ');
    // A fixed line price overrides both the normal price and discount.
    return {id:'preview-'+index,sale_id:'preview',qty,unit,total,discount:fixed?0:number('discount'),
      unit_price:fixed?total/qty:price,grade:item.grade,
      display_name:item.display_name || item.grade || {egg:'ไข่',duck:'เป็ด',fish:'ปลา'}[type],
      entry:{stacks:item.stacks||0,trays:item.trays||0,pieces:item.pieces||0}};
  };
  if (!ownItems.length && !extraItems.length) throw Error('เพิ่มรายการขายอย่างน้อย 1 รายการจากเล้านี้หรือเล้าอื่น');
  const own = ownItems.map(normalize), extra = extraItems.map((x,i)=>normalize(x,own.length+i)), items = [...own,...extra];
  const sum = list => round(list.reduce((n,x)=>n+x.total,0));
  return {sale:{id:'preview',sale_date:values.log_date,buyer:values.buyer,note:values.note||'',sale_type:type,
    status:'preview',document_title:'ใบแจ้งยอดขาย',total:sum(items)},items,ownTotal:sum(own),extraTotal:sum(extra)};
}
