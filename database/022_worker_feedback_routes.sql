-- 0.14: free-form worker drafts and persistent rich-menu routes.
begin;
create or replace function private.parse_worker_sale(raw text,b uuid,d date)returns jsonb language plpgsql security definer set search_path='' as $$declare prices jsonb;items jsonb:='[]';ln text;original text;ignored jsonb:='[]';matched text[];size text;qty numeric;mult int;it jsonb;begin
if length(coalesce(raw,''))not between 1 and 8000 then raise exception 'INVALID_MESSAGE';end if;prices:=private.worker_prices(b,d);
for original in select regexp_split_to_table(raw,E'\n+')loop
ln:=regexp_replace(regexp_replace(original,'\([^()]*\)|（[^（）]*）','','g'),'\s+','','g');if ln=''then continue;end if;
matched:=regexp_match(ln,'^(.+?)=([0-9]+(?:\.[0-9]+)?)(ตั้ง|แผง|ฟอง|ใบ)');
if matched is null then ignored:=ignored||jsonb_build_array(original);continue;end if;mult:=case matched[3]when 'ตั้ง'then 300 when 'แผง'then 30 else 1 end;size:=regexp_replace(matched[1],'^(เศษ|ศ\.)','');qty:=matched[2]::numeric*mult;it:=null;
if size like '%บุบ%'or size like '%บาง%'then select value into it from jsonb_array_elements(prices->'items')where value->>'grade'=case when size like '%บุบ%'then 'บุบ'else 'บาง'end or value->>'grade'=case when size like '%บุบ%'then 'ไข่บุบ'else 'ไข่บาง'end limit 1;
elsif size~'^[0-9]+(\.[0-9]+)?$'then select value into it from jsonb_array_elements(prices->'items')where value->>'grade'~'^[0-9]+(\.[0-9]+)?$'and case when value->>'grade'~'^[0-9]+(\.[0-9]+)?$'then(value->>'grade')::numeric<=size::numeric else false end order by(value->>'grade')::numeric desc limit 1;
else select value into it from jsonb_array_elements(prices->'items')where value->>'grade'=size limit 1;end if;
if it is null or qty<=0 or qty<>trunc(qty)then ignored:=ignored||jsonb_build_array(original);continue;end if;
items:=items||jsonb_build_array(jsonb_build_object('price_item_id',it->>'id','display_name',it->>'display_name','grade',it->>'grade','pieces',qty,'unit_price',(it->>'price')::numeric,'discount',0));end loop;
if jsonb_array_length(items)>100 then raise exception 'INVALID_SALE_ITEMS';end if;
return jsonb_build_object('sale_type','egg','buyer',coalesce((select default_buyer from public.batches where id=b),'ยังไม่ระบุผู้ซื้อ'),'items',items,'raw_message',raw,'ignored_lines',ignored);
end$$;

do $$declare d text;begin
 select pg_get_functiondef('public.worker_submit_v080(text,jsonb,uuid)'::regprocedure)into d;
 d:=replace(d,'not between 1 and 50','not between 0 and 100');d:=replace(d,'>12000','>120000');
 d:=replace(d,'q:=jsonb_set(q,''{items}'',(select jsonb_agg','q:=jsonb_set(q,''{items}'',coalesce((select jsonb_agg');
 d:=replace(d,'from jsonb_array_elements(q->''items'')item));','from jsonb_array_elements(q->''items'')item),''[]''));');execute d;
end$$;
create table private.worker_routes(id uuid primary key default gen_random_uuid(),route_key text not null unique default replace(gen_random_uuid()::text||gen_random_uuid()::text,'-',''),created_by uuid not null references public.profiles,name text not null check(length(name)between 1 and 100),link_id uuid references public.access_links on delete set null,test_mode boolean not null,liff_id text,active boolean not null default true,version int not null default 1,created_at timestamptz not null default now());
revoke all on private.worker_routes from public,anon,authenticated;
create function public.worker_route_list()returns jsonb language plpgsql security definer set search_path='' as $$begin
 if not private.feature_allowed('farm.links',true)then raise exception 'NO_ACCESS';end if;
 return coalesce((select jsonb_agg(to_jsonb(r)order by created_at desc)from private.worker_routes r where created_by=auth.uid()),'[]');end$$;
