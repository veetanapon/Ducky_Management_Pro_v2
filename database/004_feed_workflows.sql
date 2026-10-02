-- Ducky 0.2.0: additive migration on the NEW project, AFTER 001 and 003.
-- One transaction. Preserves existing orders, payments, allocations and cash.
begin;
do $$ begin
 if to_regclass('public.feed_orders') is null then raise exception 'RUN_001_FIRST'; end if;
 if to_regclass('public.feed_requests') is not null then raise exception '004_ALREADY_INSTALLED'; end if;
 if exists(select 1 from public.feed_claims) then raise exception 'EXISTING_CLAIMS_NEED_MAPPING: preserve and map old credit records first'; end if;
end $$;
alter table public.feed_orders add column supplier_name text not null default '', add column unit_price numeric(16,4) not null default 0 check(unit_price>=0), add column is_visible boolean not null default true;
update public.feed_orders set unit_price=round(total/quantity,4);
alter table public.feed_allocations alter column batch_id drop not null;
alter table public.feed_allocations add column destination_type text not null default 'batch' check(destination_type in ('batch','external')),
 add column external_name text, add column source_claim_id uuid references public.feed_claims,
 add column feed_name text, add column unit text, add column unit_price numeric(16,4), add column note text,
 add constraint allocation_destination check((destination_type='batch' and batch_id is not null and external_name is null) or (destination_type='external' and batch_id is null and length(trim(external_name))>0));
update public.feed_allocations a set feed_name=o.feed_name,unit=o.unit,unit_price=round(a.assigned_cost/a.quantity,4) from public.feed_orders o where o.id=a.order_id;
alter table public.feed_claims add column source_claim_id uuid references public.feed_claims,
 add column return_qty numeric(16,3) not null default 0 check(return_qty>=0),
 add column return_unit_price numeric(16,4) not null default 0 check(return_unit_price>=0),
 add column return_value numeric(16,2) not null default 0,
 add column replacement_qty numeric(16,3) not null default 0 check(replacement_qty>=0),
 add column replacement_feed_name text not null default '',
 add column replacement_unit_price numeric(16,4) not null default 0 check(replacement_unit_price>=0),
 add column replacement_value numeric(16,2) not null default 0,
 add column reason text not null default '', add column created_by uuid references public.profiles;
alter table public.feed_payments alter column allocation_id drop not null;
alter table public.feed_payments add column payment_group_id uuid, add column payment_method text not null default '', add column note text;
alter table public.batches add column version integer not null default 1;
create table public.feed_requests(request_id uuid primary key, actor uuid not null references public.profiles, action text not null, payload jsonb not null, result jsonb not null, created_at timestamptz not null default now());
alter table public.feed_requests enable row level security;
revoke all on public.feed_requests from public,anon,authenticated;
grant all on public.feed_requests to service_role;
create index on public.feed_payments(order_id);
create index on public.feed_allocations(order_id,source_claim_id);
create index on public.feed_claims(order_id,source_claim_id);
create trigger audit after insert or update or delete on public.feed_claims for each row execute function private.audit_change();

-- All financial/stock writers use one transaction lock in this small installation.
-- It serializes all feed/cash writes, including retries, to avoid overspending/overselling.
create function private.feed_lock() returns void language sql as $$ select pg_advisory_xact_lock(824621903) $$;
create function private.request_result(p_id uuid,p_action text,p_payload jsonb) returns jsonb language plpgsql security definer set search_path='' as $$
declare r public.feed_requests;
begin
 if p_id is null then raise exception 'REQUEST_ID_REQUIRED'; end if;
 select * into r from public.feed_requests where request_id=p_id;
 if found then
  if r.actor<>auth.uid() or r.action<>p_action or r.payload<>p_payload then raise exception 'IDEMPOTENCY_CONFLICT'; end if;
  return r.result;
 end if;
 return null;
