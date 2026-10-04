-- Ducky 0.3.0. NEW V2 project only, after 001, 003, 004. Additive, atomic.
begin;
do $$ begin
 if to_regclass('public.feed_requests') is null then raise exception 'RUN_004_FIRST';end if;
 if to_regclass('public.price_bindings') is not null then raise exception '005_ALREADY_INSTALLED';end if;
 if exists(select 1 from public.price_items a join public.price_items b on a.price_set_id=b.price_set_id and a.grade=b.grade and a.id<b.id and daterange(a.valid_from,a.valid_to,'[]')&&daterange(b.valid_from,b.valid_to,'[]')) then raise exception 'EXISTING_PRICE_OVERLAP_NEEDS_MAPPING';end if;
end $$;
alter table public.price_sets add column version int not null default 1,
 add column is_active boolean not null default true,add column is_default boolean not null default false,
 add column scope_type text not null default 'system' check(scope_type in('system','user')),
 add column remark text not null default '',add column updated_at timestamptz not null default now();
create unique index one_default_egg_price on public.price_sets((true)) where is_default and is_active;
alter table public.price_items add column display_name text not null default '',add column sort_order int not null default 0;
update public.price_items set display_name=grade;
alter table public.batches add column owner_user_id uuid references public.profiles;
alter table public.batches alter column owner_user_id set default auth.uid();
create table public.price_bindings(
 id uuid primary key default gen_random_uuid(),price_set_id uuid not null references public.price_sets,
 batch_id uuid references public.batches,housing_id uuid references public.housing_units,user_id uuid references public.profiles,
 target_type text generated always as(case when batch_id is not null then 'batch' when housing_id is not null then 'housing' else 'user' end)stored,
 target_id uuid generated always as(coalesce(batch_id,housing_id,user_id))stored,
 is_active boolean not null default true,version int not null default 1,
 created_at timestamptz not null default now(),ended_at timestamptz,
 check(num_nonnulls(batch_id,housing_id,user_id)=1)
);
create unique index one_current_price_per_target on public.price_bindings(target_type,target_id)where is_active;
create index on public.price_items(price_set_id,valid_from,valid_to);
alter table public.price_bindings enable row level security;
revoke all on public.price_bindings from public,anon,authenticated;
grant all on public.price_bindings to service_role;
revoke insert,update,delete on public.price_sets,public.price_items from authenticated;
create trigger audit after insert or update or delete on public.price_sets for each row execute function private.audit_change();
create trigger audit after insert or update or delete on public.price_items for each row execute function private.audit_change();
create trigger audit after insert or update or delete on public.price_bindings for each row execute function private.audit_change();

create function public.price_workspace()returns jsonb language plpgsql stable security definer set search_path='' as $$
begin
 if not private.has_module('prices')then return jsonb_build_object('can_read',false,'can_write',false);end if;
 return jsonb_build_object('can_read',true,'can_write',private.has_module('prices',true),
 'sets',(select coalesce(jsonb_agg(to_jsonb(s)order by s.name,s.id),'[]')from public.price_sets s),
 'items',(select coalesce(jsonb_agg(to_jsonb(i)order by i.valid_from,i.sort_order,i.grade),'[]')from public.price_items i),
 'bindings',(select coalesce(jsonb_agg(to_jsonb(b)order by b.created_at,b.id),'[]')from public.price_bindings b),
 'batches',(select coalesce(jsonb_agg(jsonb_build_object('id',id,'name',name,'status',status,'housing_id',housing_id,'owner_user_id',owner_user_id)order by name,id),'[]')from public.batches where species_id='duck'),
 'housing',(select coalesce(jsonb_agg(jsonb_build_object('id',id,'name',name)order by name,id),'[]')from public.housing_units),
 'users',(select coalesce(jsonb_agg(jsonb_build_object('id',id,'name',display_name)order by display_name,id),'[]')from public.profiles where approved));
end $$;

create function public.price_manage(p_data jsonb,p_request uuid)returns jsonb language plpgsql security definer set search_path='' as $$
declare act text:=p_data->>'action';sid uuid:=(p_data->>'id')::uuid;s public.price_sets;ret jsonb;
 d date;it jsonb;arr jsonb;target jsonb;kind text;tid uuid;old public.price_bindings;gid uuid;v int;cnt int;
