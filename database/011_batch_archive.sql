-- Ducky 0.8.0. Summary export + explicitly confirmed purge; shared ledgers retain compact totals.
begin;
alter table public.feed_orders add column archived_paid numeric(16,2)not null default 0,add column archived_activity date,add column archived_batches integer not null default 0;
create table public.feed_archive_sources(order_id uuid not null references public.feed_orders,source_key uuid not null,quantity numeric(16,3)not null,primary key(order_id,source_key));
alter table public.feed_archive_sources enable row level security;revoke all on public.feed_archive_sources from public,anon,authenticated;grant all on public.feed_archive_sources to service_role;
alter table public.supply_invoices add column archived_paid numeric(16,2)not null default 0,add column archived_activity date,add column archived_batches integer not null default 0;
alter table public.supply_lots add column archived_quantity numeric(16,3)not null default 0,add column archived_used numeric(16,3)not null default 0,add column archived_cost numeric(16,2)not null default 0,add column archived_activity date;
alter function private.feed_totals(uuid)rename to feed_totals_v070;
create function private.feed_totals(p_order uuid)returns jsonb language plpgsql stable security definer set search_path='' as $$declare r jsonb;o public.feed_orders;p numeric;a numeric;begin
 r:=private.feed_totals_v070(p_order);select * into o from public.feed_orders where id=p_order;
 p:=(r->>'paid_total')::numeric+o.archived_paid;a:=coalesce((select sum(quantity)from public.feed_archive_sources where order_id=p_order),0);
 return r||jsonb_build_object('paid_total',p,'outstanding',greatest(0,(r->>'net_total')::numeric-p),'supplier_credit',greatest(0,p-(r->>'net_total')::numeric),'allocated_quantity',(r->>'allocated_quantity')::numeric+a,'available_quantity',(r->>'available_quantity')::numeric-a);
end$$;
alter function private.feed_source(uuid,uuid)rename to feed_source_v070;
create function private.feed_source(p_order uuid,p_source uuid)returns jsonb language plpgsql stable security definer set search_path='' as $$declare r jsonb;a numeric;d date;begin
 r:=private.feed_source_v070(p_order,p_source);select quantity into a from public.feed_archive_sources where order_id=p_order and source_key=coalesce(p_source,'00000000-0000-0000-0000-000000000000');select archived_activity into d from public.feed_orders where id=p_order;
 return r||jsonb_build_object('available',(r->>'available')::numeric-coalesce(a,0),'available_from',greatest((r->>'available_from')::date,d));
end$$;
-- Preserve the original validators; replace only explicit aggregate operands.
do $$declare d text;begin
 select pg_get_functiondef('public.feed_save_order(jsonb,uuid)'::regprocedure)into d;if position('linked:=exists' in d)=0 then raise exception 'UNEXPECTED_FEED_SAVE_DEFINITION';end if;d:=replace(d,'linked:=exists','linked:=old.archived_batches>0 or exists');execute d;
 select pg_get_functiondef('public.feed_payment_preview(jsonb)'::regprocedure)into d;d:=replace(d,'if exists(select 1 from public.feed_claims where order_id=o.id and claim_date>d)','if o.archived_activity>d or exists(select 1 from public.feed_claims where order_id=o.id and claim_date>d)');execute d;
 select pg_get_functiondef('public.supply_manage(jsonb,uuid)'::regprocedure)into d;
 if position('available:=l.quantity-l.returned-'in d)=0 or position('v:=round((coalesce((select sum(u.quantity)'in d)=0 then raise exception 'UNEXPECTED_SUPPLY_DEFINITION';end if;d:=replace(d,'if d<iv.invoice_date or d<coalesce','if d<iv.invoice_date or d<iv.archived_activity or d<coalesce');
 d:=replace(d,'if exists(select 1 from public.supply_payments','if iv.archived_batches>0 or exists(select 1 from public.supply_payments');
 d:=replace(d,'select coalesce(sum(amount),0)into paid','select iv.archived_paid+coalesce(sum(amount),0)into paid');
 d:=replace(d,'if d<iv.invoice_date or d<coalesce((select max(log_date)','if d<iv.invoice_date or d<l.archived_activity or d<coalesce((select max(log_date)');
 d:=replace(d,'available:=l.quantity-l.returned-','available:=l.quantity-l.returned-l.archived_quantity-');
 d:=replace(d,'v:=round((coalesce((select sum(u.quantity)','v:=round((l.archived_used+coalesce((select sum(u.quantity)');
 d:=replace(d,')*l.unit_cost,2)-coalesce',')*l.unit_cost,2)-l.archived_cost-coalesce');execute d;
