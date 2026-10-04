-- Ducky 0.4: additive migration after 005. Run once, as database owner.
begin;
alter table public.egg_daily add column cracked integer not null default 0 check(cracked>=0), add column big integer not null default 0 check(big>=0), add column small integer not null default 0 check(small>=0), add column remaining integer check(remaining>=0), add column note text;
alter table public.sales add column sale_type text, add column note text, add column cash_id uuid references public.batch_cash, add column voided_at timestamptz;
alter table public.sale_items add column price_item_id uuid references public.price_items on delete set null, add column entry jsonb not null default '{}';
alter table public.animal_movements add column sale_id uuid references public.sales, add column event_id uuid references public.batch_events;
alter table public.batch_events add column version integer not null default 1, add column sale_id uuid references public.sales, add column cash_id uuid references public.batch_cash;
alter table public.feed_consumption add column version integer not null default 1, add column note text;
create table public.farm_egg_openings(id uuid primary key default gen_random_uuid(),batch_id uuid not null references public.batches unique,log_date date not null,qty integer not null check(qty>=0),note text not null);
create table public.farm_feed_returns(id uuid primary key default gen_random_uuid(),batch_id uuid not null references public.batches,allocation_id uuid not null,log_date date not null,quantity numeric(16,3) not null check(quantity>0),note text not null,foreign key(allocation_id,batch_id) references public.feed_allocations(id,batch_id));
create table public.farm_pending(id uuid primary key default gen_random_uuid(),batch_id uuid not null references public.batches,kind text not null check(kind in ('prebill','prefeed')),log_date date not null,payload jsonb not null,status text not null default 'pending' check(status in('pending','approved','cancelled')),version integer not null default 1,result jsonb,created_by uuid references public.profiles,created_at timestamptz not null default now());
create index on public.farm_pending(batch_id,status);
create index on public.farm_feed_returns(allocation_id);
do $$declare t text;begin foreach t in array array['farm_egg_openings','farm_feed_returns','farm_pending']loop
 execute format('alter table public.%I enable row level security',t);
 execute format('revoke all on public.%I from anon,authenticated',t);
 execute format('grant select on public.%I to authenticated',t);
 execute format('grant all on public.%I to service_role',t);
 execute format('create policy read_allowed on public.%I for select to authenticated using(private.can_batch(batch_id,''farm''))',t);
 execute format('create trigger audit after insert or update or delete on public.%I for each row execute function private.audit_change()',t);
 end loop;end$$;
-- Farm returns release stock back to its original central source, without changing receipt history.
create or replace function private.feed_totals(p_order uuid) returns jsonb language sql stable security definer set search_path='' as $$
 with v as(select o.*,
 coalesce((select sum(case kind when 'credit' then -amount when 'extra_charge' then amount else 0 end)from public.feed_claims where order_id=o.id),0) adjustment,
 coalesce((select sum(amount)from public.feed_payments where order_id=o.id),0) paid,
 coalesce((select sum(replacement_qty-return_qty)from public.feed_claims where order_id=o.id),0) qty_adjustment,
 coalesce((select sum(quantity)from public.feed_allocations where order_id=o.id),0)-coalesce((select sum(r.quantity)from public.farm_feed_returns r join public.feed_allocations a on a.id=r.allocation_id where a.order_id=o.id),0) allocated
 from public.feed_orders o where id=p_order)
 select jsonb_build_object('net_total',total+adjustment,'paid_total',paid,'outstanding',greatest(0,total+adjustment-paid),'supplier_credit',greatest(0,paid-total-adjustment),'net_quantity',quantity+qty_adjustment,'allocated_quantity',allocated,'available_quantity',quantity+qty_adjustment-allocated)from v
$$;
-- Keep the existing source validation; add returned quantities and their availability date.
do $$declare def text;begin
 select pg_get_functiondef('private.feed_source(uuid,uuid)'::regprocedure)into def;
 def:=replace(def,'q=q-coalesce', 'q=q+coalesce((select sum(r.quantity) from public.farm_feed_returns r join public.feed_allocations a on a.id=r.allocation_id where a.order_id=p_order and a.source_claim_id is not distinct from p_source),0); d=greatest(d,coalesce((select max(r.log_date) from public.farm_feed_returns r join public.feed_allocations a on a.id=r.allocation_id where a.order_id=p_order and a.source_claim_id is not distinct from p_source),d)); q=q-coalesce');
 execute def;
