-- psql -X -d pharmacy_case -f 05_queries.sql
-- Тек аудит: -v audits_only=1 ; тек басқару блогы: -v demo_only=1.
\set ON_ERROR_STOP on
\pset pager off
\if :{?demo_only}
\else
-- V01 Көлем және байланыспаған жазбалар. Әр орындалмаған шарт бір бұзушылық.
SELECT 'V01' AS audit, count(*) FILTER (WHERE NOT ok) AS violations
FROM (VALUES
  ((SELECT count(*) FROM categories) = 12),
  ((SELECT count(*) FROM manufacturers) = 15),
  ((SELECT count(*) FROM suppliers) = 12),
  ((SELECT count(*) FROM branches) = 10),
  ((SELECT count(*) FROM warehouses) = 12),
  ((SELECT count(*) FROM medicines) = 100),
  ((SELECT count(*) FROM branch_assortment) = 200),
  ((SELECT count(*) FROM customers) = 150),
  ((SELECT count(*) FROM purchases) = 320),
  ((SELECT count(*) FROM purchase_items) = 640),
  ((SELECT count(*) FROM medicine_batches) = 750),
  ((SELECT count(*) FROM inventory) = 750),
  ((SELECT count(*) FROM prescriptions) = 100),
  ((SELECT count(*) FROM sales) = 450),
  ((SELECT count(*) FROM sale_items) = 1000),
  ((SELECT count(*) FROM payments) = 510),
  ((SELECT count(*) FROM returns) = 60),
  ((SELECT count(*) FROM return_items) = 80),
  ((SELECT count(*) FROM report_settings) = 1),
  (EXISTS (SELECT FROM customers a WHERE NOT EXISTS (SELECT FROM sales b WHERE b.customer_id=a.id))),
  (EXISTS (SELECT FROM suppliers a WHERE NOT EXISTS (SELECT FROM purchases b WHERE b.supplier_id=a.id))),
  (EXISTS (SELECT FROM sales WHERE customer_id IS NULL)),
  ((SELECT count(*) FROM prescriptions p WHERE NOT EXISTS (SELECT FROM sale_items s WHERE s.prescription_id=p.id)) BETWEEN 10 AND 15),
  (EXISTS (SELECT FROM medicines m WHERE NOT EXISTS
      (SELECT FROM sale_items s JOIN inventory i ON i.id=s.inventory_id JOIN medicine_batches b ON b.id=i.batch_id
       JOIN purchase_items p ON p.id=b.purchase_item_id WHERE p.medicine_id=m.id)))
) rules(ok);

-- V02 Сатып алу саны, қабылдау күндері және қоймасы.
SELECT 'V02' AS audit, count(*) AS violations FROM (
    SELECT pi.id FROM purchase_items pi JOIN purchases p ON p.id=pi.purchase_id
    LEFT JOIN medicine_batches b ON b.purchase_item_id=pi.id LEFT JOIN inventory i ON i.batch_id=b.id
    GROUP BY pi.id,p.warehouse_id,p.purchase_date
    HAVING COALESCE(sum(b.received_quantity),0)<>pi.quantity
        OR bool_or(b.received_date<p.purchase_date OR i.warehouse_id IS DISTINCT FROM p.warehouse_id)
) problems;

-- V03 Бастапқы қор, сату, жарамды қайтарым. Әр ағын бөлек жинақталады.
WITH sold AS (SELECT inventory_id,sum(quantity) qty FROM sale_items GROUP BY inventory_id),
back AS (SELECT s.inventory_id,sum(r.quantity) qty FROM return_items r JOIN sale_items s ON s.id=r.sale_item_id
         WHERE r.disposition='restock' GROUP BY s.inventory_id)
SELECT 'V03' AS audit,count(*) AS violations FROM inventory i JOIN medicine_batches b ON b.id=i.batch_id
LEFT JOIN sold s ON s.inventory_id=i.id LEFT JOIN back r ON r.inventory_id=i.id
WHERE i.quantity<>b.received_quantity-coalesce(s.qty,0)+coalesce(r.qty,0);

