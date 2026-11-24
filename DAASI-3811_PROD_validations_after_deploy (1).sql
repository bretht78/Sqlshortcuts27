-- DAASI-3811  Medallia Files - Add Luxury Experience Tag
-- PROD VALIDATIONS AFTER THE DEPLOY. Four validations. Read only: nothing is changed, set up or cleaned up.
--
-- WHAT THE FOUR SHOW WHEN EVERY LINE SAYS PASS
--   1. The tasks are back on. All eight Medallia tasks are switched on and still linked in their two chains,
--      and the two archive tasks carry the new column.
--   2. PROD holds what was approved. The five tables match UAT column for column, with LOYALTY last, and the
--      three procedures are the code the approval validations ran.
--   3. The daily runs finished and both files went out. One line per day, before and after the deploy: all
--      eight tasks succeeded, the archive tasks ran their new statement, and each file was written. It also
--      shows how many rows went out tagged each day.
--   4. The tag is on the right rows, and only those. In today's two files and in their archive copies, the new
--      column holds LUX exactly where LMS codes the reservation LUX.
--
-- WHEN
--   Validation 1: the day of the deploy, straight after the tasks are resumed. It is the only one with a deadline.
--     A task left switched off has to be found before the next run at 09:30 Pacific (11:30 Central).
--   Validations 2, 3 and 4: any day after the deploy, from 10:30 Pacific (12:30 Central) on. By then the day's run
--     has finished and Snowflake's records of it have caught up. Run on a later day, they cover that day too.
--
-- HOW TO RUN. One worksheet, one validation at a time. Nothing to fill in: no dates and no session variables.
--   Validation 1 needs a role that can see the Medallia tasks. Whoever resumes the tasks has one.
--   Validations 2, 3 and 4 run under DAAS_TEAM.
-- WHAT TO KEEP FOR THE TICKET: the four results. They hold counts, dates and object names, no guest details.
--
-- TERMS. The invitation file is the daily survey list of Caesars Rewards members. The prospect file is the same
-- list for guests with no Caesars Rewards account. LMS is the hotel reservations system, and LUX is its code for a
-- Luxury Experience stay. A gaming-only row is a guest who played and had no hotel stay.


-- ===========================================================================================================
-- VALIDATION 1. The tasks are back on. Deploy day, straight after the tasks are resumed.
-- ===========================================================================================================

-- Run the two statements together. The first lists the Medallia tasks as they are now. The second checks the eight.
--   STATE: started means switched on. A task the deploy recreates comes back suspended until someone resumes it.
--   RUNS_AFTER: the task it waits for. The first task of each chain waits for none; it starts at 09:30 Pacific.
--   STATEMENT_HAS_LOYALTY: the two archive tasks copy each day's file into the archive tables, so their statement
--     has to name the new column. If the deploy recreated them, their CREATED_ON is the time of the deploy.
--   PASS = switched on, still linked to the task before it and, for the two archive tasks, naming LOYALTY.
-- Any INVESTIGATE has to be put right before 09:30 Pacific. A task switched off in the middle of a chain is skipped
-- without an error: the files would still go out, and the archive tables would stop being loaded. Step 3 of
-- DAASI-3811_PROD_archive_task_steps.sql resumes them.
-- If every line says NOT SHOWN TO THIS ROLE, this role cannot see the tasks: run it under the role that resumed them.
SHOW TASKS LIKE 'MEDALLIA%' IN SCHEMA DAAS_PROD.DAAS_COMMON;