begin
 if not private.has_module('prices',true)then raise exception 'NO_ACCESS';end if;
 perform pg_advisory_xact_lock(824621904);
 ret:=private.request_result(p_request,'price',p_data);if ret is not null then return ret;end if;
 select * into s from public.price_sets where id=sid;
 if found then
  if s.species_id is not null and s.species_id<>'duck' then raise exception 'INVALID_PRICE_SPECIES';end if;
  if s.version is distinct from (p_data->>'version')::int then raise exception 'VERSION_CONFLICT';end if;
 else
  if act<>'save' or coalesce((p_data->>'version')::int,0)<>0 then raise exception 'PRICE_SET_NOT_FOUND';end if;
 end if;
 if act='save' then
  if s.id is not null and not s.is_active then raise exception 'PRICE_SET_ARCHIVED';end if;
  d:=(p_data->>'valid_from')::date;arr:=p_data->'items';
  if sid is null or d is null or length(trim(coalesce(p_data->>'name','')))=0 or jsonb_typeof(arr) is distinct from 'array' then raise exception 'PRICE_DETAILS_REQUIRED';end if;
  if jsonb_array_length(arr)<1 or jsonb_array_length(arr)>200 then raise exception 'PRICE_ITEMS_REQUIRED';end if;
  if exists(select 1 from public.price_items where price_set_id=sid and valid_from>d)then raise exception 'PRICE_DATE_BEFORE_LATEST';end if;
  if exists(select 1 from jsonb_array_elements(arr)x group by lower(trim(x->>'grade'))having count(*)>1)then raise exception 'DUPLICATE_PRICE_ITEM';end if;
  for it in select value from jsonb_array_elements(arr)loop
   if length(trim(coalesce(it->>'grade','')))=0 or (it->>'price') is null or (it->>'price')::numeric::text in('NaN','Infinity','-Infinity') or (it->>'price')::numeric<0 or (it->>'price')::numeric<>round((it->>'price')::numeric,4) then raise exception 'INVALID_PRICE_ITEM';end if;
  end loop;
  if p_data->>'scope_type' not in('system','user')or p_data->>'scope_type' is null then raise exception 'INVALID_SCOPE';end if;
  if coalesce((p_data->>'is_default')::boolean,false)and p_data->>'scope_type'<>'system' then raise exception 'DEFAULT_MUST_BE_SYSTEM';end if;
  if coalesce((p_data->>'is_default')::boolean,false)then update public.price_sets set is_default=false,version=version+1,updated_at=now()where is_default and id<>sid;end if;
  insert into public.price_sets(id,name,species_id,scope_type,remark,is_default)
  values(sid,trim(p_data->>'name'),'duck',p_data->>'scope_type',coalesce(p_data->>'remark',''),coalesce((p_data->>'is_default')::boolean,false))
  on conflict(id)do update set name=excluded.name,scope_type=excluded.scope_type,remark=excluded.remark,is_default=excluded.is_default,version=public.price_sets.version+1,updated_at=now();
  -- A complete dated snapshot. Earlier dates retained; same-day correction audited.
  delete from public.price_items where price_set_id=sid and valid_from=d;
  update public.price_items set valid_to=d-1 where price_set_id=sid and valid_from<d and(valid_to is null or valid_to>=d);
  cnt:=0;
  for it in select value from jsonb_array_elements(arr)loop
   insert into public.price_items(price_set_id,grade,display_name,price,sort_order,valid_from)
   values(sid,trim(it->>'grade'),coalesce(nullif(trim(it->>'display_name'),''),trim(it->>'grade')),(it->>'price')::numeric,cnt,d);cnt:=cnt+1;
  end loop;
 elsif act='archive' then
  update public.price_sets set is_active=false,is_default=false,version=version+1,updated_at=now()where id=sid;
  update public.price_bindings set is_active=false,version=version+1,ended_at=now()where price_set_id=sid and is_active;
 elsif act='restore' then
  update public.price_sets set is_active=true,version=version+1,updated_at=now()where id=sid;
 elsif act='bind' then
  if not s.is_active then raise exception 'PRICE_SET_ARCHIVED';end if;
  arr:=p_data->'targets';if jsonb_typeof(arr) is distinct from 'array' then raise exception 'TARGET_REQUIRED';end if;
  if jsonb_array_length(arr)<1 or jsonb_array_length(arr)>500 then raise exception 'TARGET_REQUIRED';end if;
  if exists(select 1 from jsonb_array_elements(arr)x group by x->>'type',x->>'id' having count(*)>1)then raise exception 'DUPLICATE_TARGET';end if;
  for target in select value from jsonb_array_elements(arr)loop
   kind:=target->>'type';tid:=(target->>'id')::uuid;
   if kind='batch' then
    if not exists(select 1 from public.batches where id=tid and species_id='duck' and status='active')then raise exception 'INVALID_DUCK_BATCH';end if;
   elsif kind='housing' then
    if not exists(select 1 from public.housing_units where id=tid)then raise exception 'TARGET_NOT_FOUND';end if;
   elsif kind='user' then
    if not exists(select 1 from public.profiles where id=tid and approved)then raise exception 'TARGET_NOT_FOUND';end if;
   else raise exception 'INVALID_TARGET_TYPE';end if;
   old:=null;select * into old from public.price_bindings where target_type=kind and target_id=tid and is_active;
   if old.id is distinct from nullif(target->>'expected_id','')::uuid or coalesce(old.version,0)<>coalesce((target->>'expected_version')::int,0)then raise exception 'BINDING_CHANGED';end if;
   if old.id is not null and old.price_set_id<>sid then
    if not coalesce((p_data->>'replace_existing')::boolean,false)then raise exception 'TARGET_ALREADY_BOUND';end if;
    update public.price_sets set version=version+1,updated_at=now()where id=old.price_set_id;
   end if;
   if old.id is null or old.price_set_id<>sid then
    update public.price_bindings set is_active=false,version=version+1,ended_at=now()where id=old.id;
    insert into public.price_bindings(price_set_id,batch_id,housing_id,user_id)values(sid,case when kind='batch' then tid end,case when kind='housing' then tid end,case when kind='user' then tid end);
   end if;
  end loop;
  update public.price_sets set version=version+1,updated_at=now()where id=sid;
 elsif act='unbind' then
  gid:=(p_data->>'binding_id')::uuid;
  update public.price_bindings set is_active=false,version=version+1,ended_at=now()where id=gid and price_set_id=sid and is_active and version=(p_data->>'binding_version')::int;
  if not found then raise exception 'BINDING_CHANGED';end if;
  update public.price_sets set version=version+1,updated_at=now()where id=sid;
 else raise exception 'INVALID_PRICE_ACTION';end if;
 select to_jsonb(p)into ret from public.price_sets p where id=sid;
 return private.finish_request(p_request,'price',p_data,ret);
