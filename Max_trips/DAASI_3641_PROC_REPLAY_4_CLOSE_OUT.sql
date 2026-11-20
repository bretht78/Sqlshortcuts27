-- DAASI-3641: closing out the replay. Read-only checks, and one small repair call (statement 5, the only write).
--
-- Where it stands (20 Nov, the nine final checks):
--   clean     no trip is over its cap (PC6, PC7, PC1); of 13,484,294 transaction-nights on the 380,291 retired trips
--             none is lost or on a trip of the wrong dates, and the 1,852 that sit on two trips did so before (PC2,
--             PC2b); the trips' summaries hold exactly the theo of their ratings (PC3, summary_difference 0.00)
--   to open   PC3's theo_difference is 27,815.00 in BEM and 8,448.24 in WLM, not 0.00. Statement 1 takes it apart.
--   to open   PC5 counts 967 summary rows and 990 daily rows of 887,563 property trips with a figure that differs,
--             and 13 changes of the most-played denomination that are not ties. Statement 2 says which figures.
--   to repair PC4d lists three WLM market trips valued at 0.00 comp worth (the comp dollars the play earns) whose
--             property trips are worth 10.99, 2.53 and 59.97. The comp worth step values a market trip only from
--             property trips that are in the same run, and a trip valued without them comes out at 0. Two of the
--             three were built by an ordinary hourly run on 17 Nov, one in the run of 15 Nov that carried batch 6.
--             Statements 4 and 5 put them right; statement 6 confirms it.
--   to read   PC4d's fourth trip, in BEM (250.37 against 324.77), was last valued on 12 Aug and the replay did not
--             re-cut it. Statement 3 shows whether its property trips were worth the same before the replay.
--
-- Run each statement on its own, on the Large warehouse, and send me what it returns.

USE ROLE DAAS_TEAM;
USE SECONDARY ROLES ALL;


-- 1. PC3b (read-only): PC3's theo_difference, rating by rating. A rating adds to it when it has more than one live row
--    on market trips of its market. of_them_counted_as_often_before are the ratings recorded under two guests, which
--    counted on both guests' trips before the replay as after it. Expect theo_difference as PC3 gave it,
--    counted_more_often_now_than_before 0, live_but_on_no_market_trip 0 and difference_left_unexplained 0.00.
WITH gone AS (       /* the BEM/WLM market trips that were live in the before-picture and are retired now (or retired and since archived) */
    SELECT b.TRIP_MASTER_ID, b.MARKET_CD
    FROM DAAS_PROD.DAAS_TEMP_WORK.DAASI_3641_BEFORE_TRIP_MASTER b
    LEFT JOIN DAAS_PROD.DAAS_CORE.TRIP_MASTER m ON m.TRIP_MASTER_ID = b.TRIP_MASTER_ID
    WHERE b.TRIP_TYPE = 'MARKET' AND b.MARKET_CD IN ('BEM', 'WLM') AND b.DELETE_IND = 'N'
      AND (m.TRIP_MASTER_ID IS NULL OR m.DELETE_IND = 'Y')
),
held_before AS (        /* the live ratings on those trips in the before-picture, one row per trip and rating, as their summaries counted them */
    SELECT g.MARKET_CD, d.TRANSACTION_TABLE_SK AS SK
    FROM gone g
    JOIN DAAS_PROD.DAAS_TEMP_WORK.DAASI_3641_BEFORE_TRIP_DETAIL d ON d.TRIP_MASTER_ID = g.TRIP_MASTER_ID
    WHERE d.TRANSACTION_TYPE = 'RATINGS' AND d.DELETE_IND = 'N' AND d.TRANSACTION_SUB_TYPE = 'OPENED'
),
keys AS (       /* each of those ratings once, valued from RATINGS_FACT as it stands today, the way the summary step adds theo up */
    SELECT h.MARKET_CD, h.SK, COUNT(*) AS TIMES_BEFORE, MAX(IFF(f.GAME_TYPE_CD IN ('S', 'P', 'O'), f.THEO_WIN_AMT, 0)) AS THEO
    FROM held_before h
    JOIN DAAS_PROD.DAAS_CORE.RATINGS_FACT f ON f.RATINGS_FACT_SK = h.SK
    GROUP BY h.MARKET_CD, h.SK
),
live AS (       /* every live row of those ratings now, with the trip it sits on */
    SELECT k.MARKET_CD, k.SK, m.TRIP_MASTER_ID,
           IFF(m.TRIP_TYPE = 'MARKET' AND m.MARKET_CD = k.MARKET_CD, 1, 0) AS ON_ITS_MARKET
    FROM keys k
    JOIN DAAS_PROD.DAAS_CORE.TRIP_DETAIL d ON d.TRANSACTION_TABLE_SK = k.SK AND d.TRANSACTION_TYPE = 'RATINGS' AND d.DELETE_IND = 'N'
    JOIN DAAS_PROD.DAAS_CORE.TRIP_MASTER m ON m.TRIP_MASTER_ID = d.TRIP_MASTER_ID AND m.DELETE_IND = 'N'
),
per_key AS (    /* each rating as PC3 has it (MARKET_ROWS: its live rows on live market trips of its market), with the trips and guests those are */
    SELECT k.MARKET_CD, k.SK, k.THEO,
           COUNT(l.SK)                                                          AS LIVE_ROWS,
           COALESCE(SUM(l.ON_ITS_MARKET), 0)                                    AS MARKET_ROWS,
           COUNT(DISTINCT IFF(l.ON_ITS_MARKET = 1, m.GUEST_UNIQUE_ID, NULL))    AS GUESTS,
           MAX(IFF(l.ON_ITS_MARKET = 1 AND m.GUEST_UNIQUE_ID = -1, 1, 0))       AS WITH_GUEST_MINUS_1
    FROM keys k
    LEFT JOIN live l ON l.MARKET_CD = k.MARKET_CD AND l.SK = k.SK
    LEFT JOIN DAAS_PROD.DAAS_CORE.TRIP_MASTER m ON m.TRIP_MASTER_ID = l.TRIP_MASTER_ID
    GROUP BY k.MARKET_CD, k.SK, k.THEO
),
was AS (        /* the same ratings in the before-picture: their live rows on live market trips of their market then */
    SELECT k.MARKET_CD, k.SK, COUNT(*) AS ROWS_BEFORE
    FROM keys k
    JOIN DAAS_PROD.DAAS_TEMP_WORK.DAASI_3641_BEFORE_TRIP_DETAIL d ON d.TRANSACTION_TABLE_SK = k.SK AND d.TRANSACTION_TYPE = 'RATINGS' AND d.DELETE_IND = 'N'
    JOIN DAAS_PROD.DAAS_TEMP_WORK.DAASI_3641_BEFORE_TRIP_MASTER m ON m.TRIP_MASTER_ID = d.TRIP_MASTER_ID AND m.DELETE_IND = 'N'
    WHERE m.TRIP_TYPE = 'MARKET' AND m.MARKET_CD = k.MARKET_CD
    GROUP BY k.MARKET_CD, k.SK
),
judged AS (     /* EXTRA: what the rating adds to theo_difference. AS_BEFORE 1: it had as many such rows in the before-picture */
    SELECT p.MARKET_CD, p.THEO, p.MARKET_ROWS, p.GUESTS, p.WITH_GUEST_MINUS_1,
           p.THEO * (p.MARKET_ROWS - IFF(p.LIVE_ROWS > 0, 1, 0))       AS EXTRA,
           IFF(COALESCE(w.ROWS_BEFORE, 0) >= p.MARKET_ROWS, 1, 0)      AS AS_BEFORE,
           IFF(p.LIVE_ROWS > 0 AND p.MARKET_ROWS = 0, 1, 0)            AS ON_NO_MARKET_TRIP
    FROM per_key p
    LEFT JOIN was w ON w.MARKET_CD = p.MARKET_CD AND w.SK = p.SK
)
SELECT MARKET_CD                                                                        AS market,
       ROUND(SUM(EXTRA), 2)                                                             AS theo_difference,
       COUNT_IF(MARKET_ROWS > 1)                                                        AS ratings_counted_more_than_once_now,
       COUNT_IF(MARKET_ROWS > 1 AND AS_BEFORE = 1)                                      AS of_them_counted_as_often_before,
       ROUND(SUM(IFF(MARKET_ROWS > 1 AND AS_BEFORE = 1, EXTRA, 0)), 2)                  AS their_part_of_the_difference,
       COUNT_IF(MARKET_ROWS > 1 AND AS_BEFORE = 1 AND GUESTS > 1)                       AS of_them_on_trips_of_different_guests,
       COUNT_IF(MARKET_ROWS > 1 AND AS_BEFORE = 1 AND WITH_GUEST_MINUS_1 = 1)           AS of_them_one_is_guest_minus_1,
       COUNT_IF(MARKET_ROWS > 1 AND AS_BEFORE = 0)                                      AS counted_more_often_now_than_before,
       COUNT_IF(ON_NO_MARKET_TRIP = 1)                                                  AS live_but_on_no_market_trip,
       ROUND(SUM(IFF(MARKET_ROWS > 1 AND AS_BEFORE = 1, 0, EXTRA)), 2)                  AS difference_left_unexplained
