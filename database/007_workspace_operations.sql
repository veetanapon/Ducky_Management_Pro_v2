-- Ducky 0.5.0: run once AFTER 006, in the V2 project only.
begin;
alter table public.sale_items add column display_name text;
update public.sale_items i set display_name=coalesce(nullif(p.display_name,''),nullif(i.entry->>'display_name',''),i.grade) from public.price_items p where p.id=i.price_item_id;
update public.sale_items set display_name=coalesce(nullif(entry->>'display_name',''),grade) where display_name is null;
create function private.sale_name_snapshot()returns trigger language plpgsql security definer set search_path='' as $$begin
 if new.price_item_id is not null then select coalesce(nullif(display_name,''),grade) into new.display_name from public.price_items where id=new.price_item_id;end if;
 new.display_name:=coalesce(nullif(new.display_name,''),nullif(new.entry->>'display_name',''),new.grade);return new;end$$;
create trigger sale_name_snapshot before insert on public.sale_items for each row execute function private.sale_name_snapshot();
alter function private.farm_apply(jsonb) rename to farm_apply_v040;
create function private.farm_apply(p jsonb)returns jsonb language plpgsql security definer set search_path='' as $$
declare r jsonb;item jsonb;pend public.farm_pending;outcomes jsonb:='[]';b uuid:=(p->>'batch_id')::uuid;op text:=p->>'operation';begin
 if p->>'action'<>'pending_bulk' then return private.farm_apply_v040(p);end if;
 if not private.can_batch(b,'farm',true)then raise exception 'NO_BATCH_ACCESS';end if;
 if op is null or op not in('approve','cancel','review')or p->>'kind' not in('prebill','prefeed')or jsonb_typeof(p->'items')is distinct from 'array' then raise exception 'INVALID_BULK';end if;
 if jsonb_array_length(p->'items')not between 1 and 100 or (select count(distinct value->>'id')from jsonb_array_elements(p->'items'))<>jsonb_array_length(p->'items')then raise exception 'INVALID_BULK';end if;
 -- Validate every selected version and type before applying any changes.
 for item in select value from jsonb_array_elements(p->'items')loop
 select * into pend from public.farm_pending where id=(item->>'id')::uuid and batch_id=b for update;
 if not found or pend.status<>'pending' or pend.version is distinct from (item->>'version')::int or pend.kind is distinct from p->>'kind' then raise exception 'VERSION_CONFLICT';end if;
 end loop;
 for item in select value from jsonb_array_elements(p->'items') j join public.farm_pending f on f.id=(j.value->>'id')::uuid order by f.log_date,f.id loop
 if op='review'then r:=private.farm_apply_v040(item||jsonb_build_object('batch_id',b,'action','pending_save','approve',false,'kind',p->>'kind'));
 else r:=private.farm_apply_v040(item||jsonb_build_object('batch_id',b,'action',case op when 'approve'then 'pending_approve'else 'pending_cancel'end));end if;
 outcomes:=outcomes||jsonb_build_array(r);
 end loop;return jsonb_build_object('results',outcomes);
end$$;
revoke all on function private.farm_apply(jsonb),private.farm_apply_v040(jsonb),private.sale_name_snapshot() from public,anon,authenticated;

