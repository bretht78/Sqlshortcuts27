-- DAASI-3641: PROD post-check after each replayed batch, and once more at the end. Read-only. Reads the before-pictures
-- R1 made (DAAS_PROD.DAAS_TEMP_WORK.DAASI_3641_P14_*) against the live tables, per batch; a batch not yet replayed shows
-- as "kept" everywhere, so the file can be run at any point. The checks are the week test's (W1-W5) and the proof's,
-- pointed at PROD. Two scratch tables are rebuilt each run (P0a, P0b: the fate of every trip of the target guests, and the
-- transaction-night ledger); the rest are plain SELECTs.
--
--   P0   which batches have run, from the targets themselves
--   P0a  the fate of every live-before trip of the target guests (scratch table P14_FATE)
--   P0b  the transaction-night ledger of every retired trip (scratch table P14_TXN)
--   P1   the targets: reachable, retired, replaced; new trips within cap — per batch
--   P2   the scoreboard per batch: kept identical / re-cut / merged by the join rule / LOOK
--   P3   every transaction-night of every retired trip on exactly one live trip (lost / doubled) — per batch
--   P4   the kept trips' live transactions, before against now, row for row (expect 0 / 0)
--   P5   theo conserved across the re-cut, by market — per batch
--   P6   the kept trips' theo, before against now (expect identical; PROD has no ratings drift)
--   P7   Tracy's measure: live BEM/WLM market trips over their cap with no hotel night, now (expect only the unreachable)
--   P8   the join rule's merges, each with its nominated partner (for Tracy's record)
--   P9   the runs: each step's minutes, against the task timeout
--   P10  anything to look at, listed (expect no rows)

USE ROLE DAAS_TEAM;
USE SECONDARY ROLES ALL;


-- P0. Which batches have run (batch 1 the canary, 2 everyone else; both at once if R3 ran unrestricted).
SELECT t.BATCH_NO,
       COUNT(*)                                            AS targets,
       COUNT_IF(t.RATING_ROWS > 0)                         AS reachable,
       COUNT_IF(m.DELETE_IND = 'Y')                        AS retired,
       MIN(IFF(m.DELETE_IND = 'Y', m.UPDATED_DTTM, NULL))  AS first_retired_at,
       MAX(IFF(m.DELETE_IND = 'Y', m.UPDATED_DTTM, NULL))  AS last_retired_at,
       CASE WHEN COUNT_IF(m.DELETE_IND = 'Y') = 0 THEN 'not yet'
            WHEN COUNT_IF(m.DELETE_IND = 'Y') >= COUNT_IF(t.RATING_ROWS > 0) THEN 'replayed'
            ELSE 'partly (look)' END                       AS state
FROM DAAS_PROD.DAAS_TEMP_WORK.DAASI_3641_P14_TRIPS t
JOIN DAAS_PROD.DAAS_CORE.TRIP_MASTER m ON m.TRIP_MASTER_ID = t.TRIP_MASTER_ID
GROUP BY t.BATCH_NO
ORDER BY t.BATCH_NO;