create function public.worker_route_manage(p_data jsonb,p_request uuid)returns jsonb language plpgsql security definer set search_path='' as $$declare r private.worker_routes;l public.access_links;result jsonb;begin
 perform private.feed_lock();if not private.feature_allowed('farm.links',true)then raise exception 'NO_ACCESS';end if;
 result:=private.request_result(p_request,'worker-route-v14',p_data);if result is not null then return result;end if;
 if p_data->>'action'<>'create'then
  select * into strict r from private.worker_routes where id=(p_data->>'id')::uuid for update;
  if r.created_by<>auth.uid()then raise exception 'NO_ACCESS';end if;
  if r.version is distinct from(p_data->>'version')::int then raise exception 'VERSION_CONFLICT';end if;
 end if;
 if p_data->>'action'in('create','edit')then
  select * into strict l from public.access_links where id=(p_data->>'link_id')::uuid;
  if not private.can_batch(l.batch_id,'farm',true)or not private.can_batch(l.batch_id,'finance')then raise exception 'NO_ACCESS';end if;
  if l.kind<>'liff'or l.revoked or l.expires_at<=now()or exists(select 1 from public.batches where id=l.batch_id and status='closed')then raise exception 'LINK_EXPIRED';end if;
  if p_data->>'action'='create'then
   insert into private.worker_routes(created_by,name,link_id,test_mode,liff_id)values(auth.uid(),trim(p_data->>'name'),l.id,l.test_mode,l.liff_id)returning * into r;
  else
   if r.test_mode<>l.test_mode then raise exception 'LINK_MODE_IMMUTABLE';end if;
   if r.liff_id is distinct from l.liff_id then raise exception 'ROUTE_LIFF_ID_MISMATCH';end if;
   update private.worker_routes set name=trim(p_data->>'name'),link_id=l.id,active=true,version=version+1 where id=r.id returning * into r;
  end if;
 elsif p_data->>'action'='disable'then update private.worker_routes set active=false,version=version+1 where id=r.id returning * into r;
 else raise exception 'UNKNOWN_ACTION';end if;
 return private.finish_request(p_request,'worker-route-v14',p_data,to_jsonb(r));end$$;
create function public.worker_route_resolve(p_route text)returns jsonb language plpgsql security definer set search_path='' as $$declare r private.worker_routes;t text;l public.access_links;begin
 if length(p_route)is distinct from 64 then raise exception 'LINK_EXPIRED';end if;
 select * into r from private.worker_routes where route_key=p_route and active;if not found then raise exception 'LINK_EXPIRED';end if;
 select token into t from private.access_secrets where link_id=r.link_id;l:=private.access_valid(t);
 if l.kind<>'liff'or l.test_mode<>r.test_mode or l.liff_id is distinct from r.liff_id then raise exception 'LINK_EXPIRED';end if;
 return jsonb_build_object('token',t);end$$;
revoke all on function public.worker_route_list(),public.worker_route_manage(jsonb,uuid),public.worker_route_resolve(text)from public,anon,authenticated;
grant execute on function public.worker_route_list(),public.worker_route_manage(jsonb,uuid)to authenticated;
grant execute on function public.worker_route_resolve(text)to anon,authenticated;
create or replace function public.settings_status()returns jsonb language plpgsql security definer set search_path='' as $$begin if not exists(select 1 from public.profiles where id=auth.uid()and approved)then raise exception 'NO_ACCESS';end if;return jsonb_build_object('server_time',now(),'database_version','022 / 0.14.0','approved',true,'admin',private.is_admin());end$$;
commit;
notify pgrst,'reload schema';
