-- Optional activation AFTER preview approval. Requires schema 022.
-- Does not enqueue, claim, or send any message. Applies to future worker bundles only.
begin;
alter table private.line_outbox add column if not exists daily_context jsonb;
create or replace function private.daily_line_context()returns trigger language plpgsql security definer set search_path='' as $$
declare l public.access_links;r jsonb;s public.worker_submissions;prev jsonb;ctx jsonb;live numeric;
begin
 if new.is_probe then return new;end if;
 select * into strict l from public.access_links where id=new.link_id;
 select result into r from private.worker_bundles where request_id=new.request_id and link_id=l.id;
 if r is null then return new;end if;
 ctx:=jsonb_build_object('batch_name',(select name from public.batches where id=l.batch_id),'test_mode',l.test_mode,'date',(now()at time zone 'Asia/Bangkok')::date);
 for s in select w.* from jsonb_array_elements(r)x join public.worker_submissions w on w.id=(x.value->>'id')::uuid where w.link_id=l.id loop
  ctx:=ctx||jsonb_build_object('submitter',s.submitter);
  prev:=null;
  if s.kind='egg' then
   select jsonb_build_object('total',e.total,'live_count',coalesce(e.live_count,private.farm_animal_balance(l.batch_id,e.log_date)),'status','confirmed')into prev from public.egg_daily e where e.batch_id=l.batch_id and e.log_date=s.log_date-1;
   if prev is null then
    select jsonb_build_object('total',(w.payload->>'total')::numeric,'live_count',private.farm_animal_balance(l.batch_id,w.log_date),'status','pending')into prev from public.worker_submissions w where w.batch_id=l.batch_id and w.kind='egg' and w.log_date=s.log_date-1 and w.status='pending' and w.is_test=l.test_mode order by w.created_at desc,w.id desc limit 1;
   end if;
   live:=private.farm_animal_balance(l.batch_id,s.log_date);
   ctx:=ctx||jsonb_build_object('egg',jsonb_build_object('date',s.log_date,'previous_date',s.log_date-1,'payload',s.payload,'live_count',live,'previous',prev));
  elsif s.kind='feed' then
   select case when count(*)>0 and bool_and(c.unit='กระสอบ') then jsonb_build_object('consumed',sum(c.consumed),'status','confirmed')else null end into prev from public.feed_consumption c where c.batch_id=l.batch_id and c.log_date=s.log_date-1;
   if prev is null then
    select jsonb_build_object('consumed',(w.payload->>'issued')::numeric-coalesce((w.payload->>'leftover')::numeric,0)-coalesce((w.payload->>'waste')::numeric,0),'status','pending')into prev from public.worker_submissions w where w.batch_id=l.batch_id and w.kind='feed' and w.log_date=s.log_date-1 and w.status='pending' and w.is_test=l.test_mode order by w.created_at desc,w.id desc limit 1;
   end if;
   ctx:=ctx||jsonb_build_object('feed',jsonb_build_object('date',s.log_date,'previous_date',s.log_date-1,'payload',s.payload,'previous',prev));
  elsif s.kind='sale' then ctx:=ctx||jsonb_build_object('prebill',s.payload);
  end if;
 end loop;
 new.daily_context:=ctx;return new;
end$$;
revoke all on function private.daily_line_context()from public,anon,authenticated;
drop trigger if exists daily_line_context on private.line_outbox;
create trigger daily_line_context before insert on private.line_outbox for each row execute function private.daily_line_context();
commit;
notify pgrst,'reload schema';