-- V04 Әр чек және төлем күндері, сәтті төлемдердің бөлінуі.
WITH paid AS (
    SELECT sale_id,sum(amount) FILTER (WHERE status='succeeded') money,
           count(*) FILTER (WHERE status='succeeded') n FROM payments GROUP BY sale_id
), lines AS (SELECT sale_id,sum(quantity*unit_price) money FROM sale_items GROUP BY sale_id),
issues AS (
    SELECT s.id FROM sales s LEFT JOIN paid p ON p.sale_id=s.id LEFT JOIN lines l ON l.sale_id=s.id
    WHERE s.status<>'paid' OR s.total_amount IS DISTINCT FROM p.money OR s.total_amount IS DISTINCT FROM l.money
    UNION ALL SELECT p.id FROM payments p JOIN sales s ON s.id=p.sale_id WHERE p.paid_at::date<>s.sale_date
    UNION ALL SELECT 0 FROM paid HAVING count(*) FILTER (WHERE n=1)<>400 OR count(*) FILTER (WHERE n=2)<>50
)
SELECT 'V04' AS audit,count(*) AS violations FROM issues;

-- V05 Қайтарымда жолдың болуы, чек, сан шегі, ақша және қорға қосу ережесі.
WITH issues AS (
    SELECT r.id FROM returns r JOIN sales s ON s.id=r.sale_id
    LEFT JOIN return_items ri ON ri.return_id=r.id LEFT JOIN sale_items si ON si.id=ri.sale_item_id
    LEFT JOIN inventory i ON i.id=si.inventory_id LEFT JOIN medicine_batches b ON b.id=i.batch_id
    LEFT JOIN purchase_items pi ON pi.id=b.purchase_item_id LEFT JOIN medicines m ON m.id=pi.medicine_id
    GROUP BY r.id,s.id HAVING count(ri.id)=0 OR r.refund_amount IS DISTINCT FROM sum(ri.quantity*si.unit_price)
        OR r.return_date<s.sale_date OR s.status<>'paid' OR bool_or(si.sale_id<>s.id)
        OR bool_or(ri.disposition='restock' AND (m.requires_prescription OR b.expiry_date<r.return_date))
    UNION ALL SELECT si.id FROM sale_items si JOIN return_items ri ON ri.sale_item_id=si.id
    GROUP BY si.id HAVING sum(ri.quantity)>si.quantity
)
SELECT 'V05' AS audit,count(*) AS violations FROM issues;