-- Medicine/vitamins/premix use the central purchasing permission (feed).
create table public.supply_items(id uuid primary key default gen_random_uuid(),name text not null check(length(trim(name))between 1 and 200),category text not null check(category in('medicine','vitamin','premix','vaccine','other')),unit text not null check(length(trim(unit))between 1 and 40),low_stock numeric(16,3)not null default 0 check(low_stock>=0),active boolean not null default true);
create table public.supply_invoices(id uuid primary key default gen_random_uuid(),supplier text not null check(length(trim(supplier))between 1 and 200),invoice_no text,note text,invoice_date date not null,due_date date not null,total numeric(16,2)not null check(total>=0),credit numeric(16,2)not null default 0 check(credit>=0 and credit<=total),status text not null default 'posted' check(status in('posted','void')),created_by uuid references public.profiles,created_at timestamptz not null default now(),check(due_date>=invoice_date));
create table public.supply_lots(id uuid primary key default gen_random_uuid(),invoice_id uuid not null references public.supply_invoices,item_id uuid not null references public.supply_items,lot_no text,expiry_date date,quantity numeric(16,3)not null check(quantity>0),returned numeric(16,3)not null default 0 check(returned>=0 and returned<=quantity),unit_cost numeric(16,6)not null check(unit_cost>=0),total numeric(16,2)not null check(total>=0));
create table public.supply_allocations(id uuid primary key default gen_random_uuid(),lot_id uuid not null references public.supply_lots,batch_id uuid not null references public.batches,log_date date not null,quantity numeric(16,3)not null check(quantity>0),returned numeric(16,3)not null default 0 check(returned>=0 and returned<=quantity),note text);
create table public.supply_usage(id uuid primary key default gen_random_uuid(),allocation_id uuid not null references public.supply_allocations,batch_id uuid not null references public.batches,event_id uuid not null references public.batch_events,log_date date not null,quantity numeric(16,3)not null check(quantity>0),cost numeric(16,2)not null check(cost>=0),note text);
create table public.supply_payments(id uuid primary key default gen_random_uuid(),invoice_id uuid not null references public.supply_invoices,batch_id uuid not null references public.batches,payment_date date not null,amount numeric(16,2)not null check(amount>0),cash_id uuid not null references public.batch_cash,note text);
create table public.supply_returns(id uuid primary key default gen_random_uuid(),lot_id uuid not null references public.supply_lots,allocation_id uuid references public.supply_allocations,log_date date not null,quantity numeric(16,3)not null check(quantity>0),credit numeric(16,2)not null default 0,note text);
do $$declare t text;begin foreach t in array array['supply_items','supply_invoices','supply_lots','supply_allocations','supply_usage','supply_payments','supply_returns']loop
 execute format('alter table public.%I enable row level security',t);execute format('revoke all on public.%I from anon,authenticated',t);execute format('grant select on public.%I to authenticated',t);execute format('grant all on public.%I to service_role',t);
 execute format('create policy read_allowed on public.%I for select to authenticated using(private.has_module(''feed''))',t);
 execute format('create trigger audit after insert or update or delete on public.%I for each row execute function private.audit_change()',t);end loop;end$$;
