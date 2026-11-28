-- =====================================================================================================
-- DAASI-3914  Missing WCL theo in DAILY_ACTIVITY_SUMMARY_VW          inputs for the permanent fix, part 2
--
-- Read-only. Friday's results answered most of what the change needs and raised these. Run them one at
-- a time. None depends on another, except where two statements are marked to run together. Each reads
-- best as text. If one is refused or fails, skip it and send me the error text as it appears.
--
--   Part A  UAT: the copy of the procedure that sits there, and the test bed
--   Part B  PROD: voided ratings that are still on trips
--   Part C  PROD: two loose ends before Sunday's replay
-- (Theo is the casino's expected win on a guest's play. A guest-day is one guest on one day of play.)
-- =====================================================================================================


-- =====================================================================================================
-- PART A. UAT
-- =====================================================================================================

-- A1. UAT's copy of the rating step. It is not PROD's: 37,855 characters against 29,327, last changed
--     7/24/2026. October's comparison put the difference down to one added block, headed DAASI-3356
--     (market trips missing data when a market trip is created or updated). The change for this ticket
--     will replace whatever is in UAT, so I need to see exactly what that is.
--     Copy all seven cells. The TEXT cell is long, about 38,000 characters.
SELECT LAST_ALTERED,
       PROCEDURE_OWNER,
       LENGTH(PROCEDURE_DEFINITION)                                                                                        AS TEXT_LENGTH,
       MD5(PROCEDURE_DEFINITION)                                                                                           AS TEXT_FINGERPRINT,
       REPLACE(REPLACE(REPLACE(LEFT(PROCEDURE_DEFINITION, 200), CHR(13), '<CR>'), CHR(10), '<LF>'), CHR(9), '<TAB>')       AS TEXT_START,
       REPLACE(REPLACE(REPLACE(RIGHT(PROCEDURE_DEFINITION, 150), CHR(13), '<CR>'), CHR(10), '<LF>'), CHR(9), '<TAB>')      AS TEXT_END,
       PROCEDURE_DEFINITION                                                                                                AS TEXT
FROM SNOWFLAKE.ACCOUNT_USAGE.PROCEDURES
WHERE PROCEDURE_CATALOG = 'DAAS_UAT'
  AND PROCEDURE_SCHEMA = 'DAAS_COMMON'
  AND PROCEDURE_NAME = 'TRIP_RATING_DOMAIN_PIPELINE_PROC'
  AND DELETED IS NULL;

-- A2. The stream the rating step reads in UAT. UAT's trips chain has been paused since August, and a
--     stream nobody reads goes stale after a while. The test needs a stream that holds only the test's
--     own rows, so I need to know what state this one is in. Run these two statements together.
--     No rows back -> the role cannot see the stream. Switch to STREAM_OWNERS_UAT and run them again.
SHOW STREAMS LIKE 'RATINGS_FACT_STREAM' IN SCHEMA DAAS_UAT.DAAS_CORE;
SELECT "name", "table_name", "owner", "mode", "stale", "stale_after", "created_on"
FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()));

-- A3. The tasks that run the rating step in UAT, the on-demand one included. Run these two together.
SHOW TASKS LIKE '%TRIP_RATING%' IN SCHEMA DAAS_UAT.DAAS_COMMON;
SELECT "name", "state", "schedule", "predecessors", "owner", "definition"
FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()));

-- A4. The last five times the rating step ran in UAT, and how many rows each run read.
SELECT J.JOB_NAME,
       B.BATCH_ID,
       B.BATCH_STATUS,
       B.BATCH_START_DATE,
       B.UPDATED_DTTM,
       MAX(IFF(M.BATCH_METRIC_CD = 'Source_Rec_Count', M.BATCH_METRIC_VALUE, NULL))        AS ROWS_READ,
       MAX(IFF(M.BATCH_METRIC_CD = 'Detail_Insert_Count', M.BATCH_METRIC_VALUE, NULL))     AS LINKS_WRITTEN
FROM DAAS_UAT.DAAS_COMMON.BATCH_S02 B
JOIN DAAS_UAT.DAAS_COMMON.JOB J
  ON J.JOB_ID = B.JOB_ID
LEFT JOIN DAAS_UAT.DAAS_COMMON.BATCH_METRICS_S02 M
       ON M.BATCH_ID = B.BATCH_ID
