-- =====================================================================
-- Quick reset between demo runs (about 10 seconds).
-- Restores the three demo definitions, clears all requests, re-adds the
-- three sample requests. Then rebuild the semantic view (see bottom).
-- =====================================================================

USE ROLE ACCOUNTADMIN;
USE WAREHOUSE HACKATHON_WH;

-- 1. Restore the original (vague) column comments
ALTER TABLE HACKATHON_DB.MODEL.CLIENT_BALANCES ALTER COLUMN BALANCE_USD
  COMMENT 'Value of the balance in USD.';
ALTER TABLE HACKATHON_DB.MODEL.ORDERS ALTER COLUMN ORDER_STATUS
  COMMENT 'Current state of the order.';
ALTER TABLE HACKATHON_DB.MODEL.CLIENTS ALTER COLUMN IS_ACTIVE
  COMMENT 'Flag showing whether the client is active.';

-- 2. Reset the requests
TRUNCATE TABLE HACKATHON_DB.DEFINITIONS.DEFINITION_REQUESTS;

INSERT INTO HACKATHON_DB.DEFINITIONS.DEFINITION_REQUESTS
  (TABLE_NAME, COLUMN_NAME, CURRENT_DEFINITION, PROPOSED_DEFINITION, REASON, REQUESTED_BY)
VALUES
  ('CLIENT_BALANCES', 'BALANCE_USD', 'Value of the balance in USD.',
   'Value of TOTAL_BALANCE in USD at the end of day UTC price for BALANCE_DATE. Balances are daily snapshots, so for a current figure such as assets under custody (AuC) use only the latest BALANCE_DATE. Summing across dates counts the same balance several times.',
   'Total AuC queries sum every daily snapshot and overstate the figure.', 'sample.user@example.com'),
  ('ORDERS', 'ORDER_STATUS', 'Current state of the order.',
   'Current state of the order: PENDING, SETTLED or CANCELLED. Only SETTLED orders count towards traded volume; exclude PENDING and CANCELLED.',
   'Volume reports include orders that never executed.', 'sample.user@example.com'),
  ('CLIENTS', 'IS_ACTIVE', 'Flag showing whether the client is active.',
   'TRUE if the client has a non-zero balance or has placed an order in the last 90 days.',
   'Current wording is ambiguous; sales and finance use different meanings.', 'sample.user@example.com');

-- 3. Check
SELECT COLUMN_NAME, CURRENT_DEFINITION
FROM HACKATHON_DB.DEFINITIONS.COLUMN_DEFINITIONS
WHERE COLUMN_NAME IN ('BALANCE_USD', 'ORDER_STATUS', 'IS_ACTIVE');
SELECT REQUEST_ID, COLUMN_NAME, STATUS FROM HACKATHON_DB.DEFINITIONS.DEFINITION_REQUESTS ORDER BY 1;

-- 4. Finally rebuild the semantic view so the AI sees the original definitions:
--    either run 03_semantic_view.sql, or click "Build / rebuild semantic view"
--    in the app's "Ask the data" tab, then click "Clear history".