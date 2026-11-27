-- =====================================================================================================
-- DAASI-3914  Missing WCL theo in DAILY_ACTIVITY_SUMMARY_VW                inputs for the permanent fix
--
-- Read-only. What I need to write and test the change to the trips rating step
-- (TRIP_RATING_DOMAIN_PIPELINE_PROC). Run them one at a time. None depends on another, except B2, where
-- two statements run together. Each reads best as text.
-- If one is refused or fails, skip it and send me the error text as it appears.
--
--   Part A  the procedure and what the change has to work with      (PROD)
--   Part B  the test bed                                            (UAT)
-- =====================================================================================================


-- =====================================================================================================
-- PART A. The procedure, and what the change has to work with
-- =====================================================================================================

-- A1. The procedure exactly as PROD holds it. I already have its body, checked against PROD's own
--     fingerprint. What I am missing is the CREATE header: what it returns, its language, and whose
--     rights it runs with. DDL_START and DDL_END show both ends with line breaks and tabs spelled out,
--     and the length and fingerprint let me prove the file I hand back starts from exactly this text.
--     Copy all five cells. The DDL cell is long, about 30,000 characters.
--     If GET_DDL is refused, run the DESCRIBE under it instead and send every row except "body".
SELECT LENGTH(D)                                                                                        AS DDL_LENGTH,
       MD5(D)                                                                                           AS DDL_FINGERPRINT,
       REPLACE(REPLACE(REPLACE(LEFT(D, 700), CHR(13), '<CR>'), CHR(10), '<LF>'), CHR(9), '<TAB>')       AS DDL_START,
       REPLACE(REPLACE(REPLACE(RIGHT(D, 150), CHR(13), '<CR>'), CHR(10), '<LF>'), CHR(9), '<TAB>')      AS DDL_END,
       D                                                                                                AS DDL
FROM (SELECT GET_DDL('PROCEDURE',
                     'DAAS_PROD.DAAS_COMMON.TRIP_RATING_DOMAIN_PIPELINE_PROC(FLOAT, VARCHAR, VARCHAR, VARCHAR, VARCHAR)') AS D);

-- DESCRIBE PROCEDURE DAAS_PROD.DAAS_COMMON.TRIP_RATING_DOMAIN_PIPELINE_PROC(FLOAT, VARCHAR, VARCHAR, VARCHAR, VARCHAR);


-- A2. Is UAT running the same trips code as PROD? One line per trips procedure. The change goes to UAT
--     first, so the file must not wipe out something newer sitting there, and a UAT test only counts if
--     the rest of the chain matches PROD.
--       "same code" on TRIP_RATING_DOMAIN_PIPELINE_PROC -> one file serves both.
--       "DIFFERENT" on any line -> tell me before anything is deployed; I will ask for that one's text.
--     If every line says "PROD only", your role cannot see UAT's procedures here: run it again under the
--     UAT role.
WITH P AS (
    SELECT PROCEDURE_CATALOG,
           PROCEDURE_NAME,
           ARGUMENT_SIGNATURE,
           DATA_TYPE,
           PROCEDURE_LANGUAGE,
           PROCEDURE_OWNER,
           LAST_ALTERED,
           LENGTH(PROCEDURE_DEFINITION)                                    AS TEXT_LENGTH,
           MD5(REPLACE(PROCEDURE_DEFINITION, 'DAAS_UAT', 'DAAS_PROD'))     AS FINGERPRINT
    FROM SNOWFLAKE.ACCOUNT_USAGE.PROCEDURES
    WHERE PROCEDURE_CATALOG IN ('DAAS_PROD', 'DAAS_UAT')
      AND PROCEDURE_SCHEMA = 'DAAS_COMMON'
      AND (PROCEDURE_NAME LIKE 'TRIP%' OR PROCEDURE_NAME = 'DATA_REPLAY_PROC')
      AND DELETED IS NULL
)
SELECT COALESCE(A.PROCEDURE_NAME, B.PROCEDURE_NAME)        AS PROCEDURE_NAME,
       CASE WHEN A.PROCEDURE_NAME IS NULL THEN 'UAT only'
            WHEN B.PROCEDURE_NAME IS NULL THEN 'PROD only'
            WHEN A.FINGERPRINT = B.FINGERPRINT THEN 'same code'
            ELSE 'DIFFERENT'
       END                                                 AS UAT_VS_PROD,
       A.DATA_TYPE                                         AS RETURNS,
       A.PROCEDURE_LANGUAGE                                AS LANGUAGE,
       A.PROCEDURE_OWNER                                   AS PROD_OWNER,
       B.PROCEDURE_OWNER                                   AS UAT_OWNER,
       A.LAST_ALTERED                                      AS PROD_LAST_ALTERED,
       B.LAST_ALTERED                                      AS UAT_LAST_ALTERED,
       A.TEXT_LENGTH                                       AS PROD_LENGTH,
       B.TEXT_LENGTH                                       AS UAT_LENGTH,
       A.FINGERPRINT                                       AS PROD_FINGERPRINT
