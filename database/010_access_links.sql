-- Ducky 0.8.0: timed display and LINE/LIFF worker links. Run after 009.
begin;
create table public.access_links(id uuid primary key default gen_random_uuid(),batch_id uuid not null references public.batches,created_by uuid not null references public.profiles,name text not null check(length(name)between 1 and 100),kind text not null check(kind in('display','liff')),token_hash bytea not null unique,expires_at timestamptz not null,revoked boolean not null default false,created_at timestamptz not null default now(),first_day date,last_day date,rolling_days int check(rolling_days between 1 and 731),liff_id text,actions text[] not null default array['egg','feed','sale']::text[],check(actions<@array['egg','feed','sale']::text[]));
create table public.worker_submissions(id uuid primary key default gen_random_uuid(),link_id uuid not null references public.access_links,batch_id uuid not null references public.batches,request_id uuid not null unique,kind text not null check(kind in('egg','feed','sale')),log_date date not null,submitter text not null check(length(submitter)between 1 and 100),payload jsonb not null,status text not null default 'pending' check(status in('pending','approved','rejected')),version int not null default 1,created_at timestamptz not null default now(),reviewed_by uuid references public.profiles,reviewed_at timestamptz,result jsonb);
create index on public.worker_submissions(batch_id,status);
create index on public.access_links(batch_id);
alter table public.access_links enable row level security;alter table public.worker_submissions enable row level security;
revoke all on public.access_links,public.worker_submissions from public,anon,authenticated;
grant all on public.access_links,public.worker_submissions to service_role;
grant select on public.worker_submissions to authenticated;
create policy worker_inbox_read on public.worker_submissions for select to authenticated using(private.can_batch(batch_id,'farm'));
-- A farm-only user sees stock in their barns, not suppliers, central stock or invoice totals.
create function public.batch_supply_notices()returns jsonb language sql stable security definer set search_path='' as $$
 select coalesce(jsonb_agg(to_jsonb(x)),'[]')from(
 select a.batch_id,i.id,i.name,i.category,i.unit,i.low_stock,0 as central,
 sum(case when l.expiry_date is null or l.expiry_date>=(now()at time zone 'Asia/Bangkok')::date then a.quantity-a.returned-coalesce((select sum(quantity)from public.supply_usage where allocation_id=a.id),0)else 0 end)as available,
 sum(case when l.expiry_date<(now()at time zone 'Asia/Bangkok')::date then a.quantity-a.returned-coalesce((select sum(quantity)from public.supply_usage where allocation_id=a.id),0)else 0 end)as expired
 from public.supply_allocations a join public.supply_lots l on l.id=a.lot_id join public.supply_invoices iv on iv.id=l.invoice_id join public.supply_items i on i.id=l.item_id
 where private.can_batch(a.batch_id,'farm')and iv.status='posted'and i.active group by a.batch_id,i.id
 )x;
$$;
revoke all on function public.batch_supply_notices()from public,anon,authenticated;
grant execute on function public.batch_supply_notices()to authenticated;
create function private.access_valid(p_token text)returns public.access_links language plpgsql security definer set search_path='' as $$declare l public.access_links;begin
 if length(p_token)is distinct from 64 then raise exception 'LINK_EXPIRED';end if;
 select * into l from public.access_links where token_hash=sha256(convert_to(p_token,'UTF8'))and not revoked and expires_at>now();
 if not found or not private.report_owner_valid(l.created_by,l.batch_id)then raise exception 'LINK_EXPIRED';end if;return l;
