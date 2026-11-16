-- DAASI-3811  Medallia Files - Add Luxury Experience Tag
-- Discovery queries. All read-only. Run in a PROD worksheet as DAAS_TEAM.
-- Send back each result grid (photos are fine) and the code from step 5 (as text if possible).

------------------------------------------------------------------------------------------------
-- 1. Every Medallia object: procedures (matched by name or by body), tables and views.
--    Shows which procedures build the invitation and prospect datasets, what they load,
--    and whether the same objects exist in UAT for testing.
--    If this comes back empty, the objects are not named MEDALLIA: tell me what they are called.
------------------------------------------------------------------------------------------------
SELECT 'PROCEDURE'                           AS KIND
      ,PROCEDURE_CATALOG                     AS DB
      ,PROCEDURE_SCHEMA                      AS SCHEMA_NM
      ,PROCEDURE_NAME || ARGUMENT_SIGNATURE  AS OBJECT_NM
      ,LAST_ALTERED
FROM SNOWFLAKE.ACCOUNT_USAGE.PROCEDURES
WHERE DELETED IS NULL
  AND (PROCEDURE_NAME ILIKE '%MEDALLIA%' OR PROCEDURE_DEFINITION ILIKE '%MEDALLIA%')
UNION ALL
SELECT TABLE_TYPE
      ,TABLE_CATALOG
      ,TABLE_SCHEMA
      ,TABLE_NAME
      ,LAST_ALTERED
FROM SNOWFLAKE.ACCOUNT_USAGE.TABLES
WHERE DELETED IS NULL
  AND TABLE_NAME ILIKE '%MEDALLIA%'
ORDER BY 2, 1, 3, 4;

------------------------------------------------------------------------------------------------
-- 2. What runs every day. Each distinct statement that mentioned Medallia in the last 3 days:
--    who ran it, what kind of statement it was, and how many times.
--    The step that writes the daily files (an unload to a stage, or a service account reading
--    a table) shows up here. If that step lists its columns by name, it has to change too,
--    or the new columns never reach the file.
------------------------------------------------------------------------------------------------
SELECT USER_NAME
      ,QUERY_TYPE
      ,LEFT(QUERY_TEXT, 150)  AS STATEMENT_START
      ,COUNT(*)               AS RUNS
      ,MAX(START_TIME)        AS LAST_RUN
FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
WHERE START_TIME >= DATEADD(day, -3, CURRENT_TIMESTAMP())
  AND QUERY_TEXT ILIKE '%MEDALLIA%'
  AND USER_NAME <> CURRENT_USER()
GROUP BY 1, 2, 3
ORDER BY LAST_RUN DESC
LIMIT 40;

------------------------------------------------------------------------------------------------
-- 3. Which reservation objects carry the Loyalty columns, and their data types.
--    The ticket names DAAS_CORE.HOTEL_GUEST_RESERVATIONS_FACT. On DAASI-3864 the columns were
--    found only in DAAS_CORE_HOTEL.HOTEL_RESERVATIONS_FACT and HOTEL_RESERVATIONS_VW.
--    This settles which table the Medallia procedures have to read the tag from.
------------------------------------------------------------------------------------------------
SELECT TABLE_SCHEMA
      ,TABLE_NAME
      ,COLUMN_NAME
      ,DATA_TYPE
      ,CHARACTER_MAXIMUM_LENGTH AS LEN
FROM DAAS_PROD.INFORMATION_SCHEMA.COLUMNS
WHERE COLUMN_NAME ILIKE '%LOYALTY%'
  AND TABLE_NAME ILIKE '%RESERVATION%'
ORDER BY 1, 2, 3;

------------------------------------------------------------------------------------------------
-- 4. Can recent reservations actually get a tag?
--    Takes every reservation in the guest fact arriving within 7 days either side of today
--    and looks it up in the LMS73 fact, the one that carries Loyalty.
--      ALSO_IN_LMS73_FACT close to RESERVATIONS_IN_GUEST_FACT = the LMS73 feed is healthy.
--      Well short = a tag cannot reach those reservations. (On 11/9 the LMS73 fact had
--      received nothing from LMS since 10/28.)
--      WITH_A_TAG = how many of them carry a Luxury Experience tag today.
--      NEWEST_ID columns = the first five digits of a reservation ID are its booking date as a
--      day count (46322 = 10/28, 46341 = 11/16), so these two values show how current each fact is.
------------------------------------------------------------------------------------------------
WITH G AS (
    SELECT DISTINCT PROPERTY_CD, RESERVATION_ID
    FROM DAAS_PROD.DAAS_CORE_HOTEL_VW.HOTEL_GUEST_RESERVATIONS_FACT_VW
    WHERE DELETE_IND = 'N'
      AND ARRIVAL_DT BETWEEN DATEADD(day, -7, CURRENT_DATE) AND DATEADD(day, 7, CURRENT_DATE)
)
,H AS (
    SELECT PROPERTY_CD
          ,RESERVATION_ID
          ,MAX(NULLIF(TRIM(LOYALTY), '')) AS LOYALTY
    FROM DAAS_PROD.DAAS_CORE_HOTEL.HOTEL_RESERVATIONS_VW
    WHERE DELETE_IND = 'N'
    GROUP BY 1, 2
)
SELECT COUNT(*)                              AS RESERVATIONS_IN_GUEST_FACT
      ,COUNT(H.RESERVATION_ID)               AS ALSO_IN_LMS73_FACT
      ,COUNT(H.LOYALTY)                      AS WITH_A_TAG
      ,(SELECT MAX(RESERVATION_ID) FROM G)   AS NEWEST_ID_GUEST_FACT
      ,(SELECT MAX(RESERVATION_ID) FROM H)   AS NEWEST_ID_LMS73_FACT
FROM G
LEFT JOIN H
       ON H.PROPERTY_CD    = G.PROPERTY_CD
      AND H.RESERVATION_ID = G.RESERVATION_ID;

------------------------------------------------------------------------------------------------
-- 5. The code itself, for each procedure that query 1 returns.
--    If the procedure has a file in daas-snowflake (sql/core/procedures/), send that file
--    instead: the repo copy keeps the {{$ENV}} token, the Snowflake copy has DAAS_PROD filled in.
--    Otherwise fill in the three placeholders. ARG TYPES is data types only: () or (VARCHAR, DATE).
------------------------------------------------------------------------------------------------
SELECT GET_DDL('PROCEDURE', 'DAAS_PROD.<SCHEMA>.<PROC_NAME>(<ARG TYPES>)');

--    And for each table those procedures load:
SELECT GET_DDL('TABLE', 'DAAS_PROD.<SCHEMA>.<TABLE_NAME>');