create policy batch_read on public.supply_usage for select to authenticated using(private.can_batch(batch_id,'farm'));
create function public.supply_manage(p_data jsonb,p_request uuid)returns jsonb language plpgsql security definer set search_path='' as $$
declare p jsonb:=p_data;act text:=p->>'action';ret jsonb;r jsonb;iv public.supply_invoices;l public.supply_lots;a public.supply_allocations;it public.supply_items;bt public.batches;sid uuid;eid uuid;cid uuid;b uuid:=nullif(p->>'batch_id','')::uuid;d date:=nullif(p->>'log_date','')::date;q numeric;v numeric;invoice_total numeric:=0;available numeric;paid numeric;begin
 if not private.has_module('feed',true)then raise exception 'NO_ACCESS';end if;perform private.feed_lock();ret:=private.request_result(p_request,'supply',p);if ret is not null then return ret;end if;
 if act='item'then
 insert into public.supply_items(name,category,unit,low_stock)values(p->>'name',p->>'category',p->>'unit',private.farm_num(p,'low_stock'))returning id into sid;
 elsif act='item_edit'then
 update public.supply_items set low_stock=private.farm_num(p,'low_stock'),active=coalesce((p->>'active')::boolean,true)where id=(p->>'id')::uuid returning id into sid;if not found then raise exception 'NOT_FOUND';end if;
 else
 if d is null or d>(now()at time zone 'Asia/Bangkok')::date then raise exception 'INVALID_DATE';end if;
 if act='invoice'then
 if jsonb_typeof(p->'items')is distinct from 'array' or jsonb_array_length(p->'items')not between 1 and 100 then raise exception 'INVALID_ITEMS';end if;
 insert into public.supply_invoices(supplier,invoice_no,invoice_date,due_date,total,note,created_by)values(p->>'supplier',p->>'invoice_no',d,(p->>'due_date')::date,0,p->>'note',auth.uid())returning id into sid;
 for r in select value from jsonb_array_elements(p->'items')loop
 select * into strict it from public.supply_items where id=(r->>'item_id')::uuid and active;
 q:=private.farm_num(r,'quantity');v:=private.farm_num(r,'unit_price');if q<=0 or q<>round(q,3)or v<>round(v,6)then raise exception 'INVALID_QUANTITY';end if;
 insert into public.supply_lots(invoice_id,item_id,lot_no,expiry_date,quantity,unit_cost,total)values(sid,it.id,r->>'lot_no',nullif(r->>'expiry_date','')::date,q,v,round(q*v,2));invoice_total:=invoice_total+round(q*v,2);
 end loop;update public.supply_invoices set total=invoice_total where id=sid;
 elsif act in('pay','void')then
 select * into strict iv from public.supply_invoices where id=(p->>'id')::uuid and status='posted' for update;
 if d<iv.invoice_date or d<coalesce((select max(payment_date)from public.supply_payments where invoice_id=iv.id),d)then raise exception 'INVALID_DATE';end if;
 if act='void'then
 if exists(select 1 from public.supply_payments where invoice_id=iv.id)or exists(select 1 from public.supply_lots sl join public.supply_allocations sa on sa.lot_id=sl.id where sl.invoice_id=iv.id)or exists(select 1 from public.supply_returns sr join public.supply_lots sl on sl.id=sr.lot_id where sl.invoice_id=iv.id)or iv.credit>0 then raise exception 'LINKED_ORDER_LOCKED';end if;
 update public.supply_invoices set status='void'where id=iv.id;sid:=iv.id;
 else
 if not private.can_batch(b,'finance',true)then raise exception 'NO_FINANCE_ACCESS';end if;
 select coalesce(sum(amount),0)into paid from public.supply_payments where invoice_id=iv.id;
 v:=private.farm_num(p,'amount');if v<=0 or v<>round(v,2)or v>iv.total-iv.credit-paid then raise exception 'INVALID_PAYMENT';end if;
 if private.cash_available(b,d)<v then raise exception 'INSUFFICIENT_BATCH_CASH';end if;
 insert into public.batch_cash(batch_id,cash_date,kind,amount,reference_id,note,created_by)values(b,d,'expense',-v,iv.id,'จ่ายบิลยา/วิตามิน: '||iv.supplier,auth.uid())returning id into cid;
 insert into public.supply_payments(invoice_id,batch_id,payment_date,amount,cash_id,note)values(iv.id,b,d,v,cid,p->>'note')returning id into sid;
 end if;
 elsif act in('allocate','return_vendor','use','return_batch')then
 if act in('use','return_batch')then select * into strict a from public.supply_allocations where id=(p->>'id')::uuid for update;b:=a.batch_id;select * into strict l from public.supply_lots where id=a.lot_id for update;
 else select * into strict l from public.supply_lots where id=(p->>'id')::uuid for update;end if;
 select * into strict iv from public.supply_invoices where id=l.invoice_id and status='posted';select * into strict it from public.supply_items where id=l.item_id;
 if d<iv.invoice_date or d<coalesce((select max(log_date)from public.supply_allocations where lot_id=l.id),d)or d<coalesce((select max(u.log_date)from public.supply_usage u join public.supply_allocations sa on sa.id=u.allocation_id where sa.lot_id=l.id),d)or d<coalesce((select max(log_date)from public.supply_returns where lot_id=l.id),d)then raise exception 'INVALID_DATE';end if;
 q:=private.farm_num(p,'quantity');if q<=0 or q<>round(q,3)then raise exception 'INVALID_QUANTITY';end if;
 if act in('allocate','return_vendor')then available:=l.quantity-l.returned-coalesce((select sum(quantity-returned)from public.supply_allocations where lot_id=l.id),0);else available:=a.quantity-a.returned-coalesce((select sum(quantity)from public.supply_usage where allocation_id=a.id),0);end if;
 if q>available then raise exception 'INSUFFICIENT_SUPPLY_STOCK';end if;
 if act in('allocate','use','return_batch')then
 if not private.can_batch(b,'farm',true)then raise exception 'NO_BATCH_ACCESS';end if;select * into strict bt from public.batches where id=b;
 if d<bt.start_date or (bt.status='closed'and d>bt.end_date)then raise exception 'INVALID_DATE';end if;
 end if;
 if act in('allocate','use')and l.expiry_date is not null and d>l.expiry_date then raise exception 'SUPPLY_EXPIRED';end if;
 if act='allocate'then
 insert into public.supply_allocations(lot_id,batch_id,log_date,quantity,note)values(l.id,b,d,q,p->>'note')returning id into sid;
 elsif act='use'then
 if not private.can_batch(b,'finance',true)then raise exception 'NO_FINANCE_ACCESS';end if;
 -- Cumulative rounding makes the final unit reconcile to the original cost.
 v:=round((coalesce((select sum(u.quantity)from public.supply_usage u join public.supply_allocations sa on sa.id=u.allocation_id where sa.lot_id=l.id),0)+q)*l.unit_cost,2)-coalesce((select sum(u.cost)from public.supply_usage u join public.supply_allocations sa on sa.id=u.allocation_id where sa.lot_id=l.id),0);
 insert into public.batch_events(batch_id,start_date,end_date,event_type,title,details,factors)values(b,d,d,case it.category when 'vaccine'then 'injection' when 'medicine'then 'medicine'else 'vitamin'end,'ใช้ '||it.name,p->>'note',jsonb_build_object('medicine_name',it.name,'quantity',q,'unit',it.unit,'supply_allocation_id',a.id,'cost_source','inventory'))returning id into eid;
 insert into public.event_expenses(batch_id,event_id,amount,category)values(b,eid,v,it.category);
 insert into public.supply_usage(allocation_id,batch_id,event_id,log_date,quantity,cost,note)values(a.id,b,eid,d,q,v,p->>'note')returning id into sid;
 elsif act='return_batch'then
 update public.supply_allocations set returned=returned+q where id=a.id;
 insert into public.supply_returns(lot_id,allocation_id,log_date,quantity,note)values(l.id,a.id,d,q,p->>'note')returning id into sid;
 else
 v:=private.farm_num(p,'credit');if v>round(q*l.unit_cost,2)or iv.credit+v>iv.total then raise exception 'INVALID_CREDIT';end if;
 update public.supply_lots set returned=returned+q where id=l.id;update public.supply_invoices set credit=credit+v where id=iv.id;
 insert into public.supply_returns(lot_id,log_date,quantity,credit,note)values(l.id,d,q,v,p->>'note')returning id into sid;
 end if;
 else raise exception 'UNKNOWN_SUPPLY_ACTION';end if;end if;
 return private.finish_request(p_request,'supply',p,jsonb_build_object('id',sid));
