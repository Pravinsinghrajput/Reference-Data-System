/*========================================================
    RDS - Snowflake setup
    Create - 2 roles, 1 database, 1 warehouse, 5 schemas
===========================================================*/

------------------------------------------------------------
--1. Role
------------------------------------------------------------

USE ROLE SECURITYADMIN;

CREATE ROLE IF NOT EXISTS RDS_ADMIN COMMENT = 'Builds and owns all RDS objects';
CREATE ROLE IF NOT EXISTS RDS_READER COMMENT = 'Business users - Read views only';

GRANT ROLE RDS_READER TO ROLE RDS_ADMIN ;
GRANT ROLE RDS_ADMIN TO ROLE SYSADMIN ;
GRANT ROLE RDS_ADMIN TO USER PRAVINSINGH ;

------------------------------------------------
--2. WAREHOUSE
------------------------------------------------
USE ROLE SYSADMIN ;

CREATE WAREHOUSE IF NOT EXISTS RDS_WH
    WAREHOUSE_SIZE = 'XSMALL'
    AUTO_SUSPEND = 60
    AUTO_RESUME = TRUE
    INITIALLY_SUSPENDED = TRUE
    COMMENT = 'RDS loads, transformation and queries';

GRANT USAGE ON WAREHOUSE RDS_WH TO ROLE RDS_ADMIN;
GRANT USAGE ON WAREHOUSE RDS_WH TO ROLE RDS_READER;

--------------------------------------------------------
--3. DATABASE
--------------------------------------------------------
CREATE DATABASE IF NOT EXISTS RDS_DB COMMENT = 'Reference Data System';
GRANT OWNERSHIP ON DATABASE RDS_DB TO ROLE RDS_ADMIN COPY CURRENT GRANTS;

--------------------------------------------------------
--4. SCHEMA
--------------------------------------------------------
USE ROLE RDS_ADMIN;
USE DATABASE RDS_DB;

CREATE SCHEMA IF NOT EXISTS OPS    COMMENT = 'Control: inventory, audit log, job log, stage, file formats, procedures';
CREATE SCHEMA IF NOT EXISTS HDS    COMMENT = 'Hospital Delivery System tables (stage + PL)';
CREATE SCHEMA IF NOT EXISTS IHP    COMMENT = 'Insurance Health Plan tables (stage + PL)';
CREATE SCHEMA IF NOT EXISTS HDS_VW COMMENT = 'HDS consumption views for business users';
CREATE SCHEMA IF NOT EXISTS IHP_VW COMMENT = 'IHP consumption views for business users';

--------------------------------------------------
--5. READER ACCESS (View Schema only)
--------------------------------------------------
USE ROLE SECURITYADMIN;

GRANT USAGE ON DATABASE RDS_DB TO ROLE RDS_READER;
GRANT USAGE ON SCHEMA RDS_DB.HDS_VW TO ROLE RDS_READER;
GRANT USAGE ON SCHEMA RDS_DB.IHP_VW TO ROLE RDS_READER;
GRANT SELECT ON FUTURE VIEWS IN SCHEMA RDS_DB.HDS_VW TO ROLE RDS_READER;
GRANT SELECT ON FUTURE VIEWS IN SCHEMA RDS_DB.IHP_VW TO ROLE RDS_READER;

---------------------------------------------------
--6. Verify
------------------------------------------------------
USE ROLE RDS_ADMIN;
USE WAREHOUSE RDS_WH;
USE DATABASE RDS_DB;

SHOW SCHEMAS IN DATABASE RDS_DB;
SHOW GRANTS TO ROLE RDS_READER;
SHOW GRANTS TO ROLE RDS_ADMIN;

USE ROLE ACCOUNTADMIN;

CREATE STORAGE INTEGRATION IF NOT EXISTS S3_INT_RDS
    TYPE = EXTERNAL_STAGE
    STORAGE_PROVIDER = 'S3'
    ENABLED = TRUE
    STORAGE_AWS_ROLE_ARN      = 'arn:aws:iam::<AWS_ACCOUNT_ID>:role/snowflake-rds-role'
    STORAGE_ALLOWED_LOCATIONS = ('s3://<BUCKET_NAME>/')
    COMMENT                   = 'RDS healthcare bucket';

DESC INTEGRATION S3_INT_RDS ;    

-----------------------------------------------------------
-- 2. FILE FORMATS
-----------------------------------------------------------
USE ROLE RDS_ADMIN;
USE WAREHOUSE RDS_WH;
USE SCHEMA RDS_DB.OPS;

-- Reads data rows (skips header) - used for row count and loading
CREATE FILE FORMAT IF NOT EXISTS FF_CSV_HEADER
  TYPE                         = CSV
  FIELD_DELIMITER              = ','
  SKIP_HEADER                  = 1
  FIELD_OPTIONALLY_ENCLOSED_BY = '"'
  TRIM_SPACE                   = TRUE
  EMPTY_FIELD_AS_NULL          = TRUE
  SKIP_BLANK_LINES             = TRUE
  COMMENT                      = 'CSV with header row';

-- Reads each whole line as ONE column - used to count header columns
CREATE FILE FORMAT IF NOT EXISTS FF_CSV_LINE
  TYPE                         = CSV
  FIELD_DELIMITER              = NONE
  SKIP_HEADER                  = 0
  FIELD_OPTIONALLY_ENCLOSED_BY = NONE
  ESCAPE_UNENCLOSED_FIELD      = NONE
  SKIP_BLANK_LINES             = TRUE
  COMMENT                      = 'Whole line as one value';

