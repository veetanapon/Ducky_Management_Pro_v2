-- Ducky v2 0.1 — apply ONLY to a NEW Supabase project. One-time migration.
-- Deliberately refuses to install over legacy or an existing v2 schema.
begin;
do $$ begin
 if to_regclass('public.animal_batches') is not null or to_regclass('public.batches') is not null then
  raise exception 'STOP: expected an empty NEW project';
 end if;
end $$;
create schema if not exists private;
revoke all on schema private from public, anon;
grant usage on schema private to authenticated;
create table public.profiles (
 id uuid primary key references auth.users(id), display_name text not null default '',
 approved boolean not null default false, is_admin boolean not null default false,
 legacy_user_id text unique, created_at timestamptz not null default now()
);
create function private.on_signup() returns trigger language plpgsql security definer set search_path='' as $$
begin
 insert into public.profiles(id,display_name) values(new.id,coalesce(new.raw_user_meta_data->>'full_name',''));
 return new;
end $$;
create trigger ducky_signup after insert on auth.users for each row execute function private.on_signup();
create table public.module_access (
 user_id uuid references public.profiles(id), module text not null,
 can_write boolean not null default false, primary key(user_id,module),
 check(module in ('farm','feed','prices','analytics','finance','approvals','admin'))
);
create function private.is_admin() returns boolean language sql stable security definer set search_path='' as $$
 select exists(select 1 from public.profiles where id=auth.uid() and approved and is_admin)
$$;
create function private.has_module(m text, w boolean default false) returns boolean language sql stable security definer set search_path='' as $$
 select private.is_admin() or exists(select 1 from public.module_access a join public.profiles p on p.id=a.user_id
 where p.id=auth.uid() and p.approved and a.module=m and (not w or a.can_write))
$$;
create table public.species (id text primary key, name text not null);
insert into public.species values ('duck','เป็ด'),('fish','ปลา');
create table public.farms(id uuid primary key default gen_random_uuid(), name text not null, legacy_id text unique);
create table public.housing_units(id uuid primary key default gen_random_uuid(), farm_id uuid references public.farms, name text not null);
create table public.batches (
 id uuid primary key default gen_random_uuid(), legacy_id text unique, name text not null,
 species_id text not null references public.species, housing_id uuid references public.housing_units,
 start_date date not null, birth_date date, age_at_start_days integer check(age_at_start_days>=0),
 age_is_estimated boolean not null default false, initial_qty integer not null check(initial_qty>=0),
 status text not null default 'active' check(status in ('active','closed')), end_date date,
 purchase_cost numeric(16,2) check(purchase_cost>=0), breed text, image_ref text,
 created_at timestamptz not null default now(), check(end_date is null or end_date>=start_date)
);
create table public.batch_access (
 batch_id uuid references public.batches, user_id uuid references public.profiles,
 module text not null check(module in ('farm','analytics','finance')),
 can_write boolean not null default false, primary key(batch_id,user_id,module)
);
create function private.can_batch(b uuid,m text,w boolean default false) returns boolean language sql stable security definer set search_path='' as $$
 select private.is_admin() or (private.has_module(m,w) and exists(select 1 from public.batch_access
 where batch_id=b and user_id=auth.uid() and module=m and (not w or can_write)))
