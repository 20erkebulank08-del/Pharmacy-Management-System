-- PostgreSQL 16, psql. Жаңа база: psql -X -d postgres -v new_db=pharmacy_case -f 03_database_structure.sql
-- new_db берілмесе, схема ағымдағы бос базаға орнатылады.
\set ON_ERROR_STOP on
\if :{?new_db}
CREATE DATABASE :"new_db" TEMPLATE template0 ENCODING 'UTF8';
\connect :new_db
\endif

BEGIN;
SET LOCAL search_path = public, pg_catalog;

CREATE TABLE categories (
    id integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    code text NOT NULL UNIQUE,
    name text NOT NULL UNIQUE,
    description text NOT NULL,
    is_active boolean NOT NULL DEFAULT true
);
CREATE TABLE manufacturers (
    id integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    code text NOT NULL UNIQUE,
    name text NOT NULL,
    country_code char(2) NOT NULL,
    city text NOT NULL
);
CREATE TABLE suppliers (
    id integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    code text NOT NULL UNIQUE,
    name text NOT NULL,
    city text NOT NULL,
    contact_phone text NOT NULL
);
CREATE TABLE branches (
    id integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    code text NOT NULL UNIQUE,
    name text NOT NULL,
    city text NOT NULL,
    address text NOT NULL
);
CREATE TABLE warehouses (
    id integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    branch_id integer NOT NULL REFERENCES branches,
    code text NOT NULL UNIQUE,
    name text NOT NULL,
    address text NOT NULL
);
CREATE TABLE medicines (
    id integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    sku text NOT NULL UNIQUE,
    name text NOT NULL,
    category_id integer NOT NULL REFERENCES categories,
    manufacturer_id integer NOT NULL REFERENCES manufacturers,
    dosage_form text NOT NULL,
    package_description text NOT NULL,
    requires_prescription boolean NOT NULL
);
CREATE TABLE branch_assortment (
    branch_id integer NOT NULL REFERENCES branches,
    medicine_id integer NOT NULL REFERENCES medicines,
    min_stock_level integer NOT NULL CHECK (min_stock_level >= 0),
    reorder_quantity integer NOT NULL CHECK (reorder_quantity > 0),
    is_active boolean NOT NULL DEFAULT true,
    PRIMARY KEY (branch_id, medicine_id)
);
CREATE TABLE customers (
    id integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    loyalty_number text NOT NULL UNIQUE,
    full_name text NOT NULL,
    city text NOT NULL,
    joined_on date NOT NULL
);
CREATE TABLE purchases (
    id integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    purchase_number text NOT NULL UNIQUE,
    supplier_id integer NOT NULL REFERENCES suppliers,
    warehouse_id integer NOT NULL REFERENCES warehouses,
    purchase_date date NOT NULL
);
CREATE TABLE purchase_items (
    id integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    purchase_id integer NOT NULL REFERENCES purchases,
    medicine_id integer NOT NULL REFERENCES medicines,
    quantity integer NOT NULL CHECK (quantity > 0),
    unit_cost numeric(12,2) NOT NULL CHECK (unit_cost > 0)
);
CREATE TABLE medicine_batches (
    id integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    purchase_item_id integer NOT NULL REFERENCES purchase_items,
    batch_number text NOT NULL,
    received_quantity integer NOT NULL CHECK (received_quantity > 0),
    received_date date NOT NULL,
    expiry_date date NOT NULL CHECK (expiry_date >= received_date),
    UNIQUE (purchase_item_id, batch_number)
);
CREATE TABLE inventory (
    id integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    batch_id integer NOT NULL UNIQUE REFERENCES medicine_batches,
    warehouse_id integer NOT NULL REFERENCES warehouses,
    quantity integer NOT NULL CHECK (quantity >= 0),
    updated_at date NOT NULL
);
CREATE TABLE prescriptions (
    id integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    prescription_number text NOT NULL UNIQUE,
    customer_id integer NOT NULL REFERENCES customers,
    medicine_id integer NOT NULL REFERENCES medicines,
    issued_date date NOT NULL,
    valid_until date NOT NULL CHECK (valid_until >= issued_date),
    doctor_name text NOT NULL,
    clinic_name text NOT NULL
);
CREATE TABLE sales (
    id integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    receipt_number text NOT NULL UNIQUE,
    branch_id integer NOT NULL REFERENCES branches,
    customer_id integer REFERENCES customers,
    sale_date date NOT NULL,
    status text NOT NULL DEFAULT 'open' CHECK (status IN ('open', 'paid')),
    total_amount numeric(16,2) NOT NULL DEFAULT 0 CHECK (total_amount >= 0)
);
CREATE TABLE sale_items (
    id integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    sale_id integer NOT NULL REFERENCES sales,
    inventory_id integer NOT NULL REFERENCES inventory,
    prescription_id integer REFERENCES prescriptions,
    quantity integer NOT NULL CHECK (quantity > 0),
    unit_price numeric(12,2) NOT NULL CHECK (unit_price > 0)
);
CREATE UNIQUE INDEX sale_items_single_use_rx ON sale_items (prescription_id)
    WHERE prescription_id IS NOT NULL;