-- V06 Дата шектері, бірнеше қойманың қоры және нөлдік ассортимент.
WITH cfg AS (SELECT * FROM report_settings WHERE id=1),
usable AS (
    SELECT w.branch_id,p.medicine_id,count(DISTINCT i.warehouse_id) stores
    FROM inventory i JOIN medicine_batches b ON i.batch_id=b.id JOIN warehouses w ON w.id=i.warehouse_id
    JOIN purchase_items p ON p.id=b.purchase_item_id CROSS JOIN cfg
    WHERE i.quantity>0 AND b.expiry_date>=cfg.as_of_date GROUP BY 1,2
), checks(ok) AS (VALUES
    ((SELECT as_of_date=DATE '2026-11-24' AND expiry_window_days=90 FROM cfg)),
    ((SELECT min(sale_date)=DATE '2025-11-25' AND max(sale_date)=(SELECT as_of_date FROM cfg) FROM sales)),
    ((SELECT min(purchase_date)=DATE '2025-09-01' FROM purchases)),
    ((SELECT min(received_date)=DATE '2025-09-01' FROM medicine_batches)),
    (NOT EXISTS (SELECT FROM (VALUES ('P-001-1-1',0),('P-001-1-2',90),('P-001-2-1',91),('P-001-2-2',-1)) d(batch,n)
        CROSS JOIN cfg WHERE NOT EXISTS (SELECT FROM medicine_batches b JOIN inventory i ON i.batch_id=b.id
        WHERE b.batch_number=d.batch AND b.expiry_date=cfg.as_of_date+d.n AND b.received_date<=cfg.as_of_date AND i.quantity>0))),
    ((SELECT count(*) FILTER (WHERE days<0) BETWEEN 30 AND 40
         AND count(*) FILTER (WHERE days BETWEEN 0 AND 30) BETWEEN 45 AND 60
         AND count(*) FILTER (WHERE days BETWEEN 31 AND 90) BETWEEN 60 AND 75
         AND count(*) FILTER (WHERE ordinary_life)>count(*)/2
      FROM (SELECT b.expiry_date-c.as_of_date days,
                   b.expiry_date BETWEEN b.received_date+interval '12 months' AND b.received_date+interval '36 months' ordinary_life
            FROM medicine_batches b JOIN inventory i ON i.batch_id=b.id CROSS JOIN cfg c WHERE i.quantity>0) lots)),
    (EXISTS (SELECT FROM usable u JOIN branch_assortment a USING (branch_id,medicine_id) WHERE u.stores>=2)),
    (EXISTS (SELECT FROM branch_assortment a LEFT JOIN usable u USING (branch_id,medicine_id)
             WHERE a.is_active AND a.min_stock_level>0 AND u.stores IS NULL)),
    (EXISTS (SELECT FROM branches b WHERE NOT EXISTS (SELECT FROM branch_assortment a WHERE a.branch_id=b.id))),
    ((SELECT greatest((SELECT max(received_date) FROM medicine_batches),(SELECT max(purchase_date) FROM purchases),
        (SELECT max(sale_date) FROM sales),(SELECT max(return_date) FROM returns),(SELECT max(paid_at::date) FROM payments)) <= as_of_date FROM cfg))
)
SELECT 'V06' AS audit,count(*) FILTER (WHERE ok IS DISTINCT FROM true) AS violations FROM checks;
\if :{?audits_only}
\quit
\endif

-- Q01 Мерзімі аяқталуға жақын, қалдығы оң партиялар
SELECT w.code AS warehouse,b.batch_number,m.name,b.expiry_date,
       b.expiry_date-c.as_of_date AS days_left,i.quantity
FROM inventory i INNER JOIN medicine_batches b ON b.id=i.batch_id INNER JOIN warehouses w ON w.id=i.warehouse_id
INNER JOIN purchase_items pi ON pi.id=b.purchase_item_id INNER JOIN medicines m ON m.id=pi.medicine_id
CROSS JOIN report_settings c
WHERE i.quantity>0 AND b.received_date<=c.as_of_date
  AND b.expiry_date BETWEEN c.as_of_date AND c.as_of_date+c.expiry_window_days
ORDER BY days_left,w.code,b.batch_number;

-- Q02 Сату күні бойынша соңғы 12 айда ең көп сатылған он препарат
WITH back AS (
    SELECT ri.sale_item_id,sum(ri.quantity) qty FROM return_items ri INNER JOIN returns r ON r.id=ri.return_id
    CROSS JOIN report_settings c WHERE r.return_date<=c.as_of_date GROUP BY ri.sale_item_id
)
SELECT m.sku,m.name,sum(l.quantity) sold,sum(coalesce(back.qty,0)) returned,
       sum(l.quantity-coalesce(back.qty,0)) net_units
FROM sales s INNER JOIN sale_items l ON l.sale_id=s.id INNER JOIN inventory i ON i.id=l.inventory_id
INNER JOIN medicine_batches b ON b.id=i.batch_id INNER JOIN purchase_items pi ON pi.id=b.purchase_item_id
INNER JOIN medicines m ON m.id=pi.medicine_id LEFT JOIN back ON back.sale_item_id=l.id CROSS JOIN report_settings c
WHERE s.status='paid' AND s.sale_date>c.as_of_date-interval '1 year' AND s.sale_date<=c.as_of_date
GROUP BY m.id ORDER BY net_units DESC,m.sku LIMIT 10;