end $$;
create function private.finish_request(p_id uuid,p_action text,p_payload jsonb,p_result jsonb) returns jsonb language plpgsql security definer set search_path='' as $$
begin insert into public.feed_requests(request_id,actor,action,payload,result)values(p_id,auth.uid(),p_action,p_payload,p_result);return p_result;end $$;
create function private.feed_totals(p_order uuid) returns jsonb language sql stable security definer set search_path='' as $$
 with v as(select o.*,
 coalesce((select sum(case kind when 'credit' then -amount when 'extra_charge' then amount else 0 end)from public.feed_claims where order_id=o.id),0) adjustment,
 coalesce((select sum(amount)from public.feed_payments where order_id=o.id),0) paid,
 coalesce((select sum(replacement_qty-return_qty)from public.feed_claims where order_id=o.id),0) qty_adjustment,
 coalesce((select sum(quantity)from public.feed_allocations where order_id=o.id),0) allocated
 from public.feed_orders o where id=p_order)
 select jsonb_build_object('net_total',total+adjustment,'paid_total',paid,'outstanding',greatest(0,total+adjustment-paid),'supplier_credit',greatest(0,paid-total-adjustment),'net_quantity',quantity+qty_adjustment,'allocated_quantity',allocated,'available_quantity',quantity+qty_adjustment-allocated) from v
$$;
create function private.feed_source(p_order uuid,p_source uuid) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare o public.feed_orders;c public.feed_claims;q numeric;n text;price numeric;d date;
begin
 select * into o from public.feed_orders where id=p_order;if not found then raise exception 'ORDER_NOT_FOUND';end if;
 if p_source is null then q=o.quantity;n=o.feed_name;price=o.unit_price;d=o.order_date;
 else select * into c from public.feed_claims where id=p_source and order_id=p_order;
 if not found or c.replacement_qty<=0 then raise exception 'SOURCE_NOT_FOUND';end if;
 q=c.replacement_qty;n=c.replacement_feed_name;price=c.replacement_unit_price;d=c.claim_date;end if;
 q=q-coalesce((select sum(quantity)from public.feed_allocations where order_id=p_order and source_claim_id is not distinct from p_source),0)-coalesce((select sum(return_qty)from public.feed_claims where order_id=p_order and source_claim_id is not distinct from p_source),0);
 return jsonb_build_object('source_claim_id',p_source,'feed_name',n,'unit',o.unit,'unit_price',price,'available',q,'available_from',d);
end $$;
-- Lowest dated balance from a date onward, used for backdated expenditure too.
create function private.cash_available(p_batch uuid,p_date date) returns numeric language sql stable security definer set search_path='' as $$
 with days as(select cash_date,sum(amount) amount from public.batch_cash where batch_id=p_batch group by cash_date),
 running as(select cash_date,sum(amount)over(order by cash_date) balance from days),
 candidates as(select coalesce(sum(amount),0) balance from public.batch_cash where batch_id=p_batch and cash_date<=p_date union all select balance from running where cash_date>p_date)
 select least(coalesce(min(balance),0),coalesce((select sum(amount)from public.batch_cash where batch_id=p_batch and cash_date<=p_date),0))from candidates
$$;
create or replace function public.get_feed_calendar(p_offset integer default 0,p_limit integer default 500)
returns setof jsonb language plpgsql stable security definer set search_path='' as $$
begin
 if not private.has_module('feed') then return;end if;
 if p_offset<0 or p_limit<1 or p_limit>500 then raise exception 'INVALID_PAGING';end if;
 return query select to_jsonb(o)||private.feed_totals(o.id) from public.feed_orders o order by order_date,id limit p_limit offset p_offset;
