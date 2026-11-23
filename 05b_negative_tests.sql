\set ON_ERROR_STOP on
\pset pager off
-- Әр сынақтың алдында және кейін негізгі қозғалыстардың күйі салыстырылады.
CREATE TEMP VIEW test_state AS SELECT (SELECT sum(quantity) FROM inventory) stock,
 (SELECT count(*) FROM sale_items) sale_lines,(SELECT count(*) FROM return_items) return_lines,
 (SELECT count(*) FROM returns) refunds,(SELECT count(*) FROM payments) payments,(SELECT count(*) FROM sales) receipts;
CREATE TEMP VIEW test_lots AS SELECT i.id AS inventory_id,i.quantity,w.branch_id,b.expiry_date,b.received_date,
 m.requires_prescription FROM inventory i JOIN warehouses w ON w.id=i.warehouse_id
 JOIN medicine_batches b ON b.id=i.batch_id JOIN purchase_items pi ON pi.id=b.purchase_item_id
 JOIN medicines m ON m.id=pi.medicine_id;
CREATE FUNCTION pg_temp.expect_failure(stmt text, expected text) RETURNS void LANGUAGE plpgsql AS $$
DECLARE message text; original jsonb;
BEGIN
 SELECT to_jsonb(s) INTO original FROM test_state s;
 BEGIN EXECUTE stmt;
 EXCEPTION WHEN OTHERS THEN GET STACKED DIAGNOSTICS message=MESSAGE_TEXT;
 END;
 IF message IS NULL OR position(expected IN message)=0 THEN
   RAISE EXCEPTION 'Күтілген қате: %, алынғаны: %',expected,message;
 END IF;
 IF original IS DISTINCT FROM (SELECT to_jsonb(s) FROM test_state s) THEN RAISE EXCEPTION 'Қате әрекет деректерді өзгертті'; END IF;
 RAISE NOTICE 'Күтілген қате: %',message;
END; $$;
CREATE FUNCTION pg_temp.try_line(lot integer, qty integer, rx integer DEFAULT NULL) RETURNS void LANGUAGE sql AS $$
 INSERT INTO sale_items(sale_id,inventory_id,quantity,unit_price,prescription_id)
 SELECT id,lot,qty,100,rx FROM sales WHERE receipt_number='TEST-OPEN';
$$;