end$$;
revoke all on function public.supply_manage(jsonb,uuid)from public,anon,authenticated;
grant execute on function public.supply_manage(jsonb,uuid)to authenticated;
-- Public reports expose an explicit immutable snapshot, never base tables.
create table public.report_links(id uuid primary key default gen_random_uuid(),batch_id uuid not null references public.batches,created_by uuid not null references public.profiles,created_at timestamptz not null default now(),expires_at timestamptz not null,session_minutes integer not null check(session_minutes between 5 and 240),revoked boolean not null default false,token_hash bytea not null unique,snapshot jsonb not null);
create table public.report_sessions(id uuid primary key default gen_random_uuid(),link_id uuid not null references public.report_links on delete cascade,token_hash bytea not null unique,expires_at timestamptz not null);
alter table public.report_links enable row level security;alter table public.report_sessions enable row level security;
revoke all on public.report_links,public.report_sessions from public,anon,authenticated;
grant all on public.report_links,public.report_sessions to service_role;
create function private.report_snapshot(b uuid,first_day date,last_day date)returns jsonb language plpgsql security definer set search_path='' as $$
declare bt public.batches;result jsonb;begin
 if first_day is null or last_day is null or last_day<first_day or last_day-first_day>730 then raise exception 'INVALID_REPORT_RANGE';end if;
 select * into strict bt from public.batches where id=b;
 select jsonb_build_object('batch',jsonb_build_object('name',bt.name,'species_id',bt.species_id,'start_date',bt.start_date,'initial_qty',bt.initial_qty),'from',first_day,'to',last_day,'generated_at',now(),
 'eggs',coalesce((select jsonb_agg(jsonb_build_object('date',log_date,'total',total,'broken',broken,'big',big,'small',small,'cracked',cracked,'live_count',live_count,'remaining',remaining)order by log_date)from public.egg_daily where batch_id=b and log_date between first_day and last_day),'[]'),
 'feed',coalesce((select jsonb_agg(jsonb_build_object('date',log_date,'consumed',consumed,'kg_per_unit',kg_per_unit,'cost',cost,'waste',waste,'unit',unit)order by log_date)from public.feed_consumption where batch_id=b and log_date between first_day and last_day),'[]'),
 'sales',coalesce((select jsonb_agg(jsonb_build_object('date',sale_date,'total',total,'type',sale_type)order by sale_date)from public.sales where batch_id=b and status='posted'and sale_date between first_day and last_day),'[]'),
 'events',coalesce((select jsonb_agg(jsonb_build_object('date',e.start_date,'title',e.title,'type',e.event_type,'cost',coalesce((select sum(amount)from public.event_expenses where event_id=e.id),0))order by e.start_date)from public.batch_events e where e.batch_id=b and e.start_date between first_day and last_day),'[]'))into result;
 return result;
