-- DAASI-3641: the PROD replay, part 1 of 2. The pre-check: read-only, changes nothing, can be run today.
--
--   P0  v1.4 is what PROD runs
--   P1  the count: what each pair of statements in part 2 will update. The figure for the sign-off
--   P2  nine things to know before the first write, each with what is expected
--   P3  the trips still to replay, by market (the same query closes the replay, when its last line must show 0)
-- P1 and P2 read TRIP_DETAIL several times: a few minutes each on Large. Run each on its own.

USE ROLE DAAS_TEAM;
USE SECONDARY ROLES ALL;


-- P0. Expect 'v1.4 is live in PROD'.
SELECT IFF(CONTAINS(GET_DDL('PROCEDURE', 'DAAS_PROD.DAAS_COMMON.TRIP_MERGE_CHECK_PROC(FLOAT, VARCHAR, VARCHAR, VARCHAR, VARCHAR)'),
                    'my_sql_command_3A'),
           'v1.4 is live in PROD', 'PROD still runs the old version: deploy v1.4 first') AS merge_check_version;


-- P1. The count. One row for each pair of statements in part 2, and the total, counted by the statements' own logic.
--     trip_master_rows_to_update is what the TRIP_MASTER statement will report, trip_detail_rows_to_update what the
--     TRIP_DETAIL statement will report; ratings_fact_rows is 0 because the replay does not touch RATINGS_FACT (the
--     11 Nov plan would have updated 12,072,060 rows there). For comparison, the scope check of 12 Nov gave 378,800
--     trip rows and 1,051,675 rating rows; this count is the day's, and its rating rows run a little higher because
--     they also cover the neighbours (see neighbours_the_join_rule_adds, and P2). most_passes_the_merge_needs is the
--     length of the merge step's loop for that run: 30 or less for the canary and the main run by construction.
--     If the canary is skipped, the main run takes its rows too.
WITH ent AS (       /* the enterprise settings: merge check's fallback where a market has none of its own */
    SELECT MAX(IFF(KEY = 'MAX_TRIP_DAYS', VALUE, NULL)) AS MAX_TRIP_DAYS,
           MAX(IFF(KEY = 'TRIP_GAP_DAYS', VALUE, NULL)) AS TRIP_GAP_DAYS
    FROM DAAS_PROD.DAAS_CORE.TRIP_CONFIG
    WHERE CONFIG_SUBTYPE = 'ENTERPRISE' AND KEY IN ('MAX_TRIP_DAYS', 'TRIP_GAP_DAYS') AND ACTIVE_FLG = 'Y'
),
multi AS (
    SELECT TRIP_MASTER_ID, GUEST_UNIQUE_ID, MARKET_CD, TRIP_START_DT, TRIP_END_DT, TRIP_END_DT - TRIP_START_DT + 1 AS TRIP_DAYS
    FROM DAAS_PROD.DAAS_CORE.TRIP_MASTER
    WHERE DELETE_IND = 'N' AND TRIP_TYPE = 'MARKET' AND MARKET_CD IN ('BEM', 'WLM') AND TRIP_END_DT > TRIP_START_DT
),
caps AS (
    SELECT MARKET_CD, TRIP_START_DT,
           DAAS_PROD.DAAS_COMMON.TRIP_CONFIG_UDF_MARKET('MAX_TRIP_DAYS', MARKET_CD, TRIP_START_DT) AS CAP,
           DAAS_PROD.DAAS_COMMON.TRIP_CONFIG_UDF_MARKET('TRIP_GAP_DAYS', MARKET_CD, TRIP_START_DT) AS GAP
    FROM (SELECT DISTINCT MARKET_CD, TRIP_START_DT FROM multi)
),
targets AS (    /* the trips to replay: live BEM/WLM market trips over their cap with no hotel night, as v1.4 measures them */
    SELECT m.TRIP_MASTER_ID, m.GUEST_UNIQUE_ID, m.MARKET_CD, m.TRIP_START_DT, m.TRIP_END_DT, m.TRIP_DAYS,
           COALESCE(TRY_TO_NUMBER(c.CAP), TRY_TO_NUMBER(e.MAX_TRIP_DAYS)) AS CAP,
           COALESCE(TRY_TO_NUMBER(c.GAP), TRY_TO_NUMBER(e.TRIP_GAP_DAYS)) AS GAP
    FROM multi m
    JOIN caps c ON c.MARKET_CD = m.MARKET_CD AND c.TRIP_START_DT = m.TRIP_START_DT
    CROSS JOIN ent e
    WHERE m.TRIP_DAYS > COALESCE(TRY_TO_NUMBER(c.CAP), TRY_TO_NUMBER(e.MAX_TRIP_DAYS))
      AND NOT EXISTS (SELECT 1 FROM DAAS_PROD.DAAS_CORE.TRIP_DETAIL d
                      WHERE d.TRIP_MASTER_ID = m.TRIP_MASTER_ID AND d.DELETE_IND = 'N' AND d.TRANSACTION_TYPE = 'HOTEL')
),
chained AS (    /* a run: a guest's target trips in a market, each starting within the gap of where the one before ends */
    SELECT t.*,
           IFF(DATEDIFF(day, MAX(t.TRIP_END_DT) OVER (PARTITION BY t.GUEST_UNIQUE_ID, t.MARKET_CD
                                                      ORDER BY t.TRIP_START_DT, t.TRIP_END_DT, t.TRIP_MASTER_ID
                                                      ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING),
                        t.TRIP_START_DT) <= t.GAP, 0, 1) AS STARTS_A_RUN
    FROM targets t
),
numbered AS (
    SELECT c.*,
           SUM(c.STARTS_A_RUN) OVER (PARTITION BY c.GUEST_UNIQUE_ID, c.MARKET_CD
                                     ORDER BY c.TRIP_START_DT, c.TRIP_END_DT, c.TRIP_MASTER_ID
                                     ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS RUN_NO
    FROM chained c
),
placed AS (     /* each trip with its run: the passes the merge step's loop needs for the whole run, and the trip's place in it */
    SELECT n.*,
           CEIL((DATEDIFF(day, MIN(n.TRIP_START_DT) OVER (PARTITION BY n.GUEST_UNIQUE_ID, n.MARKET_CD, n.RUN_NO),
                               MAX(n.TRIP_END_DT)   OVER (PARTITION BY n.GUEST_UNIQUE_ID, n.MARKET_CD, n.RUN_NO)) + 1)
                / MIN(n.CAP) OVER (PARTITION BY n.GUEST_UNIQUE_ID, n.MARKET_CD, n.RUN_NO))                AS RUN_PASSES,
           MAX(n.CAP) OVER (PARTITION BY n.GUEST_UNIQUE_ID, n.MARKET_CD, n.RUN_NO)                        AS RUN_CAP,
           ROW_NUMBER() OVER (PARTITION BY n.GUEST_UNIQUE_ID, n.MARKET_CD, n.RUN_NO
                              ORDER BY n.TRIP_START_DT, n.TRIP_END_DT, n.TRIP_MASTER_ID)                 AS PLACE_IN_RUN
    FROM numbered n
),
picked AS (     /* a guest's longest run decides the guest's group: more than 30 passes makes a long-run guest */
    SELECT p.*, MAX(p.RUN_PASSES) OVER (PARTITION BY p.GUEST_UNIQUE_ID) AS GUEST_PASSES
    FROM placed p
),
stay AS (       /* trips holding a hotel night */
    SELECT DISTINCT TRIP_MASTER_ID
    FROM DAAS_PROD.DAAS_CORE.TRIP_DETAIL
    WHERE DELETE_IND = 'N' AND TRANSACTION_TYPE = 'HOTEL'
),
bumped AS (     /* every trip to replay, with the statement that takes it */
    SELECT t.TRIP_MASTER_ID, t.GUEST_UNIQUE_ID, t.MARKET_CD, t.TRIP_START_DT, t.TRIP_END_DT, t.GAP,
           IFF(t.GUEST_PASSES > 30 AND t.RUN_PASSES > 30 AND t.RUN_CAP = 1, CEIL(t.TRIP_DAYS / t.CAP), t.RUN_PASSES) AS PASSES,
           CASE WHEN t.GUEST_PASSES <= 30 AND MOD(ABS(HASH(t.GUEST_UNIQUE_ID)), 100) = 0                THEN '1  canary'
                WHEN t.GUEST_PASSES <= 30                                                              THEN '2  main'
                WHEN NOT (t.RUN_PASSES > 30 AND t.RUN_CAP = 1 AND MOD(t.PLACE_IN_RUN, 2) = 0)          THEN '3  long-run guests, first cut'
                ELSE                                                                                        '4  the rest'
           END AS STMT
    FROM picked t
),
going AS (      /* with the trips merge check's own join rule pairs with them */
    SELECT b.STMT, b.TRIP_MASTER_ID, b.GUEST_UNIQUE_ID, b.MARKET_CD
    FROM bumped b
    UNION
    SELECT b.STMT, o.TRIP_MASTER_ID, b.GUEST_UNIQUE_ID, b.MARKET_CD
    FROM bumped b
    JOIN DAAS_PROD.DAAS_CORE.TRIP_MASTER o
      ON o.GUEST_UNIQUE_ID = b.GUEST_UNIQUE_ID AND o.TRIP_TYPE = 'MARKET' AND o.MARKET_CD = b.MARKET_CD
     AND o.DELETE_IND = 'N' AND o.TRIP_MASTER_ID <> b.TRIP_MASTER_ID
    LEFT JOIN stay s ON s.TRIP_MASTER_ID = o.TRIP_MASTER_ID
    WHERE b.TRIP_START_DT BETWEEN o.TRIP_START_DT AND o.TRIP_END_DT
       OR o.TRIP_START_DT BETWEEN b.TRIP_START_DT AND b.TRIP_END_DT
       OR (s.TRIP_MASTER_ID IS NOT NULL AND DATEADD(day, b.GAP, b.TRIP_END_DT) BETWEEN o.TRIP_START_DT AND o.TRIP_END_DT)
),
marks AS (      /* statement 2's rows: one rating row for each property trip and day */
    SELECT g.STMT, MIN(pd.TRIP_DETAIL_ID) AS TRIP_DETAIL_ID, pd.TRIP_MASTER_ID AS PROPERTY_TRIP_ID
    FROM going g
    JOIN DAAS_PROD.DAAS_CORE.TRIP_DETAIL d  ON d.TRIP_MASTER_ID = g.TRIP_MASTER_ID
    JOIN DAAS_PROD.DAAS_CORE.TRIP_DETAIL pd ON pd.TRANSACTION_TABLE_SK = d.TRANSACTION_TABLE_SK
    JOIN DAAS_PROD.DAAS_CORE.TRIP_MASTER p  ON p.TRIP_MASTER_ID = pd.TRIP_MASTER_ID
    WHERE d.TRANSACTION_TABLE = 'RATINGS_FACT' AND d.TRANSACTION_SUB_TYPE = 'OPENED'
      AND pd.TRANSACTION_TABLE = 'RATINGS_FACT' AND pd.DELETE_IND = 'N' AND pd.TRANSACTION_SUB_TYPE = 'OPENED'
      AND p.TRIP_TYPE = 'PROPERTY' AND p.DELETE_IND = 'N'
    GROUP BY g.STMT, pd.TRIP_MASTER_ID, pd.BUSINESS_START_DT, g.GUEST_UNIQUE_ID, g.MARKET_CD
),
a AS (
    SELECT STMT, COUNT(*) AS TRIPS, COUNT(DISTINCT GUEST_UNIQUE_ID) AS GUESTS,
           COUNT_IF(MARKET_CD = 'BEM') AS BEM_TRIPS, COUNT_IF(MARKET_CD = 'WLM') AS WLM_TRIPS, MAX(PASSES) AS MOST_PASSES
    FROM bumped
    GROUP BY STMT
),
n AS (
    SELECT g.STMT, COUNT(DISTINCT g.TRIP_MASTER_ID) AS NEIGHBOURS
    FROM going g
    LEFT JOIN bumped b ON b.TRIP_MASTER_ID = g.TRIP_MASTER_ID
    WHERE b.TRIP_MASTER_ID IS NULL
    GROUP BY g.STMT
),
m AS (
    SELECT STMT, COUNT(DISTINCT TRIP_DETAIL_ID) AS ROWS_TO_MARK, COUNT(DISTINCT PROPERTY_TRIP_ID) AS PROPERTY_TRIPS
    FROM marks
    GROUP BY STMT
),
r AS (
    SELECT a.STMT, a.TRIPS, a.GUESTS, a.BEM_TRIPS, a.WLM_TRIPS, COALESCE(n.NEIGHBOURS, 0) AS NEIGHBOURS,
           COALESCE(m.ROWS_TO_MARK, 0) AS ROWS_TO_MARK, COALESCE(m.PROPERTY_TRIPS, 0) AS PROPERTY_TRIPS, a.MOST_PASSES
    FROM a
    LEFT JOIN n ON n.STMT = a.STMT
    LEFT JOIN m ON m.STMT = a.STMT
)
SELECT STMT                          AS statements,
       TRIPS                         AS trip_master_rows_to_update,
       ROWS_TO_MARK                  AS trip_detail_rows_to_update,
       TRIPS + ROWS_TO_MARK          AS rows_updated_in_all,
       0                             AS ratings_fact_rows,
       GUESTS                        AS guests,
       BEM_TRIPS                     AS bem_trips,
       WLM_TRIPS                     AS wlm_trips,
       NEIGHBOURS                    AS neighbours_the_join_rule_adds,
       PROPERTY_TRIPS                AS property_trips_marked,
       MOST_PASSES                   AS most_passes_the_merge_needs
FROM r
UNION ALL
SELECT 'all four', SUM(TRIPS), SUM(ROWS_TO_MARK), SUM(TRIPS) + SUM(ROWS_TO_MARK), 0, NULL, SUM(BEM_TRIPS), SUM(WLM_TRIPS),
       SUM(NEIGHBOURS), NULL, MAX(MOST_PASSES)
FROM r
ORDER BY 1;


-- P2. Before the first write. Rows marked 'for the record' are numbers to know; the others say what is expected.
--     Row 5 is the one that can stop the replay: the merge step gathers every row marked OPENED on a trip it re-cuts,
--     without looking at the row's own delete flag, so a soft-deleted row still marked OPENED would come back live on
--     the new trip. The steps that soft-delete a row re-mark it in the same statement (VOIDED and the like), so 0 is
--     expected; if it is not 0, nothing in part 2 is run until those rows are explained.
WITH ent AS (       /* the enterprise settings: merge check's fallback where a market has none of its own */
    SELECT MAX(IFF(KEY = 'MAX_TRIP_DAYS', VALUE, NULL)) AS MAX_TRIP_DAYS,
           MAX(IFF(KEY = 'TRIP_GAP_DAYS', VALUE, NULL)) AS TRIP_GAP_DAYS
    FROM DAAS_PROD.DAAS_CORE.TRIP_CONFIG
    WHERE CONFIG_SUBTYPE = 'ENTERPRISE' AND KEY IN ('MAX_TRIP_DAYS', 'TRIP_GAP_DAYS') AND ACTIVE_FLG = 'Y'
),
multi AS (
    SELECT TRIP_MASTER_ID, GUEST_UNIQUE_ID, MARKET_CD, TRIP_START_DT, TRIP_END_DT, TRIP_END_DT - TRIP_START_DT + 1 AS TRIP_DAYS
    FROM DAAS_PROD.DAAS_CORE.TRIP_MASTER
    WHERE DELETE_IND = 'N' AND TRIP_TYPE = 'MARKET' AND MARKET_CD IN ('BEM', 'WLM') AND TRIP_END_DT > TRIP_START_DT
),
caps AS (
    SELECT MARKET_CD, TRIP_START_DT,
           DAAS_PROD.DAAS_COMMON.TRIP_CONFIG_UDF_MARKET('MAX_TRIP_DAYS', MARKET_CD, TRIP_START_DT) AS CAP,
           DAAS_PROD.DAAS_COMMON.TRIP_CONFIG_UDF_MARKET('TRIP_GAP_DAYS', MARKET_CD, TRIP_START_DT) AS GAP
    FROM (SELECT DISTINCT MARKET_CD, TRIP_START_DT FROM multi)
),
targets AS (    /* the trips to replay: live BEM/WLM market trips over their cap with no hotel night, as v1.4 measures them */
    SELECT m.TRIP_MASTER_ID, m.GUEST_UNIQUE_ID, m.MARKET_CD, m.TRIP_START_DT, m.TRIP_END_DT, m.TRIP_DAYS,
           COALESCE(TRY_TO_NUMBER(c.CAP), TRY_TO_NUMBER(e.MAX_TRIP_DAYS)) AS CAP,
           COALESCE(TRY_TO_NUMBER(c.GAP), TRY_TO_NUMBER(e.TRIP_GAP_DAYS)) AS GAP
    FROM multi m
    JOIN caps c ON c.MARKET_CD = m.MARKET_CD AND c.TRIP_START_DT = m.TRIP_START_DT
    CROSS JOIN ent e
    WHERE m.TRIP_DAYS > COALESCE(TRY_TO_NUMBER(c.CAP), TRY_TO_NUMBER(e.MAX_TRIP_DAYS))
      AND NOT EXISTS (SELECT 1 FROM DAAS_PROD.DAAS_CORE.TRIP_DETAIL d
                      WHERE d.TRIP_MASTER_ID = m.TRIP_MASTER_ID AND d.DELETE_IND = 'N' AND d.TRANSACTION_TYPE = 'HOTEL')
),
stay AS (       /* trips holding a hotel night */
    SELECT DISTINCT TRIP_MASTER_ID
    FROM DAAS_PROD.DAAS_CORE.TRIP_DETAIL
    WHERE DELETE_IND = 'N' AND TRANSACTION_TYPE = 'HOTEL'
),
bumped AS (
    SELECT t.TRIP_MASTER_ID, t.GUEST_UNIQUE_ID, t.MARKET_CD, t.TRIP_START_DT, t.TRIP_END_DT, t.GAP
    FROM targets t
),
going AS (      /* the trips to replay and the trips merge check's own join rule pairs with them */
    SELECT TRIP_MASTER_ID, GUEST_UNIQUE_ID, MARKET_CD, MAX(REPLAYED) AS REPLAYED
    FROM (SELECT b.TRIP_MASTER_ID, b.GUEST_UNIQUE_ID, b.MARKET_CD, 1 AS REPLAYED
          FROM bumped b
          UNION ALL
          SELECT o.TRIP_MASTER_ID, b.GUEST_UNIQUE_ID, b.MARKET_CD, 0
          FROM bumped b
          JOIN DAAS_PROD.DAAS_CORE.TRIP_MASTER o
            ON o.GUEST_UNIQUE_ID = b.GUEST_UNIQUE_ID AND o.TRIP_TYPE = 'MARKET' AND o.MARKET_CD = b.MARKET_CD
           AND o.DELETE_IND = 'N' AND o.TRIP_MASTER_ID <> b.TRIP_MASTER_ID
          LEFT JOIN stay s ON s.TRIP_MASTER_ID = o.TRIP_MASTER_ID
          WHERE b.TRIP_START_DT BETWEEN o.TRIP_START_DT AND o.TRIP_END_DT
             OR o.TRIP_START_DT BETWEEN b.TRIP_START_DT AND b.TRIP_END_DT
             OR (s.TRIP_MASTER_ID IS NOT NULL AND DATEADD(day, b.GAP, b.TRIP_END_DT) BETWEEN o.TRIP_START_DT AND o.TRIP_END_DT)) x
    GROUP BY TRIP_MASTER_ID, GUEST_UNIQUE_ID, MARKET_CD
),
held AS (       /* what each of those trips holds */
    SELECT g.TRIP_MASTER_ID, MAX(g.REPLAYED) AS REPLAYED,
           COUNT_IF(d.TRANSACTION_TABLE = 'RATINGS_FACT' AND d.DELETE_IND = 'N' AND d.TRANSACTION_SUB_TYPE = 'OPENED') AS LIVE_RATINGS,
           COUNT_IF(d.TRANSACTION_SUB_TYPE = 'OPENED')                                                                AS OPENED_ROWS,
           COUNT_IF(d.DELETE_IND = 'Y' AND d.TRANSACTION_SUB_TYPE = 'OPENED')                                         AS DEAD_OPENED_ROWS,
           COUNT_IF(d.DELETE_IND = 'Y' AND d.TRANSACTION_SUB_TYPE = 'OPENED' AND d.TRANSACTION_TYPE = 'HOTEL')        AS DEAD_OPENED_HOTEL_ROWS
    FROM going g
    LEFT JOIN DAAS_PROD.DAAS_CORE.TRIP_DETAIL d ON d.TRIP_MASTER_ID = g.TRIP_MASTER_ID
    GROUP BY g.TRIP_MASTER_ID
),
marks AS (      /* statement 2's rows, with whether the property trip has its summary row */
    SELECT MIN(pd.TRIP_DETAIL_ID) AS TRIP_DETAIL_ID, pd.TRIP_MASTER_ID AS PROPERTY_TRIP_ID
    FROM going g
    JOIN DAAS_PROD.DAAS_CORE.TRIP_DETAIL d  ON d.TRIP_MASTER_ID = g.TRIP_MASTER_ID
    JOIN DAAS_PROD.DAAS_CORE.TRIP_DETAIL pd ON pd.TRANSACTION_TABLE_SK = d.TRANSACTION_TABLE_SK
    JOIN DAAS_PROD.DAAS_CORE.TRIP_MASTER p  ON p.TRIP_MASTER_ID = pd.TRIP_MASTER_ID
    WHERE d.TRANSACTION_TABLE = 'RATINGS_FACT' AND d.TRANSACTION_SUB_TYPE = 'OPENED'
      AND pd.TRANSACTION_TABLE = 'RATINGS_FACT' AND pd.DELETE_IND = 'N' AND pd.TRANSACTION_SUB_TYPE = 'OPENED'
      AND p.TRIP_TYPE = 'PROPERTY' AND p.DELETE_IND = 'N'
    GROUP BY pd.TRIP_MASTER_ID, pd.BUSINESS_START_DT, g.GUEST_UNIQUE_ID, g.MARKET_CD
),
no_summary AS (
    SELECT COUNT(DISTINCT k.TRIP_DETAIL_ID) AS N
    FROM marks k
    LEFT JOIN DAAS_PROD.DAAS_CORE.TRIP_SUMMARY s ON s.TRIP_MASTER_ID = k.PROPERTY_TRIP_ID
    WHERE s.TRIP_MASTER_ID IS NULL
),
merged_away AS (
    SELECT COUNT(DISTINCT b.GUEST_UNIQUE_ID) AS N
    FROM bumped b
    JOIN DAAS_PROD.DAAS_CORE.GUEST_DIM d ON d.GUEST_UNIQUE_ID = b.GUEST_UNIQUE_ID
    WHERE d.DELETE_IND = 'Y'
),
keep AS (
    SELECT MAX(TRY_TO_NUMBER(VALUE)) AS N
    FROM DAAS_PROD.DAAS_CORE.TRIP_CONFIG
    WHERE CONFIG_SUBTYPE = 'TRIP_INACTIVE_TRANSACTION' AND KEY = 'RETENTION_PERIOD' AND ACTIVE_FLG = 'Y'
),
board AS (
    SELECT 1 AS N, 'Trips to replay: live BEM/WLM market trips over their cap with no hotel night' AS CHECK_NAME, NULL::NUMBER(38,0) AS EXPECTED,
           (SELECT COUNT(*) FROM held WHERE REPLAYED = 1) AS ACTUAL
    UNION ALL SELECT 2, '... of them holding no live rating (a ratings replay could not reach these; this one does)', NULL,
           (SELECT COUNT(*) FROM held WHERE REPLAYED = 1 AND LIVE_RATINGS = 0)
    UNION ALL SELECT 3, '... of them holding no transaction at all (they are retired and nothing is built in their place)', NULL,
           (SELECT COUNT(*) FROM held WHERE REPLAYED = 1 AND OPENED_ROWS = 0)
    UNION ALL SELECT 4, 'Neighbouring trips merge check''s existing join rule will send to the merge step with them', NULL,
           (SELECT COUNT(*) FROM held WHERE REPLAYED = 0)
    UNION ALL SELECT 5, 'Soft-deleted rows still marked OPENED on all those trips (the merge step would bring them back as live rows)', 0,
           (SELECT COALESCE(SUM(DEAD_OPENED_ROWS), 0) FROM held)
    UNION ALL SELECT 6, '... of them hotel rows (one would turn a trip with no stay into a trip with a stay)', 0,
           (SELECT COALESCE(SUM(DEAD_OPENED_HOTEL_ROWS), 0) FROM held)
    UNION ALL SELECT 7, 'Rating rows statement 2 would mark on a property trip that has no summary row', 0,
           (SELECT N FROM no_summary)
    UNION ALL SELECT 8, 'Guests among them merged away in GUEST_DIM (the customer merge step moves their trips to the surviving guest)', NULL,
           (SELECT N FROM merged_away)
    UNION ALL SELECT 9, 'Days the archival step keeps a retired trip before deleting it for good (TRIP_CONFIG)', NULL,
           (SELECT N FROM keep)
)
SELECT N, CHECK_NAME, EXPECTED, ACTUAL,
       CASE WHEN EXPECTED IS NULL THEN 'for the record' WHEN ACTUAL = EXPECTED THEN 'ok' ELSE 'LOOK' END AS VERDICT
FROM board
ORDER BY N;


-- P3. The trips still to replay, by market. Today the 'BEM + WLM' line is P2's first row; after each run of part 2
--     it falls; when the replay is complete it shows 0.
WITH ent AS (       /* the enterprise settings: merge check's fallback where a market has none of its own */
    SELECT MAX(IFF(KEY = 'MAX_TRIP_DAYS', VALUE, NULL)) AS MAX_TRIP_DAYS,
           MAX(IFF(KEY = 'TRIP_GAP_DAYS', VALUE, NULL)) AS TRIP_GAP_DAYS
    FROM DAAS_PROD.DAAS_CORE.TRIP_CONFIG
    WHERE CONFIG_SUBTYPE = 'ENTERPRISE' AND KEY IN ('MAX_TRIP_DAYS', 'TRIP_GAP_DAYS') AND ACTIVE_FLG = 'Y'
),
multi AS (
    SELECT TRIP_MASTER_ID, GUEST_UNIQUE_ID, MARKET_CD, TRIP_START_DT, TRIP_END_DT, TRIP_END_DT - TRIP_START_DT + 1 AS TRIP_DAYS
    FROM DAAS_PROD.DAAS_CORE.TRIP_MASTER
    WHERE DELETE_IND = 'N' AND TRIP_TYPE = 'MARKET' AND MARKET_CD IN ('BEM', 'WLM') AND TRIP_END_DT > TRIP_START_DT
),
caps AS (
    SELECT MARKET_CD, TRIP_START_DT,
           DAAS_PROD.DAAS_COMMON.TRIP_CONFIG_UDF_MARKET('MAX_TRIP_DAYS', MARKET_CD, TRIP_START_DT) AS CAP,
           DAAS_PROD.DAAS_COMMON.TRIP_CONFIG_UDF_MARKET('TRIP_GAP_DAYS', MARKET_CD, TRIP_START_DT) AS GAP
    FROM (SELECT DISTINCT MARKET_CD, TRIP_START_DT FROM multi)
),
targets AS (    /* the trips to replay: live BEM/WLM market trips over their cap with no hotel night, as v1.4 measures them */
    SELECT m.TRIP_MASTER_ID, m.GUEST_UNIQUE_ID, m.MARKET_CD, m.TRIP_START_DT, m.TRIP_END_DT, m.TRIP_DAYS,
           COALESCE(TRY_TO_NUMBER(c.CAP), TRY_TO_NUMBER(e.MAX_TRIP_DAYS)) AS CAP,
           COALESCE(TRY_TO_NUMBER(c.GAP), TRY_TO_NUMBER(e.TRIP_GAP_DAYS)) AS GAP
    FROM multi m
    JOIN caps c ON c.MARKET_CD = m.MARKET_CD AND c.TRIP_START_DT = m.TRIP_START_DT
    CROSS JOIN ent e
    WHERE m.TRIP_DAYS > COALESCE(TRY_TO_NUMBER(c.CAP), TRY_TO_NUMBER(e.MAX_TRIP_DAYS))
      AND NOT EXISTS (SELECT 1 FROM DAAS_PROD.DAAS_CORE.TRIP_DETAIL d
                      WHERE d.TRIP_MASTER_ID = m.TRIP_MASTER_ID AND d.DELETE_IND = 'N' AND d.TRANSACTION_TYPE = 'HOTEL')
)
SELECT market, trips_still_over_their_cap_no_hotel_night, guests, longest_days
FROM (
    SELECT 1 AS n, t.MARKET_CD AS market, COUNT(*) AS trips_still_over_their_cap_no_hotel_night,
           COUNT(DISTINCT t.GUEST_UNIQUE_ID) AS guests, MAX(t.TRIP_DAYS) AS longest_days
    FROM targets t
    GROUP BY t.MARKET_CD
    UNION ALL
    SELECT 2, 'BEM + WLM', COUNT(*), COUNT(DISTINCT t.GUEST_UNIQUE_ID), MAX(t.TRIP_DAYS)
    FROM targets t
) x
ORDER BY n, market;
