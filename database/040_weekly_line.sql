-- Install after 039. No messages sent on installation. All dates are farm-local.
begin;
create table if not exists private.weekly_bot(bot text primary key,dow int not null check(dow between 0 and 6));
create table if not exists private.weekly_scope(bot text references private.weekly_bot,batch uuid references public.batches on delete cascade, enabled boolean not null, eggs boolean not null,feed boolean not null,ship boolean not null,primary key(bot,batch));
create table if not exists private.weekly_issue(bot text,batch uuid,ending date,primary key(bot,batch,ending));
create or replace function private.weekly_report(b uuid,d date) returns jsonb language sql stable set search_path='' as $$
with days as (select d-i dt from generate_series(0,13)i), rows as (
 select dt,e.total eggs,coalesce(e.live_count,private.farm_animal_balance(b,dt)) heads,
 f.sacks,f.grams,f.logged from days left join public.egg_daily e on e.batch_id=b and e.log_date=dt
 left join lateral(select sum(c.consumed) filter(where c.unit='กระสอบ') sacks,
 case when bool_and(coalesce(c.kg_per_unit,o.kg_per_unit,case when c.unit in('กก.','kg') then 1 end)>0 is true)
 then sum(c.consumed*coalesce(c.kg_per_unit,o.kg_per_unit,1)*1000) end grams,count(*)>0 logged
 from public.feed_consumption c left join public.feed_allocations a on a.id=c.allocation_id left join public.feed_orders o on o.id=a.order_id
 where c.batch_id=b and c.log_date=dt and o.is_visible is distinct from false)f on true),
 grades as(select i.grade,sum(i.qty) qty from public.sales s join public.sale_items i on i.sale_id=s.id
 join public.batches bt on bt.id=s.batch_id and bt.species_id='duck'
 where s.batch_id=b and s.sale_date between d-6 and d and s.status='posted' and s.sale_type='egg'
 and not s.document_only and i.unit='ฟอง' and concat_ws(' ',i.grade,i.entry->>'display_name') !~* '(ไก่|chicken|hen egg)' group by i.grade),
 ranked as(select *,row_number()over(order by qty desc,grade) r from grades)
 select jsonb_build_object('start',d-6,'end',d,'days',(select jsonb_agg(jsonb_build_object('date',dt,'egg',eggs,'feed',sacks,'logged',logged) order by dt) from rows where dt>=d-6),
 'egg_avg',(select avg(eggs) from rows where dt>=d-6),'rate',(select case when bool_and(heads>0 is true) then sum(eggs)*100/nullif(sum(heads),0) end from rows where dt>=d-6 and eggs is not null),
 'delta',(select case when count(eggs)=14 then sum(eggs)filter(where dt>=d-6)-sum(eggs)filter(where dt<d-6) end from rows),
 'grams',(select case when bool_and(grams is not null and heads>0 is true) then sum(grams)/nullif(sum(heads),0) end from rows where dt>=d-6 and logged),
 'grades',coalesce((select jsonb_agg(jsonb_build_object('name',g,'qty',q) order by ord) from(select case when r<=12 then grade else 'ประเภทที่เหลือ' end g,sum(qty) q,min(r) ord from ranked group by case when r<=12 then r else 13 end,case when r<=12 then grade else 'ประเภทที่เหลือ' end)x),'[]'::jsonb),
 'pending',(select count(*) from public.worker_submissions where batch_id=b and log_date between d-6 and d and not is_test and status='pending'))
$$;
create or replace function private.weekly_attach() returns trigger language plpgsql security definer set search_path='' as $$
declare b uuid; d date; cfg private.weekly_scope; w jsonb;
begin
 if new.daily_context is null or new.is_probe or coalesce((new.daily_context->>'test_mode')::boolean,true) or new.daily_context ? 'weekly' then return new;end if;
 select l.batch_id into b from public.access_links l join public.batches bt on bt.id=l.batch_id and bt.species_id='duck' where l.id=new.link_id and not l.test_mode;
 d:=(new.created_at at time zone 'Asia/Bangkok')::date;
 select s.* into cfg from private.weekly_scope s join private.weekly_bot t on t.bot=s.bot where s.bot=new.bot_key and s.batch=b and s.enabled and t.dow=extract(dow from d);
 if not found then return new;end if;
 insert into private.weekly_issue values(new.bot_key,b,d) on conflict do nothing;
 if found then w:=private.weekly_report(b,d)||to_jsonb(cfg);new.daily_context:=new.daily_context||jsonb_build_object('weekly',w);end if;
 return new;
end$$;
drop trigger if exists zz_weekly_attach on private.line_outbox;
create trigger zz_weekly_attach before insert on private.line_outbox for each row execute function private.weekly_attach();
create or replace function public.weekly_line_admin(p_link uuid,p_action text default 'read',p jsonb default '{}') returns jsonb language plpgsql security definer set search_path='' as $$
declare l public.access_links; cfg private.weekly_scope; d date; w jsonb; daynum int;
begin
 if not private.is_admin() then raise exception 'NO_ACCESS';end if;
 select a.* into strict l from public.access_links a join public.batches b on b.id=a.batch_id and b.species_id='duck' and b.status='active' where a.id=p_link and a.kind='liff' and not a.test_mode and not a.revoked and (a.expires_at is null or a.expires_at>now()) and nullif(a.bot_key,'') is not null and nullif(a.line_to_id,'') is not null;
 if p_action='save' then
 insert into private.weekly_bot values(l.bot_key,(p->>'dow')::int) on conflict(bot) do update set dow=excluded.dow;
 insert into private.weekly_scope values(l.bot_key,l.batch_id,(p->>'enabled')::boolean,(p->>'eggs')::boolean,(p->>'feed')::boolean,(p->>'ship')::boolean)
 on conflict(bot,batch) do update set enabled=excluded.enabled,eggs=excluded.eggs,feed=excluded.feed,ship=excluded.ship;
 elsif p_action not in ('read','revise') then raise exception 'UNKNOWN_ACTION'; end if;
 select * into cfg from private.weekly_scope where bot=l.bot_key and batch=l.batch_id;
 if cfg.enabled and not(cfg.eggs or cfg.feed or cfg.ship) then raise exception 'เลือกอย่างน้อยหนึ่งรายการ';end if;
 select dow into daynum from private.weekly_bot where bot=l.bot_key;
 select max(ending) into d from private.weekly_issue where bot=l.bot_key and batch=l.batch_id;
 if p_action='revise' then
 if cfg.enabled is not true or d is null then raise exception 'ยังไม่มีสรุปสำหรับปรับปรุง'; end if;
 w:=private.weekly_report(l.batch_id,d)||to_jsonb(cfg);
 insert into private.line_outbox(request_id,link_id,bot_key,line_to_id,message,daily_context) values((p->>'request')::uuid,l.id,l.bot_key,l.line_to_id,'สรุปสัปดาห์ฉบับปรับปรุง',jsonb_build_object('revision',true,'batch_name',(select name from public.batches where id=l.batch_id),'weekly',w)) on conflict(request_id) do nothing;
 end if;
 return coalesce(to_jsonb(cfg),'{}')||jsonb_build_object('dow',coalesce(daynum,0),'last',d);
end$$;
revoke all on function private.weekly_report(uuid,date),private.weekly_attach(), public.weekly_line_admin(uuid,text,jsonb) from public,anon,authenticated;
grant execute on function public.weekly_line_admin(uuid,text,jsonb) to authenticated;
notify pgrst,'reload schema';
commit;