WITH EXPECTED AS (
              SELECT 1 AS RUN_ORDER, 'MEDALLIA_HOTEL_TASK' AS TASK_NAME, 'first' AS PLACE
    UNION ALL SELECT 2, 'MEDALLIA_COMPLETE_TASK', 'later'
    UNION ALL SELECT 3, 'MEDALLIA_ARCHIVE_TASK', 'archive'
    UNION ALL SELECT 4, 'MEDALLIA_EXPORT_TASK', 'later'
    UNION ALL SELECT 5, 'MEDALLIA_PROPERTY_ORG_EXPORT_TASK', 'later'
    UNION ALL SELECT 6, 'MEDALLIA_PROSPECT_INVITATION_FILE_TASK', 'first'
    UNION ALL SELECT 7, 'MEDALLIA_PROSPECT_INVITATION_FILE_ARCHIVE_TASK', 'archive'
    UNION ALL SELECT 8, 'MEDALLIA_PROSPECT_EXPORT_TASK', 'later'
),
SHOWN AS (
    SELECT "name"       AS TASK_NAME,
           "state"      AS STATE,
           REPLACE(REGEXP_REPLACE("predecessors"::VARCHAR, '[^A-Za-z0-9_.,]', ''), 'DAAS_PROD.DAAS_COMMON.', '') AS RUNS_AFTER,
           "definition" ILIKE '%LOYALTY%' AS HAS_LOYALTY,
           "created_on" AS CREATED_ON
    FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()))
)
SELECT E.TASK_NAME,
       NVL(S.STATE, 'NOT SHOWN TO THIS ROLE') AS STATE,
       CASE WHEN S.TASK_NAME IS NULL THEN ''
            WHEN E.PLACE = 'first' AND NVL(S.RUNS_AFTER, '') = '' THEN '(none: first task of its chain)'
            ELSE NVL(S.RUNS_AFTER, '') END AS RUNS_AFTER,
       CASE WHEN E.PLACE <> 'archive' THEN '(task not changed)'
            WHEN S.HAS_LOYALTY THEN 'Yes'
            ELSE 'NO' END AS STATEMENT_HAS_LOYALTY,
       S.CREATED_ON,
       IFF(S.STATE = 'started'
           AND (E.PLACE = 'first' OR S.RUNS_AFTER LIKE '%MEDALLIA%')
           AND (E.PLACE <> 'archive' OR S.HAS_LOYALTY), 'PASS', 'INVESTIGATE') AS RESULT
FROM EXPECTED E
LEFT JOIN SHOWN S
    ON S.TASK_NAME = E.TASK_NAME
ORDER BY E.RUN_ORDER;


-- ===========================================================================================================
-- VALIDATION 2. PROD holds what was approved.
-- ===========================================================================================================