end$$;
create function private.farm_animal_balance(b uuid,d date)returns bigint language sql stable security definer set search_path='' as $$
 select initial_qty+coalesce((select sum(case when kind in('add','transfer_in')then qty else -qty end)from public.animal_movements where batch_id=b and log_date<=d),0)from public.batches where id=b
$$;
create function private.farm_egg_balance(b uuid,d date)returns bigint language sql stable security definer set search_path='' as $$
 select coalesce((select sum(qty)from public.farm_egg_openings where batch_id=b and log_date<=d),0)+coalesce((select sum(total-broken)from public.egg_daily where batch_id=b and log_date<=d),0)-coalesce((select sum(i.qty)from public.sales s join public.sale_items i on i.sale_id=s.id where s.batch_id=b and s.sale_type='egg' and s.status='posted' and s.sale_date<=d),0)::bigint
$$;
create function private.farm_assert_stock(b uuid)returns void language plpgsql security definer set search_path='' as $$
begin
 if exists(select 1 from public.batches where id=b and status='closed')and exists(select 1 from public.batch_events where batch_id=b and event_type='close_sale')and private.farm_animal_balance(b,'9999-12-31')<>0 then raise exception 'CLOSED_BATCH_HAS_ANIMALS';end if;
 if exists(select 1 from public.animal_movements where batch_id=b and private.farm_animal_balance(b,log_date)<0)then raise exception 'INSUFFICIENT_ANIMALS';end if;
 if exists(select 1 from public.sales where batch_id=b and sale_type='egg' and status='posted' and private.farm_egg_balance(b,sale_date)<0)then raise exception 'INSUFFICIENT_EGGS';end if;