end $$;
create function public.feed_detail(p_order uuid) returns jsonb language plpgsql stable security definer set search_path='' as $$
begin
 if not private.has_module('feed') then raise exception 'NO_ACCESS';end if;
 return jsonb_build_object(
 'sources',(select coalesce(jsonb_agg(s),'[]')from(select private.feed_source(p_order,null) s union all select private.feed_source(p_order,id)from public.feed_claims where order_id=p_order and replacement_qty>0)x),
 'claims',(select coalesce(jsonb_agg(to_jsonb(c)order by claim_date,id),'[]')from public.feed_claims c where order_id=p_order),
 'allocations',(select coalesce(jsonb_agg(to_jsonb(a)||jsonb_build_object('batch_name',b.name)order by allocation_date,a.id),'[]')from public.feed_allocations a left join public.batches b on b.id=a.batch_id where order_id=p_order),
 'payments',(select coalesce(jsonb_agg(jsonb_build_object('id',p.id,'payment_date',p.payment_date,'amount',p.amount,'payment_method',p.payment_method,'note',p.note,'batch_id',p.batch_id,'batch_name',b.name,'payment_group_id',p.payment_group_id)order by payment_date,p.id),'[]')from public.feed_payments p join public.batches b on b.id=p.batch_id where order_id=p_order));
end $$;
create function public.feed_save_order(p_data jsonb,p_request uuid) returns jsonb language plpgsql security definer set search_path='' as $$
declare r public.feed_orders;old public.feed_orders;ret jsonb;oid uuid:=(p_data->>'id')::uuid;linked boolean;
begin
 if not private.has_module('feed',true) then raise exception 'NO_ACCESS';end if;
 perform private.feed_lock();ret:=private.request_result(p_request,'order',p_data);if ret is not null then return ret;end if;
 select * into old from public.feed_orders where id=oid;
 if found then
 if old.version is distinct from (p_data->>'version')::int then raise exception 'VERSION_CONFLICT';end if;
 linked:=exists(select 1 from public.feed_claims where order_id=oid)or exists(select 1 from public.feed_allocations where order_id=oid)or exists(select 1 from public.feed_payments where order_id=oid);
 if linked and (old.feed_name is distinct from p_data->>'feed_name' or old.order_date is distinct from (p_data->>'order_date')::date or old.quantity is distinct from (p_data->>'quantity')::numeric or old.unit is distinct from p_data->>'unit' or old.unit_price is distinct from (p_data->>'unit_price')::numeric or old.kg_per_unit is distinct from nullif(p_data->>'kg_per_unit','')::numeric or old.total is distinct from (p_data->>'total')::numeric)then raise exception 'LINKED_ORDER_LOCKED';end if;
 else if coalesce((p_data->>'version')::int,0)<>0 then raise exception 'VERSION_CONFLICT';end if;end if;
 if oid is null or length(trim(coalesce(p_data->>'feed_name','')))=0 or length(trim(coalesce(p_data->>'unit','')))=0 or (p_data->>'total')::numeric<>round((p_data->>'total')::numeric,2) then raise exception 'INVALID_ORDER';end if;
 insert into public.feed_orders(id,feed_name,order_date,credit_days,quantity,unit,unit_price,kg_per_unit,total,supplier_name,note,manufacturer_lot,formula)
 values(oid,trim(p_data->>'feed_name'),(p_data->>'order_date')::date,(p_data->>'credit_days')::int,(p_data->>'quantity')::numeric,p_data->>'unit',(p_data->>'unit_price')::numeric,nullif(p_data->>'kg_per_unit','')::numeric,(p_data->>'total')::numeric,coalesce(p_data->>'supplier_name',''),p_data->>'note',p_data->>'manufacturer_lot',p_data->>'formula')
 on conflict(id)do update set feed_name=excluded.feed_name,order_date=excluded.order_date,credit_days=excluded.credit_days,quantity=excluded.quantity,unit=excluded.unit,unit_price=excluded.unit_price,kg_per_unit=excluded.kg_per_unit,total=excluded.total,supplier_name=excluded.supplier_name,note=excluded.note,manufacturer_lot=excluded.manufacturer_lot,formula=excluded.formula,version=public.feed_orders.version+1 returning * into r;
 return private.finish_request(p_request,'order',p_data,to_jsonb(r));
