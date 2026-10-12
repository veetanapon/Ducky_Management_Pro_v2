-- 0.9.0 after 011. Quantities remain in purchase units; use input is snapshotted per usage.
begin;
alter table public.supply_items add column use_unit text,add column units_per_purchase numeric(20,6)not null default 1 check(units_per_purchase>0 and units_per_purchase<=1000000000);
update public.supply_items set use_unit=unit;alter table public.supply_items alter column use_unit set not null;
create function private.supply_item_units()returns trigger language plpgsql set search_path='' as $$begin
 new.use_unit:=coalesce(nullif(trim(new.use_unit),''),new.unit);return new;
end$$;
create trigger supply_item_units before insert on public.supply_items for each row execute function private.supply_item_units();
revoke all on function private.supply_item_units()from public,anon,authenticated;
alter table public.supply_lots add column purchase_unit text,add column use_unit text,add column units_per_purchase numeric(20,6)not null default 1 check(units_per_purchase>0 and units_per_purchase<=1000000000);
update public.supply_lots l set purchase_unit=i.unit,use_unit=i.unit from public.supply_items i where i.id=l.item_id;
alter table public.supply_lots alter column purchase_unit set not null,alter column use_unit set not null;
alter table public.supply_usage alter column quantity type numeric(24,9),add column entered_quantity numeric(24,6),add column entered_unit text,add column conversion_factor numeric(20,6);
alter table public.supply_lots alter column archived_used type numeric(24,9),alter column archived_quantity type numeric(24,9);
alter table public.supply_allocations alter column quantity type numeric(24,9),alter column returned type numeric(24,9);
alter table public.supply_returns alter column quantity type numeric(24,9);
-- Snapshot package units on receipt, even if the item defaults change later.
create function private.supply_pack_snapshot()returns trigger language plpgsql security definer set search_path='' as $$declare i public.supply_items;begin
 select * into strict i from public.supply_items where id=new.item_id;
 new.purchase_unit:=coalesce(nullif(trim(new.purchase_unit),''),i.unit);new.use_unit:=coalesce(nullif(trim(new.use_unit),''),i.use_unit);
 if new.units_per_purchase is null then new.units_per_purchase:=i.units_per_purchase;end if;return new;
end$$;
alter table public.supply_lots alter column units_per_purchase drop default;
create trigger supply_pack_snapshot before insert on public.supply_lots for each row execute function private.supply_pack_snapshot();
-- Existing use validation still checks the allocation's own batch and finance permissions.
do $$declare d text;begin
 select pg_get_functiondef('public.supply_manage(jsonb,uuid)'::regprocedure)into d;
 d:=replace(d,'if not private.has_module(''feed'',true)then', 'if act<>''use''and not private.has_module(''feed'',true)then');
 d:=replace(d,'q<>round(q,3)','q<>round(q,9)');execute d;
