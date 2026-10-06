-- Ducky 0.6.0: run once after 007 in the V2 project.
begin;
create table public.workspace_branding(id boolean primary key default true check(id),farm_name text not null default 'ฟาร์ม',version integer not null default 1);
insert into public.workspace_branding default values;
create table public.workspace_images(kind text not null check(kind in('logo','farm','batch')),target_id uuid not null,image_data text check(length(image_data)<=400000 and image_data ~ '^data:image/jpeg;base64,[A-Za-z0-9+/=]+$'),version integer not null default 1,updated_at timestamptz not null default now(),primary key(kind,target_id));
alter table public.workspace_branding enable row level security;alter table public.workspace_images enable row level security;
revoke all on public.workspace_branding,public.workspace_images from public,anon,authenticated;
grant select on public.workspace_branding to authenticated;
grant all on public.workspace_branding,public.workspace_images to service_role;
create policy branding_read on public.workspace_branding for select to authenticated using(exists(select 1 from public.profiles where id=auth.uid()and approved));
create trigger branding_audit after insert or update or delete on public.workspace_branding for each row execute function private.audit_change();
-- Image content intentionally omitted from general audit payloads; version metadata is retained on the image row.
create function public.workspace_image(p_kind text,p_target uuid)returns jsonb language plpgsql security definer set search_path='' as $$declare r jsonb;begin
 if not exists(select 1 from public.profiles where id=auth.uid()and approved)then raise exception 'NO_ACCESS';end if;
 if p_kind is null or p_target is null then raise exception 'INVALID_TARGET';end if;
 if p_kind='batch'then if not private.can_batch(p_target,'farm')then raise exception 'NO_ACCESS';end if;
 elsif p_kind not in('logo','farm')or p_target<>'00000000-0000-0000-0000-000000000001'::uuid then raise exception 'INVALID_TARGET';end if;
 select jsonb_build_object('data',image_data,'version',version)into r from public.workspace_images where kind=p_kind and target_id=p_target;return coalesce(r,jsonb_build_object('data',null,'version',0));end$$;
create function public.settings_manage(p_data jsonb,p_request uuid)returns jsonb language plpgsql security definer set search_path='' as $$
declare p jsonb:=p_data;act text:=p->>'action';ret jsonb;v int;target uuid;image_kind text;image text;begin
 if not exists(select 1 from public.profiles where id=auth.uid()and approved)then raise exception 'NO_ACCESS';end if;
 perform private.feed_lock();ret:=private.request_result(p_request,'settings',p);if ret is not null then return ret;end if;
 if act='profile'then
 if length(trim(coalesce(p->>'name','')))not between 1 and 200 then raise exception 'NAME_REQUIRED';end if;
 update public.profiles set display_name=trim(p->>'name')where id=auth.uid();ret:=jsonb_build_object('saved',true);
 elsif act='branding'then
 if not private.is_admin()then raise exception 'NO_ACCESS';end if;
 if length(trim(coalesce(p->>'name','')))not between 1 and 200 then raise exception 'NAME_REQUIRED';end if;
 update public.workspace_branding set farm_name=trim(p->>'name'),version=version+1 where id=true and version=(p->>'version')::int returning version into v;if not found then raise exception 'VERSION_CONFLICT';end if;ret:=jsonb_build_object('version',v);
 elsif act='image'then
 image_kind:=p->>'kind';target:=(p->>'target_id')::uuid;image:=nullif(p->>'data','');
 if target is null then raise exception 'INVALID_TARGET';end if;
 if image_kind='batch'then if not private.can_batch(target,'farm',true)or not exists(select 1 from public.batches where id=target)then raise exception 'NO_ACCESS';end if;
 elsif image_kind in('logo','farm')then if not private.is_admin()or target<>'00000000-0000-0000-0000-000000000001'::uuid then raise exception 'NO_ACCESS';end if;
 else raise exception 'INVALID_TARGET';end if;
 select version into v from public.workspace_images where kind=image_kind and target_id=target;
 if coalesce(v,0)is distinct from (p->>'version')::int then raise exception 'VERSION_CONFLICT';end if;
 if image is not null and(length(image)>400000 or image!~'^data:image/jpeg;base64,[A-Za-z0-9+/=]+$'or substring(decode(split_part(image,',',2),'base64')from 1 for 3)<>decode('ffd8ff','hex'))then raise exception 'INVALID_IMAGE';end if;
 insert into public.workspace_images(kind,target_id,image_data,version)values(image_kind,target,image,coalesce(v,0)+1)on conflict(kind,target_id)do update set image_data=excluded.image_data,version=excluded.version,updated_at=now();ret:=jsonb_build_object('version',coalesce(v,0)+1);
 else raise exception 'UNKNOWN_SETTINGS_ACTION';end if;
 return private.finish_request(p_request,'settings',p,ret);