WHERE J.JOB_NAME = 'TRIP_RATING_DOMAIN_PIPELINE'
GROUP BY 1, 2, 3, 4, 5
ORDER BY B.BATCH_ID DESC
LIMIT 5;


-- =====================================================================================================
-- PART B. PROD: voided ratings that are still on trips
-- =====================================================================================================
-- Friday's A5a found 1,686 of them in the scheduled loads. A rating arrives live and goes on a trip.
-- Later the property edits it: Hexlite turns that row into a void and sends a new one. Nothing takes the
-- void off the trip, so the change has to do that too.

-- B1. Three real guest-days where it happened: every WCL table rating of the guest that day, in time
--     order, with what each row is now and whether it is on a trip. These become the test cases for
--     the "take a voided rating off its trip" part, the way the ticket's guest was for the pilot.
WITH LINKS AS (
    SELECT TRANSACTION_TABLE_SK                AS SK,
           COUNT_IF(DELETE_IND = 'N')          AS LIVE_LINKS,
           COUNT_IF(DELETE_IND <> 'N')         AS REMOVED_LINKS,
           MIN(CREATED_DTTM)                   AS FIRST_LINKED_ON
    FROM DAAS_PROD.DAAS_CORE.TRIP_DETAIL
    WHERE TRANSACTION_TYPE = 'RATINGS'
      AND CREATED_DTTM >= '2026-11-11'
    GROUP BY 1
),
TABLE_ROWS AS (
    SELECT R.RATINGS_FACT_SK,
           R.GUEST_UNIQUE_ID,
           R.BUSINESS_DT,
           R.TRANSACTION_NBR,
           R.RATING_STATUS_CD,
           R.DELETE_IND,
           R.TABLE_NBR,
           R.START_TM,
           R.END_TM,
           R.THEO_WIN_AMT,
           R.CREATED_BY,
           R.CREATED_DTTM,
           R.UPDATED_DTTM,
           R.REPLAY_COUNTER,
           COALESCE(L.LIVE_LINKS, 0)           AS LIVE_LINKS,
           COALESCE(L.REMOVED_LINKS, 0)        AS REMOVED_LINKS,
           L.FIRST_LINKED_ON
    FROM DAAS_PROD.DAAS_CORE.RATINGS_FACT R
    LEFT JOIN LINKS L ON L.SK = R.RATINGS_FACT_SK
    WHERE R.PROPERTY_CD = 'WCL'
      AND R.GAME_TYPE_CD = 'P'
      AND R.CREATED_DTTM >= '2026-11-11'
),
PICKED AS (
    SELECT GUEST_UNIQUE_ID,
           BUSINESS_DT
    FROM TABLE_ROWS
    GROUP BY 1, 2
    HAVING COUNT_IF(RATING_STATUS_CD = 'V' AND LIVE_LINKS > 0 AND CREATED_BY <> 'PLAVIGNE_LOCAL') > 0
       AND COUNT(*) <= 8
    QUALIFY ROW_NUMBER() OVER (ORDER BY HASH(GUEST_UNIQUE_ID, BUSINESS_DT)) <= 3
)
SELECT T.GUEST_UNIQUE_ID,
       T.BUSINESS_DT,
       T.RATINGS_FACT_SK,
       T.TRANSACTION_NBR,
       '[' || COALESCE(T.RATING_STATUS_CD::VARCHAR, 'null') || ']'     AS RATING_STATUS,
       T.DELETE_IND,
       T.TABLE_NBR,
       T.START_TM,
       T.END_TM,
       T.THEO_WIN_AMT,
       T.CREATED_BY,
       T.CREATED_DTTM,
       T.UPDATED_DTTM,
       T.REPLAY_COUNTER,
       T.LIVE_LINKS,
       T.REMOVED_LINKS,
       T.FIRST_LINKED_ON
FROM TABLE_ROWS T
JOIN PICKED P
  ON P.GUEST_UNIQUE_ID = T.GUEST_UNIQUE_ID
 AND P.BUSINESS_DT = T.BUSINESS_DT
ORDER BY T.GUEST_UNIQUE_ID, T.BUSINESS_DT, T.START_TM, T.CREATED_DTTM, T.RATINGS_FACT_SK;

