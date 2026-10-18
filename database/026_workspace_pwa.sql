-- 0.15.0: receipt attachments per batch, flexible worker prefixes. Run after 025.
begin;
alter table public.workspace_images drop constraint if exists workspace_images_kind_check;
alter table public.workspace_images add constraint workspace_images_kind_check check(kind in('logo','farm','batch','payment_qr'));
do $$declare body text;f regprocedure;begin
 foreach f in array array['public.workspace_image(text,uuid)'::regprocedure,'public.settings_manage_v080(jsonb,uuid)'::regprocedure]loop
 select pg_get_functiondef(f)into body;
 body:=replace(body,$s$p_kind='batch'$s$,$s$p_kind in('batch','payment_qr')$s$);
 body:=replace(body,$s$image_kind='batch'$s$,$s$image_kind in('batch','payment_qr')$s$);
 execute body;
 end loop;
end$$;
create or replace function private.parse_worker_sale(raw text,b uuid,d date)returns jsonb language plpgsql security definer set search_path='' as $$declare prices jsonb;items jsonb:='[]';ln text;original text;ignored jsonb:='[]';matched text[];size text;qty numeric;mult int;it jsonb;begin
if length(coalesce(raw,''))not between 1 and 8000 then raise exception 'INVALID_MESSAGE';end if;prices:=private.worker_prices(b,d);
for original in select regexp_split_to_table(raw,E'\n+')loop
ln:=regexp_replace(regexp_replace(original,'\([^()]*\)|（[^（）]*）','','g'),'\s+','','g');if ln=''then continue;end if;
matched:=regexp_match(ln,'^(.+?)=([0-9]+(?:\.[0-9]+)?)(ตั้ง|แผง|ฟอง|ใบ)');
if matched is null then ignored:=ignored||jsonb_build_array(original);continue;end if;mult:=case matched[3]when 'ตั้ง'then 300 when 'แผง'then 30 else 1 end;size:=regexp_replace(matched[1],'^(เศษ|ศ\.)','');if size~'[0-9]+(\.[0-9]+)?$'then size:=substring(size from '([0-9]+(?:\.[0-9]+)?)$');end if;qty:=matched[2]::numeric*mult;it:=null;
if size like '%บุบ%'or size like '%บาง%'then select value into it from jsonb_array_elements(prices->'items')where value->>'grade'=case when size like '%บุบ%'then 'บุบ'else 'บาง'end or value->>'grade'=case when size like '%บุบ%'then 'ไข่บุบ'else 'ไข่บาง'end limit 1;
elsif size~'^[0-9]+(\.[0-9]+)?$'then select value into it from jsonb_array_elements(prices->'items')where value->>'grade'~'^[0-9]+(\.[0-9]+)?$'and case when value->>'grade'~'^[0-9]+(\.[0-9]+)?$'then(value->>'grade')::numeric<=size::numeric else false end order by(value->>'grade')::numeric desc limit 1;
else select value into it from jsonb_array_elements(prices->'items')where right(size,length(value->>'grade'))=value->>'grade'order by length(value->>'grade')desc limit 1;end if;
if it is null or qty<=0 or qty<>trunc(qty)then ignored:=ignored||jsonb_build_array(original);continue;end if;
items:=items||jsonb_build_array(jsonb_build_object('price_item_id',it->>'id','display_name',it->>'display_name','grade',it->>'grade','pieces',qty,'unit_price',(it->>'price')::numeric,'discount',0));end loop;
if jsonb_array_length(items)>100 then raise exception 'INVALID_SALE_ITEMS';end if;
return jsonb_build_object('sale_type','egg','buyer',coalesce((select default_buyer from public.batches where id=b),'ยังไม่ระบุผู้ซื้อ'),'items',items,'raw_message',raw,'ignored_lines',ignored);
end$$;

commit;
notify pgrst,'reload schema';