end $$;
create function public.feed_set_visibility(p_order uuid,p_visible boolean,p_version int)returns void language plpgsql security definer set search_path='' as $$
begin
 if not private.has_module('feed',true)then raise exception 'NO_ACCESS';end if;perform private.feed_lock();
 update public.feed_orders set is_visible=p_visible,version=version+1 where id=p_order and version=p_version;if not found then raise exception 'VERSION_CONFLICT';end if;
end $$;
create function public.feed_allocate(p_data jsonb,p_request uuid) returns jsonb language plpgsql security definer set search_path='' as $$
declare o uuid:=(p_data->>'order_id')::uuid;s uuid:=nullif(p_data->>'source_claim_id','')::uuid;b uuid:=nullif(p_data->>'batch_id','')::uuid;q numeric:=(p_data->>'quantity')::numeric;d date:=(p_data->>'allocation_date')::date;src jsonb;r public.feed_allocations;ret jsonb;price numeric;
begin
 if not private.has_module('feed',true)then raise exception 'NO_ACCESS';end if;
 if p_data->>'destination_type'='batch' and not private.can_batch(b,'farm',true)then raise exception 'NO_BATCH_ACCESS';end if;
 perform private.feed_lock();ret:=private.request_result(p_request,'allocation',p_data);if ret is not null then return ret;end if;
 if p_data->>'destination_type' is null or p_data->>'destination_type' not in('batch','external') or (p_data->>'destination_type'='external' and length(trim(coalesce(p_data->>'external_name','')))=0) then raise exception 'DESTINATION_REQUIRED';end if;
 src:=private.feed_source(o,s);price:=(p_data->>'unit_price')::numeric;
 if q is null or q<=0 or q<>round(q,3) or q>(src->>'available')::numeric then raise exception 'INSUFFICIENT_CENTRAL_STOCK';end if;
 if d is null or d<(src->>'available_from')::date or d>(now()at time zone 'Asia/Bangkok')::date then raise exception 'INVALID_DATE';end if;
 if price is null or price<0 or price<>round(price,4)then raise exception 'INVALID_PRICE';end if;
 insert into public.feed_allocations(order_id,batch_id,quantity,assigned_cost,allocation_date,destination_type,external_name,source_claim_id,feed_name,unit,unit_price,note)
 values(o,b,q,round(q*price,2),d,p_data->>'destination_type',nullif(trim(p_data->>'external_name'),''),s,src->>'feed_name',src->>'unit',price,p_data->>'note') returning * into r;
 return private.finish_request(p_request,'allocation',p_data,to_jsonb(r));