FROM judged
GROUP BY MARKET_CD
ORDER BY MARKET_CD;


-- 2. PC5b (read-only; as long as PC5): PC5's rows 5, 6 and 10 opened up. One line per table and column that differs:
--    how many rows, how many trips, how many of those trips the pipeline itself has written to since the
--    before-pictures (ordinary activity, not the replay), the net change where the column is a number, and an
--    example. Then one line for each change of the most-played denomination that is not a tie, with the
--    denominations most played by the trip's ratings today. Send me every row (download it if it is long).
WITH gone AS (       /* the BEM/WLM market trips that were live in the before-picture and are retired now (or retired and since archived) */
    SELECT b.TRIP_MASTER_ID, b.MARKET_CD
    FROM DAAS_PROD.DAAS_TEMP_WORK.DAASI_3641_BEFORE_TRIP_MASTER b
    LEFT JOIN DAAS_PROD.DAAS_CORE.TRIP_MASTER m ON m.TRIP_MASTER_ID = b.TRIP_MASTER_ID
    WHERE b.TRIP_TYPE = 'MARKET' AND b.MARKET_CD IN ('BEM', 'WLM') AND b.DELETE_IND = 'N'
      AND (m.TRIP_MASTER_ID IS NULL OR m.DELETE_IND = 'Y')
),
pt AS (         /* the property trips that held, live, a rating of one of those trips in the before-picture */
    SELECT DISTINCT p.TRIP_MASTER_ID
    FROM gone g
    JOIN DAAS_PROD.DAAS_TEMP_WORK.DAASI_3641_BEFORE_TRIP_DETAIL d  ON d.TRIP_MASTER_ID = g.TRIP_MASTER_ID
    JOIN DAAS_PROD.DAAS_TEMP_WORK.DAASI_3641_BEFORE_TRIP_DETAIL pd ON pd.TRANSACTION_TABLE_SK = d.TRANSACTION_TABLE_SK
    JOIN DAAS_PROD.DAAS_TEMP_WORK.DAASI_3641_BEFORE_TRIP_MASTER p  ON p.TRIP_MASTER_ID = pd.TRIP_MASTER_ID
    WHERE d.TRANSACTION_TABLE = 'RATINGS_FACT' AND d.TRANSACTION_SUB_TYPE = 'OPENED'
      AND pd.TRANSACTION_TABLE = 'RATINGS_FACT' AND pd.DELETE_IND = 'N' AND pd.TRANSACTION_SUB_TYPE = 'OPENED'
      AND p.TRIP_TYPE = 'PROPERTY' AND p.DELETE_IND = 'N'
),
tm_b AS (SELECT * FROM DAAS_PROD.DAAS_TEMP_WORK.DAASI_3641_BEFORE_TRIP_MASTER WHERE TRIP_MASTER_ID IN (SELECT TRIP_MASTER_ID FROM pt)),
tm_n AS (SELECT * FROM DAAS_PROD.DAAS_CORE.TRIP_MASTER WHERE TRIP_MASTER_ID IN (SELECT TRIP_MASTER_ID FROM pt)),
td_b AS (SELECT * FROM DAAS_PROD.DAAS_TEMP_WORK.DAASI_3641_BEFORE_TRIP_DETAIL WHERE TRIP_MASTER_ID IN (SELECT TRIP_MASTER_ID FROM pt)),
td_n AS (SELECT * FROM DAAS_PROD.DAAS_CORE.TRIP_DETAIL WHERE TRIP_MASTER_ID IN (SELECT TRIP_MASTER_ID FROM pt)),
marked AS (
    SELECT n.TRIP_DETAIL_ID
    FROM td_n n
    JOIN td_b o ON o.TRIP_DETAIL_ID = n.TRIP_DETAIL_ID
    WHERE COALESCE(n.REPLAY_COUNTER, 0) > COALESCE(o.REPLAY_COUNTER, 0)
),
tdx_b AS (SELECT * EXCLUDE (REPLAY_COUNTER, UPDATED_DTTM, UPDATED_BY, LAST_DML_CD) FROM td_b),
tdx_n AS (SELECT * EXCLUDE (REPLAY_COUNTER, UPDATED_DTTM, UPDATED_BY, LAST_DML_CD) FROM td_n),
busy AS (       /* the trip's own row is not what it was, or a transaction row was added, removed or changed
                   in any column other than the three the TRIP_DETAIL call sets (LAST_DML_CD is left out with them) */
    SELECT TRIP_MASTER_ID FROM (SELECT * FROM tm_b MINUS SELECT * FROM tm_n)
    UNION
    SELECT TRIP_MASTER_ID FROM (SELECT * FROM tdx_b MINUS SELECT * FROM tdx_n)
    UNION
    SELECT TRIP_MASTER_ID FROM (SELECT * FROM tdx_n MINUS SELECT * FROM tdx_b)
),
quiet AS (SELECT TRIP_MASTER_ID FROM pt WHERE TRIP_MASTER_ID NOT IN (SELECT TRIP_MASTER_ID FROM busy)),
ts_b AS (
    SELECT * EXCLUDE (LAST_DML_CD, UPDATED_DTTM, UPDATED_BY, BATCH_ID, MOST_PLAYED_DENOM_AMT, COMP_WORTH)
    FROM DAAS_PROD.DAAS_TEMP_WORK.DAASI_3641_BEFORE_TRIP_SUMMARY
    WHERE TRIP_MASTER_ID IN (SELECT TRIP_MASTER_ID FROM quiet)
),
ts_n AS (
    SELECT * EXCLUDE (LAST_DML_CD, UPDATED_DTTM, UPDATED_BY, BATCH_ID, MOST_PLAYED_DENOM_AMT, COMP_WORTH)
    FROM DAAS_PROD.DAAS_CORE.TRIP_SUMMARY
    WHERE TRIP_MASTER_ID IN (SELECT TRIP_MASTER_ID FROM quiet)
),
das_b AS (
    SELECT * EXCLUDE (LAST_DML_CD, UPDATED_DTTM, UPDATED_BY, BATCH_ID, MOST_PLAYED_DENOM_AMT, COMP_WORTH)
    FROM DAAS_PROD.DAAS_TEMP_WORK.DAASI_3641_BEFORE_DAILY_ACTIVITY_SUMMARY
    WHERE TRIP_MASTER_ID IN (SELECT TRIP_MASTER_ID FROM quiet)
),
das_n AS (
    SELECT * EXCLUDE (LAST_DML_CD, UPDATED_DTTM, UPDATED_BY, BATCH_ID, MOST_PLAYED_DENOM_AMT, COMP_WORTH)
    FROM DAAS_PROD.DAAS_CORE.DAILY_ACTIVITY_SUMMARY
    WHERE TRIP_MASTER_ID IN (SELECT TRIP_MASTER_ID FROM quiet)
),
cw AS (         /* comp worth, to the cent: the summary row (S) and the daily rows (D) */
    SELECT o.TRIP_MASTER_ID, 'S' AS LVL, ABS(COALESCE(n.COMP_WORTH, 0) - COALESCE(o.COMP_WORTH, 0)) AS CHANGE
    FROM DAAS_PROD.DAAS_TEMP_WORK.DAASI_3641_BEFORE_TRIP_SUMMARY o
    JOIN DAAS_PROD.DAAS_CORE.TRIP_SUMMARY n ON n.TRIP_MASTER_ID = o.TRIP_MASTER_ID
    WHERE o.TRIP_MASTER_ID IN (SELECT TRIP_MASTER_ID FROM quiet)
      AND ROUND(COALESCE(o.COMP_WORTH, 0), 2) <> ROUND(COALESCE(n.COMP_WORTH, 0), 2)
    UNION ALL
    SELECT o.TRIP_MASTER_ID, 'D', 0
    FROM DAAS_PROD.DAAS_TEMP_WORK.DAASI_3641_BEFORE_DAILY_ACTIVITY_SUMMARY o
    JOIN DAAS_PROD.DAAS_CORE.DAILY_ACTIVITY_SUMMARY n ON n.TRIP_MASTER_ID = o.TRIP_MASTER_ID AND n.GUEST_ACTIVITY_DATE = o.GUEST_ACTIVITY_DATE
    WHERE o.TRIP_MASTER_ID IN (SELECT TRIP_MASTER_ID FROM quiet)
      AND ROUND(COALESCE(o.COMP_WORTH, 0), 2) <> ROUND(COALESCE(n.COMP_WORTH, 0), 2)
),
moved AS (      /* summary rows (S) and daily rows (D) whose MOST_PLAYED_DENOM_AMT is not what it was */
    SELECT o.TRIP_MASTER_ID, 'S' AS LVL, o.MOST_PLAYED_DENOM_AMT AS WAS, c.MOST_PLAYED_DENOM_AMT AS NOW_
    FROM DAAS_PROD.DAAS_TEMP_WORK.DAASI_3641_BEFORE_TRIP_SUMMARY o
    JOIN DAAS_PROD.DAAS_CORE.TRIP_SUMMARY c ON c.TRIP_MASTER_ID = o.TRIP_MASTER_ID
    WHERE o.TRIP_MASTER_ID IN (SELECT TRIP_MASTER_ID FROM quiet)
      AND NOT EQUAL_NULL(o.MOST_PLAYED_DENOM_AMT, c.MOST_PLAYED_DENOM_AMT)
    UNION ALL
    SELECT o.TRIP_MASTER_ID, 'D', o.MOST_PLAYED_DENOM_AMT, c.MOST_PLAYED_DENOM_AMT
    FROM DAAS_PROD.DAAS_TEMP_WORK.DAASI_3641_BEFORE_DAILY_ACTIVITY_SUMMARY o
    JOIN DAAS_PROD.DAAS_CORE.DAILY_ACTIVITY_SUMMARY c ON c.TRIP_MASTER_ID = o.TRIP_MASTER_ID AND c.GUEST_ACTIVITY_DATE = o.GUEST_ACTIVITY_DATE
    WHERE o.TRIP_MASTER_ID IN (SELECT TRIP_MASTER_ID FROM quiet)
      AND NOT EQUAL_NULL(o.MOST_PLAYED_DENOM_AMT, c.MOST_PLAYED_DENOM_AMT)
),
played AS (     /* as the summary step counts them: the trip's ratings per denomination, and the last day each was played */
    SELECT d.TRIP_MASTER_ID, r.DENOM_AMT, COUNT(r.DENOM_AMT) AS RATINGS, MAX(r.BUSINESS_DT) AS LAST_PLAYED
    FROM DAAS_PROD.DAAS_CORE.TRIP_DETAIL d
    JOIN DAAS_PROD.DAAS_CORE.RATINGS_FACT r ON r.RATINGS_FACT_SK = d.TRANSACTION_TABLE_SK
    WHERE d.TRANSACTION_TYPE = 'RATINGS'
      AND d.TRIP_MASTER_ID IN (SELECT TRIP_MASTER_ID FROM moved)
    GROUP BY d.TRIP_MASTER_ID, r.DENOM_AMT
),
first_place AS (        /* the step keeps the first by most ratings, then latest day; RANK shows every denomination sharing first */
    SELECT TRIP_MASTER_ID, DENOM_AMT, RATINGS, LAST_PLAYED
    FROM played
    QUALIFY RANK() OVER (PARTITION BY TRIP_MASTER_ID ORDER BY RATINGS DESC, LAST_PLAYED DESC) = 1
),
tied AS (SELECT TRIP_MASTER_ID, COUNT(*) AS TIED FROM first_place GROUP BY TRIP_MASTER_ID),
judged AS (     /* a trip is explained when two or more denominations share first place and every old and new value is one of them */
    SELECT m.TRIP_MASTER_ID,
           COUNT_IF(m.LVL = 'S')                               AS SUMMARY_ROWS,
           COUNT_IF(m.LVL = 'D')                               AS DAILY_ROWS,
           MAX(COALESCE(t.TIED, 0))                            AS TIED,
           COUNT_IF(fw.DENOM_AMT IS NULL OR fn.DENOM_AMT IS NULL) AS VALUES_NOT_FIRST
    FROM moved m
    LEFT JOIN tied t         ON t.TRIP_MASTER_ID = m.TRIP_MASTER_ID
    LEFT JOIN first_place fw ON fw.TRIP_MASTER_ID = m.TRIP_MASTER_ID AND fw.DENOM_AMT = m.WAS
    LEFT JOIN first_place fn ON fn.TRIP_MASTER_ID = m.TRIP_MASTER_ID AND fn.DENOM_AMT = m.NOW_
    GROUP BY m.TRIP_MASTER_ID
),
touched AS (    /* of the trips compared: those with a transaction row the pipeline itself has written since the before-picture:
                   the row is newer than it was, and its last writer is not this ticket's call */
    SELECT DISTINCT n.TRIP_MASTER_ID
    FROM td_n n
    JOIN td_b o ON o.TRIP_DETAIL_ID = n.TRIP_DETAIL_ID
    WHERE n.UPDATED_DTTM > o.UPDATED_DTTM AND COALESCE(n.UPDATED_BY, '') NOT LIKE '%DAASI-3641%'
),
ts_ids AS (     /* PC5's row 5: the summary rows on which a compared figure differs */
    SELECT TRIP_MASTER_ID FROM (SELECT * FROM ts_b MINUS SELECT * FROM ts_n)
    UNION
    SELECT TRIP_MASTER_ID FROM (SELECT * FROM ts_n MINUS SELECT * FROM ts_b)
),
ts_was AS (SELECT TRIP_MASTER_ID, OBJECT_CONSTRUCT_KEEP_NULL(*) AS O FROM ts_b WHERE TRIP_MASTER_ID IN (SELECT TRIP_MASTER_ID FROM ts_ids)),
ts_now AS (SELECT TRIP_MASTER_ID, OBJECT_CONSTRUCT_KEEP_NULL(*) AS O FROM ts_n WHERE TRIP_MASTER_ID IN (SELECT TRIP_MASTER_ID FROM ts_ids)),
das_ids AS (    /* PC5's row 6: the daily rows on which a compared figure differs */
    SELECT TRIP_MASTER_ID, GUEST_ACTIVITY_DATE FROM (SELECT * FROM das_b MINUS SELECT * FROM das_n)
    UNION
    SELECT TRIP_MASTER_ID, GUEST_ACTIVITY_DATE FROM (SELECT * FROM das_n MINUS SELECT * FROM das_b)
),
das_was AS (
    SELECT TRIP_MASTER_ID, GUEST_ACTIVITY_DATE, OBJECT_CONSTRUCT_KEEP_NULL(*) AS O FROM das_b
    WHERE (TRIP_MASTER_ID, GUEST_ACTIVITY_DATE) IN (SELECT TRIP_MASTER_ID, GUEST_ACTIVITY_DATE FROM das_ids)
),
das_now AS (
    SELECT TRIP_MASTER_ID, GUEST_ACTIVITY_DATE, OBJECT_CONSTRUCT_KEEP_NULL(*) AS O FROM das_n
    WHERE (TRIP_MASTER_ID, GUEST_ACTIVITY_DATE) IN (SELECT TRIP_MASTER_ID, GUEST_ACTIVITY_DATE FROM das_ids)
),
diffs AS (      /* one row for each of those rows and each column whose value is not what it was: the row as an object, column by column */
    SELECT 'TRIP_SUMMARY' AS TBL, f.VALUE::VARCHAR AS COL, n.TRIP_MASTER_ID, n.TRIP_MASTER_ID::VARCHAR AS ROW_KEY,
           GET(w.O, f.VALUE::VARCHAR)::VARCHAR AS WAS, GET(n.O, f.VALUE::VARCHAR)::VARCHAR AS NOW_
    FROM ts_now n
    JOIN ts_was w ON w.TRIP_MASTER_ID = n.TRIP_MASTER_ID,
         LATERAL FLATTEN(INPUT => OBJECT_KEYS(n.O)) f
    WHERE NOT EQUAL_NULL(GET(n.O, f.VALUE::VARCHAR)::VARCHAR, GET(w.O, f.VALUE::VARCHAR)::VARCHAR)
    UNION ALL
    SELECT 'DAILY_ACTIVITY_SUMMARY' AS TBL, f.VALUE::VARCHAR AS COL, n.TRIP_MASTER_ID, n.TRIP_MASTER_ID::VARCHAR || ' ' || n.GUEST_ACTIVITY_DATE::VARCHAR AS ROW_KEY,
           GET(w.O, f.VALUE::VARCHAR)::VARCHAR AS WAS, GET(n.O, f.VALUE::VARCHAR)::VARCHAR AS NOW_
    FROM das_now n
    JOIN das_was w ON w.TRIP_MASTER_ID = n.TRIP_MASTER_ID AND w.GUEST_ACTIVITY_DATE = n.GUEST_ACTIVITY_DATE,
         LATERAL FLATTEN(INPUT => OBJECT_KEYS(n.O)) f
    WHERE NOT EQUAL_NULL(GET(n.O, f.VALUE::VARCHAR)::VARCHAR, GET(w.O, f.VALUE::VARCHAR)::VARCHAR)
),
first_today AS (        /* per trip: the denominations most played by today's ratings, as PC5 ranks them */
    SELECT TRIP_MASTER_ID,
           LISTAGG(DENOM_AMT::VARCHAR || ' (' || RATINGS::VARCHAR || ' ratings, last ' || LAST_PLAYED::VARCHAR || ')', ', ')
               WITHIN GROUP (ORDER BY DENOM_AMT) AS FIRST_TODAY
    FROM first_place
    GROUP BY TRIP_MASTER_ID
),
odd AS (        /* PC5's row 9 less its row 10: a most-played denomination that changed, and not between two tied for first */
    SELECT DISTINCT m.TRIP_MASTER_ID, m.LVL, m.WAS, m.NOW_
    FROM moved m
    JOIN judged j ON j.TRIP_MASTER_ID = m.TRIP_MASTER_ID
    WHERE NOT (j.TIED >= 2 AND j.VALUES_NOT_FIRST = 0)
)
SELECT in_table, what_differs, rows_differing, trips, of_those_trips_the_pipeline_wrote_to_since, net_change_where_a_number,
       example_row, example_was, example_now, most_played_today