end$$;
alter function public.supply_manage(jsonb,uuid)rename to supply_manage_v080;
revoke all on function public.supply_manage_v080(jsonb,uuid)from public,anon,authenticated;
create function public.supply_manage(p_data jsonb,p_request uuid)returns jsonb language plpgsql security definer set search_path='' as $$
declare p jsonb:=p_data;act text:=p->>'action';r jsonb;ret jsonb;l public.supply_lots;a public.supply_allocations;i public.supply_items;q numeric;factor numeric;chosen_unit text;u public.supply_usage;entry jsonb;lotid uuid;first_day date;last_day date;day date;days int;part numeric;results jsonb:='[]';begin
 perform private.feed_lock();
 if act in('use','use_event')then
 select * into strict a from public.supply_allocations where id=(p->>'id')::uuid;
 if not private.can_batch(a.batch_id,'farm',true)or not private.can_batch(a.batch_id,'finance',true)then raise exception 'NO_ACCESS';end if;
 else if not private.has_module('feed',true)then raise exception 'NO_ACCESS';end if;end if;
 ret:=private.request_result(p_request,'supply-units',p);if ret is not null then return ret;end if;
 if act='use_event'then
 first_day:=(p->>'log_date')::date;last_day:=coalesce(nullif(p->>'end_date','')::date,first_day);days:=last_day-first_day+1;q:=private.farm_num(p,'quantity');
 if days is null or days not between 1 and 31 or q<=0 or q<>round(q,6)then raise exception 'INVALID_EVENT_RANGE';end if;
 for day in select generate_series(first_day,last_day,'1 day')::date loop
 part:=case when p->>'quantity_mode'='total'then case when day=last_day then q-trunc(q/days,6)*(days-1)else trunc(q/days,6)end else q end;
 r:=public.supply_manage((p-'end_date')||jsonb_build_object('action','use','log_date',day,'quantity',part),gen_random_uuid());results:=results||jsonb_build_array(r);
 end loop;r:=jsonb_build_object('results',results);
 elsif act in('item','item_edit')then
 factor:=coalesce(nullif(p->>'units_per_purchase','')::numeric,1);chosen_unit:=coalesce(nullif(trim(p->>'use_unit'),''),nullif(trim(p->>'unit'),''));
 if act='item_edit'then select * into strict i from public.supply_items where id=(p->>'id')::uuid;factor:=coalesce(nullif(p->>'units_per_purchase','')::numeric,i.units_per_purchase);chosen_unit:=coalesce(chosen_unit,i.use_unit);end if;
 if factor::text in('NaN','Infinity','-Infinity')or factor<=0 or factor>1000000000 or factor<>round(factor,6)or length(chosen_unit)not between 1 and 40 then raise exception 'INVALID_CONVERSION';end if;
 r:=public.supply_manage_v080(p,gen_random_uuid());update public.supply_items set use_unit=chosen_unit,units_per_purchase=factor where id=(r->>'id')::uuid;
 elsif act='lot_units'then
 select * into strict l from public.supply_lots where id=(p->>'id')::uuid;
 if l.archived_used>0 or exists(select 1 from public.supply_usage su join public.supply_allocations sa on sa.id=su.allocation_id where sa.lot_id=l.id)then raise exception 'CONVERSION_LOCKED';end if;
 factor:=private.farm_num(p,'units_per_purchase');chosen_unit:=trim(p->>'use_unit');if factor<=0 or factor>1000000000 or factor<>round(factor,6)or length(coalesce(chosen_unit,''))not between 1 and 40 then raise exception 'INVALID_CONVERSION';end if;
 update public.supply_lots set use_unit=chosen_unit,units_per_purchase=factor where id=l.id;r:=jsonb_build_object('id',l.id);
 elsif act='use'then
 select * into strict l from public.supply_lots where id=a.lot_id;
 factor:=case when p->>'input_mode'='use'then l.units_per_purchase else 1 end;
 chosen_unit:=case when p->>'input_mode'='use'then l.use_unit else l.purchase_unit end;
 q:=private.farm_num(p,'quantity');if q<=0 or q<>round(q,6)then raise exception 'INVALID_QUANTITY';end if;
 r:=public.supply_manage_v080(p||jsonb_build_object('quantity',round(q/factor,9)),gen_random_uuid());
 select * into strict u from public.supply_usage where id=(r->>'id')::uuid;
 update public.supply_usage set entered_quantity=q,entered_unit=chosen_unit,conversion_factor=factor where id=u.id;
 update public.batch_events set event_type=case (select category from public.supply_items where id=l.item_id)when 'premix'then 'premix'else event_type end,title=coalesce(nullif(trim(left(p->>'title',200)),''),title),factors=factors||jsonb_build_object('entered_quantity',q,'entered_unit',chosen_unit,'purchase_quantity',u.quantity,'purchase_unit',l.purchase_unit,'conversion_factor',factor,'method',left(p->>'method',200),'bird_count',private.farm_num(p,'bird_count'))where id=u.event_id;
 else r:=public.supply_manage_v080(p,gen_random_uuid());end if;
 return private.finish_request(p_request,'supply-units',p,r);
