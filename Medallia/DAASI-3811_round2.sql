-- DAASI-3811  Medallia Files - Add Luxury Experience Tag
-- Round 2. All read-only. Run in a PROD worksheet as DAAS_TEAM.
-- Results pasted into one text file, the way you sent round 1, is perfect.

------------------------------------------------------------------------------------------------
-- 1. Where the Loyalty feed stops.
--    One row per object in the LMS73 hotel reservations pipeline, raw LMS tables through facts.
--      CREATED       on or after 10/28 = the table was rebuilt by a deploy.
--      LAST_DDL      = when its structure last changed (when the DAASI-3810 columns landed), and by whom.
--      LAST_ALTERED  = the last time its data or structure changed.
--    Raw tables stuck near 10/28 = LMS data stopped arriving.
--    Raw tables current but staging tables stuck = the break is inside the Coalesce pipeline.
------------------------------------------------------------------------------------------------
SELECT TABLE_SCHEMA
      ,TABLE_NAME
      ,TABLE_TYPE
      ,ROW_COUNT
      ,CREATED
      ,LAST_DDL
      ,LAST_DDL_BY
      ,LAST_ALTERED
FROM DAAS_PROD.INFORMATION_SCHEMA.TABLES
WHERE TABLE_NAME ILIKE '%HOTEL_RESERVATIONS%'
   OR (TABLE_SCHEMA ILIKE 'DAAS_RAW_LMS%73%' AND TABLE_NAME ILIKE ANY ('GIP%', 'LMGEP%', 'RMSHP%'))
ORDER BY 1, 2;

------------------------------------------------------------------------------------------------
-- 2. Column order of the two Loyalty facts and the five Medallia tables.
--    The export is SELECT *, so a Medallia table's column order IS the file layout.
--    This shows where ORIGIN_UNIT_ID sits today and where two new columns would land.
------------------------------------------------------------------------------------------------
SELECT TABLE_SCHEMA
      ,TABLE_NAME
      ,COUNT(*)                                                             AS COLUMN_CNT
      ,LISTAGG(COLUMN_NAME, ', ') WITHIN GROUP (ORDER BY ORDINAL_POSITION)  AS COLUMNS_IN_ORDER
FROM DAAS_PROD.INFORMATION_SCHEMA.COLUMNS
WHERE (TABLE_SCHEMA = 'DAAS_CORE_HOTEL' AND TABLE_NAME IN ('HOTEL_RESERVATIONS_FACT', 'LMS73_HOTEL_RESERVATIONS_FACT'))
   OR (TABLE_SCHEMA IN ('DAAS_CORE', 'HPDB') AND TABLE_NAME ILIKE 'MEDALLIA%INVITATION%')
GROUP BY 1, 2
ORDER BY 1, 2;

------------------------------------------------------------------------------------------------
-- 3. How many rows carry a tag in each of the two Loyalty facts.
------------------------------------------------------------------------------------------------
SELECT 'HOTEL_RESERVATIONS_FACT'       AS FACT
      ,COUNT(*)                        AS ROW_CNT
      ,COUNT_IF(TRIM(LOYALTY) <> '')   AS WITH_A_TAG
FROM DAAS_PROD.DAAS_CORE_HOTEL.HOTEL_RESERVATIONS_FACT
UNION ALL
SELECT 'LMS73_HOTEL_RESERVATIONS_FACT'
      ,COUNT(*)
      ,COUNT_IF(TRIM(LOYALTY) <> '')
FROM DAAS_PROD.DAAS_CORE_HOTEL.LMS73_HOTEL_RESERVATIONS_FACT;

------------------------------------------------------------------------------------------------
-- 4. Tags at the LMS source (LMGEP_RAW, where the Loyalty code and description come from).
--    The first row is the untagged bucket (both columns NULL). Every other row is a tag in use.
--    Tags here but none in query 3 = tags exist and are stuck behind the stalled feed.
--    No tags here either = nobody has started tagging, and the sample file needs made-up values.
------------------------------------------------------------------------------------------------
SELECT NULLIF(TRIM(FGI1GE), '')  AS LOYALTY
      ,NULLIF(TRIM(FGN1GE), '')  AS LOYALTY_DESC
      ,COUNT(*)                  AS ROW_CNT
