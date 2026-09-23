/*==========================================================
  RDS - Snowflake setup
  Creates: 2 roles, 1 warehouse, RDS_DB database, 5 schemas
==========================================================*/

-----------------------------------------------------------
-- 1. ROLES
-----------------------------------------------------------
USE ROLE SECURITYADMIN;

CREATE ROLE IF NOT EXISTS RDS_ADMIN  COMMENT = 'Builds and owns all RDS objects';
CREATE ROLE IF NOT EXISTS RDS_READER COMMENT = 'Business users - read views only';

GRANT ROLE RDS_READER TO ROLE RDS_ADMIN;     -- admin can also do what reader can
GRANT ROLE RDS_ADMIN  TO ROLE SYSADMIN;      -- keeps SYSADMIN at the top of the hierarchy
GRANT ROLE RDS_ADMIN  TO USER PRAVINSINGH;   -- your login

-----------------------------------------------------------
-- 2. WAREHOUSE
-----------------------------------------------------------
USE ROLE SYSADMIN;

CREATE WAREHOUSE IF NOT EXISTS RDS_WH
  WAREHOUSE_SIZE      = 'XSMALL'
  AUTO_SUSPEND        = 60        -- stop after 60s idle (saves credits)
  AUTO_RESUME         = TRUE
  INITIALLY_SUSPENDED = TRUE
  COMMENT             = 'RDS loads, transformations and queries';

GRANT USAGE ON WAREHOUSE RDS_WH TO ROLE RDS_ADMIN;
GRANT USAGE ON WAREHOUSE RDS_WH TO ROLE RDS_READER;

-----------------------------------------------------------
-- 3. DATABASE
-----------------------------------------------------------
CREATE DATABASE IF NOT EXISTS RDS_DB COMMENT = 'Reference Data System';
GRANT OWNERSHIP ON DATABASE RDS_DB TO ROLE RDS_ADMIN COPY CURRENT GRANTS;

-----------------------------------------------------------
-- 4. SCHEMAS
-----------------------------------------------------------
USE ROLE RDS_ADMIN;
USE DATABASE RDS_DB;

CREATE SCHEMA IF NOT EXISTS OPS    COMMENT = 'Control: inventory, audit log, job log, stage, file formats, procedures';
CREATE SCHEMA IF NOT EXISTS HDS    COMMENT = 'Hospital Delivery System tables (stage + PL)';
CREATE SCHEMA IF NOT EXISTS IHP    COMMENT = 'Insurance Health Plan tables (stage + PL)';
CREATE SCHEMA IF NOT EXISTS HDS_VW COMMENT = 'HDS consumption views for business users';
CREATE SCHEMA IF NOT EXISTS IHP_VW COMMENT = 'IHP consumption views for business users';

-----------------------------------------------------------
-- 5. READER ACCESS (view schemas only)
-----------------------------------------------------------
USE ROLE SECURITYADMIN;

GRANT USAGE ON DATABASE RDS_DB        TO ROLE RDS_READER;
GRANT USAGE ON SCHEMA RDS_DB.HDS_VW   TO ROLE RDS_READER;
GRANT USAGE ON SCHEMA RDS_DB.IHP_VW   TO ROLE RDS_READER;
GRANT SELECT ON FUTURE VIEWS IN SCHEMA RDS_DB.HDS_VW TO ROLE RDS_READER;  -- views created later get access automatically
GRANT SELECT ON FUTURE VIEWS IN SCHEMA RDS_DB.IHP_VW TO ROLE RDS_READER;

-----------------------------------------------------------
-- 6. VERIFY
-----------------------------------------------------------
USE ROLE RDS_ADMIN;
USE WAREHOUSE RDS_WH;
USE DATABASE RDS_DB;

SHOW SCHEMAS IN DATABASE RDS_DB;     -- expect OPS, HDS, IHP, HDS_VW, IHP_VW (+ PUBLIC, INFORMATION_SCHEMA)
SHOW GRANTS TO ROLE RDS_READER;      -- expect usage on RDS_DB, HDS_VW, IHP_VW + warehouse
