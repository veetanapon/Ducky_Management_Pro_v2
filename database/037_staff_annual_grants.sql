-- Requires 036. Catches up on read; scheduled daily if pg_cron is installed.
begin;
alter table private.staff_registry_audit alter column actor drop not null;
create or replace function private.staff_auto_grant()returns void language plpgsql security definer set search_path='' as $$
declare d jsonb;old jsonb;v integer;rule jsonb;p jsonb;e jsonb;yr integer;mo integer;lastyr integer;firstmo integer;period text;startdt date;enddt date;today date:=(now()at time zone'Asia/Bangkok')::date;begin
 perform private.feed_lock();select document,version into d,v from private.staff_registry where id=1 for update;if d is null then return;end if;old:=d;
 for rule in select value from jsonb_array_elements(coalesce(d->'grantRules','[]'))loop
 if coalesce((rule->>'enabled')::boolean,false)is false then continue;end if;
 lastyr:=extract(year from today)::integer+case when (rule->>'beforeYear')::boolean and extract(month from today)=12 then 1 else 0 end;
 for yr in (left(rule->>'start',4)::integer)..lastyr loop
 firstmo:=case when yr=left(rule->>'start',4)::integer then right(rule->>'start',2)::integer else 1 end;
 for p in select value from jsonb_array_elements(d->'policies')a where a->>'active' is distinct from 'false'and rule->'policyIds' ? (a->>'id')loop
 for e in select value from jsonb_array_elements(d->'employees')a where a->>'status'='active'and not(rule->'excludeIds' ? (a->>'id'))and(coalesce(rule->'employeeIds','null')='null'::jsonb or rule->'employeeIds' ? (a->>'id'))loop
 for mo in firstmo..12 loop
 period:=case p->>'cycle'when 'monthly'then yr::text||'-'||lpad(mo::text,2,'0')when 'yearly'then yr::text else 'once'end;
 startdt:=case p->>'cycle'when 'monthly'then make_date(yr,mo,1)when 'yearly'then make_date(yr,1,1)else today end;
 enddt:=case p->>'cycle'when 'monthly'then (startdt+interval '1 month -1 day')::date when 'yearly'then make_date(yr,12,31)else today end;
 if (e->>'start')::date<=enddt and (nullif(e->>'end','')is null or(e->>'end')::date>=startdt)and exists(select 1 from jsonb_array_elements(e->'assignments')a where a->>'farm'=p->>'farm'and(coalesce(rule->>'farm','')=''or a->>'farm'=rule->>'farm')and(a->>'start')::date<=enddt and(nullif(a->>'end','')is null or(a->>'end')::date>=startdt))and not exists(select 1 from jsonb_array_elements(d->'ledger')a where a->>'kind'='grant'and a->>'employee'=e->>'id'and a->>'policy'=p->>'id'and a->>'period'=period)then
 d:=jsonb_set(d,'{ledger}',(d->'ledger')||jsonb_build_array(jsonb_build_object('id',gen_random_uuid(),'employee',e->>'id','policy',p->>'id','farm',p->>'farm','date',today,'period',period,'amount',p->'quantity','kind','grant','automatic',true)));
 end if;
 if p->>'cycle'<>'monthly'then exit;end if;
 end loop;end loop;end loop;end loop;end loop;
 if d<>old then
 update private.staff_registry set document=d,version=v+1,updated_at=now(),updated_by=null where id=1;
 insert into private.staff_registry_audit(version,actor,document)values(v+1,null,d);
 end if;
end$$;
revoke all on function private.staff_auto_grant()from public,anon,authenticated;
create or replace function public.staff_registry_read()returns jsonb language plpgsql security definer set search_path='' as $$begin
 if not private.is_admin()then raise exception 'NO_ACCESS';end if;
 perform private.staff_auto_grant();
 return coalesce((select jsonb_build_object('version',version,'document',document)from private.staff_registry where id=1),'{"version":0,"document":null}'::jsonb)||jsonb_build_object('farms',(select coalesce(jsonb_agg(jsonb_build_object('id',id,'name',name)order by name),'[]')from public.farms));
end$$;
-- pg_cron can be enabled in Supabase Dashboard > Database > Extensions.
-- Re-running this migration after enabling pg_cron installs the job without duplicates.
do $$begin
 if exists(select 1 from pg_extension where extname='pg_cron')then
 execute $q$select cron.schedule('ducky-staff-annual-grants','5 17 * * *','select private.staff_auto_grant()')$q$;
 end if;
end$$;
commit;
notify pgrst,'reload schema';