-- P0a. The fate of every live-before trip of the target guests. A target that is now retired was re-cut by the new rule;
--      another trip of the guest that is retired and was nominated by merge check since the mark was merged by the
--      pre-existing join rule (or, if it was over its cap with no stay at its own grain, re-cut by the new rule there);
--      a retired trip that was never nominated, a live trip whose dates, grain, code or guest changed, and a trip that
--      vanished are LOOKs — except a live trip whose dates moved because a transaction arrived since the before-picture
--      (PROD keeps moving during the replay; that is the pipeline's normal work, classed 'kept, extended by new play').
--      Everything else is kept, identical to before.
CREATE OR REPLACE TABLE DAAS_PROD.DAAS_TEMP_WORK.DAASI_3641_P14_FATE AS
WITH mark AS (SELECT MAX(IFF(mark = 'max_batch_id_before', value, NULL)) AS batch_before,
                     MAX(IFF(mark = 'max_trip_master_id_before', value, NULL)) AS tm_before
              FROM DAAS_PROD.DAAS_TEMP_WORK.DAASI_3641_P14_MARKS),
nominated AS (
    SELECT DISTINCT q.TRIP_MASTER_ID
    FROM DAAS_PROD.DAAS_CORE.TRIP_MERGE_QUEUE q
    CROSS JOIN mark
    WHERE q.BATCH_ID > mark.batch_before
),
tgt AS (SELECT TRIP_MASTER_ID, RATING_ROWS FROM DAAS_PROD.DAAS_TEMP_WORK.DAASI_3641_P14_TRIPS),
oth AS (SELECT TRIP_MASTER_ID FROM DAAS_PROD.DAAS_TEMP_WORK.DAASI_3641_P14_OTHER),
newplay AS (   -- PROD keeps moving during the replay: a live-before trip that now holds a transaction the before-picture
               -- never had (a rating that arrived since) was extended by new play, which is the pipeline's normal work
    SELECT DISTINCT d.TRIP_MASTER_ID
    FROM DAAS_PROD.DAAS_CORE.TRIP_DETAIL d
    JOIN DAAS_PROD.DAAS_TEMP_WORK.DAASI_3641_P14_TM_BEFORE t ON t.TRIP_MASTER_ID = d.TRIP_MASTER_ID
    LEFT JOIN (SELECT DISTINCT TRANSACTION_TABLE, TRANSACTION_TABLE_SK FROM DAAS_PROD.DAAS_TEMP_WORK.DAASI_3641_P14_TD_BEFORE) k
           ON k.TRANSACTION_TABLE = d.TRANSACTION_TABLE AND k.TRANSACTION_TABLE_SK = d.TRANSACTION_TABLE_SK
    WHERE d.DELETE_IND = 'N' AND k.TRANSACTION_TABLE_SK IS NULL
)
SELECT b.TRIP_MASTER_ID, b.GUEST_UNIQUE_ID, b.TRIP_TYPE, b.PROPERTY_CD, b.MARKET_CD,
       CASE b.TRIP_TYPE WHEN 'PROPERTY' THEN b.PROPERTY_CD WHEN 'MARKET' THEN b.MARKET_CD ELSE 'ENTERPRISE' END AS CODE,
       b.TRIP_START_DT, b.TRIP_END_DT, b.BATCH_NO,
       (t.TRIP_MASTER_ID IS NOT NULL)                       AS IS_TARGET,
       COALESCE(t.RATING_ROWS, 0) > 0                       AS IS_REACHABLE_TARGET,
       (o.TRIP_MASTER_ID IS NOT NULL)                       AS IS_OTHER_OVER_CAP,
       (n.TRIP_MASTER_ID IS NOT NULL)                       AS NOMINATED,
       (np.TRIP_MASTER_ID IS NOT NULL)                      AS HAS_NEW_PLAY,
       m.DELETE_IND                                         AS DELETE_IND_NOW,
       m.TRIP_START_DT AS TRIP_START_DT_NOW, m.TRIP_END_DT AS TRIP_END_DT_NOW,
       CASE WHEN m.TRIP_MASTER_ID IS NULL                                                   THEN 'LOOK: gone'
            WHEN m.DELETE_IND = 'Y' AND t.TRIP_MASTER_ID IS NOT NULL                         THEN 're-cut by the new rule (target)'
            WHEN m.DELETE_IND = 'Y' AND o.TRIP_MASTER_ID IS NOT NULL AND n.TRIP_MASTER_ID IS NOT NULL THEN 're-cut by the new rule (other grain, R2b)'
            WHEN m.DELETE_IND = 'Y' AND n.TRIP_MASTER_ID IS NOT NULL                         THEN 'merged by the join rule (nominated as a pair)'
            WHEN m.DELETE_IND = 'Y'                                                          THEN 'LOOK: retired without a nomination'
            WHEN (m.TRIP_START_DT <> b.TRIP_START_DT OR m.TRIP_END_DT <> b.TRIP_END_DT)
              AND m.GUEST_UNIQUE_ID = b.GUEST_UNIQUE_ID AND m.TRIP_TYPE = b.TRIP_TYPE
              AND EQUAL_NULL(m.PROPERTY_CD, b.PROPERTY_CD) AND EQUAL_NULL(m.MARKET_CD, b.MARKET_CD)
              AND np.TRIP_MASTER_ID IS NOT NULL                                                   THEN 'kept, extended by new play (not the replay)'
            WHEN m.TRIP_START_DT <> b.TRIP_START_DT OR m.TRIP_END_DT <> b.TRIP_END_DT
              OR m.GUEST_UNIQUE_ID <> b.GUEST_UNIQUE_ID OR m.TRIP_TYPE <> b.TRIP_TYPE
              OR NOT EQUAL_NULL(m.PROPERTY_CD, b.PROPERTY_CD) OR NOT EQUAL_NULL(m.MARKET_CD, b.MARKET_CD) THEN 'LOOK: changed in place'
            WHEN t.TRIP_MASTER_ID IS NOT NULL AND COALESCE(t.RATING_ROWS, 0) > 0              THEN 'target still live (batch not yet replayed, or LOOK)'
            WHEN t.TRIP_MASTER_ID IS NOT NULL                                                THEN 'target still live (unreachable: no live rating)'
            ELSE 'kept, identical' END                      AS FATE
FROM DAAS_PROD.DAAS_TEMP_WORK.DAASI_3641_P14_TM_BEFORE b
LEFT JOIN DAAS_PROD.DAAS_CORE.TRIP_MASTER m ON m.TRIP_MASTER_ID = b.TRIP_MASTER_ID
LEFT JOIN tgt t ON t.TRIP_MASTER_ID = b.TRIP_MASTER_ID
LEFT JOIN oth o ON o.TRIP_MASTER_ID = b.TRIP_MASTER_ID
LEFT JOIN nominated n ON n.TRIP_MASTER_ID = b.TRIP_MASTER_ID
LEFT JOIN newplay np ON np.TRIP_MASTER_ID = b.TRIP_MASTER_ID;

-- P0b. The transaction-night ledger: every live-before transaction row of every retired trip, and how many live trips of
--      the same guest and grain now hold it (expect exactly one each).
CREATE OR REPLACE TABLE DAAS_PROD.DAAS_TEMP_WORK.DAASI_3641_P14_TXN AS
WITH retired AS (
    SELECT TRIP_MASTER_ID, GUEST_UNIQUE_ID, TRIP_TYPE, PROPERTY_CD, MARKET_CD, CODE, BATCH_NO, FATE
    FROM DAAS_PROD.DAAS_TEMP_WORK.DAASI_3641_P14_FATE
    WHERE DELETE_IND_NOW = 'Y'
),
before_rows AS (
    SELECT r.TRIP_MASTER_ID AS RETIRED_TRIP, r.GUEST_UNIQUE_ID, r.TRIP_TYPE, r.PROPERTY_CD, r.MARKET_CD, r.CODE, r.BATCH_NO, r.FATE,
           d.TRANSACTION_TABLE, d.TRANSACTION_TABLE_SK, d.BUSINESS_START_DT
    FROM retired r
    JOIN DAAS_PROD.DAAS_TEMP_WORK.DAASI_3641_P14_TD_BEFORE d ON d.TRIP_MASTER_ID = r.TRIP_MASTER_ID
),
now_rows AS (
    SELECT n.TRIP_MASTER_ID, m.GUEST_UNIQUE_ID, m.TRIP_TYPE, m.PROPERTY_CD, m.MARKET_CD,
           n.TRANSACTION_TABLE, n.TRANSACTION_TABLE_SK, n.BUSINESS_START_DT
    FROM DAAS_PROD.DAAS_CORE.TRIP_DETAIL n
    JOIN DAAS_PROD.DAAS_CORE.TRIP_MASTER m ON m.TRIP_MASTER_ID = n.TRIP_MASTER_ID AND m.DELETE_IND = 'N'
    WHERE n.DELETE_IND = 'N'
      AND m.GUEST_UNIQUE_ID IN (SELECT DISTINCT GUEST_UNIQUE_ID FROM retired)
)
SELECT b.*, COUNT(n.TRIP_MASTER_ID) AS LIVE_TRIPS_HOLDING_IT
FROM before_rows b
LEFT JOIN now_rows n
  ON n.GUEST_UNIQUE_ID = b.GUEST_UNIQUE_ID AND n.TRIP_TYPE = b.TRIP_TYPE
 AND EQUAL_NULL(n.PROPERTY_CD, b.PROPERTY_CD) AND EQUAL_NULL(n.MARKET_CD, b.MARKET_CD)
 AND n.TRANSACTION_TABLE = b.TRANSACTION_TABLE AND n.TRANSACTION_TABLE_SK = b.TRANSACTION_TABLE_SK
 AND n.BUSINESS_START_DT = b.BUSINESS_START_DT
GROUP BY ALL;


-- P1. The targets, per batch: reachable, retired, and the trips the run built for those guests at BEM/WLM — within the
--     cap, with no hotel night longer than it. Expect retired = reachable for a replayed batch, built_over_cap 0,
--     longest_built_no_stay at or under the cap (1 BEM, 3 WLM).
WITH built AS (
    SELECT g.BATCH_NO, n.MARKET_CD,
           COUNT(*) AS trips_built,
           MAX(IFF(h.TRIP_MASTER_ID IS NULL, DATEDIFF(day, n.TRIP_START_DT, n.TRIP_END_DT) + 1, NULL)) AS longest_built_no_stay,
           COUNT_IF(h.TRIP_MASTER_ID IS NULL AND DATEDIFF(day, n.TRIP_START_DT, n.TRIP_END_DT) + 1 > IFF(n.MARKET_CD = 'BEM', 1, 3)) AS built_over_cap
    FROM DAAS_PROD.DAAS_CORE.TRIP_MASTER n
    JOIN (SELECT GUEST_UNIQUE_ID, MIN(BATCH_NO) AS BATCH_NO FROM DAAS_PROD.DAAS_TEMP_WORK.DAASI_3641_P14_TRIPS GROUP BY 1) g
      ON g.GUEST_UNIQUE_ID = n.GUEST_UNIQUE_ID
    LEFT JOIN (SELECT DISTINCT TRIP_MASTER_ID FROM DAAS_PROD.DAAS_CORE.TRIP_DETAIL WHERE TRANSACTION_TYPE = 'HOTEL' AND DELETE_IND = 'N'
               AND TRIP_MASTER_ID > (SELECT value FROM DAAS_PROD.DAAS_TEMP_WORK.DAASI_3641_P14_MARKS WHERE mark = 'max_trip_master_id_before')) h
      ON h.TRIP_MASTER_ID = n.TRIP_MASTER_ID
    WHERE n.TRIP_MASTER_ID > (SELECT value FROM DAAS_PROD.DAAS_TEMP_WORK.DAASI_3641_P14_MARKS WHERE mark = 'max_trip_master_id_before')
      AND n.DELETE_IND = 'N' AND n.TRIP_TYPE = 'MARKET' AND n.MARKET_CD IN ('BEM', 'WLM')
    GROUP BY 1, 2
)
SELECT t.BATCH_NO, t.MARKET_CD, MAX(t.MAX_TRIP_DAYS) AS cap,
       COUNT(*)                                        AS targets,
       COUNT_IF(t.RATING_ROWS > 0)                     AS reachable,
       COUNT_IF(f.DELETE_IND_NOW = 'Y')                AS retired,
       COUNT_IF(f.DELETE_IND_NOW = 'N' AND t.RATING_ROWS > 0) AS reachable_still_live,
       COALESCE(MAX(b.trips_built), 0)                 AS trips_built,
       MAX(b.longest_built_no_stay)                    AS longest_built_no_stay,
       COALESCE(MAX(b.built_over_cap), 0)              AS built_over_cap,
       CASE WHEN COUNT_IF(f.DELETE_IND_NOW = 'Y') = 0 THEN 'not yet'
            WHEN COUNT_IF(f.DELETE_IND_NOW = 'Y') = COUNT_IF(t.RATING_ROWS > 0) AND COALESCE(MAX(b.built_over_cap), 0) = 0 THEN 'ok'
            ELSE 'LOOK' END AS verdict
FROM DAAS_PROD.DAAS_TEMP_WORK.DAASI_3641_P14_TRIPS t
JOIN DAAS_PROD.DAAS_TEMP_WORK.DAASI_3641_P14_FATE f ON f.TRIP_MASTER_ID = t.TRIP_MASTER_ID
LEFT JOIN built b ON b.BATCH_NO = t.BATCH_NO AND b.MARKET_CD = t.MARKET_CD
GROUP BY t.BATCH_NO, t.MARKET_CD
ORDER BY t.BATCH_NO, t.MARKET_CD;


-- P2. The scoreboard, per batch: what became of every live-before trip of the batch's guests, at every grain. Expect
--     LOOK 0 everywhere; a replayed batch shows its reachable targets re-cut and the rest kept or merged by the join rule.
SELECT COALESCE(TO_VARCHAR(BATCH_NO), 'all') AS batch,
       COUNT(*)                                                                        AS trips_before,
       COUNT_IF(FATE = 'kept, identical')                                              AS kept_identical,
       COUNT_IF(FATE = 'kept, extended by new play (not the replay)')                  AS kept_extended_by_new_play,
       COUNT_IF(FATE = 're-cut by the new rule (target)')                              AS re_cut_targets,
       COUNT_IF(FATE = 're-cut by the new rule (other grain, R2b)')                    AS re_cut_other_grain,
       COUNT_IF(FATE = 'merged by the join rule (nominated as a pair)')                AS merged_by_the_join_rule,
       COUNT_IF(FATE LIKE 'target still live (batch not yet%')                         AS targets_awaiting_their_batch,
       COUNT_IF(FATE LIKE 'target still live (unreachable%')                           AS targets_unreachable,
       COUNT_IF(FATE LIKE 'LOOK%')                                                     AS look
FROM DAAS_PROD.DAAS_TEMP_WORK.DAASI_3641_P14_FATE
GROUP BY ROLLUP (BATCH_NO)
ORDER BY BATCH_NO NULLS LAST;


-- P3. Every transaction-night of every retired trip now sits on exactly one live trip of the same guest and grain.
--     Expect lost 0 and doubled 0 on every row.
SELECT COALESCE(TO_VARCHAR(BATCH_NO), 'all') AS batch,
       COUNT(DISTINCT RETIRED_TRIP)            AS retired_trips,
       COUNT(*)                                AS transaction_nights,
       COUNT_IF(LIVE_TRIPS_HOLDING_IT = 1)     AS on_exactly_one_live_trip,
       COUNT_IF(LIVE_TRIPS_HOLDING_IT = 0)     AS lost,
       COUNT_IF(LIVE_TRIPS_HOLDING_IT >= 2)    AS doubled,
       IFF(COUNT_IF(LIVE_TRIPS_HOLDING_IT <> 1) = 0, 'ok', 'LOOK') AS verdict
FROM DAAS_PROD.DAAS_TEMP_WORK.DAASI_3641_P14_TXN
GROUP BY ROLLUP (BATCH_NO)
ORDER BY BATCH_NO NULLS LAST;


-- P4. The kept trips' live transactions, before against now, on the business columns (audit stamps aside). Expect 0 / 0.
--     Rows the pipeline added to kept trips since the before-picture (new play; detail ids above the mark) are counted
--     apart, as information. Two passes over the detail rows of the kept trips: minutes.
WITH kept AS (SELECT TRIP_MASTER_ID FROM DAAS_PROD.DAAS_TEMP_WORK.DAASI_3641_P14_FATE WHERE FATE = 'kept, identical'),
k_before AS (SELECT d.TRIP_MASTER_ID, d.TRANSACTION_TABLE, d.TRANSACTION_TABLE_SK, d.TRANSACTION_TYPE, d.TRANSACTION_SUB_TYPE,
                    d.BUSINESS_START_DT, d.BUSINESS_END_DT
             FROM DAAS_PROD.DAAS_TEMP_WORK.DAASI_3641_P14_TD_BEFORE d JOIN kept k ON k.TRIP_MASTER_ID = d.TRIP_MASTER_ID),
k_now AS (SELECT d.TRIP_MASTER_ID, d.TRANSACTION_TABLE, d.TRANSACTION_TABLE_SK, d.TRANSACTION_TYPE, d.TRANSACTION_SUB_TYPE,
                 d.BUSINESS_START_DT, d.BUSINESS_END_DT
          FROM DAAS_PROD.DAAS_CORE.TRIP_DETAIL d JOIN kept k ON k.TRIP_MASTER_ID = d.TRIP_MASTER_ID
          WHERE d.DELETE_IND = 'N'
            AND d.TRIP_DETAIL_ID <= (SELECT value FROM DAAS_PROD.DAAS_TEMP_WORK.DAASI_3641_P14_MARKS WHERE mark = 'max_trip_detail_id_before')),
k_new AS (SELECT COUNT(*) AS rows_added_since_by_new_play
          FROM DAAS_PROD.DAAS_CORE.TRIP_DETAIL d JOIN kept k ON k.TRIP_MASTER_ID = d.TRIP_MASTER_ID
          WHERE d.DELETE_IND = 'N'
            AND d.TRIP_DETAIL_ID > (SELECT value FROM DAAS_PROD.DAAS_TEMP_WORK.DAASI_3641_P14_MARKS WHERE mark = 'max_trip_detail_id_before'))
SELECT (SELECT COUNT(*) FROM kept)                                                   AS kept_trips,
       (SELECT COUNT(*) FROM (SELECT * FROM k_before MINUS SELECT * FROM k_now))      AS rows_before_not_now,
       (SELECT COUNT(*) FROM (SELECT * FROM k_now MINUS SELECT * FROM k_before))      AS rows_now_not_before,
       (SELECT rows_added_since_by_new_play FROM k_new)                               AS rows_added_since_by_new_play_info;


-- P5. Theo conserved across the re-cut, by batch and market: the theo of every retired BEM/WLM trip of the batch's guests
--     (before) against the theo of every live trip the runs built for them there (now). Guests who played at that market
--     since the before-picture are left out of both sides (their totals have moved for a reason of their own) and counted.
--     Expect difference 0.00 once the batch's summaries have run (the summary step is in the same hourly run).
WITH guests AS (SELECT GUEST_UNIQUE_ID, MIN(BATCH_NO) AS BATCH_NO FROM DAAS_PROD.DAAS_TEMP_WORK.DAASI_3641_P14_TRIPS GROUP BY 1),
newplay AS (   -- guests with play at the market that the before-picture never held: their totals cannot be expected to agree
    SELECT DISTINCT m.GUEST_UNIQUE_ID, m.MARKET_CD
    FROM DAAS_PROD.DAAS_CORE.TRIP_DETAIL d
    JOIN DAAS_PROD.DAAS_CORE.TRIP_MASTER m ON m.TRIP_MASTER_ID = d.TRIP_MASTER_ID AND m.DELETE_IND = 'N'
    JOIN guests g ON g.GUEST_UNIQUE_ID = m.GUEST_UNIQUE_ID
    LEFT JOIN (SELECT DISTINCT TRANSACTION_TABLE, TRANSACTION_TABLE_SK FROM DAAS_PROD.DAAS_TEMP_WORK.DAASI_3641_P14_TD_BEFORE) k
           ON k.TRANSACTION_TABLE = d.TRANSACTION_TABLE AND k.TRANSACTION_TABLE_SK = d.TRANSACTION_TABLE_SK
    WHERE d.DELETE_IND = 'N' AND m.TRIP_TYPE = 'MARKET' AND m.MARKET_CD IN ('BEM', 'WLM') AND k.TRANSACTION_TABLE_SK IS NULL
),
retired AS (
    SELECT f.BATCH_NO, f.MARKET_CD,
           COUNT(*) AS retired_trips, COUNT(DISTINCT f.GUEST_UNIQUE_ID) AS guests_retired_at,
           COUNT_IF(np.GUEST_UNIQUE_ID IS NULL) AS retired_trips_compared,
           COUNT(DISTINCT IFF(np.GUEST_UNIQUE_ID IS NOT NULL, f.GUEST_UNIQUE_ID, NULL)) AS guests_with_new_play_left_out,
           ROUND(SUM(IFF(np.GUEST_UNIQUE_ID IS NULL, s.TOTAL_THEO_WIN_AMT, 0)), 2) AS theo_before
    FROM DAAS_PROD.DAAS_TEMP_WORK.DAASI_3641_P14_FATE f
    LEFT JOIN DAAS_PROD.DAAS_TEMP_WORK.DAASI_3641_P14_TS_BEFORE s ON s.TRIP_MASTER_ID = f.TRIP_MASTER_ID
    LEFT JOIN newplay np ON np.GUEST_UNIQUE_ID = f.GUEST_UNIQUE_ID AND np.MARKET_CD = f.MARKET_CD
    WHERE f.DELETE_IND_NOW = 'Y' AND f.TRIP_TYPE = 'MARKET' AND f.MARKET_CD IN ('BEM', 'WLM')
    GROUP BY 1, 2
),
built AS (
    SELECT g.BATCH_NO, n.MARKET_CD, COUNT(*) AS trips_built, ROUND(SUM(s.TOTAL_THEO_WIN_AMT), 2) AS theo_after
    FROM DAAS_PROD.DAAS_CORE.TRIP_MASTER n
    JOIN guests g ON g.GUEST_UNIQUE_ID = n.GUEST_UNIQUE_ID
    LEFT JOIN newplay np ON np.GUEST_UNIQUE_ID = n.GUEST_UNIQUE_ID AND np.MARKET_CD = n.MARKET_CD
    LEFT JOIN DAAS_PROD.DAAS_CORE.TRIP_SUMMARY s ON s.TRIP_MASTER_ID = n.TRIP_MASTER_ID
    WHERE n.TRIP_MASTER_ID > (SELECT value FROM DAAS_PROD.DAAS_TEMP_WORK.DAASI_3641_P14_MARKS WHERE mark = 'max_trip_master_id_before')
      AND n.DELETE_IND = 'N' AND n.TRIP_TYPE = 'MARKET' AND n.MARKET_CD IN ('BEM', 'WLM')
      AND np.GUEST_UNIQUE_ID IS NULL
    GROUP BY 1, 2
)
SELECT r.BATCH_NO, r.MARKET_CD, r.retired_trips, r.retired_trips_compared, r.guests_with_new_play_left_out, r.theo_before,
       COALESCE(b.trips_built, 0) AS trips_built_compared, COALESCE(b.theo_after, 0) AS theo_after,
       ROUND(COALESCE(b.theo_after, 0) - COALESCE(r.theo_before, 0), 2) AS difference,
       IFF(ROUND(COALESCE(b.theo_after, 0) - COALESCE(r.theo_before, 0), 2) = 0, 'ok', 'LOOK') AS verdict
FROM retired r
LEFT JOIN built b ON b.BATCH_NO = r.BATCH_NO AND b.MARKET_CD = r.MARKET_CD
ORDER BY r.BATCH_NO, r.MARKET_CD;


-- P6. The kept trips' theo, before against now, per batch. The runs rewrite the summaries of every trip they touch
--     (the twins and enterprise trips holding replayed ratings); PROD's ratings table is the same table before and
--     after, so expect theo_differs 0.
SELECT COALESCE(TO_VARCHAR(f.BATCH_NO), 'all') AS batch,
       COUNT(*)                                                                  AS kept_trips_with_both_summary_rows,
       COUNT_IF(ROUND(b.TOTAL_THEO_WIN_AMT, 2) = ROUND(n.TOTAL_THEO_WIN_AMT, 2))   AS theo_identical,
       COUNT_IF(ROUND(b.TOTAL_THEO_WIN_AMT, 2) <> ROUND(n.TOTAL_THEO_WIN_AMT, 2))  AS theo_differs,
       ROUND(SUM(b.TOTAL_THEO_WIN_AMT), 2) AS theo_before, ROUND(SUM(n.TOTAL_THEO_WIN_AMT), 2) AS theo_now
FROM DAAS_PROD.DAAS_TEMP_WORK.DAASI_3641_P14_FATE f
JOIN DAAS_PROD.DAAS_TEMP_WORK.DAASI_3641_P14_TS_BEFORE b ON b.TRIP_MASTER_ID = f.TRIP_MASTER_ID
JOIN DAAS_PROD.DAAS_CORE.TRIP_SUMMARY n ON n.TRIP_MASTER_ID = f.TRIP_MASTER_ID
WHERE f.FATE = 'kept, identical'
GROUP BY ROLLUP (f.BATCH_NO)
ORDER BY f.BATCH_NO NULLS LAST;


-- P7. Tracy's measure, now: every live BEM/WLM market trip in PROD longer than its cap with no hotel night — all guests,
--     not only the target guests. After the last batch, expect only the unreachable targets (R2c), listed by R0b's
--     trips_with_no_live_rating; after a batch, expect the other batches' targets plus those.
WITH ent AS (
    SELECT MAX(VALUE) AS MAX_TRIP_DAYS
    FROM DAAS_PROD.DAAS_CORE.TRIP_CONFIG
    WHERE CONFIG_SUBTYPE = 'ENTERPRISE' AND KEY = 'MAX_TRIP_DAYS' AND ACTIVE_FLG = 'Y'
),
multi AS (
    SELECT TRIP_MASTER_ID, GUEST_UNIQUE_ID, MARKET_CD, TRIP_START_DT, TRIP_END_DT,
           TRIP_END_DT - TRIP_START_DT + 1 AS TRIP_DAYS
    FROM DAAS_PROD.DAAS_CORE.TRIP_MASTER
    WHERE DELETE_IND = 'N' AND TRIP_TYPE = 'MARKET' AND MARKET_CD IN ('BEM', 'WLM') AND TRIP_END_DT > TRIP_START_DT
),
caps AS (
    SELECT MARKET_CD, TRIP_START_DT,
           DAAS_PROD.DAAS_COMMON.TRIP_CONFIG_UDF_MARKET('MAX_TRIP_DAYS', MARKET_CD, TRIP_START_DT) AS CAP
    FROM (SELECT DISTINCT MARKET_CD, TRIP_START_DT FROM multi)
),
over AS (
    SELECT m.*
    FROM multi m
    JOIN caps c ON c.MARKET_CD = m.MARKET_CD AND c.TRIP_START_DT = m.TRIP_START_DT
    CROSS JOIN ent e
    WHERE m.TRIP_DAYS > COALESCE(TRY_TO_NUMBER(c.CAP), TRY_TO_NUMBER(e.MAX_TRIP_DAYS))
      AND NOT EXISTS (SELECT 1 FROM DAAS_PROD.DAAS_CORE.TRIP_DETAIL d
                      WHERE d.TRIP_MASTER_ID = m.TRIP_MASTER_ID AND d.DELETE_IND = 'N' AND d.TRANSACTION_TYPE = 'HOTEL')
)
SELECT o.MARKET_CD,
       COUNT(*)                                                         AS live_trips_over_cap_no_stay_now,
       COUNT_IF(t.TRIP_MASTER_ID IS NOT NULL AND t.RATING_ROWS = 0)     AS of_them_unreachable_targets,
       COUNT_IF(t.TRIP_MASTER_ID IS NOT NULL AND t.RATING_ROWS > 0)     AS of_them_targets_awaiting_their_batch,
       COUNT_IF(t.TRIP_MASTER_ID IS NULL)                               AS of_them_not_a_target_look,
       MAX(o.TRIP_DAYS)                                                 AS longest_days
FROM over o
LEFT JOIN DAAS_PROD.DAAS_TEMP_WORK.DAASI_3641_P14_TRIPS t ON t.TRIP_MASTER_ID = o.TRIP_MASTER_ID
GROUP BY 1
ORDER BY 1;


-- P8. The join rule's merges, each with the nominated trip next to it or over it — the pre-existing pairing behaviour on
--     a replay (week test W5), for Tracy's record. One row per merged trip; a row without a partner is a LOOK.
WITH mark AS (SELECT MAX(IFF(mark = 'max_batch_id_before', value, NULL)) AS batch_before FROM DAAS_PROD.DAAS_TEMP_WORK.DAASI_3641_P14_MARKS),
nominated AS (SELECT DISTINCT q.TRIP_MASTER_ID FROM DAAS_PROD.DAAS_CORE.TRIP_MERGE_QUEUE q CROSS JOIN mark WHERE q.BATCH_ID > mark.batch_before),
merged AS (SELECT * FROM DAAS_PROD.DAAS_TEMP_WORK.DAASI_3641_P14_FATE WHERE FATE = 'merged by the join rule (nominated as a pair)')
SELECT r.BATCH_NO, r.TRIP_TYPE, r.CODE, r.GUEST_UNIQUE_ID, r.TRIP_MASTER_ID, r.TRIP_START_DT, r.TRIP_END_DT,
       LISTAGG(p.TRIP_MASTER_ID || ' [' || p.TRIP_START_DT || '..' || p.TRIP_END_DT || IFF(p.IS_TARGET, ', target', '') || ']', ' | ')
           WITHIN GROUP (ORDER BY p.TRIP_START_DT) AS nominated_partners
FROM merged r
LEFT JOIN nominated n ON n.TRIP_MASTER_ID <> r.TRIP_MASTER_ID
LEFT JOIN DAAS_PROD.DAAS_TEMP_WORK.DAASI_3641_P14_FATE p
       ON p.TRIP_MASTER_ID = n.TRIP_MASTER_ID AND p.GUEST_UNIQUE_ID = r.GUEST_UNIQUE_ID AND p.TRIP_TYPE = r.TRIP_TYPE
      AND EQUAL_NULL(p.PROPERTY_CD, r.PROPERTY_CD) AND EQUAL_NULL(p.MARKET_CD, r.MARKET_CD)
      AND p.TRIP_START_DT <= DATEADD(day, 1, r.TRIP_END_DT) AND p.TRIP_END_DT >= DATEADD(day, -1, r.TRIP_START_DT)
GROUP BY ALL
ORDER BY (nominated_partners IS NULL) DESC, r.BATCH_NO, r.TRIP_TYPE, r.CODE, r.GUEST_UNIQUE_ID, r.TRIP_START_DT
LIMIT 1000;

-- P8b. The same, counted: per batch and grain, how many trips the join rule merged, and how many of them have a partner.
WITH mark AS (SELECT MAX(IFF(mark = 'max_batch_id_before', value, NULL)) AS batch_before FROM DAAS_PROD.DAAS_TEMP_WORK.DAASI_3641_P14_MARKS),
nominated AS (SELECT DISTINCT q.TRIP_MASTER_ID FROM DAAS_PROD.DAAS_CORE.TRIP_MERGE_QUEUE q CROSS JOIN mark WHERE q.BATCH_ID > mark.batch_before),
merged AS (SELECT * FROM DAAS_PROD.DAAS_TEMP_WORK.DAASI_3641_P14_FATE WHERE FATE = 'merged by the join rule (nominated as a pair)'),
with_partner AS (
    SELECT DISTINCT r.TRIP_MASTER_ID
    FROM merged r
    JOIN nominated n ON n.TRIP_MASTER_ID <> r.TRIP_MASTER_ID
    JOIN DAAS_PROD.DAAS_TEMP_WORK.DAASI_3641_P14_FATE p
      ON p.TRIP_MASTER_ID = n.TRIP_MASTER_ID AND p.GUEST_UNIQUE_ID = r.GUEST_UNIQUE_ID AND p.TRIP_TYPE = r.TRIP_TYPE
     AND EQUAL_NULL(p.PROPERTY_CD, r.PROPERTY_CD) AND EQUAL_NULL(p.MARKET_CD, r.MARKET_CD)
     AND p.TRIP_START_DT <= DATEADD(day, 1, r.TRIP_END_DT) AND p.TRIP_END_DT >= DATEADD(day, -1, r.TRIP_START_DT)
)
SELECT COALESCE(TO_VARCHAR(r.BATCH_NO), 'all') AS batch, r.TRIP_TYPE,
       COUNT(*) AS merged_by_the_join_rule,
       COUNT(w.TRIP_MASTER_ID) AS with_a_nominated_partner,
       COUNT(*) - COUNT(w.TRIP_MASTER_ID) AS without_a_partner_look,
       COUNT(DISTINCT r.CODE) AS properties_and_markets
FROM merged r
LEFT JOIN with_partner w ON w.TRIP_MASTER_ID = r.TRIP_MASTER_ID
GROUP BY ROLLUP (r.BATCH_NO), r.TRIP_TYPE
ORDER BY r.BATCH_NO NULLS LAST, r.TRIP_TYPE;


-- P9. The runs: every trip job's batch since the mark, with minutes. Read the merge's minutes against the task timeout
--     (R0c); the ratings step and the merge are the ones that grow with a batch.
SELECT j.JOB_NAME, b.BATCH_ID, b.BATCH_STATUS, b.BATCH_START_DATE, b.UPDATED_DTTM AS last_update,
       ROUND(DATEDIFF(second, b.BATCH_START_DATE, b.UPDATED_DTTM) / 60, 1) AS minutes
FROM DAAS_PROD.DAAS_COMMON.BATCH_S02 b
JOIN DAAS_PROD.DAAS_COMMON.JOB j ON j.JOB_ID = b.JOB_ID
WHERE j.JOB_NAME LIKE 'TRIP%'
  AND b.BATCH_ID > (SELECT value FROM DAAS_PROD.DAAS_TEMP_WORK.DAASI_3641_P14_MARKS WHERE mark = 'max_batch_id_before')
ORDER BY b.BATCH_ID;


-- P10. Anything to look at, listed (expect no rows): every trip whose fate is a LOOK, and every retired trip with a
--      transaction-night lost or doubled.
SELECT 'fate' AS what, BATCH_NO, TRIP_TYPE, CODE, GUEST_UNIQUE_ID, TRIP_MASTER_ID, TRIP_START_DT, TRIP_END_DT, FATE AS detail
FROM DAAS_PROD.DAAS_TEMP_WORK.DAASI_3641_P14_FATE
WHERE FATE LIKE 'LOOK%'
UNION ALL
SELECT 'transaction-night', BATCH_NO, TRIP_TYPE, CODE, GUEST_UNIQUE_ID, RETIRED_TRIP, BUSINESS_START_DT, BUSINESS_START_DT,
       TRANSACTION_TABLE || ' ' || TRANSACTION_TABLE_SK || ' on ' || LIVE_TRIPS_HOLDING_IT || ' live trips'
FROM DAAS_PROD.DAAS_TEMP_WORK.DAASI_3641_P14_TXN
WHERE LIVE_TRIPS_HOLDING_IT <> 1
ORDER BY 1, 2, 3, 4, 5
LIMIT 500;