end$$;
revoke all on function public.supply_manage(jsonb,uuid),private.supply_pack_snapshot()from public,anon,authenticated;
grant execute on function public.supply_manage(jsonb,uuid)to authenticated;
-- Safe, batch-scoped inventory projection also for users without central purchasing access.
create function public.batch_inventory()returns jsonb language sql stable security definer set search_path='' as $$
 select coalesce(jsonb_agg(jsonb_build_object('id',a.id,'batch_id',a.batch_id,'lot_id',l.id,'name',i.name,'category',i.category,'purchase_unit',l.purchase_unit,'use_unit',l.use_unit,'units_per_purchase',l.units_per_purchase,'log_date',a.log_date,'expiry_date',l.expiry_date,'lot_no',l.lot_no,'quantity',a.quantity,'returned',a.returned,'used',coalesce((select sum(quantity)from public.supply_usage where allocation_id=a.id),0),'stock',a.quantity-a.returned-coalesce((select sum(quantity)from public.supply_usage where allocation_id=a.id),0),'unit_cost',case when private.can_batch(a.batch_id,'finance')then l.unit_cost else null end)),'[]')from public.supply_allocations a join public.supply_lots l on l.id=a.lot_id join public.supply_invoices iv on iv.id=l.invoice_id join public.supply_items i on i.id=l.item_id where private.can_batch(a.batch_id,'farm')and iv.status='posted';
$$;
revoke all on function public.batch_inventory()from public,anon,authenticated;grant execute on function public.batch_inventory()to authenticated;
alter function private.farm_apply(jsonb)rename to farm_apply_v080;
create function private.farm_apply(p jsonb)returns jsonb language plpgsql security definer set search_path='' as $$begin
 if p->>'action'='event'and p->>'event_type'in('medicine','injection','vitamin','premix')then raise exception 'USE_BATCH_INVENTORY';end if;
 return private.farm_apply_v080(p);
end$$;
revoke all on function private.farm_apply(jsonb),private.farm_apply_v080(jsonb)from public,anon,authenticated;
-- Billing name is private per user; existing workspace branding remains the fallback for unset accounts.
create table public.user_branding(user_id uuid primary key references public.profiles,farm_name text not null check(length(trim(farm_name))between 1 and 200),version int not null default 1);
alter table public.user_branding enable row level security;revoke all on public.user_branding from public,anon,authenticated;grant select on public.user_branding to authenticated;grant all on public.user_branding to service_role;
create policy own_branding on public.user_branding for select to authenticated using(user_id=auth.uid());
alter function public.settings_manage(jsonb,uuid)rename to settings_manage_v080;
revoke all on function public.settings_manage_v080(jsonb,uuid)from public,anon,authenticated;
create function public.settings_manage(p_data jsonb,p_request uuid)returns jsonb language plpgsql security definer set search_path='' as $$declare r jsonb;v int;begin
 if p_data->>'action'<>'user_branding'then return public.settings_manage_v080(p_data,p_request);end if;
 if not exists(select 1 from public.profiles where id=auth.uid()and approved)then raise exception 'NO_ACCESS';end if;
 perform private.feed_lock();r:=private.request_result(p_request,'user-branding',p_data);if r is not null then return r;end if;
 select version into v from public.user_branding where user_id=auth.uid();if coalesce(v,0)is distinct from (p_data->>'version')::int then raise exception 'VERSION_CONFLICT';end if;
 insert into public.user_branding(user_id,farm_name)values(auth.uid(),trim(p_data->>'name'))on conflict(user_id)do update set farm_name=excluded.farm_name,version=public.user_branding.version+1;
 return private.finish_request(p_request,'user-branding',p_data,jsonb_build_object('saved',true));
end$$;
revoke all on function public.settings_manage(jsonb,uuid)from public,anon,authenticated;grant execute on function public.settings_manage(jsonb,uuid)to authenticated;
alter table public.sales add column billing_farm_name text;
create function private.sale_farm_snapshot()returns trigger language plpgsql security definer set search_path='' as $$declare owner_id uuid;begin
 select owner_user_id into owner_id from public.batches where id=new.batch_id;
 new.billing_farm_name:=coalesce((select farm_name from public.user_branding where user_id=owner_id),(select farm_name from public.user_branding where user_id=auth.uid()),(select farm_name from public.workspace_branding where id=true),'ฟาร์ม');return new;
end$$;
create trigger sale_farm_snapshot before insert on public.sales for each row execute function private.sale_farm_snapshot();
revoke all on function private.sale_farm_snapshot()from public,anon,authenticated;

commit;
notify pgrst,'reload schema';
