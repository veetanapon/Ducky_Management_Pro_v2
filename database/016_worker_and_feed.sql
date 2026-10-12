begin;
alter table public.access_links alter column expires_at drop not null;
-- Worker links may be perpetual, but close with the batch. Display links keep their limited lifetime.
do $$declare d text;begin
select pg_get_functiondef('public.access_manage_v080(jsonb,uuid)'::regprocedure)into d;
d:=replace(d,'expires:=coalesce(nullif(p->>''expires_at'','''')::timestamptz,now()+interval ''4 hours'');','expires:=case when p->>''kind''=''liff''and coalesce((p->>''no_expiry'')::boolean,false)then null else coalesce(nullif(p->>''expires_at'','''')::timestamptz,now()+interval ''4 hours'')end;');
d:=replace(d,'if expires<=now()or expires>now()+interval ''30 days''then','if expires<=now()or(p->>''kind''<>''liff''and expires>now()+interval ''30 days'')then');execute d;
select pg_get_functiondef('private.access_valid(text)'::regprocedure)into d;d:=replace(d,'and expires_at>now()','and(expires_at is null or expires_at>now())');d:=replace(d,'if not found or not private.report_owner_valid(l.created_by,l.batch_id)then', 'if not found or not private.report_owner_valid(l.created_by,l.batch_id)or(l.kind=''liff''and exists(select 1 from public.batches where id=l.batch_id and status=''closed''))then');execute d;
end$$;
-- Private resolver used only after token validation. Never returns prices to workers.
do $$declare d text;begin
select pg_get_functiondef('public.price_resolve(uuid,date)'::regprocedure)into d;
d:=replace(d,'public.price_resolve','private.worker_prices');
d:=replace(d,'if not(private.has_module(''prices'')or private.can_batch(p_batch,''farm'')or private.can_batch(p_batch,''finance''))then raise exception ''NO_ACCESS'';end if;','');execute d;
end$$;
revoke all on function private.worker_prices(uuid,date)from public,anon,authenticated;
create function private.parse_worker_sale(raw text,b uuid,d date)returns jsonb language plpgsql security definer set search_path='' as $$declare prices jsonb;items jsonb:='[]';ln text;matched text[];size text;qty numeric;mult int;it jsonb;begin
if length(coalesce(raw,''))not between 1 and 8000 then raise exception 'INVALID_MESSAGE';end if;prices:=private.worker_prices(b,d);
for ln in select regexp_split_to_table(raw,E'\n+')loop
ln:=regexp_replace(trim(ln),'\s+','','g');if ln=''then continue;end if;
mult:=case when ln like '%ตั้ง%'then 300 when ln like '%แผง%'then 30 when ln like '%ฟอง%'or ln like '%ใบ%'then 1 else 0 end;
matched:=regexp_match(ln,'^(.+)=([0-9]+(?:\.[0-9]+)?)(ตั้ง|แผง|ฟอง|ใบ)$');
if matched is null or mult=0 then raise exception 'UNPARSED_LINE: %',ln;end if;size:=regexp_replace(matched[1],'^(เศษ|ศ\.)','');qty:=matched[2]::numeric*mult;it:=null;
if size like '%บุบ%'or size like '%บาง%'then select value into it from jsonb_array_elements(prices->'items')where value->>'grade'=case when size like '%บุบ%'then 'บุบ'else 'บาง'end or value->>'grade'=case when size like '%บุบ%'then 'ไข่บุบ'else 'ไข่บาง'end limit 1;
elsif size~'^[0-9]+(\.[0-9]+)?$'then select value into it from jsonb_array_elements(prices->'items')where value->>'grade'~'^[0-9]+(\.[0-9]+)?$'and case when value->>'grade'~'^[0-9]+(\.[0-9]+)?$'then(value->>'grade')::numeric<=size::numeric else false end order by(value->>'grade')::numeric desc limit 1;
else select value into it from jsonb_array_elements(prices->'items')where value->>'grade'=size limit 1;end if;
if it is null or qty<=0 or qty<>trunc(qty)then raise exception 'UNPARSED_LINE: %',ln;end if;
items:=items||jsonb_build_array(jsonb_build_object('price_item_id',it->>'id','display_name',it->>'display_name','grade',it->>'grade','pieces',qty,'unit_price',(it->>'price')::numeric,'discount',0));end loop;
if jsonb_array_length(items)=0 then raise exception 'INVALID_MESSAGE';end if;
return jsonb_build_object('sale_type','egg','buyer',coalesce((select default_buyer from public.batches where id=b),'ยังไม่ระบุผู้ซื้อ'),'items',items,'note','ข้อความคนงาน: '||raw);
end$$;
revoke all on function private.parse_worker_sale(text,uuid,date)from public,anon,authenticated;
alter table public.worker_submissions add column raw_message text;
alter function public.worker_submit(text,jsonb,uuid)rename to worker_submit_v080;revoke all on function public.worker_submit_v080(text,jsonb,uuid)from public,anon,authenticated;
create function public.worker_submit(p_token text,p_data jsonb,p_request uuid)returns jsonb language plpgsql security definer set search_path='' as $$declare l public.access_links;q jsonb:=p_data;r jsonb;old public.worker_submissions;begin
perform private.feed_lock();l:=private.access_valid(p_token);
if p_data->>'kind'='sale'then
 if nullif(trim(p_data#>>'{payload,raw_message}'),'')is null then raise exception 'WORKER_PRICE_INPUT_FORBIDDEN';end if;
 select * into old from public.worker_submissions where request_id=p_request;
 if found then if old.link_id<>l.id or old.raw_message is distinct from p_data#>>'{payload,raw_message}'or old.log_date<>(p_data->>'log_date')::date or old.submitter<>trim(p_data->>'submitter')then raise exception 'REQUEST_CONFLICT';end if;return jsonb_build_object('id',old.id,'status',old.status);end if;
 q:=jsonb_set(q,'{payload}',private.parse_worker_sale(p_data#>>'{payload,raw_message}',l.batch_id,(p_data->>'log_date')::date));
end if;
r:=public.worker_submit_v080(p_token,q,p_request);
if p_data->>'kind'='sale'then update public.worker_submissions set payload=q->'payload',raw_message=p_data#>>'{payload,raw_message}'where id=(r->>'id')::uuid;end if;return r;
end$$;
revoke all on function public.worker_submit(text,jsonb,uuid)from public;grant execute on function public.worker_submit(text,jsonb,uuid)to anon,authenticated;
create table private.worker_bundles(request_id uuid primary key,link_id uuid not null references public.access_links on delete cascade,payload_hash text not null,result jsonb not null);
create function public.worker_bundle(p_token text,p_data jsonb,p_request uuid)returns jsonb language plpgsql security definer set search_path='' as $$declare l public.access_links;old private.worker_bundles;r jsonb:='[]';q jsonb;h text:=md5(p_data::text);begin
perform private.feed_lock();l:=private.access_valid(p_token);select * into old from private.worker_bundles where request_id=p_request;
if found then if old.link_id<>l.id or old.payload_hash<>h then raise exception 'REQUEST_CONFLICT';end if;return old.result;end if;
if jsonb_typeof(p_data->'entries')is distinct from 'array'or jsonb_array_length(p_data->'entries')not between 1 and 20 then raise exception 'INVALID_ENTRIES';end if;
for q in select value from jsonb_array_elements(p_data->'entries')loop r:=r||jsonb_build_array(public.worker_submit(p_token,q||jsonb_build_object('log_date',p_data->>'log_date','submitter',p_data->>'submitter'),gen_random_uuid()));end loop;
insert into private.worker_bundles values(p_request,l.id,h,r);return r;end$$;
revoke all on function public.worker_bundle(text,jsonb,uuid)from public;grant execute on function public.worker_bundle(text,jsonb,uuid)to anon,authenticated;
-- Multiple food sources in one atomic daily submission.
alter function private.farm_apply(jsonb)rename to farm_apply_v100_permissions;
create function private.farm_apply(p jsonb)returns jsonb language plpgsql security definer set search_path='' as $$declare q jsonb;res jsonb:='[]';a public.feed_allocations;available numeric;reserved numeric;b uuid:=(p->>'batch_id')::uuid;begin
if p->>'action'<>'feed_multi'then return private.farm_apply_v100_permissions(p);end if;
if not private.can_batch(b,'farm',true)or not private.feature_allowed('farm.inventory',true)then raise exception 'NO_ACCESS';end if;
if jsonb_typeof(p->'items')is distinct from 'array'or jsonb_array_length(p->'items')not between 1 and 20 then raise exception 'INVALID_ITEMS';end if;
if(select count(distinct value->>'allocation_id')from jsonb_array_elements(p->'items'))<>jsonb_array_length(p->'items')then raise exception 'DUPLICATE_FEED_LOT';end if;
for q in select value from jsonb_array_elements(p->'items')loop
select * into strict a from public.feed_allocations where id=(q->>'allocation_id')::uuid and batch_id=b;
select coalesce(sum((payload->>'issued')::numeric-coalesce((payload->>'leftover')::numeric,0)),0)into reserved from public.farm_pending where batch_id=b and status='pending'and kind='prefeed'and payload->>'allocation_id'=a.id::text;
select reserved+coalesce(sum((payload->>'issued')::numeric-coalesce((payload->>'leftover')::numeric,0)),0)into reserved from public.worker_submissions where batch_id=b and status='pending'and kind='feed'and payload->>'allocation_id'=a.id::text;
select a.quantity-coalesce((select sum(issued-leftover)from public.feed_consumption where allocation_id=a.id),0)-coalesce((select sum(quantity)from public.farm_feed_returns where allocation_id=a.id),0)-reserved into available;
if private.farm_num(q,'issued')-private.farm_num(q,'leftover')>available then raise exception 'INSUFFICIENT_UNRESERVED_FEED';end if;
q:=q||jsonb_build_object('action','feed','batch_id',b,'log_date',p->>'log_date');
if p->>'save_mode'='draft'then q:=jsonb_build_object('action','pending_save','kind','prefeed','batch_id',b,'log_date',p->>'log_date','payload',q);end if;
res:=res||jsonb_build_array(private.farm_apply_v100_permissions(q));end loop;return res;end$$;
revoke all on function private.farm_apply(jsonb),private.farm_apply_v100_permissions(jsonb)from public,anon,authenticated;
commit;notify pgrst,'reload schema';