end$$;
create function private.farm_num(p jsonb,k text,fallback numeric default 0)returns numeric language plpgsql immutable set search_path='' as $$
declare n numeric;begin n:=coalesce(nullif(p->>k,'')::numeric,fallback);if n is null or n<0 or n::text in('NaN','Infinity','-Infinity')then raise exception 'INVALID_NUMBER: %',k;end if;return n;end$$;
create function private.farm_apply(p jsonb)returns jsonb language plpgsql security definer set search_path='' as $$
declare act text:=p->>'action';b uuid:=(p->>'batch_id')::uuid;d date:=(p->>'log_date')::date;en date;bt public.batches;eid uuid;sid uuid;cid uuid;mid uuid;ser uuid:=gen_random_uuid();old public.egg_daily;fc public.feed_consumption;al public.feed_allocations;pend public.farm_pending;ev public.batch_events;s public.sales;row jsonb;res jsonb;prices jsonb;q numeric;price numeric;cost numeric:=0;tot numeric:=0;qty numeric:=0;issued numeric;leftover numeric;waste numeric;remaining numeric;typ text;cat text;period int;day date;
begin
 if not private.can_batch(b,'farm',true)then raise exception 'NO_BATCH_ACCESS';end if;
 select * into strict bt from public.batches where id=b;
 if act in('pending_approve','pending_cancel')then
  select * into pend from public.farm_pending where id=(p->>'id')::uuid and batch_id=b for update;
  if not found or pend.status<>'pending' or pend.version<>(p->>'version')::int then raise exception 'VERSION_CONFLICT';end if;
  if act='pending_approve'then res:=private.farm_apply(pend.payload||jsonb_build_object('batch_id',b,'log_date',pend.log_date,'action',case pend.kind when 'prebill'then 'sale' else 'feed' end));end if;
  update public.farm_pending set status=case when act='pending_approve'then 'approved' else 'cancelled'end,version=version+1,result=res where id=pend.id;
  return jsonb_build_object('id',pend.id,'result',res);
 end if;
 if act='sale_void'then
  select * into s from public.sales where id=(p->>'id')::uuid and batch_id=b for update;
  if not found or s.status<>'posted' or s.sale_type is null then raise exception 'SALE_NOT_VOIDABLE';end if;
  if not private.can_batch(b,'finance',true)then raise exception 'NO_FINANCE_ACCESS';end if;
  if exists(select 1 from public.batch_events where sale_id=s.id)then raise exception 'EVENT_SALE_LOCKED';end if;
  if private.cash_available(b,s.sale_date)<s.total then raise exception 'INSUFFICIENT_BATCH_CASH';end if;
  insert into public.batch_cash(batch_id,cash_date,kind,amount,reference_id,note,created_by)values(b,s.sale_date,'expense',-s.total,s.id,'ยกเลิกบิล: '||coalesce(p->>'note',''),auth.uid());
  delete from public.animal_movements where sale_id=s.id;
  update public.sales set status='void',voided_at=now()where id=s.id;perform private.farm_assert_stock(b);
  return jsonb_build_object('id',s.id);
 end if;
 if d is null or d<bt.start_date or d>(now()at time zone 'Asia/Bangkok')::date or (bt.status='closed' and d>bt.end_date)then raise exception 'INVALID_DATE';end if;
 if act='pending_save'then
  typ:=p->>'kind';if typ not in('prebill','prefeed')or jsonb_typeof(p->'payload')<>'object'then raise exception 'INVALID_PENDING';end if;
  eid:=coalesce(nullif(p->>'id','')::uuid,gen_random_uuid());
  select * into pend from public.farm_pending where id=eid;
  if found then
   if pend.batch_id<>b or pend.status<>'pending' or pend.version<>coalesce((p->>'version')::int,0)then raise exception 'VERSION_CONFLICT';end if;
   update public.farm_pending set payload=p->'payload',kind=typ,log_date=d,version=version+1 where id=eid;
  else insert into public.farm_pending(id,batch_id,kind,log_date,payload,created_by)values(eid,b,typ,d,p->'payload',auth.uid());end if;
  if coalesce((p->>'approve')::boolean,false)then select * into pend from public.farm_pending where id=eid;res:=private.farm_apply(jsonb_build_object('action','pending_approve','batch_id',b,'id',eid,'version',pend.version));return res;end if;
  return jsonb_build_object('id',eid);
 elsif act='egg'then
  if bt.species_id<>'duck'then raise exception 'DUCK_ONLY';end if;
  select * into old from public.egg_daily where batch_id=b and log_date=d;
  if coalesce(old.version,0)<>coalesce((p->>'version')::int,0)then raise exception 'VERSION_CONFLICT';end if;
  tot:=private.farm_num(p,'total');cost:=private.farm_num(p,'broken');
  if tot<>trunc(tot) or cost<>trunc(cost) or cost+private.farm_num(p,'cracked')+private.farm_num(p,'big')+private.farm_num(p,'small')>tot then raise exception 'INVALID_EGG_CATEGORIES';end if;
  foreach cat in array array['cracked','big','small','live_count','remaining']loop if private.farm_num(p,cat)<>trunc(private.farm_num(p,cat))then raise exception 'INTEGER_REQUIRED';end if;end loop;
  insert into public.egg_daily(batch_id,log_date,total,broken,cracked,big,small,remaining,live_count,note)values(b,d,tot,cost,private.farm_num(p,'cracked'),private.farm_num(p,'big'),private.farm_num(p,'small'),nullif(p->>'remaining','')::int,nullif(p->>'live_count','')::int,p->>'note')on conflict(batch_id,log_date)do update set total=excluded.total,broken=excluded.broken,cracked=excluded.cracked,big=excluded.big,small=excluded.small,remaining=excluded.remaining,live_count=excluded.live_count,note=excluded.note,version=public.egg_daily.version+1,updated_at=now()returning id into eid;
  perform private.farm_assert_stock(b);return jsonb_build_object('id',eid);
 elsif act='egg_opening'then
  if bt.species_id<>'duck'then raise exception 'DUCK_ONLY';end if;
  if exists(select 1 from public.sales where batch_id=b and sale_type='egg')or exists(select 1 from public.egg_daily where batch_id=b and log_date<d)then raise exception 'OPENING_MUST_BE_FIRST';end if;
  q:=private.farm_num(p,'qty');if q<>trunc(q)or coalesce(trim(p->>'note'),'')=''then raise exception 'INVALID_OPENING';end if;
  insert into public.farm_egg_openings(batch_id,log_date,qty,note)values(b,d,q,p->>'note')returning id into eid;return jsonb_build_object('id',eid);
 elsif act in('feed','feed_return')then
  select * into al from public.feed_allocations where id=(p->>'allocation_id')::uuid and batch_id=b for update;
  if not found or d<al.allocation_date then raise exception 'INVALID_FEED_SOURCE';end if;
  if act='feed'then
   eid:=coalesce(nullif(p->>'id','')::uuid,gen_random_uuid());select * into fc from public.feed_consumption where id=eid;
   if found and (fc.batch_id<>b or fc.allocation_id<>al.id or fc.version<>coalesce((p->>'version')::int,0))then raise exception 'VERSION_CONFLICT';end if;
   issued:=private.farm_num(p,'issued');leftover:=private.farm_num(p,'leftover');waste:=private.farm_num(p,'waste');
   if issued<leftover+waste then raise exception 'INVALID_CONSUMPTION';end if;
   -- Stock loses consumed + discarded; reusable leftover returns to the same receipt.
   cost:=round((issued-leftover)*al.assigned_cost/al.quantity,2);
   insert into public.feed_consumption(id,batch_id,allocation_id,log_date,issued,leftover,waste,cost,unit,kg_per_unit,note)values(eid,b,al.id,d,issued,leftover,waste,cost,al.unit,(select kg_per_unit from public.feed_orders where id=al.order_id),p->>'note')on conflict(id)do update set log_date=excluded.log_date,issued=excluded.issued,leftover=excluded.leftover,waste=excluded.waste,cost=excluded.cost,note=excluded.note,version=public.feed_consumption.version+1;
  else
   if not private.has_module('feed',true)then raise exception 'NO_CENTRAL_ACCESS';end if;
   q:=private.farm_num(p,'quantity');if q<=0 or coalesce(trim(p->>'note'),'')=''then raise exception 'INVALID_RETURN';end if;
   -- Avoid making returned stock available before an already posted central transaction.
   if d<coalesce((select max(allocation_date)from public.feed_allocations where order_id=al.order_id),d)or d<coalesce((select max(claim_date)from public.feed_claims where order_id=al.order_id),d)then raise exception 'RETURN_DATE_BEFORE_ACTIVITY';end if;
   insert into public.farm_feed_returns(batch_id,allocation_id,log_date,quantity,note)values(b,al.id,d,q,p->>'note')returning id into eid;
  end if;
  select al.quantity-coalesce((select sum(cn.issued-cn.leftover)from public.feed_consumption cn where cn.allocation_id=al.id),0)-coalesce((select sum(quantity)from public.farm_feed_returns where allocation_id=al.id),0)into remaining;
  if remaining<0 then raise exception 'INSUFFICIENT_FEED';end if;
  return jsonb_build_object('id',eid,'remaining',remaining);
 elsif act='sale'then
  if not private.can_batch(b,'finance',true)then raise exception 'NO_FINANCE_ACCESS';end if;
  typ:=p->>'sale_type';if typ is null or typ not in('egg','duck','fish')or (bt.species_id='fish' and typ<>'fish')or(bt.species_id='duck' and typ='fish')then raise exception 'INVALID_SPECIES_SALE';end if;
  if p->'items' is null or jsonb_typeof(p->'items')<>'array' or jsonb_array_length(p->'items')not between 1 and 100 then raise exception 'INVALID_SALE_ITEMS';end if;
  sid:=gen_random_uuid();insert into public.sales(id,batch_id,sale_date,buyer,total,sale_type,note)values(sid,b,d,p->>'buyer',0,typ,p->>'note');
  if typ='egg'then prices:=public.price_resolve(b,d);end if;
  for row in select value from jsonb_array_elements(p->'items')loop
   if typ='egg'then
    foreach cat in array array['stacks','trays','pieces']loop if private.farm_num(row,cat)<>trunc(private.farm_num(row,cat))then raise exception 'INTEGER_REQUIRED';end if;end loop; q:=private.farm_num(row,'stacks')*300+private.farm_num(row,'trays')*30+private.farm_num(row,'pieces');if q<>trunc(q)then raise exception 'INTEGER_REQUIRED';end if;
    mid:=nullif(row->>'price_item_id','')::uuid;
    if mid is not null then select value into res from jsonb_array_elements(prices->'items')where value->>'id'=mid::text;if not found then raise exception 'PRICE_CHANGED';end if;price:=(res->>'price')::numeric;if price<>private.farm_num(row,'unit_price')then raise exception 'PRICE_CHANGED';end if;cat:=res->>'grade';
    else price:=private.farm_num(row,'unit_price');cat:=row->>'grade';if coalesce(trim(row->>'price_reason'),'')=''then raise exception 'PRICE_REASON_REQUIRED';end if;end if;
   else q:=private.farm_num(row,'qty');price:=private.farm_num(row,'unit_price');cat:=case typ when 'duck'then 'เป็ด'else 'ปลา'end;mid:=null;if typ='duck'and q<>trunc(q)then raise exception 'INTEGER_REQUIRED';end if;end if;
   cost:=round(q*price-private.farm_num(row,'discount'),2);if q<=0 or cost<0 or coalesce(trim(cat),'')=''then raise exception 'INVALID_SALE_ITEM';end if;
   insert into public.sale_items(sale_id,grade,qty,unit,unit_price,discount,total,price_item_id,entry)values(sid,cat,q,case typ when 'egg'then 'ฟอง'when 'fish'then 'กก.'else 'ตัว'end,price,private.farm_num(row,'discount'),cost,mid,row);
   tot:=tot+cost;qty:=qty+q;
  end loop;
  if typ='duck'then insert into public.animal_movements(batch_id,log_date,kind,qty,amount,sale_id)values(b,d,'sale',qty,tot,sid);
  elsif typ='fish'then q:=private.farm_num(p,'animal_count');if q<=0 or q<>trunc(q)then raise exception 'FISH_COUNT_REQUIRED';end if;insert into public.animal_movements(batch_id,log_date,kind,qty,amount,sale_id)values(b,d,'sale',q,tot,sid);end if;
  insert into public.batch_cash(batch_id,cash_date,kind,amount,reference_id,note,created_by)values(b,d,'receipt',tot,sid,'ขาย '||typ||' • '||coalesce(p->>'buyer',''),auth.uid())returning id into cid;
  update public.sales set total=tot,cash_id=cid where id=sid;perform private.farm_assert_stock(b);return jsonb_build_object('id',sid,'total',tot);
 elsif act='event'then
  typ:=p->>'event_type';if typ not in('injection','medicine','vitamin','rain','feed_swap','other','duck_cull','close_sale','death','add','heat','move')then raise exception 'INVALID_EVENT_TYPE';end if;
  en:=coalesce(nullif(p->>'end_date','')::date,d);period:=en-d+1;
  if (bt.status='closed' and en>bt.end_date)or period not between 1 and 31 or en>(now()at time zone 'Asia/Bangkok')::date or coalesce(trim(p->>'title'),'')=''then raise exception 'INVALID_EVENT_RANGE';end if;
  if typ in('duck_cull','close_sale','death','add')and period<>1 then raise exception 'SINGLE_DAY_EVENT';end if;
  foreach cat in array array['medicine','vitamin','vaccine','labor','other']loop cost:=cost+private.farm_num(coalesce(p->'costs','{}'),cat);end loop;
  if coalesce(p->>'cost_mode','total')='daily'then cost:=cost*period;end if;
  if cost>0 and not private.can_batch(b,'finance',true)then raise exception 'NO_FINANCE_ACCESS';end if;
  if typ in('duck_cull','close_sale')then
   if bt.species_id<>'duck'then raise exception 'DUCK_ONLY';end if;
   if bt.status='closed'then raise exception 'BATCH_CLOSED';end if;
   if typ='close_sale'and exists(select 1 from public.animal_movements where batch_id=b and log_date>d)then raise exception 'FUTURE_MOVEMENTS_EXIST';end if;
   q:=private.farm_num(p,'qty');if typ='close_sale'and q<>private.farm_animal_balance(b,d)then raise exception 'CLOSE_REQUIRES_ALL_ANIMALS';end if;
   res:=private.farm_apply(jsonb_build_object('action','sale','batch_id',b,'log_date',d,'sale_type','duck','buyer',p->>'buyer','note',p->>'title','items',jsonb_build_array(jsonb_build_object('qty',q,'unit_price',private.farm_num(p,'unit_price')))));sid:=(res->>'id')::uuid;
  end if;
  if cost>0 then
   if private.cash_available(b,d)<cost then raise exception 'INSUFFICIENT_BATCH_CASH';end if;
   insert into public.batch_cash(batch_id,cash_date,kind,amount,reference_id,note,created_by)values(b,d,'expense',-cost,ser,p->>'title',auth.uid())returning id into cid;
  end if;
  for day in select generate_series(d,en,'1 day')::date loop
   insert into public.batch_events(batch_id,start_date,end_date,event_type,title,severity,details,factors,sale_id,cash_id)values(b,day,day,typ,p->>'title',p->>'severity',p->>'details',coalesce(p->'factors','{}')||jsonb_build_object('series_id',ser,'series_start',d,'series_end',en,'cost_mode',coalesce(p->>'cost_mode','total')),sid,cid)returning id into eid;
   foreach cat in array array['medicine','vitamin','vaccine','labor','other']loop
    price:=private.farm_num(coalesce(p->'costs','{}'),cat);
    if coalesce(p->>'cost_mode','total')<>'daily'then price:=case when day=en then price-trunc(price/period,2)*(period-1)else trunc(price/period,2)end;end if;
    if price>0 then insert into public.event_expenses(batch_id,event_id,amount,category)values(b,eid,price,cat);end if;
   end loop;
  end loop;
  if typ in('death','add')then q:=private.farm_num(p,'qty');if q<=0 or q<>trunc(q)then raise exception 'INTEGER_REQUIRED';end if;insert into public.animal_movements(batch_id,log_date,kind,qty,event_id,note)values(b,d,typ,q,eid,p->>'title');end if;
  if typ='close_sale'then update public.batches set status='closed',end_date=d,version=version+1 where id=b;end if;
  perform private.farm_assert_stock(b);return jsonb_build_object('id',eid,'series_id',ser,'sale_id',sid);
 else raise exception 'UNKNOWN_FARM_ACTION';end if;