end$$;
-- Export tickets contain only the row fingerprint, never a second copy of the batch.
create table private.archive_tickets(id uuid primary key default gen_random_uuid(),batch_id uuid not null references public.batches,actor uuid not null,fingerprint text not null,expires_at timestamptz not null default now()+interval '2 hours');
create table private.archive_receipts(request_id uuid primary key,actor uuid not null,payload_hash text not null,batch_hash text not null,result jsonb not null);
revoke all on private.archive_tickets,private.archive_receipts from public,anon,authenticated;
-- Retain a one-way retired-id digest so an old offline creation request cannot resurrect a purged batch.
alter function public.batch_save(jsonb,uuid)rename to batch_save_v070;
revoke all on function public.batch_save_v070(jsonb,uuid)from public,anon,authenticated;
create function public.batch_save(p_data jsonb,p_request uuid)returns jsonb language plpgsql security definer set search_path='' as $$begin
 if not private.is_admin()then raise exception 'ADMIN_REQUIRED';end if;
 perform private.feed_lock();if exists(select 1 from private.archive_receipts where batch_hash=encode(sha256(convert_to((p_data->>'id')::uuid::text,'UTF8')),'hex'))then raise exception 'BATCH_ARCHIVED';end if;
 return public.batch_save_v070(p_data,p_request);
end$$;
revoke all on function public.batch_save(jsonb,uuid)from public,anon,authenticated;
grant execute on function public.batch_save(jsonb,uuid)to authenticated;
-- In-memory scope used for change detection and deletion. Not returned to clients or retained.
create function private.archive_rows(b uuid)returns jsonb language plpgsql security definer set search_path='' as $$declare t text;r jsonb:='{}';v jsonb;begin
 foreach t in array array['batches','animal_movements','egg_daily','batch_events','event_expenses','feed_allocations','feed_consumption','sales','batch_cash','feed_payments','batch_plans','historical_daily','price_bindings','farm_egg_openings','farm_feed_returns','farm_pending','supply_allocations','supply_usage','supply_payments','external_funds','report_links','worker_submissions','access_links']loop
 execute format('select coalesce(jsonb_agg(to_jsonb(x)order by id),''[]'')from public.%I x where %I=$1',t,case when t='batches'then 'id'else 'batch_id'end)into v using b;r:=r||jsonb_build_object(t,v);end loop;
 select coalesce(jsonb_agg(to_jsonb(x)order by id),'[]')into v from public.sale_items x where sale_id in(select id from public.sales where batch_id=b);r:=r||jsonb_build_object('sale_items',v);
 select coalesce(jsonb_agg(to_jsonb(x)order by id),'[]')into v from public.supply_returns x where allocation_id in(select id from public.supply_allocations where batch_id=b);r:=r||jsonb_build_object('supply_returns',v);
 select coalesce(jsonb_agg(to_jsonb(x)order by id),'[]')into v from public.report_sessions x where link_id in(select id from public.report_links where batch_id=b);r:=r||jsonb_build_object('report_sessions',v);
 select coalesce(jsonb_agg(to_jsonb(x)order by user_id,module),'[]')into v from public.batch_access x where batch_id=b;r:=r||jsonb_build_object('batch_access',v);
 select coalesce(jsonb_agg(to_jsonb(x)order by kind),'[]')into v from public.workspace_images x where kind='batch'and target_id=b;return r||jsonb_build_object('workspace_images',v);
