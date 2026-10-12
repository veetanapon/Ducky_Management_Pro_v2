begin;
alter table public.batches add column purchase_unit_price numeric(16,4)check(purchase_unit_price>=0 and purchase_unit_price<=1000000000),add column parent_batch_id uuid references public.batches,add column default_buyer text;
create table public.buyers(id uuid primary key default gen_random_uuid(),owner_id uuid not null default auth.uid()references public.profiles,name text not null check(length(trim(name))between 1 and 200),active boolean not null default true);
create table public.wallets(id uuid primary key default gen_random_uuid(),owner_id uuid not null default auth.uid()references public.profiles,name text not null check(length(trim(name))between 1 and 100));
create table public.wallet_entries(id uuid primary key default gen_random_uuid(),wallet_id uuid not null references public.wallets,entry_date date not null,amount numeric(16,2)not null,transfer_id uuid not null,note text);
create table public.sale_settlements(id uuid primary key default gen_random_uuid(),batch_id uuid not null references public.batches on delete cascade,received_date date not null,gross numeric(16,2)not null,withheld numeric(16,2)not null default 0,external_gross numeric(16,2)not null default 0,external_withheld numeric(16,2)not null default 0,note text,created_by uuid references public.profiles,created_at timestamptz default now());
create table public.tax_records(id uuid primary key default gen_random_uuid(),batch_id uuid not null references public.batches on delete cascade,log_date date not null,amount numeric(16,2)not null check(amount>0),source text not null check(source in('withheld','external_withheld','paid')),reference_id uuid,note text,created_by uuid references public.profiles);
alter table public.sales add column payment_status text not null default 'unpaid'check(payment_status in('unpaid','paid')),add column settlement_id uuid references public.sale_settlements;
-- Preserve already received legacy invoices; do not reverse existing money.
update public.sales set payment_status='paid'where cash_id is not null;
do $$declare t text;begin for t in select unnest(array['buyers','wallets','wallet_entries','sale_settlements','tax_records'])loop execute format('alter table public.%I enable row level security',t);execute format('revoke all on public.%I from public,anon,authenticated',t);execute format('grant select on public.%I to authenticated',t);execute format('grant all on public.%I to service_role',t);end loop;end$$;
create policy buyers_read on public.buyers for select to authenticated using(owner_id=auth.uid()and private.feature_allowed('farm.sales'));
create policy wallets_read on public.wallets for select to authenticated using(owner_id=auth.uid()and private.feature_allowed('finance.wallets'));
create policy wallet_entries_read on public.wallet_entries for select to authenticated using(private.feature_allowed('finance.wallets')and exists(select 1 from public.wallets w where w.id=wallet_id and owner_id=auth.uid()));
create policy settlements_read on public.sale_settlements for select to authenticated using(private.can_batch(batch_id,'finance')and(private.feature_allowed('farm.sales')or private.feature_allowed('finance.cash')));
create policy tax_read on public.tax_records for select to authenticated using(private.can_batch(batch_id,'finance')and private.feature_allowed('finance.tax'));
-- No cash entry when posting a new sale; explicit receipt writes the ledger later.
do $$declare d text;begin select pg_get_functiondef('private.farm_apply_v040(jsonb)'::regprocedure)into d;
d:=replace(d,'insert into public.batch_cash(batch_id,cash_date,kind,amount,reference_id,note,created_by)values(b,d,''receipt'',tot,sid,''ขาย ''||typ||'' • ''||coalesce(p->>''buyer'',''''),auth.uid())returning id into cid;','cid:=null;');
d:=replace(d,'cost:=round(q*price-private.farm_num(row,''discount''),2);','cost:=case when nullif(row->>''line_total'','''')is not null then round(private.farm_num(row,''line_total''),2)else round(q*price-private.farm_num(row,''discount''),2)end;');
d:=replace(d,'if private.cash_available(b,s.sale_date)<s.total then','if s.payment_status=''paid''then raise exception ''PAID_SALE_LOCKED'';end if; if s.cash_id is not null and private.cash_available(b,s.sale_date)<s.total then');
d:=replace(d,'insert into public.batch_cash(batch_id,cash_date,kind,amount,reference_id,note,created_by)values(b,s.sale_date,''expense'',-s.total,s.id,''ยกเลิกบิล: ''||coalesce(p->>''note'',''''),auth.uid());','null;');execute d;
end$$;
alter function public.batch_save(jsonb,uuid)rename to batch_save_v090;revoke all on function public.batch_save_v090(jsonb,uuid)from public,anon,authenticated;
create function public.batch_save(p_data jsonb,p_request uuid)returns jsonb language plpgsql security definer set search_path='' as $$declare r jsonb;par uuid:=nullif(p_data->>'parent_batch_id','')::uuid;begin
if not private.is_admin()then raise exception 'NO_ACCESS';end if;perform private.feed_lock();r:=private.request_result(p_request,'batch-v10',p_data);if r is not null then return r;end if;
if par is not null and (p_data->>'species_id'<>'fish'or not exists(select 1 from public.batches where id=par and species_id='duck')or par=(p_data->>'id')::uuid)then raise exception 'INVALID_PARENT_BATCH';end if;
r:=public.batch_save_v090(p_data,gen_random_uuid());update public.batches set purchase_unit_price=nullif(p_data->>'purchase_unit_price','')::numeric,parent_batch_id=par,default_buyer=nullif(trim(p_data->>'default_buyer'),'')where id=(p_data->>'id')::uuid;
if p_data?'linked_fish'then
if p_data->>'species_id'<>'duck'or jsonb_typeof(p_data->'linked_fish')<>'array'then raise exception 'INVALID_LINKED_FISH';end if;
if exists(select 1 from jsonb_array_elements_text(p_data->'linked_fish')x where not exists(select 1 from public.batches f where f.id=x.value::uuid and f.species_id='fish'and(f.parent_batch_id is null or f.parent_batch_id=(p_data->>'id')::uuid)))then raise exception 'FISH_ALREADY_LINKED_OR_INVALID';end if;
update public.batches set parent_batch_id=null,version=version+1 where parent_batch_id=(p_data->>'id')::uuid and id not in(select value::uuid from jsonb_array_elements_text(p_data->'linked_fish'));
update public.batches set parent_batch_id=(p_data->>'id')::uuid,version=version+1 where id in(select value::uuid from jsonb_array_elements_text(p_data->'linked_fish'))and parent_batch_id is distinct from(p_data->>'id')::uuid;
end if;
return private.finish_request(p_request,'batch-v10',p_data,r);end$$;
revoke all on function public.batch_save(jsonb,uuid)from public,anon;grant execute on function public.batch_save(jsonb,uuid)to authenticated;
create function public.account_manage(p_data jsonb,p_request uuid)returns jsonb language plpgsql security definer set search_path='' as $$
declare p jsonb:=p_data;act text:=p->>'action';b uuid:=nullif(p->>'batch_id','')::uuid;d date:=(p->>'log_date')::date;r jsonb;sid uuid:=gen_random_uuid();ids uuid[];gross numeric;tax numeric;ext numeric;exttax numeric;amt numeric;bal numeric;endpoint text;eid uuid;idx int;qty int;begin
perform private.feed_lock();
if act='buyer'then if not private.feature_allowed('farm.sales',true)then raise exception 'NO_ACCESS';end if;
elsif act in('wallet','transfer')then if not private.feature_allowed('finance.wallets',true)then raise exception 'NO_ACCESS';end if;
elsif not private.can_batch(b,'finance',true)or not private.feature_allowed(case when act='settle'then 'farm.sales'else 'finance.tax'end,true)then raise exception 'NO_ACCESS';end if;
r:=private.request_result(p_request,'account-v10',p);if r is not null then return r;end if;
if act in('buyer','wallet')then
if act='buyer'then insert into public.buyers(name)values(trim(p->>'name'))returning id into sid;else insert into public.wallets(name)values(trim(p->>'name'))returning id into sid;end if;
else
if d is null or d>(now()at time zone 'Asia/Bangkok')::date then raise exception 'INVALID_DATE';end if;
if act='settle'then
ids:=array(select jsonb_array_elements_text(p->'sale_ids')::uuid);qty:=cardinality(ids);if qty not between 1 and 100 or (select count(distinct x)from unnest(ids)x)<>qty then raise exception 'INVALID_BILLS';end if;
if (select count(*)from public.sales where id=any(ids)and batch_id=b and status='posted'and payment_status='unpaid'and sale_date<=d)<>qty then raise exception 'BILL_ALREADY_PAID_OR_INVALID';end if;
select sum(total)into gross from public.sales where id=any(ids);tax:=round(private.farm_num(p,'withheld'),2);ext:=round(private.farm_num(p,'external_gross'),2);exttax:=round(private.farm_num(p,'external_withheld'),2);
if tax>gross or exttax>ext then raise exception 'INVALID_WITHHOLDING';end if;
if (tax+exttax)>0 and not private.feature_allowed('finance.tax',true)then raise exception 'NO_TAX_ACCESS';end if;
insert into public.sale_settlements(id,batch_id,received_date,gross,withheld,external_gross,external_withheld,note,created_by)values(sid,b,d,gross,tax,ext,exttax,p->>'note',auth.uid());
insert into public.batch_cash(batch_id,cash_date,kind,amount,reference_id,note,created_by)values(b,d,'receipt',gross-tax,sid,'รับบิลรวม: '||coalesce(p->>'note',''),auth.uid());
if ext>exttax then insert into public.batch_cash(batch_id,cash_date,kind,amount,reference_id,note,created_by)values(b,d,'external_contribution',ext-exttax,sid,'รับเงินเล้านอกระบบในบิลรวม',auth.uid());end if;
if tax>0 then insert into public.tax_records(batch_id,log_date,amount,source,reference_id,note,created_by)values(b,d,tax,'withheld',sid,p->>'note',auth.uid());end if;
if exttax>0 then insert into public.tax_records(batch_id,log_date,amount,source,reference_id,note,created_by)values(b,d,exttax,'external_withheld',sid,p->>'note',auth.uid());end if;
update public.sales set payment_status='paid',settlement_id=sid where id=any(ids);
elsif act='tax'then
amt:=round(private.farm_num(p,'amount'),2);if amt<=0 or private.cash_available(b,d)<amt then raise exception 'INSUFFICIENT_BATCH_CASH';end if;
insert into public.tax_records(id,batch_id,log_date,amount,source,note,created_by)values(sid,b,d,amt,'paid',p->>'note',auth.uid());
insert into public.batch_cash(batch_id,cash_date,kind,amount,reference_id,note,created_by)values(b,d,'expense',-amt,sid,'จ่ายภาษี: '||coalesce(p->>'note',''),auth.uid());
elsif act='transfer'then
amt:=round(private.farm_num(p,'amount'),2);if amt<=0 or p->>'from'=p->>'to'then raise exception 'INVALID_TRANSFER';end if;
for idx in 1..2 loop endpoint:=case idx when 1 then p->>'from'else p->>'to'end;eid:=split_part(endpoint,':',2)::uuid;
if split_part(endpoint,':',1)='batch'then
 if not private.can_batch(eid,'finance',true)or not exists(select 1 from public.batches where id=eid and start_date<=d)then raise exception 'NO_ACCESS';end if;
 if idx=1 and private.cash_available(eid,d)<amt then raise exception 'INSUFFICIENT_BATCH_CASH';end if;
 insert into public.batch_cash(batch_id,cash_date,kind,amount,reference_id,note,created_by)values(eid,d,'savings_transfer',case idx when 1 then -amt else amt end,sid,'โอน: '||coalesce(p->>'note',''),auth.uid());
elsif split_part(endpoint,':',1)='wallet'then
 if not exists(select 1 from public.wallets where id=eid and owner_id=auth.uid())then raise exception 'NO_ACCESS';end if;
 with days as(select entry_date,sum(amount)amount from public.wallet_entries where wallet_id=eid group by entry_date), running as(select entry_date,sum(amount)over(order by entry_date)balance from days), candidates as(select coalesce(sum(amount),0)balance from public.wallet_entries where wallet_id=eid and entry_date<=d union all select balance from running where entry_date>d)select coalesce(min(balance),0)into bal from candidates;if idx=1 and bal<amt then raise exception 'INSUFFICIENT_WALLET_CASH';end if;
 insert into public.wallet_entries(wallet_id,entry_date,amount,transfer_id,note)values(eid,d,case idx when 1 then -amt else amt end,sid,p->>'note');
else raise exception 'INVALID_ACCOUNT';end if;end loop;
else raise exception 'UNKNOWN_ACTION';end if;end if;
return private.finish_request(p_request,'account-v10',p,jsonb_build_object('id',sid));end$$;
revoke all on function public.account_manage(jsonb,uuid)from public,anon;grant execute on function public.account_manage(jsonb,uuid)to authenticated;
commit;notify pgrst,'reload schema';
