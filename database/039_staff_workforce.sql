-- Requires 038. All workforce mutations are admin-only, versioned and atomic.
begin;
create or replace function private.staff_leave_deduction(d jsonb,emp text,mon text)returns numeric language sql immutable set search_path='' as $$
 select coalesce(sum((x->>'deduction')::numeric),0)from jsonb_array_elements(coalesce(d->'workforce'->'leaves','[]'))x where x->>'employee'=emp and left(x->>'date',7)=mon and x->>'state'='approved'
$$;
-- Preserve the established payroll/benefit validation and debit transaction.
alter function public.staff_registry_save(jsonb,uuid) rename to staff_registry_save_038;
revoke all on function public.staff_registry_save_038(jsonb,uuid) from public,anon,authenticated;
create function public.staff_registry_save(p_data jsonb,p_request uuid)returns jsonb language plpgsql security definer set search_path='' as $$
declare d jsonb:=p_data->'document';old jsonb;r jsonb;gross numeric;paid numeric;res jsonb;begin
 if not private.is_admin()then raise exception 'NO_ACCESS';end if;
 perform private.feed_lock();res:=private.request_result(p_request,'staff_registry',p_data);if res is not null then return res;end if;
 select document into old from private.staff_registry where id=1 for update;
 if coalesce(d->'workforce','{}') is distinct from coalesce(old->'workforce','{}')then raise exception 'WORKFORCE_USE_ACTION';end if;
 -- Rights used by leave cannot be refunded through the generic benefit screen.
 for r in select value from jsonb_array_elements(coalesce(d->'ledger','[]'))loop
 if not(coalesce(old->'ledger','[]')@>jsonb_build_array(r))and r->>'kind'='reverse'and exists(select 1 from jsonb_array_elements(coalesce(old->'workforce'->'leaves','[]'))l where l->>'ledgerId'=r->>'reversal')then raise exception 'LEAVE_USE_CANCEL';end if;
 end loop;
 for r in select value from jsonb_array_elements(coalesce(d->'salaryRates','[]'))loop
 if not(coalesce(old->'salaryRates','[]')@>jsonb_build_array(r))and exists(select 1 from jsonb_array_elements(coalesce(old->'workforce'->'leaves','[]'))l where l->>'employee'=r->>'employee'and left(l->>'date',7)>=r->>'month'and l->>'state'='approved'and(l->>'unpaidDays')::numeric>0)then raise exception 'LEAVE_RATE_LOCKED';end if;
 end loop;
 for r in select value from jsonb_array_elements(coalesce(d->'salaryPayments','[]'))loop
 select(a->>'amount')::numeric into gross from jsonb_array_elements(coalesce(d->'salaryRates','[]'))a where a->>'employee'=r->>'employee'and a->>'month'<=r->>'month'order by a->>'month'desc limit 1;
 select coalesce(sum((a->>'amount')::numeric),0)into paid from jsonb_array_elements(d->'salaryPayments')a where a->>'employee'=r->>'employee'and a->>'month'=r->>'month';
 if private.staff_leave_deduction(d,r->>'employee',r->>'month')>0 and paid>greatest(0,coalesce(gross,0)-private.staff_leave_deduction(d,r->>'employee',r->>'month'))then raise exception 'INSUFFICIENT_NET_SALARY';end if;
 end loop;
 return public.staff_registry_save_038(p_data,p_request);
end$$;
revoke all on function public.staff_registry_save(jsonb,uuid)from public,anon,authenticated;
grant execute on function public.staff_registry_save(jsonb,uuid)to authenticated;

