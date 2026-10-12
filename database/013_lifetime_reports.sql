-- 0.9.0: lifetime reporting facts, no buyer/contact/cash balance exposed to bearer reports.
begin;
create function private.lifetime_report(b uuid)returns jsonb language plpgsql security definer set search_path='' as $$declare bt public.batches;last_day date;begin
 select * into strict bt from public.batches where id=b;last_day:=least(coalesce(bt.end_date,'9999-12-31'),(now()at time zone 'Asia/Bangkok')::date);
 return jsonb_build_object('batch',jsonb_build_object('name',bt.name,'start_date',bt.start_date,'end_date',bt.end_date,'species_id',bt.species_id,'initial_qty',bt.initial_qty,'purchase_cost',bt.purchase_cost),'from',bt.start_date,'to',greatest(bt.start_date,last_day),'generated_at',now(),
 'eggs',coalesce((select jsonb_agg(jsonb_build_object('date',log_date,'total',total,'broken',broken,'big',big,'small',small,'cracked',cracked,'live_count',live_count)order by log_date)from public.egg_daily where batch_id=b and log_date<=last_day),'[]'),
 'feed',coalesce((select jsonb_agg(jsonb_build_object('date',c.log_date,'feed_name',a.feed_name,'source_lot',o.manufacturer_lot,'formula',o.formula,'issued',c.issued,'leftover',c.leftover,'consumed',c.consumed,'waste',c.waste,'kg_per_unit',c.kg_per_unit,'unit',c.unit,'cost',c.cost)order by c.log_date,c.id)from public.feed_consumption c join public.feed_allocations a on a.id=c.allocation_id join public.feed_orders o on o.id=a.order_id where c.batch_id=b and c.log_date<=last_day),'[]'),
 'sales',coalesce((select jsonb_agg(jsonb_build_object('date',sale_date,'type',sale_type,'total',total)order by sale_date)from public.sales where batch_id=b and status='posted'and sale_date<=last_day),'[]'),
 'events',coalesce((select jsonb_agg(jsonb_build_object('date',e.start_date,'type',e.event_type,'title',e.title,'cost',coalesce((select sum(amount)from public.event_expenses where event_id=e.id),0))order by e.start_date)from public.batch_events e where batch_id=b and e.start_date<=last_day),'[]'),
 'movements',coalesce((select jsonb_agg(jsonb_build_object('date',log_date,'kind',kind,'qty',qty)order by log_date)from public.animal_movements where batch_id=b and log_date<=last_day),'[]'),
 'other_costs',coalesce((select jsonb_agg(jsonb_build_object('date',cash_date,'cost',-amount)order by cash_date)from public.batch_cash where batch_id=b and kind='expense'and amount<0 and reference_id is null and cash_date<=last_day),'[]'));
end$$;
create or replace function public.report_data(p_batch uuid,p_from date,p_to date)returns jsonb language plpgsql security definer set search_path='' as $$begin
 if not private.can_batch(p_batch,'farm')or not private.can_batch(p_batch,'finance')then raise exception 'NO_ACCESS';end if;
 return private.report_snapshot(p_batch,p_from,p_to)||jsonb_build_object('lifetime',private.lifetime_report(p_batch));
end$$;
-- Do not expand the scope of links that were issued before this migration.
alter table public.access_links add column lifetime_scope boolean not null default false;
alter function public.access_manage(jsonb,uuid)rename to access_manage_v080;
revoke all on function public.access_manage_v080(jsonb,uuid)from public,anon,authenticated;
create function public.access_manage(p_data jsonb,p_request uuid)returns jsonb language plpgsql security definer set search_path='' as $$declare r jsonb;begin
 r:=public.access_manage_v080(p_data,p_request);
 if p_data->>'action'='create'then update public.access_links set lifetime_scope=coalesce((p_data->>'lifetime_scope')::boolean,false)where id=(r->>'id')::uuid and created_by=auth.uid();end if;return r;
end$$;
alter function public.access_read(text,date)rename to access_read_v080;
revoke all on function public.access_read_v080(text,date)from public,anon,authenticated;
create function public.access_read(p_token text,p_date date default null)returns jsonb language plpgsql security definer set search_path='' as $$declare r jsonb;l public.access_links;begin
 r:=public.access_read_v080(p_token,p_date);l:=private.access_valid(p_token);
 if l.kind='display'and l.lifetime_scope then r:=jsonb_set(r,'{snapshot,lifetime}',private.lifetime_report(l.batch_id));end if;return r;
end$$;
revoke all on function private.lifetime_report(uuid),public.access_manage(jsonb,uuid),public.access_read(text,date)from public,anon,authenticated;
grant execute on function public.access_manage(jsonb,uuid)to authenticated;
grant execute on function public.access_read(text,date)to anon,authenticated;
commit;
notify pgrst,'reload schema';