end$$;
create function public.access_manage(p_data jsonb,p_request uuid)returns jsonb language plpgsql security definer set search_path='' as $$
declare p jsonb:=p_data;b uuid:=(p->>'batch_id')::uuid;r jsonb;t text;sid uuid;expires timestamptz;actions text[];begin
 if not private.can_batch(b,'farm',true)or not private.can_batch(b,'finance')then raise exception 'NO_ACCESS';end if;
 perform private.feed_lock();r:=private.request_result(p_request,'access',p);if r is not null then return r;end if;
 if p->>'action'='create'then
 expires:=coalesce(nullif(p->>'expires_at','')::timestamptz,now()+interval '4 hours');
 if expires<=now()or expires>now()+interval '30 days'then raise exception 'INVALID_EXPIRY';end if;
 if p->>'kind'='display'then perform private.report_snapshot(b,(p->>'from')::date,(p->>'to')::date);end if;
 if nullif(p->>'liff_id','')is not null and (p->>'liff_id')!~'^[0-9]+-[A-Za-z0-9]+$'then raise exception 'INVALID_LIFF_ID';end if;
 actions:=array(select jsonb_array_elements_text(coalesce(p->'actions','["egg","feed","sale"]')));
 t:=replace(gen_random_uuid()::text||gen_random_uuid()::text,'-','');
 insert into public.access_links(batch_id,created_by,name,kind,token_hash,expires_at,first_day,last_day,rolling_days,liff_id,actions)values(b,auth.uid(),trim(p->>'name'),p->>'kind',sha256(convert_to(t,'UTF8')),expires,(p->>'from')::date,(p->>'to')::date,nullif(p->>'rolling_days','')::int,nullif(p->>'liff_id',''),actions)returning id into sid;
 r:=jsonb_build_object('id',sid,'token',t,'expires_at',expires);
 elsif p->>'action'='revoke'then update public.access_links set revoked=true where id=(p->>'id')::uuid and batch_id=b returning id into sid;if not found then raise exception 'NOT_FOUND';end if;r:=jsonb_build_object('id',sid);
 else raise exception 'UNKNOWN_ACTION';end if;
 return private.finish_request(p_request,'access',p,r);
end$$;
create function public.access_list(p_batch uuid)returns jsonb language plpgsql security definer set search_path='' as $$begin
 if not private.can_batch(p_batch,'farm',true)or not private.can_batch(p_batch,'finance')then raise exception 'NO_ACCESS';end if;
 return jsonb_build_object('links',coalesce((select jsonb_agg(to_jsonb(l)-'token_hash'order by created_at desc)from public.access_links l where batch_id=p_batch),'[]'),'submissions',coalesce((select jsonb_agg(to_jsonb(s)order by log_date,created_at)from public.worker_submissions s where batch_id=p_batch and status='pending'),'[]'));
end$$;
create function public.access_read(p_token text,p_date date default null)returns jsonb language plpgsql security definer set search_path='' as $$
declare l public.access_links;bt public.batches;d date:=coalesce(p_date,(now()at time zone 'Asia/Bangkok')::date);last_day date;begin
 l:=private.access_valid(p_token);select * into strict bt from public.batches where id=l.batch_id;
 if l.kind='display'then
 last_day:=case when l.rolling_days is not null then least(coalesce(bt.end_date,'9999-12-31'),(now()at time zone 'Asia/Bangkok')::date)else l.last_day end;
 return jsonb_build_object('kind',l.kind,'name',l.name,'expires_at',l.expires_at,'snapshot',private.report_snapshot(l.batch_id,case when l.rolling_days is null then l.first_day else greatest(bt.start_date,last_day-l.rolling_days+1)end,last_day));end if;
 return jsonb_build_object('kind',l.kind,'name',l.name,'expires_at',l.expires_at,'actions',l.actions,'batch',jsonb_build_object('name',bt.name,'species_id',bt.species_id,'start_date',bt.start_date,'end_date',bt.end_date,'status',bt.status),'egg',coalesce((select jsonb_build_object('total',e.total,'big',e.big,'small',e.small,'cracked',e.cracked,'broken',e.broken,'live_count',e.live_count,'remaining',e.remaining,'version',e.version)from public.egg_daily e where batch_id=bt.id and log_date=d),'{}'),'allocations',coalesce((select jsonb_agg(jsonb_build_object('id',a.id,'feed_name',a.feed_name,'unit',a.unit,'allocation_date',a.allocation_date,'stock',a.quantity-coalesce((select sum(issued-leftover)from public.feed_consumption where allocation_id=a.id),0)-coalesce((select sum(quantity)from public.farm_feed_returns where allocation_id=a.id),0)))from public.feed_allocations a where batch_id=bt.id),'[]'));
