-- Safe to rerun; only corrects the notification function's table reference.
begin;
do $fix$
declare fn regprocedure; definition text;
begin
  fn := to_regprocedure('private.generate_notices(uuid)');
  if fn is null then raise exception 'Run SQL 027 first'; end if;
  if to_regclass('public.farm_feed_returns') is null then raise exception 'Missing farm_feed_returns; check SQL 006'; end if;
  definition := pg_get_functiondef(fn);
  if position('public.feed_returns' in definition)>0 then
    execute replace(definition,'public.feed_returns','public.farm_feed_returns');
  end if;
end;
$fix$;
notify pgrst,'reload schema';
commit;
