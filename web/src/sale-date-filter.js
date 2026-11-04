export function salesInPeriod(rows,{mode='month',month,from,to}){
 if(mode==='range')return from&&to&&from<=to?rows.filter(x=>x.sale_date>=from&&x.sale_date<=to):[];
 return rows.filter(x=>String(x.sale_date||'').startsWith(month));
}
