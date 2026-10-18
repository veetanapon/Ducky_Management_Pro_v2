begin;
alter table public.sales add column if not exists external_items jsonb not null default '[]';
create or replace function private.external_sale_items(items jsonb, typ text) returns jsonb
language plpgsql immutable set search_path='' as $$
declare x jsonb; result jsonb:='[]'; q numeric; price numeric; discount numeric; total numeric; k text; n numeric;
begin
 if items is null then return result; end if;
 if jsonb_typeof(items)<>'array' or jsonb_array_length(items)>100 then raise exception 'INVALID_EXTERNAL_ITEMS'; end if;
 for x in select value from jsonb_array_elements(items) loop
  if jsonb_typeof(x)<>'object' or length(trim(coalesce(x->>'display_name',''))) not between 1 and 200 then raise exception 'EXTERNAL_ITEM_NAME_REQUIRED'; end if;
  foreach k in array array['stacks','trays','pieces','qty','unit_price','discount'] loop
   n:=coalesce(nullif(x->>k,''),'0')::numeric;
   if n<0 or n>100000000 or n::text in ('NaN','Infinity','-Infinity') then raise exception 'INVALID_EXTERNAL_NUMBER'; end if;
   if typ='egg' and k in ('stacks','trays','pieces') and n<>trunc(n) then raise exception 'INTEGER_REQUIRED'; end if;
  end loop;
  q:=case when typ='egg' then coalesce((x->>'stacks')::numeric,0)*300+coalesce((x->>'trays')::numeric,0)*30+coalesce((x->>'pieces')::numeric,0) else (x->>'qty')::numeric end;
  if q is null or q<=0 or (typ='duck' and q<>trunc(q)) then raise exception 'INVALID_EXTERNAL_QUANTITY'; end if;
  price:=coalesce(nullif(x->>'unit_price',''),'0')::numeric;
  discount:=coalesce(nullif(x->>'discount',''),'0')::numeric;
  if nullif(x->>'line_total','') is not null then
   total:=(x->>'line_total')::numeric;discount:=0;price:=total/q;
  else total:=round(q*price-discount,2); end if;
  if total<0 or total>100000000000 or total::text in ('NaN','Infinity','-Infinity') then raise exception 'INVALID_EXTERNAL_TOTAL'; end if;
  result:=result||jsonb_build_array(jsonb_build_object('display_name',trim(x->>'display_name'),'qty',q,'unit',case typ when 'egg' then 'ฟอง' when 'duck' then 'ตัว' else 'กก.' end,'unit_price',price,'discount',discount,'total',round(total,2),'entry',x));
 end loop;
 return result;
end;$$;
revoke all on function private.external_sale_items(jsonb,text) from public,anon,authenticated;
-- Attach document-only data inside the existing sale transaction, including approvals.
do $$declare definition text; anchor text:='if typ=''egg''then prices:=public.price_resolve(b,d);end if;';begin
 definition:=pg_get_functiondef('private.farm_apply_v040(jsonb)'::regprocedure);
 if position('private.external_sale_items' in definition)=0 then
  if position(anchor in definition)=0 then raise exception 'SALE_FUNCTION_VERSION_MISMATCH';end if;
  definition:=replace(definition,anchor,'update public.sales set external_items=private.external_sale_items(p->''external_items'',typ) where id=sid; '||anchor);
  execute definition;
 end if;
end;$$;
notify pgrst,'reload schema';
commit;
