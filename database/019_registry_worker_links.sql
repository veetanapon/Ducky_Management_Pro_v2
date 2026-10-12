-- Run once after 018. No production data is deleted.
begin;
alter table public.wallet_entries add column created_at timestamptz not null default clock_timestamp();
alter table public.buyers add column full_name text,add column bank_account text,add column address text,add column phone text,add column version int not null default 1;
alter table public.tax_records add column source_label text;
alter table public.feed_allocations add column source_order_date date;
update public.feed_allocations a set source_order_date=o.order_date from public.feed_orders o where o.id=a.order_id;
create function private.allocation_source_date()returns trigger language plpgsql security definer set search_path='' as $$begin select order_date into new.source_order_date from public.feed_orders where id=new.order_id;return new;end$$;
create trigger source_date before insert or update of order_id on public.feed_allocations for each row execute function private.allocation_source_date();
revoke all on function private.allocation_source_date()from public,anon,authenticated;
alter function public.account_manage(jsonb,uuid)rename to account_manage_v101;
revoke all on function public.account_manage_v101(jsonb,uuid)from public,anon,authenticated;
create function public.account_manage(p_data jsonb,p_request uuid)returns jsonb language plpgsql security definer set search_path='' as $$declare r jsonb;sid uuid;begin
if p_data->>'action'='buyer'then
perform private.feed_lock();if not private.feature_allowed('farm.sales',true)then raise exception 'NO_ACCESS';end if;
r:=private.request_result(p_request,'buyer-v11',p_data);if r is not null then return r;end if;
if length(trim(coalesce(p_data->>'name','')))not between 1 and 200 or length(coalesce(p_data->>'full_name',''))>200 or length(coalesce(p_data->>'address',''))>1000 or length(coalesce(p_data->>'phone',''))>40 or length(coalesce(p_data->>'bank_account',''))>200 then raise exception 'INVALID_BUYER';end if;
sid:=nullif(p_data->>'id','')::uuid;
if sid is null then insert into public.buyers(name,full_name,bank_account,address,phone,active)values(trim(p_data->>'name'),p_data->>'full_name',p_data->>'bank_account',p_data->>'address',p_data->>'phone',coalesce((p_data->>'active')::boolean,true))returning id into sid;
else update public.buyers set name=trim(p_data->>'name'),full_name=p_data->>'full_name',bank_account=p_data->>'bank_account',address=p_data->>'address',phone=p_data->>'phone',active=coalesce((p_data->>'active')::boolean,true),version=version+1 where id=sid and owner_id=auth.uid()and version=(p_data->>'version')::int;if not found then raise exception 'VERSION_CONFLICT';end if;end if;
return private.finish_request(p_request,'buyer-v11',p_data,jsonb_build_object('id',sid));end if;
if p_data->>'action'='tax'and length(trim(coalesce(p_data->>'source_label','')))not between 1 and 200 then raise exception 'TAX_SOURCE_REQUIRED';end if;
r:=public.account_manage_v101(p_data,p_request);
if p_data->>'action'='tax'then update public.tax_records set source_label=trim(p_data->>'source_label')where id=(r->>'id')::uuid;end if;return r;end$$;
revoke all on function public.account_manage(jsonb,uuid)from public,anon;grant execute on function public.account_manage(jsonb,uuid)to authenticated;
-- Only the authorized link manager may retrieve a secret URL.
create table private.access_secrets(link_id uuid primary key references public.access_links on delete cascade,token text not null);
revoke all on private.access_secrets from public,anon,authenticated;
alter table public.access_links add column bot_key text,add column line_to_id text,add column version int not null default 1;
alter function public.access_manage(jsonb,uuid)rename to access_manage_v101;
revoke all on function public.access_manage_v101(jsonb,uuid)from public,anon,authenticated;
create function public.access_manage(p_data jsonb,p_request uuid)returns jsonb language plpgsql security definer set search_path='' as $$declare p jsonb:=p_data;r jsonb;l public.access_links;b uuid:=(p->>'batch_id')::uuid;ex timestamptz;tok text;begin
perform private.feed_lock();if not private.can_batch(b,'farm',true)or not private.can_batch(b,'finance')or not private.feature_allowed('farm.links',true)then raise exception 'NO_ACCESS';end if;
r:=private.request_result(p_request,'access-v11',p);if r is not null then return r;end if;
if length(coalesce(p->>'bot_key',''))>80 or coalesce(p->>'bot_key','')!~'^[A-Za-z0-9_]*$'or(coalesce(p->>'line_to_id','')<>''and p->>'line_to_id'!~'^[UCR][0-9a-fA-F]{32}$')then raise exception 'INVALID_LINE_DESTINATION';end if;
if p->>'action'='create'then
r:=public.access_manage_v101(p,gen_random_uuid());insert into private.access_secrets values((r->>'id')::uuid,r->>'token');update public.access_links set bot_key=nullif(p->>'bot_key',''),line_to_id=nullif(p->>'line_to_id','')where id=(r->>'id')::uuid;
elsif p->>'action' in('edit','rotate')then
select * into strict l from public.access_links where id=(p->>'id')::uuid and batch_id=b and not revoked for update;
if l.version is distinct from(p->>'version')::int then raise exception 'VERSION_CONFLICT';end if;
if p->>'action'='rotate'then tok:=replace(gen_random_uuid()::text||gen_random_uuid()::text,'-','');update public.access_links set token_hash=sha256(convert_to(tok,'UTF8')),version=version+1 where id=l.id;insert into private.access_secrets values(l.id,tok)on conflict(link_id)do update set token=excluded.token;r:=jsonb_build_object('id',l.id,'token',tok);
else
ex:=case when l.kind='liff'and coalesce((p->>'no_expiry')::boolean,false)then null else coalesce(nullif(p->>'expires_at','')::timestamptz,now()+interval '4 hours')end;
if ex<=now()or(l.kind='display'and ex>now()+interval '30 days')then raise exception 'INVALID_EXPIRY';end if;
if nullif(p->>'liff_id','')is not null and p->>'liff_id'!~'^[0-9]+-[A-Za-z0-9]+$'then raise exception 'INVALID_LIFF_ID';end if;
update public.access_links set name=trim(p->>'name'),expires_at=ex,liff_id=nullif(p->>'liff_id',''),bot_key=nullif(p->>'bot_key',''),line_to_id=nullif(p->>'line_to_id',''),version=version+1 where id=l.id;r:=jsonb_build_object('id',l.id);end if;
else r:=public.access_manage_v101(p,gen_random_uuid());end if;
return private.finish_request(p_request,'access-v11',p,r);end$$;
revoke all on function public.access_manage(jsonb,uuid)from public,anon;grant execute on function public.access_manage(jsonb,uuid)to authenticated;
alter function public.access_list(uuid)rename to access_list_v101;revoke all on function public.access_list_v101(uuid)from public,anon,authenticated;
create function public.access_list(p_batch uuid)returns jsonb language plpgsql security definer set search_path='' as $$declare r jsonb;begin
if not private.feature_allowed('farm.links')then raise exception 'NO_ACCESS';end if;r:=public.access_list_v101(p_batch);
return jsonb_set(r,'{links}',coalesce((select jsonb_agg(x.value||jsonb_build_object('token',s.token))from jsonb_array_elements(r->'links')x left join private.access_secrets s on s.link_id=(x.value->>'id')::uuid),'[]'));end$$;
revoke all on function public.access_list(uuid)from public,anon;grant execute on function public.access_list(uuid)to authenticated;
-- Worker UI dates are enforced on the server. Food quantities are unassigned until reviewed.
alter function public.access_read(text,date)rename to access_read_v101;revoke all on function public.access_read_v101(text,date)from public,anon,authenticated;
create function public.access_read(p_token text,p_date date default null)returns jsonb language plpgsql security definer set search_path='' as $$declare l public.access_links;d date:=(now()at time zone 'Asia/Bangkok')::date;r jsonb;begin l:=private.access_valid(p_token);if l.kind='display'then return public.access_read_v101(p_token,p_date);end if;r:=public.access_read_v101(p_token,d);return(r-'allocations')||jsonb_build_object('liff_id',l.liff_id,'today',d,'feed_date',d-1,'live_count',private.farm_animal_balance(l.batch_id,d));end$$;
revoke all on function public.access_read(text,date)from public;grant execute on function public.access_read(text,date)to anon,authenticated;
alter function public.worker_submit(text,jsonb,uuid)rename to worker_submit_v101;revoke all on function public.worker_submit_v101(text,jsonb,uuid)from public,anon,authenticated;
create function public.worker_submit(p_token text,p_data jsonb,p_request uuid)returns jsonb language plpgsql security definer set search_path='' as $$declare l public.access_links;q jsonb:=p_data->'payload';p jsonb:=p_data;k text:=p_data->>'kind';d date;old public.worker_submissions;r jsonb;sid uuid;issued numeric;leftover numeric;begin
perform private.feed_lock();l:=private.access_valid(p_token);if l.kind<>'liff'or not coalesce(k=any(l.actions),false)or p_request is null then raise exception 'NO_ACCESS';end if;
d:=(now()at time zone 'Asia/Bangkok')::date-case when k='feed'then 1 else 0 end;
-- A retry keeps the original day even across midnight.
select * into old from public.worker_submissions where request_id=p_request;
if found then d:=old.log_date;end if;
p:=jsonb_set(p,'{log_date}',to_jsonb(d::text));
if k<>'feed'then
if k='egg'then p:=jsonb_set(p,'{payload}',q||jsonb_build_object('live_count',private.farm_animal_balance(l.batch_id,d)));end if;
return public.worker_submit_v101(p_token,p,p_request);end if;
q:=jsonb_build_object('issued',private.farm_num(q,'issued'),'leftover',private.farm_num(q,'leftover'),'waste',0,'note',left(coalesce(q->>'note',''),1000));
issued:=(q->>'issued')::numeric;leftover:=(q->>'leftover')::numeric;
if leftover>issued or issued>1000000 or length(trim(coalesce(p->>'submitter','')))not between 1 and 100 then raise exception 'INVALID_SUBMISSION';end if;
if old.id is not null then if old.link_id<>l.id or old.kind<>k or old.payload is distinct from q or old.submitter<>trim(p->>'submitter')then raise exception 'REQUEST_CONFLICT';end if;return jsonb_build_object('id',old.id,'status',old.status);end if;
if d<(select start_date from public.batches where id=l.batch_id)then raise exception 'INVALID_DATE';end if;
if(select count(*)from public.worker_submissions where link_id=l.id and status='pending')>=100 then raise exception 'PENDING_LIMIT';end if;
insert into public.worker_submissions(link_id,batch_id,request_id,kind,log_date,submitter,payload)values(l.id,l.batch_id,p_request,k,d,trim(p->>'submitter'),q)returning id into sid;return jsonb_build_object('id',sid,'status','pending');end$$;
revoke all on function public.worker_submit(text,jsonb,uuid)from public;grant execute on function public.worker_submit(text,jsonb,uuid)to anon,authenticated;
-- Outbox is server-only. The GAS bridge polls it without exposing bot credentials.
create table private.line_outbox(id uuid primary key default gen_random_uuid(),request_id uuid not null unique,link_id uuid not null references public.access_links on delete cascade,bot_key text not null,line_to_id text not null,message text not null,created_at timestamptz not null default now(),sent_at timestamptz,attempts int not null default 0,last_error text,lease_until timestamptz);
revoke all on private.line_outbox from public,anon,authenticated;
create or replace function public.worker_bundle(p_token text,p_data jsonb,p_request uuid)returns jsonb language plpgsql security definer set search_path='' as $$declare l public.access_links;old private.worker_bundles;r jsonb:='[]';q jsonb;h text:=md5(p_data::text);item jsonb;msg text;begin
perform private.feed_lock();l:=private.access_valid(p_token);select * into old from private.worker_bundles where request_id=p_request;
if found then if old.link_id<>l.id or old.payload_hash<>h then raise exception 'REQUEST_CONFLICT';end if;return old.result;end if;
if jsonb_typeof(p_data->'entries')is distinct from 'array'or jsonb_array_length(p_data->'entries')not between 1 and 3 or(select count(distinct value->>'kind')from jsonb_array_elements(p_data->'entries'))<>jsonb_array_length(p_data->'entries')then raise exception 'INVALID_ENTRIES';end if;
msg:='DUCKY · '||(select name from public.batches where id=l.batch_id)||E'\nผู้บันทึก: '||left(p_data->>'submitter',100)||E'\nรอผู้ดูแลตรวจ';
for q in select value from jsonb_array_elements(p_data->'entries')loop
item:=public.worker_submit(p_token,q||jsonb_build_object('submitter',p_data->>'submitter'),gen_random_uuid());r:=r||jsonb_build_array(item);
update public.worker_submissions set status='rejected',version=version+1,reviewed_at=now(),result='{"superseded":true}'where link_id=l.id and kind=q->>'kind'and status='pending'and id<>(item->>'id')::uuid and log_date=(select log_date from public.worker_submissions where id=(item->>'id')::uuid);
msg:=msg||E'\n'||case q->>'kind'when 'egg'then 'ไข่วันนี้: '||coalesce(q#>>'{payload,total}','0')when 'feed'then 'อาหารเมื่อวาน: เท '||coalesce(q#>>'{payload,issued}','0')||' เหลือ '||coalesce(q#>>'{payload,leftover}','0')else 'ส่งขาย: '||left(q#>>'{payload,raw_message}',2000)end;
end loop;
insert into private.worker_bundles values(p_request,l.id,h,r);
if l.bot_key is not null and l.line_to_id is not null then insert into private.line_outbox(request_id,link_id,bot_key,line_to_id,message)values(p_request,l.id,l.bot_key,l.line_to_id,left(msg,4900));end if;return r;end$$;
-- Reviewing unassigned food supports multiple sources atomically.
alter function public.worker_review(jsonb,uuid)rename to worker_review_v101;revoke all on function public.worker_review_v101(jsonb,uuid)from public,anon,authenticated;
create function public.worker_review(p_data jsonb,p_request uuid)returns jsonb language plpgsql security definer set search_path='' as $$declare r public.worker_submissions;ret jsonb;items jsonb;begin
perform private.feed_lock();select * into strict r from public.worker_submissions where id=(p_data->>'id')::uuid for update;
if r.kind<>'feed'then return public.worker_review_v101(p_data,p_request);end if;
if not private.can_batch(r.batch_id,'farm',true)or not private.feature_allowed('farm.inventory',true)then raise exception 'NO_ACCESS';end if;
ret:=private.request_result(p_request,'worker-feed-v11',p_data);if ret is not null then return ret;end if;
if r.status<>'pending'or r.version is distinct from(p_data->>'version')::int then raise exception 'VERSION_CONFLICT';end if;
items:=coalesce(p_data->'items',r.payload->'items',case when r.payload?'allocation_id'then jsonb_build_array(r.payload)end);
if p_data->>'action'='edit'then
if jsonb_typeof(items)is distinct from 'array'or jsonb_array_length(items)not between 1 and 20 then raise exception 'SELECT_FEED_SOURCE';end if;
select jsonb_agg(jsonb_build_object('allocation_id',q->>'allocation_id','issued',private.farm_num(q,'issued'),'leftover',private.farm_num(q,'leftover'),'waste',private.farm_num(q,'waste')))into items from jsonb_array_elements(items)q;
if exists(select 1 from jsonb_array_elements(items)q where (q->>'leftover')::numeric+(q->>'waste')::numeric>(q->>'issued')::numeric)then raise exception 'INVALID_FEED';end if;
if exists(select 1 from jsonb_array_elements(items)q where not exists(select 1 from public.feed_allocations where id=(q->>'allocation_id')::uuid and batch_id=r.batch_id))then raise exception 'INVALID_FEED_SOURCE';end if;
update public.worker_submissions set payload=payload||jsonb_build_object('items',items),version=version+1 where id=r.id;
elsif p_data->>'action'='approve'then
if items is null then raise exception 'SELECT_FEED_SOURCE';end if;
-- Exclude this reviewed reservation, retain other pending reservations.
update public.worker_submissions set status='approved'where id=r.id;
ret:=private.farm_apply(jsonb_build_object('action','feed_multi','batch_id',r.batch_id,'log_date',r.log_date,'save_mode','post','items',items));
update public.worker_submissions set version=version+1,reviewed_by=auth.uid(),reviewed_at=now(),result=ret where id=r.id;
elsif p_data->>'action'='reject'then update public.worker_submissions set status='rejected',version=version+1,reviewed_by=auth.uid(),reviewed_at=now()where id=r.id;
else raise exception 'UNKNOWN_ACTION';end if;
return private.finish_request(p_request,'worker-feed-v11',p_data,jsonb_build_object('id',r.id,'result',ret));end$$;
revoke all on function public.worker_review(jsonb,uuid)from public,anon;grant execute on function public.worker_review(jsonb,uuid)to authenticated;
create function public.line_outbox_claim()returns jsonb language plpgsql security definer set search_path='' as $$declare r jsonb;begin
with picked as(select id from private.line_outbox where sent_at is null and attempts<20 and(lease_until is null or lease_until<now())and created_at>now()-interval '23 hours'order by created_at limit 20 for update skip locked),updated as(update private.line_outbox o set lease_until=now()+interval '5 minutes',attempts=attempts+1 from picked where o.id=picked.id returning o.*)select coalesce(jsonb_agg(to_jsonb(updated)),'[]')into r from updated;return r;end$$;
create function public.line_outbox_finish(p_id uuid,p_sent boolean,p_error text default '')returns void language sql security definer set search_path='' as $$update private.line_outbox set sent_at=case when p_sent then now()else null end,last_error=left(p_error,500),lease_until=case when p_sent then null else now()+interval '5 minutes'end where id=p_id and sent_at is null$$;
revoke all on function public.line_outbox_claim(),public.line_outbox_finish(uuid,boolean,text)from public,anon,authenticated;grant execute on function public.line_outbox_claim(),public.line_outbox_finish(uuid,boolean,text)to service_role;
create or replace function public.settings_status()returns jsonb language plpgsql security definer set search_path='' as $$begin if not exists(select 1 from public.profiles where id=auth.uid()and approved)then raise exception 'NO_ACCESS';end if;return jsonb_build_object('server_time',now(),'database_version','019 / 0.11.0','approved',true,'admin',private.is_admin());end$$;
-- Keep the displayed master date aligned if an order date is corrected.
create function private.sync_order_source_date()returns trigger language plpgsql security definer set search_path='' as $$begin update public.feed_allocations set source_order_date=new.order_date where order_id=new.id;return new;end$$;
create trigger sync_source_date after update of order_date on public.feed_orders for each row execute function private.sync_order_source_date();
revoke all on function private.sync_order_source_date()from public,anon,authenticated;
-- Reviewed worker food lines reserve the selected sources, including split lots.
do $$declare d text;begin
select pg_get_functiondef('private.farm_apply(jsonb)'::regprocedure)into d;
d:=replace(d,'select reserved+coalesce(sum((payload->>''issued'')::numeric-coalesce((payload->>''leftover'')::numeric,0)),0)into reserved from public.worker_submissions where batch_id=b and status=''pending''and kind=''feed''and payload->>''allocation_id''=a.id::text;',
'select reserved+coalesce(sum((line->>''issued'')::numeric-coalesce((line->>''leftover'')::numeric,0)),0)into reserved from public.worker_submissions ws cross join lateral jsonb_array_elements(coalesce(ws.payload->''items'',jsonb_build_array(ws.payload)))line where ws.batch_id=b and ws.status=''pending''and ws.kind=''feed''and line->>''allocation_id''=a.id::text;');execute d;end$$;
commit;notify pgrst,'reload schema';
