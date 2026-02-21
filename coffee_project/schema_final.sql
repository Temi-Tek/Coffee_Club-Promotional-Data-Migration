1. Creating Primary_keys

ALTER TABLE customers
ADD CONSTRAINT pk_customers PRIMARY KEY (customer_id);

ALTER TABLE offers
ADD CONSTRAINT pk_offers PRIMARY KEY (offer_id);

--Events has no natural PK so we generate one
ALTER TABLE events ADD COLUMN event_id BIGSERIAL;
ALTER TABLE events ADD CONSTRAINT pk_events PRIMARY KEY (event_id);

--offer_channels: composite PK on  (offer_id, channel)
ALTER TABLE offer_channels
ADD CONSTRAINT pk_offer_channels PRIMARY KEY (offer_id, channels);

2. Creating Foreign_Keys

ALTER TABLE events
ADD CONSTRAINT fk_events_customer
FOREIGN KEY (customer_id) REFERENCES customers(customer_id)
ON DELETE CASCADE

ALTER TABLE events
ADD CONSTRAINT fk_events_offer
FOREIGN KEY (offer_id) REFERENCES offers(offer_id)
ON DELETE SET NULL;

ALTER TABLE offer_channels
ADD CONSTRAINT fk_offerchannels_offer 
FOREIGN KEY (offer_id) REFERENCES offers(offer_id)
ON DELETE CASCADE

ALTER TABLE events
ADD CONSTRAINT fk_events_offer 
FOREIGN KEY (offer_id) REFERENCES offers(offer_id)
ON DELETE SET NULL

3. --High Traffic_Columns (Tree Indexex)

CREATE INDEX idx_events_customer_id ON events(customer_id);
CREATE INDEX idx_events_offer_id    ON events(offer_id);
CREATE INDEX idx_events_event       ON events(event);
CREATE INDEX idx_events_time        ON events(time);

-- customer segmentation columns (common in analytics queries)
CREATE INDEX idx_customers_income   ON customers(income);
CREATE INDEX idx_customers_age      ON customers(age);
CREATE INDEX idx_customers_became_member ON customers(became_member_on);

-- offer lookups
CREATE INDEX idx_offers_offer_type  ON offers(offer_type);
CREATE INDEX idx_offerchannels_offer_id ON offer_channels(offer_id);


-- SOLUTION TO TASK 2
--Converting raw time integers into days/hours

-- Step 1: Add the two new columns
ALTER TABLE events
ADD COLUMN day          SMALLINT,
ADD COLUMN hour_of_day  SMALLINT;

-- Step 2: Populate them from the raw time column
-- time is hours elapsed since start of the 30-day period
-- day        = which day of the 30-day period (0–29)
-- hour_of_day = what hour within that day   (0–23)
UPDATE events
SET 
    day          = (time / 24),   -- integer division: 0–29
    hour_of_day  = (time % 24);   -- remainder: 0, 6, 12, or 18

-- Step 3: Verify the transformation
SELECT 
    time,
    day,
    hour_of_day
FROM events
ORDER BY time;


--Handling time delta/ (interval mapping)

-- Add a proper interval column
ALTER TABLE events
ADD COLUMN time_interval INTERVAL;

-- Convert raw hours integer → PostgreSQL INTERVAL
UPDATE events
SET time_interval = (time || ' hours')::INTERVAL;

-- Verify: this lets you do real time arithmetic
SELECT 
    time,
    time_interval,
    TIMESTAMP '2024-01-01' + time_interval AS actual_timestamp
FROM events;

--Adding constraints to new columns

-- Ensure day is always 0–29
ALTER TABLE events
ADD CONSTRAINT chk_day 
CHECK (day BETWEEN 0 AND 29);

-- Ensure hour_of_day is always 0–23
ALTER TABLE events
ADD CONSTRAINT chk_hour 
CHECK (hour_of_day BETWEEN 0 AND 23);


2. --"Data Quality Audit": Handle the "Age 118"

UPDATE customers
SET age = NULL
WHERE age = 118;



--SOLUTION TO TASK 3

