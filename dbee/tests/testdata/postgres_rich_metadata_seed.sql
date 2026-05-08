DROP SCHEMA IF EXISTS pg20_sales CASCADE;
DROP SCHEMA IF EXISTS pg20_inventory CASCADE;
DROP SCHEMA IF EXISTS pg20_analytics CASCADE;

CREATE SCHEMA pg20_sales;
CREATE SCHEMA pg20_inventory;
CREATE SCHEMA pg20_analytics;

CREATE SEQUENCE pg20_sales.invoice_number_seq
    START WITH 1000
    INCREMENT BY 7
    CACHE 11;

CREATE SEQUENCE pg20_inventory.stock_movement_seq
    START WITH 10
    INCREMENT BY 3
    CACHE 5;

CREATE TABLE pg20_sales.customers (
    tenant_id INTEGER NOT NULL,
    customer_id BIGINT NOT NULL,
    surrogate_id BIGINT GENERATED ALWAYS AS IDENTITY,
    first_name TEXT NOT NULL,
    last_name TEXT NOT NULL,
    full_name TEXT GENERATED ALWAYS AS (first_name || ' ' || last_name) STORED,
    status TEXT NOT NULL DEFAULT 'active',
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (tenant_id, customer_id)
);

CREATE TABLE pg20_sales.orders (
    tenant_id INTEGER NOT NULL,
    order_id BIGINT NOT NULL,
    customer_id BIGINT NOT NULL,
    invoice_number BIGINT NOT NULL DEFAULT nextval('pg20_sales.invoice_number_seq'::regclass),
    order_status TEXT NOT NULL DEFAULT 'open',
    ordered_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (tenant_id, order_id),
    CONSTRAINT fk_orders_customer
        FOREIGN KEY (tenant_id, customer_id)
        REFERENCES pg20_sales.customers (tenant_id, customer_id)
);

CREATE TABLE pg20_sales.order_items (
    tenant_id INTEGER NOT NULL,
    order_id BIGINT NOT NULL,
    line_no INTEGER NOT NULL,
    item_id BIGINT GENERATED ALWAYS AS IDENTITY,
    sku TEXT NOT NULL,
    quantity INTEGER NOT NULL DEFAULT 1,
    unit_price NUMERIC(12,2) NOT NULL DEFAULT 0,
    line_total NUMERIC(12,2) GENERATED ALWAYS AS (quantity * unit_price) STORED,
    PRIMARY KEY (tenant_id, order_id, line_no),
    CONSTRAINT fk_order_items_order
        FOREIGN KEY (tenant_id, order_id)
        REFERENCES pg20_sales.orders (tenant_id, order_id)
);

CREATE TABLE pg20_inventory.orders (
    tenant_id INTEGER NOT NULL,
    order_id BIGINT NOT NULL,
    warehouse_code TEXT NOT NULL,
    PRIMARY KEY (tenant_id, order_id)
);

CREATE TABLE pg20_inventory.stock_movements (
    tenant_id INTEGER NOT NULL,
    movement_id BIGINT NOT NULL DEFAULT nextval('pg20_inventory.stock_movement_seq'::regclass),
    sku TEXT NOT NULL,
    quantity_delta INTEGER NOT NULL,
    PRIMARY KEY (tenant_id, movement_id)
);

INSERT INTO pg20_sales.customers (tenant_id, customer_id, first_name, last_name, status) VALUES
    (10, 100, 'Ada', 'Lovelace', 'active'),
    (10, 101, 'Grace', 'Hopper', 'active'),
    (20, 200, 'Katherine', 'Johnson', 'active');

INSERT INTO pg20_sales.orders (tenant_id, order_id, customer_id, order_status) VALUES
    (10, 5000, 100, 'open'),
    (10, 5001, 101, 'closed'),
    (20, 6000, 200, 'open');

INSERT INTO pg20_sales.order_items (tenant_id, order_id, line_no, sku, quantity, unit_price) VALUES
    (10, 5000, 1, 'SKU-ALPHA', 2, 19.95),
    (10, 5000, 2, 'SKU-BETA', 1, 7.50),
    (10, 5001, 1, 'SKU-GAMMA', 5, 3.25),
    (20, 6000, 1, 'SKU-ALPHA', 1, 19.95);

INSERT INTO pg20_inventory.orders (tenant_id, order_id, warehouse_code) VALUES
    (10, 9000, 'DFW'),
    (20, 9001, 'PHX');

INSERT INTO pg20_inventory.stock_movements (tenant_id, sku, quantity_delta) VALUES
    (10, 'SKU-ALPHA', 8),
    (20, 'SKU-BETA', -2);

CREATE INDEX idx_order_items_lookup
    ON pg20_sales.order_items (tenant_id ASC, order_id DESC)
    INCLUDE (sku, quantity);

CREATE UNIQUE INDEX idx_orders_invoice_number
    ON pg20_sales.orders (invoice_number);

CREATE VIEW pg20_analytics.active_customers AS
    SELECT tenant_id, customer_id, full_name, status
    FROM pg20_sales.customers
    WHERE status = 'active';

CREATE MATERIALIZED VIEW pg20_analytics.customer_order_summary AS
    SELECT c.tenant_id,
           c.customer_id,
           c.full_name,
           count(o.order_id)::INTEGER AS order_count,
           coalesce(sum(oi.quantity), 0)::INTEGER AS total_items
    FROM pg20_sales.customers c
    LEFT JOIN pg20_sales.orders o
      ON o.tenant_id = c.tenant_id
     AND o.customer_id = c.customer_id
    LEFT JOIN pg20_sales.order_items oi
      ON oi.tenant_id = o.tenant_id
     AND oi.order_id = o.order_id
    GROUP BY c.tenant_id, c.customer_id, c.full_name;

CREATE UNIQUE INDEX idx_customer_order_summary_customer
    ON pg20_analytics.customer_order_summary (tenant_id, customer_id);

CREATE INDEX idx_customer_order_summary_lookup
    ON pg20_analytics.customer_order_summary (tenant_id ASC, order_count DESC)
    INCLUDE (total_items);
