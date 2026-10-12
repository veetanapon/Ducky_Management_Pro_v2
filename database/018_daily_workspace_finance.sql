-- Run once after 017 in V2. Wallet cash entries and withholding on shared outside funds.
begin;
alter table public.external_funds add column withheld numeric(16,2)not null default 0 check(withheld>=0 and withheld<=amount);
alter function public.external_fund_manage(jsonb,uuid)rename to external_fund_manage_v100;
revoke all on function public.external_fund_manage_v100(jsonb,uuid)from public,anon,authenticated;
create function public.external_fund_manage(p_data jsonb,p_request uuid)returns jsonb language plpgsql security definer set search_path='' as $$
declare r jsonb;old public.external_funds;b uuid;tax numeric;gross numeric;receiving boolean;begin
perform private.feed_lock();
if p_data->>'action'='create'then b:=(p_data->>'batch_id')::uuid;gross:=private.farm_num(p_data,'amount');else select * into strict old from public.external_funds where id=(p_data->>'id')::uuid;b:=old.batch_id;gross:=old.amount;end if;
if not private.can_batch(b,'finance',true)then raise exception 'NO_ACCESS';end if;
r:=private.request_result(p_request,'external-tax',p_data);if r is not null then return r;end if;
tax:=round(case when p_data?'withheld'then private.farm_num(p_data,'withheld')else coalesce(old.withheld,0)end,2);
if tax>gross then raise exception 'INVALID_WITHHOLDING';end if;
if tax>0 and not private.feature_allowed('finance.tax',true)then raise exception 'NO_TAX_ACCESS';end if;
r:=public.external_fund_manage_v100(p_data,gen_random_uuid());
update public.external_funds set withheld=tax where id=(r->>'id')::uuid returning * into old;
if old.status='received'then
update public.batch_cash set amount=old.amount-tax where id=old.cash_id;
if tax>0 then insert into public.tax_records(batch_id,log_date,amount,source,reference_id,note,created_by)values(b,old.received_date,tax,'external_withheld',old.id,old.source_name||' · '||old.reference,auth.uid());end if;
end if;
return private.finish_request(p_request,'external-tax',p_data,to_jsonb(old));end$$;
revoke all on function public.external_fund_manage(jsonb,uuid)from public,anon;grant execute on function public.external_fund_manage(jsonb,uuid)to authenticated;
alter function public.account_manage(jsonb,uuid)rename to account_manage_v100;
revoke all on function public.account_manage_v100(jsonb,uuid)from public,anon,authenticated;
create function public.account_manage(p_data jsonb,p_request uuid)returns jsonb language plpgsql security definer set search_path='' as $$
declare w uuid:=(p_data->>'wallet_id')::uuid;d date:=(p_data->>'log_date')::date;a numeric;bal numeric;r jsonb;entry uuid:=gen_random_uuid();begin
if p_data->>'action'<>'wallet_entry'then return public.account_manage_v100(p_data,p_request);end if;
perform private.feed_lock();
if not private.feature_allowed('finance.wallets',true)or not exists(select 1 from public.wallets where id=w and owner_id=auth.uid())then raise exception 'NO_ACCESS';end if;
r:=private.request_result(p_request,'wallet-entry',p_data);if r is not null then return r;end if;
a:=round(private.farm_num(p_data,'amount'),2);
if a<=0 or d is null or d>(now()at time zone 'Asia/Bangkok')::date or coalesce(p_data->>'kind','')not in('receipt','expense')or length(trim(coalesce(p_data->>'note','')))=0 then raise exception 'INVALID_WALLET_ENTRY';end if;
if p_data->>'kind'='expense'then
with days as(select entry_date,sum(amount)amount from public.wallet_entries where wallet_id=w group by entry_date),running as(select entry_date,sum(amount)over(order by entry_date)balance from days),candidates as(select coalesce(sum(amount),0)balance from public.wallet_entries where wallet_id=w and entry_date<=d union all select balance from running where entry_date>d)select coalesce(min(balance),0)into bal from candidates;
if bal<a then raise exception 'INSUFFICIENT_WALLET_CASH';end if;a:=-a;end if;
insert into public.wallet_entries(id,wallet_id,entry_date,amount,transfer_id,note)values(entry,w,d,a,entry,p_data->>'note');
return private.finish_request(p_request,'wallet-entry',p_data,jsonb_build_object('id',entry));end$$;
revoke all on function public.account_manage(jsonb,uuid)from public,anon;grant execute on function public.account_manage(jsonb,uuid)to authenticated;
create or replace function public.settings_status()returns jsonb language plpgsql security definer set search_path='' as $$begin
if not exists(select 1 from public.profiles where id=auth.uid()and approved)then raise exception 'NO_ACCESS';end if;
return jsonb_build_object('server_time',now(),'database_version','018 / 0.10.1','approved',true,'admin',private.is_admin());end$$;
commit;notify pgrst,'reload schema';