FROM (SELECT * FROM P WHERE PROCEDURE_CATALOG = 'DAAS_PROD') A
FULL OUTER JOIN (SELECT * FROM P WHERE PROCEDURE_CATALOG = 'DAAS_UAT') B
       ON B.PROCEDURE_NAME = A.PROCEDURE_NAME
      AND B.ARGUMENT_SIGNATURE = A.ARGUMENT_SIGNATURE
ORDER BY 1;


-- A3a. The trips config functions. One way to scope the change is a setting in TRIP_CONFIG, read the way
--      the pipeline already reads MAX_TRIP_DAYS for a property. To offer Pete that option I need to see
--      how these functions pick a value and what they return when a property has no row.
--      Copy every cell, the FUNCTION_DEFINITION ones included (they are short).
SELECT FUNCTION_NAME,
       ARGUMENT_SIGNATURE,
       DATA_TYPE               AS RETURNS,
       FUNCTION_LANGUAGE,
       FUNCTION_DEFINITION
FROM SNOWFLAKE.ACCOUNT_USAGE.FUNCTIONS
WHERE FUNCTION_CATALOG = 'DAAS_PROD'
  AND FUNCTION_SCHEMA = 'DAAS_COMMON'
  AND FUNCTION_NAME LIKE 'TRIP_CONFIG_UDF%'
  AND DELETED IS NULL
ORDER BY 1, 2;

-- A3b. Every kind of setting TRIP_CONFIG holds today, one line per kind, so a new one would follow the
--      existing pattern.
SELECT CONFIG_TYPE,
       CONFIG_SUBTYPE,
       KEY,
       COUNT(*)                                AS SETTINGS,
       COUNT(DISTINCT PROPERTY_CD)             AS PROPERTIES,
       COUNT(DISTINCT MARKET_CD)               AS MARKETS,
       MIN(VALUE)                              AS LOWEST_VALUE,
       MAX(VALUE)                              AS HIGHEST_VALUE,
       MIN(EFFECTIVE_START_DT)                 AS EARLIEST_START,
       COUNT_IF(ACTIVE_FLG <> 'Y')             AS NOT_ACTIVE
FROM DAAS_PROD.DAAS_CORE.TRIP_CONFIG
GROUP BY 1, 2, 3
ORDER BY 1, 2, 3;


-- A4a. Which source systems feed WCL, month by month. This gives the exact name Hexlite's rows carry,
--      whether its void rows carry the same name, and the day WCL changed over. Any way of scoping the
--      change hangs on those three.
SELECT DATE_TRUNC('MONTH', BUSINESS_DT)::DATE                              AS MONTH_START,
       '[' || COALESCE(SOURCE_SYSTEM_NM::VARCHAR, 'null') || ']'           AS SOURCE_SYSTEM,
       COUNT_IF(DELETE_IND = 'N')                                          AS LIVE_ROWS,
       COUNT_IF(DELETE_IND <> 'N')                                         AS DELETED_ROWS,
       COUNT_IF(RATING_STATUS_CD = 'V')                                    AS STATUS_V_ROWS,
       MIN(BUSINESS_DT)                                                    AS FIRST_PLAY_DAY,
       MAX(BUSINESS_DT)                                                    AS LAST_PLAY_DAY,
       MIN(CREATED_DTTM)                                                   AS FIRST_LOADED,
       MAX(CREATED_DTTM)                                                   AS LAST_LOADED
FROM DAAS_PROD.DAAS_CORE_GAMING_VW.RATINGS_FACT_VW
WHERE PROPERTY_CD = 'WCL'
  AND BUSINESS_DT >= '2025-12-01'
GROUP BY 1, 2
ORDER BY 1, 2;

-- A4b. Is any other property on Hexlite? Rows loaded since November 1 whose source name starts with HEX.
--        WCL only -> scoping by source system and scoping by property come to the same thing today.
SELECT PROPERTY_CD,
       '[' || SOURCE_SYSTEM_NM || ']'          AS SOURCE_SYSTEM,
       COUNT(*)                                AS ROW_COUNT,
       MIN(BUSINESS_DT)                        AS FIRST_PLAY_DAY,
       MAX(BUSINESS_DT)                        AS LAST_PLAY_DAY
FROM DAAS_PROD.DAAS_CORE_GAMING_VW.RATINGS_FACT_VW
WHERE CREATED_DTTM >= '2026-11-01'
  AND SOURCE_SYSTEM_NM LIKE 'HEX%'
GROUP BY 1, 2
ORDER BY 1, 2;