-- Creating SQL Views
--Offers received vs Offers completed
CREATE VIEW v_offer_performance AS
SELECT
    o.offer_id,
    o.offer_type,
    o.difficulty,
    o.reward,
    o.duration,

    -- Count how many times each offer was received
    COUNT(CASE WHEN e.event = 'offer received'  THEN 1 END) AS total_received,

    -- Count how many times each offer was viewed
    COUNT(CASE WHEN e.event = 'offer viewed'    THEN 1 END) AS total_viewed,

    -- Count how many times each offer was completed
    COUNT(CASE WHEN e.event = 'offer completed' THEN 1 END) AS total_completed,

    -- Completion rate as a percentage
    ROUND(
        COUNT(CASE WHEN e.event = 'offer completed' THEN 1 END)::NUMERIC /
        NULLIF(COUNT(CASE WHEN e.event = 'offer received' THEN 1 END), 0) * 100
    , 2) AS completion_rate_pct

FROM offers o
LEFT JOIN events e ON o.offer_id = e.offer_id
GROUP BY o.offer_id, o.offer_type, o.difficulty, o.reward, o.duration
ORDER BY completion_rate_pct DESC;

--Highest completion rate

CREATE VIEW v_best_offers AS
SELECT
    ROW_NUMBER() OVER (ORDER BY completion_rate_pct DESC) AS rank,
    offer_id,
    offer_type,
    difficulty,
    reward,
    total_received,
    total_completed,
    completion_rate_pct,

    -- Plain English performance label
    CASE
        WHEN completion_rate_pct >= 50 THEN 'High Performer'
        WHEN completion_rate_pct >= 30 THEN 'Average Performer'
        ELSE                                'Low Performer'
    END AS performance_label

FROM v_offer_performance
ORDER BY rank;

--Information offers followed by transactions

CREATE VIEW v_informational_impact AS
SELECT
    e1.customer_id,
    e1.offer_id                             AS informational_offer_id,
    e1.time                                 AS offer_viewed_at,
    e2.time                                 AS transaction_time,
    (e2.time - e1.time)                     AS hours_until_purchase

FROM events e1

-- Find a transaction by the same customer AFTER they viewed the informational offer
JOIN events e2
    ON  e1.customer_id = e2.customer_id
    AND e2.event       = 'transaction'
    AND e2.time        > e1.time        -- transaction must come AFTER the offer view

-- Only look at informational offers
JOIN offers o
    ON  e1.offer_id  = o.offer_id
    AND o.offer_type = 'informational'

WHERE e1.event = 'offer viewed';


-- SOLUTION TO TASK 4

-- 4. 

UPDATE customers
SET age = NULL
WHERE age = 118;

-- Confirm it's clean
SELECT COUNT(*) AS remaining_age_118
FROM customers
WHERE age = 118;

-- Creating income buckets and age groups

-- Add empty columns first
ALTER TABLE customers
ADD COLUMN age_group    TEXT,
ADD COLUMN income_band  TEXT;

-- Populate Age Groups
UPDATE customers
SET age_group = CASE
    WHEN age IS NULL        THEN 'Unknown'
    WHEN age BETWEEN 18 AND 29 THEN 'Young Adult'   
    WHEN age BETWEEN 30 AND 44 THEN 'Adult'          
    WHEN age BETWEEN 45 AND 59 THEN 'Middle Aged'    
    WHEN age BETWEEN 60 AND 74 THEN 'Senior'         
    WHEN age >= 75             THEN 'Older Senior'   
    ELSE 'Unknown'
END;

-- Populate Income Bands
UPDATE customers
SET income_band = CASE
    WHEN income IS NULL          THEN 'Unknown'
    WHEN income < 49000          THEN 'Low Income'        
    WHEN income BETWEEN 49000 AND 63999 THEN 'Mid Income'  
    WHEN income BETWEEN 64000 AND 79999 THEN 'Upper Mid'  
    WHEN income >= 80000         THEN 'High Income'       
    ELSE 'Unknown'
END;

-- Check age group distribution
SELECT 
    age_group,
    COUNT(*)                                        AS total,
    ROUND(COUNT(*) * 100.0 / SUM(COUNT(*)) OVER(), 0) AS pct
FROM customers
GROUP BY age_group
ORDER BY total DESC;

-- Check income band distribution
SELECT 
    income_band,
    COUNT(*)                                        AS total,
    ROUND(COUNT(*) * 100.0 / SUM(COUNT(*)) OVER(), 2) AS pct
FROM customers
GROUP BY income_band
ORDER BY total DESC;