-- B2. Is the daily view still counting theo for those voided ratings? Every guest-day that has a voided
--     table rating on a trip: the view's table theo, against the theo of the guest's live table ratings
--     that are on a trip that day.
--       Only line 1 -> the voids add nothing: their theo is 0 now and the view has caught up. Taking them
--           off the trips is housekeeping.
--       A line 2 -> the view is overstated on those days by DAILY_TABLE_THEO less LIVE_THEO_ON_A_TRIP.
--           That is a second symptom for the ticket, and the catch-up replay has to cover those rows.
WITH LINKS AS (
    SELECT DISTINCT TRANSACTION_TABLE_SK AS SK
    FROM DAAS_PROD.DAAS_CORE.TRIP_DETAIL
    WHERE TRANSACTION_TYPE = 'RATINGS'
      AND DELETE_IND = 'N'
      AND CREATED_DTTM >= '2026-11-11'
),
T AS (
    SELECT R.GUEST_UNIQUE_ID,
           R.BUSINESS_DT,
           COUNT_IF(R.RATING_STATUS_CD = 'V' AND L.SK IS NOT NULL)                                 AS VOIDS_ON_A_TRIP,
           SUM(IFF(R.RATING_STATUS_CD = 'V' AND L.SK IS NOT NULL, R.THEO_WIN_AMT, 0))              AS THEO_ON_THOSE_VOIDS,
           SUM(IFF(R.DELETE_IND = 'N' AND IFNULL(R.RATING_STATUS_CD, '') NOT IN ('V', 'E')
                   AND L.SK IS NOT NULL, R.THEO_WIN_AMT, 0))                                       AS LIVE_THEO_ON_A_TRIP,
           SUM(IFF(R.DELETE_IND = 'N' AND IFNULL(R.RATING_STATUS_CD, '') NOT IN ('V', 'E'),
                   R.THEO_WIN_AMT, 0))                                                             AS LIVE_THEO
    FROM DAAS_PROD.DAAS_CORE_GAMING_VW.RATINGS_FACT_VW R
    LEFT JOIN LINKS L ON L.SK = R.RATINGS_FACT_SK
    WHERE R.PROPERTY_CD = 'WCL'
      AND R.GAME_TYPE_CD = 'P'
      AND R.CREATED_DTTM >= '2026-11-11'
      AND R.BUSINESS_DT >= '2026-02-25'
      AND R.GUEST_UNIQUE_ID <> 0
      AND IFNULL(R.GAME_CD, '') <> '95'
    GROUP BY 1, 2
    HAVING COUNT_IF(R.RATING_STATUS_CD = 'V' AND L.SK IS NOT NULL) > 0
),
D AS (
    SELECT S.GUEST_UNIQUE_ID,
           S.GUEST_ACTIVITY_DATE,
           SUM(S.TABLE_THEO_WIN_AMT) AS TABLE_THEO
    FROM DAAS_PROD.DAAS_CORE_MARKETING_VW.DAILY_ACTIVITY_SUMMARY_VW S
    JOIN T
      ON T.GUEST_UNIQUE_ID = S.GUEST_UNIQUE_ID
     AND T.BUSINESS_DT = S.GUEST_ACTIVITY_DATE
    WHERE S.TRIP_TYPE = 'PROPERTY'
      AND S.PROPERTY_CD = 'WCL'
    GROUP BY 1, 2
)
SELECT CASE WHEN ABS(COALESCE(D.TABLE_THEO, 0) - T.LIVE_THEO_ON_A_TRIP) < 0.01 THEN '1 the view counts the live ratings on the trip, nothing more'
            WHEN COALESCE(D.TABLE_THEO, 0) > T.LIVE_THEO_ON_A_TRIP THEN '2 the view counts more: voided theo is still in it'
            ELSE '3 the view counts less'
       END                                         AS WHAT_THE_VIEW_SHOWS,
       COUNT(*)                                    AS GUEST_DAYS,
       SUM(T.VOIDS_ON_A_TRIP)                      AS VOIDS_ON_A_TRIP,
       ROUND(SUM(D.TABLE_THEO))                    AS DAILY_TABLE_THEO,
       ROUND(SUM(T.LIVE_THEO_ON_A_TRIP))           AS LIVE_THEO_ON_A_TRIP,
       ROUND(SUM(T.LIVE_THEO))                     AS LIVE_THEO,
       ROUND(SUM(T.THEO_ON_THOSE_VOIDS))           AS THEO_ON_THOSE_VOIDS
