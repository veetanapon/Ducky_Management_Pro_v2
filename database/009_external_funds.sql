-- 0.7.0: run once after 008, in the V2 database only.
begin;
alter table public.batch_cash drop constraint batch_cash_kind_check;
alter table public.batch_cash add constraint batch_cash_kind_check check(kind in('opening','receipt','expense','withdrawal','feed_payment','savings_transfer','external_contribution'));
create table public.external_funds(
 id uuid primary key default gen_random_uuid(),batch_id uuid not null references public.batches,
 source_name text not null check(length(trim(source_name))between 1 and 200),reference text not null check(length(trim(reference))between 1 and 200),
 amount numeric(16,2)not null check(amount>0),expected_date date not null,received_date date,
 status text not null default 'expected' check(status in('expected','received','cancelled')),
 cash_id uuid unique references public.batch_cash,version int not null default 1,note text,
 created_by uuid references public.profiles,created_at timestamptz not null default now(),
 unique(batch_id,source_name,reference),
 check((status='received' and cash_id is not null and received_date is not null)or(status<>'received'and cash_id is null and received_date is null))
);
alter table public.external_funds enable row level security;
revoke all on public.external_funds from public,anon,authenticated;
grant select on public.external_funds to authenticated;grant all on public.external_funds to service_role;
create policy external_read on public.external_funds for select to authenticated using(private.can_batch(batch_id,'finance'));
create trigger external_funds_audit after insert or update or delete on public.external_funds for each row execute function private.audit_change();
create function public.external_fund_manage(p_data jsonb,p_request uuid)returns jsonb language plpgsql security definer set search_path='' as $$
declare p jsonb:=p_data;act text:=p->>'action';b uuid;row public.external_funds;ret jsonb;cash uuid;d date;amount numeric;begin
 perform private.feed_lock();
 if act='create'then b:=(p->>'batch_id')::uuid;
 else select * into row from public.external_funds where id=(p->>'id')::uuid;b:=row.batch_id;end if;
 if b is null or not private.can_batch(b,'finance',true)then raise exception 'NO_ACCESS';end if;
 ret:=private.request_result(p_request,'external_fund',p);if ret is not null then return ret;end if;
 if act='create'then
 amount:=(p->>'amount')::numeric;
 if amount is null or amount<=0 or amount<>round(amount,2)or amount>=100000000000000 then raise exception 'INVALID_CASH';end if;
 if p->>'expected_date' is null or length(trim(coalesce(p->>'source_name','')))not between 1 and 200 or length(trim(coalesce(p->>'reference','')))not between 1 and 200 then raise exception 'CASH_DETAILS_REQUIRED';end if;
 if exists(select 1 from public.external_funds where batch_id=b and source_name=trim(p->>'source_name')and reference=trim(p->>'reference'))then raise exception 'DUPLICATE_EXTERNAL_REFERENCE';end if;
 insert into public.external_funds(batch_id,source_name,reference,amount,expected_date,note,created_by)values(b,trim(p->>'source_name'),trim(p->>'reference'),amount,(p->>'expected_date')::date,p->>'note',auth.uid())returning * into row;
 elsif act in('receive','cancel')then
 if row.version is distinct from (p->>'version')::int then raise exception 'VERSION_CONFLICT';end if;
 if row.status<>'expected'then raise exception 'EXTERNAL_ALREADY_FINAL';end if;
 else raise exception 'INVALID_ACTION';end if;
 if act='receive' or(act='create'and coalesce((p->>'received')::boolean,false))then
 d:=(p->>'received_date')::date;
 if d is null or d>(now()at time zone 'Asia/Bangkok')::date then raise exception 'INVALID_DATE';end if;
 insert into public.batch_cash(batch_id,cash_date,kind,amount,reference_id,note,request_id,created_by)values(b,d,'external_contribution',row.amount,row.id,'เงินสมทบจาก '||row.source_name||' · '||row.reference,p_request,auth.uid())returning id into cash;
 update public.external_funds set status='received',received_date=d,cash_id=cash,version=version+1 where id=row.id returning * into row;
 elsif act='cancel'then update public.external_funds set status='cancelled',version=version+1 where id=row.id returning * into row;end if;
 return private.finish_request(p_request,'external_fund',p,to_jsonb(row));
end$$;
revoke all on function public.external_fund_manage(jsonb,uuid)from public,anon,authenticated;
grant execute on function public.external_fund_manage(jsonb,uuid)to authenticated;
create or replace function public.settings_status()returns jsonb language plpgsql security definer set search_path='' as $$begin
 if not exists(select 1 from public.profiles where id=auth.uid()and approved)then raise exception 'NO_ACCESS';end if;
 return jsonb_build_object('server_time',now(),'database_version','009','approved',true,'admin',private.is_admin());end$$;
commit;
notify pgrst,'reload schema';
