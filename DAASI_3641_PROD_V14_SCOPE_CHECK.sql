-- DAASI-3641: what the PROD replay has to touch, checked before anything is replayed. Read-only: four SELECTs.
--
-- Why this file. The plan of 11 Nov replayed every rating on the over-cap trips: 12,072,257 rows of RATINGS_FACT.
-- Read again on 12 Nov, PROD's own code says that replay would not put those trips in front of the fix:
--   * v1.4 is in merge check, and merge check only looks at trips whose TRIP_MASTER row has changed (its stream is on
--     TRIP_MASTER).
--   * The ratings step re-stamps a replayed rating's TRIP_DETAIL rows, but it rewrites a trip's TRIP_MASTER row only
--     when the rating lands after the trip's end date and extends it. A rating that already sits inside its trip's
--     dates leaves the trip row alone. The other steps that feed trips (hotel, POS, offers, comps, markers, free
--     play) work the same way: a transaction that does not move a trip's end date does not rewrite the trip row.
-- So what has to be replayed is the trip rows themselves, not their ratings. S1 to S3 check that against PROD;
-- S4 counts the rows of the smaller replay. Until S3 is back, the UPDATEs of DAASI_3641_PROD_V14_REPLAY.sql (R3-C, R3,
-- R3-L, R3-Z) should not be run.
--
--   S1  the three pieces of code this rests on, as they are live today (Pete changed the trips pipeline on 11 Nov)
--   S2  the big ratings replays of 2026 in the pipeline's own batch log: ratings read against trip rows rewritten
--   S3  the over-cap trips as they stand: what the August replay did to their ratings, and to the trip rows
--   S4  the rows the smaller replay touches, next to the 11 Nov plan
--
-- S3 and S4 read TRIP_DETAIL: a few minutes each on a Large warehouse. Run each statement on its own.

USE ROLE DAAS_TEAM;
USE SECONDARY ROLES ALL;


