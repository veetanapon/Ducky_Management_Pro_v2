-- After your FIRST verified login, run in SQL Editor on the NEW project.
-- Replace the UUID below with Authentication > Users > your user ID.
-- Never promote users based on editable profile metadata.
update public.profiles set approved=true,is_admin=true
where id='31ae568e-0526-4d52-9cba-31d1648e8e7b'
returning id, approved, is_admin;
