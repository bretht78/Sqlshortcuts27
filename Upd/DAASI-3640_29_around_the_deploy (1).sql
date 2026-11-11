/* =====================================================================
   DAASI-3640 | 29: around the PROD deploy. Read-only.
   Before the PR is merged: 1 to 4. After it has deployed: 5 and 6.

   Why these: the architect's UAT run through the procedure (14) did
   not happen, so PROD's first five-minute load after the deploy is the
   first time Snowflake executes the daily procedure's main statement in
   its final form (a JavaScript procedure's SQL is not checked when the
   procedure is created). A failure there is quiet: the procedure
   catches its own errors, rolls back and returns FAILURE, so the task
   can still show SUCCEEDED while nothing loads. Nothing is lost while
   that lasts (the stream keeps every row until a run commits), but the
   report goes stale, and going back to v1.12 means dropping the column
   first. 1 to 4 find out beforehand, 5 and 6 confirm afterwards.

   Roles: 1, 2 and the second query of 4 read the account usage views
   (DAAS_SNOWFLAKE_ACCTUSAGE, up to two or three hours behind on grants
   and dependencies). The rest as DAAS_TEAM.

   11/11 afternoon: 01 is now in the BEGIN / CREATE TABLE IF NOT EXISTS /
   ALTER form, with five columns widened, and the two load procedures
   name the columns they insert. Checks 4 and 5 follow that.
   ===================================================================== */

USE DATABASE DAAS_PROD;


-- ---------------------------------------------------------------------
-- BEFORE THE PR IS MERGED
-- ---------------------------------------------------------------------

-- 1. Who runs the load, and on what. The procedure tags its own statements, so the last day of
--    query history names the role it really runs under and the warehouse it really uses.
--    Expect one row. ROLE_NAME is the role checks 2 and 3 are about.
SELECT role_name, user_name, warehouse_name, warehouse_size,
       COUNT(*) AS statements, MAX(start_time) AS latest
FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
WHERE database_name = 'DAAS_PROD'
  AND query_tag LIKE '%HETCMS_COMP_DETAIL_FACT_LOAD_PROC'
  AND start_time > DATEADD(hour, -24, CURRENT_TIMESTAMP())
GROUP BY 1, 2, 3, 4;

-- 2. Can that role read what v1.14 reads? v1.14 reads three tables the daily procedure never
--    read before: the remarks feed and the two tables of the bridge rule. Rows 1 and 2 are
--    tables the load reads today, so they must say yes. If one of them says NO, this check
--    cannot see how the role gets its access, and rows 3 to 5 mean nothing: then SHOW GRANTS ON
--    TABLE for each of the three decides, or check 3 run under the load's own role.
--    The first line takes ROLE_NAME from 1. Then run it once more with the dynamic table's owner
--    (SHOW DYNAMIC TABLES LIKE 'COMP_DETAIL_FACT_DT' IN SCHEMA DAAS_PROD.DAAS_CORE_GAMING).
SET LOAD_ROLE = 'APP_SERVICE_PROD';

