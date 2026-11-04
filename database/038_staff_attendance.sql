begin;
create table private.att_devices(id uuid primary key default gen_random_uuid(), employee text, farm uuid references public.farms, name text not null, kind text not null check(kind in('employee','kiosk')), mode text not null default 'qr' check(mode in('qr','shared')), secret_hash bytea unique not null, status text not null default 'pending' check(status in('pending','approved','revoked')), created_at timestamptz not null default now(), approved_by uuid references public.profiles, failures integer not null default 0, blocked_until timestamptz, attempts_at timestamptz, attempts integer not null default 0);
create table private.att_invites(id uuid primary key default gen_random_uuid(),employee text not null,secret_hash bytea unique not null,expires timestamptz not null,used boolean not null default false);
create table private.att_challenges(device uuid primary key references private.att_devices,token text not null,expires timestamptz not null);
create table private.att_pins(employee text primary key,salt text not null,pin_hash bytea not null,failures integer not null default 0,blocked_until timestamptz);
create table private.att_sessions(id uuid primary key default gen_random_uuid(),employee text not null,employee_code text not null,employee_name text not null,farm uuid not null references public.farms,in_at timestamptz not null,out_at timestamptz,source text not null,in_device uuid references private.att_devices,out_device uuid references private.att_devices,actor uuid references public.profiles,note text not null default '',check(out_at is null or out_at>=in_at));
create unique index att_one_open on private.att_sessions(employee) where out_at is null;
create index att_sessions_period on private.att_sessions(in_at,out_at);
create table private.att_requests(id uuid primary key,device uuid references private.att_devices,actor uuid,payload jsonb not null,result jsonb not null);
create table private.att_audit(id bigint generated always as identity primary key,at timestamptz not null default now(),actor uuid,action text not null,target text,note text);
revoke all on private.att_devices,private.att_invites,private.att_challenges,private.att_pins,private.att_sessions,private.att_requests,private.att_audit from public,anon,authenticated;
alter table private.att_devices enable row level security;
alter table private.att_invites enable row level security;
alter table private.att_challenges enable row level security;
alter table private.att_pins enable row level security;
alter table private.att_sessions enable row level security;
alter table private.att_requests enable row level security;
alter table private.att_audit enable row level security;
create function private.att_secret()returns text language sql volatile set search_path='' as $$select replace(gen_random_uuid()::text||gen_random_uuid()::text,'-','')$$;
create function private.att_employee(p_id text,p_farm uuid default null)returns jsonb language plpgsql security definer set search_path='' as $$declare e jsonb;d date:=(now()at time zone'Asia/Bangkok')::date;begin
 select value into e from private.staff_registry sr,jsonb_array_elements(sr.document->'employees') where value->>'id'=p_id;
 if e is null or e->>'status' is distinct from 'active' or (e->>'start')::date>d or nullif(e->>'end','')::date<d then raise exception 'INACTIVE_EMPLOYEE';end if;
 if p_farm is not null and not exists(select 1 from jsonb_array_elements(e->'assignments')a where a->>'farm'=p_farm::text and (a->>'start')::date<=d and (nullif(a->>'end','')is null or(a->>'end')::date>=d))then raise exception 'WRONG_FARM';end if;
 return e;end$$;
