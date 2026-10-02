-- After your FIRST verified login, run in SQL Editor on the NEW project.
-- Replace the UUID below with Authentication > Users > your user ID.
-- Never promote users based on editable profile metadata.
update public.profiles set approved=true,is_admin=true
where id='00000000-0000-0000-0000-000000000000';