FROM (
    SELECT 1 AS ORD, d.TBL AS in_table, d.COL AS what_differs, COUNT(*) AS rows_differing, COUNT(DISTINCT d.TRIP_MASTER_ID) AS trips,
           COUNT(DISTINCT IFF(t.TRIP_MASTER_ID IS NOT NULL, d.TRIP_MASTER_ID, NULL)) AS of_those_trips_the_pipeline_wrote_to_since,
           ROUND(SUM(TRY_TO_DOUBLE(d.NOW_) - TRY_TO_DOUBLE(d.WAS)), 2) AS net_change_where_a_number,
           MIN(d.ROW_KEY) AS example_row, MIN_BY(d.WAS, d.ROW_KEY) AS example_was, MIN_BY(d.NOW_, d.ROW_KEY) AS example_now,
           NULL AS most_played_today
    FROM diffs d
    LEFT JOIN touched t ON t.TRIP_MASTER_ID = d.TRIP_MASTER_ID
    GROUP BY d.TBL, d.COL
    UNION ALL
    SELECT 2 AS ORD, 'MOST_PLAYED_DENOM_AMT, not a tie' AS in_table, IFF(o.LVL = 'S', 'on the summary row', 'on a daily row') AS what_differs,
           1 AS rows_differing, 1 AS trips, IFF(t.TRIP_MASTER_ID IS NOT NULL, 1, 0) AS of_those_trips_the_pipeline_wrote_to_since,
           NULL AS net_change_where_a_number,
           o.TRIP_MASTER_ID::VARCHAR || ' ' || m.TRIP_START_DT::VARCHAR || ' to ' || m.TRIP_END_DT::VARCHAR AS example_row,
           o.WAS::VARCHAR AS example_was, o.NOW_::VARCHAR AS example_now, f.FIRST_TODAY AS most_played_today
    FROM odd o
    JOIN tm_n m ON m.TRIP_MASTER_ID = o.TRIP_MASTER_ID
    LEFT JOIN touched t ON t.TRIP_MASTER_ID = o.TRIP_MASTER_ID
    LEFT JOIN first_today f ON f.TRIP_MASTER_ID = o.TRIP_MASTER_ID
) x
ORDER BY ORD, in_table DESC, rows_differing DESC, what_differs, example_row;


