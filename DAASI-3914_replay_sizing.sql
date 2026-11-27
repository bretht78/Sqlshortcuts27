-- =====================================================================================================
-- DAASI-3914  Missing WCL theo in DAILY_ACTIVITY_SUMMARY_VW                         sizing the replay
--
-- Read-only. What decides whether the replay goes in one batch, and what it will do to trips.
-- Run them one at a time. None depends on another. Each reads best as text.
--
-- The replay list is every live WCL rating loaded since 11/11 that trips should hold and that is not on
-- a trip today: a matched guest, not game code 95, game type S, O or P, not a void, and loaded at least
-- three hours ago so trips has had its turn. Last night that was about 193,000 ratings, nearly all of
-- them table play.
-- (Theo is the casino's expected win on a guest's play. A guest-day is one guest on one day of play.)
-- =====================================================================================================


-- 1. The list, month by month, with a total on the last line. PLAY_IN_LAST_3_DAYS shows how much of it
--    is very recent play, which can still be edited at the property and is best left to the catch-up.
WITH LINKS AS (
    SELECT DISTINCT TRANSACTION_TABLE_SK AS SK
    FROM DAAS_PROD.DAAS_CORE.TRIP_DETAIL
    WHERE TRANSACTION_TYPE = 'RATINGS'
      AND DELETE_IND = 'N'
      AND CREATED_DTTM >= '2026-11-11'
),
TO_REPLAY AS (
    SELECT R.RATINGS_FACT_SK,
           R.GUEST_UNIQUE_ID,
           R.BUSINESS_DT,
           R.GAME_TYPE_CD,
           R.THEO_WIN_AMT
    FROM DAAS_PROD.DAAS_CORE_GAMING_VW.RATINGS_FACT_VW R
    LEFT JOIN LINKS L ON L.SK = R.RATINGS_FACT_SK
    WHERE R.PROPERTY_CD = 'WCL'
      AND R.DELETE_IND = 'N'
      AND R.CREATED_DTTM >= '2026-11-11'
      AND R.CREATED_DTTM < DATEADD(hour, -3, CURRENT_TIMESTAMP()::TIMESTAMP_NTZ)
      AND R.GUEST_UNIQUE_ID <> 0
      AND IFNULL(R.GAME_CD, '') <> '95'
      AND CONTAINS('S,O,P', R.GAME_TYPE_CD)
      AND IFNULL(R.RATING_STATUS_CD, '') NOT IN ('V', 'E')
      AND L.SK IS NULL
)
SELECT DATE_TRUNC('MONTH', BUSINESS_DT)::DATE                              AS MONTH_START,
       COUNT(*)                                                            AS RATINGS,
       COUNT_IF(GAME_TYPE_CD = 'P')                                        AS TABLE_RATINGS,
       COUNT(DISTINCT GUEST_UNIQUE_ID)                                     AS GUESTS,
       COUNT(DISTINCT GUEST_UNIQUE_ID || '|' || BUSINESS_DT)               AS GUEST_DAYS,
       ROUND(SUM(THEO_WIN_AMT))                                            AS THEO,
       COUNT_IF(BUSINESS_DT >= DATEADD(day, -3, CURRENT_DATE()))           AS PLAY_IN_LAST_3_DAYS
FROM TO_REPLAY
GROUP BY ROLLUP (DATE_TRUNC('MONTH', BUSINESS_DT)::DATE)
ORDER BY 1 NULLS LAST;


