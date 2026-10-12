begin;
-- Include newly introduced financial details in the export fingerprint.
alter function private.archive_rows(uuid)rename to archive_rows_v090;
create function private.archive_rows(b uuid)returns jsonb language sql stable security definer set search_path='' as $$
select private.archive_rows_v090(b)||jsonb_build_object('sale_settlements',coalesce((select jsonb_agg(to_jsonb(s)order by id)from public.sale_settlements s where batch_id=b),'[]'),'tax_records',coalesce((select jsonb_agg(to_jsonb(t)order by id)from public.tax_records t where batch_id=b),'[]'));
$$;
revoke all on function private.archive_rows(uuid),private.archive_rows_v090(uuid)from public,anon,authenticated;
alter function private.archive_blockers(uuid)rename to archive_blockers_v090;
create function private.archive_blockers(b uuid)returns jsonb language sql stable security definer set search_path='' as $$select private.archive_blockers_v090(b)||case when exists(select 1 from public.sales where batch_id=b and status='posted'and payment_status='unpaid')then '["มีบิลรอรับเงิน"]'::jsonb else '[]'::jsonb end$$;
revoke all on function private.archive_blockers(uuid),private.archive_blockers_v090(uuid)from public,anon,authenticated;
alter function public.batch_export(uuid)rename to batch_export_v090;
revoke all on function public.batch_export_v090(uuid)from public,anon,authenticated;
create function public.batch_export(p_batch uuid)returns jsonb language plpgsql security definer set search_path='' as $$declare r jsonb;c jsonb;children jsonb:='[]';b public.batches;begin
if not private.is_admin()then raise exception 'NO_ACCESS';end if;perform private.feed_lock();r:=public.batch_export_v090(p_batch);
for b in select * from public.batches where parent_batch_id=p_batch order by id loop c:=public.batch_export(b.id);children:=children||jsonb_build_array(jsonb_build_object('batch_id',b.id,'ticket',c->'ticket','fingerprint',c->'fingerprint','summary',c->'summary','confirmation',b.name));r:=jsonb_set(r,'{blockers}',r->'blockers'||coalesce((select jsonb_agg(to_jsonb(b.name||': '||value))from jsonb_array_elements_text(c->'blockers')),'[]'));end loop;
r:=r||jsonb_build_object('linked',children);r:=jsonb_set(r,'{summary,linked_batches}',coalesce((select jsonb_agg(value->'summary')from jsonb_array_elements(children)),'[]'));
r:=jsonb_set(r,'{summary,tax_monthly}',coalesce((select jsonb_agg(to_jsonb(t))from(select to_char(log_date,'YYYY-MM')as "month",source,sum(amount)amount from public.tax_records where batch_id=p_batch group by 1,2)t),'[]'));return r;end$$;
alter function public.batch_purge(jsonb,uuid)rename to batch_purge_v090;
revoke all on function public.batch_purge_v090(jsonb,uuid)from public,anon,authenticated;
create function public.batch_purge(p_data jsonb,p_request uuid)returns jsonb language plpgsql security definer set search_path='' as $$declare child jsonb;r jsonb;actual uuid[];provided uuid[];begin
if not private.is_admin()then raise exception 'NO_ACCESS';end if;perform private.feed_lock();
r:=private.request_result(p_request,'archive-linked',p_data);if r is not null then return r;end if;
select coalesce(array_agg(id order by id),'{}')into actual from public.batches where parent_batch_id=(p_data->>'batch_id')::uuid;
select coalesce(array_agg((value->>'batch_id')::uuid order by(value->>'batch_id')::uuid),'{}')into provided from jsonb_array_elements(coalesce(p_data->'linked','[]'));
if actual<>provided then raise exception 'DATA_CHANGED_EXPORT_AGAIN';end if;
for child in select value from jsonb_array_elements(coalesce(p_data->'linked','[]'))loop perform public.batch_purge_v090(child||jsonb_build_object('downloaded',(p_data->>'downloaded')::boolean),gen_random_uuid());end loop;
r:=public.batch_purge_v090(p_data,gen_random_uuid());return private.finish_request(p_request,'archive-linked',p_data,r);end$$;
revoke all on function public.batch_export(uuid),public.batch_purge(jsonb,uuid)from public,anon;grant execute on function public.batch_export(uuid),public.batch_purge(jsonb,uuid)to authenticated;
create or replace function public.settings_status()returns jsonb language plpgsql security definer set search_path='' as $$begin
if not exists(select 1 from public.profiles where id=auth.uid()and approved)then raise exception 'NO_ACCESS';end if;
return jsonb_build_object('server_time',now(),'database_version','017 / 0.10.0','approved',true,'admin',private.is_admin());end$$;
commit;notify pgrst,'reload schema';