-- 3. PC4e (read-only, quick): PC4d's four market trips and their property trips, as their summary rows stood in the
--    before-pictures and as they stand now: comp worth, theo, and the step that wrote the row. It shows whether a
--    property trip's comp worth moved when the replay had it valued again. The three WLM market trips were built
--    after the before-pictures, so their 'before' columns are empty.
SELECT t.MARKET_TRIP                        AS market_trip,
       IFF(t.ORD = 0, 'market trip', 'property trip') AS kind,
       t.TRIP_MASTER_ID                     AS trip_master_id,
       m.GUEST_UNIQUE_ID                    AS guest,
       m.PROPERTY_CD                        AS property,
       m.TRIP_START_DT                      AS trip_start,
       m.TRIP_END_DT                        AS trip_end,
       ROUND(b.COMP_WORTH, 2)               AS comp_worth_before,
       ROUND(s.COMP_WORTH, 2)               AS comp_worth_now,
       ROUND(b.TOTAL_THEO_WIN_AMT, 2)       AS theo_before,
       ROUND(s.TOTAL_THEO_WIN_AMT, 2)       AS theo_now,
       b.BATCH_ID                           AS written_by_batch_id_before,
       b.UPDATED_DTTM                       AS summary_updated_before,
       s.BATCH_ID                           AS written_by_batch_id_now,
       s.UPDATED_DTTM                       AS summary_updated_now
