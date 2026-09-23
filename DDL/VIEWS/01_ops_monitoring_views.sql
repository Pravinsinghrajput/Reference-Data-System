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
    MAX(IFF(STEP_NM = 'ARCHIVE',      STATUS,        NULL)) AS ARCHIVE_STATUS,
    MAX(IFF(STEP_NM = 'FILE_MISSING', STATUS,        NULL)) AS MISSING_STATUS,
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