end $$;
create function public.feed_claim(p_data jsonb,p_request uuid)returns jsonb language plpgsql security definer set search_path='' as $$
declare o uuid:=(p_data->>'order_id')::uuid;s uuid:=nullif(p_data->>'source_claim_id','')::uuid;q numeric:=(p_data->>'return_qty')::numeric;rq numeric:=(p_data->>'replacement_qty')::numeric;rp numeric:=(p_data->>'replacement_unit_price')::numeric;d date:=(p_data->>'claim_date')::date;src jsonb;rv numeric;nv numeric;delta numeric;r public.feed_claims;ret jsonb;
begin
 if not private.has_module('feed',true)then raise exception 'NO_ACCESS';end if;perform private.feed_lock();ret:=private.request_result(p_request,'claim',p_data);if ret is not null then return ret;end if;
 src:=private.feed_source(o,s);
 if q is null or rq is null or rp is null or q<0 or rq<0 or rp<0 or q+rq<=0 or q<>round(q,3) or rq<>round(rq,3) or rp<>round(rp,4)then raise exception 'INVALID_CLAIM';end if;
 if q>(src->>'available')::numeric then raise exception 'INSUFFICIENT_CENTRAL_STOCK';end if;
 if d is null or d<(src->>'available_from')::date or d>(now()at time zone 'Asia/Bangkok')::date then raise exception 'INVALID_DATE';end if;
 if length(trim(coalesce(p_data->>'reason','')))=0 or(rq>0 and length(trim(coalesce(p_data->>'replacement_feed_name','')))=0)then raise exception 'CLAIM_DETAILS_REQUIRED';end if;
 rv:=round(q*(src->>'unit_price')::numeric,2);nv:=round(rq*rp,2);delta:=nv-rv;
 if (private.feed_totals(o)->>'net_total')::numeric+delta<0 then raise exception 'CLAIM_EXCEEDS_INVOICE_VALUE';end if;
 insert into public.feed_claims(order_id,claim_date,kind,amount,quantity,note,source_claim_id,return_qty,return_unit_price,return_value,replacement_qty,replacement_feed_name,replacement_unit_price,replacement_value,reason,created_by)
 values(o,d,case when delta<0 then 'credit' when delta>0 then 'extra_charge' else 'replacement'end,abs(delta),q,p_data->>'note',s,q,(src->>'unit_price')::numeric,rv,rq,coalesce(p_data->>'replacement_feed_name',''),rp,nv,p_data->>'reason',auth.uid())returning * into r;
 return private.finish_request(p_request,'claim',p_data,to_jsonb(r));
end $$;
create function public.feed_payment_preview(p_data jsonb) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare b uuid:=(p_data->>'batch_id')::uuid;oid uuid:=nullif(p_data->>'order_id','')::uuid;amt numeric:=(p_data->>'amount')::numeric;d date:=(p_data->>'payment_date')::date;leftover numeric;applied numeric:=0;due numeric;part numeric;o public.feed_orders;rows jsonb:='[]';bal numeric;plan jsonb;
begin
 if not private.has_module('feed',true)or not private.can_batch(b,'finance',true)then raise exception 'NO_ACCESS';end if;
 if amt is null or amt<=0 or amt<>round(amt,2)then raise exception 'INVALID_PAYMENT';end if;
 if d is null or d>(now()at time zone 'Asia/Bangkok')::date then raise exception 'INVALID_DATE';end if;
 if not exists(select 1 from public.batches where id=b)then raise exception 'BATCH_NOT_FOUND';end if;
 if oid is not null and not exists(select 1 from public.feed_orders where id=oid)then raise exception 'ORDER_NOT_FOUND';end if;
 leftover:=amt;bal:=private.cash_available(b,d);
 for o in select * from public.feed_orders where (oid is not null and id=oid)or(oid is null and is_visible)order by order_date,created_at,id loop
 exit when leftover<=0;
 if o.order_date>d then continue;end if;
 due:=(private.feed_totals(o.id)->>'outstanding')::numeric;if due<=0 then continue;end if;
 if exists(select 1 from public.feed_claims where order_id=o.id and claim_date>d)or exists(select 1 from public.feed_payments where order_id=o.id and payment_date>d)then raise exception 'PAYMENT_DATE_BEFORE_ACTIVITY';end if;
 part:=least(leftover,due);rows:=rows||jsonb_build_array(jsonb_build_object('order_id',o.id,'order_date',o.order_date,'feed_name',o.feed_name,'before',due,'amount',part,'after',due-part,'version',o.version));
 leftover:=leftover-part;applied:=applied+part;
 end loop;
 if applied<=0 then raise exception 'NO_PAYABLE_ORDERS';end if;
 plan:=jsonb_build_object('rows',rows,'requested',amt,'applied',applied,'unapplied',leftover,'available_cash',bal,'can_pay',bal>=applied,'batch_id',b,'payment_date',d);
 return plan||jsonb_build_object('fingerprint',md5(plan::text));