create function public.attendance_admin(p_action text,p_data jsonb default '{}')returns jsonb language plpgsql security definer set search_path='' as $$declare t text;did uuid;e jsonb;f uuid;begin
 if not private.is_admin()then raise exception 'NO_ACCESS';end if;
 if p_action='list'then return jsonb_build_object('devices',(select coalesce(jsonb_agg(to_jsonb(d)-'secret_hash'-'failures'-'blocked_until'-'attempts'-'attempts_at' order by created_at desc),'[]')from private.att_devices d),'audit',(select coalesce(jsonb_agg(x),'[]')from(select at,action,target,note from private.att_audit order by id desc limit 100)x));
 elsif p_action='invite'then
 e:=private.att_employee(p_data->>'employee');t:=private.att_secret();insert into private.att_invites(employee,secret_hash,expires)values(e->>'id',sha256(convert_to(t,'UTF8')),now()+interval'15 minutes');
 elsif p_action='kiosk'then
 f:=(p_data->>'farm')::uuid;if coalesce(trim(p_data->>'name'),'')=''then raise exception 'NAME_REQUIRED';end if;t:=private.att_secret();insert into private.att_devices(farm,name,kind,mode,secret_hash,status,approved_by)values(f,left(p_data->>'name',100),'kiosk',coalesce(p_data->>'mode','qr'),sha256(convert_to(t,'UTF8')),'approved',auth.uid())returning id into did;
 elsif p_action='approve'or p_action='revoke'then
 did:=(p_data->>'id')::uuid;update private.att_devices set status=case when p_action='approve'then'approved'else'revoked'end,approved_by=auth.uid()where id=did;if not found then raise exception 'DEVICE_NOT_FOUND';end if;delete from private.att_challenges where device=did;
 elsif p_action='pin'then
 e:=private.att_employee(p_data->>'employee');if coalesce(p_data->>'pin','')!~'^[0-9]{6,12}$'then raise exception 'PIN_6_12_DIGITS';end if;t:=private.att_secret();insert into private.att_pins(employee,salt,pin_hash)values(e->>'id',t,sha256(convert_to(t||':'||(p_data->>'pin'),'UTF8')))on conflict(employee)do update set salt=excluded.salt,pin_hash=excluded.pin_hash,failures=0,blocked_until=null;t:=null;
 else raise exception 'INVALID_ACTION';end if;
 insert into private.att_audit(actor,action,target)values(auth.uid(),p_action,coalesce(did::text,p_data->>'employee'));
 return jsonb_build_object('token',t,'id',did);end$$;
create function public.attendance_enroll(p_invite text,p_name text,p_secret text)returns jsonb language plpgsql security definer set search_path='' as $$declare i private.att_invites;d private.att_devices;begin
 if length(p_invite)<>64 or p_secret!~'^[a-f0-9]{64}$'or coalesce(trim(p_name),'')=''then raise exception 'INVALID_ENROLLMENT';end if;
 select * into i from private.att_invites where secret_hash=sha256(convert_to(p_invite,'UTF8'))for update;
 if i.id is null or i.expires<=now()then raise exception 'INVITE_EXPIRED';end if;
 if i.used then select * into d from private.att_devices where secret_hash=sha256(convert_to(p_secret,'UTF8'))and employee=i.employee;if d.id is not null then return jsonb_build_object('id',d.id,'status',d.status);end if;raise exception 'INVITE_USED';end if;
 perform private.att_employee(i.employee);
 insert into private.att_devices(employee,name,kind,secret_hash)values(i.employee,left(p_name,100),'employee',sha256(convert_to(p_secret,'UTF8')))returning * into d;update private.att_invites set used=true where id=i.id;
 return jsonb_build_object('id',d.id,'status',d.status);end$$;
create function private.att_device(p_secret text)returns private.att_devices language plpgsql security definer set search_path='' as $$declare d private.att_devices;begin
 select * into d from private.att_devices where secret_hash=sha256(convert_to(p_secret,'UTF8'))for update;
 if d.id is null or d.status<>'approved'then raise exception 'DEVICE_NOT_APPROVED';end if;
 if d.kind='employee'then perform private.att_employee(d.employee);end if;return d;end$$;
create function public.attendance_status(p_secret text)returns jsonb language plpgsql security definer set search_path='' as $$declare d private.att_devices;e jsonb;begin
 d:=private.att_device(p_secret);if d.kind='employee'then e:=private.att_employee(d.employee);end if;
 return jsonb_build_object('kind',d.kind,'mode',d.mode,'name',d.name,'farm',d.farm,'farm_name',(select name from public.farms where id=d.farm),'employee',case when e is null then null else jsonb_build_object('id',e->>'id','code',e->>'code','name',(e->>'first_name')||' '||(e->>'last_name'))end,'open',(select to_jsonb(s)from private.att_sessions s where employee=d.employee and out_at is null),'recent',(select coalesce(jsonb_agg(x),'[]')from(select in_at,out_at,source from private.att_sessions where employee=d.employee order by in_at desc limit 20)x),'server_time',clock_timestamp());end$$;