-----------------------------------------------------------
-- 3. EXTERNAL STAGE (Snowflake's pointer to the bucket)
-----------------------------------------------------------
USE ROLE RDS_ADMIN;
USE WAREHOUSE RDS_WH;
USE SCHEMA RDS_DB.OPS;

CREATE OR REPLACE STAGE EXT_STAGE_RDS
  URL         = 's3://<BUCKET_NAME>/'
  CREDENTIALS = (AWS_KEY_ID = '<ACCESS_KEY_ID>' AWS_SECRET_KEY = '<SECRET_ACCESS_KEY>')
  DIRECTORY   = (ENABLE = TRUE)
  FILE_FORMAT = (FORMAT_NAME = 'RDS_DB.OPS.FF_CSV_HEADER')
  COMMENT     = 'RDS healthcare bucket - temporary key auth, switch to S3_INT_RDS later';


  LIST @EXT_STAGE_RDS;

ALTER STAGE EXT_STAGE_RDS REFRESH;
SELECT RELATIVE_PATH, SIZE, LAST_MODIFIED FROM DIRECTORY(@EXT_STAGE_RDS);

-- Inventory files
SELECT METADATA$FILENAME AS INVENTORY_FILE,
       $1 AS FILE_NM, $2 AS COL_CNT, $3 AS ROW_CNT, $4 AS FILE_DATE, $5 AS OWNER
FROM @EXT_STAGE_RDS (FILE_FORMAT => 'RDS_DB.OPS.FF_CSV_HEADER', PATTERN => '.*RDS_Inventory_.*[.]csv');

-- Actual row counts -> expect 20 (HDS) and 18 (IHP)
SELECT METADATA$FILENAME AS FILE_PATH, COUNT(*) AS ACTUAL_ROW_CNT
FROM @EXT_STAGE_RDS (FILE_FORMAT => 'RDS_DB.OPS.FF_CSV_HEADER', PATTERN => '.*(HDS_FACILITY|IHP_HEALTH_PLAN)_[0-9]{8}[.]csv')
GROUP BY 1;

-- Actual column counts -> expect 12 (HDS) and 13 (IHP)
SELECT METADATA$FILENAME AS FILE_PATH, ARRAY_SIZE(SPLIT($1, ',')) AS ACTUAL_COL_CNT
FROM @EXT_STAGE_RDS (FILE_FORMAT => 'RDS_DB.OPS.FF_CSV_LINE', PATTERN => '.*(HDS_FACILITY|IHP_HEALTH_PLAN)_[0-9]{8}[.]csv')
WHERE METADATA$FILE_ROW_NUMBER = 1;


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


/*==========================================================
  RDS - OPS monitoring views (support / troubleshooting)
==========================================================*/
USE ROLE RDS_ADMIN;
USE WAREHOUSE RDS_WH;
USE SCHEMA RDS_DB.OPS;

-- One row per file per run: validation, load and view status side by side
CREATE OR REPLACE VIEW VW_LOAD_SUMMARY AS
SELECT
    JOB_RUN_ID,
    CATEGORY,
    FILE_NM,
    MAX(IFF(STEP_NM = 'VALIDATION',   STATUS,        NULL)) AS VALIDATION_STATUS,
    MAX(IFF(STEP_NM = 'TABLE_LOAD',   STATUS,        NULL)) AS LOAD_STATUS,
    MAX(IFF(STEP_NM = 'TABLE_LOAD',   ROW_CNT,       NULL)) AS ROWS_LOADED,
    MAX(IFF(STEP_NM = 'TABLE_LOAD',   TARGET_OBJECT, NULL)) AS TARGET_TABLE,
    MAX(IFF(STEP_NM = 'VIEW_REFRESH', STATUS,        NULL)) AS VIEW_STATUS,
    MAX(IFF(STEP_NM = 'VIEW_REFRESH', TARGET_OBJECT, NULL)) AS TARGET_VIEW,
    MAX(ERROR_MSG)                                          AS ERROR_MSG,
    MIN(START_TS)                                           AS START_TS,
    MAX(END_TS)                                             AS END_TS,
    DATEDIFF('second', MIN(START_TS), MAX(END_TS))          AS DURATION_SEC
FROM JOB_LOG
GROUP BY JOB_RUN_ID, CATEGORY, FILE_NM;

-- Only the checks that failed
CREATE OR REPLACE VIEW VW_FAILED_CHECKS AS
SELECT JOB_RUN_ID, CATEGORY, FILE_NM, CHECK_NM, EXPECTED_VAL, ACTUAL_VAL, CHECK_MSG, CHECKED_AT
FROM AUDIT_LOG
WHERE CHECK_STATUS = 'FAIL';

-- Which dated table each consumption view currently points at
CREATE OR REPLACE VIEW VW_CURRENT_VIEW_SOURCE AS
SELECT TABLE_SCHEMA AS VIEW_SCHEMA,
       TABLE_NAME   AS VIEW_NAME,
       COMMENT      AS POINTS_TO,
       CREATED      AS LAST_REFRESHED
FROM RDS_DB.INFORMATION_SCHEMA.VIEWS
WHERE TABLE_SCHEMA IN ('HDS_VW', 'IHP_VW');

SHOW VIEWS IN SCHEMA RDS_DB.OPS;

/*==========================================================
  RDS - SP_LOAD_CATEGORY
  Call:  CALL RDS_DB.OPS.SP_LOAD_CATEGORY('HDS');
         CALL RDS_DB.OPS.SP_LOAD_CATEGORY('IHP');

  For every file listed in @EXT_STAGE_RDS/<CAT>/RDS_Inventory_<CAT>.csv:
    1. VALIDATION   FILE_NAME_EXISTS -> COLUMN_COUNT -> ROW_COUNT   (AUDIT_LOG)
    2. TABLE_LOAD   creates RDS_DB.<CAT>.<FILE_NAME_WITHOUT_.csv> and loads it
                    e.g. HDS_FACILITY_20260914.csv -> RDS_DB.HDS.HDS_FACILITY_20260914
    3. VIEW_REFRESH creates RDS_DB.<CAT>_VW.<NAME_WITHOUT_DATE> pointing at the
                    table with the LATEST date, e.g. RDS_DB.HDS_VW.HDS_FACILITY
    Every step writes to OPS.JOB_LOG; every check writes to OPS.AUDIT_LOG.
    A file that fails validation is skipped; the other files still load.
==========================================================*/

-----------------------------------------------------------
-- PREREQUISITE (run once): file format used to read the header
--   PARSE_HEADER = TRUE lets Snowflake build the table from the header row
--   and match columns by name during COPY. It cannot be combined with SKIP_HEADER.
-----------------------------------------------------------
USE ROLE RDS_ADMIN;
USE WAREHOUSE RDS_WH;
USE SCHEMA RDS_DB.OPS;

CREATE OR REPLACE FILE FORMAT FF_CSV_INFER
  TYPE                         = CSV
  PARSE_HEADER                 = TRUE
  FIELD_DELIMITER              = ','
  FIELD_OPTIONALLY_ENCLOSED_BY = '"'
  TRIM_SPACE                   = TRUE
  EMPTY_FIELD_AS_NULL          = TRUE
  SKIP_BLANK_LINES             = TRUE
  COMMENT                      = 'CSV header row used for INFER_SCHEMA and MATCH_BY_COLUMN_NAME';

-----------------------------------------------------------
-- PROCEDURE
-----------------------------------------------------------
CREATE OR REPLACE PROCEDURE RDS_DB.OPS.SP_LOAD_CATEGORY(P_CATEGORY VARCHAR)
RETURNS VARIANT
LANGUAGE SQL
COMMENT = 'Validates inventory files for a category, loads each file into a dated table and refreshes the view'
EXECUTE AS CALLER
AS
$$
DECLARE
    c_stage       VARCHAR DEFAULT '@RDS_DB.OPS.EXT_STAGE_RDS';
    v_job_run_id  VARCHAR;
    v_cat         VARCHAR;
    v_folder      VARCHAR;
    v_inv_path    VARCHAR;
    v_file_nm     VARCHAR;
    v_exp_cols    NUMBER;
    v_exp_rows    NUMBER;
    v_act_cols    NUMBER;
    v_act_rows    NUMBER;
    v_exists      NUMBER;
    v_failed      NUMBER;
    v_tbl_nm      VARCHAR;
    v_base_nm     VARCHAR;
    v_latest_tbl  VARCHAR;
    v_rows_loaded NUMBER;
    v_ok_cnt      NUMBER DEFAULT 0;
    v_fail_cnt    NUMBER DEFAULT 0;
    v_sql         VARCHAR;
    -- TMP_INVENTORY is created below, at run time
    c_inv CURSOR FOR SELECT FILE_NM, COL_CNT, ROW_CNT FROM RDS_DB.OPS.TMP_INVENTORY ORDER BY FILE_NM;
BEGIN
    v_cat        := UPPER(P_CATEGORY);
    v_job_run_id := UUID_STRING();
    v_folder     := v_cat || '/';
    v_inv_path   := c_stage || '/' || v_folder || 'RDS_Inventory_' || v_cat || '.csv';

    -- directory table must be current for the FILE_NAME_EXISTS check
    ALTER STAGE RDS_DB.OPS.EXT_STAGE_RDS REFRESH;

    -- read the inventory file from S3 into a temp table
    v_sql := 'CREATE OR REPLACE TEMPORARY TABLE RDS_DB.OPS.TMP_INVENTORY AS
              SELECT TRIM($1)::VARCHAR     AS FILE_NM,
                     TRY_TO_NUMBER(TRIM($2)) AS COL_CNT,
                     TRY_TO_NUMBER(TRIM($3)) AS ROW_CNT
              FROM ' || v_inv_path || ' (FILE_FORMAT => ''RDS_DB.OPS.FF_CSV_HEADER'')
              WHERE NULLIF(TRIM($1), '''') IS NOT NULL';
    EXECUTE IMMEDIATE :v_sql;

    FOR rec IN c_inv DO
        v_file_nm     := rec.FILE_NM;
        v_exp_cols    := rec.COL_CNT;
        v_exp_rows    := rec.ROW_CNT;
        v_failed      := 0;
        v_act_cols    := 0;
        v_act_rows    := 0;
        v_rows_loaded := 0;
        v_tbl_nm      := SPLIT_PART(v_file_nm, '.', 1);                 -- HDS_FACILITY_20260914
        v_base_nm     := REGEXP_REPLACE(v_tbl_nm, '_[0-9]{8}$', '');    -- HDS_FACILITY

        BEGIN
            -------------------------------------------------------------
            -- STEP 1: VALIDATION
            -------------------------------------------------------------
            INSERT INTO RDS_DB.OPS.JOB_LOG (JOB_RUN_ID, JOB_NM, CATEGORY, FILE_NM, STEP_NM, TARGET_OBJECT, STATUS)
            SELECT :v_job_run_id, 'SP_LOAD_CATEGORY', :v_cat, :v_file_nm, 'VALIDATION',
                   'RDS_DB.' || :v_cat || '.' || :v_tbl_nm, 'RUNNING';

            -- check 1: the file named in the inventory really exists in S3
            SELECT COUNT(*) INTO :v_exists
              FROM DIRECTORY(@RDS_DB.OPS.EXT_STAGE_RDS)
             WHERE RELATIVE_PATH = :v_folder || :v_file_nm;

            INSERT INTO RDS_DB.OPS.AUDIT_LOG
                (JOB_RUN_ID, CATEGORY, FILE_NM, CHECK_NM, EXPECTED_VAL, ACTUAL_VAL, CHECK_STATUS, CHECK_MSG)
            SELECT :v_job_run_id, :v_cat, :v_file_nm, 'FILE_NAME_EXISTS', 'Y',
                   IFF(:v_exists > 0, 'Y', 'N'),
                   IFF(:v_exists > 0, 'PASS', 'FAIL'),
                   'Looked for ' || :v_folder || :v_file_nm || ' on the stage';

            IF (v_exists = 0) THEN
                v_failed := v_failed + 1;
                INSERT INTO RDS_DB.OPS.AUDIT_LOG
                    (JOB_RUN_ID, CATEGORY, FILE_NM, CHECK_NM, CHECK_STATUS, CHECK_MSG)
                SELECT :v_job_run_id, :v_cat, :v_file_nm, t.CHECK_NM, 'SKIPPED', 'File not found in S3'
                  FROM (SELECT $1 AS CHECK_NM FROM VALUES ('COLUMN_COUNT'), ('ROW_COUNT')) t;
            ELSE
                -- check 2: column count taken from the header line
                v_sql := 'SELECT ARRAY_SIZE(SPLIT($1, '','')) AS CNT FROM ' || c_stage || '/' || v_folder || v_file_nm ||
                         ' (FILE_FORMAT => ''RDS_DB.OPS.FF_CSV_LINE'') WHERE METADATA$FILE_ROW_NUMBER = 1';
                EXECUTE IMMEDIATE :v_sql;
                SELECT COALESCE(MAX(CNT), 0) INTO :v_act_cols FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()));

                -- check 3: data row count (header skipped by FF_CSV_HEADER)
                v_sql := 'SELECT COUNT(*) AS CNT FROM ' || c_stage || '/' || v_folder || v_file_nm ||
                         ' (FILE_FORMAT => ''RDS_DB.OPS.FF_CSV_HEADER'')';
                EXECUTE IMMEDIATE :v_sql;
                SELECT COALESCE(MAX(CNT), 0) INTO :v_act_rows FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()));

                INSERT INTO RDS_DB.OPS.AUDIT_LOG
                    (JOB_RUN_ID, CATEGORY, FILE_NM, CHECK_NM, EXPECTED_VAL, ACTUAL_VAL, CHECK_STATUS, CHECK_MSG)
                SELECT :v_job_run_id, :v_cat, :v_file_nm, t.CHECK_NM,
                       t.EXPECTED_VAL::VARCHAR, t.ACTUAL_VAL::VARCHAR,
                       IFF(EQUAL_NULL(t.EXPECTED_VAL, t.ACTUAL_VAL), 'PASS', 'FAIL'), t.CHECK_MSG
                  FROM (
                        SELECT 'COLUMN_COUNT' AS CHECK_NM, :v_exp_cols AS EXPECTED_VAL, :v_act_cols AS ACTUAL_VAL,
                               'Header columns vs inventory COL_CNT' AS CHECK_MSG
                        UNION ALL
                        SELECT 'ROW_COUNT', :v_exp_rows, :v_act_rows,
                               'Data rows in file vs inventory ROW_CNT'
                       ) t;

                IF (NOT EQUAL_NULL(v_act_cols, v_exp_cols)) THEN v_failed := v_failed + 1; END IF;
                IF (NOT EQUAL_NULL(v_act_rows, v_exp_rows)) THEN v_failed := v_failed + 1; END IF;
            END IF;

            UPDATE RDS_DB.OPS.JOB_LOG
               SET STATUS    = IFF(:v_failed = 0, 'SUCCESS', 'FAILED'),
                   ERROR_MSG = IFF(:v_failed = 0, NULL, :v_failed || ' check(s) failed - see OPS.AUDIT_LOG'),
                   END_TS    = CURRENT_TIMESTAMP()
             WHERE JOB_RUN_ID = :v_job_run_id AND FILE_NM = :v_file_nm AND STEP_NM = 'VALIDATION';

            IF (v_failed > 0) THEN
                -- validation failed: do not load, record the skip
                v_fail_cnt := v_fail_cnt + 1;
                INSERT INTO RDS_DB.OPS.JOB_LOG
                    (JOB_RUN_ID, JOB_NM, CATEGORY, FILE_NM, STEP_NM, STATUS, ERROR_MSG, END_TS)
                SELECT :v_job_run_id, 'SP_LOAD_CATEGORY', :v_cat, :v_file_nm, 'TABLE_LOAD', 'SKIPPED',
                       'Validation failed', CURRENT_TIMESTAMP();
            ELSE
                ---------------------------------------------------------
                -- STEP 2: TABLE_LOAD  (table named after the file)
                ---------------------------------------------------------
                INSERT INTO RDS_DB.OPS.JOB_LOG (JOB_RUN_ID, JOB_NM, CATEGORY, FILE_NM, STEP_NM, TARGET_OBJECT, STATUS)
                SELECT :v_job_run_id, 'SP_LOAD_CATEGORY', :v_cat, :v_file_nm, 'TABLE_LOAD',
                       'RDS_DB.' || :v_cat || '.' || :v_tbl_nm, 'RUNNING';

                -- build the table straight from the file header (column names + types)
                v_sql := 'CREATE OR REPLACE TABLE RDS_DB.' || v_cat || '.' || v_tbl_nm || '
                          USING TEMPLATE (
                              SELECT ARRAY_AGG(OBJECT_CONSTRUCT(*)) WITHIN GROUP (ORDER BY ORDER_ID)
                              FROM TABLE(INFER_SCHEMA(
                                   LOCATION    => ''' || c_stage || '/' || v_folder || v_file_nm || ''',
                                   FILE_FORMAT => ''RDS_DB.OPS.FF_CSV_INFER'')))';
                EXECUTE IMMEDIATE :v_sql;

                -- Positional load: the table was just built from THIS file's own header
                -- and COLUMN_COUNT was validated above, so column 1..n line up 1:1.
                -- (No MATCH_BY_COLUMN_NAME, so this works on every Snowflake version.)
                v_sql := 'COPY INTO RDS_DB.' || v_cat || '.' || v_tbl_nm ||
                         ' FROM ' || c_stage || '/' || v_folder ||
                         ' FILES = (''' || v_file_nm || ''')' ||
                         ' FILE_FORMAT = (FORMAT_NAME = ''RDS_DB.OPS.FF_CSV_HEADER'')' ||
                         ' ON_ERROR = ABORT_STATEMENT' ||
                         ' FORCE = TRUE';
                EXECUTE IMMEDIATE :v_sql;
                SELECT COALESCE(SUM("rows_loaded"), 0) INTO :v_rows_loaded
                  FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()));

                -- Lineage columns are added AFTER the load, so the file column count
                -- and the table column count still match during COPY
                EXECUTE IMMEDIATE 'ALTER TABLE RDS_DB.' || v_cat || '.' || v_tbl_nm || ' ADD COLUMN SRC_FILE_NM VARCHAR';
                EXECUTE IMMEDIATE 'ALTER TABLE RDS_DB.' || v_cat || '.' || v_tbl_nm || ' ADD COLUMN LOAD_TS TIMESTAMP_LTZ';

                v_sql := 'UPDATE RDS_DB.' || v_cat || '.' || v_tbl_nm ||
                         ' SET SRC_FILE_NM = ''' || v_folder || v_file_nm || ''',' ||
                         '     LOAD_TS     = CURRENT_TIMESTAMP()';
                EXECUTE IMMEDIATE :v_sql;

                -- check 4: rows actually loaded must match the inventory
                INSERT INTO RDS_DB.OPS.AUDIT_LOG
                    (JOB_RUN_ID, CATEGORY, FILE_NM, CHECK_NM, EXPECTED_VAL, ACTUAL_VAL, CHECK_STATUS, CHECK_MSG)
                SELECT :v_job_run_id, :v_cat, :v_file_nm, 'ROWS_LOADED',
                       :v_exp_rows::VARCHAR, :v_rows_loaded::VARCHAR,
                       IFF(:v_rows_loaded = :v_exp_rows, 'PASS', 'FAIL'),
                       'Rows loaded into RDS_DB.' || :v_cat || '.' || :v_tbl_nm;

                UPDATE RDS_DB.OPS.JOB_LOG
                   SET STATUS    = IFF(:v_rows_loaded = :v_exp_rows, 'SUCCESS', 'FAILED'),
                       ROW_CNT   = :v_rows_loaded,
                       ERROR_MSG = IFF(:v_rows_loaded = :v_exp_rows, NULL, 'Loaded row count does not match inventory'),
                       END_TS    = CURRENT_TIMESTAMP()
                 WHERE JOB_RUN_ID = :v_job_run_id AND FILE_NM = :v_file_nm AND STEP_NM = 'TABLE_LOAD';

                ---------------------------------------------------------
                -- STEP 3: VIEW_REFRESH  (view without date -> latest dated table)
                ---------------------------------------------------------
                INSERT INTO RDS_DB.OPS.JOB_LOG (JOB_RUN_ID, JOB_NM, CATEGORY, FILE_NM, STEP_NM, TARGET_OBJECT, STATUS)
                SELECT :v_job_run_id, 'SP_LOAD_CATEGORY', :v_cat, :v_file_nm, 'VIEW_REFRESH',
                       'RDS_DB.' || :v_cat || '_VW.' || :v_base_nm, 'RUNNING';

                -- YYYYMMDD sorts correctly as text, so MAX() = latest date
                SELECT MAX(TABLE_NAME) INTO :v_latest_tbl
                  FROM RDS_DB.INFORMATION_SCHEMA.TABLES
                 WHERE TABLE_SCHEMA = :v_cat
                   AND TABLE_TYPE   = 'BASE TABLE'
                   AND REGEXP_LIKE(TABLE_NAME, :v_base_nm || '_[0-9]{8}');

                v_sql := 'CREATE OR REPLACE VIEW RDS_DB.' || v_cat || '_VW.' || v_base_nm ||
                         ' COMMENT = ''RDS_DB.' || v_cat || '.' || v_latest_tbl || '''' ||
                         ' AS SELECT * FROM RDS_DB.' || v_cat || '.' || v_latest_tbl;
                EXECUTE IMMEDIATE :v_sql;

                UPDATE RDS_DB.OPS.JOB_LOG
                   SET STATUS = 'SUCCESS', END_TS = CURRENT_TIMESTAMP(),
                       ERROR_MSG = 'Points to ' || :v_latest_tbl
                 WHERE JOB_RUN_ID = :v_job_run_id AND FILE_NM = :v_file_nm AND STEP_NM = 'VIEW_REFRESH';

                v_ok_cnt := v_ok_cnt + 1;
            END IF;

        EXCEPTION
            WHEN OTHER THEN
                -- one bad file must not stop the rest of the batch
                v_fail_cnt := v_fail_cnt + 1;
                UPDATE RDS_DB.OPS.JOB_LOG
                   SET STATUS    = 'ERROR',
                       ERROR_MSG = LEFT(:SQLERRM, 1000),
                       END_TS    = CURRENT_TIMESTAMP()
                 WHERE JOB_RUN_ID = :v_job_run_id AND FILE_NM = :v_file_nm AND STATUS = 'RUNNING';
        END;
    END FOR;

    RETURN OBJECT_CONSTRUCT('job_run_id',    v_job_run_id,
                            'category',      v_cat,
                            'files_loaded',  v_ok_cnt,
                            'files_failed',  v_fail_cnt);
END;
$$;

-----------------------------------------------------------
-- RUN
-----------------------------------------------------------
CALL RDS_DB.OPS.SP_LOAD_CATEGORY('HDS');
CALL RDS_DB.OPS.SP_LOAD_CATEGORY('IHP');

-----------------------------------------------------------
-- CHECK RESULTS
-----------------------------------------------------------
SELECT * FROM RDS_DB.OPS.VW_LOAD_SUMMARY ORDER BY START_TS DESC;
SELECT * FROM RDS_DB.OPS.AUDIT_LOG       ORDER BY AUDIT_ID DESC;
SELECT * FROM RDS_DB.OPS.VW_FAILED_CHECKS;
SHOW TABLES IN SCHEMA RDS_DB.HDS;
SELECT * FROM RDS_DB.HDS_VW.HDS_FACILITY;
SELECT * FROM RDS_DB.IHP_VW.IHP_HEALTH_PLAN;

/*==========================================================
  RDS - SP_LOAD_CATEGORY
  Call:  CALL RDS_DB.OPS.SP_LOAD_CATEGORY('HDS');
         CALL RDS_DB.OPS.SP_LOAD_CATEGORY('IHP');

  DRIVEN BY THE FOLDER, NOT THE INVENTORY:
    Scans  <CAT>/  on the stage, ignoring <CAT>/History/ and the inventory file.
    For every file found:
      1. VALIDATION    FILE_IN_INVENTORY -> COLUMN_COUNT -> ROW_COUNT
                       not in inventory  -> logged and left in place (never loaded)
      2. TABLE_LOAD    RDS_DB.<CAT>.<file name without .csv>
                       e.g. HDS_FACILITY_20260914.csv -> RDS_DB.HDS.HDS_FACILITY_20260914
      3. VIEW_REFRESH  RDS_DB.<CAT>_VW.<name without date> -> table with the LATEST date
      4. ARCHIVE       moves the file to <CAT>/History/ so it is never loaded twice

    After the loop, any inventory row whose file is not in the folder AND was never
    loaded successfully is reported as FILE_MISSING (vendor promised, never delivered).

  Every step writes OPS.JOB_LOG; every check writes OPS.AUDIT_LOG; both share JOB_RUN_ID.
  One bad file is logged and skipped - the rest of the batch still loads.
==========================================================*/

-----------------------------------------------------------
-- PREREQUISITE (run once): file format used by INFER_SCHEMA to read the header
-----------------------------------------------------------
USE ROLE RDS_ADMIN;
USE WAREHOUSE RDS_WH;
USE SCHEMA RDS_DB.OPS;

CREATE OR REPLACE FILE FORMAT FF_CSV_INFER
  TYPE                         = CSV
  PARSE_HEADER                 = TRUE
  FIELD_DELIMITER              = ','
  FIELD_OPTIONALLY_ENCLOSED_BY = '"'
  TRIM_SPACE                   = TRUE
  EMPTY_FIELD_AS_NULL          = TRUE
  SKIP_BLANK_LINES             = TRUE
  COMMENT                      = 'Header row used by INFER_SCHEMA to build the table';

-----------------------------------------------------------
-- PROCEDURE
-----------------------------------------------------------
CREATE OR REPLACE PROCEDURE RDS_DB.OPS.SP_LOAD_CATEGORY(P_CATEGORY VARCHAR)
RETURNS VARIANT
LANGUAGE SQL
COMMENT = 'Loads new files for a category: validate against inventory, load to dated table, refresh view, archive to History'
EXECUTE AS CALLER
AS
$$
DECLARE
    c_stage        VARCHAR DEFAULT '@RDS_DB.OPS.EXT_STAGE_RDS';
    v_job_run_id   VARCHAR;
    v_cat          VARCHAR;
    v_folder       VARCHAR;
    v_hist_folder  VARCHAR;
    v_inv_path     VARCHAR;
    v_file_nm      VARCHAR;
    v_in_inventory NUMBER;
    v_exp_cols     NUMBER;
    v_exp_rows     NUMBER;
    v_act_cols     NUMBER;
    v_act_rows     NUMBER;
    v_failed       NUMBER;
    v_tbl_nm       VARCHAR;
    v_base_nm      VARCHAR;
    v_latest_tbl   VARCHAR;
    v_rows_loaded  NUMBER;
    v_found_cnt    NUMBER DEFAULT 0;
    v_ok_cnt       NUMBER DEFAULT 0;
    v_fail_cnt     NUMBER DEFAULT 0;
    v_noinv_cnt    NUMBER DEFAULT 0;
    v_missing_cnt  NUMBER DEFAULT 0;
    v_sql          VARCHAR;
    -- both temp tables are created at run time, just below
    c_files CURSOR FOR SELECT FILE_NM FROM RDS_DB.OPS.TMP_FILE_LIST ORDER BY FILE_NM;
BEGIN
    v_cat         := UPPER(P_CATEGORY);
    v_job_run_id  := UUID_STRING();
    v_folder      := v_cat || '/';
    v_hist_folder := v_folder || 'History/';
    v_inv_path    := c_stage || '/' || v_folder || 'RDS_Inventory_' || v_cat || '.csv';

    -- the directory table must reflect what is in S3 right now
    ALTER STAGE RDS_DB.OPS.EXT_STAGE_RDS REFRESH;

    -------------------------------------------------------------
    -- A. Inventory: what the vendor says they sent
    -------------------------------------------------------------
    v_sql := 'CREATE OR REPLACE TEMPORARY TABLE RDS_DB.OPS.TMP_INVENTORY AS
              SELECT TRIM($1)::VARCHAR      AS FILE_NM,
                     TRY_TO_NUMBER(TRIM($2)) AS COL_CNT,
                     TRY_TO_NUMBER(TRIM($3)) AS ROW_CNT
              FROM ' || v_inv_path || ' (FILE_FORMAT => ''RDS_DB.OPS.FF_CSV_HEADER'')
              WHERE NULLIF(TRIM($1), '''') IS NOT NULL';
    EXECUTE IMMEDIATE :v_sql;

    -------------------------------------------------------------
    -- B. Folder: what is actually waiting to be loaded
    --    (skips History/, the inventory file and folder placeholders)
    -------------------------------------------------------------
    CREATE OR REPLACE TEMPORARY TABLE RDS_DB.OPS.TMP_FILE_LIST AS
    SELECT SPLIT_PART(RELATIVE_PATH, '/', -1) AS FILE_NM,
           RELATIVE_PATH,
           SIZE,
           LAST_MODIFIED
    FROM DIRECTORY(@RDS_DB.OPS.EXT_STAGE_RDS)
    WHERE RELATIVE_PATH LIKE :v_folder || '%'
      AND RELATIVE_PATH NOT LIKE :v_hist_folder || '%'
      AND SPLIT_PART(RELATIVE_PATH, '/', -1) NOT ILIKE 'RDS_Inventory%'
      AND SPLIT_PART(RELATIVE_PATH, '/', -1) <> '';

    SELECT COUNT(*) INTO :v_found_cnt FROM RDS_DB.OPS.TMP_FILE_LIST;

    -------------------------------------------------------------
    -- C. Process each file found in the folder
    -------------------------------------------------------------
    FOR rec IN c_files DO
        v_file_nm     := rec.FILE_NM;
        v_failed      := 0;
        v_act_cols    := 0;
        v_act_rows    := 0;
        v_rows_loaded := 0;
        v_tbl_nm      := SPLIT_PART(v_file_nm, '.', 1);                 -- HDS_FACILITY_20260914
        v_base_nm     := REGEXP_REPLACE(v_tbl_nm, '_[0-9]{8}$', '');    -- HDS_FACILITY

        BEGIN
            -------------------------------------------------------------
            -- STEP 1: VALIDATION
            -------------------------------------------------------------
            INSERT INTO RDS_DB.OPS.JOB_LOG (JOB_RUN_ID, JOB_NM, CATEGORY, FILE_NM, STEP_NM, TARGET_OBJECT, STATUS)
            SELECT :v_job_run_id, 'SP_LOAD_CATEGORY', :v_cat, :v_file_nm, 'VALIDATION',
                   'RDS_DB.' || :v_cat || '.' || :v_tbl_nm, 'RUNNING';

            -- check 1: is this file listed in the inventory?
            SELECT COUNT(*), MAX(COL_CNT), MAX(ROW_CNT)
              INTO :v_in_inventory, :v_exp_cols, :v_exp_rows
              FROM RDS_DB.OPS.TMP_INVENTORY
             WHERE UPPER(FILE_NM) = UPPER(:v_file_nm);

            INSERT INTO RDS_DB.OPS.AUDIT_LOG
                (JOB_RUN_ID, CATEGORY, FILE_NM, CHECK_NM, EXPECTED_VAL, ACTUAL_VAL, CHECK_STATUS, CHECK_MSG)
            SELECT :v_job_run_id, :v_cat, :v_file_nm, 'FILE_IN_INVENTORY', 'Y',
                   IFF(:v_in_inventory > 0, 'Y', 'N'),
                   IFF(:v_in_inventory > 0, 'PASS', 'FAIL'),
                   IFF(:v_in_inventory > 0,
                       'Found in RDS_Inventory_' || :v_cat || '.csv',
                       'File is in S3 but NOT listed in RDS_Inventory_' || :v_cat || '.csv - not loaded');

            IF (v_in_inventory = 0) THEN
                -- unknown file: log it, leave it in the folder, do not load
                v_failed    := v_failed + 1;
                v_noinv_cnt := v_noinv_cnt + 1;

                INSERT INTO RDS_DB.OPS.AUDIT_LOG
                    (JOB_RUN_ID, CATEGORY, FILE_NM, CHECK_NM, CHECK_STATUS, CHECK_MSG)
                SELECT :v_job_run_id, :v_cat, :v_file_nm, t.CHECK_NM, 'SKIPPED', 'File not in inventory'
                  FROM (SELECT $1 AS CHECK_NM FROM VALUES ('COLUMN_COUNT'), ('ROW_COUNT')) t;
            ELSE
                -- check 2: column count from the header line
                v_sql := 'SELECT ARRAY_SIZE(SPLIT($1, '','')) AS CNT FROM ' || c_stage || '/' || v_folder || v_file_nm ||
                         ' (FILE_FORMAT => ''RDS_DB.OPS.FF_CSV_LINE'') WHERE METADATA$FILE_ROW_NUMBER = 1';
                EXECUTE IMMEDIATE :v_sql;
                SELECT COALESCE(MAX(CNT), 0) INTO :v_act_cols FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()));

                -- check 3: data row count (header skipped by FF_CSV_HEADER)
                v_sql := 'SELECT COUNT(*) AS CNT FROM ' || c_stage || '/' || v_folder || v_file_nm ||
                         ' (FILE_FORMAT => ''RDS_DB.OPS.FF_CSV_HEADER'')';
                EXECUTE IMMEDIATE :v_sql;
                SELECT COALESCE(MAX(CNT), 0) INTO :v_act_rows FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()));

                INSERT INTO RDS_DB.OPS.AUDIT_LOG
                    (JOB_RUN_ID, CATEGORY, FILE_NM, CHECK_NM, EXPECTED_VAL, ACTUAL_VAL, CHECK_STATUS, CHECK_MSG)
                SELECT :v_job_run_id, :v_cat, :v_file_nm, t.CHECK_NM,
                       t.EXPECTED_VAL::VARCHAR, t.ACTUAL_VAL::VARCHAR,
                       IFF(EQUAL_NULL(t.EXPECTED_VAL, t.ACTUAL_VAL), 'PASS', 'FAIL'), t.CHECK_MSG
                  FROM (
                        SELECT 'COLUMN_COUNT' AS CHECK_NM, :v_exp_cols AS EXPECTED_VAL, :v_act_cols AS ACTUAL_VAL,
                               'Header columns vs inventory COL_CNT' AS CHECK_MSG
                        UNION ALL
                        SELECT 'ROW_COUNT', :v_exp_rows, :v_act_rows,
                               'Data rows in file vs inventory ROW_CNT'
                       ) t;

                IF (NOT EQUAL_NULL(v_act_cols, v_exp_cols)) THEN v_failed := v_failed + 1; END IF;
                IF (NOT EQUAL_NULL(v_act_rows, v_exp_rows)) THEN v_failed := v_failed + 1; END IF;
            END IF;

            UPDATE RDS_DB.OPS.JOB_LOG
               SET STATUS    = IFF(:v_failed = 0, 'SUCCESS', 'FAILED'),
                   ERROR_MSG = IFF(:v_failed = 0, NULL, :v_failed || ' check(s) failed - see OPS.AUDIT_LOG'),
                   END_TS    = CURRENT_TIMESTAMP()
             WHERE JOB_RUN_ID = :v_job_run_id AND FILE_NM = :v_file_nm AND STEP_NM = 'VALIDATION';

            IF (v_failed > 0) THEN
                -- not loaded, and deliberately NOT archived: the file stays in the
                -- folder so it can be corrected and picked up on the next run
                IF (v_in_inventory > 0) THEN v_fail_cnt := v_fail_cnt + 1; END IF;

                INSERT INTO RDS_DB.OPS.JOB_LOG
                    (JOB_RUN_ID, JOB_NM, CATEGORY, FILE_NM, STEP_NM, STATUS, ERROR_MSG, END_TS)
                SELECT :v_job_run_id, 'SP_LOAD_CATEGORY', :v_cat, :v_file_nm, 'TABLE_LOAD', 'SKIPPED',
                       'Validation failed - file left in ' || :v_folder, CURRENT_TIMESTAMP();
            ELSE
                ---------------------------------------------------------
                -- STEP 2: TABLE_LOAD
                ---------------------------------------------------------
                INSERT INTO RDS_DB.OPS.JOB_LOG (JOB_RUN_ID, JOB_NM, CATEGORY, FILE_NM, STEP_NM, TARGET_OBJECT, STATUS)
                SELECT :v_job_run_id, 'SP_LOAD_CATEGORY', :v_cat, :v_file_nm, 'TABLE_LOAD',
                       'RDS_DB.' || :v_cat || '.' || :v_tbl_nm, 'RUNNING';

                -- build the table straight from the file header (column names + types)
                v_sql := 'CREATE OR REPLACE TABLE RDS_DB.' || v_cat || '.' || v_tbl_nm || '
                          USING TEMPLATE (
                              SELECT ARRAY_AGG(OBJECT_CONSTRUCT(*)) WITHIN GROUP (ORDER BY ORDER_ID)
                              FROM TABLE(INFER_SCHEMA(
                                   LOCATION    => ''' || c_stage || '/' || v_folder || v_file_nm || ''',
                                   FILE_FORMAT => ''RDS_DB.OPS.FF_CSV_INFER'')))';
                EXECUTE IMMEDIATE :v_sql;

                -- Positional load: the table was just built from THIS file's own header
                -- and COLUMN_COUNT was validated above, so columns line up 1:1.
                v_sql := 'COPY INTO RDS_DB.' || v_cat || '.' || v_tbl_nm ||
                         ' FROM ' || c_stage || '/' || v_folder ||
                         ' FILES = (''' || v_file_nm || ''')' ||
                         ' FILE_FORMAT = (FORMAT_NAME = ''RDS_DB.OPS.FF_CSV_HEADER'')' ||
                         ' ON_ERROR = ABORT_STATEMENT' ||
                         ' FORCE = TRUE';
                EXECUTE IMMEDIATE :v_sql;
                SELECT COALESCE(SUM("rows_loaded"), 0) INTO :v_rows_loaded
                  FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()));

                -- lineage columns added after the load, so counts match during COPY
                EXECUTE IMMEDIATE 'ALTER TABLE RDS_DB.' || v_cat || '.' || v_tbl_nm || ' ADD COLUMN SRC_FILE_NM VARCHAR';
                EXECUTE IMMEDIATE 'ALTER TABLE RDS_DB.' || v_cat || '.' || v_tbl_nm || ' ADD COLUMN LOAD_TS TIMESTAMP_LTZ';

                v_sql := 'UPDATE RDS_DB.' || v_cat || '.' || v_tbl_nm ||
                         ' SET SRC_FILE_NM = ''' || v_folder || v_file_nm || ''',' ||
                         '     LOAD_TS     = CURRENT_TIMESTAMP()';
                EXECUTE IMMEDIATE :v_sql;

                -- check 4: rows actually loaded must match the inventory
                INSERT INTO RDS_DB.OPS.AUDIT_LOG
                    (JOB_RUN_ID, CATEGORY, FILE_NM, CHECK_NM, EXPECTED_VAL, ACTUAL_VAL, CHECK_STATUS, CHECK_MSG)
                SELECT :v_job_run_id, :v_cat, :v_file_nm, 'ROWS_LOADED',
                       :v_exp_rows::VARCHAR, :v_rows_loaded::VARCHAR,
                       IFF(:v_rows_loaded = :v_exp_rows, 'PASS', 'FAIL'),
                       'Rows loaded into RDS_DB.' || :v_cat || '.' || :v_tbl_nm;

                UPDATE RDS_DB.OPS.JOB_LOG
                   SET STATUS    = IFF(:v_rows_loaded = :v_exp_rows, 'SUCCESS', 'FAILED'),
                       ROW_CNT   = :v_rows_loaded,
                       ERROR_MSG = IFF(:v_rows_loaded = :v_exp_rows, NULL, 'Loaded row count does not match inventory'),
                       END_TS    = CURRENT_TIMESTAMP()
                 WHERE JOB_RUN_ID = :v_job_run_id AND FILE_NM = :v_file_nm AND STEP_NM = 'TABLE_LOAD';

                ---------------------------------------------------------
                -- STEP 3: VIEW_REFRESH  (view without date -> latest dated table)
                ---------------------------------------------------------
                INSERT INTO RDS_DB.OPS.JOB_LOG (JOB_RUN_ID, JOB_NM, CATEGORY, FILE_NM, STEP_NM, TARGET_OBJECT, STATUS)
                SELECT :v_job_run_id, 'SP_LOAD_CATEGORY', :v_cat, :v_file_nm, 'VIEW_REFRESH',
                       'RDS_DB.' || :v_cat || '_VW.' || :v_base_nm, 'RUNNING';

                -- YYYYMMDD sorts correctly as text, so MAX() = latest date
                SELECT MAX(TABLE_NAME) INTO :v_latest_tbl
                  FROM RDS_DB.INFORMATION_SCHEMA.TABLES
                 WHERE TABLE_SCHEMA = :v_cat
                   AND TABLE_TYPE   = 'BASE TABLE'
                   AND REGEXP_LIKE(TABLE_NAME, :v_base_nm || '_[0-9]{8}');

                v_sql := 'CREATE OR REPLACE VIEW RDS_DB.' || v_cat || '_VW.' || v_base_nm ||
                         ' COMMENT = ''RDS_DB.' || v_cat || '.' || v_latest_tbl || '''' ||
                         ' AS SELECT * FROM RDS_DB.' || v_cat || '.' || v_latest_tbl;
                EXECUTE IMMEDIATE :v_sql;

                UPDATE RDS_DB.OPS.JOB_LOG
                   SET STATUS = 'SUCCESS', END_TS = CURRENT_TIMESTAMP(),
                       ERROR_MSG = 'Points to ' || :v_latest_tbl
                 WHERE JOB_RUN_ID = :v_job_run_id AND FILE_NM = :v_file_nm AND STEP_NM = 'VIEW_REFRESH';

                ---------------------------------------------------------
                -- STEP 4: ARCHIVE  (move to History/ so it is never loaded twice)
                ---------------------------------------------------------
                INSERT INTO RDS_DB.OPS.JOB_LOG (JOB_RUN_ID, JOB_NM, CATEGORY, FILE_NM, STEP_NM, TARGET_OBJECT, STATUS)
                SELECT :v_job_run_id, 'SP_LOAD_CATEGORY', :v_cat, :v_file_nm, 'ARCHIVE',
                       :v_hist_folder || :v_file_nm, 'RUNNING';

                v_sql := 'COPY FILES INTO ' || c_stage || '/' || v_hist_folder ||
                         ' FROM ' || c_stage || '/' || v_folder ||
                         ' FILES = (''' || v_file_nm || ''')';
                EXECUTE IMMEDIATE :v_sql;

                v_sql := 'REMOVE ' || c_stage || '/' || v_folder || v_file_nm;
                EXECUTE IMMEDIATE :v_sql;

                UPDATE RDS_DB.OPS.JOB_LOG
                   SET STATUS = 'SUCCESS', END_TS = CURRENT_TIMESTAMP(),
                       ERROR_MSG = 'Moved to ' || :v_hist_folder
                 WHERE JOB_RUN_ID = :v_job_run_id AND FILE_NM = :v_file_nm AND STEP_NM = 'ARCHIVE';

                v_ok_cnt := v_ok_cnt + 1;
            END IF;

        EXCEPTION
            WHEN OTHER THEN
                -- one bad file must not stop the rest of the batch
                v_fail_cnt := v_fail_cnt + 1;
                UPDATE RDS_DB.OPS.JOB_LOG
                   SET STATUS    = 'ERROR',
                       ERROR_MSG = LEFT(:SQLERRM, 1000),
                       END_TS    = CURRENT_TIMESTAMP()
                 WHERE JOB_RUN_ID = :v_job_run_id AND FILE_NM = :v_file_nm AND STATUS = 'RUNNING';
        END;
    END FOR;

    -------------------------------------------------------------
    -- D. Promised but never delivered:
    --    in the inventory, not in the folder, and never loaded before
    -------------------------------------------------------------
    INSERT INTO RDS_DB.OPS.AUDIT_LOG
        (JOB_RUN_ID, CATEGORY, FILE_NM, CHECK_NM, EXPECTED_VAL, ACTUAL_VAL, CHECK_STATUS, CHECK_MSG)
    SELECT :v_job_run_id, :v_cat, i.FILE_NM, 'FILE_NAME_EXISTS', 'Y', 'N', 'FAIL',
           'Listed in the inventory but not found in ' || :v_folder
      FROM RDS_DB.OPS.TMP_INVENTORY i
     WHERE NOT EXISTS (SELECT 1 FROM RDS_DB.OPS.TMP_FILE_LIST f
                        WHERE UPPER(f.FILE_NM) = UPPER(i.FILE_NM))
       AND NOT EXISTS (SELECT 1 FROM RDS_DB.OPS.JOB_LOG j
                        WHERE UPPER(j.FILE_NM) = UPPER(i.FILE_NM)
                          AND j.STEP_NM = 'TABLE_LOAD' AND j.STATUS = 'SUCCESS');

    v_missing_cnt := SQLROWCOUNT;

    INSERT INTO RDS_DB.OPS.JOB_LOG
        (JOB_RUN_ID, JOB_NM, CATEGORY, FILE_NM, STEP_NM, STATUS, ERROR_MSG, END_TS)
    SELECT :v_job_run_id, 'SP_LOAD_CATEGORY', :v_cat, i.FILE_NM, 'FILE_MISSING', 'FAILED',
           'In inventory, not in ' || :v_folder || ', never loaded', CURRENT_TIMESTAMP()
      FROM RDS_DB.OPS.TMP_INVENTORY i
     WHERE NOT EXISTS (SELECT 1 FROM RDS_DB.OPS.TMP_FILE_LIST f
                        WHERE UPPER(f.FILE_NM) = UPPER(i.FILE_NM))
       AND NOT EXISTS (SELECT 1 FROM RDS_DB.OPS.JOB_LOG j
                        WHERE UPPER(j.FILE_NM) = UPPER(i.FILE_NM)
                          AND j.STEP_NM = 'TABLE_LOAD' AND j.STATUS = 'SUCCESS');

    RETURN OBJECT_CONSTRUCT('job_run_id',           v_job_run_id,
                            'category',             v_cat,
                            'files_found',          v_found_cnt,
                            'files_loaded',         v_ok_cnt,
                            'files_failed',         v_fail_cnt,
                            'files_not_in_inventory', v_noinv_cnt,
                            'files_missing',        v_missing_cnt);
END;
$$;

-----------------------------------------------------------
-- RUN
-----------------------------------------------------------
CALL RDS_DB.OPS.SP_LOAD_CATEGORY('HDS');
CALL RDS_DB.OPS.SP_LOAD_CATEGORY('IHP');
-- Running it again straight away does nothing: the files are already in History/.

-----------------------------------------------------------
-- CHECK RESULTS
-----------------------------------------------------------
SELECT * FROM RDS_DB.OPS.VW_LOAD_SUMMARY ORDER BY START_TS DESC;
SELECT * FROM RDS_DB.OPS.AUDIT_LOG       ORDER BY AUDIT_ID DESC;
SELECT * FROM RDS_DB.OPS.VW_FAILED_CHECKS;
LIST @RDS_DB.OPS.EXT_STAGE_RDS/HDS/;           -- only the inventory file should remain
LIST @RDS_DB.OPS.EXT_STAGE_RDS/HDS/History/;   -- loaded files land here
SELECT * FROM RDS_DB.HDS_VW.HDS_FACILITY;
SELECT * FROM RDS_DB.IHP_VW.IHP_HEALTH_PLAN;
    


