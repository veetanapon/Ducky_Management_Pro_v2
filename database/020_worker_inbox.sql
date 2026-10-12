-- 0.12.0: per-module worker review and editable egg/sale drafts.
begin;
drop policy worker_inbox_read on public.worker_submissions;
create policy worker_inbox_read on public.worker_submissions for select to authenticated using(private.can_batch(batch_id,'farm') and private.feature_allowed(case kind when 'egg' then 'farm.eggs' when 'feed' then 'farm.inventory' when 'sale' then 'farm.sales' end));
alter function public.worker_review(jsonb,uuid) rename to worker_review_v110;
revoke all on function public.worker_review_v110(jsonb,uuid) from public,anon,authenticated;
create function public.worker_review(p_data jsonb,p_request uuid) returns jsonb language plpgsql security definer set search_path='' as $$
declare r public.worker_submissions;ret jsonb;q jsonb;p jsonb;items jsonb;v jsonb;k text;n numeric;
begin
 perform private.feed_lock();select * into strict r from public.worker_submissions where id=(p_data->>'id')::uuid for update;
 if not private.can_batch(r.batch_id,'farm',true) or not private.feature_allowed(case r.kind when 'egg' then 'farm.eggs' when 'feed' then 'farm.inventory' when 'sale' then 'farm.sales' end,true) then raise exception 'NO_ACCESS';end if;
 if r.kind='feed' or p_data->>'action' is distinct from 'edit' then return public.worker_review_v110(p_data,p_request);end if;
 ret:=private.request_result(p_request,'worker-edit-v12',p_data);if ret is not null then return ret;end if;
 if r.status<>'pending' or r.version is distinct from(p_data->>'version')::int then raise exception 'VERSION_CONFLICT';end if;
 q:=p_data->'payload';if jsonb_typeof(q) is distinct from 'object' then raise exception 'INVALID_PAYLOAD';end if;
 p:=r.payload;
 if r.kind='egg' then
  foreach k in array array['total','big','small','cracked','broken','remaining','live_count'] loop
   n:=private.farm_num(q,k);if n<>trunc(n)then raise exception 'INVALID_EGG_CATEGORIES';end if;
   p:=p||jsonb_build_object(k,n);
  end loop;
  if (p->>'big')::numeric+(p->>'small')::numeric+(p->>'cracked')::numeric+(p->>'broken')::numeric>(p->>'total')::numeric then raise exception 'INVALID_EGG_CATEGORIES';end if;
 else
  if length(trim(coalesce(q->>'buyer','')))=0 or length(q->>'buyer')>200 then raise exception 'INVALID_BUYER';end if;
  if jsonb_typeof(q->'items') is distinct from 'array' then raise exception 'INVALID_ITEMS';end if;
  if jsonb_array_length(q->'items') not between 1 and 100 then raise exception 'INVALID_ITEMS';end if;
  items:='[]';
  for v in select value from jsonb_array_elements(q->'items') loop
   n:=private.farm_num(v,'pieces');if n<=0 or n<>trunc(n)then raise exception 'INVALID_ITEMS';end if;
   if nullif(v->>'price_item_id','') is null and length(trim(coalesce(v->>'price_reason','')))=0 then raise exception 'PRICE_REASON_REQUIRED';end if;
   items:=items||jsonb_build_array(jsonb_build_object('price_item_id',v->>'price_item_id','grade',v->>'grade','display_name',v->>'display_name','pieces',n,'unit_price',private.farm_num(v,'unit_price'),'discount',private.farm_num(v,'discount'),'price_reason',left(v->>'price_reason',500)));
  end loop;
  p:=p||jsonb_build_object('buyer',trim(q->>'buyer'),'items',items);
 end if;
 update public.worker_submissions set payload=p,version=version+1 where id=r.id;
 return private.finish_request(p_request,'worker-edit-v12',p_data,jsonb_build_object('id',r.id,'version',r.version+1));
end$$;
revoke all on function public.worker_review(jsonb,uuid) from public,anon;
grant execute on function public.worker_review(jsonb,uuid) to authenticated;
create or replace function public.settings_status()returns jsonb language plpgsql security definer set search_path='' as $$begin if not exists(select 1 from public.profiles where id=auth.uid()and approved)then raise exception 'NO_ACCESS';end if;return jsonb_build_object('server_time',now(),'database_version','020 / 0.12.0','approved',true,'admin',private.is_admin());end$$;
commit;
notify pgrst,'reload schema';
