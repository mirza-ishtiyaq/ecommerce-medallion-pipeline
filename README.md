# E-Commerce Fulfilment Medallion Pipeline & Revenue Leakage Audit

![Star Schema Data Model](./docs/images/data_model.png)

A Databricks/Delta Lake medallion pipeline (Bronze → Silver → Gold) that pushes SLA and revenue-leakage logic upstream of Power BI, surfacing $97.24K in unrealised revenue and a 26-day regional transit outlier out of ~99K real Olist orders.

---

## Business Problem

E-commerce fulfilment teams operating on raw transactional databases faced two bottlenecks:
1. **Dashboard latency:** Reporting directly off un-indexed source tables created slow Power BI refresh cycles.
2. **Fragmented business logic:** SLA flags, revenue-loss classification, and transit-time calculations were embedded in Power BI DAX instead of being resolved upstream in the warehouse — making them untestable and unreproducible.

The result: leadership had **no single source of truth** for order fulfilment performance, no visibility into which regional lanes were failing OTIF targets, and no quantified view of revenue trapped in non-delivered order states.

---

## The Data

Real operational datasets: the public [Brazilian E-Commerce (Olist) dataset](https://www.kaggle.com/datasets/olistbr/brazilian-ecommerce) — **~99,000 real orders** across customers, orders, items, products, sellers, and geolocation tables.

> **Note:** Raw CSVs are **not** checked into this repo due to file size (`data/datasets/` is an intentionally empty placeholder). Download the dataset from Kaggle and land it in your own Bronze source location to reproduce the pipeline end-to-end.

---

## The Stack

| Layer | Tool |
|---|---|
| **Data Platform** | Databricks / Spark SQL |
| **Storage Format** | Delta Lake (ACID-compliant) |
| **Data Warehousing** | Medallion Architecture (Bronze → Silver → Gold) |
| **Business Intelligence** | Power BI (Import Mode / Star Schema Data Model) |

```text
       [Raw Transactional & Operational Extracts]
                         │
                         ▼
       BRONZE LAYER     : Raw Delta Lake Migration (01_bronze_ingestion.sql)
                         │
                         ▼ (Timestamp Parsing, Schema Enforcement, Null Filtering)
       SILVER LAYER     : Cleaned Operational Tables (02_silver_transformations.sql)
                         │
                         ▼ (Star Schema Joins & Upstream Performance Pre-Calculations)
       GOLD LAYER       : Production Fact Tables (03_gold_star_schema.sql)
                         │
                         ▼ (Lightweight Import / DirectQuery)
       POWER BI         : Executive Financial & Logistics Dashboards
```

---

## Methodology

### Bronze Layer (Raw Ingestion)
All 6 Olist source tables are migrated into a Delta Lake catalog (`ecommerce_logistics.bronze`) with no transformation — establishing data lineage and ACID-compliant storage.

### Silver Layer (Schema Enforcement & Cleansing)
- **Temporal normalization:** All 5 date/time columns in `olist_orders` cast from `STRING` to `TIMESTAMP`
- **Null filtering:** Orders missing `order_id` or `customer_id` are excluded
- **Dimensional pass-through:** Customer, seller, product, and geolocation tables promoted with schema validation

### Gold Layer (Star Schema & Business Logic)
Two purpose-built fact tables, pre-computed for Power BI Import Mode:

1. **`master_operations`** — Fulfilment performance fact table
   - Joins orders → items → customers → sellers → products via `LEFT JOIN`
   - Pre-computes `actual_delivery_days` and `promised_delivery_days` via `DATEDIFF()`
   - Pre-computes `delivery_status` (`'Late'` / `'On-Time'`) — an upstream **OTIF flag** that eliminates the need for DAX-level SLA logic
   - Filtered to `order_status = 'delivered'` only

2. **`lost_revenue`** — Financial leakage fact table
   - Isolates `canceled` and `unavailable` orders with their associated `price` values
   - Surfaces the **$97.24K unrealised revenue** figure — a documented, table-backed number, not an estimate

### Ad-Hoc Executive Analytics
Stakeholder-driven queries using `RANK()`, `LAG()`, and `CASE` window functions:
- Top 5 transit bottleneck lanes, deduplicated to order-grain first (VP of Logistics)
- National transit baseline vs. worst regional outlier, same dedup applied (VP of Logistics)
- Top 5 revenue-generating categories (CMO)
- #1 product vertical per state (VP of Sales)
- Month-over-Month revenue growth velocity, guarded against a null first-month comparison (CFO)

---

## What It Found

| Finding | Value |
|---|---|
| **Unrealised revenue surfaced** | **$97.24K** trapped in canceled/unavailable order states — **8.12%** of a **$1.20M** gross pipeline |
| **Transit outlier** | **26-day** regional delivery average vs a **12.3-day** national baseline |
| **Transformations pushed upstream** | **90%** of data cleaning, temporal conversions, and star-schema modeling moved from Power BI into the Databricks warehouse |
| **Dashboard labeling bug caught** | The 26-day bottleneck state is Rondônia ("RO"), not Roraima ("RR") as originally mislabeled — corrected under independent review |

![Executive Financial Performance Dashboard](./docs/images/page1_finance.png)
![Logistics & Supply Chain Dashboard](./docs/images/page2_logistics.png)

**Stakeholder summary:** Finance can act on a documented **$97.24K leakage figure** today. Logistics should investigate **Rondônia specifically** before renegotiating carrier contracts on that lane.

---

## How to Run It

### Prerequisites
- **Databricks** workspace (Community Edition works for SQL execution)
- **Power BI Desktop** (Windows) for the interactive dashboard
- Download the [Olist dataset from Kaggle](https://www.kaggle.com/datasets/olistbr/brazilian-ecommerce)

### Step-by-step

```bash
# 1. Clone the repository
git clone https://github.com/mirza-ishtiyaq/ecommerce-medallion-pipeline.git
cd ecommerce-medallion-pipeline

# 2. Upload Olist CSV files to your Databricks workspace
# Place the downloaded Kaggle CSVs in your DBFS or Unity Catalog volume
```

```sql
-- 3. Execute the SQL pipeline in Databricks SQL Worksheet, in order:

-- Step 1: Ingest raw data into Bronze Delta tables
-- Run: sql/01_bronze_ingestion.sql

-- Step 2: Clean and transform into Silver layer
-- Run: sql/02_silver_transformations.sql

-- Step 3: Build Gold star schema with pre-computed metrics
-- Run: sql/03_gold_star_schema.sql

-- Step 4: Run executive ad-hoc analysis queries
-- Run: sql/04_executive_adhoc_analysis.sql
```

```text
# 4. Open the Power BI dashboard
# File: dashboards/Ecommerce Olist Dashboard.pbix
# Open in Power BI Desktop → the star schema will render automatically
# Explore Page 1 (Financial) and Page 2 (Logistics)
```

---

## Repository Structure

```
ecommerce-medallion-pipeline/
├── README.md
├── LICENSE
├── dashboards/
│   └── Ecommerce Olist Dashboard.pbix
├── data/
│   ├── data_dictionary.md                         # Field-level documentation for all tables
│   └── datasets/                                  # Intentionally empty — download from Kaggle
├── docs/
│   └── images/
│       ├── data_model.png
│       ├── page1_finance.png
│       └── page2_logistics.png
└── sql/
    ├── 01_bronze_ingestion.sql
    ├── 02_silver_transformations.sql
    ├── 03_gold_star_schema.sql
    └── 04_executive_adhoc_analysis.sql
```

---

**Author:** Mirza Ishtiyaq Baig — Data Analyst, Supply Chain & Service Operations Analytics
**LinkedIn:** [linkedin.com/in/mirzaishtiyaqbaig](https://www.linkedin.com/in/mirzaishtiyaqbaig/)
**Email:** mirzaishtiyaqbaig1@gmail.com
**GitHub:** [github.com/mirza-ishtiyaq](https://github.com/mirza-ishtiyaq)