WITH RECURSIVE held (ROLE_NAME) AS (
    SELECT $LOAD_ROLE::VARCHAR
    UNION ALL
    SELECT g.NAME::VARCHAR
    FROM held h
    JOIN SNOWFLAKE.ACCOUNT_USAGE.GRANTS_TO_ROLES g
      ON  g.GRANTEE_NAME = h.ROLE_NAME
      AND g.GRANTED_ON = 'ROLE' AND g.PRIVILEGE = 'USAGE' AND g.DELETED_ON IS NULL
),
needs (TBL, WHY) AS (
    SELECT column1, column2
    FROM VALUES ('DAAS_RAW_HETCMS.CMPRW_RAW',       '1. control: the load reads it today'),
                ('DAAS_CORE.CASINO_OUTLET_CD_LKP',  '2. control: the load reads it today'),
                ('DAAS_RAW_HETCMS.CMPRM_RAW',       '3. new in v1.14: the remarks'),
                ('DAAS_CORE.PROPERTY_DIM',          '4. new in v1.14: the bridge rule'),
                ('DAAS_CORE.GUEST_XREF_BRIDGE_LKP', '5. new in v1.14: the bridge rule')
),
can_read AS (
    SELECT g.TABLE_SCHEMA || '.' || g.NAME AS TBL, g.GRANTEE_NAME
    FROM SNOWFLAKE.ACCOUNT_USAGE.GRANTS_TO_ROLES g
    JOIN (SELECT DISTINCT ROLE_NAME FROM held) h
      ON h.ROLE_NAME = g.GRANTEE_NAME
    WHERE g.TABLE_CATALOG = 'DAAS_PROD'
      AND g.PRIVILEGE IN ('SELECT', 'OWNERSHIP')
      AND g.DELETED_ON IS NULL
)
SELECT n.WHY,
       n.TBL                                        AS OBJECT_READ,
       IFF(COUNT(c.GRANTEE_NAME) > 0, 'yes', 'NO')  AS ROLE_CAN_READ_IT,
       MIN(c.GRANTEE_NAME)                          AS THROUGH_ROLE
FROM needs n
LEFT JOIN can_read c
       ON c.TBL = n.TBL
GROUP BY n.WHY, n.TBL
ORDER BY n.WHY, n.TBL;

-- 3. The dry run: file DAASI-3640_28_proc_dry_run.sql. The procedure's main statement as one
--    read-only SELECT, in UAT (0 rows, it compiles) and then in PROD (the comps waiting in the
--    stream). A SELECT does not consume a stream. Run in PROD by someone who can use the role
--    from 1, it answers check 2 as well, with the real statement under the real role.

-- 4. The table before the deploy: 77 columns today. 01 only adds to it (its CREATE TABLE IF NOT
--    EXISTS is skipped where the table exists, and the rest are ALTERs), so it cannot drop a
--    column or a row whatever this shows. Note both numbers for check 5.
SELECT (SELECT COUNT(*) FROM DAAS_PROD.INFORMATION_SCHEMA.COLUMNS
        WHERE TABLE_SCHEMA = 'DAAS_CORE' AND TABLE_NAME = 'COMP_DETAIL_FACT')   AS columns_now,
       (SELECT COUNT(*) FROM DAAS_PROD.DAAS_CORE.COMP_DETAIL_FACT)             AS rows_now;

--    And what is built on the table. A view written as SELECT * on it stops working when a
--    column is added. STAR_SELECTS above 0 is a view to read before the deploy
--    (COMP_DETAIL_FACT_VW lists its columns and shows 0).
SELECT d.REFERENCING_DATABASE, d.REFERENCING_SCHEMA, d.REFERENCING_OBJECT_NAME, d.REFERENCING_OBJECT_DOMAIN,
       REGEXP_COUNT(v.VIEW_DEFINITION, 'select\\s+\\*|\\.\\*', 1, 'i') AS STAR_SELECTS
FROM SNOWFLAKE.ACCOUNT_USAGE.OBJECT_DEPENDENCIES d
LEFT JOIN SNOWFLAKE.ACCOUNT_USAGE.VIEWS v
       ON v.TABLE_ID = d.REFERENCING_OBJECT_ID AND v.DELETED IS NULL
WHERE d.REFERENCED_DATABASE = 'DAAS_PROD'
  AND d.REFERENCED_SCHEMA = 'DAAS_CORE'
  AND d.REFERENCED_OBJECT_NAME = 'COMP_DETAIL_FACT'
ORDER BY STAR_SELECTS DESC NULLS LAST, 1, 2, 3;


-- ---------------------------------------------------------------------
-- AFTER THE DEPLOY
-- ---------------------------------------------------------------------

