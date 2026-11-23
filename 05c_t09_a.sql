\set ON_ERROR_STOP on
SET application_name='case16_T09_a';
SET lock_timeout='20s';
BEGIN;
CREATE TEMP TABLE target AS SELECT r.id AS rid,si.id AS sid,si.quantity-coalesce((SELECT sum(x.quantity) FROM return_items x WHERE x.sale_item_id=si.id),0) AS available
FROM returns r JOIN sale_items si ON si.sale_id=r.sale_id
WHERE si.quantity>coalesce((SELECT sum(x.quantity) FROM return_items x WHERE x.sale_item_id=si.id),0)
ORDER BY r.return_number,si.id LIMIT 1;
INSERT INTO return_items(return_id,sale_item_id,quantity,disposition) SELECT rid,sid,1,'write-off' FROM target;
DO $$ DECLARE deadline timestamptz:=clock_timestamp()+interval '45 seconds';
BEGIN LOOP
 PERFORM pg_stat_clear_snapshot();
 EXIT WHEN EXISTS (SELECT FROM pg_stat_activity WHERE application_name='case16_T09_b' AND pg_backend_pid()=ANY(pg_blocking_pids(pid)));
 IF clock_timestamp()>deadline THEN RAISE EXCEPTION 'Екінші сессияның құлыпты күтуі байқалмады'; END IF;
 PERFORM pg_sleep(0.1);
END LOOP;
RAISE NOTICE 'T09: B сессиясы A сессиясының құлпын күтті'; END $$;
SELECT 'T09-A' AS test, rid,sid FROM target;
ROLLBACK;