-- 2. Where each guest-day will land. Last night's pilot only added links to a trip the guest already
--    had. Much of the full list is different: a guest whose only play that day was at the tables has no
--    trip there at all, so the replay will make trips build new ones or lengthen old ones, and then the
--    merge steps run. This counts how much of each. It is a first cut: each day is judged on its own
--    against the WCL property trips that exist now (trips there run 3 days at most, with a 1-day gap).
--      Mostly line 1 -> the replay is the pilot, many times over.
--      A large line 3 -> thousands of new trips. Still one batch, but worth a second small pilot first
--          that covers lines 2 and 3, and the validation should look at the trips themselves.
WITH LINKS AS (
    SELECT DISTINCT TRANSACTION_TABLE_SK AS SK
    FROM DAAS_PROD.DAAS_CORE.TRIP_DETAIL
    WHERE TRANSACTION_TYPE = 'RATINGS'
      AND DELETE_IND = 'N'
      AND CREATED_DTTM >= '2026-11-11'
),
TO_REPLAY AS (
    SELECT R.RATINGS_FACT_SK,
           R.GUEST_UNIQUE_ID,
           R.BUSINESS_DT,
           R.THEO_WIN_AMT
    FROM DAAS_PROD.DAAS_CORE_GAMING_VW.RATINGS_FACT_VW R
    LEFT JOIN LINKS L ON L.SK = R.RATINGS_FACT_SK
    WHERE R.PROPERTY_CD = 'WCL'
      AND R.DELETE_IND = 'N'
      AND R.CREATED_DTTM >= '2026-11-11'
      AND R.CREATED_DTTM < DATEADD(hour, -3, CURRENT_TIMESTAMP()::TIMESTAMP_NTZ)
      AND R.GUEST_UNIQUE_ID <> 0
      AND IFNULL(R.GAME_CD, '') <> '95'
      AND CONTAINS('S,O,P', R.GAME_TYPE_CD)
      AND IFNULL(R.RATING_STATUS_CD, '') NOT IN ('V', 'E')
      AND L.SK IS NULL
),
GUEST_DAYS AS (
    SELECT GUEST_UNIQUE_ID,
           BUSINESS_DT,
           COUNT(*)            AS RATINGS,
           SUM(THEO_WIN_AMT)   AS THEO
    FROM TO_REPLAY
    GROUP BY 1, 2
),
TRIPS AS (
    SELECT GUEST_UNIQUE_ID,
           TRIP_START_DT,
           TRIP_END_DT
    FROM DAAS_PROD.DAAS_CORE.TRIP_MASTER
    WHERE TRIP_TYPE = 'PROPERTY'
      AND PROPERTY_CD = 'WCL'
      AND DELETE_IND = 'N'
      AND TRIP_END_DT >= '2026-01-15'
),
PLACED AS (
    SELECT G.GUEST_UNIQUE_ID,
           G.BUSINESS_DT,
           G.RATINGS,
           G.THEO,
           MAX(IFF(G.BUSINESS_DT BETWEEN T.TRIP_START_DT AND T.TRIP_END_DT, 1, 0))             AS INSIDE,
           MAX(IFF(T.TRIP_END_DT < G.BUSINESS_DT
                   AND DATEDIFF(day, T.TRIP_END_DT, G.BUSINESS_DT) <= 1
                   AND DATEDIFF(day, T.TRIP_START_DT, G.BUSINESS_DT) + 1 <= 3, 1, 0))          AS NEXT_TO
    FROM GUEST_DAYS G
    LEFT JOIN TRIPS T
           ON T.GUEST_UNIQUE_ID = G.GUEST_UNIQUE_ID
          AND T.TRIP_START_DT <= G.BUSINESS_DT
          AND T.TRIP_END_DT >= DATEADD(day, -1, G.BUSINESS_DT)
    GROUP BY 1, 2, 3, 4
)
SELECT CASE WHEN INSIDE = 1 THEN '1 inside a trip the guest already has: links are added, as in the pilot'
            WHEN NEXT_TO = 1 THEN '2 the day after a trip: that trip is lengthened'
            ELSE '3 no trip there: a new trip is built'
       END                                     AS WHERE_IT_LANDS,
       COUNT(*)                                AS GUEST_DAYS,
       COUNT(DISTINCT GUEST_UNIQUE_ID)         AS GUESTS,
       SUM(RATINGS)                            AS RATINGS,
       ROUND(SUM(THEO))                        AS THEO
FROM PLACED
GROUP BY 1
ORDER BY 1;


-- 3a. What trips did with the 11/11 load. That load put 6.59 million ratings through in one go, 34 times
--     this replay, so it is the best measure of what one batch costs. Every trips step from the load to
--     the next morning that ran 10 minutes or longer, or did not succeed. Times are Snowflake's (Pacific).
--       Each step SUCCESS, with the rating and summary steps in minutes or a few hours -> one batch of
--           193,000 is comfortable.
--       A step that failed or was cut off -> send it over before we settle on one batch.
SELECT J.JOB_NAME,
       B.BATCH_ID,
       B.BATCH_STATUS,
       B.BATCH_START_DATE,
       B.UPDATED_DTTM,
       ROUND(DATEDIFF(second, B.BATCH_START_DATE, B.UPDATED_DTTM) / 60, 1)     AS MINUTES