FROM (VALUES (1, 2931098003, 0, 2931098003), (1, 2931098003, 1, 2864501996), (2, 2931804858, 0, 2931804858), (2, 2931804858, 1, 2896296029),
                 (3, 2931804855, 0, 2931804855), (3, 2931804855, 1, 2896296029), (3, 2931804855, 2, 2929494770), (4, 2893110449, 0, 2893110449),
                 (4, 2893110449, 1, 2507810404), (4, 2893110449, 2, 2643360783), (4, 2893110449, 3, 2643362173), (4, 2893110449, 4, 2643363277),
                 (4, 2893110449, 5, 2893110567), (4, 2893110449, 6, 2893110586)
     ) AS t (GRP, MARKET_TRIP, ORD, TRIP_MASTER_ID)
LEFT JOIN DAAS_PROD.DAAS_CORE.TRIP_MASTER m ON m.TRIP_MASTER_ID = t.TRIP_MASTER_ID
LEFT JOIN DAAS_PROD.DAAS_TEMP_WORK.DAASI_3641_BEFORE_TRIP_SUMMARY b ON b.TRIP_MASTER_ID = t.TRIP_MASTER_ID
LEFT JOIN DAAS_PROD.DAAS_CORE.TRIP_SUMMARY s ON s.TRIP_MASTER_ID = t.TRIP_MASTER_ID
ORDER BY t.GRP, t.ORD, t.TRIP_MASTER_ID;


