-- Personal cash-flow scenarios. No writes to cash, sales, stock or supplier ledgers.
begin;
create table if not exists private.cashflow_plans(
 user_id uuid primary key references public.profiles on delete cascade,
 version integer not null default 1,
 document jsonb not null,
 updated_at timestamptz not null default now()
);
revoke all on private.cashflow_plans from public,anon,authenticated;
create or replace function public.cashflow_plan_read()returns jsonb language plpgsql security definer set search_path='' as $$begin
 if not private.feature_allowed('finance.plans')then raise exception 'NO_ACCESS';end if;
 return coalesce((select jsonb_build_object('version',version,'document',document)from private.cashflow_plans where user_id=auth.uid()),'{"version":0,"document":null}'::jsonb);
end$$;
create or replace function public.cashflow_plan_save(p_data jsonb,p_request uuid)returns jsonb language plpgsql security definer set search_path='' as $$
declare doc jsonb:=p_data->'document';item jsonb;ret jsonb;v integer;begin
 if not private.feature_allowed('finance.plans',true)then raise exception 'NO_ACCESS';end if;
 perform private.feed_lock();ret:=private.request_result(p_request,'cashflow_plan',p_data);if ret is not null then return ret;end if;
 if jsonb_typeof(doc)is distinct from 'object'or jsonb_typeof(doc->'settings')is distinct from 'object'or jsonb_typeof(doc->'entries')is distinct from 'array'then raise exception 'INVALID_PLAN';end if;
 if octet_length(doc::text)>500000 or jsonb_array_length(doc->'entries')>1000 then raise exception 'PLAN_TOO_LARGE';end if;
 if doc->'settings'->>'start' is null or doc->'settings'->>'end' is null or (doc->'settings'->>'end')::date<(doc->'settings'->>'start')::date or (doc->'settings'->>'end')::date-(doc->'settings'->>'start')::date>365 then raise exception 'INVALID_RANGE';end if;
 for item in select value from jsonb_array_elements(doc->'entries')loop
 if jsonb_typeof(item)is distinct from 'object'or coalesce(item->>'id','')=''or length(item->>'id')>300 or coalesce(item->>'kind','')not in('income','expense','payment','order')or coalesce(item->>'status','')not in('planned','actual')or item->>'date' is null or coalesce(item->>'amount','')!~'^[0-9]+([.][0-9]+)?$'then raise exception 'INVALID_ENTRY';end if;
 perform (item->>'date')::date;
 if (item->>'amount')::numeric>1000000000000 or length(coalesce(item->>'title',''))>200 then raise exception 'INVALID_ENTRY';end if;
 if item->>'status'='actual'and (item->>'date')::date>(now()at time zone'Asia/Bangkok')::date then raise exception 'ACTUAL_DATE_IN_FUTURE';end if;
 end loop;
 if exists(select 1 from jsonb_array_elements(doc->'entries')x group by x->>'id' having count(*)>1)then raise exception 'DUPLICATE_ENTRY';end if;
 select version into v from private.cashflow_plans where user_id=auth.uid()for update;
 if coalesce(v,0)<>coalesce((p_data->>'version')::integer,-1)then raise exception 'VERSION_CONFLICT';end if;
 insert into private.cashflow_plans(user_id,version,document)values(auth.uid(),1,doc)on conflict(user_id)do update set version=cashflow_plans.version+1,document=excluded.document,updated_at=now()returning version into v;
 return private.finish_request(p_request,'cashflow_plan',p_data,jsonb_build_object('version',v,'saved',true));
end$$;
revoke all on function public.cashflow_plan_read(),public.cashflow_plan_save(jsonb,uuid)from public,anon,authenticated;
grant execute on function public.cashflow_plan_read(),public.cashflow_plan_save(jsonb,uuid)to authenticated;
commit;
notify pgrst,'reload schema';