end$$;
create function public.report_data(p_batch uuid,p_from date,p_to date)returns jsonb language plpgsql security definer set search_path='' as $$begin
 if not private.can_batch(p_batch,'farm')or not private.can_batch(p_batch,'finance')then raise exception 'NO_ACCESS';end if;return private.report_snapshot(p_batch,p_from,p_to);end$$;
create function public.report_manage(p_data jsonb,p_request uuid)returns jsonb language plpgsql security definer set search_path='' as $$
declare p jsonb:=p_data;b uuid:=(p->>'batch_id')::uuid;ret jsonb;token text;sid uuid;expires timestamptz;hours int;minutes int;begin
 if not private.can_batch(b,'farm',true)or not private.can_batch(b,'finance')then raise exception 'NO_ACCESS';end if;
 perform private.feed_lock();ret:=private.request_result(p_request,'report',p);if ret is not null then return ret;end if;
 if p->>'action'='create'then
 hours:=(p->>'hours')::int;minutes:=(p->>'session_minutes')::int;
 if hours is null or hours not between 1 and 168 or minutes is null or minutes not between 5 and 240 then raise exception 'INVALID_EXPIRY';end if;
 token:=replace(gen_random_uuid()::text||gen_random_uuid()::text,'-','');expires:=now()+hours*interval '1 hour';
 insert into public.report_links(batch_id,created_by,expires_at,session_minutes,token_hash,snapshot)values(b,auth.uid(),expires,minutes,sha256(convert_to(token,'UTF8')),private.report_snapshot(b,(p->>'from')::date,(p->>'to')::date))returning id into sid;
 ret:=jsonb_build_object('id',sid,'token',token,'expires_at',expires);
 elsif p->>'action'='revoke'then
 update public.report_links set revoked=true where id=(p->>'id')::uuid and batch_id=b returning id into sid;if not found then raise exception 'NOT_FOUND';end if;ret:=jsonb_build_object('id',sid);
 else raise exception 'UNKNOWN_REPORT_ACTION';end if;
 return private.finish_request(p_request,'report',p,ret);