-- Q03 Белсенді ассортимент бойынша филиалға жетіспейтін қаптама
WITH stock AS (
    SELECT w.branch_id,pi.medicine_id,sum(i.quantity) qty FROM inventory i
    INNER JOIN warehouses w ON w.id=i.warehouse_id INNER JOIN medicine_batches b ON b.id=i.batch_id
    INNER JOIN purchase_items pi ON pi.id=b.purchase_item_id CROSS JOIN report_settings c
    WHERE i.quantity>0 AND b.expiry_date>=c.as_of_date AND b.received_date<=c.as_of_date GROUP BY 1,2
)
SELECT b.code AS branch,m.sku,m.name,coalesce(s.qty,0) usable,a.min_stock_level,
       a.min_stock_level-coalesce(s.qty,0) shortage
FROM branch_assortment a INNER JOIN branches b ON b.id=a.branch_id INNER JOIN medicines m ON m.id=a.medicine_id
LEFT JOIN stock s USING (branch_id,medicine_id)
WHERE a.is_active AND coalesce(s.qty,0)<a.min_stock_level ORDER BY shortage DESC,b.code,m.sku;

-- Q04 Мерзімі өткен, қоймада қалған партиялар
SELECT w.code AS warehouse,b.batch_number,b.expiry_date,i.quantity,c.as_of_date-b.expiry_date days_overdue
FROM inventory i INNER JOIN medicine_batches b ON b.id=i.batch_id INNER JOIN warehouses w ON w.id=i.warehouse_id
CROSS JOIN report_settings c WHERE i.quantity>0 AND b.expiry_date<c.as_of_date ORDER BY days_overdue DESC,b.batch_number;

-- Q05 Дәріханалар орналасқан қалалар
SELECT DISTINCT city FROM branches ORDER BY city;

-- Q06 Қаптамасы шағын рецептсіз таблеткалар
SELECT sku,name FROM medicines WHERE dosage_form='таблетка' AND NOT requires_prescription
AND package_description IN ('5 дана','10 дана') ORDER BY name;

-- Q07 Қайта тапсырыс көлемі орташа позициялар
SELECT branch_id,medicine_id,reorder_quantity FROM branch_assortment
WHERE is_active AND reorder_quantity BETWEEN 25 AND 30 ORDER BY reorder_quantity,branch_id,medicine_id;

-- Q08 Астана мен Алматыдағы жеткізушілер
SELECT code,name,city FROM suppliers WHERE city='Астана' OR city='Алматы' ORDER BY city,name;

-- Q09 Атауы бойынша таңғыштарды іздеу
SELECT sku,name,package_description FROM medicines WHERE name LIKE '%таңғыш%' ORDER BY name;

-- Q10 Ең ірі бес чек
SELECT receipt_number,sale_date,total_amount FROM sales WHERE status='paid' ORDER BY total_amount DESC,receipt_number LIMIT 5;

-- Q11 Қолма-қол ақшасыз сәтсіз төлемдер
SELECT p.method,p.amount,p.paid_at FROM payments p
WHERE p.status='failed' AND p.method IN ('card','transfer') ORDER BY p.paid_at;

-- Q12 Анонимді ірі чектер
SELECT receipt_number,sale_date,total_amount FROM sales WHERE customer_id IS NULL AND total_amount>=5000
ORDER BY total_amount DESC,receipt_number;

-- Q13 Желінің жалпы сатылымы мен чек саны
SELECT count(*) receipts,sum(total_amount) gross FROM sales WHERE status='paid';

-- Q14 Орташа чек
SELECT round(avg(total_amount),2) avg_receipt FROM sales WHERE status='paid';

-- Q15 Ең төмен және ең жоғары сатып алу бағасы
SELECT min(unit_cost) min_cost,max(unit_cost) max_cost FROM purchase_items;

-- Q16 Қайтарылған ақша және құжат саны
SELECT sum(refund_amount) refunded,count(*) documents FROM returns;

-- Q17 Қоймадағы қаптамалар
SELECT sum(quantity) stock,count(*) FILTER (WHERE quantity>0) positive_lots FROM inventory;

-- Q18 Оннан көп төленген чегі бар филиалдар
SELECT b.code,count(*) receipts,sum(s.total_amount) gross FROM sales s JOIN branches b ON b.id=s.branch_id
WHERE s.status='paid' GROUP BY b.code HAVING count(*)>10 ORDER BY gross DESC,b.code;

