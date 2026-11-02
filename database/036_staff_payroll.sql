-- Run after 035. Payroll and annual benefit automation.
begin;

create or replace function private.staff_debit(source text,dt date,amt numeric,ref uuid,memo text)returns void language plpgsql security definer set search_path='' as $$
declare eid uuid:=split_part(source,':',2)::uuid;bal numeric;begin
 if not private.is_admin()or dt is null or dt>(now()at time zone'Asia/Bangkok')::date or amt is null or amt<=0 then raise exception 'INVALID_PAYMENT';end if;
 if split_part(source,':',1)='batch'then
 if not private.can_batch(eid,'finance',true)or not private.feature_allowed('finance.cash',true)or not exists(select 1 from public.batches where id=eid and start_date<=dt)then raise exception 'NO_ACCESS';end if;
 if private.cash_available(eid,dt)<amt then raise exception 'INSUFFICIENT_BATCH_CASH';end if;
 insert into public.batch_cash(batch_id,cash_date,kind,amount,reference_id,note,created_by)values(eid,dt,'expense',-amt,ref,memo,auth.uid());
 elsif split_part(source,':',1)='wallet'then
 if not private.feature_allowed('finance.wallets',true)or not exists(select 1 from public.wallets where id=eid and owner_id=auth.uid())then raise exception 'NO_ACCESS';end if;
 with days as(select entry_date,sum(amount)amount from public.wallet_entries where wallet_id=eid group by entry_date),running as(select entry_date,sum(amount)over(order by entry_date)balance from days),candidates as(select coalesce(sum(amount),0)balance from public.wallet_entries where wallet_id=eid and entry_date<=dt union all select balance from running where entry_date>dt)select min(balance)into bal from candidates;
 if bal<amt then raise exception 'INSUFFICIENT_WALLET_CASH';end if;
 insert into public.wallet_entries(wallet_id,entry_date,amount,transfer_id,note)values(eid,dt,-amt,ref,memo);
 else raise exception 'INVALID_ACCOUNT';end if;
