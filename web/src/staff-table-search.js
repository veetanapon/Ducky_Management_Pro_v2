export const personTerms=e=>[e?.code,e?.first_name,e?.last_name,e?.nickname].filter(Boolean).join(' ');
export function bindTableSearch(input,root,empty,initial='',onQuery=()=>{}){
 const rows=[...root.querySelectorAll('[data-find]')];input.value=initial;
 const apply=()=>{const query=input.value,terms=query.trim().toLowerCase().split(/\s+/);let count=0;
  for(const row of rows){row.hidden=!terms.every(t=>row.dataset.find.toLowerCase().includes(t));if(!row.hidden)count++}
  empty.hidden=count>0;onQuery(query);
 };
 input.oninput=apply;apply();
}