-- 5. The table after the deploy: one column more than check 4 (78), and ROWS_NOW not below
--    check 4's (the load keeps adding).
SELECT (SELECT COUNT(*) FROM DAAS_PROD.INFORMATION_SCHEMA.COLUMNS
        WHERE TABLE_SCHEMA = 'DAAS_CORE' AND TABLE_NAME = 'COMP_DETAIL_FACT')   AS columns_now,
       (SELECT COUNT(*) FROM DAAS_PROD.DAAS_CORE.COMP_DETAIL_FACT)             AS rows_now;

--    The six columns 01 touches, by position: the five widened ones at 100, 50, 50, 50 and 50,
--    and COMMENTS_EXTENDED, last, at 4000. (Before the deploy: 3, 7, 7, 7, 7 and no sixth row.)
SELECT ORDINAL_POSITION, COLUMN_NAME, DATA_TYPE, CHARACTER_MAXIMUM_LENGTH, IS_NULLABLE
FROM DAAS_PROD.INFORMATION_SCHEMA.COLUMNS
WHERE TABLE_SCHEMA = 'DAAS_CORE' AND TABLE_NAME = 'COMP_DETAIL_FACT'
  AND COLUMN_NAME IN ('CASINO_OUTLET_CD', 'ISSUED_BY_CD', 'REDEEM_AUTHORIZATION_CD',
                      'EXTERNAL_TICKET_NBR', 'VOID_AUTHORIZATION_CD', 'COMMENTS_EXTENDED')
ORDER BY ORDINAL_POSITION;

--    The two tagged columns are still tagged (AUTHORIZER_ID and COMPOR_AUTHOR_NBR,
--    DATA_CATEGORY_TAG = COMPCODE). 01 carries no tags and does not touch them.
SELECT COLUMN_NAME, TAG_NAME, TAG_VALUE
FROM TABLE(DAAS_PROD.INFORMATION_SCHEMA.TAG_REFERENCES_ALL_COLUMNS('DAAS_PROD.DAAS_CORE.COMP_DETAIL_FACT', 'table'));