-- 4. R3 (read-only): the rows statement 5 will mark, so that you see them first. They are the rating rows of the
--    three market trips and, for each rating, its row on the property trip. Expect a few dozen rows, the market
--    rows on trips 2931098003, 2931804858 and 2931804855 only. Note how many rows it returns.
WITH to_mark AS (       /* the condition the call hands to the procedure, word for word */
    SELECT *
    FROM DAAS_PROD.DAAS_CORE.TRIP_DETAIL
    WHERE DELETE_IND = 'N' AND TRANSACTION_TABLE = 'RATINGS_FACT' AND TRANSACTION_SUB_TYPE = 'OPENED' AND TRANSACTION_TABLE_SK IN (SELECT TRANSACTION_TABLE_SK FROM DAAS_PROD.DAAS_CORE.TRIP_DETAIL WHERE TRIP_MASTER_ID IN (2931098003, 2931804858, 2931804855) AND TRANSACTION_TABLE = 'RATINGS_FACT' AND DELETE_IND = 'N' AND TRANSACTION_SUB_TYPE = 'OPENED') AND (TRIP_MASTER_ID IN (2931098003, 2931804858, 2931804855) OR TRIP_MASTER_ID IN (SELECT TRIP_MASTER_ID FROM DAAS_PROD.DAAS_CORE.TRIP_MASTER WHERE TRIP_TYPE = 'PROPERTY' AND DELETE_IND = 'N'))
)
SELECT m.TRIP_TYPE            AS trip_type,
       d.TRIP_MASTER_ID       AS trip_master_id,
       m.GUEST_UNIQUE_ID      AS guest,
       m.PROPERTY_CD          AS property,
       d.BUSINESS_START_DT    AS business_date,
       d.TRANSACTION_TABLE_SK AS rating_sk,
       d.TRIP_DETAIL_ID       AS trip_detail_id,
       d.REPLAY_COUNTER       AS replay_counter,
       d.UPDATED_DTTM         AS updated_dttm,
       d.UPDATED_BY           AS updated_by
