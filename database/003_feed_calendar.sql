-- Apply to the NEW v2 project after 001. Read-only aggregate for central feed calendar.
-- Does not grant access to batch funding/payment rows. Only approved feed readers.
begin;
create or replace function public.get_feed_calendar(p_offset integer default 0,p_limit integer default 500)
returns setof jsonb language plpgsql stable security definer set search_path='' as $$
begin
 if not private.has_module('feed') then return; end if;
 if p_offset<0 or p_limit<1 or p_limit>500 then raise exception 'INVALID_PAGING'; end if;
 return query
 select to_jsonb(o)||jsonb_build_object('paid_total',coalesce(p.amount,0),
  'outstanding',greatest(0,o.total-coalesce(c.credit,0)-coalesce(p.amount,0)))
 from public.feed_orders o
 left join lateral(select sum(amount) amount from public.feed_payments where order_id=o.id)p on true
 left join lateral(select sum(case kind when 'credit' then amount when 'extra_charge' then -amount else 0 end)credit
 from public.feed_claims where order_id=o.id)c on true
 order by o.order_date,o.id limit p_limit offset p_offset;
end $$;
revoke all on function public.get_feed_calendar(integer,integer) from public,anon;
grant execute on function public.get_feed_calendar(integer,integer) to authenticated;
commit;