end$$;
revoke all on function private.staff_debit(text,date,numeric,uuid,text)from public,anon,authenticated;
create or replace function public.staff_registry_save(p_data jsonb,p_request uuid)returns jsonb language plpgsql security definer set search_path='' as $$
declare d jsonb:=p_data->'document';old jsonb;v integer;r jsonb;p jsonb;e jsonb;x jsonb;res jsonb;assigned jsonb:='[]';pool jsonb;prior jsonb;prefix text;seq integer;pay jsonb;rate jsonb;gross numeric;paid numeric;today date:=(now() at time zone 'Asia/Bangkok')::date;begin
 if not private.is_admin()then raise exception 'NO_ACCESS';end if;
 perform private.feed_lock();res:=private.request_result(p_request,'staff_registry',p_data);if res is not null then return res;end if;
 select version,document into v,old from private.staff_registry where id=1 for update;
 if coalesce(v,0)<>coalesce((p_data->>'version')::integer,-1)then raise exception 'VERSION_CONFLICT';end if;
 if jsonb_typeof(d)is distinct from 'object' or octet_length(d::text)>20000000 then raise exception 'INVALID_DOCUMENT';end if;
 foreach res in array array[d->'employees',d->'policies',d->'ledger']loop
 if jsonb_typeof(res)is distinct from 'array' or jsonb_array_length(res)>10000 then raise exception 'INVALID_DOCUMENT';end if;
 if exists(select 1 from jsonb_array_elements(res)a where coalesce(a->>'id','')='')or exists(select 1 from jsonb_array_elements(res)a group by a->>'id' having count(*)>1)then raise exception 'DUPLICATE_ID';end if;
 end loop;
 for prefix in select unnest(array['salaryRates','salaryPayments','grantRules'])loop
 d:=jsonb_set(d,array[prefix],coalesce(d->prefix,old->prefix,'[]'::jsonb));
 if jsonb_typeof(d->prefix) is distinct from 'array' or jsonb_array_length(d->prefix)>10000 then raise exception 'INVALID_DOCUMENT';end if;
 if exists(select 1 from jsonb_array_elements(d->prefix)a where coalesce(a->>'id','')='')or exists(select 1 from jsonb_array_elements(d->prefix)a group by a->>'id'having count(*)>1)then raise exception 'DUPLICATE_ID';end if;
 end loop;
 pool:=coalesce(old->'employees','[]');
 for e in select value from jsonb_array_elements(d->'employees')loop
 select value into prior from jsonb_array_elements(coalesce(old->'employees','[]'))a where a->>'id'=e->>'id';
 if prior is not null then e:=jsonb_set(e,'{code}',prior->'code');
 else
 if coalesce(e->>'start','')=''then raise exception 'START_DATE_REQUIRED';end if;
 prefix:=lpad(mod(extract(year from (e->>'start')::date)::integer+543,100)::text,2,'0');
 select coalesce(max(right(a->>'code',3)::integer),0)+1 into seq from jsonb_array_elements(pool)a where a->>'code' ~ ('^'||prefix||'[0-9]{3}$');
 if seq>999 then raise exception 'EMPLOYEE_CODE_YEAR_FULL';end if;
 e:=jsonb_set(e,'{code}',to_jsonb(prefix||lpad(seq::text,3,'0')));pool:=pool||jsonb_build_array(e);
 end if;
 assigned:=assigned||jsonb_build_array(e);
 end loop;
 d:=jsonb_set(d,'{employees}',assigned);
 for e in select value from jsonb_array_elements(d->'employees')loop
 if coalesce(trim(e->>'first_name'),'')=''or coalesce(trim(e->>'last_name'),'')=''or coalesce(trim(e->>'code'),'')=''then raise exception 'INVALID_EMPLOYEE';end if;
 if jsonb_typeof(e->'assignments')is distinct from 'array'then raise exception 'INVALID_ASSIGNMENT';end if;
 for x in select value from jsonb_array_elements(e->'assignments')loop
 if not exists(select 1 from public.farms where id=(x->>'farm')::uuid)or x->>'start' is null then raise exception 'INVALID_FARM';end if;perform (x->>'start')::date;
 if nullif(x->>'end','')::date<(x->>'start')::date then raise exception 'INVALID_DATES';end if;
 end loop;
 if coalesce(e->>'photo','')<>''and (length(e->>'photo')>400000 or e->>'photo'!~'^data:image/jpeg;base64,[A-Za-z0-9+/=]+$')then raise exception 'INVALID_PHOTO';end if;
 if coalesce(e->>'qr','')<>''and (length(e->>'qr')>400000 or e->>'qr'!~'^data:image/jpeg;base64,[A-Za-z0-9+/=]+$')then raise exception 'INVALID_QR';end if;
 end loop;
 if exists(select 1 from jsonb_array_elements(d->'employees')a group by a->>'code' having count(*)>1)then raise exception 'DUPLICATE_EMPLOYEE_CODE';end if;
 for p in select value from jsonb_array_elements(d->'policies')loop
 if coalesce(p->>'name','')=''or coalesce(p->>'unit','')=''or coalesce((p->>'quantity')::numeric,0)<=0 or p->>'cycle' not in('monthly','yearly','once')or not exists(select 1 from public.farms where id=(p->>'farm')::uuid)then raise exception 'INVALID_POLICY';end if;
 end loop;
 -- Historical people, assignments, policy definitions and ledger entries cannot disappear.
 for e in select value from jsonb_array_elements(coalesce(old->'employees','[]'))loop
 select value into x from jsonb_array_elements(d->'employees')a where a->>'id'=e->>'id';if x is null or not ((x->'assignments') @> (e->'assignments'))then raise exception 'EMPLOYEE_HISTORY_REQUIRED';end if;
 end loop;
 for p in select value from jsonb_array_elements(coalesce(old->'policies','[]'))loop
 if not exists(select 1 from jsonb_array_elements(d->'policies')a where a->>'id'=p->>'id'and a-'active'=p-'active' and (p->>'active'<>'false'or a->>'active'='false'))then raise exception 'POLICY_IMMUTABLE';end if;
 end loop;
 for r in select value from jsonb_array_elements(coalesce(old->'ledger','[]'))loop
 if not (d->'ledger' @> jsonb_build_array(r))then raise exception 'LEDGER_IMMUTABLE';end if;
 end loop;
 for r in select value from jsonb_array_elements(d->'ledger')loop
 select value into p from jsonb_array_elements(d->'policies')a where a->>'id'=r->>'policy';select value into e from jsonb_array_elements(d->'employees')a where a->>'id'=r->>'employee';
 if p is null or e is null or r->>'farm' is distinct from p->>'farm'or not exists(select 1 from jsonb_array_elements(e->'assignments')a where a->>'farm'=r->>'farm')or coalesce(r->>'period','')=''or coalesce((r->>'amount')::numeric,0)=0 then raise exception 'INVALID_LEDGER';end if;
 perform (r->>'date')::date;if r->>'date' is null then raise exception 'INVALID_DATE';end if;
 if r->>'kind'='grant'then
 if (r->>'amount')::numeric<>(p->>'quantity')::numeric or (p->>'cycle'='monthly'and r->>'period'!~'^[0-9]{4}-(0[1-9]|1[0-2])$')or (p->>'cycle'='yearly'and r->>'period'!~'^[0-9]{4}$')or(p->>'cycle'='once'and r->>'period'<>'once')then raise exception 'INVALID_GRANT';end if;
 if not(coalesce(old->'ledger','[]') @> jsonb_build_array(r))and(p->>'active'='false'or e->>'status'<>'active')then raise exception 'INACTIVE';end if;
 elsif r->>'kind'='pay'then
 if not(coalesce(old->'ledger','[]') @> jsonb_build_array(r))then
 if (p->>'cycle'='monthly'and r->>'period'>left(r->>'date',7))or(p->>'cycle'='yearly'and r->>'period'>left(r->>'date',4))then raise exception 'BENEFIT_ADVANCE_LIMIT';end if;
 if coalesce(r->>'source','')<>''then
 if p->>'type'<>'money'or (r->>'value')::numeric<>-(r->>'amount')::numeric then raise exception 'INVALID_BENEFIT_MONEY';end if;
 perform private.staff_debit(r->>'source',(r->>'date')::date,(r->>'value')::numeric,(r->>'id')::uuid,'สวัสดิการ '||(p->>'name')||' รอบ '||(r->>'period'));
 end if;end if;
 if (r->>'amount')::numeric>=0 or coalesce((r->>'value')::numeric,0)<0 or(r->>'date')::date>(now()at time zone'Asia/Bangkok')::date or coalesce(r->>'receiver','')=''then raise exception 'INVALID_PAYMENT';end if;
 elsif r->>'kind'='reverse'then
 select value into x from jsonb_array_elements(d->'ledger')a where a->>'id'=r->>'reversal'and a->>'kind'='pay';
 if coalesce(x->>'source','')<>''then raise exception 'LINKED_PAYMENT_REVERSAL_REQUIRES_FINANCE';end if;
 if x is null or x->>'employee'<>r->>'employee'or x->>'policy'<>r->>'policy'or x->>'period'<>r->>'period'or (r->>'amount')::numeric<>-(x->>'amount')::numeric or coalesce((r->>'value')::numeric,0)<>-coalesce((x->>'value')::numeric,0)or coalesce(r->>'note','')=''then raise exception 'INVALID_REVERSAL';end if;
 else raise exception 'INVALID_KIND';end if;
 end loop;
 if exists(select 1 from jsonb_array_elements(d->'ledger')a where a->>'kind'='grant'group by a->>'employee',a->>'policy',a->>'period' having count(*)>1)or exists(select 1 from jsonb_array_elements(d->'ledger')a where a->>'kind'='reverse'group by a->>'reversal'having count(*)>1)then raise exception 'DUPLICATE_LEDGER';end if;
 if exists(select 1 from jsonb_array_elements(d->'ledger')a group by a->>'employee',a->>'policy',a->>'period' having sum((a->>'amount')::numeric)<0)then raise exception 'INSUFFICIENT_BENEFIT';end if;

 -- Payroll history is append-only; whole-document optimistic version and feed lock serialize payments.
 for prefix in select unnest(array['salaryRates','salaryPayments'])loop
 for r in select value from jsonb_array_elements(coalesce(old->prefix,'[]'))loop
 if not(d->prefix @> jsonb_build_array(r))then raise exception 'PAYROLL_HISTORY_IMMUTABLE';end if;
 end loop;
 for r in select value from jsonb_array_elements(d->prefix)loop
 if not exists(select 1 from jsonb_array_elements(d->'employees')a where a->>'id'=r->>'employee')or coalesce(r->>'month','')!~'^[0-9]{4}-(0[1-9]|1[0-2])$'or jsonb_typeof(r->'amount') is distinct from 'number' or (r->>'amount')::numeric<=0 or (r->>'amount')::numeric>1000000000 or round((r->>'amount')::numeric,2)<>(r->>'amount')::numeric then raise exception 'INVALID_PAYROLL';end if;
 end loop;end loop;
 if exists(select 1 from jsonb_array_elements(d->'salaryRates')a group by a->>'employee',a->>'month'having count(*)>1)then raise exception 'DUPLICATE_SALARY_RATE';end if;
 for rate in select value from jsonb_array_elements(d->'salaryRates')loop
 if not(coalesce(old->'salaryRates','[]') @> jsonb_build_array(rate))and exists(select 1 from jsonb_array_elements(coalesce(old->'salaryPayments','[]'))a where a->>'employee'=rate->>'employee'and a->>'month'>=rate->>'month')then raise exception 'SALARY_MONTH_ALREADY_PAID';end if;
 end loop;
 for pay in select value from jsonb_array_elements(d->'salaryPayments')loop
 select (a->>'amount')::numeric into gross from jsonb_array_elements(d->'salaryRates')a where a->>'employee'=pay->>'employee'and a->>'month'<=pay->>'month'order by a->>'month'desc limit 1;
 select sum((a->>'amount')::numeric)into paid from jsonb_array_elements(d->'salaryPayments')a where a->>'employee'=pay->>'employee'and a->>'month'=pay->>'month';
 if gross is null or paid>gross then raise exception 'INSUFFICIENT_SALARY';end if;
 if not(coalesce(old->'salaryPayments','[]') @> jsonb_build_array(pay))then
 select value into e from jsonb_array_elements(d->'employees')a where a->>'id'=pay->>'employee';
 if coalesce(pay->>'date','')=''or (pay->>'date')::date>today or pay->>'kind' is null or pay->>'kind' not in('advance','pay')or (pay->>'kind'='advance'and pay->>'month'<>left(pay->>'date',7))or(pay->>'kind'='pay'and pay->>'month'>=left(pay->>'date',7))or pay->>'month'<left(e->>'start',7)or (nullif(e->>'end','')is not null and pay->>'month'>left(e->>'end',7))then raise exception 'INVALID_SALARY_PERIOD';end if;
 perform private.staff_debit(pay->>'source',(pay->>'date')::date,(pay->>'amount')::numeric,(pay->>'id')::uuid,'เงินเดือน '||coalesce(e->>'code','')||' รอบ '||(pay->>'month')||' '||(pay->>'kind'));
 end if;end loop;
 for r in select value from jsonb_array_elements(coalesce(old->'grantRules','[]'))loop
 if not exists(select 1 from jsonb_array_elements(d->'grantRules')a where a->>'id'=r->>'id'and a-'enabled'=r-'enabled')then raise exception 'GRANT_RULE_HISTORY_REQUIRED';end if;end loop;
 for r in select value from jsonb_array_elements(d->'grantRules')loop
 if not exists(select 1 from jsonb_array_elements(coalesce(old->'grantRules','[]'))a where a->>'id'=r->>'id')and (r->>'start'<to_char(today,'YYYY-MM')or r->>'start'>((extract(year from today)::int+1)::text||'-12'))then raise exception 'INVALID_GRANT_START';end if;
 if coalesce(r->>'start','')!~'^[0-9]{4}-(0[1-9]|1[0-2])$'or jsonb_typeof(r->'policyIds')is distinct from 'array'or jsonb_typeof(r->'excludeIds')is distinct from 'array' then raise exception 'INVALID_GRANT_RULE';end if;
 if exists(select 1 from jsonb_array_elements_text(r->'policyIds')a where not exists(select 1 from jsonb_array_elements(d->'policies')b where b->>'id'=a.value))then raise exception 'INVALID_POLICY';end if;
 if r->'employeeIds'<>'null'::jsonb and jsonb_typeof(r->'employeeIds')is distinct from 'array'then raise exception 'INVALID_GRANT_RULE';end if;
 end loop;
 v:=coalesce(v,0)+1;
 insert into private.staff_registry values(1,v,d,auth.uid(),now())on conflict(id)do update set version=excluded.version,document=excluded.document,updated_by=excluded.updated_by,updated_at=excluded.updated_at;
 insert into private.staff_registry_audit(version,actor,document)values(v,auth.uid(),d);
 return private.finish_request(p_request,'staff_registry',p_data,jsonb_build_object('version',v,'codes',(select jsonb_object_agg(a->>'id',a->>'code')from jsonb_array_elements(d->'employees')a)));
end$$;
revoke all on function public.staff_registry_save(jsonb,uuid)from public,anon,authenticated;
grant execute on function public.staff_registry_save(jsonb,uuid)to authenticated;
commit;
notify pgrst,'reload schema';
