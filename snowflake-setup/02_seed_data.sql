-- =====================================================================
-- Seed synthetic data into the MODEL tables (run after 01_setup.sql).
-- Deterministic, so results are repeatable between demo runs.
-- The semantic view itself is built from the app (Ask the data tab).
-- =====================================================================

USE ROLE ACCOUNTADMIN;
USE WAREHOUSE HACKATHON_WH;
USE SCHEMA HACKATHON_DB.MODEL;

TRUNCATE TABLE CLIENTS;
TRUNCATE TABLE CLIENT_BALANCES;
TRUNCATE TABLE ORDERS;
TRUNCATE TABLE WALLETS;

-- 25 clients. IS_ACTIVE is deliberately not the same as CLIENT_STATUS,
-- so "active" is genuinely ambiguous.
INSERT INTO CLIENTS
WITH n AS (SELECT ROW_NUMBER() OVER (ORDER BY SEQ4()) AS i FROM TABLE(GENERATOR(ROWCOUNT => 25)))
SELECT
  'C' || LPAD(i::VARCHAR, 3, '0'),
  'Client ' || i,
  GET(ARRAY_CONSTRUCT('UK','Germany','Singapore','UAE','Switzerland'), MOD(i,5))::VARCHAR,
  GET(ARRAY_CONSTRUCT('Alice Moore','Ben Carter','Chloe Evans','Dev Patel'), MOD(i,4))::VARCHAR,
  DATEADD(day, -(100 + i*20), CURRENT_TIMESTAMP())::TIMESTAMP_NTZ,
  CASE WHEN MOD(i,10) = 0 THEN 'CLOSED' WHEN MOD(i,5) = 0 THEN 'DORMANT' ELSE 'ACTIVE' END,
  MOD(i,4) <> 0,
  GET(ARRAY_CONSTRUCT('Tier 1','Tier 2','Tier 3'), MOD(i,3))::VARCHAR
FROM n;

-- Daily balance snapshots: 25 clients x 3 assets x 5 days.
-- Summing BALANCE_USD across all dates counts every balance five times.
INSERT INTO CLIENT_BALANCES
WITH c AS (SELECT ROW_NUMBER() OVER (ORDER BY SEQ4()) AS i FROM TABLE(GENERATOR(ROWCOUNT => 25))),
     a AS (SELECT * FROM VALUES ('BTC', 60000, 1), ('ETH', 3000, 2), ('SOL', 150, 3) AS t(asset, price, k)),
     d AS (SELECT ROW_NUMBER() OVER (ORDER BY SEQ4()) - 1 AS day_offset FROM TABLE(GENERATOR(ROWCOUNT => 5))),
     base AS (
       SELECT c.i, a.asset, a.price, d.day_offset,
              ROUND((5 + MOD(c.i*7 + a.k*13, 40)) * (1 - d.day_offset*0.01), 8) AS total
       FROM c CROSS JOIN a CROSS JOIN d
     )
SELECT
  'C' || LPAD(i::VARCHAR, 3, '0'),
  asset,
  CURRENT_DATE() - day_offset,
  total,
  ROUND(total * 0.7, 8),
  ROUND(total * 0.2, 8),
  ROUND(total * 0.1, 8),
  ROUND(total * price, 2),
  'VAULT'
FROM base;