-- A5a. Does a rating ever arrive live, get linked to a trip, and only later turn into a void? WCL rows
--      from the scheduled loads since 11/11 (not the 11/11 hand load), by what they are now.
--        On the deleted / status V lines, CHANGED_AFTER_LOADING and ON_A_TRIP_NOW both 0 -> voids arrive
--            already voided. Changing the time match is then the whole fix.
--        ON_A_TRIP_NOW above 0 on those lines -> voided ratings are still sitting on trips. The change
--            should then also take a Hexlite rating off its trip when it is voided, and I would check
--            what the summary step counts for them.
WITH NEW_ROWS AS (
    SELECT RATINGS_FACT_SK,
           GAME_TYPE_CD,
           DELETE_IND,
           RATING_STATUS_CD,
           CREATED_DTTM,
           UPDATED_DTTM
    FROM DAAS_PROD.DAAS_CORE.RATINGS_FACT
    WHERE PROPERTY_CD = 'WCL'
      AND CREATED_BY <> 'PLAVIGNE_LOCAL'
      AND CREATED_DTTM >= '2026-11-11'
),
LINKS AS (
    SELECT TRANSACTION_TABLE_SK        AS SK,
           COUNT_IF(DELETE_IND = 'N')  AS LIVE_LINKS,
           COUNT(*)                    AS ALL_LINKS
    FROM DAAS_PROD.DAAS_CORE.TRIP_DETAIL
    WHERE TRANSACTION_TYPE = 'RATINGS'
      AND CREATED_DTTM >= '2026-11-11'
    GROUP BY 1
)
SELECT '[' || COALESCE(N.GAME_TYPE_CD::VARCHAR, 'null') || ']'             AS GAME_TYPE,
       N.DELETE_IND,
       '[' || COALESCE(N.RATING_STATUS_CD::VARCHAR, 'null') || ']'         AS RATING_STATUS,
       COUNT(*)                                                            AS ROW_COUNT,
       COUNT_IF(N.UPDATED_DTTM > N.CREATED_DTTM)                           AS CHANGED_AFTER_LOADING,
       COUNT_IF(L.LIVE_LINKS > 0)                                          AS ON_A_TRIP_NOW,
       COUNT_IF(L.ALL_LINKS > 0 AND L.LIVE_LINKS = 0)                      AS TAKEN_OFF_A_TRIP
FROM NEW_ROWS N
LEFT JOIN LINKS L ON L.SK = N.RATINGS_FACT_SK
GROUP BY 1, 2, 3
ORDER BY 1, 2, 3;

-- A5b. How often the scheduled load runs for WCL: one line per day for the last week, with the number of
--      separate load times that day. This says how soon a new rating reaches trips after it is played.
SELECT CREATED_DTTM::DATE              AS LOAD_DAY,
       COUNT(DISTINCT CREATED_DTTM)    AS LOAD_TIMES,
       MIN(CREATED_DTTM)               AS FIRST_LOAD,
       MAX(CREATED_DTTM)               AS LAST_LOAD,
       COUNT(*)                        AS ROWS_LOADED
FROM DAAS_PROD.DAAS_CORE.RATINGS_FACT
WHERE PROPERTY_CD = 'WCL'
  AND CREATED_BY <> 'PLAVIGNE_LOCAL'
  AND CREATED_DTTM >= DATEADD(day, -7, CURRENT_DATE())
GROUP BY 1
ORDER BY 1;


-- =====================================================================================================
-- PART B. The test bed (UAT). Use the UAT role if DAAS_TEAM is refused.
-- =====================================================================================================

-- B1. Does UAT hold WCL's Hexlite ratings, voids included? The test needs live ratings with voids beside
--     them. If UAT has none, the test starts by copying a few guests' rows over from PROD.
SELECT '[' || COALESCE(SOURCE_SYSTEM_NM::VARCHAR, 'null') || ']'           AS SOURCE_SYSTEM,
       CREATED_BY,
       COUNT(*)                                                            AS ROW_COUNT,
       COUNT_IF(DELETE_IND = 'N')                                          AS LIVE_ROWS,
       COUNT_IF(RATING_STATUS_CD = 'V')                                    AS STATUS_V_ROWS,
       MIN(BUSINESS_DT)                                                    AS FIRST_PLAY_DAY,
       MAX(BUSINESS_DT)                                                    AS LAST_PLAY_DAY,
       MAX(CREATED_DTTM)                                                   AS LAST_LOADED
FROM DAAS_UAT.DAAS_CORE_GAMING_VW.RATINGS_FACT_VW
WHERE PROPERTY_CD = 'WCL'
  AND BUSINESS_DT >= '2026-02-01'
GROUP BY 1, 2
ORDER BY 1, 2;

-- B2. Is the trips chain running in UAT, and on what schedule? Run these two statements together.
SHOW TASKS LIKE 'TRIP_ROOT_TASK' IN SCHEMA DAAS_UAT.DAAS_COMMON;
SELECT "name", "state", "schedule", "owner", "last_suspended_on"
FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()));

-- B3. When trips last ran in UAT: its 20 newest steps.
SELECT J.JOB_NAME,
       B.BATCH_STATUS,
       B.BATCH_START_DATE,
       B.UPDATED_DTTM
FROM DAAS_UAT.DAAS_COMMON.BATCH_S02 B
JOIN DAAS_UAT.DAAS_COMMON.JOB J
  ON J.JOB_ID = B.JOB_ID
WHERE J.JOB_NAME LIKE 'TRIP%'
ORDER BY B.BATCH_ID DESC
LIMIT 20;