end $$;

create function public.price_resolve(p_batch uuid,p_date date default current_date)returns jsonb language plpgsql stable security definer set search_path='' as $$
declare b public.batches;s public.price_sets;sid uuid;origin text;
begin
 if not(private.has_module('prices')or private.can_batch(p_batch,'farm')or private.can_batch(p_batch,'finance'))then raise exception 'NO_ACCESS';end if;
 select * into b from public.batches where id=p_batch;
 if not found or b.species_id<>'duck' or p_date is null then raise exception 'INVALID_DUCK_BATCH';end if;
 select x.price_set_id,x.target_type into sid,origin from public.price_bindings x join public.price_sets p on p.id=x.price_set_id and p.is_active
 where x.is_active and(x.batch_id=b.id or x.housing_id=b.housing_id or x.user_id=b.owner_user_id or x.user_id=auth.uid())
 order by case when x.batch_id=b.id then 1 when x.housing_id=b.housing_id then 2 when x.user_id=b.owner_user_id then 3 else 4 end limit 1;
 if sid is null then select id into sid from public.price_sets where is_active and is_default and scope_type='system';origin:='default';end if;
 select * into s from public.price_sets where id=sid;
 return jsonb_build_object('price_set',case when s.id is null then null else to_jsonb(s)end,'source',origin,'items',(select coalesce(jsonb_agg(to_jsonb(i)order by sort_order,grade),'[]')from public.price_items i where price_set_id=sid and valid_from<=p_date and(valid_to is null or valid_to>=p_date)));
end $$;
revoke all on function public.price_workspace(),public.price_manage(jsonb,uuid),public.price_resolve(uuid,date) from public,anon;
grant execute on function public.price_workspace(),public.price_manage(jsonb,uuid),public.price_resolve(uuid,date) to authenticated;
commit;