--    The columns the two load procedures (03, 04) now name in their INSERT, against the live
--    table. The list in the first line is the one in the procedures. Expect 78 | 78 | 0 | 0 | 0.
--    NAMED_BUT_NOT_IN_TABLE must be 0, or the load cannot run. IN_TABLE_BUT_NOT_NAMED above 0
--    means a column was added that the procedures do not fill, which is harmless while that
--    column is nullable: that is what naming the columns buys. NOT_IN_TABLE_ORDER is tidiness
--    only. Before the deploy PROD reads 78 | 77 | 1 | 0 | 0, the 1 being COMMENTS_EXTENDED.
--    For UAT, put DAAS_UAT in place of DAAS_PROD in the tbl part: 78 | 78 | 0 | 0 | 0 already.
WITH named AS (
    SELECT f.INDEX + 1 AS POS, f.VALUE::VARCHAR AS COL
    FROM TABLE(FLATTEN(INPUT => SPLIT('COMP_DETAIL_FACT_SK,GUEST_ID,COMP_NBR,CASINO_OUTLET_CD,LIMIT_TYPE_CD,AUTHORIZER_ID,COMPOR_DEPARTMENT_CD,PROPERTY_CD,REDEEM_AMT,ISSUE_COMP_LIMIT_AMT,LIMIT_DESC,LAST_CHANGE_ISSUE_DTTM,PROPERTY_ID,ISSUE_DT,SNAPSHOT_CMS_TRIP_WIN_LOSS_AMT,SNAPSHOT_CMS_TRIP_COMP_WORTH,SNAPSHOT_CMS_PROPERTY_COMP_WORTH,SNAPSHOT_CMS_BRAND_COMP_WORTH,COMP_AVERAGE_AMT,COMP_OVERAGE_PCT,COMPOR_AUTHOR_NBR,STATUS_CD,COMP_STATUS_CD,LAST_CHANGE_DT,LAST_CHANGE_COMP_LIMIT_AMT,LAST_CHANGE_COMP_OVER_AMT,LAST_CHANGE_COMP_OVER_PCT,SNAPSHOT_CMS_COMP_WORTH_AVAILABLE_AMT,SNAPSHOT_CMS_CURRENT_TRIP_THEO_AMT,DISCRETIONARY_COMP_FLG,ISSUED_BY_CD,COMP_TYPE_CD,NUMBER_OF_PEOPLE_CNT,WINE_COMP_LIMIT_AMT,ISSUE_POINT_LIMIT_AMT,WINE_POINT_LIMIT_AMT,ISSUE_POINT_LIMIT,REDEEM_AUTHORIZATION_CD,FOLIO_ID,EXTERNAL_TICKET_NBR,REDEEM_POINT_AMT,COMP_EXCEPTION_CD,VOID_AUTHORIZATION_CD,VOID_DTTM,CREATE_DTTM,LAST_DTTM,NGC_EXTRACTION_PROCESSED_FLG,ISS_REWARD_CREDIT_AMT,ISS_REWARD_CREDIT_NBR,USED_REWARD_CREDT_AMT,USED_REWARD_CREDITS_NBR,PLAYER_DEVELOPMENT_FLG,SNAPSHOT_CMS_REWARD_CREDIT_BALANCE_AT_ISSUE_AMT,ISSUE_COMP_WORTH_AMT,USED_COMP_WORTH_AMT,UNIQUE_REWARD_LINK_NBR,COMP_COMMENTS_DESC,SOURCE_SYSTEM_NM,TIME_ZONE,CREATED_DTTM,CREATED_BY,UPDATED_DTTM,UPDATED_BY,DELETE_IND,BATCH_ID,LAST_DML_CD,OPERATION_SEQUENCE_NBR,MD5_CHECKSUM,ISSUE_DTTM,REPLAY_COUNTER,OUTLET_CATEGORY,COMPOR_NAME,EMPLOYEE_FIRST_NM,EMPLOYEE_LAST_NM,COMP_CATEGORY,ISHDRW,REDEEM_DTTM,COMMENTS_EXTENDED', ','))) f
),
tbl AS (
    SELECT COLUMN_NAME, ORDINAL_POSITION
    FROM DAAS_PROD.INFORMATION_SCHEMA.COLUMNS
    WHERE TABLE_SCHEMA = 'DAAS_CORE' AND TABLE_NAME = 'COMP_DETAIL_FACT'
)
SELECT COUNT(n.COL)                               AS NAMED_IN_THE_PROCS,
       COUNT(t.COLUMN_NAME)                       AS COLUMNS_IN_THE_TABLE,
       COUNT_IF(t.COLUMN_NAME IS NULL)            AS NAMED_BUT_NOT_IN_TABLE,
       COUNT_IF(n.COL IS NULL)                    AS IN_TABLE_BUT_NOT_NAMED,
       COUNT_IF(t.ORDINAL_POSITION <> n.POS)      AS NOT_IN_TABLE_ORDER
FROM named n
FULL OUTER JOIN tbl t
  ON t.COLUMN_NAME = n.COL;

-- 6. v1.14 is loading. Only v1.14 can fill the new column, so the first rows that carry remarks
--    are the proof that the new procedure runs under the task and writes. About one comp in two
--    hundred has remarks, so give it a few runs. Run this twice, some minutes apart:
--    ROWS_WITH_REMARKS above 0, and LATEST_ONE moving.
SELECT COUNT(*)          AS rows_with_remarks,
       MIN(UPDATED_DTTM) AS first_one,
       MAX(UPDATED_DTTM) AS latest_one
FROM DAAS_CORE.COMP_DETAIL_FACT
WHERE COMMENTS_EXTENDED IS NOT NULL;

--    And the load is consuming its stream: this drops back to a small number after each run. A
--    number that only climbs, run after run, means the runs are failing quietly. No remarks yet
--    while this keeps dropping back just means no comp with remarks has come in so far.
SELECT COUNT(*) AS rows_waiting FROM DAAS_RAW_HETCMS.CMPRW_RAW_COMP_DETAIL_STREAM;
