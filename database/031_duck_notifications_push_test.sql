-- Run after 030. Duck-only notices; tasks remain available for all species.
begin;
create or replace function private.emit_notice(u uuid,b uuid,f text,k text,t text,msg text,path text,expiry timestamptz)returns void language plpgsql security definer set search_path='' as $$declare nid uuid;begin
 if not exists(select 1 from public.batches where id=b and species_id='duck')then return;end if;
 if not private.notice_allowed(u,b,f)then return;end if;
 insert into public.app_notifications(user_id,batch_id,feature,dedupe_key,title,body,route,expires_at)values(u,b,f,k,t,msg,path,expiry)on conflict(user_id,dedupe_key)do nothing returning id into nid;
 if nid is not null then insert into private.push_deliveries(notification_id,subscription_id)select nid,id from private.push_subscriptions where user_id=u and active on conflict do nothing;end if;
end$$;

create or replace function private.generate_notices(only_user uuid default null)returns void language plpgsql security definer set search_path='' as $$
declare u record;b record;day date:=(now()at time zone'Asia/Bangkok')::date;expiry timestamptz:=(((now()at time zone'Asia/Bangkok')::date+1)::timestamp at time zone'Asia/Bangkok');hr int:=extract(hour from now()at time zone'Asia/Bangkok');pref private.notification_preferences;r record;stock numeric;avg_use numeric;days_left numeric;delivery date;begin
 for u in select id from public.profiles where approved and(only_user is null or id=only_user)loop
 select * into pref from private.notification_preferences where user_id=u.id;
 update public.app_notifications n set resolved=true where n.user_id=u.id and not resolved and (
 (n.dedupe_key like 'missing:egg:%'and exists(select 1 from public.egg_daily e where e.batch_id=n.batch_id and e.log_date::text=split_part(n.dedupe_key,':',4)))or
 (n.dedupe_key like 'missing:feed:%'and exists(select 1 from public.feed_consumption c where c.batch_id=n.batch_id and(c.log_date+1)::text=split_part(n.dedupe_key,':',4)))or
 (n.dedupe_key like 'missing:sale:%'and exists(select 1 from public.sales x where x.batch_id=n.batch_id and x.sale_date::text=split_part(n.dedupe_key,':',4)and x.status='posted'))or
 (n.dedupe_key like 'due:%'and exists(select 1 from public.feed_orders o where o.id::text=split_part(n.dedupe_key,':',2)and(private.feed_totals(o.id)->>'outstanding')::numeric<=0)));
 for r in select * from public.worker_submissions where status='pending'and created_at>now()-interval '30 days'loop
 perform private.emit_notice(u.id,r.batch_id,case r.kind when 'egg'then 'farm.eggs'when 'feed'then 'farm.inventory'else 'farm.sales'end,'worker:'||r.id,case when r.is_test then '[ทดสอบ] 'else ''end||'มีงานจาก LIFF รอตรวจ',r.submitter||' · '||r.log_date,case r.kind when 'egg'then '#farm/eggs'when 'feed'then '#farm/feed'else '#farm/sales'end,now()+interval '30 days');end loop;

 for b in select * from public.batches where species_id='duck'and status='active'and start_date<=day and (private.notice_allowed(u.id,id,'farm.eggs')or private.notice_allowed(u.id,id,'farm.inventory')or private.notice_allowed(u.id,id,'farm.sales'))loop
 if hr>=coalesce(pref.remind_hour,18)then
 if b.species_id='duck'and not exists(select 1 from public.egg_daily where batch_id=b.id and log_date=day)and not exists(select 1 from public.worker_submissions where batch_id=b.id and kind='egg'and log_date=day and status='pending'and not is_test)then
 perform private.emit_notice(u.id,b.id,'farm.eggs','missing:egg:'||b.id||':'||day,'ยังไม่มีไข่วันนี้',b.name||' · กรุณาบันทึกหรือตรวจงานวันที่ '||day,'#farm/eggs',expiry);end if;
 if day>b.start_date and not exists(select 1 from public.feed_consumption where batch_id=b.id and log_date=day-1)and not exists(select 1 from public.worker_submissions where batch_id=b.id and kind='feed'and log_date=day-1 and status='pending'and not is_test)and not exists(select 1 from public.farm_pending where batch_id=b.id and kind='prefeed'and log_date=day-1 and status='pending')then
 perform private.emit_notice(u.id,b.id,'farm.inventory','missing:feed:'||b.id||':'||day,'ยังไม่มีอาหารของเมื่อวาน',b.name||' · วันที่ '||(day-1),'#farm/feed',expiry);end if;
 if coalesce(pref.missing_sale,true)and not exists(select 1 from public.sales where batch_id=b.id and sale_date=day and status='posted')and not exists(select 1 from public.worker_submissions where batch_id=b.id and kind='sale'and log_date=day and status='pending'and not is_test)and not exists(select 1 from public.farm_pending where batch_id=b.id and kind='prebill'and log_date=day and status='pending')then
 perform private.emit_notice(u.id,b.id,'farm.sales','missing:sale:'||b.id||':'||day,'ตรวจบิลขายวันนี้',b.name||' · ยังไม่มีบิลวันนี้ หากวันนี้ไม่มีขายสามารถปิดเตือนบิลรายวันได้','#farm/sales',expiry);end if;
 end if;
 -- Group food by product/unit, never add bags and kilograms or old archived quantities together.
 for r in select distinct a.feed_name,a.unit from public.feed_allocations a where a.batch_id=b.id loop
 select coalesce(sum(greatest(0,a.quantity+a.stock_adjustment-coalesce((select sum(c.issued-c.leftover)from public.feed_consumption c where c.allocation_id=a.id and c.log_date<=day),0)-coalesce((select sum(x.quantity)from public.farm_feed_returns x where x.allocation_id=a.id and x.log_date<=day),0))),0)into stock from public.feed_allocations a where a.batch_id=b.id and a.feed_name=r.feed_name and a.unit=r.unit and a.allocation_date<=day;
 select avg(qty)into avg_use from(select c.log_date,sum(c.consumed)qty from public.feed_consumption c join public.feed_allocations a on a.id=c.allocation_id where c.batch_id=b.id and a.feed_name=r.feed_name and a.unit=r.unit and c.log_date between day-7 and day-1 group by c.log_date)x;
 if avg_use is null or avg_use<=0 or stock/avg_use>4 then update public.app_notifications set resolved=true where user_id=u.id and dedupe_key='food:'||b.id||':'||md5(r.feed_name||r.unit)||':'||day;end if;
 if avg_use>0 and stock/avg_use<=4 then
 -- Exhausted import-only foods no longer drive reorder alerts.
 if stock=0 and not exists(select 1 from public.feed_allocations a where a.batch_id=b.id and a.feed_name=r.feed_name and a.unit=r.unit and a.legacy_id is null)then continue;end if;
 days_left:=stock/avg_use;delivery:=day+floor(days_left)::int;
 perform private.emit_notice(u.id,b.id,'farm.inventory','food:'||b.id||':'||md5(r.feed_name||r.unit)||':'||day,'อาหารใกล้หมด · ควรสั่งแล้ว',b.name||' · '||r.feed_name||' เหลือ '||round(stock,2)||' '||r.unit||' · ให้มาลงไม่เกิน '||delivery||' (เฉลี่ยจากวันที่บันทึกใน 7 วันก่อนหน้า)','#farm/feed',expiry);
 end if;
 end loop;
 -- Purchase due notices are routed only to users who also have the central feed module.
 if exists(select 1 from public.module_access where user_id=u.id and module='feed')or exists(select 1 from public.profiles where id=u.id and is_admin)then
 for r in select distinct o.* from public.feed_orders o join public.feed_allocations a on a.order_id=o.id where a.batch_id=b.id and o.is_visible and o.due_date<=day+3 loop
 if (private.feed_totals(r.id)->>'outstanding')::numeric>0 then perform private.emit_notice(u.id,b.id,'farm.inventory','due:'||r.id||':'||day,'บิลอาหารใกล้ / ถึงกำหนดจ่าย',r.feed_name||' · ครบกำหนด '||r.due_date,'#feed',expiry);end if;end loop;end if;
 end loop;
 for r in select * from public.batch_tasks where exists(select 1 from public.batches bt where bt.id=batch_tasks.batch_id and bt.status='active')and u.id=any(assignees)and completed_at is null and start_date<=day and end_date>=day loop
 perform private.emit_notice(u.id,r.batch_id,'farm.events','task:'||r.id||':'||day,'งานที่ได้รับมอบหมาย',r.title||' · '||r.start_date||' ถึง '||r.end_date,'#farm/events',expiry);end loop;
 end loop;