$$;
create table public.animal_movements (
 id uuid primary key default gen_random_uuid(), legacy_id text unique, batch_id uuid not null references public.batches,
 log_date date not null, kind text not null check(kind in ('add','death','sale','transfer_in','transfer_out')),
 qty integer not null check(qty>0), amount numeric(16,2), note text
);
create table public.egg_daily (
 id uuid primary key default gen_random_uuid(), legacy_id text unique, batch_id uuid not null references public.batches,
 log_date date not null, total integer not null check(total>=0), broken integer not null default 0 check(broken>=0 and broken<=total),
 live_count integer check(live_count>=0), data_complete boolean not null default true,
 version integer not null default 1, updated_at timestamptz not null default now(), unique(batch_id,log_date)
);
create table public.batch_events (
 id uuid primary key default gen_random_uuid(), legacy_id text unique, batch_id uuid not null references public.batches,
 start_date date not null, end_date date, event_type text not null, title text not null,
 severity text, details text, factors jsonb not null default '{}', check(end_date is null or end_date>=start_date)
);
create table public.event_expenses (
 id uuid primary key default gen_random_uuid(), legacy_id text unique, batch_id uuid not null references public.batches,
 event_id uuid not null references public.batch_events, amount numeric(16,2) not null check(amount>=0), category text not null,
 unique(event_id,id)
);
create table public.suppliers (
 id uuid primary key default gen_random_uuid(), name text not null unique,
 default_credit_days integer not null default 25 check(default_credit_days between 0 and 3650)
);
create table public.feed_orders (
 id uuid primary key default gen_random_uuid(), legacy_id text unique, supplier_id uuid references public.suppliers,
 feed_name text not null, order_date date not null, credit_days integer not null default 25 check(credit_days between 0 and 3650),
 due_date date generated always as (order_date+credit_days) stored,
 quantity numeric(16,3) not null check(quantity>0), unit text not null,
 kg_per_unit numeric(12,4) check(kg_per_unit>0), total numeric(16,2) not null check(total>=0),
 manufacturer_lot text, formula text, note text, version integer not null default 1, created_at timestamptz not null default now()
);
create table public.feed_allocations (
 id uuid primary key default gen_random_uuid(), legacy_id text unique, order_id uuid not null references public.feed_orders,
 batch_id uuid not null references public.batches, quantity numeric(16,3) not null check(quantity>0),
 assigned_cost numeric(16,2) not null check(assigned_cost>=0), allocation_date date not null,
 unique(id,batch_id), unique(id,order_id,batch_id)
);
create table public.feed_consumption (
 id uuid primary key default gen_random_uuid(), legacy_id text unique, batch_id uuid not null references public.batches,
 allocation_id uuid, log_date date not null, issued numeric(16,3) not null check(issued>=0),
 leftover numeric(16,3) not null check(leftover>=0), waste numeric(16,3) not null default 0 check(waste>=0),
 consumed numeric generated always as (issued-leftover-waste) stored,
 cost numeric(16,2) check(cost>=0), unit text not null, kg_per_unit numeric check(kg_per_unit>0),
 check(leftover+waste<=issued), foreign key(allocation_id,batch_id) references public.feed_allocations(id,batch_id)
);
create table public.feed_claims (
 id uuid primary key default gen_random_uuid(), legacy_id text unique, order_id uuid not null references public.feed_orders,
 claim_date date not null, kind text not null check(kind in ('credit','replacement','extra_charge')),
 amount numeric(16,2) not null check(amount>=0), quantity numeric check(quantity>=0), note text
);
create table public.price_sets(id uuid primary key default gen_random_uuid(),legacy_id text unique,name text not null,species_id text references public.species);
create table public.price_items (
 id uuid primary key default gen_random_uuid(), legacy_id text unique, price_set_id uuid not null references public.price_sets,
 grade text not null, price numeric(16,4) not null check(price>=0), valid_from date not null, valid_to date,
 check(valid_to is null or valid_to>=valid_from)
);
create table public.sales (
 id uuid primary key default gen_random_uuid(), legacy_id text unique, batch_id uuid not null references public.batches,
 sale_date date not null, buyer text, total numeric(16,2) not null check(total>=0), status text not null default 'posted'
);
create table public.sale_items (
 id uuid primary key default gen_random_uuid(), legacy_id text unique, sale_id uuid not null references public.sales,
 grade text not null, qty numeric not null check(qty>=0), unit text not null,
 unit_price numeric not null check(unit_price>=0), discount numeric not null default 0 check(discount>=0), total numeric not null check(total>=0)
);
create table public.batch_cash (
 id uuid primary key default gen_random_uuid(), batch_id uuid not null references public.batches,
 cash_date date not null, kind text not null check(kind in ('opening','receipt','expense','withdrawal','feed_payment','savings_transfer')),
 amount numeric(16,2) not null, reference_id uuid, note text, request_id uuid unique,
 created_by uuid references public.profiles, created_at timestamptz not null default now()
);
create table public.feed_payments (
 id uuid primary key default gen_random_uuid(), legacy_id text unique, order_id uuid not null references public.feed_orders,
 batch_id uuid not null references public.batches, allocation_id uuid not null,
 payment_date date not null, amount numeric(16,2) not null check(amount>0), request_id uuid not null unique,
 cash_id uuid not null references public.batch_cash, created_by uuid references public.profiles,
 foreign key(allocation_id,order_id,batch_id) references public.feed_allocations(id,order_id,batch_id)
);
create table public.batch_plans (
 id uuid primary key default gen_random_uuid(), batch_id uuid not null references public.batches,
 name text not null, version integer not null default 1, target_profit numeric(16,2),
 start_date date not null, end_date date not null, assumptions jsonb not null,
 created_at timestamptz not null default now(),check(end_date>=start_date)
);
create table public.historical_daily (
 id uuid primary key default gen_random_uuid(),legacy_id text unique,batch_id uuid not null references public.batches,
 log_date date not null, egg_total numeric,live_count numeric,feed_qty numeric,feed_cost numeric,
 egg_income numeric,margin_after_feed numeric,data_quality text not null default 'legacy_unknown',
 source text not null default 'REPORT_SUMMARYREPORT_DAILY',raw jsonb not null default '{}', unique(batch_id,log_date,source)
);
create table public.notifications (
 id uuid primary key default gen_random_uuid(), user_id uuid not null references public.profiles,
 title text not null, body text, route text, read_at timestamptz, created_at timestamptz not null default now()
);
create table public.push_subscriptions (
 id uuid primary key default gen_random_uuid(),user_id uuid not null references public.profiles,
 endpoint text not null unique, keys jsonb not null, created_at timestamptz not null default now()
);
create table public.audit_logs (
 id uuid primary key default gen_random_uuid(),actor uuid,table_name text not null,record_id text,
 operation text not null,before_data jsonb,after_data jsonb,created_at timestamptz not null default now()
);
create table public.integration_jobs (
 id uuid primary key default gen_random_uuid(),kind text not null,payload jsonb not null,
 status text not null default 'pending',attempts integer not null default 0,available_at timestamptz not null default now(),
 idempotency_key text not null unique,last_error text
);
create function private.audit_change() returns trigger language plpgsql security definer set search_path='' as $$
begin
 insert into public.audit_logs(actor,table_name,record_id,operation,before_data,after_data)
 values(auth.uid(),tg_table_name,coalesce(to_jsonb(new)->>'id',to_jsonb(old)->>'id'),tg_op,
 case when tg_op<>'INSERT' then to_jsonb(old) end,case when tg_op<>'DELETE' then to_jsonb(new) end);
 return coalesce(new,old);
