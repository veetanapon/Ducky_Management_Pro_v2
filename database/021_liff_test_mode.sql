-- 0.13: clearly isolated LIFF test links and explicit bot connection probes.
begin;
alter table public.access_links add column test_mode boolean not null default false;
alter table public.worker_submissions add column is_test boolean not null default false;
alter table private.line_outbox add column is_probe boolean not null default false;
create function private.worker_test_flag()returns trigger language plpgsql security definer set search_path='' as $$begin select test_mode into new.is_test from public.access_links where id=new.link_id;return new;end$$;
create trigger worker_test_flag before insert on public.worker_submissions for each row execute function private.worker_test_flag();
create function private.line_test_label()returns trigger language plpgsql security definer set search_path='' as $$begin if (select test_mode from public.access_links where id=new.link_id)or new.is_probe then new.message:=E'[ทดสอบ — ไม่ใช่รายการจริง]\n'||left(new.message,4800);end if;return new;end$$;
create trigger line_test_label before insert on private.line_outbox for each row execute function private.line_test_label();
alter function public.access_manage(jsonb,uuid)rename to access_manage_v120;
revoke all on function public.access_manage_v120(jsonb,uuid)from public,anon,authenticated;
create function public.access_manage(p_data jsonb,p_request uuid)returns jsonb language plpgsql security definer set search_path='' as $$declare r jsonb;l public.access_links;begin
 perform private.feed_lock();
 if p_data->>'action'='edit'and p_data?'test_mode'then select * into l from public.access_links where id=(p_data->>'id')::uuid;if l.test_mode is distinct from (p_data->>'test_mode')::boolean then raise exception 'LINK_MODE_IMMUTABLE';end if;end if;
 r:=public.access_manage_v120(p_data,p_request);
 if p_data->>'action'='create'then update public.access_links set test_mode=kind='liff'and coalesce((p_data->>'test_mode')::boolean,false)where id=(r->>'id')::uuid;end if;
 return r;
end$$;
revoke all on function public.access_manage(jsonb,uuid)from public,anon;grant execute on function public.access_manage(jsonb,uuid)to authenticated;
alter function public.access_read(text,date)rename to access_read_v120;
revoke all on function public.access_read_v120(text,date)from public,anon,authenticated;
create function public.access_read(p_token text,p_date date default null)returns jsonb language plpgsql security definer set search_path='' as $$declare l public.access_links;begin l:=private.access_valid(p_token);return public.access_read_v120(p_token,p_date)||jsonb_build_object('test_mode',l.test_mode);end$$;
revoke all on function public.access_read(text,date)from public;grant execute on function public.access_read(text,date)to anon,authenticated;
-- Test drafts never reserve real inventory.
do $$declare d text;begin select pg_get_functiondef('private.farm_apply(jsonb)'::regprocedure)into d;if position('ws.status=''pending''and ws.kind=''feed'''in d)=0 then raise exception 'EXPECTED_FEED_RESERVATION_NOT_FOUND';end if;d:=replace(d,'ws.status=''pending''and ws.kind=''feed''','ws.status=''pending''and not ws.is_test and ws.kind=''feed''');execute d;end$$;
alter function public.worker_review(jsonb,uuid)rename to worker_review_v120;
revoke all on function public.worker_review_v120(jsonb,uuid)from public,anon,authenticated;
create function public.worker_review(p_data jsonb,p_request uuid)returns jsonb language plpgsql security definer set search_path='' as $$declare r public.worker_submissions;ret jsonb;begin
 perform private.feed_lock();select * into strict r from public.worker_submissions where id=(p_data->>'id')::uuid for update;
 if not r.is_test or p_data->>'action' is distinct from 'approve'then return public.worker_review_v120(p_data,p_request);end if;
 if not private.can_batch(r.batch_id,'farm',true)or not private.feature_allowed(case r.kind when 'egg'then 'farm.eggs'when 'feed'then 'farm.inventory'else 'farm.sales'end,true)then raise exception 'NO_ACCESS';end if;
 ret:=private.request_result(p_request,'worker-test-v13',p_data);if ret is not null then return ret;end if;
 -- Run the normal validation and posting path in a subtransaction, then roll back
 -- every business write. Only the test submission's review result is persisted.
 begin
  ret:=public.worker_review_v120(p_data,p_request);
  raise exception using errcode='P9013',message='ROLLBACK_TEST_POST';
 exception when sqlstate 'P9013' then null;
 end;
 update public.worker_submissions set status='approved',version=version+1,reviewed_by=auth.uid(),reviewed_at=now(),result=jsonb_build_object('test',true,'message','ผ่านการตรวจ ไม่ลงข้อมูลจริง')where id=r.id;
 return private.finish_request(p_request,'worker-test-v13',p_data,jsonb_build_object('id',r.id,'test',true));