-- T01
BEGIN;
SELECT * FROM test_state;
SELECT to_jsonb(s) AS initial_state FROM test_state s \gset
INSERT INTO sales(receipt_number,branch_id,sale_date)
SELECT 'TEST-OPEN',(SELECT min(id) FROM branches WHERE id<>test_lots.branch_id),expiry_date FROM test_lots WHERE NOT requires_prescription AND quantity>0 ORDER BY inventory_id LIMIT 1;
SELECT pg_temp.expect_failure($cmd$ SELECT pg_temp.try_line((SELECT inventory_id FROM test_lots WHERE NOT requires_prescription AND quantity>0 ORDER BY inventory_id LIMIT 1),1) $cmd$, 'басқа филиал');
ROLLBACK;
SELECT to_jsonb(s)=:'initial_state'::jsonb AS restored FROM test_state s \gset
\if :restored
\echo PASS
\else
DO $$ BEGIN RAISE EXCEPTION 'Сынақтан кейін күй өзгерді'; END $$;
\endif
-- T02
BEGIN;
SELECT * FROM test_state;
SELECT to_jsonb(s) AS initial_state FROM test_state s \gset
INSERT INTO sales(receipt_number,branch_id,sale_date)
SELECT 'TEST-OPEN',branch_id,expiry_date FROM test_lots WHERE NOT requires_prescription AND quantity>0 ORDER BY inventory_id LIMIT 1;
SELECT pg_temp.expect_failure($cmd$ SELECT pg_temp.try_line((SELECT inventory_id FROM test_lots WHERE NOT requires_prescription AND quantity>0 ORDER BY inventory_id LIMIT 1),100000) $cmd$, 'жеткіліксіз');
ROLLBACK;
SELECT to_jsonb(s)=:'initial_state'::jsonb AS restored FROM test_state s \gset
\if :restored
\echo PASS
\else
DO $$ BEGIN RAISE EXCEPTION 'Сынақтан кейін күй өзгерді'; END $$;
\endif
-- T03
BEGIN;
SELECT * FROM test_state;
SELECT to_jsonb(s) AS initial_state FROM test_state s \gset
SAVEPOINT dates;
INSERT INTO sales(receipt_number,branch_id,sale_date)
SELECT 'TEST-OPEN',branch_id,expiry_date+1 FROM test_lots WHERE NOT requires_prescription AND quantity>0 ORDER BY inventory_id LIMIT 1;
SELECT pg_temp.expect_failure($cmd$ SELECT pg_temp.try_line((SELECT inventory_id FROM test_lots WHERE NOT requires_prescription AND quantity>0 ORDER BY inventory_id LIMIT 1),1) $cmd$, 'мерзімі өткен');
ROLLBACK TO dates;
INSERT INTO sales(receipt_number,branch_id,sale_date)
SELECT 'TEST-OPEN',branch_id,received_date-1 FROM test_lots WHERE NOT requires_prescription AND quantity>0 ORDER BY inventory_id LIMIT 1;
SELECT pg_temp.expect_failure($cmd$ SELECT pg_temp.try_line((SELECT inventory_id FROM test_lots WHERE NOT requires_prescription AND quantity>0 ORDER BY inventory_id LIMIT 1),1) $cmd$, 'қабылданбаған');
ROLLBACK;
SELECT to_jsonb(s)=:'initial_state'::jsonb AS restored FROM test_state s \gset
\if :restored
\echo PASS
\else
DO $$ BEGIN RAISE EXCEPTION 'Сынақтан кейін күй өзгерді'; END $$;
\endif
-- T04
BEGIN;
SELECT * FROM test_state;
SELECT to_jsonb(s) AS initial_state FROM test_state s \gset
INSERT INTO sales(receipt_number,branch_id,sale_date)
SELECT 'TEST-OPEN',branch_id,expiry_date FROM test_lots WHERE requires_prescription AND quantity>0 ORDER BY inventory_id LIMIT 1;
SELECT pg_temp.expect_failure($cmd$ SELECT pg_temp.try_line((SELECT inventory_id FROM test_lots WHERE requires_prescription AND quantity>0 ORDER BY inventory_id LIMIT 1),1) $cmd$, 'рецепт міндетті');
CREATE TEMP VIEW used_rx AS SELECT s.*,si.inventory_id,si.prescription_id FROM sales s JOIN sale_items si ON si.sale_id=s.id WHERE si.prescription_id IS NOT NULL ORDER BY receipt_number LIMIT 1;
INSERT INTO sales(receipt_number,branch_id,customer_id,sale_date) SELECT 'ANON',branch_id,NULL,sale_date FROM used_rx;
SELECT pg_temp.expect_failure($cmd$ INSERT INTO sale_items(sale_id,inventory_id,quantity,unit_price,prescription_id) SELECT s.id,u.inventory_id,1,100,u.prescription_id FROM used_rx u JOIN sales s ON s.receipt_number='ANON' $cmd$, 'сәйкес емес');
INSERT INTO sales(receipt_number,branch_id,customer_id,sale_date) SELECT 'DATE',branch_id,customer_id,sale_date-20 FROM used_rx;
SELECT pg_temp.expect_failure($cmd$ INSERT INTO sale_items(sale_id,inventory_id,quantity,unit_price,prescription_id) SELECT s.id,u.inventory_id,1,100,u.prescription_id FROM used_rx u JOIN sales s ON s.receipt_number='DATE' $cmd$, 'сәйкес емес');
INSERT INTO sales(receipt_number,branch_id,customer_id,sale_date) SELECT 'CLIENT',branch_id,(SELECT min(c.id) FROM customers c WHERE c.id<>used_rx.customer_id),sale_date FROM used_rx;
SELECT pg_temp.expect_failure($cmd$ INSERT INTO sale_items(sale_id,inventory_id,quantity,unit_price,prescription_id) SELECT s.id,u.inventory_id,1,100,u.prescription_id FROM used_rx u JOIN sales s ON s.receipt_number='CLIENT' $cmd$, 'сәйкес емес');
INSERT INTO sales(receipt_number,branch_id,customer_id,sale_date) SELECT 'REUSE',branch_id,customer_id,sale_date FROM used_rx;
SELECT pg_temp.expect_failure($cmd$ INSERT INTO sale_items(sale_id,inventory_id,quantity,unit_price,prescription_id) SELECT s.id,u.inventory_id,1,100,u.prescription_id FROM used_rx u JOIN sales s ON s.receipt_number='REUSE' $cmd$, 'sale_items_single_use_rx');
ROLLBACK;
SELECT to_jsonb(s)=:'initial_state'::jsonb AS restored FROM test_state s \gset
\if :restored
\echo PASS
\else
DO $$ BEGIN RAISE EXCEPTION 'Сынақтан кейін күй өзгерді'; END $$;
\endif
-- T05
BEGIN;
SELECT * FROM test_state;
SELECT to_jsonb(s) AS initial_state FROM test_state s \gset
INSERT INTO sales(receipt_number,branch_id,sale_date)
SELECT 'TEST-OPEN',branch_id,expiry_date FROM test_lots WHERE NOT requires_prescription AND quantity>0 ORDER BY inventory_id LIMIT 1;
SELECT pg_temp.try_line((SELECT inventory_id FROM test_lots WHERE NOT requires_prescription AND quantity>0 ORDER BY inventory_id LIMIT 1),1);
SELECT pg_temp.expect_failure($cmd$ UPDATE sales SET status='paid' WHERE receipt_number='TEST-OPEN' $cmd$, 'жабылмады');
SELECT pg_temp.expect_failure($cmd$ UPDATE payments SET amount=amount+1 WHERE id=(SELECT min(id) FROM payments) $cmd$, 'төлемдері бекітілген');
SELECT pg_temp.expect_failure($cmd$ INSERT INTO sale_items(sale_id,inventory_id,quantity,unit_price) SELECT sale_id,inventory_id,1,100 FROM sale_items LIMIT 1 $cmd$, 'Төленген чекке');
ROLLBACK;
SELECT to_jsonb(s)=:'initial_state'::jsonb AS restored FROM test_state s \gset
\if :restored
\echo PASS
\else
DO $$ BEGIN RAISE EXCEPTION 'Сынақтан кейін күй өзгерді'; END $$;
\endif
-- T06
BEGIN;
SELECT * FROM test_state;
SELECT to_jsonb(s) AS initial_state FROM test_state s \gset
INSERT INTO sales(receipt_number,branch_id,sale_date)
SELECT 'TEST-OPEN',branch_id,expiry_date FROM test_lots WHERE NOT requires_prescription AND quantity>0 ORDER BY inventory_id LIMIT 1;
SELECT pg_temp.expect_failure($cmd$ INSERT INTO returns(return_number,sale_id,return_date,reason) SELECT 'TEST-R',id,sale_date,'сынақ' FROM sales WHERE receipt_number='TEST-OPEN' $cmd$, 'төленген чек');
SELECT pg_temp.expect_failure($cmd$ INSERT INTO returns(return_number,sale_id,return_date,reason) SELECT 'TEST-R',id,sale_date-1,'сынақ' FROM sales WHERE receipt_number='S-001' $cmd$, 'төленген чек');
SELECT pg_temp.expect_failure($cmd$ INSERT INTO return_items(return_id,sale_item_id,quantity,disposition) SELECT r.id,si.id,1,'write-off' FROM returns r JOIN sale_items si ON si.sale_id<>r.sale_id LIMIT 1 $cmd$, 'тиесілі емес');
ROLLBACK;
SELECT to_jsonb(s)=:'initial_state'::jsonb AS restored FROM test_state s \gset
\if :restored
\echo PASS
\else
DO $$ BEGIN RAISE EXCEPTION 'Сынақтан кейін күй өзгерді'; END $$;
\endif
-- T07
BEGIN;
SELECT * FROM test_state;
SELECT to_jsonb(s) AS initial_state FROM test_state s \gset
SELECT pg_temp.expect_failure($cmd$ UPDATE return_items SET quantity=quantity $cmd$, 'әрекетіне рұқсат жоқ');
SELECT pg_temp.expect_failure($cmd$ DELETE FROM return_items $cmd$, 'әрекетіне рұқсат жоқ');
SELECT pg_temp.expect_failure($cmd$ INSERT INTO return_items(return_id,sale_item_id,quantity,disposition) SELECT return_id,sale_item_id,9999,'write-off' FROM return_items LIMIT 1 $cmd$, 'сатылған саннан асады');
ROLLBACK;
SELECT to_jsonb(s)=:'initial_state'::jsonb AS restored FROM test_state s \gset
\if :restored
\echo PASS
\else
DO $$ BEGIN RAISE EXCEPTION 'Сынақтан кейін күй өзгерді'; END $$;
\endif
-- T08
BEGIN;
SELECT * FROM test_state;
SELECT to_jsonb(s) AS initial_state FROM test_state s \gset
CREATE TEMP TABLE chosen_0 AS SELECT si.id,si.sale_id,c.as_of_date FROM sale_items si
 JOIN test_lots l ON l.inventory_id=si.inventory_id CROSS JOIN report_settings c WHERE l.requires_prescription
 AND si.quantity>coalesce((SELECT sum(quantity) FROM return_items WHERE sale_item_id=si.id),0)
 ORDER BY si.id LIMIT 1;