create function public.staff_workforce_action(p_version integer,p_action text,p_data jsonb,p_request uuid)returns jsonb language plpgsql security definer set search_path='' as $$
declare d jsonb;w jsonb;v integer;res jsonb;e jsonb;r jsonb;s jsonb;t jsonb;b jsonb;rows jsonb;cfg jsonb;ids jsonb;emp text;dt date;fromdt date;todt date;today date:=(now()at time zone'Asia/Bangkok')::date;uid text:=gen_random_uuid()::text;attext text:=now()::text;pid text;period text;policy jsonb;qty numeric;bal numeric;used numeric;unpaid numeric;rate numeric;gross numeric;paid numeric;divisor numeric;deduct numeric;leaveid text;starttime time;endtime time;before_rows jsonb;after_rows jsonb;part text;payload jsonb:=jsonb_build_object('version',p_version,'action',p_action,'data',p_data);begin
 if not private.is_admin()then raise exception 'NO_ACCESS';end if;
 perform private.feed_lock();res:=private.request_result(p_request,'staff_workforce',payload);if res is not null then return res;end if;
 select document,version into d,v from private.staff_registry where id=1 for update;
 if v is null or v<>p_version then raise exception 'VERSION_CONFLICT';end if;
 w:=jsonb_build_object('schedules','[]'::jsonb,'swaps','[]'::jsonb,'ot','[]'::jsonb,'leaves','[]'::jsonb,'settings','{}'::jsonb,'audit','[]'::jsonb)||coalesce(d->'workforce','{}');
 ids:=coalesce(p_data->'employees','[]');if jsonb_typeof(ids)<>'array'or jsonb_array_length(ids)>1000 then raise exception 'INVALID_EMPLOYEES';end if;
 if p_action in('configure','generate','ot')and jsonb_array_length(ids)=0 then raise exception 'SELECT_EMPLOYEES';end if;
 for emp in select distinct value from jsonb_array_elements_text(ids)loop
 if not exists(select 1 from jsonb_array_elements(d->'employees')x where x->>'id'=emp and x->>'status'='active')then raise exception 'INVALID_EMPLOYEE';end if;
 end loop;
 if p_action='configure'then
 cfg:=p_data->'settings';starttime:=(cfg->>'start')::time;endtime:=(cfg->>'end')::time;
 if starttime is null or endtime is null or starttime>=endtime or(cfg->>'breakStart')::time<starttime or(cfg->>'breakEnd')::time>endtime or(cfg->>'breakStart')::time>=(cfg->>'breakEnd')::time or cfg->>'breakStart' is null or cfg->>'breakEnd' is null or jsonb_typeof(cfg->'offDays')is distinct from'array'or coalesce((cfg->>'dailyDivisor')::numeric,0)<=0 or(cfg->>'dailyDivisor')::numeric>366 or coalesce((cfg->>'otRate')::numeric,-1)<0 or coalesce((cfg->>'salaryDays')::numeric,0)<=0 or coalesce((cfg->>'salaryHours')::numeric,0)<=0 or coalesce((cfg->>'otMultiplier')::numeric,-1)<0 or cfg->>'otMode' not in('fixed','salary')then raise exception 'INVALID_SETTINGS';end if;
 if exists(select 1 from jsonb_array_elements_text(cfg->'offDays')x where x.value::integer not between 0 and 6)then raise exception 'INVALID_SETTINGS';end if;
 for emp in select distinct value from jsonb_array_elements_text(ids)loop w:=jsonb_set(w,array['settings',emp],cfg);end loop;
 elsif p_action='generate'then
 fromdt:=(p_data->>'from')::date;todt:=(p_data->>'to')::date;if fromdt is null or todt is null or todt<fromdt or todt-fromdt>366 or fromdt<today then raise exception 'INVALID_DATES';end if;
 for emp in select distinct value from jsonb_array_elements_text(ids)loop
 cfg:=w->'settings'->emp;if cfg is null then raise exception 'SET_WORK_HOURS_FIRST';end if;
 select value into e from jsonb_array_elements(d->'employees')x where x->>'id'=emp;
 for dt in select generate_series(fromdt,todt,interval'1 day')::date loop
 if dt<(e->>'start')::date or dt>coalesce(nullif(e->>'end','')::date,'9999-12-31'::date)then continue;end if;
 if exists(select 1 from jsonb_array_elements(w->'schedules')x where x->>'employee'=emp and x->>'date'=dt::text)then continue;end if;
 s:=jsonb_build_object('id',emp||'@'||dt::text,'employee',emp,'date',dt,'start',cfg->>'start','end',cfg->>'end','breakStart',cfg->>'breakStart','breakEnd',cfg->>'breakEnd','off',(cfg->'offDays')@>jsonb_build_array(extract(dow from dt)::integer));w:=jsonb_set(w,'{schedules}',(w->'schedules')||jsonb_build_array(s));end loop;end loop;
 elsif p_action='ot'then
 dt:=(p_data->>'date')::date;starttime:=(p_data->>'start')::time;endtime:=(p_data->>'end')::time;
 if dt is null or dt<today or starttime is null or endtime is null or starttime>=endtime or coalesce(trim(p_data->>'reason'),'')=''then raise exception 'INVALID_OT';end if;
 for emp in select distinct value from jsonb_array_elements_text(ids)loop
 select value into s from jsonb_array_elements(w->'schedules')x where x->>'employee'=emp and x->>'date'=dt::text;
 if s is null then raise exception 'SCHEDULE_REQUIRED';end if;
 if exists(select 1 from jsonb_array_elements(w->'swaps')x,jsonb_array_elements(x->'after')y where x->>'state'='pending'and y->>'employee'=emp and y->>'date'=dt::text)then raise exception 'APPROVE_SCHEDULE_FIRST';end if;
 if not(s->>'off')::boolean and starttime<(s->>'end')::time and endtime>(s->>'start')::time then raise exception 'OT_OVERLAPS_WORK';end if;
 if exists(select 1 from jsonb_array_elements(w->'ot')x where x->>'employee'=emp and x->>'date'=dt::text and x->>'state'='approved'and starttime<(x->>'end')::time and endtime>(x->>'start')::time)then raise exception 'OT_OVERLAP';end if;
 if exists(select 1 from jsonb_array_elements(w->'leaves')x where x->>'employee'=emp and x->>'date'=dt::text and x->>'state'='approved'and starttime<(x->>'end')::time and endtime>(x->>'start')::time)then raise exception 'OT_OVERLAPS_LEAVE';end if;
 w:=jsonb_set(w,'{ot}',(w->'ot')||jsonb_build_array(jsonb_build_object('id',gen_random_uuid(),'batch',uid,'employee',emp,'date',dt,'start',p_data->>'start','end',p_data->>'end','reason',p_data->>'reason','state','approved','at',attext,'actor',auth.uid())));end loop;
 elsif p_action='cancel_ot'then
 if not exists(select 1 from jsonb_array_elements(w->'ot')x where x->>'id'=p_data->>'id'and x->>'state'='approved')then raise exception 'NOT_FOUND';end if;
 select jsonb_agg(case when x->>'id'=p_data->>'id'then x||jsonb_build_object('state','cancelled','cancelledAt',attext)else x end)into rows from jsonb_array_elements(w->'ot')x;w:=jsonb_set(w,'{ot}',rows);
 elsif p_action='leave'then
 emp:=p_data->>'employee';dt:=(p_data->>'date')::date;part:=p_data->>'part';pid:=p_data->>'policy';
 select value into e from jsonb_array_elements(d->'employees')x where x->>'id'=emp and x->>'status'='active';select value into policy from jsonb_array_elements(d->'policies')x where x->>'id'=pid and x->>'type'='leave'and x->>'active' is distinct from'false';
 if e is null or policy is null or dt is null or part is null or part not in('am','pm','full')or coalesce(trim(p_data->>'reason'),'')=''or not exists(select 1 from jsonb_array_elements(e->'assignments')a where a->>'farm'=policy->>'farm'and(a->>'start')::date<=dt and coalesce(nullif(a->>'end','')::date,'9999-12-31'::date)>=dt)then raise exception 'INVALID_LEAVE';end if;
 select value into s from jsonb_array_elements(w->'schedules')x where x->>'employee'=emp and x->>'date'=dt::text;
 if s is null or(s->>'off')::boolean then raise exception 'LEAVE_REQUIRES_WORKDAY';end if;
 starttime:=case when part='pm'then(s->>'breakEnd')::time else(s->>'start')::time end;endtime:=case when part='am'then(s->>'breakStart')::time else(s->>'end')::time end;
 if exists(select 1 from jsonb_array_elements(w->'leaves')x where x->>'employee'=emp and x->>'date'=dt::text and x->>'state'='approved'and starttime<(x->>'end')::time and endtime>(x->>'start')::time)then raise exception 'LEAVE_OVERLAP';end if;
 if exists(select 1 from jsonb_array_elements(w->'ot')x where x->>'employee'=emp and x->>'date'=dt::text and x->>'state'='approved'and starttime<(x->>'end')::time and endtime>(x->>'start')::time)then raise exception 'OT_OVERLAPS_LEAVE';end if;
 if exists(select 1 from jsonb_array_elements(w->'swaps')x,jsonb_array_elements(x->'after')y where x->>'state'='pending'and y->>'employee'=emp and y->>'date'=dt::text)then raise exception 'APPROVE_SCHEDULE_FIRST';end if;
 period:=case policy->>'cycle'when'monthly'then to_char(dt,'YYYY-MM')when'yearly'then to_char(dt,'YYYY')else'once'end;qty:=case part when'full'then 1 else .5 end;
 select coalesce(sum((x->>'amount')::numeric),0)into bal from jsonb_array_elements(d->'ledger')x where x->>'employee'=emp and x->>'policy'=pid and x->>'period'=period;
 used:=least(qty,greatest(0,bal));unpaid:=qty-used;cfg:=w->'settings'->emp;divisor:=coalesce((cfg->>'dailyDivisor')::numeric,30);
 select(x->>'amount')::numeric into gross from jsonb_array_elements(coalesce(d->'salaryRates','[]'))x where x->>'employee'=emp and x->>'month'<=to_char(dt,'YYYY-MM')order by x->>'month'desc limit 1;
 if unpaid>0 and coalesce(gross,0)<=0 then raise exception 'SET_SALARY_FOR_UNPAID_LEAVE';end if;
 rate:=coalesce(gross,0)/divisor;deduct:=round(unpaid*rate,2);
 select coalesce(sum((x->>'amount')::numeric),0)into paid from jsonb_array_elements(coalesce(d->'salaryPayments','[]'))x where x->>'employee'=emp and x->>'month'=to_char(dt,'YYYY-MM');
 if paid>greatest(0,coalesce(gross,0)-private.staff_leave_deduction(d,emp,to_char(dt,'YYYY-MM'))-deduct)then raise exception 'LEAVE_MONTH_ALREADY_PAID';end if;
 leaveid:=gen_random_uuid()::text;
 r:=jsonb_build_object('id',uid,'employee',emp,'date',dt,'policy',pid,'period',period,'part',part,'start',to_char(starttime,'HH24:MI'),'end',to_char(endtime,'HH24:MI'),'days',qty,'paidDays',used,'unpaidDays',unpaid,'dailyRate',round(rate,6),'dailyDivisor',divisor,'deduction',deduct,'reason',p_data->>'reason','state','approved','ledgerId',case when used>0 then leaveid else null end,'at',attext,'actor',auth.uid());
 w:=jsonb_set(w,'{leaves}',(w->'leaves')||jsonb_build_array(r));
 if used>0 then d:=jsonb_set(d,'{ledger}',(d->'ledger')||jsonb_build_array(jsonb_build_object('id',leaveid,'employee',emp,'policy',pid,'farm',policy->>'farm','date',today,'period',period,'amount',-used,'kind','pay','value',0,'receiver',e->>'first_name','note','ลา '||dt::text||' '||part,'leaveId',uid)));end if;
 elsif p_action='cancel_leave'then
 select value into r from jsonb_array_elements(w->'leaves')x where x->>'id'=p_data->>'id'and x->>'state'='approved';if r is null or coalesce(trim(p_data->>'reason'),'')=''then raise exception 'INVALID_LEAVE_CANCEL';end if;
 if exists(select 1 from jsonb_array_elements(coalesce(d->'salaryPayments','[]'))x where x->>'employee'=r->>'employee'and x->>'month'=left(r->>'date',7)and x->>'kind'='pay')then raise exception 'LEAVE_MONTH_ALREADY_PAID';end if;
 if coalesce(r->>'ledgerId','')<>''then
 select value into t from jsonb_array_elements(d->'ledger')x where x->>'id'=r->>'ledgerId';
 d:=jsonb_set(d,'{ledger}',(d->'ledger')||jsonb_build_array(t||jsonb_build_object('id',gen_random_uuid(),'kind','reverse','reversal',t->>'id','amount',-(t->>'amount')::numeric,'date',today,'note',p_data->>'reason')));end if;
 select jsonb_agg(case when x->>'id'=r->>'id'then x||jsonb_build_object('state','cancelled','cancelledAt',attext,'cancelReason',p_data->>'reason')else x end)into rows from jsonb_array_elements(w->'leaves')x;w:=jsonb_set(w,'{leaves}',rows);
 elsif p_action='swap'then
 rows:=w->'schedules';select value into b from jsonb_array_elements(w->'swaps')x where x->>'state'='pending';if b is not null then for r in select value from jsonb_array_elements(b->'after')loop select jsonb_agg(case when x->>'id'=r->>'id'then r else x end)into rows from jsonb_array_elements(rows)x;end loop;end if;
 select value into s from jsonb_array_elements(rows)x where x->>'id'=p_data->>'from';select value into t from jsonb_array_elements(rows)x where x->>'id'=p_data->>'to';
 if s is null or t is null or s->>'employee'=t->>'employee'or(s->>'date')::date<today or(t->>'date')::date<today then raise exception 'INVALID_SWAP';end if;
 if exists(select 1 from jsonb_array_elements(w->'leaves')x where x->>'state'='approved'and x->>'employee'in(s->>'employee',t->>'employee')and x->>'date'in(s->>'date',t->>'date'))or exists(select 1 from jsonb_array_elements(w->'ot')x where x->>'state'='approved'and x->>'employee'in(s->>'employee',t->>'employee')and x->>'date'in(s->>'date',t->>'date'))then raise exception 'SWAP_HAS_LEAVE_OR_OT';end if;
 select jsonb_agg(x)into before_rows from jsonb_array_elements(rows)x where x->>'employee'in(s->>'employee',t->>'employee')and x->>'date'in(s->>'date',t->>'date');
 -- Swap daily duties; preserve one row per person/date and their identity.
 after_rows:='[]';for r in select value from jsonb_array_elements(before_rows)loop
 select value into cfg from jsonb_array_elements(before_rows)x where x->>'date'=r->>'date'and x->>'employee'<>r->>'employee';if cfg is null then raise exception 'BOTH_PEOPLE_NEED_SCHEDULE';end if;
 after_rows:=after_rows||jsonb_build_array(cfg||jsonb_build_object('id',r->>'id','employee',r->>'employee','override',true,'displayOrder',cfg->>'employee'));
 end loop;
 if b is null then b:=jsonb_build_object('id',uid,'state','pending','before','[]'::jsonb,'after','[]'::jsonb,'count',0);end if;
 for r in select value from jsonb_array_elements(before_rows)loop if not exists(select 1 from jsonb_array_elements(b->'before')x where x->>'id'=r->>'id')then b:=jsonb_set(b,'{before}',(b->'before')||jsonb_build_array(r));end if;end loop;
 for r in select value from jsonb_array_elements(after_rows)loop select coalesce(jsonb_agg(x),'[]')into cfg from jsonb_array_elements(b->'after')x where x->>'id'<>r->>'id';b:=jsonb_set(b,'{after}',cfg||jsonb_build_array(r));end loop;
 b:=b||jsonb_build_object('count',(b->>'count')::integer+1,'at',attext);select coalesce(jsonb_agg(x),'[]')into rows from jsonb_array_elements(w->'swaps')x where x->>'id'<>b->>'id';w:=jsonb_set(w,'{swaps}',rows||jsonb_build_array(b));
 elsif p_action in('approve_swap','reject_swap')then
 select value into b from jsonb_array_elements(w->'swaps')x where x->>'id'=p_data->>'id'and x->>'state'='pending';if b is null then raise exception 'NOT_FOUND';end if;
 if p_action='approve_swap'then
 for r in select value from jsonb_array_elements(b->'before')loop if not exists(select 1 from jsonb_array_elements(w->'schedules')x where x=r)then raise exception 'SCHEDULE_CONFLICT';end if;end loop;
 for r in select value from jsonb_array_elements(b->'after')loop select jsonb_agg(case when x->>'id'=r->>'id'then r else x end)into rows from jsonb_array_elements(w->'schedules')x;w:=jsonb_set(w,'{schedules}',rows);end loop;end if;
 select jsonb_agg(case when x->>'id'=b->>'id'then x||jsonb_build_object('state',case when p_action='approve_swap'then'approved'else'rejected'end,'decidedAt',attext,'actor',auth.uid())else x end)into rows from jsonb_array_elements(w->'swaps')x;w:=jsonb_set(w,'{swaps}',rows);
 else raise exception 'INVALID_ACTION';end if;
 w:=jsonb_set(w,'{audit}',(w->'audit')||jsonb_build_array(jsonb_build_object('id',uid,'action',p_action,'data',p_data,'before',before_rows,'after',after_rows,'at',attext,'actor',auth.uid())));
 d:=jsonb_set(d,'{workforce}',w);if octet_length(d::text)>20000000 then raise exception 'DOCUMENT_TOO_LARGE';end if;v:=v+1;
 update private.staff_registry set document=d,version=v,updated_by=auth.uid(),updated_at=now()where id=1;insert into private.staff_registry_audit(version,actor,document)values(v,auth.uid(),d);
 return private.finish_request(p_request,'staff_workforce',payload,jsonb_build_object('version',v,'document',d));
end$$;
revoke all on function public.staff_workforce_action(integer,text,jsonb,uuid)from public,anon,authenticated;
grant execute on function public.staff_workforce_action(integer,text,jsonb,uuid)to authenticated;
revoke all on function private.staff_leave_deduction(jsonb,text,text)from public,anon,authenticated;
commit;
notify pgrst,'reload schema';
