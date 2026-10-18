begin;
alter table public.sales add column if not exists document_only boolean not null default false;
do $$
declare definition text; old_guard text:='jsonb_array_length(p->''items'')not between 1 and 100';
anchor text:='update public.sales set external_items=private.external_sale_items(p->''external_items'',typ) where id=sid;';
begin
 definition:=pg_get_functiondef('private.farm_apply_v040(jsonb)'::regprocedure);
 if position('document_only=true' in definition)=0 then
  if position(old_guard in definition)=0 or position(anchor in definition)=0 then raise exception 'Run SQL 029 before 030';end if;
  definition:=replace(definition,old_guard,'jsonb_array_length(p->''items'')not between 0 and 100');
  definition:=replace(definition,anchor,anchor||'
  if jsonb_array_length(p->''items'')=0 then
   if jsonb_array_length((select external_items from public.sales where id=sid))=0 then raise exception ''SALE_ITEMS_REQUIRED'';end if;
   update public.sales set document_only=true where id=sid;
   return jsonb_build_object(''id'',sid,''total'',0,''document_only'',true);
  end if;');
  execute definition;
 end if;
end;$$;
-- A document-only bill never becomes a cash receipt, even through a direct API call.
create or replace function private.guard_external_only_bill()returns trigger language plpgsql set search_path='' as $$begin
 if new.document_only and (new.total<>0 or new.cash_id is not null or new.settlement_id is not null or new.payment_status='paid') then
  raise exception 'EXTERNAL_ONLY_DOCUMENT_NOT_RECEIVABLE';
 end if;
 return new;
end;$$;
revoke all on function private.guard_external_only_bill()from public,anon,authenticated;
drop trigger if exists external_only_bill_guard on public.sales;
create trigger external_only_bill_guard before insert or update on public.sales for each row execute function private.guard_external_only_bill();
notify pgrst,'reload schema';
commit;