end $$;
create function public.feed_pay(p_data jsonb,p_expected text,p_request uuid) returns jsonb language plpgsql security definer set search_path='' as $$
declare plan jsonb;ret jsonb;item jsonb;cash uuid;rid uuid;groupid uuid:=gen_random_uuid();payload jsonb:=jsonb_build_object('data',p_data,'expected',p_expected);b uuid:=(p_data->>'batch_id')::uuid;
begin
 if not private.has_module('feed',true)or not private.can_batch(b,'finance',true)then raise exception 'NO_ACCESS';end if;
 perform private.feed_lock();ret:=private.request_result(p_request,'payment',payload);if ret is not null then return ret;end if;
 plan:=public.feed_payment_preview(p_data);
 if p_expected is distinct from plan->>'fingerprint' then raise exception 'PAYMENT_PREVIEW_CHANGED';end if;
 if not(plan->>'can_pay')::boolean then raise exception 'INSUFFICIENT_BATCH_CASH';end if;
 if length(trim(coalesce(p_data->>'payment_method','')))=0 then raise exception 'PAYMENT_METHOD_REQUIRED';end if;
 for item in select value from jsonb_array_elements(plan->'rows')loop
 rid:=gen_random_uuid();
 insert into public.batch_cash(batch_id,cash_date,kind,amount,reference_id,note,request_id,created_by)
 values(b,(p_data->>'payment_date')::date,'feed_payment',-(item->>'amount')::numeric,(item->>'order_id')::uuid,p_data->>'note',rid,auth.uid())returning id into cash;
 insert into public.feed_payments(order_id,batch_id,payment_date,amount,request_id,cash_id,created_by,payment_group_id,payment_method,note)
 values((item->>'order_id')::uuid,b,(p_data->>'payment_date')::date,(item->>'amount')::numeric,rid,cash,auth.uid(),groupid,p_data->>'payment_method',p_data->>'note');
 end loop;
 return private.finish_request(p_request,'payment',payload,plan||jsonb_build_object('payment_group_id',groupid,'saved',true));
end $$;
create function public.cash_record(p_data jsonb,p_request uuid)returns jsonb language plpgsql security definer set search_path='' as $$
declare b uuid:=(p_data->>'batch_id')::uuid;d date:=(p_data->>'cash_date')::date;k text:=p_data->>'kind';a numeric:=(p_data->>'amount')::numeric;r public.batch_cash;ret jsonb;
begin
 if not private.can_batch(b,'finance',true)then raise exception 'NO_ACCESS';end if;
 perform private.feed_lock();ret:=private.request_result(p_request,'cash',p_data);if ret is not null then return ret;end if;
 if k is null or k not in('opening','receipt','expense','withdrawal','savings_transfer')or a is null or a<=0 or a<>round(a,2)then raise exception 'INVALID_CASH';end if;
 if d is null or d>(now()at time zone 'Asia/Bangkok')::date or length(trim(coalesce(p_data->>'note','')))=0 then raise exception 'CASH_DETAILS_REQUIRED';end if;
 if k='opening' and exists(select 1 from public.batch_cash where batch_id=b) then raise exception 'OPENING_MUST_BE_FIRST';end if;
 if k in('expense','withdrawal','savings_transfer')then
 if private.cash_available(b,d)<a then raise exception 'INSUFFICIENT_BATCH_CASH';end if;a:=-a;end if;
 insert into public.batch_cash(batch_id,cash_date,kind,amount,note,request_id,created_by)values(b,d,k,a,p_data->>'note',p_request,auth.uid())returning * into r;
 return private.finish_request(p_request,'cash',p_data,to_jsonb(r));