FROM T
LEFT JOIN D
       ON D.GUEST_UNIQUE_ID = T.GUEST_UNIQUE_ID
      AND D.GUEST_ACTIVITY_DATE = T.BUSINESS_DT
GROUP BY 1
ORDER BY 1;


-- =====================================================================================================
-- PART C. PROD: two loose ends before Sunday's replay
-- =====================================================================================================

-- C1. Thursday's pilot guest in the daily view, with COMP_WORTH this time (a figure trips works out from
--     the ratings on the trip). Sunday's replay checks that comp worth never goes down. This shows what
--     it looks like after a replay, on the one guest we have: whether it was valued on 9/25 and 9/26,
--     and whether the three kinds of trip agree.
SELECT GUEST_ACTIVITY_DATE,
       TRIP_TYPE,
       TRIP_MASTER_ID,
       TABLE_THEO_WIN_AMT,
       TOTAL_THEO_WIN_AMT,
       COMP_WORTH,
       UPDATED_DTTM
FROM DAAS_PROD.DAAS_CORE_MARKETING_VW.DAILY_ACTIVITY_SUMMARY_VW
WHERE GUEST_UNIQUE_ID = 14400356783
  AND GUEST_ACTIVITY_DATE BETWEEN '2026-09-24' AND '2026-09-26'
ORDER BY GUEST_ACTIVITY_DATE, TRIP_TYPE;

-- C2. Hexlite rows dated before 2/25. HETCMS was still loading WCL's play through 2/24, yet Hexlite has
--     rows from 2/9. The replay holds these back (batch 9) until we know what they are.
--       SAME_GUEST_DAY_IN_HETCMS near ROW_COUNT -> likely the same play recorded twice. I would then
--           compare a few guests in both systems before anything dated before 2/25 is replayed, and the
--           ones already ON_A_TRIP would be a double count to report.
--       SAME_GUEST_DAY_IN_HETCMS near 0 -> separate play. They join the catch-up replay.
WITH LINKS AS (
    SELECT DISTINCT TRANSACTION_TABLE_SK AS SK
    FROM DAAS_PROD.DAAS_CORE.TRIP_DETAIL
    WHERE TRANSACTION_TYPE = 'RATINGS'
      AND DELETE_IND = 'N'
      AND CREATED_DTTM >= '2026-11-11'
),
OLD_SYSTEM AS (
    SELECT DISTINCT GUEST_UNIQUE_ID,
           BUSINESS_DT
    FROM DAAS_PROD.DAAS_CORE_GAMING_VW.RATINGS_FACT_VW
    WHERE PROPERTY_CD = 'WCL'
      AND SOURCE_SYSTEM_NM = 'HETCMS'
      AND DELETE_IND = 'N'
      AND BUSINESS_DT BETWEEN '2026-02-01' AND '2026-02-24'
)
SELECT '[' || COALESCE(R.GAME_TYPE_CD::VARCHAR, 'null') || ']'             AS GAME_TYPE,
       R.DELETE_IND,
       '[' || COALESCE(R.RATING_STATUS_CD::VARCHAR, 'null') || ']'         AS RATING_STATUS,
       COUNT(*)                                                            AS ROW_COUNT,
       COUNT_IF(L.SK IS NOT NULL)                                          AS ON_A_TRIP,
       COUNT_IF(O.GUEST_UNIQUE_ID IS NOT NULL)                             AS SAME_GUEST_DAY_IN_HETCMS,
       ROUND(SUM(R.THEO_WIN_AMT))                                          AS THEO,
       MIN(R.BUSINESS_DT)                                                  AS FIRST_PLAY_DAY,
       MAX(R.BUSINESS_DT)                                                  AS LAST_PLAY_DAY
FROM DAAS_PROD.DAAS_CORE_GAMING_VW.RATINGS_FACT_VW R
LEFT JOIN LINKS L ON L.SK = R.RATINGS_FACT_SK
LEFT JOIN OLD_SYSTEM O
       ON O.GUEST_UNIQUE_ID = R.GUEST_UNIQUE_ID
      AND O.BUSINESS_DT = R.BUSINESS_DT
WHERE R.PROPERTY_CD = 'WCL'
  AND R.SOURCE_SYSTEM_NM = 'HEXLITE-CMP'
  AND R.BUSINESS_DT < '2026-02-25'
GROUP BY 1, 2, 3
ORDER BY 1, 2, 3;