CREATE INDEX sale_items_by_sale ON sale_items (sale_id);
CREATE INDEX sale_items_by_inventory ON sale_items (inventory_id);
CREATE TABLE payments (
    id integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    sale_id integer NOT NULL REFERENCES sales,
    amount numeric(16,2) NOT NULL CHECK (amount > 0),
    method text NOT NULL CHECK (method IN ('cash','card','transfer')),
    status text NOT NULL CHECK (status IN ('succeeded','failed')),
    paid_at timestamp NOT NULL
);
CREATE INDEX payments_by_sale ON payments (sale_id);
CREATE TABLE returns (
    id integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    return_number text NOT NULL UNIQUE,
    sale_id integer NOT NULL REFERENCES sales,
    return_date date NOT NULL,
    reason text NOT NULL,
    refund_amount numeric(16,2) NOT NULL DEFAULT 0 CHECK (refund_amount >= 0)
);
CREATE TABLE return_items (
    id integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    return_id integer NOT NULL REFERENCES returns,
    sale_item_id integer NOT NULL REFERENCES sale_items,
    quantity integer NOT NULL CHECK (quantity > 0),
    disposition text NOT NULL CHECK (disposition IN ('restock','write-off'))
);
CREATE INDEX return_items_by_line ON return_items (sale_item_id);
CREATE TABLE report_settings (
    id integer PRIMARY KEY CHECK (id = 1),
    as_of_date date NOT NULL,
    expiry_window_days integer NOT NULL DEFAULT 90 CHECK (expiry_window_days >= 0),
    currency_code char(3) NOT NULL DEFAULT 'KZT',
    updated_at date NOT NULL
);

-- Бастапқы құжат пен қозғалыс тарихын сақтау.
CREATE FUNCTION reject_change() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    RAISE EXCEPTION '%: % әрекетіне рұқсат жоқ', TG_TABLE_NAME, TG_OP;
END;
$$;
COMMENT ON FUNCTION reject_change() IS 'Тарихи жолды өзгерту мен жоюды тоқтатады.';
CREATE TRIGGER immutable_sale_line BEFORE UPDATE OR DELETE ON sale_items
    FOR EACH ROW EXECUTE FUNCTION reject_change();
CREATE TRIGGER immutable_return_line BEFORE UPDATE OR DELETE ON return_items
    FOR EACH ROW EXECUTE FUNCTION reject_change();
CREATE TRIGGER immutable_batch BEFORE UPDATE OR DELETE ON medicine_batches
    FOR EACH ROW EXECUTE FUNCTION reject_change();
CREATE TRIGGER immutable_purchase_line BEFORE UPDATE ON purchase_items
    FOR EACH ROW WHEN (OLD IS DISTINCT FROM NEW) EXECUTE FUNCTION reject_change();
CREATE TRIGGER keep_purchase_line BEFORE DELETE ON purchase_items
    FOR EACH ROW EXECUTE FUNCTION reject_change();
CREATE TRIGGER immutable_purchase_source BEFORE UPDATE OF warehouse_id, purchase_date, supplier_id ON purchases
    FOR EACH ROW EXECUTE FUNCTION reject_change();
CREATE TRIGGER immutable_warehouse_branch BEFORE UPDATE OF branch_id ON warehouses
    FOR EACH ROW EXECUTE FUNCTION reject_change();