end$$;
create function private.archive_blockers(b uuid)returns jsonb language plpgsql security definer set search_path='' as $$declare r jsonb:='[]';begin
 if not exists(select 1 from public.batches where id=b and status='closed')then r:=r||'"ต้องปิดล็อตก่อนล้างข้อมูล"'::jsonb;end if;
 if(select coalesce(sum(amount),0)from public.batch_cash where batch_id=b)<>0 then r:=r||'"เงินของล็อตยังไม่เป็นศูนย์ ให้บันทึกการนำเงินออกก่อน"'::jsonb;end if;
 if exists(select 1 from public.farm_pending where batch_id=b and status='pending')or exists(select 1 from public.worker_submissions where batch_id=b and status='pending')then r:=r||'"มีงานรอตรวจ ให้ยืนยันหรือยกเลิกก่อน"'::jsonb;end if;
 if exists(select 1 from public.external_funds where batch_id=b and status='expected')then r:=r||'"มีเงินจากเล้าอื่นรอรับ ให้รับหรือยกเลิกก่อน"'::jsonb;end if;
 if exists(select 1 from public.feed_allocations a where batch_id=b and quantity-coalesce((select sum(issued-leftover)from public.feed_consumption where allocation_id=a.id),0)-coalesce((select sum(quantity)from public.farm_feed_returns where allocation_id=a.id),0)<>0)then r:=r||'"อาหารของล็อตยังเหลือ ให้คืนคลังหรือบันทึกการใช้ให้ครบ"'::jsonb;end if;
 if exists(select 1 from public.supply_allocations a where batch_id=b and quantity-returned-coalesce((select sum(quantity)from public.supply_usage where allocation_id=a.id),0)<>0)then r:=r||'"ยา/วิตามินของล็อตยังเหลือ ให้คืนคลังหรือบันทึกการใช้ให้ครบ"'::jsonb;end if;
 return r;
end$$;
create function public.batch_export(p_batch uuid)returns jsonb language plpgsql security definer set search_path='' as $$
declare b uuid:=p_batch;bt public.batches;r jsonb;scope jsonb;fp text;ticket uuid;counts jsonb;tbl text;begin
 if not private.is_admin()then raise exception 'ADMIN_REQUIRED';end if;perform private.feed_lock();for tbl in select tablename from pg_tables where schemaname='public'order by tablename loop execute format('lock table public.%I in share row exclusive mode',tbl);end loop;select * into strict bt from public.batches where id=b;
 scope:=private.archive_rows(b);fp:=encode(sha256(convert_to(scope::text,'UTF8')),'hex');select jsonb_object_agg(key,jsonb_array_length(value))into counts from jsonb_each(scope);
 select jsonb_build_object('format','ducky-batch-summary-1','generated_at',now(),'batch',jsonb_build_object('name',bt.name,'species_id',bt.species_id,'start_date',bt.start_date,'end_date',bt.end_date,'status',bt.status,'initial_qty',bt.initial_qty,'purchase_cost',bt.purchase_cost),'counts',counts,
 'totals',jsonb_build_object('eggs',coalesce((select sum(total)from public.egg_daily where batch_id=b),0),'broken',coalesce((select sum(broken)from public.egg_daily where batch_id=b),0),'sales',coalesce((select sum(total)from public.sales where batch_id=b and status='posted'),0),'feed_cost',coalesce((select sum(cost)from public.feed_consumption where batch_id=b),0),'event_cost',coalesce((select sum(amount)from public.event_expenses where batch_id=b),0),'cash_balance',coalesce((select sum(amount)from public.batch_cash where batch_id=b),0),'animal_balance',private.farm_animal_balance(b,'9999-12-31'),'egg_balance',private.farm_egg_balance(b,'9999-12-31'),'feed_debt_payments',coalesce((select sum(amount)from public.feed_payments where batch_id=b),0),'supply_debt_payments',coalesce((select sum(amount)from public.supply_payments where batch_id=b),0),'external_received',coalesce((select sum(amount)from public.external_funds where batch_id=b and status='received'),0)),
 'eggs_daily',coalesce((select jsonb_agg(jsonb_build_object('date',log_date,'total',total,'broken',broken,'big',big,'small',small,'cracked',cracked,'live_count',live_count,'counted_remaining',remaining)order by log_date)from public.egg_daily where batch_id=b),'[]'),
 'feed_daily',coalesce((select jsonb_agg(to_jsonb(x)order by log_date,feed_name,unit)from(select c.log_date,a.feed_name,c.unit,sum(c.consumed)consumed,sum(c.waste)waste,sum(c.cost)cost,case when bool_and(c.kg_per_unit is not null)then sum(c.consumed*c.kg_per_unit)end consumed_kg from public.feed_consumption c join public.feed_allocations a on a.id=c.allocation_id where c.batch_id=b group by c.log_date,a.feed_name,c.unit)x),'[]'),
 'sales_daily',coalesce((select jsonb_agg(to_jsonb(x)order by sale_date,sale_type)from(select sale_date,sale_type,count(*)bills,sum(total)amount from public.sales where batch_id=b and status='posted'group by sale_date,sale_type)x),'[]'),
 'cash_monthly',coalesce((select jsonb_agg(to_jsonb(x)order by x."month",kind)from(select to_char(cash_date,'YYYY-MM') as "month",kind,sum(amount)amount from public.batch_cash where batch_id=b group by 1,kind)x),'[]'),
 'events_monthly',coalesce((select jsonb_agg(to_jsonb(x)order by x."month",event_type)from(select to_char(e.start_date,'YYYY-MM') as "month",e.event_type,count(*)events,sum(coalesce((select sum(amount)from public.event_expenses where event_id=e.id),0))cost from public.batch_events e where batch_id=b group by 1,event_type)x),'[]'),
 'animals_monthly',coalesce((select jsonb_agg(to_jsonb(x)order by x."month",kind)from(select to_char(log_date,'YYYY-MM') as "month",kind,sum(qty)quantity from public.animal_movements where batch_id=b group by 1,kind)x),'[]'),
 'supplies',coalesce((select jsonb_agg(to_jsonb(x)order by name)from(select i.name,i.category,i.unit,sum(u.quantity)used,sum(u.cost)cost from public.supply_usage u join public.supply_allocations a on a.id=u.allocation_id join public.supply_lots l on l.id=a.lot_id join public.supply_items i on i.id=l.item_id where u.batch_id=b group by i.name,i.category,i.unit)x),'[]'),
 'legacy_monthly',coalesce((select jsonb_agg(to_jsonb(x)order by x."month")from(select to_char(log_date,'YYYY-MM') as "month",count(*)records,sum(egg_total)eggs,sum(feed_cost)feed_cost,sum(egg_income)egg_income,sum(margin_after_feed)margin_after_feed from public.historical_daily where batch_id=b group by 1)x),'[]'))into r;
 delete from private.archive_tickets where actor=auth.uid()and(expires_at<=now()or batch_id=b);
 insert into private.archive_tickets(batch_id,actor,fingerprint)values(b,auth.uid(),fp)returning id into ticket;
 return jsonb_build_object('summary',r,'fingerprint',fp,'ticket',ticket,'blockers',private.archive_blockers(b));
