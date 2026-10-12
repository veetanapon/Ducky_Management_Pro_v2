// Prefer an active duck lot on first use; explicit selections always win.
export const sortBatches=rows=>[...rows].sort((a,b)=>Number(a.species_id!=='duck')-Number(b.species_id!=='duck')||Number(a.status==='closed')-Number(b.status==='closed')||String(a.name).localeCompare(String(b.name),'th')||String(a.id).localeCompare(String(b.id)));