-- 300 orders. About 60% settled, 15% pending, 25% cancelled.
-- Summing every order counts pending and cancelled ones as traded volume.
INSERT INTO ORDERS
WITH o AS (SELECT ROW_NUMBER() OVER (ORDER BY SEQ4()) AS i FROM TABLE(GENERATOR(ROWCOUNT => 300)))
SELECT
  'O' || LPAD(i::VARCHAR, 5, '0'),
  'C' || LPAD((MOD(i,25) + 1)::VARCHAR, 3, '0'),
  GET(ARRAY_CONSTRUCT('BUY','SELL','CONVERT'), MOD(i,3))::VARCHAR,
  CASE WHEN MOD(i,20) < 12 THEN 'SETTLED' WHEN MOD(i,20) < 15 THEN 'PENDING' ELSE 'CANCELLED' END,
  ROUND(0.1 + MOD(i,50) * 0.1, 8),
  ROUND(100 + MOD(i*37, 600) * 100, 2),
  ROUND((0.1 + MOD(i,50) * 0.1) * (100 + MOD(i*37, 600) * 100) * 0.001, 2),
  DATEADD(hour, -i*5, CURRENT_TIMESTAMP())::TIMESTAMP_NTZ,
  CASE WHEN MOD(i,20) < 12 THEN DATEADD(minute, 30, DATEADD(hour, -i*5, CURRENT_TIMESTAMP()))::TIMESTAMP_NTZ END
FROM o;

INSERT INTO WALLETS
WITH w AS (SELECT ROW_NUMBER() OVER (ORDER BY SEQ4()) AS i FROM TABLE(GENERATOR(ROWCOUNT => 50)))
SELECT
  'W' || LPAD(i::VARCHAR, 4, '0'),
  'C' || LPAD((MOD(i,25) + 1)::VARCHAR, 3, '0'),
  GET(ARRAY_CONSTRUCT('VAULT','HOT'), MOD(i,2))::VARCHAR,
  GET(ARRAY_CONSTRUCT('Bitcoin','Ethereum','Solana'), MOD(i,3))::VARCHAR,
  MOD(i,4) = 0
FROM w;

-- Make the two sample requests carry definitions that actually steer the AI.
-- (Run this once, in the DEFINITIONS schema.)
UPDATE HACKATHON_DB.DEFINITIONS.DEFINITION_REQUESTS
SET PROPOSED_DEFINITION = 'Value of TOTAL_BALANCE in USD at the end of day UTC price for BALANCE_DATE. Balances are daily snapshots, so for a current figure such as assets under custody (AuC) use only the latest BALANCE_DATE. Summing across dates counts the same balance several times.',
    REASON = 'Total AuC queries sum every daily snapshot and overstate the figure.'
WHERE COLUMN_NAME = 'BALANCE_USD' AND STATUS = 'PENDING' AND REQUESTED_BY = 'sample.user@example.com';

INSERT INTO HACKATHON_DB.DEFINITIONS.DEFINITION_REQUESTS
  (TABLE_NAME, COLUMN_NAME, CURRENT_DEFINITION, PROPOSED_DEFINITION, REASON, REQUESTED_BY)
VALUES
  ('ORDERS', 'ORDER_STATUS', 'Current state of the order.',
   'Current state of the order: PENDING, SETTLED or CANCELLED. Only SETTLED orders count towards traded volume; exclude PENDING and CANCELLED.',
   'Volume reports include orders that never executed.', 'sample.user@example.com');

-- Sanity checks and the "right answers" to compare Cortex Analyst against
SELECT 'clients' AS t, COUNT(*) AS n FROM CLIENTS
UNION ALL SELECT 'balances', COUNT(*) FROM CLIENT_BALANCES
UNION ALL SELECT 'orders', COUNT(*) FROM ORDERS
UNION ALL SELECT 'wallets', COUNT(*) FROM WALLETS;

-- AuC, wrong way (all snapshots) vs right way (latest snapshot only)
SELECT SUM(BALANCE_USD) AS auc_all_dates FROM CLIENT_BALANCES;
SELECT SUM(BALANCE_USD) AS auc_latest_date
FROM CLIENT_BALANCES WHERE BALANCE_DATE = (SELECT MAX(BALANCE_DATE) FROM CLIENT_BALANCES);

-- Traded volume, wrong way (all orders) vs right way (settled only)
SELECT SUM(QUANTITY * PRICE_USD) AS volume_all_orders FROM ORDERS;
SELECT SUM(QUANTITY * PRICE_USD) AS volume_settled FROM ORDERS WHERE ORDER_STATUS = 'SETTLED';