-- DAASI-3811  Medallia Files - Add Luxury Experience Tag
-- Round 3. All read-only. Run in a PROD worksheet as DAAS_TEAM.
-- Part A confirms why nothing reaches HOTEL_RESERVATIONS_FACT. Part B is what I build the change from.

------------------------------------------------------------------------------------------------
-- A1. Is LMS73_HOTEL_RESERVATIONS_FACT current, and is it one row per reservation?
--       NEWEST_RESERVATION_ID starting 46342 = booked today (46322 = 10/28).
--       LIVE_ROWS equal to RESERVATIONS = one row per reservation, so a join cannot multiply rows.
--       LUX_ROWS = reservations carrying the Luxury Experience code.
------------------------------------------------------------------------------------------------
SELECT 'LMS73_HOTEL_RESERVATIONS_FACT'               AS FACT
      ,COUNT(*)                                      AS LIVE_ROWS
      ,COUNT(DISTINCT PROPERTY_CD, RESERVATION_ID)   AS RESERVATIONS
      ,MAX(RESERVATION_ID)                           AS NEWEST_RESERVATION_ID
      ,MAX(LAST_MODIFIED_DTTM)                       AS NEWEST_LMS_CHANGE
      ,MAX(UPDATED_DTTM)                             AS NEWEST_LOAD
      ,COUNT_IF(TRIM(LOYALTY) = 'LUX')               AS LUX_ROWS
FROM DAAS_PROD.DAAS_CORE_HOTEL.LMS73_HOTEL_RESERVATIONS_FACT
WHERE DELETE_IND = 'N'
UNION ALL
SELECT 'HOTEL_RESERVATIONS_FACT'
      ,COUNT(*)
      ,COUNT(DISTINCT PROPERTY_CD, RESERVATION_ID)
      ,MAX(RESERVATION_ID)
      ,MAX(LAST_MODIFIED_DTTM)
      ,MAX(UPDATED_DTTM)
      ,COUNT_IF(TRIM(LOYALTY) = 'LUX')
FROM DAAS_PROD.DAAS_CORE_HOTEL.HOTEL_RESERVATIONS_FACT
WHERE DELETE_IND = 'N';

------------------------------------------------------------------------------------------------
-- A2. Every Loyalty code in use, with how many reservations carry it and over what arrival dates.
--     This is the full code list for Marlene. Descriptions that are numbers (the CZR account
--     numbers) are shown as '(a number)' so none leave Snowflake.
------------------------------------------------------------------------------------------------
SELECT TRIM(LOYALTY)                                                    AS LOYALTY
      ,COUNT(*)                                                         AS RESERVATIONS
      ,COUNT(DISTINCT TRIM(LOYALTY_DESC))                               AS DISTINCT_DESCRIPTIONS
      ,MIN(IFF(REGEXP_LIKE(TRIM(LOYALTY_DESC), '[0-9 ]+'), '(a number)', TRIM(LOYALTY_DESC))) AS EXAMPLE_DESCRIPTION
      ,MIN(ARRIVAL_DT)                                                  AS EARLIEST_ARRIVAL
      ,MAX(ARRIVAL_DT)                                                  AS LATEST_ARRIVAL
FROM DAAS_PROD.DAAS_CORE_HOTEL.LMS73_HOTEL_RESERVATIONS_FACT
WHERE DELETE_IND = 'N'
  AND TRIM(LOYALTY) <> ''
GROUP BY 1
ORDER BY 2 DESC;

------------------------------------------------------------------------------------------------
-- A3. What the broken step actually ran. The last loads that touch STG_LMS73_HOTEL_RESERVATIONS_05:
--     whether each succeeded, how many rows it inserted, any error, and the full statement.
--     The FROM clause of the statement that fills that table names what it reads from.
------------------------------------------------------------------------------------------------
SELECT START_TIME
      ,USER_NAME
      ,QUERY_TYPE
      ,EXECUTION_STATUS
      ,ROWS_INSERTED
      ,ERROR_MESSAGE
      ,QUERY_TEXT
FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
WHERE START_TIME >= DATEADD(hour, -30, CURRENT_TIMESTAMP())
  AND QUERY_TEXT ILIKE '%STG_LMS73_HOTEL_RESERVATIONS_05%'
  AND QUERY_TYPE IN ('INSERT', 'MERGE', 'CREATE_TABLE_AS_SELECT')
  AND USER_NAME <> CURRENT_USER()
ORDER BY START_TIME DESC
LIMIT 4;

------------------------------------------------------------------------------------------------
-- A4. Streams on the hotel reservations tables. Run these two statements together, in order.
--     A stream created before 10/28 13:41 Pacific on a table that was rebuilt at that time is
--     still attached to the old copy. Look at created_on, stale and the invalid reason.
------------------------------------------------------------------------------------------------
SHOW STREAMS IN DATABASE DAAS_PROD;

SELECT *
FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()))
WHERE "table_name" ILIKE '%HOTEL_RESERVATIONS%'
   OR "name" ILIKE '%HOTEL_RESERVATIONS%';

------------------------------------------------------------------------------------------------
-- Part B. Definitions I build from. Skip any that exist as a file in daas-snowflake and send
-- me that file instead.
------------------------------------------------------------------------------------------------
-- B1. The five tables.
SELECT 'INVITATION_HOTEL' AS TBL, GET_DDL('TABLE', 'DAAS_PROD.DAAS_CORE.MEDALLIA_V_CUSTOMER_INVITATION_HOTEL') AS TABLE_DDL
UNION ALL
SELECT 'INVITATION_COMPLETE', GET_DDL('TABLE', 'DAAS_PROD.DAAS_CORE.MEDALLIA_V_CUSTOMER_INVITATION_COMPLETE')
UNION ALL
SELECT 'INVITATION_ARCHIVE', GET_DDL('TABLE', 'DAAS_PROD.DAAS_CORE.MEDALLIA_V_CUSTOMER_INVITATION_ARCHIVE')
UNION ALL
SELECT 'PROSPECT_FILE', GET_DDL('TABLE', 'DAAS_PROD.HPDB.MEDALLIA_PROSPECT_INVITATION_FILE')
UNION ALL
SELECT 'PROSPECT_FILE_ARCHIVE', GET_DDL('TABLE', 'DAAS_PROD.HPDB.MEDALLIA_PROSPECT_INVITATION_FILE_ARCHIVE');

-- B2. The two archive tasks, with their schedule, warehouse and predecessor.
SELECT 'MEDALLIA_ARCHIVE_TASK' AS TASK_NM, GET_DDL('TASK', 'DAAS_PROD.DAAS_COMMON.MEDALLIA_ARCHIVE_TASK') AS TASK_DDL
UNION ALL
SELECT 'MEDALLIA_PROSPECT_INVITATION_FILE_ARCHIVE_TASK', GET_DDL('TASK', 'DAAS_PROD.DAAS_COMMON.MEDALLIA_PROSPECT_INVITATION_FILE_ARCHIVE_TASK');

-- B3. The PROD copy of the prospect procedure (the one sent in round 1 was the UAT copy).
SELECT GET_DDL('PROCEDURE', 'DAAS_PROD.HPDB.MEDALLIA_PROSPECT_INVITATION_FILE_PROC(DATE)');