FROM DAAS_PROD.DAAS_RAW_LMS_73.LMGEP_RAW
GROUP BY 1, 2
ORDER BY 3 DESC
LIMIT 50;

------------------------------------------------------------------------------------------------
-- 5. The Medallia tasks: what runs each day, in what order, and the SQL each one runs.
--    Round 1 showed an INSERT into the ARCHIVE table that is in neither procedure. It lives in
--    one of these, and it lists its columns, so it has to change with the procedures.
--    (This view can lag by up to 45 minutes.)
------------------------------------------------------------------------------------------------
SELECT DATABASE_NAME
      ,SCHEMA_NAME
      ,NAME
      ,MAX(SCHEDULED_TIME)                 AS LAST_RUN
      ,MAX_BY(STATE, SCHEDULED_TIME)       AS LAST_STATE
      ,MAX_BY(QUERY_TEXT, SCHEDULED_TIME)  AS TASK_SQL
FROM SNOWFLAKE.ACCOUNT_USAGE.TASK_HISTORY
WHERE SCHEDULED_TIME >= DATEADD(day, -3, CURRENT_TIMESTAMP())
  AND (NAME ILIKE '%MEDALLIA%' OR QUERY_TEXT ILIKE '%MEDALLIA%')
GROUP BY 1, 2, 3
ORDER BY LAST_RUN;

------------------------------------------------------------------------------------------------
-- 6. The export statements in full. Round 1 cut them off at 150 characters.
--    The file format options at the end (delimiter, quoting, header row, how an empty value is
--    written) are what the sample file for Marlene has to match exactly. This also shows
--    whether Snowflake writes the prospect file at all.
------------------------------------------------------------------------------------------------
SELECT START_TIME
      ,QUERY_TEXT
FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
WHERE START_TIME >= DATEADD(day, -2, CURRENT_TIMESTAMP())
  AND QUERY_TYPE = 'UNLOAD'
  AND QUERY_TEXT ILIKE '%MEDALLIA%'
ORDER BY START_TIME DESC
LIMIT 6;

------------------------------------------------------------------------------------------------
-- 7. The two Medallia views. If either reads the invitation tables, it decides whether analysts
--    see the new columns, and a view written as SELECT * breaks when its table gains a column.
------------------------------------------------------------------------------------------------
SELECT 'DAAS_CORE_SURVEY_VW.V_MEDALLIA_CUSTOMER_INVITATION' AS VIEW_NM
      ,GET_DDL('VIEW', 'DAAS_PROD.DAAS_CORE_SURVEY_VW.V_MEDALLIA_CUSTOMER_INVITATION') AS VIEW_DDL
UNION ALL
SELECT 'DAAS_CORE_HOTEL_VW.MEDALLIA_V_CUSTOMER_INVITATION'
      ,GET_DDL('VIEW', 'DAAS_PROD.DAAS_CORE_HOTEL_VW.MEDALLIA_V_CUSTOMER_INVITATION');

------------------------------------------------------------------------------------------------
-- ONLY IF the repo search for ORIGIN_UNIT_ID finds no table files: the five table definitions.
------------------------------------------------------------------------------------------------
SELECT 'INVITATION_HOTEL' AS TBL, GET_DDL('TABLE', 'DAAS_PROD.DAAS_CORE.MEDALLIA_V_CUSTOMER_INVITATION_HOTEL') AS TABLE_DDL
UNION ALL
SELECT 'INVITATION_COMPLETE', GET_DDL('TABLE', 'DAAS_PROD.DAAS_CORE.MEDALLIA_V_CUSTOMER_INVITATION_COMPLETE')
UNION ALL
SELECT 'INVITATION_ARCHIVE', GET_DDL('TABLE', 'DAAS_PROD.DAAS_CORE.MEDALLIA_V_CUSTOMER_INVITATION_ARCHIVE')
UNION ALL
SELECT 'PROSPECT_FILE', GET_DDL('TABLE', 'DAAS_PROD.HPDB.MEDALLIA_PROSPECT_INVITATION_FILE')
UNION ALL
SELECT 'PROSPECT_FILE_ARCHIVE', GET_DDL('TABLE', 'DAAS_PROD.HPDB.MEDALLIA_PROSPECT_INVITATION_FILE_ARCHIVE');
