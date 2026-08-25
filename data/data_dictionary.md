# Data Dictionary — E-Commerce Fulfilment Medallion Pipeline

This document provides field-level documentation for every data source and derived table used in the Databricks Medallion pipeline.

---

## Source Dataset

**Brazilian E-Commerce (Olist)** — a public dataset from [Kaggle](https://www.kaggle.com/datasets/olistbr/brazilian-ecommerce) containing **~99,000 real orders** placed between 2016–2018 across 6 interrelated tables.

> **Note:** Raw CSVs are not checked into this repo (`data/datasets/` is an intentionally empty placeholder). Download from Kaggle and land into your Databricks workspace to reproduce.

---

## Bronze Layer Tables (`ecommerce_logistics.bronze`)

Raw, unmodified ingestion from CSV. No transformations applied — data lineage starts here.

### `olist_orders`

| Column | Type | Description |
|---|---|---|
| `order_id` | `STRING` | Unique order identifier (PK) |
| `customer_id` | `STRING` | FK to `olist_customers` |
| `order_status` | `STRING` | Order lifecycle state: `delivered`, `shipped`, `canceled`, `unavailable`, `processing`, etc. |
| `order_purchase_timestamp` | `STRING` | Timestamp of purchase (text — parsed to `TIMESTAMP` in Silver) |
| `order_approved_at` | `STRING` | Timestamp of payment approval |
| `order_delivered_carrier_date` | `STRING` | Timestamp when carrier picked up the order |
| `order_delivered_customer_date` | `STRING` | Timestamp when customer received delivery |
| `order_estimated_delivery_date` | `STRING` | Estimated delivery date promised to customer |

### `olist_customers`

| Column | Type | Description |
|---|---|---|
| `customer_id` | `STRING` | Unique customer identifier (PK) |
| `customer_unique_id` | `STRING` | De-duplicated customer identifier across orders |
| `customer_zip_code_prefix` | `STRING` | First 5 digits of customer zip code |
| `customer_city` | `STRING` | Customer city name |
| `customer_state` | `STRING` | Customer state abbreviation (e.g., `SP`, `RJ`, `RO`) |

### `olist_order_items`

| Column | Type | Description |
|---|---|---|
| `order_id` | `STRING` | FK to `olist_orders` |
| `order_item_id` | `INT` | Sequential item number within an order |
| `product_id` | `STRING` | FK to `olist_products` |
| `seller_id` | `STRING` | FK to `olist_sellers` |
| `price` | `DOUBLE` | Item sale price (BRL) |
| `freight_value` | `DOUBLE` | Freight cost charged for the item (BRL) |

### `olist_products`

| Column | Type | Description |
|---|---|---|
| `product_id` | `STRING` | Unique product identifier (PK) |
| `product_category_name` | `STRING` | Product category (Portuguese) |
| `product_weight_g` | `INT` | Product weight in grams |
| `product_length_cm` | `INT` | Product length in centimeters |
| `product_height_cm` | `INT` | Product height in centimeters |
| `product_width_cm` | `INT` | Product width in centimeters |

### `olist_sellers`

| Column | Type | Description |
|---|---|---|
| `seller_id` | `STRING` | Unique seller identifier (PK) |
| `seller_zip_code_prefix` | `STRING` | First 5 digits of seller zip code |
| `seller_city` | `STRING` | Seller city name |
| `seller_state` | `STRING` | Seller state abbreviation — used as `origin_state` in Gold layer |

### `olist_geolocation`

| Column | Type | Description |
|---|---|---|
| `geolocation_zip_code_prefix` | `STRING` | Zip code prefix |
| `geolocation_lat` | `DOUBLE` | Latitude |
| `geolocation_lng` | `DOUBLE` | Longitude |
| `geolocation_city` | `STRING` | City name |
| `geolocation_state` | `STRING` | State abbreviation |

---

## Silver Layer Tables (`ecommerce_logistics.silver`)

Schema enforcement, temporal normalization, and null filtering applied.

### `olist_orders` (Silver)

| Transformation | Detail |
|---|---|
| Timestamp parsing | All 5 temporal columns cast from `STRING` → `TIMESTAMP` via `CAST(... AS TIMESTAMP)` |
| Null filtering | Rows where `order_id IS NULL` or `customer_id IS NULL` are excluded |

All other Silver tables (`olist_customers`, `olist_order_items`, `olist_sellers`, `olist_products`, `olist_geolocation`) are promoted from Bronze without transformation — schema-validated pass-through.

---

## Gold Layer Fact Tables (`ecommerce_logistics.gold`)

### `master_operations` — Fulfilment & Transit Performance Fact Table

| Column | Source | Description |
|---|---|---|
| `order_id` | `silver.olist_orders` | Order identifier |
| `order_status` | `silver.olist_orders` | Always `'delivered'` (filtered) |
| `product_id` | `silver.olist_order_items` | Product identifier |
| `price` | `silver.olist_order_items` | Item sale price (BRL) |
| `freight_value` | `silver.olist_order_items` | Freight cost (BRL) |
| `destination_state` | `silver.olist_customers.customer_state` | Customer destination state |
| `origin_state` | `silver.olist_sellers.seller_state` | Seller origin state |
| `product_weight_g` | `silver.olist_products` | Product weight |
| `actual_delivery_days` | **Derived** | `DATEDIFF(delivered_customer_date, purchase_timestamp)` |
| `promised_delivery_days` | **Derived** | `DATEDIFF(estimated_delivery_date, purchase_timestamp)` |
| `delivery_status` | **Derived** | `'Late'` if actual > estimated, else `'On-Time'` — upstream SLA/OTIF flag |

> **Star-schema design:** `master_operations` is a denormalized fact table joining orders → items → customers → sellers → products via LEFT JOINs. Optimized for Power BI Import Mode with pre-computed transit metrics.

### `lost_revenue` — Financial Leakage Fact Table

| Column | Source | Description |
|---|---|---|
| `order_id` | `silver.olist_orders` | Order identifier |
| `order_status` | `silver.olist_orders` | Only `'canceled'` or `'unavailable'` orders |
| `order_purchase_timestamp` | `silver.olist_orders` | When the order was originally placed |
| `lost_item_revenue` | `silver.olist_order_items.price` | Revenue that was never realized — `COALESCE(price, 0)` |

> **Total unrealized revenue:** **$97.24K** trapped in canceled/unavailable order states — **8.12%** of a **$1.20M** gross pipeline.

---

## Key Metrics Derived in the Pipeline

| Metric | Value | Source |
|---|---|---|
| **Unrealized revenue** | $97,240 | `SUM(lost_item_revenue)` from `gold.lost_revenue` |
| **Gross pipeline** | $1.20M | `SUM(price)` from all delivered orders |
| **Leakage rate** | 8.12% | $97.24K / $1.20M |
| **National transit baseline** | 12.3 days | `AVG(actual_delivery_days)`, deduplicated to one row per `order_id` first — see Request 1b in `04_executive_adhoc_analysis.sql`. `master_operations` is item-grain (one row per order line-item), so this can't be averaged directly without overweighting multi-item orders. |
| **Worst regional outlier** | 26 days | Rondônia (`RO`) — corrected from original mislabeling as Roraima (`RR`); also computed on the deduplicated order-grain population |
| **Late delivery rate** | Varies by lane | `delivery_status = 'Late'` percentage per origin-destination pair, same order-grain dedup applied in Request 1 |