-- S1. The live code. Expect 'yes' on all three rows. A 'NO' on row 1 means v1.4 is no longer what PROD runs (a later
--     deploy replaced it); a 'NO' on row 2 or 3 means that code has changed since I read it: send me its GET_DDL.
WITH code AS (
    SELECT 1 AS n, 'merge check' AS step,
           REPLACE(REGEXP_REPLACE(UPPER(GET_DDL('PROCEDURE', 'DAAS_PROD.DAAS_COMMON.TRIP_MERGE_CHECK_PROC(FLOAT, VARCHAR, VARCHAR, VARCHAR, VARCHAR)')), '\\s', ''), '''', '') AS txt
    UNION ALL
    SELECT 2, 'ratings step',
           REPLACE(REGEXP_REPLACE(UPPER(GET_DDL('PROCEDURE', 'DAAS_PROD.DAAS_COMMON.TRIP_RATING_DOMAIN_PIPELINE_PROC(FLOAT, VARCHAR, VARCHAR, VARCHAR, VARCHAR)')), '\\s', ''), '''', '')
    UNION ALL
    SELECT 3, 'trip identifier',
           REPLACE(REGEXP_REPLACE(UPPER(GET_DDL('PROCEDURE', 'DAAS_PROD.DAAS_COMMON.TRIP_IDENTIFIER_PROC(FLOAT, VARCHAR, VARCHAR, VARCHAR, VARCHAR)')), '\\s', ''), '''', '')
)
SELECT n, step,
       CASE n WHEN 1 THEN 'v1.4 is live, and it reads the stream on TRIP_MASTER'
              WHEN 2 THEN 'its statement 11 rewrites a TRIP_MASTER row only when the rating brings a new end date'
              WHEN 3 THEN 'a rating inside its trip''s dates comes back with the trip id and no new end date'
       END AS what_the_plan_rests_on,
       IFF(CASE n WHEN 1 THEN CONTAINS(txt, 'MY_SQL_COMMAND_3A') AND CONTAINS(txt, 'FROMDAAS_TEMP.TRIP_MASTER_TRIP_MERGE_CHECK_STREAM')
                  WHEN 2 THEN CONTAINS(txt, 'ANDLENGTH(SPLIT_PART(TRIP_INDICATOR,|,3))>0`;STATEMENT11=')
                  WHEN 3 THEN CONTAINS(txt, 'BETWEENTRIP_MASTER.TRIP_START_DTANDTRIP_END_DTTHENY|||||TRIP_MASTER.TRIP_MASTER_ID|||WHEN')
           END, 'yes', 'NO') AS still_so_in_prod
FROM code
ORDER BY n;


-- S2. The twelve runs of the ratings step that read the most ratings this year: the April and August replays. For
--     each, the pipeline's own counts: ratings read, TRIP_DETAIL rows it re-stamped, TRIP_MASTER rows it rewrote.
--     Expect ratings_read and trip_detail_rows_restamped in the millions on the replay runs, and
--     trip_master_rows_rewritten a small fraction of them. everything_logged shows the counts under the names the
--     log uses, in case a column comes back empty. (If this one errors on a column name, skip it: S3 is the proof.)
SELECT *
FROM (
    SELECT b.BATCH_ID,
           b.BATCH_START_DATE                                                                                AS started_pacific,
           b.BATCH_STATUS,
           ROUND(DATEDIFF(second, b.BATCH_START_DATE, COALESCE(b.BATCH_END_DATE, b.UPDATED_DTTM)) / 60, 1)   AS minutes,
           MAX(IFF(m.BATCH_METRIC_CD ILIKE '%SOURCE%',        TRY_TO_DOUBLE(TO_VARCHAR(m.BATCH_METRIC_VALUE)), NULL))::NUMBER(38,0) AS ratings_read,
           MAX(IFF(m.BATCH_METRIC_CD ILIKE '%DETAIL%UPDATE%', TRY_TO_DOUBLE(TO_VARCHAR(m.BATCH_METRIC_VALUE)), NULL))::NUMBER(38,0) AS trip_detail_rows_restamped,
           MAX(IFF(m.BATCH_METRIC_CD ILIKE '%MASTER%UPDATE%', TRY_TO_DOUBLE(TO_VARCHAR(m.BATCH_METRIC_VALUE)), NULL))::NUMBER(38,0) AS trip_master_rows_rewritten,
           MAX(IFF(m.BATCH_METRIC_CD ILIKE '%MASTER%INSERT%', TRY_TO_DOUBLE(TO_VARCHAR(m.BATCH_METRIC_VALUE)), NULL))::NUMBER(38,0) AS new_trips_built,
           LISTAGG(DISTINCT m.BATCH_METRIC_CD || '=' || TO_VARCHAR(m.BATCH_METRIC_VALUE), ', ')              AS everything_logged
    FROM DAAS_PROD.DAAS_COMMON.BATCH_S02 b
    JOIN DAAS_PROD.DAAS_COMMON.JOB j ON j.JOB_ID = b.JOB_ID
    JOIN DAAS_PROD.DAAS_COMMON.BATCH_METRICS_S02 m ON m.BATCH_ID = b.BATCH_ID
    WHERE j.JOB_NAME = 'TRIP_RATING_DOMAIN_PIPELINE'
      AND b.BATCH_START_DATE >= '2026-01-01'
    GROUP BY b.BATCH_ID, b.BATCH_START_DATE, b.BATCH_STATUS, b.BATCH_END_DATE, b.UPDATED_DTTM
)
ORDER BY ratings_read DESC NULLS LAST
LIMIT 12;


-- S3. The over-cap trips as they stand today (the same trips as the replay file: live BEM/WLM market trips longer
--     than their cap with no hotel night). The August replay (DAASI-3376, from 12 Aug 2026) replayed every IBE and IWA
--     rating, so it went over these trips' ratings. For the trips that existed then:
--       of_those_with_ratings_restamped_since   trips holding a rating row the pipeline has re-stamped since 12 Aug
--       of_those_with_the_trip_row_rewritten    trips whose own TRIP_MASTER row has been rewritten since 12 Aug
--     Expect the first close to built_before_the_august_replay and the second a small fraction of it: the replay
--     reached the ratings and not the trip rows, which is why merge check never saw these trips, and would not see
--     them on another replay of their ratings. If the second is close to the first instead, I am wrong about this
--     and the ratings route does reach the trips: send me the result before anything else.
WITH ent AS (
    SELECT MAX(VALUE) AS MAX_TRIP_DAYS
    FROM DAAS_PROD.DAAS_CORE.TRIP_CONFIG
    WHERE CONFIG_SUBTYPE = 'ENTERPRISE' AND KEY = 'MAX_TRIP_DAYS' AND ACTIVE_FLG = 'Y'
),
multi AS (
    SELECT TRIP_MASTER_ID, MARKET_CD, TRIP_START_DT, TRIP_END_DT - TRIP_START_DT + 1 AS TRIP_DAYS, CREATED_DTTM, UPDATED_DTTM
    FROM DAAS_PROD.DAAS_CORE.TRIP_MASTER
    WHERE DELETE_IND = 'N' AND TRIP_TYPE = 'MARKET' AND MARKET_CD IN ('BEM', 'WLM') AND TRIP_END_DT > TRIP_START_DT
),
caps AS (
    SELECT MARKET_CD, TRIP_START_DT,
           DAAS_PROD.DAAS_COMMON.TRIP_CONFIG_UDF_MARKET('MAX_TRIP_DAYS', MARKET_CD, TRIP_START_DT) AS CAP
    FROM (SELECT DISTINCT MARKET_CD, TRIP_START_DT FROM multi)
),
targets AS (    /* live BEM/WLM market trips over their cap with no hotel night */
    SELECT m.TRIP_MASTER_ID, m.MARKET_CD, m.CREATED_DTTM, m.UPDATED_DTTM
    FROM multi m
    JOIN caps c ON c.MARKET_CD = m.MARKET_CD AND c.TRIP_START_DT = m.TRIP_START_DT
    CROSS JOIN ent e
    WHERE m.TRIP_DAYS > COALESCE(TRY_TO_NUMBER(c.CAP), TRY_TO_NUMBER(e.MAX_TRIP_DAYS))
      AND NOT EXISTS (SELECT 1 FROM DAAS_PROD.DAAS_CORE.TRIP_DETAIL d
                      WHERE d.TRIP_MASTER_ID = m.TRIP_MASTER_ID AND d.DELETE_IND = 'N' AND d.TRANSACTION_TYPE = 'HOTEL')
),
ratings AS (    /* their live rating rows, and how many of them the pipeline has re-stamped since 12 Aug */
    SELECT d.TRIP_MASTER_ID,
           COUNT(*)                                                             AS RATING_ROWS,
           COUNT_IF(d.LAST_DML_CD = 'U' AND d.UPDATED_DTTM >= '2026-08-12')     AS RESTAMPED
    FROM DAAS_PROD.DAAS_CORE.TRIP_DETAIL d
    JOIN targets t ON t.TRIP_MASTER_ID = d.TRIP_MASTER_ID
    WHERE d.TRANSACTION_TABLE = 'RATINGS_FACT' AND d.DELETE_IND = 'N' AND d.TRANSACTION_SUB_TYPE = 'OPENED'
    GROUP BY d.TRIP_MASTER_ID
)
SELECT t.MARKET_CD,
       COUNT(*)                                                                         AS over_cap_trips_today,
       COUNT_IF(t.CREATED_DTTM < '2026-08-12')                                          AS built_before_the_august_replay,
       COUNT_IF(t.CREATED_DTTM < '2026-08-12' AND r.RESTAMPED > 0)                      AS of_those_with_ratings_restamped_since,
       COUNT_IF(t.CREATED_DTTM < '2026-08-12' AND t.UPDATED_DTTM >= '2026-08-12')       AS of_those_with_the_trip_row_rewritten,
       SUM(IFF(t.CREATED_DTTM < '2026-08-12', COALESCE(r.RATING_ROWS, 0), 0))           AS their_rating_rows,
       SUM(IFF(t.CREATED_DTTM < '2026-08-12', COALESCE(r.RESTAMPED, 0), 0))             AS rating_rows_restamped_since
FROM targets t
LEFT JOIN ratings r ON r.TRIP_MASTER_ID = t.TRIP_MASTER_ID
GROUP BY t.MARKET_CD
ORDER BY t.MARKET_CD;


-- S4. The rows the smaller replay touches, next to the 11 Nov plan. Two kinds of row, both on the trip tables:
--       trip_master_rows_to_replay   the over-cap trips themselves, one row each: this is what puts them in front of v1.4
--       trip_detail_rows_to_mark     one rating row for each property trip and day that shares a rating with them, so
--                                    the summary step has the property trip in the same run and comp worth (the comp
--                                    dollars the play earns) is valued on the new market trips, as in the UAT tests
--     and no RATINGS_FACT row at all. Expect trip_master_rows_to_replay near 378,800 (the 377,172 trips the old plan
--     reached and the 1,633 it could not), marks_on_property_trips_with_no_summary_row 0, and
--     ratings_fact_rows_in_the_11_nov_plan near 12,072,257.
WITH ent AS (
    SELECT MAX(VALUE) AS MAX_TRIP_DAYS
    FROM DAAS_PROD.DAAS_CORE.TRIP_CONFIG
    WHERE CONFIG_SUBTYPE = 'ENTERPRISE' AND KEY = 'MAX_TRIP_DAYS' AND ACTIVE_FLG = 'Y'
),
multi AS (
    SELECT TRIP_MASTER_ID, MARKET_CD, TRIP_START_DT, TRIP_END_DT - TRIP_START_DT + 1 AS TRIP_DAYS
    FROM DAAS_PROD.DAAS_CORE.TRIP_MASTER
    WHERE DELETE_IND = 'N' AND TRIP_TYPE = 'MARKET' AND MARKET_CD IN ('BEM', 'WLM') AND TRIP_END_DT > TRIP_START_DT
),
caps AS (
    SELECT MARKET_CD, TRIP_START_DT,
           DAAS_PROD.DAAS_COMMON.TRIP_CONFIG_UDF_MARKET('MAX_TRIP_DAYS', MARKET_CD, TRIP_START_DT) AS CAP
    FROM (SELECT DISTINCT MARKET_CD, TRIP_START_DT FROM multi)
),
targets AS (    /* live BEM/WLM market trips over their cap with no hotel night */
    SELECT m.TRIP_MASTER_ID
    FROM multi m
    JOIN caps c ON c.MARKET_CD = m.MARKET_CD AND c.TRIP_START_DT = m.TRIP_START_DT
    CROSS JOIN ent e
    WHERE m.TRIP_DAYS > COALESCE(TRY_TO_NUMBER(c.CAP), TRY_TO_NUMBER(e.MAX_TRIP_DAYS))
      AND NOT EXISTS (SELECT 1 FROM DAAS_PROD.DAAS_CORE.TRIP_DETAIL d
                      WHERE d.TRIP_MASTER_ID = m.TRIP_MASTER_ID AND d.DELETE_IND = 'N' AND d.TRANSACTION_TYPE = 'HOTEL')
),
on_them AS (    /* every live rating row on those trips: what the 11 Nov plan replayed */
    SELECT d.TRIP_MASTER_ID, d.TRANSACTION_TABLE_SK
    FROM DAAS_PROD.DAAS_CORE.TRIP_DETAIL d
    JOIN targets t ON t.TRIP_MASTER_ID = d.TRIP_MASTER_ID
    WHERE d.TRANSACTION_TABLE = 'RATINGS_FACT' AND d.DELETE_IND = 'N' AND d.TRANSACTION_SUB_TYPE = 'OPENED'
),
marks AS (      /* the same ratings where they sit on a live property trip: one row for each property trip and day */
    SELECT pd.TRIP_MASTER_ID, pd.BUSINESS_START_DT, MIN(pd.TRIP_DETAIL_ID) AS TRIP_DETAIL_ID
    FROM DAAS_PROD.DAAS_CORE.TRIP_DETAIL pd
    JOIN DAAS_PROD.DAAS_CORE.TRIP_MASTER p ON p.TRIP_MASTER_ID = pd.TRIP_MASTER_ID
    WHERE pd.TRANSACTION_TABLE = 'RATINGS_FACT' AND pd.DELETE_IND = 'N' AND pd.TRANSACTION_SUB_TYPE = 'OPENED'
      AND p.TRIP_TYPE = 'PROPERTY' AND p.DELETE_IND = 'N'
      AND pd.TRANSACTION_TABLE_SK IN (SELECT TRANSACTION_TABLE_SK FROM on_them)
    GROUP BY pd.TRIP_MASTER_ID, pd.BUSINESS_START_DT
),
t_count AS (SELECT COUNT(*) AS TRIPS FROM targets),
o_count AS (SELECT COUNT(DISTINCT TRIP_MASTER_ID) AS TRIPS_WITH_A_RATING, COUNT(DISTINCT TRANSACTION_TABLE_SK) AS RATINGS FROM on_them),
m_count AS (
    SELECT COUNT(*) AS MARKS, COUNT(DISTINCT m.TRIP_MASTER_ID) AS PROPERTY_TRIPS, COUNT_IF(s.TRIP_MASTER_ID IS NULL) AS NO_SUMMARY_ROW
    FROM marks m
    LEFT JOIN (SELECT DISTINCT TRIP_MASTER_ID FROM DAAS_PROD.DAAS_CORE.TRIP_SUMMARY) s ON s.TRIP_MASTER_ID = m.TRIP_MASTER_ID
)
SELECT t.TRIPS                         AS trip_master_rows_to_replay,
       o.TRIPS_WITH_A_RATING           AS of_them_holding_a_rating,
       m.MARKS                         AS trip_detail_rows_to_mark,
       m.PROPERTY_TRIPS                AS on_this_many_property_trips,
       m.NO_SUMMARY_ROW                AS marks_on_property_trips_with_no_summary_row,
       t.TRIPS + m.MARKS               AS all_rows_the_smaller_replay_touches,
       0                               AS ratings_fact_rows_in_the_smaller_replay,
       o.RATINGS                       AS ratings_fact_rows_in_the_11_nov_plan
FROM t_count t
CROSS JOIN o_count o
CROSS JOIN m_count m;