FROM to_mark d
JOIN DAAS_PROD.DAAS_CORE.TRIP_MASTER m ON m.TRIP_MASTER_ID = d.TRIP_MASTER_ID
ORDER BY d.TRANSACTION_TABLE_SK, m.TRIP_TYPE, d.TRIP_MASTER_ID;


-- 5. R4 (the one write, through the procedure as every batch was): marks those rows, so that the next hourly run
--    summarises the three trips and their property trips together and values them. It changes nothing else: no
--    trip is re-cut, and no other market trip's row is touched. Run the two session settings first, as for a batch.
--    Expect 'Records Updated: ' and the number of rows statement 4 returned. If it says 'Exceeds Threshold',
--    nothing was changed: send me the message.
ALTER SESSION SET AUTOCOMMIT = TRUE;
ALTER SESSION SET TIMEZONE = 'America/Los_Angeles';
CALL DAAS_PROD.DAAS_COMMON.DATA_REPLAY_PROC('DAAS_CORE', 'TRIP_DETAIL', 'WHERE DELETE_IND = ''N'' AND TRANSACTION_TABLE = ''RATINGS_FACT'' AND TRANSACTION_SUB_TYPE = ''OPENED'' AND TRANSACTION_TABLE_SK IN (SELECT TRANSACTION_TABLE_SK FROM DAAS_PROD.DAAS_CORE.TRIP_DETAIL WHERE TRIP_MASTER_ID IN (2931098003, 2931804858, 2931804855) AND TRANSACTION_TABLE = ''RATINGS_FACT'' AND DELETE_IND = ''N'' AND TRANSACTION_SUB_TYPE = ''OPENED'') AND (TRIP_MASTER_ID IN (2931098003, 2931804858, 2931804855) OR TRIP_MASTER_ID IN (SELECT TRIP_MASTER_ID FROM DAAS_PROD.DAAS_CORE.TRIP_MASTER WHERE TRIP_TYPE = ''PROPERTY'' AND DELETE_IND = ''N''))', 'DAASI-3641', 500);


