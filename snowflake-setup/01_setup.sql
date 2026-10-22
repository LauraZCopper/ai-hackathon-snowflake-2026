-- =====================================================================
-- Column Definitions Catalogue: setup (run top to bottom in a Snowsight
-- SQL Workspace on the TRIAL account only). All data is synthetic.
--
-- Mirrors production:
--   model yml description --(dbt persist_docs)--> Snowflake column COMMENT
--   The catalogue READS those comments from INFORMATION_SCHEMA.COLUMNS.
--   Only change requests are stored in a table of our own.
-- =====================================================================

USE ROLE ACCOUNTADMIN;

-- 1. Warehouse, database, schemas --------------------------------------
CREATE WAREHOUSE IF NOT EXISTS HACKATHON_WH
  WAREHOUSE_SIZE = 'XSMALL'
  AUTO_SUSPEND = 60
  AUTO_RESUME = TRUE
  INITIALLY_SUSPENDED = TRUE;

CREATE DATABASE IF NOT EXISTS HACKATHON_DB;
CREATE SCHEMA IF NOT EXISTS HACKATHON_DB.MODEL;        -- stands in for DWH_MODEL
CREATE SCHEMA IF NOT EXISTS HACKATHON_DB.DEFINITIONS;  -- app objects

USE WAREHOUSE HACKATHON_WH;

-- 2. Roles (product users submit, data team reviews) -------------------
CREATE ROLE IF NOT EXISTS PRODUCT_USER;
CREATE ROLE IF NOT EXISTS DATA_TEAM;

SET me = CURRENT_USER();
GRANT ROLE PRODUCT_USER TO USER IDENTIFIER($me);
GRANT ROLE DATA_TEAM    TO USER IDENTIFIER($me);

GRANT USAGE ON WAREHOUSE HACKATHON_WH TO ROLE PRODUCT_USER;
GRANT USAGE ON WAREHOUSE HACKATHON_WH TO ROLE DATA_TEAM;
GRANT USAGE ON DATABASE HACKATHON_DB TO ROLE PRODUCT_USER;
GRANT USAGE ON DATABASE HACKATHON_DB TO ROLE DATA_TEAM;
GRANT USAGE ON SCHEMA HACKATHON_DB.MODEL TO ROLE PRODUCT_USER;
GRANT USAGE ON SCHEMA HACKATHON_DB.MODEL TO ROLE DATA_TEAM;
GRANT USAGE ON SCHEMA HACKATHON_DB.DEFINITIONS TO ROLE PRODUCT_USER;
GRANT USAGE ON SCHEMA HACKATHON_DB.DEFINITIONS TO ROLE DATA_TEAM;

-- 3. "Model" tables with comments, as dbt persist_docs would create ----
--    (relation: true  -> table COMMENT, columns: true -> column COMMENT)
USE SCHEMA HACKATHON_DB.MODEL;

CREATE OR REPLACE TABLE CLIENT_BALANCES (
  CLIENT_ID          VARCHAR       COMMENT 'Unique identifier of the client entity.',
  ASSET_CODE         VARCHAR       COMMENT 'Ticker of the digital asset held, for example BTC.',
  BALANCE_DATE       DATE          COMMENT 'Calendar date of the snapshot, taken at end of day UTC.',
  TOTAL_BALANCE      NUMBER(38,8)  COMMENT 'Total units of the asset held for the client.',
  AVAILABLE_BALANCE  NUMBER(38,8)  COMMENT 'Units that can be withdrawn immediately.',
  STAKED_BALANCE     NUMBER(38,8)  COMMENT 'Units currently delegated to a staking validator.',
  PLEDGED_BALANCE    NUMBER(38,8)  COMMENT 'Units locked as collateral.',
  BALANCE_USD        NUMBER(38,2)  COMMENT 'Value of the balance in USD.',
  ACCOUNT_TYPE       VARCHAR       COMMENT 'Type of account holding the balance: VAULT or TRADING.'
) COMMENT = 'Daily balance snapshot per client, asset and account type.';

CREATE OR REPLACE TABLE CLIENTS (
  CLIENT_ID        VARCHAR        COMMENT 'Unique identifier of the client entity.',
  CLIENT_NAME      VARCHAR        COMMENT 'Registered legal name of the client.',
  JURISDICTION     VARCHAR        COMMENT 'Legal jurisdiction of the contracting entity.',
  ACCOUNT_MANAGER  VARCHAR        COMMENT 'Name of the account manager assigned to the client.',
  ONBOARDED_AT     TIMESTAMP_NTZ  COMMENT 'Timestamp when onboarding was completed.',
  CLIENT_STATUS    VARCHAR        COMMENT 'Status of the client.',
  IS_ACTIVE        BOOLEAN        COMMENT 'Flag showing whether the client is active.',
  CLIENT_TIER      VARCHAR        COMMENT 'Commercial tier assigned to the client.'
) COMMENT = 'One row per client organisation.';

CREATE OR REPLACE TABLE ORDERS (
  ORDER_ID      VARCHAR        COMMENT 'Unique identifier of the order.',
  CLIENT_ID     VARCHAR        COMMENT 'Client that placed the order.',
  ORDER_TYPE    VARCHAR        COMMENT 'Direction of the order: BUY, SELL or CONVERT.',
  ORDER_STATUS  VARCHAR        COMMENT 'Current state of the order.',
  QUANTITY      NUMBER(38,8)   COMMENT 'Amount of the asset in the order.',
  PRICE_USD     NUMBER(38,2)   COMMENT 'Execution price.',
  FEE_USD       NUMBER(38,2)   COMMENT 'Fee charged for the order.',
  CREATED_AT    TIMESTAMP_NTZ  COMMENT 'Timestamp when the order was created.',
  SETTLED_AT    TIMESTAMP_NTZ  COMMENT 'Timestamp when the order settled.'
) COMMENT = 'One row per client order in its latest known state.';