CREATE TRIGGER immutable_rx_class BEFORE UPDATE OF requires_prescription ON medicines
    FOR EACH ROW EXECUTE FUNCTION reject_change();
CREATE TRIGGER immutable_prescription BEFORE UPDATE ON prescriptions
    FOR EACH ROW EXECUTE FUNCTION reject_change();

CREATE FUNCTION guard_inventory() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    -- Тікелей оператор үшін тереңдік 1, құжат триггерінен келгенде кемінде 2.
    IF pg_trigger_depth() < 2 OR TG_OP = 'DELETE' THEN
        RAISE EXCEPTION 'Қор тек қабылдау, сату немесе қайтару құжатымен өзгереді';
    END IF;
    RETURN NEW;
END;
$$;
COMMENT ON FUNCTION guard_inventory() IS 'Қорды қолмен өзгертуден қорғайды.';
CREATE TRIGGER guard_stock BEFORE INSERT OR UPDATE OR DELETE ON inventory
    FOR EACH ROW EXECUTE FUNCTION guard_inventory();

CREATE FUNCTION check_batch_entry() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF current_setting('pharmacy.receiving', true) IS DISTINCT FROM 'on' THEN
        RAISE EXCEPTION 'Партияны receive_batch арқылы қабылдаңыз';
    END IF;
    RETURN NEW;
END;
$$;
COMMENT ON FUNCTION check_batch_entry() IS 'Қабылдау функциясынан тыс партия енгізуді тоқтатады.';
CREATE TRIGGER check_batch_entry BEFORE INSERT ON medicine_batches
    FOR EACH ROW EXECUTE FUNCTION check_batch_entry();

CREATE FUNCTION open_batch_stock() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO inventory (batch_id, warehouse_id, quantity, updated_at)
    SELECT NEW.id, p.warehouse_id, NEW.received_quantity, NEW.received_date
    FROM purchase_items pi JOIN purchases p ON p.id = pi.purchase_id
    WHERE pi.id = NEW.purchase_item_id;
    RETURN NULL;
END;
$$;
COMMENT ON FUNCTION open_batch_stock() IS 'Қабылданған партияға сатып алу қоймасында қор жолын ашады.';
CREATE TRIGGER open_batch_stock AFTER INSERT ON medicine_batches
    FOR EACH ROW EXECUTE FUNCTION open_batch_stock();

CREATE FUNCTION receive_batch(p_purchase_item_id integer, p_batch_number text,
    p_quantity integer, p_received_date date, p_expiry_date date)
RETURNS integer LANGUAGE plpgsql AS $$
DECLARE
    ordered integer;
    bought_on date;
    previously_received bigint;
    batch_key integer;
    prior_flag text := current_setting('pharmacy.receiving', true);
BEGIN
    -- Бір мезгілде қабылдауларды бірізді етеді, ескі транзакциялық суретті анықтайды.
    UPDATE purchase_items SET quantity = quantity WHERE id = p_purchase_item_id;
    SELECT pi.quantity, p.purchase_date INTO STRICT ordered, bought_on
    FROM purchase_items pi JOIN purchases p ON p.id = pi.purchase_id
    WHERE pi.id = p_purchase_item_id FOR UPDATE OF pi;
    IF p_received_date < bought_on THEN
        RAISE EXCEPTION 'Қабылдау күні сатып алу күнінен ерте';
    END IF;
    SELECT COALESCE(sum(received_quantity), 0) INTO previously_received
    FROM medicine_batches WHERE purchase_item_id = p_purchase_item_id;
    IF previously_received + p_quantity > ordered THEN
        RAISE EXCEPTION 'Қабылдау саны сатып алу жолындағы саннан асады';
    END IF;

    PERFORM set_config('pharmacy.receiving', 'on', true);
    INSERT INTO medicine_batches (purchase_item_id, batch_number, received_quantity, received_date, expiry_date)
    VALUES (p_purchase_item_id, p_batch_number, p_quantity, p_received_date, p_expiry_date)
    RETURNING id INTO batch_key;
    PERFORM set_config('pharmacy.receiving', COALESCE(prior_flag, ''), true);
    RETURN batch_key;