FROM DAAS_PROD.DAAS_COMMON.BATCH_S02 B
JOIN DAAS_PROD.DAAS_COMMON.JOB J
  ON J.JOB_ID = B.JOB_ID
WHERE J.JOB_NAME LIKE 'TRIP%'
  AND B.BATCH_START_DATE >= '2026-11-11 15:30:00'
  AND B.BATCH_START_DATE <  '2026-11-12 08:00:00'
  AND (DATEDIFF(minute, B.BATCH_START_DATE, B.UPDATED_DTTM) >= 10
       OR NOT STARTSWITH(B.BATCH_STATUS, 'SUCCESS'))
ORDER BY B.BATCH_ID;

-- 3b. The rating step's own counts for its first two runs after that load: rows read, trips made, links
--     written. Whatever columns the metrics table has are shown as they are.
SELECT J.JOB_NAME,
       B.BATCH_START_DATE,
       B.UPDATED_DTTM,
       M.*
FROM DAAS_PROD.DAAS_COMMON.BATCH_S02 B
JOIN DAAS_PROD.DAAS_COMMON.JOB J
  ON J.JOB_ID = B.JOB_ID
JOIN DAAS_PROD.DAAS_COMMON.BATCH_METRICS_S02 M
  ON M.BATCH_ID = B.BATCH_ID
WHERE J.JOB_NAME = 'TRIP_RATING_DOMAIN_PIPELINE'
  AND B.BATCH_START_DATE >= '2026-11-11 15:30:00'
  AND B.BATCH_START_DATE <  '2026-11-12 08:00:00'
QUALIFY DENSE_RANK() OVER (ORDER BY B.BATCH_ID) <= 2
ORDER BY B.BATCH_ID;


-- 4. When is trips quietest? The last 14 days of runs, by the hour they started (Pacific: add two hours
--    for Central). A run longer than an hour makes the next start skip, as on Thursday night.
--    The replay call should go in a few minutes before a start that is usually short.
WITH STEPS AS (
    SELECT J.JOB_NAME,
           B.BATCH_ID,
           B.BATCH_START_DATE,
           B.UPDATED_DTTM
    FROM DAAS_PROD.DAAS_COMMON.BATCH_S02 B
    JOIN DAAS_PROD.DAAS_COMMON.JOB J
      ON J.JOB_ID = B.JOB_ID
    WHERE J.JOB_NAME LIKE 'TRIP%'
      AND J.JOB_NAME <> 'TRIP_INACTIVE_TXNS_ARCHIVAL'
      AND B.BATCH_START_DATE >= DATEADD(day, -14, CURRENT_TIMESTAMP()::TIMESTAMP_NTZ)
),
RUNS AS (
    SELECT S.*,
           MAX(IFF(JOB_NAME = 'TRIP_FILTERED_TXNS', BATCH_START_DATE, NULL))
               OVER (ORDER BY BATCH_START_DATE, BATCH_ID ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS RUN_START
    FROM STEPS S
),
PER_RUN AS (
    SELECT RUN_START,
           DATEDIFF(second, RUN_START, MAX(UPDATED_DTTM)) / 60                                             AS RUN_MINUTES,
           SUM(IFF(JOB_NAME = 'TRIP_SUMMARY_WRAPPER', DATEDIFF(second, BATCH_START_DATE, UPDATED_DTTM), 0)) / 60 AS SUMMARY_MINUTES
    FROM RUNS
    WHERE RUN_START IS NOT NULL
    GROUP BY 1
)
SELECT HOUR(RUN_START)                         AS START_HOUR_PACIFIC,
       COUNT(*)                                AS RUNS,
       ROUND(AVG(RUN_MINUTES))                 AS USUAL_MINUTES,
       ROUND(MAX(RUN_MINUTES))                 AS LONGEST_MINUTES,
       COUNT_IF(RUN_MINUTES > 60)              AS RUNS_OVER_AN_HOUR,
       ROUND(AVG(SUMMARY_MINUTES))             AS USUAL_SUMMARY_MINUTES,
       COUNT_IF(DAYNAME(RUN_START) = 'Sun')    AS OF_THOSE_ON_SUNDAY,
       ROUND(AVG(IFF(DAYNAME(RUN_START) = 'Sun', RUN_MINUTES, NULL)))      AS USUAL_MINUTES_SUNDAY
FROM PER_RUN
GROUP BY 1
ORDER BY 1;
