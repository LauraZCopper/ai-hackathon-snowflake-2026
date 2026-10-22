-- Standalone version of the semantic view the app generates (for testing the
-- syntax in a Workspace). The app rebuilds this from the live column comments.
-- Run after 01_setup.sql and 02_seed_data.sql.
USE ROLE ACCOUNTADMIN;
USE WAREHOUSE HACKATHON_WH;

CREATE OR REPLACE SEMANTIC VIEW HACKATHON_DB.DEFINITIONS.DEFINITIONS_SV
  TABLES (
    clients AS HACKATHON_DB.MODEL.CLIENTS
      PRIMARY KEY (CLIENT_ID)
      WITH SYNONYMS = ('customers', 'organisations')
      COMMENT = 'One row per client organisation.',
    orders AS HACKATHON_DB.MODEL.ORDERS
      PRIMARY KEY (ORDER_ID)
      WITH SYNONYMS = ('trades', 'transactions')
      COMMENT = 'One row per client order in its latest known state.',
    balances AS HACKATHON_DB.MODEL.CLIENT_BALANCES
      WITH SYNONYMS = ('holdings', 'assets under custody', 'AuC')
      COMMENT = 'Daily balance snapshot per client, asset and account type.'
  )
  RELATIONSHIPS (
    orders_to_clients AS orders (CLIENT_ID) REFERENCES clients,
    balances_to_clients AS balances (CLIENT_ID) REFERENCES clients
  )
  FACTS (
    orders.quantity AS QUANTITY
      COMMENT = 'Amount of the asset in the order.',
    orders.price_usd AS PRICE_USD
      COMMENT = 'Execution price.',
    orders.fee_usd AS FEE_USD
      COMMENT = 'Fee charged for the order.',
    balances.total_balance AS TOTAL_BALANCE
      COMMENT = 'Total units of the asset held for the client.',
    balances.available_balance AS AVAILABLE_BALANCE
      COMMENT = 'Units that can be withdrawn immediately.',
    balances.staked_balance AS STAKED_BALANCE
      COMMENT = 'Units currently delegated to a staking validator.',
    balances.pledged_balance AS PLEDGED_BALANCE
      COMMENT = 'Units locked as collateral.',
    balances.balance_usd AS BALANCE_USD
      COMMENT = 'Value of the balance in USD.'
  )
  DIMENSIONS (
    clients.client_id AS CLIENT_ID
      COMMENT = 'Unique identifier of the client entity.',
    clients.client_name AS CLIENT_NAME
      COMMENT = 'Registered legal name of the client.',
    clients.jurisdiction AS JURISDICTION
      COMMENT = 'Legal jurisdiction of the contracting entity.',
    clients.account_manager AS ACCOUNT_MANAGER
      COMMENT = 'Name of the account manager assigned to the client.',
    clients.onboarded_at AS ONBOARDED_AT
      COMMENT = 'Timestamp when onboarding was completed.',
    clients.client_status AS CLIENT_STATUS
      COMMENT = 'Status of the client.',
    clients.is_active AS IS_ACTIVE
      COMMENT = 'Flag showing whether the client is active.',
    clients.client_tier AS CLIENT_TIER
      COMMENT = 'Commercial tier assigned to the client.',
    orders.order_id AS ORDER_ID
      COMMENT = 'Unique identifier of the order.',
    orders.client_id AS CLIENT_ID
      COMMENT = 'Client that placed the order.',
    orders.order_type AS ORDER_TYPE
      COMMENT = 'Direction of the order: BUY, SELL or CONVERT.',
    orders.order_status AS ORDER_STATUS
      COMMENT = 'Current state of the order.',
    orders.created_at AS CREATED_AT
      COMMENT = 'Timestamp when the order was created.',
    orders.settled_at AS SETTLED_AT
      COMMENT = 'Timestamp when the order settled.',
    balances.client_id AS CLIENT_ID
      COMMENT = 'Unique identifier of the client entity.',
    balances.asset_code AS ASSET_CODE
      COMMENT = 'Ticker of the digital asset held, for example BTC.',
    balances.balance_date AS BALANCE_DATE
      COMMENT = 'Calendar date of the snapshot, taken at end of day UTC.',
    balances.account_type AS ACCOUNT_TYPE
      COMMENT = 'Type of account holding the balance: VAULT or TRADING.'
  )
  METRICS (
    clients.client_count AS COUNT(clients.client_id)
      WITH SYNONYMS = ('number of clients')
      COMMENT = 'Number of clients.',
    orders.order_count AS COUNT(orders.order_id)
      WITH SYNONYMS = ('number of orders')
      COMMENT = 'Number of orders.',
    orders.traded_value_usd AS SUM(orders.quantity * orders.price_usd)
      WITH SYNONYMS = ('trading volume', 'volume', 'traded volume')
      COMMENT = 'Traded value in USD: quantity multiplied by execution price. Respect the ORDER_STATUS definition.',
    orders.total_fees_usd AS SUM(orders.fee_usd)
      WITH SYNONYMS = ('fees', 'revenue')
      COMMENT = 'Total fees charged in USD.',
    balances.total_balance_usd AS SUM(balances.balance_usd)
      WITH SYNONYMS = ('AuC', 'assets under custody', 'total holdings')
      COMMENT = 'Value of the balance in USD.'
  )
  COMMENT = 'Generated from the column comments in HACKATHON_DB.MODEL.';

-- Check it exists and test a query
DESCRIBE SEMANTIC VIEW HACKATHON_DB.DEFINITIONS.DEFINITIONS_SV;
SELECT * FROM SEMANTIC_VIEW(HACKATHON_DB.DEFINITIONS.DEFINITIONS_SV METRICS balances.total_balance_usd);