END;
$$;
COMMENT ON FUNCTION receive_batch IS 'Партия мен қорды бір операцияда тіркеп, жаңа партияның кілтін береді.';

CREATE FUNCTION manage_sale() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
    line_total numeric;
    paid_total numeric;
BEGIN
    IF TG_OP = 'INSERT' THEN
        IF NEW.status <> 'open' OR NEW.total_amount <> 0 THEN
            RAISE EXCEPTION 'Жаңа чек нөлдік сомамен ашылады';
        END IF;
        RETURN NEW;
    END IF;

    -- Бірдей нұсқаны қайта жазу қатар операцияларды бір чекке кезекке қояды.
    IF NEW IS NOT DISTINCT FROM OLD THEN
        RETURN NEW;
    END IF;
    IF OLD.status <> 'open' OR NEW.status <> 'paid'
        OR (to_jsonb(NEW) - 'status') <> (to_jsonb(OLD) - 'status') THEN
        RAISE EXCEPTION 'Чек деректері бекітілген, тек ашық чекті жабуға болады';
    END IF;
    SELECT sum(quantity * unit_price) INTO line_total FROM sale_items WHERE sale_id = OLD.id;
    SELECT COALESCE(sum(amount), 0) INTO paid_total FROM payments
    WHERE sale_id = OLD.id AND status = 'succeeded';
    IF line_total IS NULL OR line_total <> paid_total THEN
        RAISE EXCEPTION 'Чек жабылмады: тауарлар сомасы %, төлемдер %', line_total, paid_total;
    END IF;
    NEW.total_amount := line_total;
    RETURN NEW;
END;
$$;
COMMENT ON FUNCTION manage_sale() IS 'Чекті ашады немесе жолдар мен сәтті төлемдерді салыстырып жабады.';
CREATE TRIGGER manage_sale BEFORE INSERT OR UPDATE ON sales
    FOR EACH ROW EXECUTE FUNCTION manage_sale();
CREATE TRIGGER keep_receipt BEFORE DELETE ON sales FOR EACH ROW EXECUTE FUNCTION reject_change();

-- Чекті бірінші құлыптау. Жолдың жаңа нұсқасы ескі транзакциялық суретпен
-- қатар жазылғанда PostgreSQL сериализация қатесін беруге мүмкіндік береді.
CREATE FUNCTION lock_receipt(p_id integer) RETURNS sales LANGUAGE plpgsql AS $$
DECLARE
    receipt sales;
BEGIN
    UPDATE sales SET status = status WHERE id = p_id RETURNING * INTO STRICT receipt;
    RETURN receipt;
END;
$$;

CREATE FUNCTION check_prescription() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
    receipt sales := lock_receipt(NEW.sale_id);
    drug medicines;
    rx prescriptions;
BEGIN
    IF receipt.status <> 'open' THEN
        RAISE EXCEPTION 'Төленген чекке тауар қосуға болмайды';
    END IF;
    SELECT m.* INTO STRICT drug
    FROM inventory i JOIN medicine_batches b ON b.id = i.batch_id
    JOIN purchase_items pi ON pi.id = b.purchase_item_id
    JOIN medicines m ON m.id = pi.medicine_id WHERE i.id = NEW.inventory_id;
    IF NEW.prescription_id IS NULL THEN
        IF drug.requires_prescription THEN
            RAISE EXCEPTION 'Рецептуралық препаратқа рецепт міндетті';
        END IF;
    ELSE
        SELECT * INTO STRICT rx FROM prescriptions WHERE id = NEW.prescription_id;
        IF rx.customer_id IS DISTINCT FROM receipt.customer_id OR rx.medicine_id <> drug.id
           OR receipt.sale_date NOT BETWEEN rx.issued_date AND rx.valid_until THEN
            RAISE EXCEPTION 'Рецепт клиентке, препаратқа немесе сату күніне сәйкес емес';
        END IF;
    END IF;
    RETURN NEW;
END;
$$;
COMMENT ON FUNCTION check_prescription() IS 'Ашық чекті құлыптап, рецепттің клиентін, препаратын және мерзімін тексереді.';
CREATE TRIGGER trg_01_prescription_check BEFORE INSERT ON sale_items
    FOR EACH ROW EXECUTE FUNCTION check_prescription();

