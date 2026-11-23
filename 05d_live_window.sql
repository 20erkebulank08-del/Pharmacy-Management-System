\set ON_ERROR_STOP on
-- Есептік күн өзгермейді. Бір Q01 көрінісін екі тереземен салыстыру.
BEGIN;
CREATE TEMP VIEW live_q01 AS
SELECT w.code AS warehouse,b.batch_number,m.name,b.expiry_date,
       b.expiry_date-c.as_of_date AS days_left,i.quantity
FROM inventory i INNER JOIN medicine_batches b ON b.id=i.batch_id INNER JOIN warehouses w ON w.id=i.warehouse_id
INNER JOIN purchase_items pi ON pi.id=b.purchase_item_id INNER JOIN medicines m ON m.id=pi.medicine_id
CROSS JOIN report_settings c
WHERE i.quantity>0 AND b.received_date<=c.as_of_date
  AND b.expiry_date BETWEEN c.as_of_date AND c.as_of_date+c.expiry_window_days
ORDER BY days_left,w.code,b.batch_number;
SELECT c.as_of_date,c.expiry_window_days,count(v.batch_number) AS lots
FROM report_settings c LEFT JOIN live_q01 v ON true GROUP BY c.id;
SELECT batch_number,days_left FROM live_q01 WHERE batch_number LIKE 'P-001-%' ORDER BY days_left;
UPDATE report_settings SET expiry_window_days=30 WHERE id=1;
SELECT c.as_of_date,c.expiry_window_days,count(v.batch_number) AS lots
FROM report_settings c LEFT JOIN live_q01 v ON true GROUP BY c.id;
SELECT * FROM live_q01 ORDER BY days_left,warehouse,batch_number;
ROLLBACK;