end$$;
-- Module and batch access are edited together with an optimistic fingerprint.
create function private.admin_user_snapshot(uid uuid)returns jsonb language sql stable security definer set search_path='' as $$
 select jsonb_build_object('profile',jsonb_build_object('id',id,'display_name',display_name,'approved',approved,'is_admin',is_admin),'modules',coalesce((select jsonb_agg(to_jsonb(m)order by module)from public.module_access m where user_id=uid),'[]'),'batches',coalesce((select jsonb_agg(to_jsonb(a)order by batch_id,module)from public.batch_access a where user_id=uid),'[]'))from public.profiles where id=uid;
$$;
create function public.admin_workspace()returns jsonb language plpgsql security definer set search_path='' as $$begin
 if not private.is_admin()then raise exception 'NO_ACCESS';end if;
 return jsonb_build_object('users',coalesce((select jsonb_agg(private.admin_user_snapshot(p.id)||jsonb_build_object('fingerprint',md5(private.admin_user_snapshot(p.id)::text))order by p.created_at)from public.profiles p),'[]'));
end$$;
create function public.admin_manage(p_data jsonb,p_request uuid)returns jsonb language plpgsql security definer set search_path='' as $$
declare p jsonb:=p_data;u uuid:=(p->>'user_id')::uuid;ret jsonb;r jsonb;begin
 if not private.is_admin()then raise exception 'NO_ACCESS';end if;perform private.feed_lock();ret:=private.request_result(p_request,'admin',p);if ret is not null then return ret;end if;
 if md5(private.admin_user_snapshot(u)::text)is distinct from p->>'fingerprint'then raise exception 'VERSION_CONFLICT';end if;
 if jsonb_typeof(p->'modules')is distinct from 'array'or jsonb_typeof(p->'batches')is distinct from 'array'or jsonb_typeof(p->'approved')is distinct from 'boolean'or jsonb_typeof(p->'is_admin')is distinct from 'boolean'then raise exception 'INVALID_PERMISSIONS';end if;
 if (not(p->>'approved')::boolean or not(p->>'is_admin')::boolean)and not exists(select 1 from public.profiles where id<>u and approved and is_admin)then raise exception 'LAST_ADMIN';end if;
 update public.profiles set approved=(p->>'approved')::boolean,is_admin=(p->>'is_admin')::boolean where id=u;if not found then raise exception 'NOT_FOUND';end if;
 delete from public.module_access where user_id=u;delete from public.batch_access where user_id=u;
 for r in select value from jsonb_array_elements(p->'modules')loop insert into public.module_access(user_id,module,can_write)values(u,r->>'module',(r->>'can_write')::boolean);end loop;
 for r in select value from jsonb_array_elements(p->'batches')loop insert into public.batch_access(user_id,batch_id,module,can_write)values(u,(r->>'batch_id')::uuid,r->>'module',(r->>'can_write')::boolean);end loop;
 return private.finish_request(p_request,'admin',p,jsonb_build_object('saved',true));
end$$;
create function public.settings_status()returns jsonb language plpgsql security definer set search_path='' as $$begin
 if not exists(select 1 from public.profiles where id=auth.uid()and approved)then raise exception 'NO_ACCESS';end if;
 return jsonb_build_object('server_time',now(),'database_version','008','approved',true,'admin',private.is_admin());end$$;
revoke all on function public.workspace_image(text,uuid),public.settings_manage(jsonb,uuid),private.admin_user_snapshot(uuid),public.admin_workspace(),public.admin_manage(jsonb,uuid),public.settings_status()from public,anon,authenticated;
grant execute on function public.workspace_image(text,uuid),public.settings_manage(jsonb,uuid),public.admin_workspace(),public.admin_manage(jsonb,uuid),public.settings_status()to authenticated;
commit;
notify pgrst,'reload schema';