CREATE FUNCTION deduct_inventory() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
    receipt sales;
    stock record;
BEGIN
    SELECT * INTO STRICT receipt FROM sales WHERE id = NEW.sale_id;
    SELECT i.quantity, w.branch_id, b.received_date, b.expiry_date INTO STRICT stock
    FROM inventory i JOIN warehouses w ON w.id = i.warehouse_id
    JOIN medicine_batches b ON b.id = i.batch_id WHERE i.id = NEW.inventory_id FOR UPDATE OF i;
    IF stock.branch_id <> receipt.branch_id THEN
        RAISE EXCEPTION 'Қойма басқа филиалға тиесілі';
    ELSIF receipt.sale_date < stock.received_date THEN
        RAISE EXCEPTION 'Партия сату күніне дейін қабылданбаған';
    ELSIF receipt.sale_date > stock.expiry_date THEN
        RAISE EXCEPTION 'Сату күні партияның мерзімі өткен';
    ELSIF NEW.quantity > stock.quantity THEN
        RAISE EXCEPTION 'Қоймадағы қалдық жеткіліксіз';
    END IF;
    UPDATE inventory SET quantity = quantity - NEW.quantity,
        updated_at = greatest(updated_at, receipt.sale_date) WHERE id = NEW.inventory_id;
    RETURN NEW;
END;
$$;
COMMENT ON FUNCTION deduct_inventory() IS 'Қорды құлыптайды, филиал мен күндерді тексеріп, сатылған санды шегереді.';
CREATE TRIGGER trg_02_inventory_deduct BEFORE INSERT ON sale_items
    FOR EACH ROW EXECUTE FUNCTION deduct_inventory();

CREATE FUNCTION guard_payment() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
    receipt sales;
BEGIN
    IF TG_OP = 'UPDATE' AND NEW.sale_id <> OLD.sale_id THEN
        RAISE EXCEPTION 'Төлемді басқа чекке көшіруге болмайды';
    END IF;
    IF TG_OP = 'DELETE' THEN
        receipt := lock_receipt(OLD.sale_id);
    ELSE
        receipt := lock_receipt(NEW.sale_id);
    END IF;
    IF receipt.status <> 'open' THEN
        RAISE EXCEPTION 'Төленген чектің төлемдері бекітілген';
    END IF;
    IF TG_OP = 'DELETE' THEN RETURN OLD; END IF;
    RETURN NEW;
END;
$$;
COMMENT ON FUNCTION guard_payment() IS 'Төлем енгізу, өзгерту және жою алдында чектің ашық күйін тексереді.';
CREATE TRIGGER guard_payment BEFORE INSERT OR UPDATE OR DELETE ON payments
    FOR EACH ROW EXECUTE FUNCTION guard_payment();

CREATE FUNCTION guard_refund() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
    receipt sales;
BEGIN
    IF TG_OP = 'UPDATE' THEN
        IF pg_trigger_depth() < 2 OR (to_jsonb(NEW) - 'refund_amount') <> (to_jsonb(OLD) - 'refund_amount') THEN
            RAISE EXCEPTION 'Қайтарым құжаты бекітілген';
        END IF;
    ELSE
        receipt := lock_receipt(NEW.sale_id);
        IF receipt.status <> 'paid' OR NEW.return_date < receipt.sale_date OR NEW.refund_amount <> 0 THEN
            RAISE EXCEPTION 'Қайтарымға төленген чек, дұрыс күн және нөлдік бастапқы сома қажет';
        END IF;
    END IF;
    RETURN NEW;
END;
$$;
COMMENT ON FUNCTION guard_refund() IS 'Қайтарымның чегі мен күнін тексереді, соманы тек жолдардан жинауға рұқсат береді.';
CREATE TRIGGER guard_refund BEFORE INSERT OR UPDATE ON returns FOR EACH ROW EXECUTE FUNCTION guard_refund();
CREATE TRIGGER keep_refund BEFORE DELETE ON returns FOR EACH ROW EXECUTE FUNCTION reject_change();

-- FK тексерулері жолдарды құлыптамай тұрып, ортақ ретті орнату.
CREATE FUNCTION lock_return_source() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
    receipt_id integer;
    original_sale integer;