end $$;
alter table public.profiles enable row level security;
revoke all on public.profiles from anon, authenticated;
alter table public.module_access enable row level security;
revoke all on public.module_access from anon, authenticated;
alter table public.species enable row level security;
revoke all on public.species from anon, authenticated;
alter table public.farms enable row level security;
revoke all on public.farms from anon, authenticated;
alter table public.housing_units enable row level security;
revoke all on public.housing_units from anon, authenticated;
alter table public.batches enable row level security;
revoke all on public.batches from anon, authenticated;
alter table public.batch_access enable row level security;
revoke all on public.batch_access from anon, authenticated;
alter table public.animal_movements enable row level security;
revoke all on public.animal_movements from anon, authenticated;
alter table public.egg_daily enable row level security;
revoke all on public.egg_daily from anon, authenticated;
alter table public.batch_events enable row level security;
revoke all on public.batch_events from anon, authenticated;
alter table public.event_expenses enable row level security;
revoke all on public.event_expenses from anon, authenticated;
alter table public.suppliers enable row level security;
revoke all on public.suppliers from anon, authenticated;
alter table public.feed_orders enable row level security;
revoke all on public.feed_orders from anon, authenticated;
alter table public.feed_allocations enable row level security;
revoke all on public.feed_allocations from anon, authenticated;
alter table public.feed_consumption enable row level security;
revoke all on public.feed_consumption from anon, authenticated;
alter table public.feed_claims enable row level security;
revoke all on public.feed_claims from anon, authenticated;
alter table public.price_sets enable row level security;
revoke all on public.price_sets from anon, authenticated;
alter table public.price_items enable row level security;
revoke all on public.price_items from anon, authenticated;
alter table public.sales enable row level security;
revoke all on public.sales from anon, authenticated;
alter table public.sale_items enable row level security;
revoke all on public.sale_items from anon, authenticated;
alter table public.batch_cash enable row level security;
revoke all on public.batch_cash from anon, authenticated;
alter table public.feed_payments enable row level security;
revoke all on public.feed_payments from anon, authenticated;
alter table public.batch_plans enable row level security;
revoke all on public.batch_plans from anon, authenticated;
alter table public.historical_daily enable row level security;
revoke all on public.historical_daily from anon, authenticated;
alter table public.notifications enable row level security;
revoke all on public.notifications from anon, authenticated;
alter table public.push_subscriptions enable row level security;
revoke all on public.push_subscriptions from anon, authenticated;
alter table public.audit_logs enable row level security;
revoke all on public.audit_logs from anon, authenticated;
alter table public.integration_jobs enable row level security;
revoke all on public.integration_jobs from anon, authenticated;
grant select on public.profiles to authenticated;
create policy read_allowed on public.profiles for select to authenticated using (id=auth.uid() or private.is_admin());
grant select on public.module_access to authenticated;
create policy read_allowed on public.module_access for select to authenticated using (user_id=auth.uid() or private.is_admin());
grant select on public.species to authenticated;
create policy read_allowed on public.species for select to authenticated using (auth.uid() is not null);
grant select on public.farms to authenticated;
create policy read_allowed on public.farms for select to authenticated using (private.has_module('farm'));
grant select on public.housing_units to authenticated;
create policy read_allowed on public.housing_units for select to authenticated using (private.has_module('farm'));
grant select on public.batches to authenticated;
create policy read_allowed on public.batches for select to authenticated using (private.can_batch(id,'farm') or private.can_batch(id,'analytics') or private.can_batch(id,'finance'));
grant select on public.batch_access to authenticated;
create policy read_allowed on public.batch_access for select to authenticated using (user_id=auth.uid() or private.is_admin());
grant select on public.suppliers to authenticated;
create policy read_allowed on public.suppliers for select to authenticated using (private.has_module('feed'));
grant select on public.feed_orders to authenticated;
create policy read_allowed on public.feed_orders for select to authenticated using (private.has_module('feed'));
grant select on public.feed_allocations to authenticated;
create policy read_allowed on public.feed_allocations for select to authenticated using (private.has_module('feed') or private.can_batch(batch_id,'farm'));
grant select on public.feed_claims to authenticated;
create policy read_allowed on public.feed_claims for select to authenticated using (private.has_module('feed'));
grant select on public.price_sets to authenticated;
create policy read_allowed on public.price_sets for select to authenticated using (private.has_module('prices') or private.has_module('farm'));
grant select on public.price_items to authenticated;
create policy read_allowed on public.price_items for select to authenticated using (private.has_module('prices') or private.has_module('farm'));
grant select on public.feed_payments to authenticated;
create policy read_allowed on public.feed_payments for select to authenticated using (private.can_batch(batch_id,'finance'));
grant select on public.batch_cash to authenticated;
create policy read_allowed on public.batch_cash for select to authenticated using (private.can_batch(batch_id,'finance'));
grant select on public.batch_plans to authenticated;
create policy read_allowed on public.batch_plans for select to authenticated using (private.can_batch(batch_id,'finance'));
grant select on public.notifications to authenticated;
create policy read_allowed on public.notifications for select to authenticated using (user_id=auth.uid());
grant select on public.push_subscriptions to authenticated;
create policy read_allowed on public.push_subscriptions for select to authenticated using (user_id=auth.uid());
grant select on public.audit_logs to authenticated;
create policy read_allowed on public.audit_logs for select to authenticated using (private.is_admin());
grant select on public.sale_items to authenticated;
create policy read_allowed on public.sale_items for select to authenticated using (exists(select 1 from public.sales s where s.id=sale_id));
grant select on public.animal_movements to authenticated;
create policy read_allowed on public.animal_movements for select to authenticated using (private.can_batch(batch_id,'farm') or private.can_batch(batch_id,'analytics'));
grant select on public.egg_daily to authenticated;
create policy read_allowed on public.egg_daily for select to authenticated using (private.can_batch(batch_id,'farm') or private.can_batch(batch_id,'analytics'));
grant select on public.batch_events to authenticated;
create policy read_allowed on public.batch_events for select to authenticated using (private.can_batch(batch_id,'farm') or private.can_batch(batch_id,'analytics'));
grant select on public.feed_consumption to authenticated;
create policy read_allowed on public.feed_consumption for select to authenticated using (private.can_batch(batch_id,'farm') or private.can_batch(batch_id,'analytics'));
grant select on public.historical_daily to authenticated;
create policy read_allowed on public.historical_daily for select to authenticated using (private.can_batch(batch_id,'farm') or private.can_batch(batch_id,'analytics'));
grant select on public.sales to authenticated;
create policy read_allowed on public.sales for select to authenticated using (private.can_batch(batch_id,'finance') or private.can_batch(batch_id,'farm'));
grant select on public.event_expenses to authenticated;
create policy read_allowed on public.event_expenses for select to authenticated using (private.can_batch(batch_id,'finance') or private.can_batch(batch_id,'farm'));
grant insert, update on public.batches to authenticated;
create policy insert_allowed on public.batches for insert to authenticated with check (private.is_admin());
create policy update_allowed on public.batches for update to authenticated using (private.is_admin()) with check (private.is_admin());
grant insert, update on public.batch_events to authenticated;
create policy insert_allowed on public.batch_events for insert to authenticated with check (private.can_batch(batch_id,'farm',true));
create policy update_allowed on public.batch_events for update to authenticated using (private.can_batch(batch_id,'farm',true)) with check (private.can_batch(batch_id,'farm',true));
grant insert, update on public.suppliers to authenticated;
create policy insert_allowed on public.suppliers for insert to authenticated with check (private.has_module('feed',true));
create policy update_allowed on public.suppliers for update to authenticated using (private.has_module('feed',true)) with check (private.has_module('feed',true));
grant insert, update on public.price_sets to authenticated;
create policy insert_allowed on public.price_sets for insert to authenticated with check (private.has_module('prices',true));
create policy update_allowed on public.price_sets for update to authenticated using (private.has_module('prices',true)) with check (private.has_module('prices',true));
grant insert, update on public.price_items to authenticated;
create policy insert_allowed on public.price_items for insert to authenticated with check (private.has_module('prices',true));
create policy update_allowed on public.price_items for update to authenticated using (private.has_module('prices',true)) with check (private.has_module('prices',true));
grant insert, update on public.batch_plans to authenticated;
create policy insert_allowed on public.batch_plans for insert to authenticated with check (private.can_batch(batch_id,'finance',true));
create policy update_allowed on public.batch_plans for update to authenticated using (private.can_batch(batch_id,'finance',true)) with check (private.can_batch(batch_id,'finance',true));
grant insert, update on public.push_subscriptions to authenticated;
create policy insert_allowed on public.push_subscriptions for insert to authenticated with check (user_id=auth.uid());
create policy update_allowed on public.push_subscriptions for update to authenticated using (user_id=auth.uid()) with check (user_id=auth.uid());
grant update(read_at) on public.notifications to authenticated;
create policy mark_read on public.notifications for update to authenticated using(user_id=auth.uid()) with check(user_id=auth.uid());
grant delete on public.push_subscriptions to authenticated;
create policy unsubscribe on public.push_subscriptions for delete to authenticated using(user_id=auth.uid());
create trigger audit after insert or update or delete on public.batches for each row execute function private.audit_change();
create trigger audit after insert or update or delete on public.batch_events for each row execute function private.audit_change();
create trigger audit after insert or update or delete on public.feed_orders for each row execute function private.audit_change();
create trigger audit after insert or update or delete on public.feed_payments for each row execute function private.audit_change();
create trigger audit after insert or update or delete on public.batch_cash for each row execute function private.audit_change();
create trigger audit after insert or update or delete on public.egg_daily for each row execute function private.audit_change();
create trigger audit after insert or update or delete on public.batch_plans for each row execute function private.audit_change();
create trigger audit after insert or update or delete on public.feed_allocations for each row execute function private.audit_change();
create index on public.egg_daily(batch_id);
create index on public.batch_events(batch_id);
create index on public.feed_consumption(batch_id);
create index on public.sales(batch_id);
create index on public.batch_cash(batch_id);
create index on public.historical_daily(batch_id);
create index on public.batch_plans(batch_id);

