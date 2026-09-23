/*==========================================================
  RDS - OPS log tables
  JOB_LOG   : one row per STEP per file per run (VALIDATION, TABLE_LOAD, VIEW_REFRESH)
  AUDIT_LOG : one row per CHECK per file per run (expected vs actual)

  Both are linked by JOB_RUN_ID (one id per SP_LOAD_CATEGORY run).
==========================================================*/
USE ROLE RDS_ADMIN;
USE WAREHOUSE RDS_WH;
USE SCHEMA RDS_DB.OPS;

-----------------------------------------------------------
-- 1. JOB_LOG  - what the job did
-----------------------------------------------------------
CREATE TABLE IF NOT EXISTS JOB_LOG (
    JOB_LOG_ID      NUMBER AUTOINCREMENT START 1 INCREMENT 1,
    JOB_RUN_ID      VARCHAR       NOT NULL,   -- one id per procedure run
    JOB_NM          VARCHAR       NOT NULL,   -- SP_LOAD_CATEGORY
    CATEGORY        VARCHAR(10),              -- HDS | IHP
    FILE_NM         VARCHAR,                  -- HDS_FACILITY_20260914.csv
    STEP_NM         VARCHAR,                  -- VALIDATION | TABLE_LOAD | VIEW_REFRESH
    TARGET_OBJECT   VARCHAR,                  -- table or view that was written
    STATUS          VARCHAR,                  -- RUNNING | SUCCESS | FAILED | SKIPPED | ERROR
    ROW_CNT         NUMBER,                   -- rows loaded (TABLE_LOAD step)
    ERROR_MSG       VARCHAR,
    START_TS        TIMESTAMP_LTZ DEFAULT CURRENT_TIMESTAMP(),
    END_TS          TIMESTAMP_LTZ,
    CREATED_BY      VARCHAR       DEFAULT CURRENT_USER(),
    CONSTRAINT PK_JOB_LOG PRIMARY KEY (JOB_LOG_ID)
) COMMENT = 'Job execution log - one row per step per file';

-----------------------------------------------------------
-- 2. AUDIT_LOG  - what the validation found
-----------------------------------------------------------
CREATE TABLE IF NOT EXISTS AUDIT_LOG (
    AUDIT_ID        NUMBER AUTOINCREMENT START 1 INCREMENT 1,
    JOB_RUN_ID      VARCHAR       NOT NULL,
    CATEGORY        VARCHAR(10),
    FILE_NM         VARCHAR,
    CHECK_NM        VARCHAR,                  -- FILE_NAME_EXISTS | COLUMN_COUNT | ROW_COUNT | ROWS_LOADED
    EXPECTED_VAL    VARCHAR,                  -- from the inventory file
    ACTUAL_VAL      VARCHAR,                  -- measured on the real file
    CHECK_STATUS    VARCHAR,                  -- PASS | FAIL | SKIPPED
    CHECK_MSG       VARCHAR,
    CHECKED_AT      TIMESTAMP_LTZ DEFAULT CURRENT_TIMESTAMP(),
    CONSTRAINT PK_AUDIT_LOG PRIMARY KEY (AUDIT_ID)
) COMMENT = 'Validation audit log - one row per check per file';

-----------------------------------------------------------
-- 3. VERIFY
-----------------------------------------------------------
SHOW TABLES IN SCHEMA RDS_DB.OPS;