INSERT INTO returns(return_number,sale_id,return_date,reason) SELECT 'TEST-R0',sale_id,as_of_date,'сынақ' FROM chosen_0;
SELECT pg_temp.expect_failure($cmd$ INSERT INTO return_items(return_id,sale_item_id,quantity,disposition) SELECT r.id,c.id,1,'restock' FROM returns r CROSS JOIN chosen_0 c WHERE r.return_number='TEST-R0' $cmd$, 'қорға қосуға болмайды');
CREATE TEMP TABLE chosen_1 AS SELECT si.id,si.sale_id,c.as_of_date FROM sale_items si
 JOIN test_lots l ON l.inventory_id=si.inventory_id CROSS JOIN report_settings c WHERE NOT l.requires_prescription AND l.expiry_date<c.as_of_date
 AND si.quantity>coalesce((SELECT sum(quantity) FROM return_items WHERE sale_item_id=si.id),0)
 ORDER BY si.id LIMIT 1;
INSERT INTO returns(return_number,sale_id,return_date,reason) SELECT 'TEST-R1',sale_id,as_of_date,'сынақ' FROM chosen_1;
SELECT pg_temp.expect_failure($cmd$ INSERT INTO return_items(return_id,sale_item_id,quantity,disposition) SELECT r.id,c.id,1,'restock' FROM returns r CROSS JOIN chosen_1 c WHERE r.return_number='TEST-R1' $cmd$, 'қорға қосуға болмайды');
ROLLBACK;
SELECT to_jsonb(s)=:'initial_state'::jsonb AS restored FROM test_state s \gset
\if :restored
\echo PASS
\else
DO $$ BEGIN RAISE EXCEPTION 'Сынақтан кейін күй өзгерді'; END $$;
\endif
-- T10
BEGIN;
SELECT * FROM test_state;
SELECT to_jsonb(s) AS initial_state FROM test_state s \gset
CREATE TEMP TABLE target AS SELECT r.id AS rid,si.id AS sid,si.quantity-coalesce((SELECT sum(x.quantity) FROM return_items x WHERE x.sale_item_id=si.id),0) AS available
FROM returns r JOIN sale_items si ON si.sale_id=r.sale_id
WHERE si.quantity>coalesce((SELECT sum(x.quantity) FROM return_items x WHERE x.sale_item_id=si.id),0)
ORDER BY r.return_number,si.id LIMIT 1;
INSERT INTO return_items(return_id,sale_item_id,quantity,disposition) SELECT rid,sid,available,'write-off' FROM target;
SELECT pg_temp.expect_failure($cmd$ INSERT INTO return_items(return_id,sale_item_id,quantity,disposition) SELECT rid,sid,1,'write-off' FROM target $cmd$, 'сатылған саннан асады');
ROLLBACK;
SELECT to_jsonb(s)=:'initial_state'::jsonb AS restored FROM test_state s \gset
\if :restored
\echo PASS
\else
DO $$ BEGIN RAISE EXCEPTION 'Сынақтан кейін күй өзгерді'; END $$;
\endif