end$$;
create function public.report_link_list(p_batch uuid)returns jsonb language plpgsql security definer set search_path='' as $$begin
 if not private.can_batch(p_batch,'farm',true)or not private.can_batch(p_batch,'finance')then raise exception 'NO_ACCESS';end if;
 return coalesce((select jsonb_agg(jsonb_build_object('id',id,'created_at',created_at,'expires_at',expires_at,'revoked',revoked,'session_minutes',session_minutes)order by created_at desc)from public.report_links where batch_id=p_batch),'[]');end$$;
create function private.report_owner_valid(p_owner uuid,p_batch uuid)returns boolean language sql stable security definer set search_path='' as $$
 select exists(select 1 from public.profiles p where p.id=p_owner and p.approved and(p.is_admin or (exists(select 1 from public.module_access where user_id=p_owner and module='farm' and can_write)and exists(select 1 from public.batch_access where user_id=p_owner and batch_id=p_batch and module='farm' and can_write)and exists(select 1 from public.module_access where user_id=p_owner and module='finance')and exists(select 1 from public.batch_access where user_id=p_owner and batch_id=p_batch and module='finance'))));
$$;
create function public.open_report(p_token text)returns jsonb language plpgsql security definer set search_path='' as $$
declare l public.report_links;t text;expires timestamptz;begin
 if length(p_token)<>64 then raise exception 'REPORT_EXPIRED';end if;
 select * into l from public.report_links where token_hash=sha256(convert_to(p_token,'UTF8')) and not revoked and expires_at>now() for update;
 if not found or not private.report_owner_valid(l.created_by,l.batch_id)then raise exception 'REPORT_EXPIRED';end if;
 delete from public.report_sessions where link_id=l.id and expires_at<=now();
 if(select count(*)from public.report_sessions where link_id=l.id)>=500 then raise exception 'REPORT_SESSION_LIMIT';end if;
 t:=replace(gen_random_uuid()::text||gen_random_uuid()::text,'-','');expires:=least(l.expires_at,now()+l.session_minutes*interval '1 minute');
 insert into public.report_sessions(link_id,token_hash,expires_at)values(l.id,sha256(convert_to(t,'UTF8')),expires);
 return jsonb_build_object('session_token',t,'expires_at',expires,'snapshot',l.snapshot);
end$$;
create function public.read_report(p_session text)returns jsonb language plpgsql security definer set search_path='' as $$
declare result jsonb;begin
 select jsonb_build_object('snapshot',l.snapshot,'expires_at',least(l.expires_at,s.expires_at)) into result from public.report_sessions s join public.report_links l on l.id=s.link_id where s.token_hash=sha256(convert_to(p_session,'UTF8'))and s.expires_at>now()and l.expires_at>now()and not l.revoked and private.report_owner_valid(l.created_by,l.batch_id);
 if result is null then raise exception 'REPORT_EXPIRED';end if;return result;
end$$;
revoke all on function private.report_snapshot(uuid,date,date),private.report_owner_valid(uuid,uuid),public.report_data(uuid,date,date),public.report_manage(jsonb,uuid),public.report_link_list(uuid),public.open_report(text),public.read_report(text)from public,anon,authenticated;
grant execute on function public.report_data(uuid,date,date),public.report_manage(jsonb,uuid),public.report_link_list(uuid)to authenticated;
grant execute on function public.open_report(text),public.read_report(text)to anon,authenticated;
commit;

notify pgrst, 'reload schema';