end$$;

create or replace function public.notification_workspace()returns jsonb language plpgsql security definer set search_path='' as $$begin
 if not exists(select 1 from public.profiles where id=auth.uid()and approved)then raise exception 'NO_ACCESS';end if;
 perform private.generate_notices(auth.uid());
 return jsonb_build_object('notices',(select coalesce(jsonb_agg(to_jsonb(n)order by created_at desc),'[]')from(select * from public.app_notifications where exists(select 1 from public.batches b where b.id=app_notifications.batch_id and b.species_id='duck')and user_id=auth.uid()and expires_at>now()and not resolved and private.notice_allowed(auth.uid(),batch_id,feature)order by created_at desc limit 200)n),'tasks',(select coalesce(jsonb_agg(to_jsonb(t)order by start_date),'[]')from public.batch_tasks t where private.notice_allowed(auth.uid(),batch_id,'farm.events')and(created_by=auth.uid()or auth.uid()=any(assignees))and(completed_at is null or completed_at>now()-interval '30 days')),'preferences',coalesce((select to_jsonb(p)-'user_id'from private.notification_preferences p where user_id=auth.uid()),'{"remind_hour":18,"missing_sale":true}'));
end$$;

create or replace function public.notification_push_claim()returns jsonb language plpgsql security definer set search_path='' as $$declare result jsonb;begin
 perform private.generate_notices();
 with picked as(select d.id from private.push_deliveries d join public.app_notifications n on n.id=d.notification_id join private.push_subscriptions s on s.id=d.subscription_id where exists(select 1 from public.batches b where b.id=n.batch_id and b.species_id='duck')and d.status in('pending','sending')and(d.lease_until is null or d.lease_until<now())and d.attempts<8 and s.active and s.user_id=n.user_id and not n.resolved and n.read_at is null and n.expires_at>now()and private.notice_allowed(n.user_id,n.batch_id,n.feature)order by n.created_at for update of d skip locked limit 20),claimed as(update private.push_deliveries d set status='sending',attempts=attempts+1,lease_until=now()+interval '5 minutes',lease_token=gen_random_uuid()from picked p where d.id=p.id returning d.*)
 select coalesce(jsonb_agg(jsonb_build_object('id',c.id,'lease',c.lease_token,'subscription',s.subscription,'payload',jsonb_build_object('id',n.id,'title',n.title,'body',n.body,'route',n.route,'batch_id',n.batch_id))),'[]')into result from claimed c join private.push_subscriptions s on s.id=c.subscription_id join public.app_notifications n on n.id=c.notification_id;
 return result;end$$;