-- Compares what PROD holds now with what was tested and approved, object by object.
--   Lines 1 to 5, the tables: PROD against UAT, where the change was tested. PASS = the same columns in the same
--     order with the same types, one more column than before the deploy, and LOYALTY last. The exports send every
--     column of the two file tables in table order, so this is also the layout of the two files.
--   Lines 6 to 8, the procedures: the code PROD holds, comments and spacing set aside, against the code the
--     approval validations ran on 11/21. PASS = the same code. NEITHER THE OLD NOR THE APPROVED CODE means the
--     procedure was changed after those validations ran.
--   BEFORE_THE_DEPLOY is what the approval validations recorded on 11/21.
-- The table lines are right as soon as the deploy finishes. The procedure lines come from a record Snowflake can
-- keep up to three hours behind, so on deploy day they may still say STILL THE OLD CODE.
-- It reads the column catalogue of both databases, which took about seven minutes on 11/21.
WITH PROD_COLS AS (
    SELECT TABLE_SCHEMA, TABLE_NAME, COLUMN_NAME, ORDINAL_POSITION, DATA_TYPE
    FROM DAAS_PROD.INFORMATION_SCHEMA.COLUMNS
    WHERE (TABLE_SCHEMA = 'DAAS_CORE' AND TABLE_NAME IN ('MEDALLIA_V_CUSTOMER_INVITATION_HOTEL',
                                                     'MEDALLIA_V_CUSTOMER_INVITATION_COMPLETE',
                                                     'MEDALLIA_V_CUSTOMER_INVITATION_ARCHIVE'))
    OR    (TABLE_SCHEMA = 'HPDB'      AND TABLE_NAME IN ('MEDALLIA_PROSPECT_INVITATION_FILE',
                                                     'MEDALLIA_PROSPECT_INVITATION_FILE_ARCHIVE'))
),
UAT_COLS AS (
    SELECT TABLE_SCHEMA, TABLE_NAME, COLUMN_NAME, ORDINAL_POSITION, DATA_TYPE
    FROM DAAS_UAT.INFORMATION_SCHEMA.COLUMNS
    WHERE (TABLE_SCHEMA = 'DAAS_CORE' AND TABLE_NAME IN ('MEDALLIA_V_CUSTOMER_INVITATION_HOTEL',
                                                     'MEDALLIA_V_CUSTOMER_INVITATION_COMPLETE',
                                                     'MEDALLIA_V_CUSTOMER_INVITATION_ARCHIVE'))
    OR    (TABLE_SCHEMA = 'HPDB'      AND TABLE_NAME IN ('MEDALLIA_PROSPECT_INVITATION_FILE',
                                                     'MEDALLIA_PROSPECT_INVITATION_FILE_ARCHIVE'))
),
TABLES_NOW AS (
    SELECT NVL(P.TABLE_SCHEMA, U.TABLE_SCHEMA) || '.' || NVL(P.TABLE_NAME, U.TABLE_NAME) AS OBJECT_NAME,
           COUNT(P.COLUMN_NAME) AS COLUMNS_IN_PROD,
           COUNT(U.COLUMN_NAME) AS COLUMNS_IN_UAT,
           COUNT_IF(P.ORDINAL_POSITION = U.ORDINAL_POSITION AND P.DATA_TYPE = U.DATA_TYPE) AS SAME_COLUMNS,
           MAX(IFF(P.COLUMN_NAME = 'LOYALTY', P.ORDINAL_POSITION, NULL)) AS LOYALTY_POSITION,
           NVL(LISTAGG(IFF(P.COLUMN_NAME IS NULL OR U.COLUMN_NAME IS NULL
                           OR P.ORDINAL_POSITION <> U.ORDINAL_POSITION OR P.DATA_TYPE <> U.DATA_TYPE,
                           NVL(P.COLUMN_NAME, U.COLUMN_NAME), NULL), ', '), '') AS DIFFERENT_COLUMNS
    FROM PROD_COLS P
    FULL OUTER JOIN UAT_COLS U
        ON U.TABLE_SCHEMA = P.TABLE_SCHEMA
        AND U.TABLE_NAME = P.TABLE_NAME
        AND U.COLUMN_NAME = P.COLUMN_NAME
    GROUP BY 1
),
PROCEDURES_NOW AS (
    SELECT PROCEDURE_SCHEMA || '.' || PROCEDURE_NAME AS OBJECT_NAME,
           LAST_ALTERED,
           MD5(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REGEXP_REPLACE(PROCEDURE_DEFINITION, '--[^\n]*', ''), ' '), CHAR(9)), CHAR(10)), CHAR(13)), CHAR(160)), CHAR(8203)), CHAR(65279)), CHAR(8239))) AS CODE_FINGERPRINT
    FROM SNOWFLAKE.ACCOUNT_USAGE.PROCEDURES
    WHERE DELETED IS NULL
    AND PROCEDURE_CATALOG = 'DAAS_PROD'
    AND PROCEDURE_SCHEMA IN ('DAAS_COMMON', 'HPDB')
    AND PROCEDURE_NAME IN ('MEDALLIA_V_CUSTOMER_INVITATION_HOTEL_PROC',
                           'MEDALLIA_V_CUSTOMER_INVITATION_COMPLETE_PROC',
                           'MEDALLIA_PROSPECT_INVITATION_FILE_PROC')
    QUALIFY ROW_NUMBER() OVER (PARTITION BY PROCEDURE_SCHEMA, PROCEDURE_NAME ORDER BY LAST_ALTERED DESC) = 1
),
EXPECTED AS (
              SELECT 1 AS LINE_NO, 'TABLE' AS OBJECT_TYPE, 'DAAS_CORE.MEDALLIA_V_CUSTOMER_INVITATION_HOTEL' AS OBJECT_NAME, 48 AS COLUMNS_BEFORE, '' AS APPROVED_CODE, '' AS OLD_CODE
    UNION ALL SELECT 2, 'TABLE', 'DAAS_CORE.MEDALLIA_V_CUSTOMER_INVITATION_COMPLETE', 48, '', ''
    UNION ALL SELECT 3, 'TABLE', 'DAAS_CORE.MEDALLIA_V_CUSTOMER_INVITATION_ARCHIVE', 50, '', ''
    UNION ALL SELECT 4, 'TABLE', 'HPDB.MEDALLIA_PROSPECT_INVITATION_FILE', 49, '', ''
    UNION ALL SELECT 5, 'TABLE', 'HPDB.MEDALLIA_PROSPECT_INVITATION_FILE_ARCHIVE', 50, '', ''
    UNION ALL SELECT 6, 'PROCEDURE', 'DAAS_COMMON.MEDALLIA_V_CUSTOMER_INVITATION_HOTEL_PROC', 0, 'aeebed257b2d90ce54ce8882cbd6472e', '90d0f3988d0c366c055757affbe525bb'
    UNION ALL SELECT 7, 'PROCEDURE', 'DAAS_COMMON.MEDALLIA_V_CUSTOMER_INVITATION_COMPLETE_PROC', 0, 'cb52a2ea028663edc1ad654ac1dd9b25', '8bfc7871321ae659174af99429dcaa1e'
    UNION ALL SELECT 8, 'PROCEDURE', 'HPDB.MEDALLIA_PROSPECT_INVITATION_FILE_PROC', 0, 'f42505a6f72ca296dbb96d94b30e086a', 'a64cafa32a63ced0ba13e5be513ef782'
)
SELECT E.OBJECT_TYPE || ' ' || E.OBJECT_NAME AS DEPLOYED,
       IFF(E.OBJECT_TYPE = 'TABLE', TO_VARCHAR(E.COLUMNS_BEFORE) || ' columns', 'The old code') AS BEFORE_THE_DEPLOY,
       CASE WHEN E.OBJECT_TYPE = 'TABLE' AND T.OBJECT_NAME IS NULL THEN 'NOT FOUND'
            WHEN E.OBJECT_TYPE = 'TABLE' THEN
                 TO_VARCHAR(T.COLUMNS_IN_PROD) || ' columns. '
                 || IFF(T.DIFFERENT_COLUMNS = '', 'Same as UAT, column for column. ',
                        'DIFFERS FROM UAT IN: ' || T.DIFFERENT_COLUMNS || '. ')
                 || CASE WHEN T.LOYALTY_POSITION = T.COLUMNS_IN_PROD THEN 'LOYALTY is the last column.'
                         WHEN T.LOYALTY_POSITION IS NULL THEN 'NO LOYALTY COLUMN.'
                         ELSE 'LOYALTY IS NOT THE LAST COLUMN.' END
            WHEN P.OBJECT_NAME IS NULL THEN 'NOT FOUND, OR NOT SHOWN TO THIS ROLE'
            ELSE CASE P.CODE_FINGERPRINT WHEN E.APPROVED_CODE THEN 'The approved code'
                                         WHEN E.OLD_CODE THEN 'STILL THE OLD CODE'
                                         ELSE 'NEITHER THE OLD NOR THE APPROVED CODE' END
                 || ', last changed ' || TO_VARCHAR(CONVERT_TIMEZONE('America/Los_Angeles', P.LAST_ALTERED), 'YYYY-MM-DD HH24:MI')
                 || ' Pacific.'
       END AS NOW_IN_PROD,
       IFF((E.OBJECT_TYPE = 'TABLE'
            AND T.COLUMNS_IN_PROD = E.COLUMNS_BEFORE + 1
            AND T.COLUMNS_IN_UAT = T.COLUMNS_IN_PROD
            AND T.SAME_COLUMNS = T.COLUMNS_IN_PROD
            AND T.LOYALTY_POSITION = T.COLUMNS_IN_PROD)
           OR (E.OBJECT_TYPE = 'PROCEDURE' AND P.CODE_FINGERPRINT = E.APPROVED_CODE), 'PASS', 'INVESTIGATE') AS RESULT