create function public.attendance_qr(p_secret text)returns jsonb language plpgsql security definer set search_path='' as $$declare d private.att_devices;q private.att_challenges;begin
 d:=private.att_device(p_secret);if d.kind<>'kiosk'then raise exception 'KIOSK_REQUIRED';end if;
 select * into q from private.att_challenges where device=d.id;
 if q.device is null or q.expires<=clock_timestamp()then insert into private.att_challenges(device,token,expires)values(d.id,private.att_secret(),clock_timestamp()+interval'180 seconds')on conflict(device)do update set token=excluded.token,expires=excluded.expires returning * into q;end if;
 return jsonb_build_object('token',q.token,'expires',q.expires,'server_time',clock_timestamp(),'farm_name',(select name from public.farms where id=d.farm));end$$;
create function public.attendance_clock(p_secret text,p_data jsonb,p_request uuid)returns jsonb language plpgsql security definer set search_path='' as $$declare d private.att_devices;k private.att_devices;pin private.att_pins;q private.att_challenges;e jsonb;s private.att_sessions;r private.att_requests;emp text;fid uuid;act text:=p_data->>'action';src text;ts timestamptz:=clock_timestamp();res jsonb;payload jsonb:=p_data-'pin';begin
 if p_request is null or act not in('in','out')or act is null then raise exception 'INVALID_ACTION';end if;
 d:=private.att_device(p_secret);
 select * into r from private.att_requests where id=p_request;if found then if r.device is distinct from d.id or r.payload<>payload then raise exception 'REQUEST_CONFLICT';end if;return r.result;end if;
 if d.kind='employee'then
 select c.* into q from private.att_challenges c join private.att_devices kd on kd.id=c.device where c.token=p_data->>'qr'and kd.status='approved' and c.expires>ts;
 if q.device is null then raise exception 'QR_EXPIRED';end if;select * into k from private.att_devices where id=q.device for share;if k.status<>'approved' or q.expires<=clock_timestamp()then raise exception 'QR_EXPIRED';end if;fid:=k.farm;emp:=d.employee;src:='mobile';
 else
 if d.mode<>'shared'then raise exception 'KIOSK_QR_ONLY';end if;
 if d.blocked_until>ts then return jsonb_build_object('error','TRY_LATER');end if;
 if d.attempts_at is null or d.attempts_at<ts-interval'1 minute'then d.attempts:=0;d.attempts_at:=ts;end if;
 update private.att_devices set attempts=d.attempts+1,attempts_at=d.attempts_at where id=d.id;
 if d.attempts>=30 then return jsonb_build_object('error','TRY_LATER');end if;
 select value->>'id' into emp from private.staff_registry sr,jsonb_array_elements(sr.document->'employees')where value->>'code'=p_data->>'code';select * into pin from private.att_pins where employee=emp for update;
 if pin.blocked_until>ts then return jsonb_build_object('error','TRY_LATER');end if;
 if pin.employee is null or pin.pin_hash<>sha256(convert_to(pin.salt||':'||coalesce(p_data->>'pin',''),'UTF8'))then
 update private.att_pins set failures=failures+1,blocked_until=case when failures+1>=5 then ts+interval'15 minutes'else null end where employee=emp;
 update private.att_devices set failures=failures+1,blocked_until=case when failures+1>=15 then ts+interval'15 minutes'else null end where id=d.id;
 return jsonb_build_object('error','INVALID_CODE_OR_PIN');end if;
 update private.att_pins set failures=0,blocked_until=null where employee=emp;update private.att_devices set failures=0,blocked_until=null where id=d.id;fid:=d.farm;src:='kiosk';end if;
 perform pg_advisory_xact_lock(hashtextextended(emp,42));e:=private.att_employee(emp,fid);
 select * into s from private.att_sessions where employee=emp and out_at is null for update;
 if act='in'then if s.id is not null then raise exception 'ALREADY_IN';end if;
 insert into private.att_sessions(employee,employee_code,employee_name,farm,in_at,source,in_device)values(emp,e->>'code',(e->>'first_name')||' '||(e->>'last_name'),fid,ts,src,d.id)returning * into s;
 else if s.id is null then raise exception 'NOT_IN';end if;if s.farm<>fid then raise exception 'WRONG_FARM';end if;update private.att_sessions set out_at=ts,out_device=d.id where id=s.id returning * into s;end if;
 res:=jsonb_build_object('session',to_jsonb(s),'action',act,'server_time',ts);insert into private.att_requests values(p_request,d.id,null,payload,res);return res;end$$;
