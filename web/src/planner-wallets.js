export function walletSnapshot(data,doc,date,today){
 const funds=(data.context?.funds||[]).map(f=>({id:'batch:'+f.id,name:f.name,rows:(data.cash||[]).filter(r=>r.batch_id===f.id).map(r=>({...r,date:r.cash_date}))}));
 const wallets=(data.wallets||[]).map(w=>({id:'wallet:'+w.id,name:w.name+' · กระเป๋ากลาง',rows:(data.walletEntries||[]).filter(r=>r.wallet_id===w.id).map(r=>({...r,date:r.entry_date}))}));
 return [...funds,...wallets].map(a=>{const actual=a.rows.filter(r=>r.date<=date&&r.date<=today).reduce((s,r)=>s+Number(r.amount),0);const entries=(doc.settings.walletPlan||[]).filter(r=>r.account===a.id&&r.date<=date);return {...a,actual,planned:entries.reduce((s,r)=>s+Number(r.amount),actual),entries}});
}