FROM EXPECTED E
LEFT JOIN TABLES_NOW T
    ON E.OBJECT_TYPE = 'TABLE'
    AND T.OBJECT_NAME = E.OBJECT_NAME
LEFT JOIN PROCEDURES_NOW P
    ON E.OBJECT_TYPE = 'PROCEDURE'
    AND P.OBJECT_NAME = E.OBJECT_NAME
ORDER BY E.LINE_NO;


-- ===========================================================================================================
-- VALIDATION 3. The daily runs finished and both files went out.
-- ===========================================================================================================

-- One line per day for the last week, newest first, from Snowflake's own record of task runs and of exports.
-- The two ROWS_TAGGED columns are counted in the archive tables.
--   TASKS_SUCCEEDED: how many of the eight Medallia tasks ran and succeeded that day. Expect 8.
--   ARCHIVE_TASKS_RAN: the statement the two archive tasks ran: the old one, or the new one that names LOYALTY.
--   INVITATION_FILE_ROWS, PROSPECT_FILE_ROWS: rows written to that day's CaesarsCustomerInvitation and
--     CaesarsProspectInvitation files.
--   INVITATION_ROWS_TAGGED, PROSPECT_ROWS_TAGGED: rows of that day's file that carry LUX, counted in its archive
--     copy. 0 before the deploy. After it, a small number on a day with a Luxury Experience stay and 0 on the
--     rest. It is there to read, not part of PASS: it shows on which days tagged rows went out.
--   PROBLEMS: any task that did not run or did not succeed, by name. Its error message is in Snowflake's task
--     history. It is left out here because an error message can quote a data value, and this result is for the ticket.
--   PASS = all eight succeeded, both archive tasks ran the new statement, both files were written, neither empty.
--   OLD CODE = the same, on the old statement. That is right for every day up to and including deploy day; those
--     lines are the "before". On any later day it means the archive tasks were not replaced.
-- Expect a line for every day, PASS on every day after the deploy, and files about the size they were before it.
-- These records can run 45 minutes behind. Before 10:30 Pacific, a missing or incomplete line for today only means
-- it is too early.
WITH EXPECTED AS (
              SELECT 'MEDALLIA_HOTEL_TASK' AS TASK_NAME, 'load' AS KIND
    UNION ALL SELECT 'MEDALLIA_COMPLETE_TASK', 'load'
    UNION ALL SELECT 'MEDALLIA_ARCHIVE_TASK', 'archive'
    UNION ALL SELECT 'MEDALLIA_EXPORT_TASK', 'export'
    UNION ALL SELECT 'MEDALLIA_PROPERTY_ORG_EXPORT_TASK', 'export'
    UNION ALL SELECT 'MEDALLIA_PROSPECT_INVITATION_FILE_TASK', 'load'
    UNION ALL SELECT 'MEDALLIA_PROSPECT_INVITATION_FILE_ARCHIVE_TASK', 'archive'
    UNION ALL SELECT 'MEDALLIA_PROSPECT_EXPORT_TASK', 'export'
),
RUNS AS (
    SELECT TO_DATE(CONVERT_TIMEZONE('America/Los_Angeles', SCHEDULED_TIME)) AS RUN_DAY,
           NAME AS TASK_NAME,
           STATE,
           QUERY_TEXT
    FROM SNOWFLAKE.ACCOUNT_USAGE.TASK_HISTORY
    WHERE SCHEDULED_TIME >= DATEADD(DAY, -7, CURRENT_DATE())
    AND DATABASE_NAME = 'DAAS_PROD'
    AND SCHEMA_NAME = 'DAAS_COMMON'
    AND NAME LIKE 'MEDALLIA%'
),
TASK_DAYS AS (
    SELECT D.RUN_DAY,
           E.TASK_NAME,
           E.KIND,
           COUNT(R.TASK_NAME) AS RUNS,
           COUNT_IF(R.STATE = 'SUCCEEDED') AS RUNS_SUCCEEDED,
           COUNT_IF(R.STATE = 'SUCCEEDED' AND R.QUERY_TEXT ILIKE '%LOYALTY%') AS RUNS_NAMING_LOYALTY
    FROM (SELECT DISTINCT RUN_DAY FROM RUNS) D
    CROSS JOIN EXPECTED E
    LEFT JOIN RUNS R
        ON R.RUN_DAY = D.RUN_DAY
        AND R.TASK_NAME = E.TASK_NAME
    GROUP BY D.RUN_DAY, E.TASK_NAME, E.KIND
),
DAYS AS (
    SELECT RUN_DAY,
           COUNT_IF(RUNS > 0 AND RUNS_SUCCEEDED = RUNS) AS TASKS_SUCCEEDED,
           COUNT_IF(KIND = 'archive' AND RUNS_SUCCEEDED > 0 AND RUNS_NAMING_LOYALTY = RUNS_SUCCEEDED) AS ARCHIVE_ON_NEW,
           COUNT_IF(KIND = 'archive' AND RUNS_SUCCEEDED > 0 AND RUNS_NAMING_LOYALTY = 0) AS ARCHIVE_ON_OLD,
           NVL(LISTAGG(CASE WHEN RUNS = 0 THEN TASK_NAME || ' did not run'
                            WHEN RUNS_SUCCEEDED < RUNS THEN TASK_NAME || ' did not succeed' END, '; ')
                   WITHIN GROUP (ORDER BY TASK_NAME), '') AS PROBLEMS
    FROM TASK_DAYS
    GROUP BY RUN_DAY
),
EXPORTS AS (
    SELECT TO_DATE(CONVERT_TIMEZONE('America/Los_Angeles', START_TIME)) AS RUN_DAY,
           COUNT_IF(QUERY_TEXT ILIKE '%Medallia/CaesarsCustomerInvitation%') AS INVITATION_EXPORTS,
           COUNT_IF(QUERY_TEXT ILIKE '%Medallia/CaesarsProspectInvitation%') AS PROSPECT_EXPORTS,
           MAX(IFF(QUERY_TEXT ILIKE '%Medallia/CaesarsCustomerInvitation%', ROWS_UNLOADED, NULL)) AS INVITATION_FILE_ROWS,
           MAX(IFF(QUERY_TEXT ILIKE '%Medallia/CaesarsProspectInvitation%', ROWS_UNLOADED, NULL)) AS PROSPECT_FILE_ROWS
    FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
    WHERE START_TIME >= DATEADD(DAY, -7, CURRENT_DATE())
    AND QUERY_TYPE = 'UNLOAD'
    AND UPPER(EXECUTION_STATUS) = 'SUCCESS'
    AND QUERY_TEXT ILIKE '%@DAAS_EXT_STG_OUTBOUND/Medallia/Caesars%Invitation%'
    GROUP BY 1
),
INVITATION_TAGS AS (
    SELECT TO_DATE(SNOWFLAKE_CREATED_DT) AS RUN_DAY, COUNT(LOYALTY) AS ROWS_TAGGED
    FROM DAAS_PROD.DAAS_CORE.MEDALLIA_V_CUSTOMER_INVITATION_ARCHIVE
    WHERE SNOWFLAKE_CREATED_DT >= DATEADD(DAY, -7, CURRENT_DATE())
    GROUP BY 1
),
PROSPECT_TAGS AS (
    SELECT TO_DATE(CREATED_DTTM) AS RUN_DAY, COUNT(LOYALTY) AS ROWS_TAGGED
    FROM DAAS_PROD.HPDB.MEDALLIA_PROSPECT_INVITATION_FILE_ARCHIVE
    WHERE CREATED_DTTM >= DATEADD(DAY, -7, CURRENT_DATE())
    GROUP BY 1
)
SELECT D.RUN_DAY,
       D.TASKS_SUCCEEDED,
       CASE WHEN D.ARCHIVE_ON_NEW = 2 THEN 'The new statement, with LOYALTY'
            WHEN D.ARCHIVE_ON_OLD = 2 THEN 'The old statement'
            WHEN D.ARCHIVE_ON_NEW + D.ARCHIVE_ON_OLD < 2 THEN 'DID NOT BOTH RUN'
            ELSE 'ONE OLD, ONE NEW' END AS ARCHIVE_TASKS_RAN,
       X.INVITATION_FILE_ROWS,
       IT.ROWS_TAGGED AS INVITATION_ROWS_TAGGED,
       X.PROSPECT_FILE_ROWS,
       PT.ROWS_TAGGED AS PROSPECT_ROWS_TAGGED,
       NVL(NULLIF(D.PROBLEMS, ''), '(none)') AS PROBLEMS,
       CASE WHEN D.TASKS_SUCCEEDED < 8
                 OR NVL(X.INVITATION_EXPORTS, 0) = 0 OR NVL(X.INVITATION_FILE_ROWS, 1) = 0
                 OR NVL(X.PROSPECT_EXPORTS, 0) = 0 OR NVL(X.PROSPECT_FILE_ROWS, 1) = 0 THEN 'INVESTIGATE'
            WHEN D.ARCHIVE_ON_NEW = 2 THEN 'PASS'
            WHEN D.ARCHIVE_ON_OLD = 2 THEN 'OLD CODE'
            ELSE 'INVESTIGATE' END AS RESULT
