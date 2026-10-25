begin;
create table if not exists private.staff_registry(id integer primary key check(id=1),version integer not null,document jsonb not null,updated_by uuid references public.profiles,updated_at timestamptz not null default now());
create table if not exists private.staff_registry_audit(id bigint generated always as identity primary key,version integer not null,actor uuid not null,created_at timestamptz not null default now(),document jsonb not null);
revoke all on private.staff_registry,private.staff_registry_audit from public,anon,authenticated;
create or replace function public.staff_registry_read()returns jsonb language plpgsql security definer set search_path='' as $$begin
 if not private.is_admin() then raise exception 'NO_ACCESS';end if;
 return coalesce((select jsonb_build_object('version',version,'document',document)from private.staff_registry where id=1),'{"version":0,"document":null}'::jsonb)||jsonb_build_object('farms',(select coalesce(jsonb_agg(jsonb_build_object('id',id,'name',name)order by name),'[]')from public.farms));
end$$;
create or replace function public.staff_registry_save(p_data jsonb,p_request uuid)returns jsonb language plpgsql security definer set search_path='' as $$
declare d jsonb:=p_data->'document';old jsonb;v integer;r jsonb;p jsonb;e jsonb;x jsonb;res jsonb;begin
 if not private.is_admin()then raise exception 'NO_ACCESS';end if;
 perform private.feed_lock();res:=private.request_result(p_request,'staff_registry',p_data);if res is not null then return res;end if;
 select version,document into v,old from private.staff_registry where id=1 for update;
 if coalesce(v,0)<>coalesce((p_data->>'version')::integer,-1)then raise exception 'VERSION_CONFLICT';end if;
 if jsonb_typeof(d)is distinct from 'object' or octet_length(d::text)>20000000 then raise exception 'INVALID_DOCUMENT';end if;
 foreach res in array array[d->'employees',d->'policies',d->'ledger']loop
 if jsonb_typeof(res)is distinct from 'array' or jsonb_array_length(res)>10000 then raise exception 'INVALID_DOCUMENT';end if;
 if exists(select 1 from jsonb_array_elements(res)a where coalesce(a->>'id','')='')or exists(select 1 from jsonb_array_elements(res)a group by a->>'id' having count(*)>1)then raise exception 'DUPLICATE_ID';end if;
 end loop;
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
 if (r->>'amount')::numeric>=0 or coalesce((r->>'value')::numeric,0)<0 or(r->>'date')::date>(now()at time zone'Asia/Bangkok')::date or coalesce(r->>'receiver','')=''then raise exception 'INVALID_PAYMENT';end if;
 elsif r->>'kind'='reverse'then
 select value into x from jsonb_array_elements(d->'ledger')a where a->>'id'=r->>'reversal'and a->>'kind'='pay';
 if x is null or x->>'employee'<>r->>'employee'or x->>'policy'<>r->>'policy'or x->>'period'<>r->>'period'or (r->>'amount')::numeric<>-(x->>'amount')::numeric or coalesce((r->>'value')::numeric,0)<>-coalesce((x->>'value')::numeric,0)or coalesce(r->>'note','')=''then raise exception 'INVALID_REVERSAL';end if;
 else raise exception 'INVALID_KIND';end if;
 end loop;
 if exists(select 1 from jsonb_array_elements(d->'ledger')a where a->>'kind'='grant'group by a->>'employee',a->>'policy',a->>'period' having count(*)>1)or exists(select 1 from jsonb_array_elements(d->'ledger')a where a->>'kind'='reverse'group by a->>'reversal'having count(*)>1)then raise exception 'DUPLICATE_LEDGER';end if;
 if exists(select 1 from jsonb_array_elements(d->'ledger')a group by a->>'employee',a->>'policy',a->>'period' having sum((a->>'amount')::numeric)<0)then raise exception 'INSUFFICIENT_BENEFIT';end if;
 v:=coalesce(v,0)+1;
 insert into private.staff_registry values(1,v,d,auth.uid(),now())on conflict(id)do update set version=excluded.version,document=excluded.document,updated_by=excluded.updated_by,updated_at=excluded.updated_at;
 insert into private.staff_registry_audit(version,actor,document)values(v,auth.uid(),d);
 return private.finish_request(p_request,'staff_registry',p_data,jsonb_build_object('version',v));
end$$;
revoke all on function public.staff_registry_read(),public.staff_registry_save(jsonb,uuid)from public,anon,authenticated;
grant execute on function public.staff_registry_read(),public.staff_registry_save(jsonb,uuid)to authenticated;
create or replace function public.staff_farm_create(p_name text)returns jsonb language plpgsql security definer set search_path='' as $$declare fid uuid;begin
if not private.is_admin()then raise exception 'NO_ACCESS';end if;
if coalesce(trim(p_name),'')=''or length(p_name)>200 then raise exception 'INVALID_NAME';end if;
perform private.feed_lock();select id into fid from public.farms where name=trim(p_name)limit 1;
if fid is null then insert into public.farms(name)values(trim(p_name))returning id into fid;end if;
return jsonb_build_object('id',fid,'farms',(select jsonb_agg(jsonb_build_object('id',id,'name',name)order by name)from public.farms));end$$;
revoke all on function public.staff_farm_create(text)from public,anon,authenticated;
grant execute on function public.staff_farm_create(text)to authenticated;
commit;
notify pgrst,'reload schema';
