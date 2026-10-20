-- Apply after migrations 001–030. Equipment persists by housing_id, not batch_id.
begin;
create table if not exists public.twin_equipment(
 id uuid primary key default gen_random_uuid(),housing_id uuid not null references public.housing_units(id),
 name text not null check(length(name) between 1 and 120),kind text not null default 'other',
 status text not null default 'unknown' check(status in ('unknown','ready','maintenance','off')),
 sensor_key text,unit text not null default '',note text not null default '',version integer not null default 1,
 updated_at timestamptz not null default now(),unique(housing_id,sensor_key));
create table if not exists public.twin_sensor_latest(
 equipment_id uuid primary key references public.twin_equipment(id) on delete cascade,
 value numeric not null,status text not null check(status in ('ok','warning','alarm','offline')),observed_at timestamptz not null);
alter table public.twin_equipment enable row level security;
alter table public.twin_sensor_latest enable row level security;
revoke all on public.twin_equipment,public.twin_sensor_latest from anon,authenticated;
create or replace function public.twin_equipment_manage(p_batch uuid,p_action text default 'list',p_data jsonb default '{}') returns jsonb
language plpgsql security definer set search_path='' as $$
declare h uuid; e public.twin_equipment; write_ok boolean; target uuid;
begin
 if not private.can_batch(p_batch,'farm') then raise exception 'NO_ACCESS';end if;
 select housing_id into h from public.batches where id=p_batch for update;
 write_ok:=private.can_batch(p_batch,'farm',true) and private.feature_allowed('farm.batches',true);
 if p_action<>'list' and not write_ok then raise exception 'NO_WRITE_ACCESS';end if;
 if p_action='create_housing' then
  if h is not null then raise exception 'ALREADY_ASSIGNED';end if;
  if length(trim(coalesce(p_data->>'name','')))=0 then raise exception 'NAME_REQUIRED';end if;
  insert into public.housing_units(name) values(left(trim(p_data->>'name'),120)) returning id into h;
  update public.batches set housing_id=h where id=p_batch;
 elsif p_action='bind_housing' then
  target:=(p_data->>'housing_id')::uuid;
  if not exists(select 1 from public.batches b where b.housing_id=target and private.can_batch(b.id,'farm',true)) then raise exception 'NO_HOUSING_ACCESS';end if;
  update public.batches set housing_id=target where id=p_batch;h:=target;
 elsif p_action in ('save','delete') then
  if h is null then raise exception 'SELECT_HOUSING_FIRST';end if;
  if p_data->>'id' is not null then
   select * into e from public.twin_equipment where id=(p_data->>'id')::uuid and housing_id=h for update;
   if not found then raise exception 'NOT_FOUND';end if;
   if e.version<>coalesce((p_data->>'version')::integer,0) then raise exception 'VERSION_CONFLICT';end if;
  end if;
  if p_action='delete' then
   if e.id is null then raise exception 'NOT_FOUND';end if;
   delete from public.twin_equipment where id=e.id;
  elsif e.id is null then
   insert into public.twin_equipment(housing_id,name,kind,status,sensor_key,unit,note)
   values(h,trim(p_data->>'name'),left(coalesce(p_data->>'kind','other'),50),coalesce(p_data->>'status','unknown'),nullif(trim(p_data->>'sensor_key'),''),left(coalesce(p_data->>'unit',''),30),left(coalesce(p_data->>'note',''),1000));
  else
   if e.sensor_key is distinct from nullif(trim(p_data->>'sensor_key'),'') or e.unit is distinct from left(coalesce(p_data->>'unit',''),30) then delete from public.twin_sensor_latest where equipment_id=e.id;end if;
   update public.twin_equipment set name=trim(p_data->>'name'),kind=left(coalesce(p_data->>'kind','other'),50),status=coalesce(p_data->>'status','unknown'),sensor_key=nullif(trim(p_data->>'sensor_key'),''),unit=left(coalesce(p_data->>'unit',''),30),note=left(coalesce(p_data->>'note',''),1000),version=version+1,updated_at=now() where id=e.id;
  end if;
 elsif p_action<>'list' then raise exception 'INVALID_ACTION';end if;
 return jsonb_build_object('housingId',h,'housingName',(select name from public.housing_units where id=h),'canWrite',write_ok,'items',(select coalesce(jsonb_agg(to_jsonb(d)||jsonb_build_object('reading',to_jsonb(r)) order by d.name),'[]') from public.twin_equipment d left join public.twin_sensor_latest r on r.equipment_id=d.id where d.housing_id=h),'housingOptions',(select coalesce(jsonb_agg(to_jsonb(q)),'[]') from (select distinct u.id,u.name from public.housing_units u join public.batches b on b.housing_id=u.id where private.can_batch(b.id,'farm',true))q));
end $$;
revoke all on function public.twin_equipment_manage(uuid,text,jsonb) from public,anon;
grant execute on function public.twin_equipment_manage(uuid,text,jsonb) to authenticated;
-- Only trusted server ingestion may publish observations; never put its key in browser firmware/UI.
create or replace function public.twin_sensor_ingest(p_equipment uuid,p_value numeric,p_status text,p_observed_at timestamptz) returns void
language plpgsql security definer set search_path='' as $$
begin
 if p_value is null or p_value::text in ('NaN','Infinity','-Infinity') or p_observed_at is null or p_observed_at>now()+interval '5 minutes' then raise exception 'INVALID_OBSERVATION';end if;
 insert into public.twin_sensor_latest(equipment_id,value,status,observed_at) values(p_equipment,p_value,p_status,p_observed_at)
 on conflict(equipment_id) do update set value=excluded.value,status=excluded.status,observed_at=excluded.observed_at where excluded.observed_at>public.twin_sensor_latest.observed_at;
end $$;
revoke all on function public.twin_sensor_ingest(uuid,numeric,text,timestamptz) from public,anon,authenticated;
grant execute on function public.twin_sensor_ingest(uuid,numeric,text,timestamptz) to service_role;
commit;