-- Client writes that must be atomic are RPC only.
create function public.save_egg(p_batch uuid,p_date date,p_total integer,p_broken integer,p_live integer,p_expected integer default 0)
returns public.egg_daily language plpgsql security definer set search_path='' as $$
declare r public.egg_daily;
begin
 if not private.can_batch(p_batch,'farm',true) then raise exception 'NO_ACCESS'; end if;
 if (select species_id from public.batches where id=p_batch)<>'duck' then raise exception 'SPECIES_MISMATCH'; end if;
 perform pg_advisory_xact_lock(hashtextextended(p_batch::text||p_date::text,0));
 select * into r from public.egg_daily where batch_id=p_batch and log_date=p_date for update;
 if found then
  if r.version<>p_expected then raise exception 'VERSION_CONFLICT'; end if;
  update public.egg_daily set total=p_total,broken=p_broken,live_count=p_live,version=version+1,updated_at=now()
  where id=r.id returning * into r;
 else
  if p_expected<>0 then raise exception 'VERSION_CONFLICT'; end if;
  insert into public.egg_daily(batch_id,log_date,total,broken,live_count) values(p_batch,p_date,p_total,p_broken,p_live) returning * into r;
 end if;
 return r;
end $$;
create function public.save_feed_order(p_id uuid,p_feed text,p_date date,p_days integer,p_qty numeric,p_unit text,p_kg numeric,p_total numeric,p_expected integer default 0)
returns public.feed_orders language plpgsql security definer set search_path='' as $$
declare r public.feed_orders;
begin
 if not private.has_module('feed',true) then raise exception 'NO_ACCESS'; end if;
 perform pg_advisory_xact_lock(hashtextextended(p_id::text,0));
 select * into r from public.feed_orders where id=p_id for update;
 if found then
  if r.version<>p_expected then raise exception 'VERSION_CONFLICT'; end if;
  if r.feed_name<>p_feed or r.order_date<>p_date or r.quantity<>p_qty or r.unit<>p_unit or r.kg_per_unit is distinct from p_kg or r.total<>p_total then
   raise exception 'ONLY_CREDIT_DAYS_EDITABLE_IN_V01';
  end if;
  update public.feed_orders set credit_days=p_days,version=version+1 where id=p_id returning * into r;
 else
  if p_expected<>0 then raise exception 'VERSION_CONFLICT'; end if;
  insert into public.feed_orders(id,feed_name,order_date,credit_days,quantity,unit,kg_per_unit,total)
  values(p_id,p_feed,p_date,p_days,p_qty,p_unit,p_kg,p_total) returning * into r;
 end if;
 return r;