end$$;
revoke all on function public.worker_review(jsonb,uuid)from public,anon;grant execute on function public.worker_review(jsonb,uuid)to authenticated;
create function public.line_probe_status(p_link uuid)returns jsonb language plpgsql security definer set search_path='' as $$declare l public.access_links;r jsonb;begin
 select * into strict l from public.access_links where id=p_link;
 if not private.can_batch(l.batch_id,'farm',true)or not private.feature_allowed('farm.links',true)then raise exception 'NO_ACCESS';end if;
 select jsonb_build_object('id',id,'created_at',created_at,'sent_at',sent_at,'attempts',attempts,'error',last_error,'status',case when sent_at is not null then 'sent'when last_error is not null and last_error<>''then 'error'else 'queued'end)into r from private.line_outbox where link_id=l.id and is_probe order by created_at desc limit 1;
 return coalesce(r,'{}');
end$$;
create function public.line_probe(p_data jsonb,p_request uuid)returns jsonb language plpgsql security definer set search_path='' as $$declare l public.access_links;r jsonb;oid uuid;begin
 perform private.feed_lock();select * into strict l from public.access_links where id=(p_data->>'id')::uuid;
 if not private.can_batch(l.batch_id,'farm',true)or not private.feature_allowed('farm.links',true)then raise exception 'NO_ACCESS';end if;
 r:=private.request_result(p_request,'line-probe-v13',p_data);if r is not null then return r;end if;
 if l.kind<>'liff'or l.revoked or l.expires_at<=now()or exists(select 1 from public.batches where id=l.batch_id and status='closed')then raise exception 'LINK_EXPIRED';end if;
 if l.bot_key is null or l.line_to_id is null then raise exception 'LINE_NOT_CONFIGURED';end if;
 if exists(select 1 from private.line_outbox where link_id=l.id and is_probe and created_at>now()-interval '30 seconds')then raise exception 'TEST_ALREADY_QUEUED';end if;
 insert into private.line_outbox(request_id,link_id,bot_key,line_to_id,message,is_probe)values(p_request,l.id,l.bot_key,l.line_to_id,'ทดสอบการเชื่อมต่อ DUCKY · '||l.name||E'\nข้อความนี้ไม่บันทึกไข่ อาหาร บิล หรือเงิน',true)returning id into oid;
 return private.finish_request(p_request,'line-probe-v13',p_data,jsonb_build_object('id',oid,'status','queued'));
end$$;
revoke all on function public.line_probe(jsonb,uuid),public.line_probe_status(uuid)from public,anon;
grant execute on function public.line_probe(jsonb,uuid),public.line_probe_status(uuid)to authenticated;
create or replace function public.settings_status()returns jsonb language plpgsql security definer set search_path='' as $$begin if not exists(select 1 from public.profiles where id=auth.uid()and approved)then raise exception 'NO_ACCESS';end if;return jsonb_build_object('server_time',now(),'database_version','021 / 0.13.0','approved',true,'admin',private.is_admin());end$$;
commit;
notify pgrst,'reload schema';
