-- DAASI-3641: the checks left to run after the last batch. Read-only: nothing here changes anything.
--
-- All seven batches are in. PC1 and PC4 were read on 20 Nov at 6:45 AM Central:
--   PC1  all 378,798 listed trips are retired and re-cut, and none is still as it was. The longest trip with no
--        hotel stay is 1 day in BEM and 3 in WLM, and none is over its cap.
--   PC4  comp worth (the comp dollars the play earns) equals the property side to the cent on every line but two,
--        where one trip differs: batch 5 WLM ($10.99 under on the line) and 'not listed' WLM ($2.53 under).
--
-- What is left, in the order to run it. Run each statement on its own and send me what it returns.
--   The case
--     1  PC6   no trip is left over its cap
--     2  PC7   Tracy's query: no trip over the max trip value
--     3  PC4d  the trips whose comp worth differs, row for row (new: it shows what those two trips are)
--     4  PC2   everything that sat on a retired trip sits on exactly one trip now
--     5  PC2b  what PC2 calls doubled was on two trips before the replay too
--     6  PC3   theo (the house's expected win from the play) is what it was
--   For the record
--     7  PC5   the property side is as it was (the longest one: several minutes)
--     8  C4    the hourly runs since 14 Nov: what each batch cost the trip jobs
--     9  C9    the nightly archival step: which nights it ran, and when (new)
-- PC6, PC7, PC2, PC2b, PC3 and PC5 are the statements of the post-check file, unchanged; C4 is part 1's with a later
-- start date.
--
-- Use the Large warehouse. These read the before-pictures and the list of trips, so leave Z (the drops) until
-- sign-off.

USE ROLE DAAS_TEAM;
USE SECONDARY ROLES ALL;


-- 1. PC6: the trips still to replay. Live BEM/WLM market trips over their cap with no hotel night, listed or not.
--    Expect 0 on the 'BEM + WLM' line.
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


-- 2. PC7: Tracy's query from DAASI-3376, as she wrote it. The longest market trip per end date in the reporting
--    view, hotel stays left out, longest first. Expect 3 or less on the first row and no BEM row above 1. A screen
--    of the first rows is enough. The view reads the trip dynamic tables, which refresh on their own schedule: if
--    the top rows still show long trips, run it again later.
select
market_cd,
trip_end_dt,
max(trip_days)
from daas_prod.daas_core_marketing_vw.trip_summary_vw
where market_cd in ('BEM', 'WLM')
and trip_type = 'MARKET'
and hotel_flg = 'N'
group by 1, 2
order by 3 desc, 1, 2 desc;


-- 3. PC4d (new): every market trip whose comp worth is not what its property trips add up to, each followed by the
--    property trips that hold its ratings. counted_in_pc4_under names the PC4 column that counts the trip. The ones
--    under comp_worth_differs come first (two on 20 Nov); the rest are among the trips PC4 leaves out, because a
--    later ordinary run valued them apart from their property trips. Expect a few trips. Send me every row
--    (download the result if it is more than a screen). It takes about as long as PC4.
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


-- 4. PC2: the transactions, by SK. Every transaction-night (one row per transaction and business date) that sat on
--    a retired BEM/WLM market trip, and where it sits now. Expect lost 0 and on_a_trip_that_does_not_cover_its_date
--    0. doubled will not be 0: PC2b says what those are.
WITH gone AS (       /* the BEM/WLM market trips that were live in the before-picture and are retired now (or retired and since archived) */
    SELECT b.TRIP_MASTER_ID, b.MARKET_CD
    FROM DAAS_PROD.DAAS_TEMP_WORK.DAASI_3641_BEFORE_TRIP_MASTER b
    LEFT JOIN DAAS_PROD.DAAS_CORE.TRIP_MASTER m ON m.TRIP_MASTER_ID = b.TRIP_MASTER_ID
    WHERE b.TRIP_TYPE = 'MARKET' AND b.MARKET_CD IN ('BEM', 'WLM') AND b.DELETE_IND = 'N'
      AND (m.TRIP_MASTER_ID IS NULL OR m.DELETE_IND = 'Y')
),
keys AS (       /* every transaction-night on those trips in the before-picture: one row per transaction and business date.
                   WAS_LIVE 1: the row counted there (not soft-deleted, still OPENED) */
    SELECT g.MARKET_CD, d.TRANSACTION_TABLE, d.TRANSACTION_TABLE_SK, d.BUSINESS_START_DT,
           MAX(IFF(d.DELETE_IND = 'N' AND d.TRANSACTION_SUB_TYPE = 'OPENED', 1, 0)) AS WAS_LIVE
    FROM gone g
    JOIN DAAS_PROD.DAAS_TEMP_WORK.DAASI_3641_BEFORE_TRIP_DETAIL d ON d.TRIP_MASTER_ID = g.TRIP_MASTER_ID
    GROUP BY g.MARKET_CD, d.TRANSACTION_TABLE, d.TRANSACTION_TABLE_SK, d.BUSINESS_START_DT
),
found AS (      /* where each sits now: on how many live market trips of its market, and on how many live trips of the other kinds */
    SELECT k.MARKET_CD, k.TRANSACTION_TABLE, k.TRANSACTION_TABLE_SK, k.BUSINESS_START_DT, k.WAS_LIVE,
           COUNT(DISTINCT IFF(m.TRIP_TYPE = 'MARKET' AND m.MARKET_CD = k.MARKET_CD, m.TRIP_MASTER_ID, NULL)) AS MARKET_TRIPS,
           COUNT_IF(m.TRIP_TYPE = 'MARKET' AND m.MARKET_CD = k.MARKET_CD
                    AND k.BUSINESS_START_DT NOT BETWEEN m.TRIP_START_DT AND m.TRIP_END_DT)                    AS OUTSIDE,
           COUNT_IF(m.TRIP_TYPE <> 'MARKET')                                                                 AS OTHER_KINDS
    FROM keys k
    LEFT JOIN DAAS_PROD.DAAS_CORE.TRIP_DETAIL d
           ON d.TRANSACTION_TABLE = k.TRANSACTION_TABLE AND d.TRANSACTION_TABLE_SK = k.TRANSACTION_TABLE_SK
          AND d.BUSINESS_START_DT = k.BUSINESS_START_DT AND d.DELETE_IND = 'N' AND d.TRANSACTION_SUB_TYPE = 'OPENED'
    LEFT JOIN DAAS_PROD.DAAS_CORE.TRIP_MASTER m ON m.TRIP_MASTER_ID = d.TRIP_MASTER_ID AND m.DELETE_IND = 'N'
    GROUP BY k.MARKET_CD, k.TRANSACTION_TABLE, k.TRANSACTION_TABLE_SK, k.BUSINESS_START_DT, k.WAS_LIVE
),
t AS (SELECT MARKET_CD, COUNT(*) AS TRIPS FROM gone GROUP BY MARKET_CD),
f AS (
    SELECT MARKET_CD,
           COUNT_IF(WAS_LIVE = 1)                                             AS NIGHTS,
           COUNT_IF(WAS_LIVE = 1 AND MARKET_TRIPS = 1)                        AS ON_ONE,
           COUNT_IF(WAS_LIVE = 1 AND MARKET_TRIPS = 0 AND OTHER_KINDS > 0)    AS LOST,
           COUNT_IF(WAS_LIVE = 1 AND MARKET_TRIPS > 1)                        AS DOUBLED,
           COUNT_IF(WAS_LIVE = 1 AND OUTSIDE > 0)                             AS OUTSIDE,
           COUNT_IF(WAS_LIVE = 0 AND MARKET_TRIPS > 0)                        AS BROUGHT_BACK,
           COUNT_IF(WAS_LIVE = 1 AND MARKET_TRIPS = 0 AND OTHER_KINDS = 0)    AS WITHDRAWN
    FROM found
    GROUP BY MARKET_CD
)
SELECT t.MARKET_CD                  AS market,
       t.TRIPS                      AS trips_retired,
       COALESCE(f.NIGHTS, 0)        AS transaction_nights_on_the_retired_trips,
       COALESCE(f.ON_ONE, 0)        AS now_on_exactly_one_live_trip,
       COALESCE(f.LOST, 0)          AS lost,
       COALESCE(f.DOUBLED, 0)       AS doubled,
       COALESCE(f.OUTSIDE, 0)       AS on_a_trip_that_does_not_cover_its_date,
       COALESCE(f.BROUGHT_BACK, 0)  AS not_live_before_live_now,
       COALESCE(f.WITHDRAWN, 0)     AS no_longer_live_on_any_trip
FROM t
LEFT JOIN f ON f.MARKET_CD = t.MARKET_CD
ORDER BY t.MARKET_CD;


-- 5. PC2b: the doubled ones against the before-pictures. On 14 Nov they were transactions recorded under two guests
--    (guest -1 and the real guest), which sat on two trips before the replay as well. Expect
--    on_more_trips_now_than_before 0 and on_two_trips_of_one_guest 0.
WITH gone AS (       /* the BEM/WLM market trips that were live in the before-picture and are retired now (or retired and since archived) */
    SELECT b.TRIP_MASTER_ID, b.MARKET_CD
    FROM DAAS_PROD.DAAS_TEMP_WORK.DAASI_3641_BEFORE_TRIP_MASTER b
    LEFT JOIN DAAS_PROD.DAAS_CORE.TRIP_MASTER m ON m.TRIP_MASTER_ID = b.TRIP_MASTER_ID
    WHERE b.TRIP_TYPE = 'MARKET' AND b.MARKET_CD IN ('BEM', 'WLM') AND b.DELETE_IND = 'N'
      AND (m.TRIP_MASTER_ID IS NULL OR m.DELETE_IND = 'Y')
),
keys AS (       /* every transaction-night on those trips in the before-picture: one row per transaction and business date.
                   WAS_LIVE 1: the row counted there (not soft-deleted, still OPENED) */
    SELECT g.MARKET_CD, d.TRANSACTION_TABLE, d.TRANSACTION_TABLE_SK, d.BUSINESS_START_DT,
           MAX(IFF(d.DELETE_IND = 'N' AND d.TRANSACTION_SUB_TYPE = 'OPENED', 1, 0)) AS WAS_LIVE
    FROM gone g
    JOIN DAAS_PROD.DAAS_TEMP_WORK.DAASI_3641_BEFORE_TRIP_DETAIL d ON d.TRIP_MASTER_ID = g.TRIP_MASTER_ID
    GROUP BY g.MARKET_CD, d.TRANSACTION_TABLE, d.TRANSACTION_TABLE_SK, d.BUSINESS_START_DT
),
now_on AS (     /* PC2's doubled: counted on a retired trip before, on two or more live market trips of its market now */
    SELECT k.MARKET_CD, k.TRANSACTION_TABLE, k.TRANSACTION_TABLE_SK, k.BUSINESS_START_DT,
           COUNT(DISTINCT m.TRIP_MASTER_ID)        AS TRIPS_NOW,
           COUNT(DISTINCT m.GUEST_UNIQUE_ID)       AS GUESTS_NOW,
           MAX(IFF(m.GUEST_UNIQUE_ID = -1, 1, 0))  AS WITH_GUEST_MINUS_1
    FROM keys k
    JOIN DAAS_PROD.DAAS_CORE.TRIP_DETAIL d
      ON d.TRANSACTION_TABLE = k.TRANSACTION_TABLE AND d.TRANSACTION_TABLE_SK = k.TRANSACTION_TABLE_SK
     AND d.BUSINESS_START_DT = k.BUSINESS_START_DT AND d.DELETE_IND = 'N' AND d.TRANSACTION_SUB_TYPE = 'OPENED'
    JOIN DAAS_PROD.DAAS_CORE.TRIP_MASTER m ON m.TRIP_MASTER_ID = d.TRIP_MASTER_ID AND m.DELETE_IND = 'N'
                                       AND m.TRIP_TYPE = 'MARKET' AND m.MARKET_CD = k.MARKET_CD
    WHERE k.WAS_LIVE = 1
    GROUP BY k.MARKET_CD, k.TRANSACTION_TABLE, k.TRANSACTION_TABLE_SK, k.BUSINESS_START_DT
    HAVING COUNT(DISTINCT m.TRIP_MASTER_ID) > 1
),
was_on AS (     /* the same ones in the before-picture: on how many live market trips of their market they counted then */
    SELECT o.MARKET_CD, o.TRANSACTION_TABLE, o.TRANSACTION_TABLE_SK, o.BUSINESS_START_DT,
           COUNT(DISTINCT m.TRIP_MASTER_ID) AS TRIPS_BEFORE
    FROM now_on o
    JOIN DAAS_PROD.DAAS_TEMP_WORK.DAASI_3641_BEFORE_TRIP_DETAIL d
      ON d.TRANSACTION_TABLE = o.TRANSACTION_TABLE AND d.TRANSACTION_TABLE_SK = o.TRANSACTION_TABLE_SK
     AND d.BUSINESS_START_DT = o.BUSINESS_START_DT AND d.DELETE_IND = 'N' AND d.TRANSACTION_SUB_TYPE = 'OPENED'
    JOIN DAAS_PROD.DAAS_TEMP_WORK.DAASI_3641_BEFORE_TRIP_MASTER m ON m.TRIP_MASTER_ID = d.TRIP_MASTER_ID AND m.DELETE_IND = 'N'
                                       AND m.TRIP_TYPE = 'MARKET' AND m.MARKET_CD = o.MARKET_CD
    GROUP BY o.MARKET_CD, o.TRANSACTION_TABLE, o.TRANSACTION_TABLE_SK, o.BUSINESS_START_DT
)
SELECT o.MARKET_CD                                              AS market,
       COUNT(*)                                                 AS doubled,
       COUNT_IF(COALESCE(w.TRIPS_BEFORE, 0) >= o.TRIPS_NOW)     AS on_as_many_trips_before,
       COUNT_IF(COALESCE(w.TRIPS_BEFORE, 0) <  o.TRIPS_NOW)     AS on_more_trips_now_than_before,
       COUNT_IF(o.GUESTS_NOW > 1)                               AS on_trips_of_different_guests,
       COUNT_IF(o.WITH_GUEST_MINUS_1 = 1)                       AS of_them_one_is_guest_minus_1,
       COUNT_IF(o.GUESTS_NOW = 1)                               AS on_two_trips_of_one_guest
FROM now_on o
LEFT JOIN was_on w
       ON w.MARKET_CD = o.MARKET_CD AND w.TRANSACTION_TABLE = o.TRANSACTION_TABLE
      AND w.TRANSACTION_TABLE_SK = o.TRANSACTION_TABLE_SK AND w.BUSINESS_START_DT = o.BUSINESS_START_DT
GROUP BY o.MARKET_CD
ORDER BY o.MARKET_CD;


-- 6. PC3: theo (the house's expected win from the play), per market. Expect theo_difference 0.00 and
--    summary_difference 0.00.
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
per_key AS (
    SELECT k.MARKET_CD, k.SK, k.THEO, k.TIMES_BEFORE,
           COUNT(l.SK) AS LIVE_ROWS, COALESCE(SUM(l.ON_ITS_MARKET), 0) AS MARKET_ROWS
    FROM keys k
    LEFT JOIN live l ON l.MARKET_CD = k.MARKET_CD AND l.SK = k.SK
    GROUP BY k.MARKET_CD, k.SK, k.THEO, k.TIMES_BEFORE
),
ratings AS (
    SELECT MARKET_CD,
           SUM(THEO * TIMES_BEFORE)             AS THEO_AS_COUNTED,
           SUM(THEO * (TIMES_BEFORE - 1))       AS THEO_MORE_THAN_ONCE,
           SUM(IFF(LIVE_ROWS = 0, THEO, 0))     AS THEO_WITHDRAWN,
           SUM(THEO * MARKET_ROWS)              AS THEO_CARRIED
    FROM per_key
    GROUP BY MARKET_CD
),
holders AS (SELECT DISTINCT MARKET_CD, TRIP_MASTER_ID FROM live WHERE ON_ITS_MARKET = 1),
on_them AS (    /* every live rating on the trips they sit on now, valued the same way */
    SELECT h.MARKET_CD, COUNT(DISTINCT h.TRIP_MASTER_ID) AS TRIPS, SUM(IFF(f.GAME_TYPE_CD IN ('S', 'P', 'O'), f.THEO_WIN_AMT, 0)) AS THEO
    FROM holders h
    JOIN DAAS_PROD.DAAS_CORE.TRIP_DETAIL d ON d.TRIP_MASTER_ID = h.TRIP_MASTER_ID
    JOIN DAAS_PROD.DAAS_CORE.RATINGS_FACT f ON f.RATINGS_FACT_SK = d.TRANSACTION_TABLE_SK
    WHERE d.TRANSACTION_TYPE = 'RATINGS' AND d.DELETE_IND = 'N'
    GROUP BY h.MARKET_CD
),
summ AS (       /* and what those trips' summary rows say */
    SELECT h.MARKET_CD, SUM(s.TOTAL_THEO_WIN_AMT) AS THEO
    FROM holders h
    LEFT JOIN DAAS_PROD.DAAS_CORE.TRIP_SUMMARY s ON s.TRIP_MASTER_ID = h.TRIP_MASTER_ID
    GROUP BY h.MARKET_CD
),
before_ AS (
    SELECT g.MARKET_CD, COUNT(*) AS TRIPS, SUM(s.TOTAL_THEO_WIN_AMT) AS THEO
    FROM gone g
    LEFT JOIN DAAS_PROD.DAAS_TEMP_WORK.DAASI_3641_BEFORE_TRIP_SUMMARY s ON s.TRIP_MASTER_ID = g.TRIP_MASTER_ID
    GROUP BY g.MARKET_CD
)
SELECT o.MARKET_CD                                                              AS market,
       o.TRIPS                                                                  AS trips_retired,
       ROUND(o.THEO, 2)                                                         AS theo_before,
       ROUND(r.THEO_AS_COUNTED, 2)                                              AS theo_of_the_same_ratings_today,
       ROUND(r.THEO_MORE_THAN_ONCE, 2)                                          AS of_it_counted_more_than_once_before,
       ROUND(r.THEO_WITHDRAWN, 2)                                               AS of_it_no_longer_live_on_any_trip,
       n.TRIPS                                                                  AS trips_they_sit_on_now,
       ROUND(r.THEO_CARRIED, 2)                                                 AS theo_they_carry_now,
       ROUND(COALESCE(r.THEO_CARRIED, 0)
             - (COALESCE(r.THEO_AS_COUNTED, 0) - COALESCE(r.THEO_MORE_THAN_ONCE, 0) - COALESCE(r.THEO_WITHDRAWN, 0)), 2) AS theo_difference,
       ROUND(n.THEO, 2)                                                         AS all_theo_on_those_trips,
       ROUND(u.THEO, 2)                                                         AS their_summaries_say,
       ROUND(COALESCE(u.THEO, 0) - COALESCE(n.THEO, 0), 2)                      AS summary_difference
FROM before_ o
LEFT JOIN ratings r ON r.MARKET_CD = o.MARKET_CD
LEFT JOIN on_them n ON n.MARKET_CD = o.MARKET_CD
LEFT JOIN summ u    ON u.MARKET_CD = o.MARKET_CD
ORDER BY o.MARKET_CD;


-- 7. PC5 (for the record): the property side, row for row against the before-pictures. Expect ok on rows 5, 6 and
--    10; the other rows are counts. The longest of these checks.
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
counts AS (     /* a changed row shows on both sides of a comparison, as it was and as it is: it is counted once */
    SELECT 'PT' AS WHAT, COUNT(*) AS N FROM pt
    UNION ALL SELECT 'MARK',  COUNT(*) FROM marked
    UNION ALL SELECT 'BUSY',  COUNT(*) FROM busy
    UNION ALL SELECT 'QUIET', COUNT(*) FROM quiet
    UNION ALL SELECT 'TS',    GREATEST((SELECT COUNT(*) FROM (SELECT * FROM ts_b MINUS SELECT * FROM ts_n)),
                                       (SELECT COUNT(*) FROM (SELECT * FROM ts_n MINUS SELECT * FROM ts_b)))
    UNION ALL SELECT 'DAS',   GREATEST((SELECT COUNT(*) FROM (SELECT * FROM das_b MINUS SELECT * FROM das_n)),
                                       (SELECT COUNT(*) FROM (SELECT * FROM das_n MINUS SELECT * FROM das_b)))
    UNION ALL SELECT 'CW',    COUNT(DISTINCT TRIP_MASTER_ID) FROM cw
    UNION ALL SELECT 'CWSUM', COALESCE(ROUND(SUM(CHANGE)), 0) FROM cw
    UNION ALL SELECT 'DENOM', COUNT(*) FROM judged
    UNION ALL SELECT 'TIED',  COALESCE(COUNT_IF(TIED >= 2 AND VALUES_NOT_FIRST = 0), 0) FROM judged
),
board AS (
    SELECT l.N, l.CHECK_NAME,
           CASE WHEN l.WHAT IN ('TS', 'DAS') THEN 0
                WHEN l.WHAT = 'TIED' THEN (SELECT N FROM counts WHERE WHAT = 'DENOM') END AS EXPECTED,
           c.N AS ACTUAL
    FROM (VALUES
                 ( 1, 'PT', 'Property trips that held a rating of a retired trip in the before-picture: the trips the TRIP_DETAIL calls mark'),
                 ( 2, 'MARK', 'Rating rows on them with a replay counter higher than in the before-picture: the rows it marked'),
                 ( 3, 'BUSY', 'Of those trips, changed by other activity since the before-picture (set aside; expect few)'),
                 ( 4, 'QUIET', 'The rest, compared below with the before-picture'),
                 ( 5, 'TS', '... TRIP_SUMMARY rows with a figure that differs (run stamps, comp worth, most-played denomination aside)'),
                 ( 6, 'DAS', '... DAILY_ACTIVITY_SUMMARY rows with a figure that differs (same three aside)'),
                 ( 7, 'CW', '... trips whose comp worth is not what it was, on the summary row or a daily row'),
                 ( 8, 'CWSUM', '... and the total of those changes on the summary rows, in comp dollars (rounded)'),
                 ( 9, 'DENOM', '... trips whose most-played denomination changed, on the summary row or a daily row'),
                 (10, 'TIED', '... of them, trips where the old and the new value are two of the denominations tied for most played')
         ) AS l (N, WHAT, CHECK_NAME)
    JOIN counts c ON c.WHAT = l.WHAT
)
SELECT N, CHECK_NAME, EXPECTED, ACTUAL,
       CASE WHEN EXPECTED IS NULL THEN 'for the record' WHEN ACTUAL = EXPECTED THEN 'ok' ELSE 'LOOK' END AS VERDICT
FROM board
ORDER BY N;


-- 8. C4 (for the record): the hourly runs since 14 Nov, one row each, with the minutes of the run and of its heavy
--    steps. A row an hour: please download the result and attach it.
WITH runs AS (
    SELECT r.RUN_STARTED,
           ROUND(DATEDIFF(second, r.RUN_STARTED, MAX(r.ENDED)) / 60, 1)   AS RUN_MINUTES,
           ROUND(SUM(IFF(r.JOB_NAME = 'TRIP_MERGE_CHECK', r.SECONDS, 0)) / 60, 1)     AS MERGE_CHECK_MINUTES,
           ROUND(SUM(IFF(r.JOB_NAME = 'TRIP_MERGE', r.SECONDS, 0)) / 60, 1)           AS MERGE_MINUTES,
           ROUND(SUM(IFF(r.JOB_NAME = 'TRIP_SUMMARY_WRAPPER', r.SECONDS, 0)) / 60, 1) AS SUMMARY_MINUTES,
           ROUND(SUM(IFF(r.JOB_NAME = 'TRIP_COMP_WORTH', r.SECONDS, 0)) / 60, 1)      AS COMP_WORTH_MINUTES,
           COUNT_IF(r.BATCH_STATUS <> 'SUCCESS')                                  AS STEPS_NOT_AT_SUCCESS,
           MAX(IFF(r.JOB_NAME = 'TRIP_SUMMARY_WRAPPER', r.BATCH_ID, NULL))        AS SUMMARY_BATCH_ID
    FROM (SELECT j.JOB_NAME, b.BATCH_ID, b.BATCH_STATUS, COALESCE(b.BATCH_END_DATE, b.UPDATED_DTTM) AS ENDED,
                 DATEDIFF(second, b.BATCH_START_DATE, COALESCE(b.BATCH_END_DATE, b.UPDATED_DTTM)) AS SECONDS,
                 MAX(IFF(j.JOB_NAME = 'TRIP_FILTERED_TXNS', b.BATCH_START_DATE, NULL))
                     OVER (ORDER BY b.BATCH_START_DATE ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS RUN_STARTED
          FROM DAAS_PROD.DAAS_COMMON.BATCH_S02 b
          JOIN DAAS_PROD.DAAS_COMMON.JOB j ON j.JOB_ID = b.JOB_ID
          WHERE j.JOB_NAME LIKE 'TRIP%' AND b.BATCH_START_DATE >= '2026-11-14 04:00') r
    WHERE r.RUN_STARTED IS NOT NULL
    GROUP BY r.RUN_STARTED
),
m AS (
    SELECT BATCH_ID,
           MAX(IFF(LOWER(BATCH_METRIC_CD) = 'summary_insert_count', TRY_TO_NUMBER(BATCH_METRIC_VALUE::VARCHAR), NULL)) AS TRIP_SUMMARIES_INSERTED,
           MAX(IFF(LOWER(BATCH_METRIC_CD) = 'summary_update_count', TRY_TO_NUMBER(BATCH_METRIC_VALUE::VARCHAR), NULL)) AS TRIP_SUMMARIES_UPDATED,
           MAX(IFF(LOWER(BATCH_METRIC_CD) = 'daily_summary_insert_count', TRY_TO_NUMBER(BATCH_METRIC_VALUE::VARCHAR), NULL)) AS DAILY_SUMMARIES_INSERTED,
           MAX(IFF(LOWER(BATCH_METRIC_CD) = 'daily_summary_update_count', TRY_TO_NUMBER(BATCH_METRIC_VALUE::VARCHAR), NULL)) AS DAILY_SUMMARIES_UPDATED
    FROM DAAS_PROD.DAAS_COMMON.BATCH_METRICS_S02
    WHERE BATCH_ID IN (SELECT SUMMARY_BATCH_ID FROM runs)
    GROUP BY BATCH_ID
)
SELECT runs.RUN_STARTED AS run_started_pacific, runs.RUN_MINUTES AS run_minutes, runs.MERGE_CHECK_MINUTES AS merge_check_minutes,
       runs.MERGE_MINUTES AS merge_minutes, runs.SUMMARY_MINUTES AS summary_minutes, runs.COMP_WORTH_MINUTES AS comp_worth_minutes,
       runs.STEPS_NOT_AT_SUCCESS AS steps_not_at_success, runs.SUMMARY_BATCH_ID AS summary_batch_id,
       m.TRIP_SUMMARIES_INSERTED AS trip_summaries_inserted,
       m.TRIP_SUMMARIES_UPDATED AS trip_summaries_updated,
       m.DAILY_SUMMARIES_INSERTED AS daily_summaries_inserted,
       m.DAILY_SUMMARIES_UPDATED AS daily_summaries_updated
FROM runs
LEFT JOIN m ON m.BATCH_ID = runs.SUMMARY_BATCH_ID
ORDER BY runs.RUN_STARTED;


-- 9. C9 (new, for the record): the archival step in the trip jobs' batch log since 10 Nov, one row each time it
--    ran: when it started and ended (Pacific), how long it took and how it ended. A night with no row had none.
SELECT j.JOB_NAME AS job_name, b.BATCH_ID AS batch_id, b.BATCH_STATUS AS batch_status,
       b.BATCH_START_DATE AS started_pacific, COALESCE(b.BATCH_END_DATE, b.UPDATED_DTTM) AS ended_pacific,
       ROUND(DATEDIFF(second, b.BATCH_START_DATE, COALESCE(b.BATCH_END_DATE, b.UPDATED_DTTM)) / 60, 1) AS minutes
FROM DAAS_PROD.DAAS_COMMON.BATCH_S02 b
JOIN DAAS_PROD.DAAS_COMMON.JOB j ON j.JOB_ID = b.JOB_ID
WHERE j.JOB_NAME LIKE '%ARCHIV%' AND b.BATCH_START_DATE >= '2026-11-10'
ORDER BY b.BATCH_START_DATE;