FROM DAYS D
LEFT JOIN EXPORTS X
    ON X.RUN_DAY = D.RUN_DAY
LEFT JOIN INVITATION_TAGS IT
    ON IT.RUN_DAY = D.RUN_DAY
LEFT JOIN PROSPECT_TAGS PT
    ON PT.RUN_DAY = D.RUN_DAY
ORDER BY D.RUN_DAY DESC;


-- ===========================================================================================================
-- VALIDATION 4. The tag is on the right rows, and only those.
-- ===========================================================================================================

-- Looks up every row of today's two files, and of their archive copies, in LMS by property and reservation number.
--   FILE_DAY: the day the rows are for. Each morning's run sends the day before.
--   TAGGED_LUX: rows that carry LUX in the new column.
--   LUX_IN_LMS: rows whose reservation LMS codes LUX.
--   MISMATCHES: rows where the two disagree, either way.
--   MATCHES_THE_FILE, on the two archive lines: the archive's newest load is for the same day as the file and has
--     the same number of rows and of tagged rows.
--   PASS = no mismatch. Lines 3 and 6 also need MATCHES_THE_FILE = Yes.
-- Run it on a day when Validation 3 says PASS for today. Before the first run on the new code the files are still
-- the old ones and the column is empty, so a Luxury Experience stay in them would show as a mismatch.
-- TAGGED_LUX can be 0 on every line: Luxury Experience stays are rare (3 of 7,446 hotel-stay rows on 11/16). That
-- still shows no row is tagged wrongly. To show a file with tags in it, run it again on a day whose line in
-- Validation 3 has a number in a ROWS_TAGGED column.
-- A reservation coded LUX in LMS after the morning's run shows as one mismatch that day. That is timing, not a fault.
-- Lines 1 and 2 add up to the invitation file, lines 4 and 5 to the prospect file. They equal today's
-- INVITATION_FILE_ROWS and PROSPECT_FILE_ROWS in Validation 3: the export writes every row of the file table.
-- Line 5 can be 0 rows on a day when every prospect row is a hotel stay.
WITH LUX AS (
    SELECT PROPERTY_CD, RESERVATION_ID, MAX(TRIM(LOYALTY)) AS LOYALTY
    FROM DAAS_PROD.DAAS_CORE_HOTEL.LMS73_HOTEL_RESERVATIONS_FACT
    WHERE DELETE_IND = 'N'
    AND TRIM(LOYALTY) IN ('LUX')
    GROUP BY PROPERTY_CD, RESERVATION_ID
),
SENT AS (
    -- LOOKUP_NUMBER is the reservation number to look up in LMS. Only a hotel stay has one.
    SELECT IFF(NVL(RESERVATION_NUMBER, '') = '', 2, 1) AS LINE_NO,
           TRANSACTION_DATE, UNIT_ID, RESERVATION_NUMBER AS LOOKUP_NUMBER, LOYALTY
    FROM DAAS_PROD.DAAS_CORE.MEDALLIA_V_CUSTOMER_INVITATION_COMPLETE
    UNION ALL
    SELECT 3, TRANSACTION_DATE, UNIT_ID, RESERVATION_NUMBER, LOYALTY
    FROM DAAS_PROD.DAAS_CORE.MEDALLIA_V_CUSTOMER_INVITATION_ARCHIVE
    WHERE SNOWFLAKE_CREATED_DT = (SELECT MAX(SNOWFLAKE_CREATED_DT) FROM DAAS_PROD.DAAS_CORE.MEDALLIA_V_CUSTOMER_INVITATION_ARCHIVE)
    UNION ALL
    SELECT IFF(TRANSACTION_SOURCE_SYSTEM = 'HOTEL', 4, 5),
           TRANSACTION_DATE, UNIT_ID, IFF(TRANSACTION_SOURCE_SYSTEM = 'HOTEL', RESERVATION_NUMBER, NULL), LOYALTY
    FROM DAAS_PROD.HPDB.MEDALLIA_PROSPECT_INVITATION_FILE
    UNION ALL
    SELECT 6, TRANSACTION_DATE, UNIT_ID, IFF(TRANSACTION_SOURCE_SYSTEM = 'HOTEL', RESERVATION_NUMBER, NULL), LOYALTY
    FROM DAAS_PROD.HPDB.MEDALLIA_PROSPECT_INVITATION_FILE_ARCHIVE
    WHERE CREATED_DTTM = (SELECT MAX(CREATED_DTTM) FROM DAAS_PROD.HPDB.MEDALLIA_PROSPECT_INVITATION_FILE_ARCHIVE)
),
COUNTED AS (
    SELECT S.LINE_NO,
           MAX(LEFT(S.TRANSACTION_DATE, 10)) AS FILE_DAY,
           COUNT(*) AS ROW_COUNT,
           COUNT(S.LOYALTY) AS TAGGED_LUX,
           COUNT(LUX.LOYALTY) AS LUX_IN_LMS,
           COUNT_IF(NVL(S.LOYALTY, '') <> NVL(LUX.LOYALTY, '')) AS MISMATCHES
    FROM SENT S
    LEFT JOIN LUX
        ON LUX.PROPERTY_CD = S.UNIT_ID
        AND LUX.RESERVATION_ID = TRY_TO_NUMBER(S.LOOKUP_NUMBER)
    GROUP BY S.LINE_NO
),
LINES AS (
              SELECT 1 AS LINE_NO, '1 Invitation file, hotel-stay rows' AS CHECKED_ROWS, 'Invitation' AS FILE_NAME, 'file' AS KIND
    UNION ALL SELECT 2, '2 Invitation file, gaming-only rows', 'Invitation', 'file'
    UNION ALL SELECT 3, '3 Invitation archive, newest load', 'Invitation', 'archive'
    UNION ALL SELECT 4, '4 Prospect file, hotel-stay rows', 'Prospect', 'file'
    UNION ALL SELECT 5, '5 Prospect file, other rows', 'Prospect', 'file'
    UNION ALL SELECT 6, '6 Prospect archive, newest load', 'Prospect', 'archive'
),
FILES AS (
    SELECT L.FILE_NAME,
           MAX(C.FILE_DAY) AS FILE_DAY,
           SUM(C.ROW_COUNT) AS ROW_COUNT,
           SUM(C.TAGGED_LUX) AS TAGGED_LUX
    FROM LINES L
    JOIN COUNTED C
        ON C.LINE_NO = L.LINE_NO
    WHERE L.KIND = 'file'
    GROUP BY L.FILE_NAME
)
SELECT L.CHECKED_ROWS,
       C.FILE_DAY,
       NVL(C.ROW_COUNT, 0) AS ROW_COUNT,
       NVL(C.TAGGED_LUX, 0) AS TAGGED_LUX,
       NVL(C.LUX_IN_LMS, 0) AS LUX_IN_LMS,
       NVL(C.MISMATCHES, 0) AS MISMATCHES,
       CASE WHEN L.KIND = 'file' THEN ''
            WHEN C.ROW_COUNT = F.ROW_COUNT AND C.TAGGED_LUX = F.TAGGED_LUX AND NVL(C.FILE_DAY, '') = NVL(F.FILE_DAY, '') THEN 'Yes'
            ELSE 'NO' END AS MATCHES_THE_FILE,
       CASE WHEN L.LINE_NO = 5 AND C.LINE_NO IS NULL THEN 'PASS'
            WHEN C.ROW_COUNT > 0 AND C.MISMATCHES = 0
                 AND (L.KIND = 'file'
                      OR (C.ROW_COUNT = F.ROW_COUNT AND C.TAGGED_LUX = F.TAGGED_LUX AND NVL(C.FILE_DAY, '') = NVL(F.FILE_DAY, ''))) THEN 'PASS'
            ELSE 'INVESTIGATE' END AS RESULT
FROM LINES L
LEFT JOIN COUNTED C
    ON C.LINE_NO = L.LINE_NO
LEFT JOIN FILES F
    ON F.FILE_NAME = L.FILE_NAME
ORDER BY L.LINE_NO;