end $$;
create function public.record_feed_payment(p_allocation uuid,p_amount numeric,p_date date,p_request uuid)
returns public.feed_payments language plpgsql security definer set search_path='' as $$
declare a public.feed_allocations; r public.feed_payments; o public.feed_orders; paid numeric; credit numeric; cash uuid; balance numeric;
begin
 if p_amount is null or p_amount<=0 or p_amount<>round(p_amount,2) or p_date is null or p_request is null then raise exception 'INVALID_PAYMENT'; end if;
 select * into a from public.feed_allocations where id=p_allocation;
 if not found then raise exception 'ALLOCATION_NOT_FOUND'; end if;
 if not private.can_batch(a.batch_id,'finance',true) then raise exception 'NO_ACCESS'; end if;
 perform pg_advisory_xact_lock(hashtextextended(p_request::text,1));
 select * into r from public.feed_payments where request_id=p_request;
 if found then
  if r.allocation_id<>p_allocation or r.amount<>p_amount or r.payment_date<>p_date then raise exception 'IDEMPOTENCY_CONFLICT'; end if;
  return r;
 end if;
 -- Same lock must be used by every future cash/claim/allocation writer.
 perform 1 from public.batches where id=a.batch_id for update;
 select * into o from public.feed_orders where id=a.order_id for update;
 select coalesce(sum(amount),0) into paid from public.feed_payments where allocation_id=a.id;
 if p_amount>a.assigned_cost-paid then raise exception 'EXCEEDS_BATCH_SHARE'; end if;
 select coalesce(sum(amount),0) into paid from public.feed_payments where order_id=o.id;
 select coalesce(sum(case kind when 'credit' then amount when 'extra_charge' then -amount else 0 end),0)
 into credit from public.feed_claims where order_id=o.id;
 if p_amount>o.total-credit-paid then raise exception 'EXCEEDS_BILL_BALANCE'; end if;
 select coalesce(sum(amount),0) into balance from public.batch_cash where batch_id=a.batch_id and cash_date<=p_date;
 if balance<p_amount then raise exception 'INSUFFICIENT_BATCH_CASH'; end if;
 insert into public.batch_cash(batch_id,cash_date,kind,amount,request_id,created_by)
 values(a.batch_id,p_date,'feed_payment',-p_amount,p_request,auth.uid()) returning id into cash;
 insert into public.feed_payments(order_id,batch_id,allocation_id,payment_date,amount,request_id,cash_id,created_by)
 values(a.order_id,a.batch_id,a.id,p_date,p_amount,p_request,cash,auth.uid()) returning * into r;
 return r;
end $$;
grant all on all tables in schema public to service_role;
-- Restricted by default, explicitly expose only these RPCs and policy helpers.
revoke all on all functions in schema private from public, anon, authenticated;
grant execute on function private.is_admin(),private.has_module(text,boolean),private.can_batch(uuid,text,boolean) to authenticated;
revoke all on function public.save_egg(uuid,date,integer,integer,integer,integer),public.save_feed_order(uuid,text,date,integer,numeric,text,numeric,numeric,integer),public.record_feed_payment(uuid,numeric,date,uuid) from public,anon,authenticated;
grant execute on function public.save_egg(uuid,date,integer,integer,integer,integer),public.save_feed_order(uuid,text,date,integer,numeric,text,numeric,numeric,integer),public.record_feed_payment(uuid,numeric,date,uuid) to authenticated;
commit;