end$$;
create function public.farm_manage(p_data jsonb,p_request uuid)returns jsonb language plpgsql security definer set search_path='' as $$
declare ret jsonb;begin
 if auth.uid()is null then raise exception 'NO_ACCESS';end if;
 perform private.feed_lock();ret:=private.request_result(p_request,'farm',p_data);if ret is not null then return ret;end if;
 ret:=private.farm_apply(p_data);return private.finish_request(p_request,'farm',p_data,ret);
end$$;
revoke insert,update on public.batch_events from authenticated;
revoke execute on function public.save_egg(uuid,date,integer,integer,integer,integer)from authenticated;
revoke all on function private.farm_animal_balance(uuid,date),private.farm_egg_balance(uuid,date),private.farm_assert_stock(uuid),private.farm_num(jsonb,text,numeric),private.farm_apply(jsonb),public.farm_manage(jsonb,uuid)from public,anon,authenticated;
grant execute on function public.farm_manage(jsonb,uuid)to authenticated;
create trigger audit after insert or update or delete on public.sales for each row execute function private.audit_change();
create trigger audit after insert or update or delete on public.sale_items for each row execute function private.audit_change();
create trigger audit after insert or update or delete on public.animal_movements for each row execute function private.audit_change();
create trigger audit after insert or update or delete on public.feed_consumption for each row execute function private.audit_change();
create function private.farm_batch_guard()returns trigger language plpgsql security definer set search_path='' as $$
begin
 if (new.initial_qty<>old.initial_qty or new.start_date<>old.start_date)and(exists(select 1 from public.animal_movements where batch_id=old.id)or exists(select 1 from public.egg_daily where batch_id=old.id)or exists(select 1 from public.feed_consumption where batch_id=old.id))then raise exception 'BATCH_BASE_LOCKED';end if;
 if new.status='closed' and exists(select 1 from public.batch_events where batch_id=old.id and event_type='close_sale')and private.farm_animal_balance(old.id,'9999-12-31')<>0 then raise exception 'CLOSED_BATCH_HAS_ANIMALS';end if;
 return new;
end$$;
revoke all on function private.farm_batch_guard()from public,anon,authenticated;
create trigger farm_batch_guard before update on public.batches for each row execute function private.farm_batch_guard();
commit;
