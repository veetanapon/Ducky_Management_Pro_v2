-- 0.10: module navigation + server-enforced optional feature restrictions.
begin;
create table public.feature_access(user_id uuid not null references public.profiles,feature text not null,level text not null check(level in('none','read','write')),primary key(user_id,feature));
create table public.feature_catalog(feature text primary key,module text not null,label text not null);
insert into public.feature_catalog values
('farm.batches','farm','ข้อมูลล็อต'),('farm.eggs','farm','ไข่รายวัน'),('farm.sales','farm','บิลขาย'),('farm.inventory','farm','คลังและอาหาร'),('farm.events','farm','เหตุการณ์'),('farm.report','farm','รายงานสรุป'),('farm.links','farm','จัดการ link & LIFF'),('finance.cash','finance','บัญชีรับจ่าย'),('finance.wallets','finance','กระเป๋าเงิน'),('finance.plans','finance','สมมติฐานและแผน'),('finance.tax','finance','บันทึกภาษี');
alter table public.feature_access add foreign key(feature)references public.feature_catalog;
alter table public.feature_access enable row level security;revoke all on public.feature_access from public,anon,authenticated;grant select on public.feature_access to authenticated;grant all on public.feature_access to service_role;
create policy own_features on public.feature_access for select to authenticated using(user_id=auth.uid()or private.is_admin());
create function private.feature_allowed(f text,w boolean default false)returns boolean language sql stable security definer set search_path='' as $$
select private.is_admin()or(private.has_module((select module from public.feature_catalog where feature=f),w)and coalesce((select case when w then level='write'else level in('read','write')end from public.feature_access where user_id=auth.uid()and feature=f),true));
$$;
revoke all on function private.feature_allowed(text,boolean)from public,anon;grant execute on function private.feature_allowed(text,boolean)to authenticated;
alter function public.operating_context()rename to operating_context_v090;
revoke all on function public.operating_context_v090()from public,anon,authenticated;
create function public.operating_context()returns jsonb language sql stable security definer set search_path='' as $$
select public.operating_context_v090()||jsonb_build_object('funds',case when private.feature_allowed('finance.cash')then public.operating_context_v090()->'funds'else(select coalesce(jsonb_agg(value-'balance'),'[]')from jsonb_array_elements(public.operating_context_v090()->'funds'))end,'modules',(select jsonb_object_agg(m,jsonb_build_object('read',private.has_module(m),'write',private.has_module(m,true)))from unnest(array['farm','feed','prices','analytics','finance','approvals','admin'])m),'features',(select jsonb_object_agg(feature,jsonb_build_object('read',private.feature_allowed(feature),'write',private.feature_allowed(feature,true)))from public.feature_catalog),'batch_rights',(select coalesce(jsonb_object_agg(id,jsonb_build_object('farm',private.can_batch(id,'farm'),'analytics',private.can_batch(id,'analytics'),'finance',private.can_batch(id,'finance'))),'{}')from public.batches where private.can_batch(id,'farm')or private.can_batch(id,'analytics')or private.can_batch(id,'finance')));
$$;
revoke all on function public.operating_context()from public,anon;grant execute on function public.operating_context()to authenticated;
-- Include feature restrictions in the optimistic fingerprint.
do $$declare d text;begin select pg_get_functiondef('private.admin_user_snapshot(uuid)'::regprocedure)into d;
d:=replace(d,'''profile'',jsonb_build_object','''features'',coalesce((select jsonb_agg(to_jsonb(f)order by feature)from public.feature_access f where user_id=uid),''[]''),''profile'',jsonb_build_object');execute d;end$$;
alter function public.admin_manage(jsonb,uuid)rename to admin_manage_v090;
revoke all on function public.admin_manage_v090(jsonb,uuid)from public,anon,authenticated;
create function public.admin_manage(p_data jsonb,p_request uuid)returns jsonb language plpgsql security definer set search_path='' as $$declare r jsonb;x jsonb;begin
if not private.is_admin()then raise exception 'NO_ACCESS';end if;
perform private.feed_lock();r:=private.request_result(p_request,'admin-feature',p_data);if r is not null then return r;end if;
r:=public.admin_manage_v090(p_data,gen_random_uuid());
if p_data?'features'then delete from public.feature_access where user_id=(p_data->>'user_id')::uuid;for x in select value from jsonb_array_elements(p_data->'features')loop insert into public.feature_access values((p_data->>'user_id')::uuid,x->>'feature',x->>'level');end loop;end if;
return private.finish_request(p_request,'admin-feature',p_data,r);end$$;
revoke all on function public.admin_manage(jsonb,uuid)from public,anon;grant execute on function public.admin_manage(jsonb,uuid)to authenticated;
-- Restrictive policies supplement existing per-batch policies, never replace them.
do $$declare t text;f text;begin
for t,f in select * from(values('egg_daily','farm.eggs'),('sales','farm.sales'),('sale_items','farm.sales'),('farm_pending','farm.batches'),('feed_consumption','farm.inventory'),('batch_events','farm.events'),('batch_plans','finance.plans'))v(t,f)loop
if to_regclass('public.'||t)is not null then execute format('create policy feature_read on public.%I as restrictive for select to authenticated using(private.feature_allowed(%L))',t,f);end if;end loop;end$$;
create policy feature_plan_insert on public.batch_plans as restrictive for insert to authenticated with check(private.feature_allowed('finance.plans',true));
create policy feature_plan_update on public.batch_plans as restrictive for update to authenticated using(private.feature_allowed('finance.plans',true))with check(private.feature_allowed('finance.plans',true));
alter function private.farm_apply(jsonb)rename to farm_apply_v090;
create function private.farm_apply(p jsonb)returns jsonb language plpgsql security definer set search_path='' as $$declare act text:=p->>'action';f text;row public.farm_pending;begin
if act like 'pending_%'then
 if act in('pending_save','pending_bulk')then act:=case p->>'kind'when 'prebill'then 'sale'when 'prefeed'then 'feed'else 'egg'end;
 else select * into row from public.farm_pending where id=(p->>'id')::uuid;act:=case row.kind when 'prebill'then 'sale'when 'prefeed'then 'feed'else 'egg'end;end if;
end if;
f:=case when act in('sale','sale_void')then 'farm.sales'when act='egg'then 'farm.eggs'when act in('feed','feed_return')then 'farm.inventory'when act='event'then 'farm.events'else 'farm.batches'end;
if not private.feature_allowed(f,true)then raise exception 'NO_FEATURE_ACCESS: %',f;end if;
return private.farm_apply_v090(p);end$$;
revoke all on function private.farm_apply(jsonb),private.farm_apply_v090(jsonb)from public,anon,authenticated;
-- Report/link RPCs are security definers; enforce features at each entry point.
do $$declare n text;sig text;d text;f text;begin
for n,sig,f in select * from(values('report_data','uuid,date,date','farm.report'),('access_manage','jsonb,uuid','farm.links'),('access_list','uuid','farm.links'),('report_manage','jsonb,uuid','farm.links'),('report_link_list','uuid','farm.links'))v(n,sig,f)loop
 select pg_get_functiondef(('public.'||n||'('||sig||')')::regprocedure)into d;
 d:=regexp_replace(d,'\mbegin\M',format('begin if not private.feature_allowed(%L,%L)then raise exception ''NO_FEATURE_ACCESS'';end if;',f,n in('access_manage','report_manage')),'i');execute d;
end loop;end$$;
-- Legacy RPCs remain callable; gate them as strictly as the current screens.
do $$declare d text;begin
select pg_get_functiondef('public.save_egg(uuid,date,integer,integer,integer,integer)'::regprocedure)into d;
d:=regexp_replace(d,'\mbegin\M','begin if not private.feature_allowed(''farm.eggs'',true)then raise exception ''NO_FEATURE_ACCESS'';end if;','i');execute d;
select pg_get_functiondef('public.cash_record(jsonb,uuid)'::regprocedure)into d;
d:=regexp_replace(d,'\mbegin\M','begin if not private.feature_allowed(''finance.cash'',true)then raise exception ''NO_FEATURE_ACCESS'';end if;','i');execute d;
select pg_get_functiondef('public.supply_manage(jsonb,uuid)'::regprocedure)into d;
d:=regexp_replace(d,'\mbegin\M','begin if p_data->>''action'' in(''use'',''use_event'')and not private.feature_allowed(''farm.events'',true)then raise exception ''NO_FEATURE_ACCESS'';end if;','i');execute d;
end$$;
create policy feature_event_insert on public.batch_events as restrictive for insert to authenticated with check(private.feature_allowed('farm.events',true));
create policy feature_event_update on public.batch_events as restrictive for update to authenticated using(private.feature_allowed('farm.events',true))with check(private.feature_allowed('farm.events',true));
-- An analytics-only grant can read production facts without granting a farm menu.
do $$declare t text;f text;begin
for t,f in select * from(values('egg_daily','farm.eggs'),('feed_consumption','farm.inventory'),('batch_events','farm.events'))v(t,f)loop
execute format('drop policy feature_read on public.%I',t);
execute format('create policy feature_read on public.%I as restrictive for select to authenticated using(private.feature_allowed(%L)or(not private.has_module(''farm'')and private.can_batch(batch_id,''analytics'')))',t,f);
end loop;end$$;
drop policy feature_read on public.farm_pending;
create policy feature_read on public.farm_pending as restrictive for select to authenticated using(private.feature_allowed(case kind when 'prebill'then 'farm.sales'else 'farm.inventory'end));
create policy feature_cash_read on public.batch_cash as restrictive for select to authenticated using(private.feature_allowed('finance.cash'));
create function public.analytics_data(p_batch uuid)returns jsonb language plpgsql stable security definer set search_path='' as $$begin
if not private.can_batch(p_batch,'analytics')then raise exception 'NO_ACCESS';end if;
return private.lifetime_report(p_batch);end$$;
revoke all on function public.analytics_data(uuid)from public,anon;grant execute on function public.analytics_data(uuid)to authenticated;
commit;notify pgrst,'reload schema';