end$$;
create function public.batch_purge(p_data jsonb,p_request uuid)returns jsonb language plpgsql security definer set search_path='' as $$
declare p jsonb:=p_data;b uuid:=(p->>'batch_id')::uuid;bt public.batches;t private.archive_tickets;rec private.archive_receipts;scope jsonb;ids text[];tbl text;r jsonb;hash text:=encode(sha256(convert_to(p::text,'UTF8')),'hex');begin
 if not private.is_admin()then raise exception 'ADMIN_REQUIRED';end if;
 perform private.feed_lock();select * into rec from private.archive_receipts where request_id=p_request;
 if found then if rec.actor<>auth.uid()or rec.payload_hash<>hash then raise exception 'REQUEST_CONFLICT';end if;return rec.result;end if;
 -- Prevent edits/inserts while the exported fingerprint is compared and rows are removed.
 for tbl in select tablename from pg_tables where schemaname='public'order by tablename loop execute format('lock table public.%I in share row exclusive mode',tbl);end loop;
 select * into strict bt from public.batches where id=b;
 if p->>'confirmation'is distinct from bt.name or (p->>'downloaded')::boolean is distinct from true then raise exception 'CONFIRMATION_REQUIRED';end if;
 select * into t from private.archive_tickets where id=(p->>'ticket')::uuid and batch_id=b and actor=auth.uid()and expires_at>now();if not found then raise exception 'EXPORT_AGAIN';end if;
 scope:=private.archive_rows(b);if encode(sha256(convert_to(scope::text,'UTF8')),'hex')is distinct from t.fingerprint or p->>'fingerprint'is distinct from t.fingerprint then raise exception 'DATA_CHANGED_EXPORT_AGAIN';end if;
 if jsonb_array_length(private.archive_blockers(b))>0 then raise exception 'BATCH_NOT_READY';end if;
 select array_agg(distinct val)into ids from(select b::text val union all select row->>'id'from jsonb_each(scope)e cross join lateral jsonb_array_elements(e.value)row where row?'id')x;
 -- These aggregates have no batch identifier or personal details. Central stock/debt must survive.
 insert into public.feed_archive_sources(order_id,source_key,quantity)select a.order_id,coalesce(a.source_claim_id,'00000000-0000-0000-0000-000000000000'),sum(a.quantity-coalesce((select sum(quantity)from public.farm_feed_returns where allocation_id=a.id),0))from public.feed_allocations a where batch_id=b group by a.order_id,a.source_claim_id on conflict(order_id,source_key)do update set quantity=public.feed_archive_sources.quantity+excluded.quantity;
 update public.feed_orders o set archived_paid=archived_paid+coalesce((select sum(amount)from public.feed_payments where order_id=o.id and batch_id=b),0),archived_activity=greatest(archived_activity,coalesce(bt.end_date,bt.start_date),(select max(payment_date)from public.feed_payments where order_id=o.id and batch_id=b)),archived_batches=archived_batches+1 where exists(select 1 from public.feed_allocations where order_id=o.id and batch_id=b)or exists(select 1 from public.feed_payments where order_id=o.id and batch_id=b);
 update public.supply_invoices i set archived_paid=archived_paid+coalesce((select sum(amount)from public.supply_payments where invoice_id=i.id and batch_id=b),0),archived_activity=greatest(archived_activity,coalesce(bt.end_date,bt.start_date),(select max(payment_date)from public.supply_payments where invoice_id=i.id and batch_id=b)),archived_batches=archived_batches+1 where exists(select 1 from public.supply_payments where invoice_id=i.id and batch_id=b)or exists(select 1 from public.supply_allocations a join public.supply_lots l on l.id=a.lot_id where l.invoice_id=i.id and a.batch_id=b);
 update public.supply_lots l set archived_quantity=archived_quantity+coalesce((select sum(quantity-returned)from public.supply_allocations where lot_id=l.id and batch_id=b),0),archived_used=archived_used+coalesce((select sum(u.quantity)from public.supply_usage u join public.supply_allocations a on a.id=u.allocation_id where a.lot_id=l.id and u.batch_id=b),0),archived_cost=archived_cost+coalesce((select sum(u.cost)from public.supply_usage u join public.supply_allocations a on a.id=u.allocation_id where a.lot_id=l.id and u.batch_id=b),0),archived_activity=greatest(archived_activity,coalesce(bt.end_date,bt.start_date))where exists(select 1 from public.supply_allocations where lot_id=l.id and batch_id=b);
 delete from public.report_sessions where link_id in(select id from public.report_links where batch_id=b);
 delete from public.sale_items where sale_id in(select id from public.sales where batch_id=b);
 delete from public.supply_returns where allocation_id in(select id from public.supply_allocations where batch_id=b);
 foreach tbl in array array['worker_submissions','access_links','report_links','price_bindings','batch_plans','historical_daily','external_funds','feed_payments','supply_payments','supply_usage','event_expenses','animal_movements','batch_events','sales','feed_consumption','farm_feed_returns','feed_allocations','supply_allocations','farm_egg_openings','egg_daily','batch_cash','farm_pending','batch_access']loop execute format('delete from public.%I where batch_id=$1',tbl)using b;end loop;
 delete from public.workspace_images where kind='batch'and target_id=b;
 delete from private.archive_tickets where batch_id=b;
 delete from public.batches where id=b;
 -- Drop retained row payloads, notifications and idempotency copies for this batch too.
 delete from public.audit_logs a where record_id=any(ids)or exists(select 1 from unnest(ids)x where position(x in coalesce(a.before_data::text,'')||coalesce(a.after_data::text,''))>0);
 delete from public.feed_requests a where exists(select 1 from unnest(ids)x where position(x in a.payload::text||a.result::text)>0);
 delete from public.notifications a where exists(select 1 from unnest(ids)x where position(x in coalesce(a.route,'')||coalesce(a.body,''))>0);
 delete from public.integration_jobs a where exists(select 1 from unnest(ids)x where position(x in a.payload::text)>0);
 r:=jsonb_build_object('purged',true,'summary_fingerprint',t.fingerprint,'completed_at',now());insert into private.archive_receipts values(p_request,auth.uid(),hash,encode(sha256(convert_to(b::text,'UTF8')),'hex'),r);return r;
end$$;
revoke all on function private.feed_totals_v070(uuid),private.feed_totals(uuid),private.feed_source_v070(uuid,uuid),private.feed_source(uuid,uuid),private.archive_rows(uuid),private.archive_blockers(uuid),public.batch_export(uuid),public.batch_purge(jsonb,uuid)from public,anon,authenticated;
grant execute on function public.batch_export(uuid),public.batch_purge(jsonb,uuid)to authenticated;
commit;
notify pgrst,'reload schema';