CREATE OR REPLACE TABLE WALLETS (
  WALLET_ID    VARCHAR  COMMENT 'Unique identifier of the wallet.',
  CLIENT_ID    VARCHAR  COMMENT 'Client that owns the wallet.',
  WALLET_TYPE  VARCHAR  COMMENT 'Kind of wallet, for example VAULT or HOT.',
  NETWORK      VARCHAR  COMMENT 'Blockchain network the wallet belongs to.',
  IS_WALLED    BOOLEAN  COMMENT 'Whether the wallet is in the walled garden.'
) COMMENT = 'One row per client wallet.';

-- 4. App objects --------------------------------------------------------
USE SCHEMA HACKATHON_DB.DEFINITIONS;

-- Domain and owner are not part of persist_docs; keep them in a tiny table.
CREATE OR REPLACE TABLE TABLE_METADATA (
  TABLE_NAME  VARCHAR PRIMARY KEY,
  DOMAIN      VARCHAR,
  OWNER       VARCHAR
);

INSERT INTO TABLE_METADATA VALUES
  ('CLIENT_BALANCES', 'Custody',           'Custody Product'),
  ('CLIENTS',         'Client Management', 'Data Team'),
  ('ORDERS',          'Trading',           'Trading Product'),
  ('WALLETS',         'Custody',           'Custody Product');

-- The catalogue. Same name and columns as before, but now a VIEW over the
-- real column comments, so it always shows what is deployed in Snowflake.
CREATE OR REPLACE VIEW COLUMN_DEFINITIONS AS
SELECT
  c.TABLE_NAME,
  c.COLUMN_NAME,
  c.DATA_TYPE,
  COALESCE(c.COMMENT, '') AS CURRENT_DEFINITION,
  COALESCE(m.DOMAIN, 'Unassigned') AS DOMAIN,
  COALESCE(m.OWNER, 'Unassigned')  AS OWNER,
  c.ORDINAL_POSITION
FROM HACKATHON_DB.INFORMATION_SCHEMA.COLUMNS c
LEFT JOIN TABLE_METADATA m ON m.TABLE_NAME = c.TABLE_NAME
WHERE c.TABLE_SCHEMA = 'MODEL';

-- Change requests (the only real table of our own)
CREATE OR REPLACE TABLE DEFINITION_REQUESTS (
  REQUEST_ID           NUMBER AUTOINCREMENT START 1 INCREMENT 1,
  TABLE_NAME           VARCHAR NOT NULL,
  COLUMN_NAME          VARCHAR NOT NULL,
  CURRENT_DEFINITION   VARCHAR,
  PROPOSED_DEFINITION  VARCHAR NOT NULL,
  REASON               VARCHAR,
  REQUESTED_BY         VARCHAR NOT NULL,
  REQUESTED_AT         TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
  STATUS               VARCHAR DEFAULT 'PENDING',   -- PENDING | APPROVED | REJECTED
  REVIEWED_BY          VARCHAR,
  REVIEWED_AT          TIMESTAMP_NTZ,
  REVIEW_COMMENT       VARCHAR,
  PRIMARY KEY (REQUEST_ID)
) COMMENT = 'Change requests for column definitions, pending data team approval';

GRANT SELECT ON VIEW COLUMN_DEFINITIONS TO ROLE PRODUCT_USER;
GRANT SELECT ON VIEW COLUMN_DEFINITIONS TO ROLE DATA_TEAM;
GRANT SELECT ON TABLE TABLE_METADATA TO ROLE PRODUCT_USER;
GRANT SELECT ON TABLE TABLE_METADATA TO ROLE DATA_TEAM;
GRANT SELECT, INSERT ON TABLE DEFINITION_REQUESTS TO ROLE PRODUCT_USER;
GRANT SELECT, INSERT, UPDATE ON TABLE DEFINITION_REQUESTS TO ROLE DATA_TEAM;

-- 5. Sample requests so the review queue is not empty later ------------
INSERT INTO DEFINITION_REQUESTS
  (TABLE_NAME, COLUMN_NAME, CURRENT_DEFINITION, PROPOSED_DEFINITION, REASON, REQUESTED_BY)
VALUES
  ('CLIENTS','IS_ACTIVE','Flag showing whether the client is active.',
   'TRUE if the client has a non-zero balance or has placed an order in the last 90 days.',
   'Current wording is ambiguous; sales and finance use different meanings.','sample.user@example.com'),
  ('CLIENT_BALANCES','BALANCE_USD','Value of the balance in USD.',
   'Value of TOTAL_BALANCE in USD, using the end of day UTC price for BALANCE_DATE.',
   'Unclear which balance and which price are used.','sample.user@example.com');

-- 6. Sanity checks ------------------------------------------------------
SELECT TABLE_NAME, COUNT(*) AS COLUMNS_DEFINED FROM COLUMN_DEFINITIONS GROUP BY 1 ORDER BY 1;
SELECT STATUS, COUNT(*) FROM DEFINITION_REQUESTS GROUP BY 1;

-- 7. What an approved change does once the PR is merged and dbt runs:
--    dbt persist_docs issues the equivalent of this. Simulate it by hand
--    to see the catalogue pick the new definition up.
-- ALTER TABLE HACKATHON_DB.MODEL.CLIENTS ALTER COLUMN IS_ACTIVE
--   COMMENT 'TRUE if the client has a non-zero balance or has placed an order in the last 90 days.';
-- SELECT * FROM HACKATHON_DB.DEFINITIONS.COLUMN_DEFINITIONS WHERE COLUMN_NAME = 'IS_ACTIVE';