end$$;
create function public.worker_submit(p_token text,p_data jsonb,p_request uuid)returns jsonb language plpgsql security definer set search_path='' as $$
declare l public.access_links;bt public.batches;r public.worker_submissions;k text:=p_data->>'kind';d date:=(p_data->>'log_date')::date;q jsonb:=p_data->'payload';sid uuid;begin
 perform private.feed_lock();l:=private.access_valid(p_token);
 if l.kind<>'liff'or k is null or not k=any(l.actions)or p_request is null then raise exception 'NO_ACCESS';end if;
 -- Only fields displayed to the reviewer are accepted. Links cannot edit an existing feed row or inject a different action/batch.
 if jsonb_typeof(q)is distinct from 'object'or octet_length(q::text)>12000 then raise exception 'INVALID_SUBMISSION';end if;
 select coalesce(jsonb_object_agg(key,value),'{}')into q from jsonb_each(q)where key=any(case k when 'egg'then array['total','big','small','cracked','broken','remaining','live_count','version']when 'feed'then array['allocation_id','issued','leftover','waste']else array['sale_type','buyer','animal_count','items']end);
 if k='sale'then
 if jsonb_typeof(q->'items')is distinct from 'array'or jsonb_array_length(q->'items')not between 1 and 50 then raise exception 'INVALID_SALE_ITEMS';end if;
 q:=jsonb_set(q,'{items}',(select jsonb_agg((select jsonb_object_agg(key,value)from jsonb_each(item)where key=any(array['display_name','grade','qty','pieces','unit_price','price_reason'])))from jsonb_array_elements(q->'items')item));
 end if;
 select * into r from public.worker_submissions where request_id=p_request;
 if found then if r.link_id<>l.id or r.payload is distinct from q or r.log_date is distinct from d or r.kind<>k or r.submitter is distinct from trim(p_data->>'submitter')then raise exception 'REQUEST_CONFLICT';end if;return jsonb_build_object('id',r.id,'status',r.status);end if;
 select * into strict bt from public.batches where id=l.batch_id;
 if bt.status='closed'or d is null or d<bt.start_date or d>(now()at time zone 'Asia/Bangkok')::date then raise exception 'INVALID_DATE';end if;
 if jsonb_typeof(q)is distinct from 'object'or octet_length(q::text)>12000 or length(trim(coalesce(p_data->>'submitter','')))not between 1 and 100 then raise exception 'INVALID_SUBMISSION';end if;
 if(select count(*)from public.worker_submissions where link_id=l.id and status='pending')>=100 then raise exception 'PENDING_LIMIT';end if;
 if k='egg'and bt.species_id<>'duck'then raise exception 'DUCK_ONLY';end if;
 if k='feed'and not exists(select 1 from public.feed_allocations where id=(q->>'allocation_id')::uuid and batch_id=bt.id)then raise exception 'INVALID_FEED_SOURCE';end if;
 insert into public.worker_submissions(link_id,batch_id,request_id,kind,log_date,submitter,payload)values(l.id,bt.id,p_request,k,d,trim(p_data->>'submitter'),q)returning id into sid;
 return jsonb_build_object('id',sid,'status','pending');
end$$;
create function public.worker_review(p_data jsonb,p_request uuid)returns jsonb language plpgsql security definer set search_path='' as $$
declare p jsonb:=p_data;r public.worker_submissions;ret jsonb;review_result jsonb;begin
 perform private.feed_lock();select * into strict r from public.worker_submissions where id=(p->>'id')::uuid for update;
 if not private.can_batch(r.batch_id,'farm',true)then raise exception 'NO_ACCESS';end if;
 ret:=private.request_result(p_request,'worker-review',p);if ret is not null then return ret;end if;
 if r.status<>'pending'or r.version is distinct from (p->>'version')::int then raise exception 'VERSION_CONFLICT';end if;
 if p->>'action'='approve'then
 review_result:=private.farm_apply(r.payload||jsonb_build_object('batch_id',r.batch_id,'log_date',r.log_date,'action',r.kind));
 elsif p->>'action'<>'reject'or p->>'action'is null then raise exception 'UNKNOWN_ACTION';end if;
 update public.worker_submissions set status=case when p->>'action'='approve'then 'approved'else 'rejected'end,version=version+1,reviewed_by=auth.uid(),reviewed_at=now(),result=review_result where id=r.id;
 return private.finish_request(p_request,'worker-review',p,jsonb_build_object('id',r.id,'result',review_result));
end$$;
revoke all on function private.access_valid(text),public.access_manage(jsonb,uuid),public.access_list(uuid),public.access_read(text,date),public.worker_submit(text,jsonb,uuid),public.worker_review(jsonb,uuid)from public,anon,authenticated;
grant execute on function public.access_manage(jsonb,uuid),public.access_list(uuid),public.worker_review(jsonb,uuid)to authenticated;
grant execute on function public.access_read(text,date),public.worker_submit(text,jsonb,uuid)to anon,authenticated;
commit;
notify pgrst,'reload schema';