-- Q19 Бірнеше рет сатып алған клиенттер
SELECT c.loyalty_number,count(*) visits FROM customers c JOIN sales s ON s.customer_id=c.id
WHERE s.status='paid' GROUP BY c.loyalty_number HAVING count(*)>=3 ORDER BY visits DESC,c.loyalty_number;

-- Q20 Ірі қабылдау көлемі бар жеткізушілер
SELECT s.code,sum(pi.quantity) packs FROM purchases p JOIN suppliers s ON s.id=p.supplier_id
JOIN purchase_items pi ON pi.purchase_id=p.id WHERE pi.unit_cost>=500
GROUP BY s.code HAVING sum(pi.quantity)>=500 ORDER BY packs DESC,s.code;

-- Q21 Бірнеше қайтарымы бар филиалдар
SELECT b.code,count(*) documents,sum(r.refund_amount) refunded FROM returns r JOIN sales s ON s.id=r.sale_id
JOIN branches b ON b.id=s.branch_id WHERE r.refund_amount>0 GROUP BY b.code HAVING count(*)>=3 ORDER BY refunded DESC,b.code;

-- Q22 Екі сәтті төлеммен жабылған чектер
SELECT s.receipt_number,count(*) parts,sum(p.amount) money FROM payments p JOIN sales s ON s.id=p.sale_id
WHERE p.status='succeeded' GROUP BY s.receipt_number HAVING count(*)=2 ORDER BY s.receipt_number;

-- Q23 Тауардың жеткізушіден қоймаға дейінгі жолы
SELECT p.purchase_number,s.name supplier,m.name,b.batch_number,w.code warehouse FROM suppliers s
INNER JOIN purchases p ON p.supplier_id=s.id JOIN purchase_items pi ON pi.purchase_id=p.id JOIN medicines m ON m.id=pi.medicine_id
JOIN medicine_batches b ON b.purchase_item_id=pi.id JOIN inventory i ON i.batch_id=b.id JOIN warehouses w ON w.id=i.warehouse_id
ORDER BY p.purchase_number,b.batch_number;

-- Q24 Сатып алмаған клиенттер
SELECT c.loyalty_number,c.full_name FROM customers c LEFT JOIN sales s ON s.customer_id=c.id WHERE s.id IS NULL ORDER BY 1;

-- Q25 Сатып алу құжаты жоқ жеткізушілерді қоса көрсету
SELECT s.code,s.name,count(p.id) orders FROM purchases p RIGHT JOIN suppliers s ON s.id=p.supplier_id
GROUP BY s.id ORDER BY orders,s.code;

-- Q26 Клиент және чек тізімдерінің толық бірігуі
SELECT c.loyalty_number,s.receipt_number FROM customers c FULL OUTER JOIN sales s ON s.customer_id=c.id
ORDER BY 1 NULLS LAST,2 NULLS LAST;

-- Q27 Толық біріктірудің UNION ALL нұсқасы
SELECT c.loyalty_number,s.receipt_number FROM customers c LEFT JOIN sales s ON s.customer_id=c.id
UNION ALL
SELECT c.loyalty_number,s.receipt_number FROM sales s LEFT JOIN customers c ON s.customer_id=c.id WHERE c.id IS NULL
ORDER BY 1 NULLS LAST,2 NULLS LAST;

-- Q28 Қолданылмаған рецепттер
SELECT p.prescription_number,m.name,c.loyalty_number FROM prescriptions p JOIN medicines m ON m.id=p.medicine_id
JOIN customers c ON c.id=p.customer_id LEFT JOIN sale_items l ON l.prescription_id=p.id WHERE l.id IS NULL ORDER BY 1;

-- Q29 Рецептпен берілген қаптама саны
SELECT m.sku,m.name,count(*) rx_lines,sum(s.quantity) packs FROM sale_items s JOIN prescriptions p ON p.id=s.prescription_id
JOIN medicines m ON m.id=p.medicine_id GROUP BY m.id ORDER BY packs DESC,m.sku;

