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
-- CALL RDS_DB.OPS.SP_LOAD_CATEGORY('HDS');
-- CALL RDS_DB.OPS.SP_LOAD_CATEGORY('IHP');
-- Running it again straight away does nothing: the files are already in History/.

-----------------------------------------------------------
-- CHECK RESULTS
-----------------------------------------------------------
-- SELECT * FROM RDS_DB.OPS.VW_LOAD_SUMMARY ORDER BY START_TS DESC;
-- SELECT * FROM RDS_DB.OPS.AUDIT_LOG       ORDER BY AUDIT_ID DESC;
-- SELECT * FROM RDS_DB.OPS.VW_FAILED_CHECKS;
-- LIST @RDS_DB.OPS.EXT_STAGE_RDS/HDS/;           -- only the inventory file should remain
-- LIST @RDS_DB.OPS.EXT_STAGE_RDS/HDS/History/;   -- loaded files land here
-- SELECT * FROM RDS_DB.HDS_VW.HDS_FACILITY;
-- SELECT * FROM RDS_DB.IHP_VW.IHP_HEALTH_PLAN;