-- 6. PC4d again (read-only), about two hours after statement 5: the hourly run that takes the rows has to finish
--    first. Expect the three WLM trips gone, and one trip left: the BEM trip 2893110449. If the three are still
--    listed, run it once more an hour later.
WITH gone AS (       /* the BEM/WLM market trips that were live in the before-picture and are retired now (or retired and since archived) */
    SELECT b.TRIP_MASTER_ID, b.MARKET_CD
    FROM DAAS_PROD.DAAS_TEMP_WORK.DAASI_3641_BEFORE_TRIP_MASTER b
    LEFT JOIN DAAS_PROD.DAAS_CORE.TRIP_MASTER m ON m.TRIP_MASTER_ID = b.TRIP_MASTER_ID
    WHERE b.TRIP_TYPE = 'MARKET' AND b.MARKET_CD IN ('BEM', 'WLM') AND b.DELETE_IND = 'N'
      AND (m.TRIP_MASTER_ID IS NULL OR m.DELETE_IND = 'Y')
),
keys AS (       /* the ratings those trips held, live, in the before-picture, with the batch of the listed trip that held them */
    SELECT g.MARKET_CD, d.TRANSACTION_TABLE_SK AS SK, MIN(l.BATCH_NO) AS BATCH_NO
    FROM gone g
    JOIN DAAS_PROD.DAAS_TEMP_WORK.DAASI_3641_BEFORE_TRIP_DETAIL d ON d.TRIP_MASTER_ID = g.TRIP_MASTER_ID
    LEFT JOIN DAAS_PROD.DAAS_TEMP_WORK.DAASI_3641_REPLAY_TRIPS l ON l.TRIP_MASTER_ID = g.TRIP_MASTER_ID
    WHERE d.TRANSACTION_TYPE = 'RATINGS' AND d.DELETE_IND = 'N' AND d.TRANSACTION_SUB_TYPE = 'OPENED'
    GROUP BY g.MARKET_CD, d.TRANSACTION_TABLE_SK
),
holders AS (    /* the live market trips those ratings sit on now */
    SELECT m.MARKET_CD, m.TRIP_MASTER_ID, MIN(k.BATCH_NO) AS BATCH_NO
    FROM keys k
    JOIN DAAS_PROD.DAAS_CORE.TRIP_DETAIL d ON d.TRANSACTION_TABLE_SK = k.SK AND d.TRANSACTION_TYPE = 'RATINGS' AND d.DELETE_IND = 'N'
    JOIN DAAS_PROD.DAAS_CORE.TRIP_MASTER m ON m.TRIP_MASTER_ID = d.TRIP_MASTER_ID
    WHERE m.TRIP_TYPE = 'MARKET' AND m.MARKET_CD = k.MARKET_CD AND m.DELETE_IND = 'N'
    GROUP BY m.MARKET_CD, m.TRIP_MASTER_ID
),
shares AS (     /* each of those trips with the live property trips that hold one of its ratings */
    SELECT DISTINCT h.TRIP_MASTER_ID AS MARKET_TRIP, p.TRIP_MASTER_ID AS PROPERTY_TRIP
    FROM holders h
    JOIN DAAS_PROD.DAAS_CORE.TRIP_DETAIL d  ON d.TRIP_MASTER_ID = h.TRIP_MASTER_ID
    JOIN DAAS_PROD.DAAS_CORE.TRIP_DETAIL pd ON pd.TRANSACTION_TABLE_SK = d.TRANSACTION_TABLE_SK
    JOIN DAAS_PROD.DAAS_CORE.TRIP_MASTER p  ON p.TRIP_MASTER_ID = pd.TRIP_MASTER_ID
    WHERE d.TRANSACTION_TYPE = 'RATINGS' AND d.DELETE_IND = 'N'
      AND pd.TRANSACTION_TYPE = 'RATINGS' AND pd.DELETE_IND = 'N'
      AND p.TRIP_TYPE = 'PROPERTY' AND p.DELETE_IND = 'N'
),
side AS (       /* the property side of a market trip. The comp worth step adds up each different comp worth among those property
                   trips once (ONCE_EACH); EVERY_ONE adds them all, for the case of two that differ by less than a cent.
                   RUNS: how many runs of the step last valued those property trips (its batch number is on the summary row) */
    SELECT x.MARKET_TRIP, COUNT(*) AS PROPERTY_TRIPS,
           SUM(DISTINCT ROUND(COALESCE(s.COMP_WORTH, 0), 2)) AS ONCE_EACH,
           SUM(ROUND(COALESCE(s.COMP_WORTH, 0), 2))          AS EVERY_ONE,
           COUNT(DISTINCT COALESCE(s.BATCH_ID, -1))          AS RUNS,
           MAX(s.BATCH_ID)                                   AS LAST_RUN
    FROM shares x
    LEFT JOIN DAAS_PROD.DAAS_CORE.TRIP_SUMMARY s ON s.TRIP_MASTER_ID = x.PROPERTY_TRIP
    GROUP BY x.MARKET_TRIP
),
differing AS (  /* PC4's own test of a trip against its property side, on every trip that has one: kept where it fails.
                   TOGETHER as PC4 has it: 1 when the trip and all its property trips were last valued by one and the same run */
    SELECT h.BATCH_NO, h.MARKET_CD, h.TRIP_MASTER_ID AS MARKET_TRIP, x.ONCE_EACH, x.EVERY_ONE,
           IFF(x.RUNS = 1 AND x.LAST_RUN = s.BATCH_ID, 1, 0) AS TOGETHER
    FROM holders h
    JOIN side x ON x.MARKET_TRIP = h.TRIP_MASTER_ID
    LEFT JOIN DAAS_PROD.DAAS_CORE.TRIP_SUMMARY s ON s.TRIP_MASTER_ID = h.TRIP_MASTER_ID
    WHERE IFF(ABS(ROUND(COALESCE(s.COMP_WORTH, 0), 2) - x.ONCE_EACH) <= 0.01 * x.PROPERTY_TRIPS
               OR ABS(ROUND(COALESCE(s.COMP_WORTH, 0), 2) - x.EVERY_ONE) <= 0.01 * x.PROPERTY_TRIPS, 1, 0) = 0
),
each_trip AS (  /* the market trip, then each property trip that holds one of its ratings */
    SELECT o.BATCH_NO, o.MARKET_CD, o.TOGETHER, o.MARKET_TRIP, 1 AS ORD, 'market trip' AS KIND, o.MARKET_TRIP AS TRIP_MASTER_ID,
           o.ONCE_EACH, o.EVERY_ONE
    FROM differing o
    UNION ALL
    SELECT o.BATCH_NO, o.MARKET_CD, o.TOGETHER, o.MARKET_TRIP, 2 AS ORD, 'property trip' AS KIND, x.PROPERTY_TRIP AS TRIP_MASTER_ID,
           NULL AS ONCE_EACH, NULL AS EVERY_ONE
    FROM differing o
    JOIN shares x ON x.MARKET_TRIP = o.MARKET_TRIP
)
SELECT COALESCE('batch ' || e.BATCH_NO, 'not listed')  AS batch,
       e.MARKET_CD                                    AS market,
       IFF(e.TOGETHER = 1, 'comp_worth_differs', 'left_out_valued_in_different_runs') AS counted_in_pc4_under,
       e.MARKET_TRIP                                  AS market_trip,
       e.KIND                                         AS kind,
       e.TRIP_MASTER_ID                               AS trip_master_id,
       m.GUEST_UNIQUE_ID                              AS guest,
       m.PROPERTY_CD                                  AS property,
       m.TRIP_START_DT                                AS trip_start,
       m.TRIP_END_DT                                  AS trip_end,
       m.CREATED_DTTM                                 AS trip_created,
       ROUND(s.TOTAL_THEO_WIN_AMT, 2)                 AS theo,
       ROUND(s.COMP_WORTH, 2)                         AS comp_worth,
       e.ONCE_EACH                                    AS its_property_trips_add_up_to,
       e.EVERY_ONE                                    AS or_with_every_one_counted,
       s.BATCH_ID                                     AS last_written_by_batch_id,
       s.UPDATED_DTTM                                 AS summary_updated
FROM each_trip e
JOIN DAAS_PROD.DAAS_CORE.TRIP_MASTER m ON m.TRIP_MASTER_ID = e.TRIP_MASTER_ID
LEFT JOIN DAAS_PROD.DAAS_CORE.TRIP_SUMMARY s ON s.TRIP_MASTER_ID = e.TRIP_MASTER_ID
ORDER BY e.TOGETHER DESC, e.BATCH_NO NULLS LAST, e.MARKET_CD, e.MARKET_TRIP, e.ORD, e.TRIP_MASTER_ID;