-- Q30 Қоймалар бойынша мерзім күйі
SELECT w.code,b.batch_number,i.quantity,CASE WHEN b.expiry_date<c.as_of_date THEN 'Мерзімі өткен'
WHEN b.expiry_date<=c.as_of_date+least(30,c.expiry_window_days) THEN '30 күнге дейін'
WHEN b.expiry_date<=c.as_of_date+c.expiry_window_days THEN 'Терезе ішінде, 30 күннен кейін'
ELSE 'Терезеден кейін' END AS state
FROM inventory i JOIN medicine_batches b ON b.id=i.batch_id JOIN warehouses w ON w.id=i.warehouse_id
CROSS JOIN report_settings c ORDER BY w.code,b.batch_number;

-- Q31 Клиент бонусы: таза сома 30000 ₸ болса 3%, 10000 ₸ болса 1%
WITH refunds AS (SELECT sale_id,sum(refund_amount) amt FROM returns GROUP BY sale_id),
spend AS (SELECT c.loyalty_number,coalesce(sum(s.total_amount-coalesce(r.amt,0)),0) net
FROM customers c LEFT JOIN sales s ON s.customer_id=c.id AND s.status='paid' LEFT JOIN refunds r ON r.sale_id=s.id GROUP BY c.id)
SELECT loyalty_number,net,round(net*CASE WHEN net>=30000 THEN 0.03 WHEN net>=10000 THEN 0.01 ELSE 0 END,2) bonus
FROM spend ORDER BY bonus DESC,loyalty_number;

-- Q32 Чек сомасының сегменттері
SELECT CASE WHEN total_amount<3000 THEN 'Шағын' WHEN total_amount<7000 THEN 'Орта' ELSE 'Ірі' END segment,
count(*) receipts FROM sales WHERE status='paid' GROUP BY 1 ORDER BY 2 DESC;

-- Q33 Қайтарылған тауардың бағыты
SELECT CASE WHEN disposition='restock' THEN 'Қоймаға қосылды' ELSE 'Есептен шықты' END destination,
sum(quantity) packs FROM return_items GROUP BY 1 ORDER BY 2 DESC;

-- Q34 Айлық сату
SELECT date_trunc('month',sale_date)::date AS month,sum(total_amount) gross,count(*) receipts
FROM sales WHERE status='paid' GROUP BY 1 ORDER BY 1;

-- Q35 Ең көп сатылған тауар санаттары
SELECT c.name,sum(l.quantity) sold FROM sale_items l JOIN inventory i ON i.id=l.inventory_id
JOIN medicine_batches b ON b.id=i.batch_id JOIN purchase_items p ON p.id=b.purchase_item_id
JOIN medicines m ON m.id=p.medicine_id JOIN categories c ON c.id=m.category_id GROUP BY c.id ORDER BY sold DESC,c.name;

-- Q36 Төлем тәсілдерінің үлесі
SELECT method,count(*) payments,sum(amount) money,round(100*sum(amount)/sum(sum(amount)) OVER (),2) pct
FROM payments WHERE status='succeeded' GROUP BY method ORDER BY money DESC,method;

-- Q37 Қоймалар бойынша мерзімі өткен тауардың сатып алу құны
SELECT w.code,sum(i.quantity) packs,sum(i.quantity*pi.unit_cost) cost FROM inventory i JOIN warehouses w ON w.id=i.warehouse_id
JOIN medicine_batches b ON b.id=i.batch_id JOIN purchase_items pi ON pi.id=b.purchase_item_id CROSS JOIN report_settings c
WHERE b.expiry_date<c.as_of_date AND i.quantity>0 GROUP BY w.code ORDER BY cost DESC,w.code;

-- Q38 Өндірушінің ассортимент көлемі
SELECT f.name,count(m.id) products FROM manufacturers f LEFT JOIN medicines m ON m.manufacturer_id=f.id GROUP BY f.id ORDER BY products DESC,f.name;