end $$;
create function public.operating_context()returns jsonb language plpgsql stable security definer set search_path='' as $$
begin
 return jsonb_build_object('is_admin',private.is_admin(),'feed_write',private.has_module('feed',true),
 'farm_write_ids',(select coalesce(jsonb_agg(id),'[]')from public.batches where private.can_batch(id,'farm',true)),
 'funds',(select coalesce(jsonb_agg(jsonb_build_object('id',b.id,'name',b.name,'can_write',private.can_batch(b.id,'finance',true),'balance',coalesce((select sum(amount)from public.batch_cash where batch_id=b.id and cash_date<=(now()at time zone 'Asia/Bangkok')::date),0))order by b.start_date,b.id),'[]')from public.batches b where private.can_batch(b.id,'finance')));
end $$;
create function public.batch_save(p_data jsonb,p_request uuid)returns jsonb language plpgsql security definer set search_path='' as $$
declare r public.batches;ret jsonb;i uuid:=(p_data->>'id')::uuid;
begin
 if not private.is_admin()then raise exception 'NO_ACCESS';end if;perform private.feed_lock();ret:=private.request_result(p_request,'batch',p_data);if ret is not null then return ret;end if;
 select * into r from public.batches where id=i;
 if found then
 if r.version is distinct from (p_data->>'version')::int then raise exception 'VERSION_CONFLICT';end if;
 if r.species_id is distinct from p_data->>'species_id' then raise exception 'SPECIES_LOCKED';end if;
 else if coalesce((p_data->>'version')::int,0)<>0 then raise exception 'VERSION_CONFLICT';end if;end if;
 if length(trim(coalesce(p_data->>'name','')))=0 then raise exception 'NAME_REQUIRED';end if;
 insert into public.batches(id,name,species_id,start_date,initial_qty,birth_date,age_at_start_days,purchase_cost,status,end_date)
 values(i,trim(p_data->>'name'),p_data->>'species_id',(p_data->>'start_date')::date,(p_data->>'initial_qty')::int,nullif(p_data->>'birth_date','')::date,nullif(p_data->>'age_at_start_days','')::int,nullif(p_data->>'purchase_cost','')::numeric,coalesce(p_data->>'status','active'),nullif(p_data->>'end_date','')::date)
 on conflict(id)do update set name=excluded.name,start_date=excluded.start_date,initial_qty=excluded.initial_qty,birth_date=excluded.birth_date,age_at_start_days=excluded.age_at_start_days,purchase_cost=excluded.purchase_cost,status=excluded.status,end_date=excluded.end_date,version=public.batches.version+1 returning * into r;
 return private.finish_request(p_request,'batch',p_data,to_jsonb(r));
end $$;
-- Remove older write entry points so mixed frontend versions cannot bypass the new locks.
revoke execute on function public.save_feed_order(uuid,text,date,integer,numeric,text,numeric,numeric,integer),public.record_feed_payment(uuid,numeric,date,uuid) from public,anon,authenticated;
revoke insert,update on public.batches from authenticated;
revoke all on function private.feed_lock(),private.request_result(uuid,text,jsonb),private.finish_request(uuid,text,jsonb,jsonb),private.feed_totals(uuid),private.feed_source(uuid,uuid),private.cash_available(uuid,date) from public,anon,authenticated;
revoke all on function public.feed_detail(uuid),public.feed_save_order(jsonb,uuid),public.feed_set_visibility(uuid,boolean,int),public.feed_allocate(jsonb,uuid),public.feed_claim(jsonb,uuid),public.feed_payment_preview(jsonb),public.feed_pay(jsonb,text,uuid),public.cash_record(jsonb,uuid),public.operating_context(),public.batch_save(jsonb,uuid) from public,anon;
grant execute on function public.feed_detail(uuid),public.feed_save_order(jsonb,uuid),public.feed_set_visibility(uuid,boolean,int),public.feed_allocate(jsonb,uuid),public.feed_claim(jsonb,uuid),public.feed_payment_preview(jsonb),public.feed_pay(jsonb,text,uuid),public.cash_record(jsonb,uuid),public.operating_context(),public.batch_save(jsonb,uuid) to authenticated;
commit;