create or replace function public.notification_manage(p_data jsonb,p_request uuid)returns jsonb language plpgsql security definer set search_path='' as $$declare p jsonb:=p_data;r jsonb;t public.batch_tasks;bid uuid;ass uuid[];uid uuid;begin
 if not exists(select 1 from public.profiles where id=auth.uid()and approved)then raise exception 'NO_ACCESS';end if;
 perform private.feed_lock();r:=private.request_result(p_request,'notifications',p);if r is not null then return r;end if;
 case p->>'action'
 when 'test_push'then
 -- Own device only; keep the normal permissions, leases and delivery path.
 if not exists(select 1 from private.push_subscriptions where user_id=auth.uid()and active and endpoint=p->>'endpoint')then raise exception 'PUSH_NOT_SUBSCRIBED';end if;
 select b.id into bid from public.batches b where b.species_id='duck'and b.status='active'and private.notice_allowed(auth.uid(),b.id,'farm.events')order by b.id limit 1;
 if bid is null then raise exception 'NO_ACCESSIBLE_DUCK_BATCH';end if;
 if exists(select 1 from public.app_notifications where user_id=auth.uid()and dedupe_key like 'push-test:%'and created_at>now()-interval '1 minute')then raise exception 'WAIT_ONE_MINUTE';end if;
 insert into public.app_notifications(user_id,batch_id,feature,dedupe_key,title,body,route,expires_at)
 values(auth.uid(),bid,'farm.events','push-test:'||p_request,'ทดสอบ Push จาก Ducky','ได้รับ Push จากเซิร์ฟเวอร์แล้ว','#farm',now()+interval '1 hour')returning id into uid;
 insert into private.push_deliveries(notification_id,subscription_id)select uid,id from private.push_subscriptions where user_id=auth.uid()and active and endpoint=p->>'endpoint';
 when 'read'then update public.app_notifications set read_at=now()where id=(p->>'id')::uuid and user_id=auth.uid();
 when 'preferences'then insert into private.notification_preferences values(auth.uid(),(p->>'remind_hour')::int,(p->>'missing_sale')::boolean)on conflict(user_id)do update set remind_hour=excluded.remind_hour,missing_sale=excluded.missing_sale;
 when 'subscribe'then
 if coalesce(p->'subscription'->>'endpoint','')=''or coalesce(p->'subscription'->'keys'->>'p256dh','')=''or coalesce(p->'subscription'->'keys'->>'auth','')=''or length(p->'subscription'->>'endpoint')>2048 or (p->'subscription'->>'endpoint')!~'^https://(web\.push\.apple\.com|fcm\.googleapis\.com|updates\.push\.services\.mozilla\.com|[a-z0-9-]+\.notify\.windows\.com)/'or length(p->'subscription'->'keys'->>'p256dh')not between 80 and 100 or length(p->'subscription'->'keys'->>'auth')not between 20 and 32 then raise exception 'INVALID_SUBSCRIPTION';end if;
 insert into private.push_subscriptions(user_id,endpoint,subscription)values(auth.uid(),p->'subscription'->>'endpoint',p->'subscription')on conflict(endpoint)do update set user_id=excluded.user_id,subscription=excluded.subscription,active=true;
 when 'unsubscribe'then update private.push_subscriptions set active=false where user_id=auth.uid()and endpoint=p->>'endpoint';
 when 'task'then
 bid:=(p->>'batch_id')::uuid;if not private.notice_allowed(auth.uid(),bid,'farm.events',true)then raise exception 'NO_ACCESS';end if;
 select array_agg(value::uuid)into ass from jsonb_array_elements_text(p->'assignees');if coalesce(cardinality(ass),0)not between 1 and 100 then raise exception 'SELECT_ASSIGNEES';end if;
 foreach uid in array ass loop if not private.notice_allowed(uid,bid,'farm.events')then raise exception 'ASSIGNEE_NO_ACCESS';end if;end loop;
 insert into public.batch_tasks(batch_id,created_by,assignees,title,note,start_date,end_date)values(bid,auth.uid(),ass,trim(p->>'title'),coalesce(p->>'note',''),(p->>'start_date')::date,(p->>'end_date')::date)returning * into t;
 foreach uid in array ass loop perform private.emit_notice(uid,bid,'farm.events','assigned:'||t.id,'มีงานใหม่ในเล้า',t.title||' · '||t.start_date||' ถึง '||t.end_date,'#farm/events',greatest(now()+interval '1 day',(t.end_date+1)::timestamp at time zone'Asia/Bangkok'));end loop;
 when 'complete'then
 select * into strict t from public.batch_tasks where id=(p->>'id')::uuid for update;
 if not private.notice_allowed(auth.uid(),t.batch_id,'farm.events')or not(auth.uid()=t.created_by or auth.uid()=any(t.assignees))then raise exception 'NO_ACCESS';end if;
 if t.version<>(p->>'version')::int then raise exception 'VERSION_CONFLICT';end if;
 update public.batch_tasks set completed_at=now(),completed_by=auth.uid(),version=version+1 where id=t.id;
 update public.app_notifications set resolved=true where dedupe_key='assigned:'||t.id or dedupe_key like 'task:'||t.id||':%';
 else raise exception 'UNKNOWN_ACTION';end case;
 return private.finish_request(p_request,'notifications',p,jsonb_build_object('saved',true,'id',t.id));
end$$;
-- Preserve history and tasks, but remove all non-duck alerts from inbox and queue.
update public.app_notifications n set resolved=true where exists(select 1 from public.batches b where b.id=n.batch_id and b.species_id<>'duck');
update private.push_deliveries d set status='cancelled',lease_until=null,lease_token=null
from public.app_notifications n,public.batches b
where d.notification_id=n.id and b.id=n.batch_id and b.species_id<>'duck'and d.status in('pending','sending');

commit;
notify pgrst,'reload schema';