-- Q39 Сатылмаған препараттар
SELECT m.sku,m.name FROM medicines m WHERE NOT EXISTS
(SELECT FROM sale_items l JOIN inventory i ON i.id=l.inventory_id JOIN medicine_batches b ON b.id=i.batch_id
JOIN purchase_items p ON p.id=b.purchase_item_id WHERE p.medicine_id=m.id) ORDER BY m.sku;

-- Q40 Чекке шаққандағы қаптама саны
WITH per_sale AS (SELECT sale_id,sum(quantity) packs FROM sale_items GROUP BY sale_id)
SELECT round(avg(packs),2) avg_packs,min(packs) min_packs,max(packs) max_packs FROM per_sale;

-- Q41 Филиалдардағы анонимді сатылым үлесі
SELECT b.code,count(*) FILTER (WHERE s.customer_id IS NULL) anonymous,count(*) receipts
FROM sales s JOIN branches b ON b.id=s.branch_id GROUP BY b.code ORDER BY anonymous DESC,b.code;

-- Q42 Партияға бөлінген сатып алу жолдары
SELECT p.purchase_number,m.sku,count(*) batches FROM purchase_items pi JOIN purchases p ON p.id=pi.purchase_id
JOIN medicines m ON m.id=pi.medicine_id JOIN medicine_batches b ON b.purchase_item_id=pi.id
WHERE pi.quantity>0 GROUP BY pi.id,p.purchase_number,m.sku HAVING count(*)>1 ORDER BY 1,2;

-- Q43 Сатып алудан қабылдауға дейінгі күн саны
SELECT s.code,round(avg(b.received_date-p.purchase_date),2) avg_days,max(b.received_date-p.purchase_date) max_days
FROM suppliers s JOIN purchases p ON p.supplier_id=s.id JOIN purchase_items pi ON pi.purchase_id=p.id
JOIN medicine_batches b ON b.purchase_item_id=pi.id GROUP BY s.code ORDER BY avg_days DESC,s.code;

-- Q44 Таза түсім
SELECT (SELECT sum(total_amount) FROM sales WHERE status='paid')-(SELECT coalesce(sum(refund_amount),0) FROM returns) net_revenue;

-- Q45 Қайтару себептері
SELECT reason,count(*) documents,sum(refund_amount) money FROM returns GROUP BY reason ORDER BY money DESC,reason;

-- Q46 Бірнеше қоймасы бар филиалдар
SELECT b.code,count(*) stores FROM branches b JOIN warehouses w ON w.branch_id=b.id WHERE w.address<>''
GROUP BY b.code HAVING count(*)>=2 ORDER BY b.code;

-- Q47 Рецептуралық және еркін ассортимент
SELECT requires_prescription,count(*) products FROM medicines GROUP BY requires_prescription ORDER BY 1;

-- Q48 Белсенді ассортименті жоқ филиал
SELECT b.code,b.name FROM branches b WHERE NOT EXISTS
(SELECT FROM branch_assortment a WHERE a.branch_id=b.id AND a.is_active) ORDER BY b.code;

-- Q49 Сатып алу құны бойынша алғашқы үш жеткізуші
SELECT s.name,sum(pi.quantity*pi.unit_cost) cost FROM suppliers s JOIN purchases p ON p.supplier_id=s.id
JOIN purchase_items pi ON pi.purchase_id=p.id GROUP BY s.id ORDER BY cost DESC,s.name LIMIT 3;

-- Q50 Апта күндері бойынша чек саны
SELECT extract(isodow FROM sale_date)::int weekday,count(*) receipts,round(avg(total_amount),2) avg_receipt
FROM sales WHERE status='paid' GROUP BY 1 ORDER BY 1;

-- Q51 Қайтарылған рецепттік қаптамалар
SELECT count(*) lines,coalesce(sum(r.quantity),0) packs FROM return_items r JOIN sale_items l ON l.id=r.sale_item_id
WHERE l.prescription_id IS NOT NULL;