BEGIN
    SELECT sale_id INTO STRICT receipt_id FROM returns WHERE id = NEW.return_id;
    PERFORM lock_receipt(receipt_id);
    SELECT sale_id INTO STRICT original_sale FROM sale_items WHERE id = NEW.sale_item_id FOR UPDATE;
    IF original_sale <> receipt_id THEN
        RAISE EXCEPTION 'Тауар жолы қайтарым чегіне тиесілі емес';
    END IF;
    RETURN NEW;
END;
$$;
COMMENT ON FUNCTION lock_return_source() IS 'Қайтарым алдында алдымен чекті, кейін сол чектің тауар жолын құлыптайды.';
CREATE TRIGGER lock_return_source BEFORE INSERT ON return_items
    FOR EACH ROW EXECUTE FUNCTION lock_return_source();

CREATE FUNCTION post_return_line() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
    document returns;
    line sale_items;
    returned bigint;
    batch_info record;
BEGIN
    SELECT * INTO STRICT document FROM returns WHERE id = NEW.return_id;
    SELECT * INTO STRICT line FROM sale_items WHERE id = NEW.sale_item_id;
    -- AFTER INSERT: осы оператордағы барлық жаңа жолдар қосындыға кірген.
    SELECT sum(quantity) INTO returned FROM return_items WHERE sale_item_id = line.id;
    IF returned > line.quantity THEN
        RAISE EXCEPTION 'Қайтарылған саны сатылған саннан асады';
    END IF;
    IF NEW.disposition = 'restock' THEN
        SELECT b.expiry_date, m.requires_prescription INTO STRICT batch_info
        FROM inventory i JOIN medicine_batches b ON b.id = i.batch_id
        JOIN purchase_items pi ON pi.id = b.purchase_item_id JOIN medicines m ON m.id = pi.medicine_id
        WHERE i.id = line.inventory_id FOR UPDATE OF i;
        IF batch_info.requires_prescription OR document.return_date > batch_info.expiry_date THEN
            RAISE EXCEPTION 'Рецептуралық немесе мерзімі өткен тауарды қорға қосуға болмайды';
        END IF;
        UPDATE inventory SET quantity = quantity + NEW.quantity,
            updated_at = greatest(updated_at, document.return_date) WHERE id = line.inventory_id;
    END IF;
    UPDATE returns SET refund_amount = refund_amount + NEW.quantity * line.unit_price
    WHERE id = document.id;
    RETURN NULL;
END;
$$;
COMMENT ON FUNCTION post_return_line() IS 'Қайтарым лимитін бастапқы чек бойынша тексеріп, қор мен ақшаны сол транзакцияда жаңартады.';
CREATE TRIGGER post_return_line AFTER INSERT ON return_items
    FOR EACH ROW EXECUTE FUNCTION post_return_line();

-- BEFORE INSERT орындалып, ON CONFLICT DO NOTHING сату жолын өткізіп жіберсе,
-- құжатсыз қор қозғалысы транзакциямен бірге бекітілмеуі керек.
CREATE FUNCTION reconcile_stock() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
    available integer;
    expected bigint;
BEGIN
    SELECT i.quantity, b.received_quantity
        - COALESCE((SELECT sum(s.quantity) FROM sale_items s WHERE s.inventory_id = i.id), 0)
        + COALESCE((SELECT sum(r.quantity) FROM return_items r JOIN sale_items s ON s.id = r.sale_item_id
                    WHERE s.inventory_id = i.id AND r.disposition = 'restock'), 0)
    INTO STRICT available, expected
    FROM inventory i JOIN medicine_batches b ON b.id = i.batch_id WHERE i.id = NEW.id;
    IF available <> expected THEN
        RAISE EXCEPTION 'Қор құжаттарға сәйкес емес: %, қалдық %, есеп %', NEW.id, available, expected;
    END IF;
    RETURN NULL;
END;
$$;
COMMENT ON FUNCTION reconcile_stock() IS 'Транзакция соңында өзгерген қалдықты қабылдау, сату және қайтарым құжаттарымен салыстырады.';
CREATE CONSTRAINT TRIGGER reconcile_stock AFTER INSERT OR UPDATE ON inventory
    DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION reconcile_stock();

COMMIT;
