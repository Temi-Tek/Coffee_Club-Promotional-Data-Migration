# CoffeeClub Database Capstone — Technical README

---

## Table of Contents
1. [Project Overview](#project-overview)
2. [Database Model](#database-model)
3. [Rationale: 2NF Logic](#rationale-2nf-logic)
4. [Workflow: Transformation to Loading](#workflow-transformation-to-loading)
5. [SQL Implementation Summary](#sql-implementation-summary)
6. [Group Role Breakdown](#group-role-breakdown)

---

## Project Overview

This Capstone transforms a flat, CSV-based dataset for **CoffeeClub** — a coffee loyalty programme — into a high-performance, normalised PostgreSQL relational database. The raw data covers 17,000 customers, 306,534 event records, and 10 promotional offers tracked over a 30-day period.

The project is structured across four technical phases:

| Phase | Focus |
|---|---|
| 1 | Relational Enforcement & Indexing |
| 2 | Time Transformation & Data Cleaning |
| 3 | Summary Views (Analytical Layer) |
| 4 | Feature Engineering (Demographic Bucketing) |

---

## Database Model

```
customers                events                    offers
─────────────────        ──────────────────────    ──────────────────
customer_id (PK) ◄──── customer_id (FK)           offer_id (PK) ◄──┐
became_member_on         event_id (PK)             offer_type        │
gender                   event                     difficulty        │
age                      offer_id (FK) ────────────────────────────►─┘
age_group                amount                    reward
income                   reward                    duration
income_band              time                         │
                         day                          ▼
                         hour_of_day          offer_channels
                         time_hours           ──────────────────────
                         time_interval        offer_id (FK, PK) ◄──┘
                                              channel  (PK)
```

**Primary Keys:**

| Table | Primary Key | Type |
|---|---|---|
| customers | `customer_id` | Natural (UUID text) |
| offers | `offer_id` | Natural (UUID text) |
| events | `event_id` | Surrogate (BIGSERIAL) |
| offer_channels | `(offer_id, channel)` | Composite |

**Foreign Keys:**

| Table | Column | References | On Delete |
|---|---|---|---|
| events | `customer_id` | customers(customer_id) | CASCADE |
| events | `offer_id` | offers(offer_id) | SET NULL |
| offer_channels | `offer_id` | offers(offer_id) | CASCADE |

---

## Rationale: 2NF Logic

### What is 2NF?

Second Normal Form (2NF) requires that:
1. The table is already in First Normal Form (1NF) — each column holds a single, atomic value
2. Every non-key column is **fully dependent** on the entire primary key, not just part of it

### Problem 1: Channels Stored as a List (1NF Violation)

The raw `offers` table stored channels as an array inside a single column:

```
offer_id   |  channels
-----------|---------------------------------
abc123     |  ['email', 'mobile', 'social']
```

A single cell holding multiple values violates 1NF. Each channel is a separate fact and must occupy its own row.

**Fix:** The `channels` column was extracted into a separate `offer_channels` table:

```
offer_id   |  channel
-----------|----------
abc123     |  email
abc123     |  mobile
abc123     |  social
```

A composite primary key `(offer_id, channel)` ensures no offer-channel pair is ever duplicated.

### Problem 2: No Primary Key on Events (Integrity Risk)

The raw `events` table had no column that uniquely identified each row. Without a primary key, duplicate rows can silently enter the table and corrupt aggregations.

**Fix:** A surrogate key `event_id BIGSERIAL` was added — PostgreSQL auto-assigns a unique integer to every new event row.

### Problem 3: Age 118 Placeholder (Data Quality)

2,175 customers had `age = 118` alongside `NULL` gender and `NULL` income. This was a placeholder for missing data, not a real age, which would skew any age-based aggregation.

**Fix:**
```sql
UPDATE customers
SET age = NULL
WHERE age = 118;
```

### Problem 4: Orphaned Records Risk

Without foreign key constraints, it was possible to:
- Insert an event for a customer that doesn't exist
- Insert an event referencing an offer that doesn't exist

**Fix:** Foreign key constraints enforce referential integrity at the database level, making orphaned records impossible.

---

## Workflow: Transformation to Loading

### Phase 1 — Relational Enforcement & Indexing

**Goal:** Add structural constraints to enforce data integrity.

```
Raw CSVs imported into PostgreSQL
          ↓
Add PRIMARY KEY constraints to all tables
          ↓
Add FOREIGN KEY constraints between tables
          ↓
Add B-Tree INDEXES on high-traffic columns
          ↓
Database is now relationally enforced
```

**Key decisions:**

- `ON DELETE CASCADE` for events → customers: deleting a customer removes their events
- `ON DELETE SET NULL` for events → offers: deleting an offer preserves transaction rows
- Indexes placed on `customer_id`, `offer_id`, `event`, and `time` in the events table — the largest table at 306,534 rows

---

### Phase 2 — Time Transformation & Data Cleaning

**Goal:** Convert the raw `time` integer (hours elapsed) into meaningful analytical columns.

```
Raw time column (integer: 0–714)
          ↓
day = time / 24          → which day of the 30-day period (0–29)
hour_of_day = time % 24  → what hour within that day (0, 6, 12, 18)
time_hours = time::FLOAT → float version for numeric analysis
time_interval = (time || ' hours')::INTERVAL → for date arithmetic
          ↓
CHECK constraints added: day BETWEEN 0 AND 29, hour_of_day BETWEEN 0 AND 23
          ↓
Age 118 cleaned: UPDATE customers SET age = NULL WHERE age = 118
```

**Why INTERVAL vs FLOAT?**

| Type | Use Case |
|---|---|
| `INTERVAL` | Date arithmetic — adding elapsed time to a real timestamp |
| `FLOAT` | Numeric analysis — averages, ranges, differences |

Both columns were added to support either use case.

---

### Phase 3 — Summary Views (Analytical Layer)

**Goal:** Create reusable SQL views that non-technical users can query with a single `SELECT *`.

```
events + offers tables
          ↓
v_offer_performance   → received vs viewed vs completed per offer, with completion rate %
          ↓
v_best_offers         → ranked table with performance labels (High / Average / Low Performer)
          ↓
v_informational_impact → transactions that followed informational offer views
          ↓
v_informational_summary → aggregated: how many customers bought after seeing an informational offer?
```

**Key findings from the views:**

- Overall offer completion rate: **44%**
- Discount offers outperform BOGO: **58.6% vs 51.4%**
- Top performing offer (discount, difficulty 10, 10-day duration): **70% completion rate**
- Informational offers cannot be completed — their impact is measured through downstream transactions

---

### Phase 4 — Feature Engineering (Demographic Bucketing)

**Goal:** Pre-label every customer with a readable age group and income band so demographic queries require no calculation at query time.

```
customers table (raw age + income)
          ↓
age_group column added:
    18–29  → 'Young Adult'
    30–44  → 'Adult'
    45–59  → 'Middle Aged'
    60–74  → 'Senior'
    75+    → 'Older Senior'
    NULL   → 'Unknown'
          ↓
income_band column added (based on actual quartiles):
    < $49k           → 'Low Income'
    $49k – $63,999   → 'Mid Income'
    $64k – $79,999   → 'Upper Mid'
    ≥ $80k           → 'High Income'
    NULL             → 'Unknown'
          ↓
CHECK constraints protect both columns from invalid values
          ↓
v_customer_demographics view created for instant demographic reporting
```

**Bucket boundaries** were set at the actual 25th, 50th and 75th income percentiles of the dataset — ensuring roughly equal customer counts in each income band, which prevents any single band from dominating aggregations.

---

## SQL Implementation Summary

### DDL (Structure Changes)

```sql
-- Primary Keys
ALTER TABLE customers ADD CONSTRAINT pk_customers PRIMARY KEY (customer_id);
ALTER TABLE offers ADD CONSTRAINT pk_offers PRIMARY KEY (offer_id);
ALTER TABLE events ADD COLUMN event_id BIGSERIAL;
ALTER TABLE events ADD CONSTRAINT pk_events PRIMARY KEY (event_id);
ALTER TABLE offer_channels ADD CONSTRAINT pk_offer_channels PRIMARY KEY (offer_id, channel);

-- Foreign Keys
ALTER TABLE events ADD CONSTRAINT fk_events_customer
    FOREIGN KEY (customer_id) REFERENCES customers(customer_id) ON DELETE CASCADE;
ALTER TABLE events ADD CONSTRAINT fk_events_offer
    FOREIGN KEY (offer_id) REFERENCES offers(offer_id) ON DELETE SET NULL;
ALTER TABLE offer_channels ADD CONSTRAINT fk_offerchannels_offer
    FOREIGN KEY (offer_id) REFERENCES offers(offer_id) ON DELETE CASCADE;

-- Time Feature Columns
ALTER TABLE events ADD COLUMN day SMALLINT;
ALTER TABLE events ADD COLUMN hour_of_day SMALLINT;
ALTER TABLE events ADD COLUMN time_hours FLOAT;
ALTER TABLE events ADD COLUMN time_interval INTERVAL;

-- Demographic Bucket Columns
ALTER TABLE customers ADD COLUMN age_group TEXT;
ALTER TABLE customers ADD COLUMN income_band TEXT;
```

### DML (Data Changes)

```sql
-- Clean age outlier
UPDATE customers SET age = NULL WHERE age = 118;

-- Populate time features
UPDATE events SET
    day          = (time / 24),
    hour_of_day  = (time % 24),
    time_hours   = time::FLOAT,
    time_interval = (time || ' hours')::INTERVAL;

-- Populate age groups
UPDATE customers SET age_group = CASE
    WHEN age IS NULL THEN 'Unknown'
    WHEN age BETWEEN 18 AND 29 THEN 'Young Adult'
    WHEN age BETWEEN 30 AND 44 THEN 'Adult'
    WHEN age BETWEEN 45 AND 59 THEN 'Middle Aged'
    WHEN age BETWEEN 60 AND 74 THEN 'Senior'
    WHEN age >= 75 THEN 'Older Senior'
    ELSE 'Unknown' END;

-- Populate income bands
UPDATE customers SET income_band = CASE
    WHEN income IS NULL THEN 'Unknown'
    WHEN income < 49000 THEN 'Low Income'
    WHEN income BETWEEN 49000 AND 63999 THEN 'Mid Income'
    WHEN income BETWEEN 64000 AND 79999 THEN 'Upper Mid'
    WHEN income >= 80000 THEN 'High Income'
    ELSE 'Unknown' END;
```

### Indexes

```sql
CREATE INDEX idx_events_customer_id ON events(customer_id);
CREATE INDEX idx_events_offer_id    ON events(offer_id);
CREATE INDEX idx_events_event       ON events(event);
CREATE INDEX idx_events_time        ON events(time);
CREATE INDEX idx_customers_income   ON customers(income);
CREATE INDEX idx_customers_age      ON customers(age);
CREATE INDEX idx_offers_offer_type  ON offers(offer_type);
```

### Views

```sql
CREATE VIEW v_offer_performance AS ...       -- offer completion rates
CREATE VIEW v_best_offers AS ...             -- ranked performance labels
CREATE VIEW v_informational_impact AS ...    -- post-informational transactions
CREATE VIEW v_informational_summary AS ...   -- aggregated informational impact
CREATE VIEW v_customer_demographics AS ...   -- demographic segment counts
```

---

## Group Role Breakdown

### Role 1 — Relational Enforcement & Indexing
**Responsibility:** Post-migration structural integrity

- Added PRIMARY KEY constraints to all four tables
- Defined FOREIGN KEY relationships with appropriate ON DELETE behaviour
- Identified high-traffic columns and implemented B-Tree indexes
- Ensured the database prevents orphaned records at the constraint level

**Key deliverables:** PKs, FKs, 8 B-Tree indexes

---

### Role 2 — Time Transformation & Data Cleaning
**Responsibility:** Raw data type conversion and quality audit

- Converted raw `time` integer (hours elapsed) into `day`, `hour_of_day`, `time_hours`, and `time_interval` columns
- Identified and resolved the Age 118 placeholder issue affecting 2,175 customers
- Added CHECK constraints to validate the new time-derived columns
- Bridged the gap between raw integers and meaningful analytical timeframes

**Key deliverables:** 4 new time columns, age data fix, CHECK constraints

---

### Role 3 — Summary Views (Analytical Layer)
**Responsibility:** Non-technical reporting interface

- Created `v_offer_performance` counting received vs viewed vs completed per offer
- Created `v_best_offers` with ranked completion rates and plain-English performance labels
- Created `v_informational_impact` and `v_informational_summary` to measure whether informational offers drive transactions
- Enabled any team member to run `SELECT * FROM v_best_offers` for instant insights

**Key deliverables:** 4 SQL views, offer performance analysis

---

### Role 4 — Feature Engineering (Demographic Bucketing)
**Responsibility:** Pre-computed demographic segmentation

- Added `age_group` and `income_band` columns to the customers table
- Set bucket boundaries based on actual data quartiles (not arbitrary values)
- Handled the Age 118 outlier so it labels as 'Unknown' rather than breaking age aggregations
- Created `v_customer_demographics` for instant demographic reporting
- Added CHECK constraints to protect bucket columns from invalid values

**Key deliverables:** 2 new demographic columns, 5 age groups, 4 income bands, 1 demographic view

---

*CoffeeClub Capstone Project — PostgreSQL Relational Database Implementation*
