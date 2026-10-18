-- Additive stock correction, independent of purchases, cash and consumption history.
BEGIN;
ALTER TABLE public.feed_allocations ADD COLUMN IF NOT EXISTS stock_adjustment numeric(16,3) NOT NULL DEFAULT 0;
DO $$ DECLARE f text;d text;old text;new text;BEGIN
 FOR f,old,new IN SELECT * FROM (VALUES
 ('private.farm_apply_v040(jsonb)','select al.quantity-coalesce','select al.quantity+al.stock_adjustment-coalesce'),
 ('private.farm_apply(jsonb)','select a.quantity-coalesce','select a.quantity+a.stock_adjustment-coalesce')
 )patches(fn,old_fragment,new_fragment) LOOP
  SELECT pg_get_functiondef(f::regprocedure)INTO d;
  IF position(new IN d)>0 THEN CONTINUE;END IF;
  IF position(old IN d)=0 THEN RAISE EXCEPTION 'UNEXPECTED_STOCK_FUNCTION: %',f;END IF;
  EXECUTE replace(d,old,new);
 END LOOP;
END $$;
COMMIT;
NOTIFY pgrst,'reload schema';