-- Q52 Соңғы 30 күндегі сатып алулар
SELECT p.purchase_number,s.name,p.purchase_date FROM purchases p JOIN suppliers s ON s.id=p.supplier_id
CROSS JOIN report_settings c WHERE p.purchase_date BETWEEN c.as_of_date-29 AND c.as_of_date ORDER BY p.purchase_date,p.purchase_number;

-- Q53 Қордың сатып алу құны бойынша алғашқы бес препарат
SELECT m.sku,m.name,sum(i.quantity*pi.unit_cost) stock_cost FROM inventory i JOIN medicine_batches b ON b.id=i.batch_id
JOIN purchase_items pi ON pi.id=b.purchase_item_id JOIN medicines m ON m.id=pi.medicine_id GROUP BY m.id
ORDER BY stock_cost DESC,m.sku LIMIT 5;

-- Q54 Күндік таза ақша қозғалысы
WITH entries AS (SELECT sale_date AS day,total_amount AS money FROM sales WHERE status='paid'
UNION ALL SELECT return_date,-refund_amount FROM returns)
SELECT day,sum(money) net FROM entries GROUP BY day ORDER BY day;

\endif

-- Басқару блогын бөлек іске қосу: psql -X -v demo_only=1 -d pharmacy_case -f 05_queries.sql
\if :{?demo_only}
\set ON_ERROR_STOP on
BEGIN;
CREATE SCHEMA demo;
CREATE FUNCTION pg_temp.fingerprint() RETURNS TABLE(tbl text,rows_count bigint,digest text)
LANGUAGE plpgsql AS $$
DECLARE t record;
BEGIN
    FOR t IN SELECT c.oid::regclass AS rel,c.relname,
       (SELECT string_agg(quote_ident(a.attname),',' ORDER BY k.pos)
        FROM unnest(pk.conkey) WITH ORDINALITY k(att,pos)
        JOIN pg_attribute a ON a.attrelid=c.oid AND a.attnum=k.att) ordering
       FROM pg_class c JOIN pg_constraint pk ON pk.conrelid=c.oid AND pk.contype='p'
       WHERE c.relnamespace='public'::regnamespace AND c.relkind='r'
    LOOP
       RETURN QUERY EXECUTE format(
         'SELECT %L::text,count(*),md5(coalesce(string_agg(to_jsonb(x)::text,chr(10) ORDER BY %s),'''')) FROM %s x',
         t.relname,t.ordering,t.rel);
    END LOOP;
END $$;
CREATE TEMP TABLE before_demo ON COMMIT DROP AS SELECT * FROM pg_temp.fingerprint();
CREATE TABLE demo.demo_customers AS SELECT c.* FROM customers c WHERE NOT EXISTS
(SELECT FROM sales s WHERE s.customer_id=c.id);
CREATE TABLE demo.demo_product AS SELECT m.* FROM medicines m JOIN categories c ON c.id=m.category_id WHERE c.code='CAT-001';
ALTER TABLE demo.demo_customers ADD COLUMN contact_status text DEFAULT 'Жаңа';
ALTER TABLE demo.demo_product ADD COLUMN review_required boolean DEFAULT false;
UPDATE demo.demo_customers SET contact_status='Шақыру' WHERE city='Алматы';
UPDATE demo.demo_product SET review_required=true WHERE NOT requires_prescription;
DELETE FROM demo.demo_customers WHERE loyalty_number=(SELECT max(loyalty_number) FROM demo.demo_customers);
SELECT contact_status,count(*) FROM demo.demo_customers GROUP BY contact_status;
SELECT review_required,count(*) FROM demo.demo_product GROUP BY review_required;
DROP TABLE demo.demo_product;
DO $$ BEGIN
 IF EXISTS (SELECT FROM before_demo b FULL JOIN pg_temp.fingerprint() a USING(tbl)
            WHERE b.rows_count IS DISTINCT FROM a.rows_count OR b.digest IS DISTINCT FROM a.digest)
 THEN RAISE EXCEPTION 'Негізгі кестелердің бақылау сомасы өзгерді'; END IF;
END $$;
SELECT count(*) AS verified_tables FROM before_demo;
ROLLBACK;
\endif
