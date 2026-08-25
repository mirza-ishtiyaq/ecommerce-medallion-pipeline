-- ====================================================================
-- PHASE 4: ADVANCED BUSINESS INTELLIGENCE & AD-HOC ANALYTICS
-- Objective: Execute enterprise strategic queries targeting C-Suite requests
-- utilizing analytical window functions, metrics momentum, and bottlenecks.
-- ====================================================================

-- --------------------------------------------------------------------
-- REQUEST 1 (VP OF LOGISTICS): Identify Top 5 Transit Bottleneck Lanes
-- --------------------------------------------------------------------
-- master_operations is item-grain (one row per order line-item, via the
-- LEFT JOIN to olist_order_items in 03_gold_star_schema.sql), but
-- delivery_status and actual_delivery_days are order-level values
-- repeated across every item row of the same order. Aggregating the raw
-- table directly overweights multi-item orders in both total_orders and
-- late_percentage. order_delivery_dedup collapses back to one row per
-- order before the lane-level aggregation below.
WITH order_delivery_dedup AS (
    SELECT DISTINCT
        order_id,
        origin_state,
        destination_state,
        delivery_status,
        actual_delivery_days
    FROM ecommerce_logistics.gold.master_operations
)
SELECT
    origin_state,
    destination_state,
    COUNT(DISTINCT order_id) AS total_orders,
    ROUND(AVG(actual_delivery_days), 1) AS avg_delivery_days,
    ROUND((SUM(CASE WHEN delivery_status = 'Late' THEN 1 ELSE 0 END) * 100.0) / COUNT(*), 2) AS late_percentage
FROM order_delivery_dedup
GROUP BY origin_state, destination_state
HAVING COUNT(DISTINCT order_id) >= 50
ORDER BY late_percentage DESC
LIMIT 5;

-- --------------------------------------------------------------------
-- REQUEST 1b (VP OF LOGISTICS): National Baseline vs. Regional Outlier
-- --------------------------------------------------------------------
-- The runnable source of the README's "26-day regional outlier vs
-- 12.3-day national baseline" figure -- on the same deduplicated,
-- order-grain population as Request 1 above, not the raw fanned-out table.
WITH order_delivery_dedup AS (
    SELECT DISTINCT order_id, destination_state, actual_delivery_days
    FROM ecommerce_logistics.gold.master_operations
)
SELECT
    destination_state,
    COUNT(DISTINCT order_id) AS total_orders,
    ROUND(AVG(actual_delivery_days), 1) AS avg_delivery_days,
    ROUND((SELECT AVG(actual_delivery_days) FROM order_delivery_dedup), 1) AS national_avg_delivery_days
FROM order_delivery_dedup
GROUP BY destination_state
HAVING COUNT(DISTINCT order_id) >= 50
ORDER BY avg_delivery_days DESC
LIMIT 5;

-- --------------------------------------------------------------------
-- REQUEST 2 (CMO): Identify Top 5 Revenue-Generating Categories & Average Price
-- --------------------------------------------------------------------
SELECT
    p.product_category_name,
    COUNT(DISTINCT o.order_id) AS total_orders,
    ROUND(SUM(oi.price), 2) AS total_revenue,
    ROUND(AVG(oi.price), 2) AS avg_item_price
FROM ecommerce_logistics.silver.olist_orders o
INNER JOIN ecommerce_logistics.silver.olist_order_items oi ON o.order_id = oi.order_id
INNER JOIN ecommerce_logistics.silver.olist_products p     ON oi.product_id = p.product_id
WHERE o.order_status = 'delivered'
GROUP BY p.product_category_name
ORDER BY total_revenue DESC
LIMIT 5;

-- --------------------------------------------------------------------
-- REQUEST 3 (VP OF SALES): Isolate the Top #1 Product Vertical per Individual State
-- --------------------------------------------------------------------
WITH ranked_regional_revenue AS (
    SELECT
        c.customer_state,
        p.product_category_name,
        ROUND(SUM(oi.price), 2) AS total_revenue,
        ROUND(COUNT(DISTINCT o.order_id), 2) AS total_orders,
        RANK() OVER (PARTITION BY c.customer_state ORDER BY SUM(oi.price) DESC) AS revenue_rank
    FROM ecommerce_logistics.silver.olist_orders o
    INNER JOIN ecommerce_logistics.silver.olist_customers c ON o.customer_id = c.customer_id
    INNER JOIN ecommerce_logistics.silver.olist_order_items oi ON o.order_id = oi.order_id
    INNER JOIN ecommerce_logistics.silver.olist_products p     ON oi.product_id = p.product_id
    WHERE o.order_status = 'delivered'
    GROUP BY c.customer_state, p.product_category_name
)
SELECT customer_state, product_category_name, total_revenue, total_orders
FROM ranked_regional_revenue
WHERE revenue_rank = 1
ORDER BY total_revenue DESC;

-- --------------------------------------------------------------------
-- REQUEST 4 (CFO): Compute Month-Over-Month (MoM) Traction & Growth Velocity
-- --------------------------------------------------------------------
WITH monthly_revenue_ledger AS (
    SELECT
        DATE_FORMAT(CAST(o.order_purchase_timestamp AS TIMESTAMP), 'yyyy-MM') AS financial_month,
        ROUND(SUM(oi.price), 2) AS current_month_revenue,
        LAG(ROUND(SUM(oi.price), 2)) OVER (
            ORDER BY DATE_FORMAT(CAST(o.order_purchase_timestamp AS TIMESTAMP), 'yyyy-MM') ASC
        ) AS previous_month_revenue
    FROM ecommerce_logistics.silver.olist_orders o
    INNER JOIN ecommerce_logistics.silver.olist_order_items oi ON o.order_id = oi.order_id
    WHERE o.order_status = 'delivered'
    GROUP BY financial_month
)
SELECT
    financial_month,
    current_month_revenue,
    previous_month_revenue,
    -- NULLIF guards the first month in the series, where LAG() has no prior
    -- row: previous_month_revenue is NULL there, so growth% is reported as
    -- NULL (no comparable prior month) instead of erroring on a NULL divisor.
    ROUND(((current_month_revenue - previous_month_revenue) / NULLIF(previous_month_revenue, 0) * 100), 2) AS mom_growth_percentage
FROM monthly_revenue_ledger
ORDER BY financial_month;