create function public.attendance_manual(p_data jsonb,p_request uuid)returns jsonb language plpgsql security definer set search_path='' as $$declare e jsonb;s private.att_sessions;r private.att_requests;emp text:=p_data->>'employee';fid uuid:=(p_data->>'farm')::uuid;t timestamptz:=(p_data->>'time')::timestamptz;res jsonb;begin
 if not private.is_admin()then raise exception 'NO_ACCESS';end if;
 perform pg_advisory_xact_lock(hashtextextended(emp,42));select * into r from private.att_requests where id=p_request;if found then if r.actor is distinct from auth.uid()or r.payload<>p_data then raise exception 'REQUEST_CONFLICT';end if;return r.result;end if;
 if p_request is null or t is null or t>clock_timestamp()or coalesce(trim(p_data->>'reason'),'')=''then raise exception 'INVALID_MANUAL';end if;e:=private.att_employee(emp,fid);
 if p_data->>'action'='in'then
 if exists(select 1 from private.att_sessions where employee=emp and(out_at is null or out_at>t))then raise exception 'OVERLAPPING_SESSION';end if;
 insert into private.att_sessions(employee,employee_code,employee_name,farm,in_at,source,actor,note)values(emp,e->>'code',(e->>'first_name')||' '||(e->>'last_name'),fid,t,'supervisor',auth.uid(),left(p_data->>'reason',1000))returning * into s;
 elsif p_data->>'action'='out'then select * into s from private.att_sessions where employee=emp and out_at is null for update;if s.id is null or s.farm<>fid or t<s.in_at then raise exception 'INVALID_OPEN_SESSION';end if;update private.att_sessions set out_at=t,note=note||' / ออกโดยผู้ดูแล: '||left(p_data->>'reason',1000)where id=s.id returning * into s;
 else raise exception 'INVALID_ACTION';end if;
 insert into private.att_audit(actor,action,target,note)values(auth.uid(),'manual_'||(p_data->>'action'),s.id::text,p_data->>'reason');res:=jsonb_build_object('session',to_jsonb(s));insert into private.att_requests values(p_request,null,auth.uid(),p_data,res);return res;end$$;
create function public.attendance_report(p_month text,p_farm uuid default null,p_offset integer default 0)returns jsonb language plpgsql security definer set search_path='' as $$declare a timestamptz;b timestamptz;begin
 if not private.is_admin()then raise exception 'NO_ACCESS';end if;if p_month!~'^[0-9]{4}-(0[1-9]|1[0-2])$'or p_offset<0 then raise exception 'INVALID_MONTH';end if;
 a:=(p_month||'-01')::timestamp at time zone'Asia/Bangkok';b:=((p_month||'-01')::date+interval'1 month')at time zone'Asia/Bangkok';
 return jsonb_build_object('rows',(select coalesce(jsonb_agg(x order by x.in_at,x.id),'[]')from(select * from private.att_sessions where in_at<b and((out_at is null and a<clock_timestamp())or out_at>a)and(p_farm is null or farm=p_farm)order by in_at,id limit 500 offset p_offset)x),'start',a,'end',b);end$$;
revoke all on function private.att_secret(),private.att_employee(text,uuid),private.att_device(text)from public,anon,authenticated;
revoke all on function public.attendance_admin(text,jsonb),public.attendance_manual(jsonb,uuid),public.attendance_report(text,uuid,integer),public.attendance_enroll(text,text,text),public.attendance_status(text),public.attendance_qr(text),public.attendance_clock(text,jsonb,uuid)from public,anon,authenticated;
grant execute on function public.attendance_admin(text,jsonb),public.attendance_manual(jsonb,uuid),public.attendance_report(text,uuid,integer)to authenticated;
grant execute on function public.attendance_enroll(text,text,text),public.attendance_status(text),public.attendance_qr(text),public.attendance_clock(text,jsonb,uuid)to anon,authenticated;
commit;
notify pgrst,'reload schema';
