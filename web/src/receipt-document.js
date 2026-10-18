// Document copies only: never pass these augmented totals to accounting actions.
export function receiptDocument(sales,items){
 const rows=[...items];
 const bills=sales.map(s=>{
  if(s._external_included||!s.external_items?.length)return s;
  const extra=s.external_items.map((x,i)=>({...x,id:s.id+'-external-'+i,sale_id:s.id,external:true}));
  rows.push(...extra);
  const externalTotal=extra.reduce((n,x)=>n+Number(x.total),0);
  return {...s,_external_included:true,_own_total:Number(s.total),_external_total:externalTotal,total:Math.round((Number(s.total)+externalTotal)*100)/100,document_title:'ใบแจ้งยอดขาย'};
 });
 return {sales:bills,items:rows};
}
