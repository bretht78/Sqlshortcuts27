-- DAASI-3641: do the R3 statements do exactly what they say? Four checks, no replay. T1-T3 run in PROD and change
-- nothing; T4 runs the real write in UAT against one guest's ratings, with the pipeline idle, and reads back what it did.
--
--   T1  the privilege: a zero-row probe of the UPDATE (who can run the R3 statements)
--   T2  the targeting: what each statement would update, counted by the statements' own logic — the four lines must add
--       up to R0b exactly
--   T3  the statements themselves, in PROD, each with a condition that makes it match no row: compiles, updates 0
--   T4  the effect, in UAT, on one guest: counter up by one, stamps set, nothing else touched, rows in the stream
--
-- Why these four cover it. Each R3 statement is one UPDATE whose only moving parts are (a) which rows it picks and (b)
-- what it writes on them. T2 runs the picking logic for real, as a SELECT, and pins it against an independently
-- written count (R0b); T3 proves each exact text compiles in PROD under the role that will run it; T4 shows (b) on real
-- rows (the write is the same three columns in every statement). Everything after the UPDATE is the pipeline's own
-- work, already shown in the proof and the week test. The statements are R3-C (the canary, optional), R3 (everyone
-- except the long-run guests), R3-L (the long-run guests, first step) and R3-Z (the statement with no grouping, which
-- replays what R3-L leaves): see R3 in DAASI_3641_PROD_V14_REPLAY.sql for why the replay is split this way. The picking
-- logic was also run on synthetic trips against a re-implementation of the merge's loop: the groups do not overlap,
-- together they are exactly the ungrouped statement's rows, R3 never needs more than 30 passes, and the trips built
-- are the same as one ungrouped replay would build.

USE ROLE DAAS_TEAM;
USE SECONDARY ROLES ALL;


-- T1. The privilege. An UPDATE that matches no row still needs UPDATE on the table: a 'SQL access control error' means
--     your role cannot run the R3 statements and Pete's can (expected); '0 rows updated' means it could. Changes
--     nothing either way.
UPDATE DAAS_PROD.DAAS_CORE.RATINGS_FACT RF
SET RF.REPLAY_COUNTER = RF.REPLAY_COUNTER
WHERE 1 = 0;


-- T2. The targeting. What each statement would update now, counted by the statements' own logic (the same query as
--     R3-0 in the replay file). The four rating_rows add up to R0b's ratings_fact_rows_to_update, trips to its
--     trips_the_replay_reaches (run R0b the same day, since PROD moves); most_passes_the_merge_needs is 30 or less on
--     lines 1 and 2. Each line is what its UPDATE must report as rows updated. A few minutes on Large.
WITH ent AS (
    SELECT MAX(VALUE) AS MAX_TRIP_DAYS
    FROM DAAS_PROD.DAAS_CORE.TRIP_CONFIG
    WHERE CONFIG_SUBTYPE = 'ENTERPRISE' AND KEY = 'MAX_TRIP_DAYS' AND ACTIVE_FLG = 'Y'
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
targets AS (    /* the trips to replay: live BEM/WLM market trips over their cap with no hotel night */
    SELECT m.TRIP_MASTER_ID, m.GUEST_UNIQUE_ID, m.MARKET_CD, m.TRIP_START_DT, m.TRIP_END_DT, m.TRIP_DAYS,
           COALESCE(TRY_TO_NUMBER(c.CAP), TRY_TO_NUMBER(e.MAX_TRIP_DAYS)) AS CAP,
           COALESCE(TRY_TO_NUMBER(c.GAP), 1)                              AS GAP
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
placed AS (     /* each trip with its run: the passes the merge's loop needs for the whole run, and the trip's place in it */
    SELECT n.*,
           CEIL((DATEDIFF(day, MIN(n.TRIP_START_DT) OVER (PARTITION BY n.GUEST_UNIQUE_ID, n.MARKET_CD, n.RUN_NO),
                               MAX(n.TRIP_END_DT)   OVER (PARTITION BY n.GUEST_UNIQUE_ID, n.MARKET_CD, n.RUN_NO)) + 1)
                / MIN(n.CAP) OVER (PARTITION BY n.GUEST_UNIQUE_ID, n.MARKET_CD, n.RUN_NO))                AS RUN_PASSES,
           MAX(n.CAP) OVER (PARTITION BY n.GUEST_UNIQUE_ID, n.MARKET_CD, n.RUN_NO)                        AS RUN_CAP,
           ROW_NUMBER() OVER (PARTITION BY n.GUEST_UNIQUE_ID, n.MARKET_CD, n.RUN_NO
                              ORDER BY n.TRIP_START_DT, n.TRIP_END_DT, n.TRIP_MASTER_ID)                 AS PLACE_IN_RUN
    FROM numbered n
),
picked AS (     /* a guest's longest run decides the guest's group: more than 30 passes = a long-run guest */
    SELECT p.*, MAX(p.RUN_PASSES) OVER (PARTITION BY p.GUEST_UNIQUE_ID) AS GUEST_PASSES
    FROM placed p
)
SELECT CASE WHEN t.GUEST_PASSES <= 30 AND MOD(ABS(HASH(t.GUEST_UNIQUE_ID)), 100) = 0 THEN '1  R3-C (the canary)'
            WHEN t.GUEST_PASSES <= 30                                                THEN '2  R3 (everyone else)'
            WHEN NOT (t.RUN_PASSES > 30 AND t.RUN_CAP = 1 AND MOD(t.PLACE_IN_RUN, 2) = 0) THEN '3a R3-L (long-run guests)'
            ELSE                                                                          '3b R3-Z (what R3-L leaves)'
       END                                    AS statement,
       COUNT(DISTINCT d.TRANSACTION_TABLE_SK) AS rating_rows,
       COUNT(DISTINCT t.TRIP_MASTER_ID)       AS trips,
       COUNT(DISTINCT t.GUEST_UNIQUE_ID)      AS guests,
       MAX(IFF(t.GUEST_PASSES > 30 AND t.RUN_PASSES > 30 AND t.RUN_CAP = 1,
               CEIL(t.TRIP_DAYS / t.CAP), t.RUN_PASSES)) AS most_passes_the_merge_needs
FROM DAAS_PROD.DAAS_CORE.TRIP_DETAIL d
JOIN picked t ON t.TRIP_MASTER_ID = d.TRIP_MASTER_ID
WHERE d.TRANSACTION_TABLE = 'RATINGS_FACT' AND d.DELETE_IND = 'N' AND d.TRANSACTION_SUB_TYPE = 'OPENED'
GROUP BY 1
ORDER BY 1;

-- T2b. A sample of what they would touch, with the values the write replaces, so the reviewer sees the rows: 20
--      ratings of one target trip (current counter and stamps).
WITH ent AS (
    SELECT MAX(VALUE) AS MAX_TRIP_DAYS
    FROM DAAS_PROD.DAAS_CORE.TRIP_CONFIG
    WHERE CONFIG_SUBTYPE = 'ENTERPRISE' AND KEY = 'MAX_TRIP_DAYS' AND ACTIVE_FLG = 'Y'
),
multi AS (
    SELECT TRIP_MASTER_ID, GUEST_UNIQUE_ID, MARKET_CD, TRIP_START_DT, TRIP_END_DT, TRIP_END_DT - TRIP_START_DT + 1 AS TRIP_DAYS
    FROM DAAS_PROD.DAAS_CORE.TRIP_MASTER
    WHERE DELETE_IND = 'N' AND TRIP_TYPE = 'MARKET' AND MARKET_CD IN ('BEM', 'WLM') AND TRIP_END_DT > TRIP_START_DT
),
caps AS (
    SELECT MARKET_CD, TRIP_START_DT,
           DAAS_PROD.DAAS_COMMON.TRIP_CONFIG_UDF_MARKET('MAX_TRIP_DAYS', MARKET_CD, TRIP_START_DT) AS CAP
    FROM (SELECT DISTINCT MARKET_CD, TRIP_START_DT FROM multi)
),
one_target AS (
    SELECT m.*
    FROM multi m
    JOIN caps c ON c.MARKET_CD = m.MARKET_CD AND c.TRIP_START_DT = m.TRIP_START_DT
    CROSS JOIN ent e
    WHERE m.TRIP_DAYS > COALESCE(TRY_TO_NUMBER(c.CAP), TRY_TO_NUMBER(e.MAX_TRIP_DAYS))
      AND NOT EXISTS (SELECT 1 FROM DAAS_PROD.DAAS_CORE.TRIP_DETAIL d
                      WHERE d.TRIP_MASTER_ID = m.TRIP_MASTER_ID AND d.DELETE_IND = 'N' AND d.TRANSACTION_TYPE = 'HOTEL')
    ORDER BY m.TRIP_END_DT DESC
    LIMIT 1
)
SELECT t.MARKET_CD, t.TRIP_MASTER_ID, t.TRIP_START_DT, t.TRIP_END_DT, t.TRIP_DAYS,
       r.RATINGS_FACT_SK, r.BUSINESS_DT, r.PROPERTY_CD, r.REPLAY_COUNTER, r.UPDATED_DTTM, r.UPDATED_BY
FROM one_target t
JOIN DAAS_PROD.DAAS_CORE.TRIP_DETAIL d ON d.TRIP_MASTER_ID = t.TRIP_MASTER_ID
JOIN DAAS_PROD.DAAS_CORE.RATINGS_FACT r ON r.RATINGS_FACT_SK = d.TRANSACTION_TABLE_SK
WHERE d.TRANSACTION_TABLE = 'RATINGS_FACT' AND d.DELETE_IND = 'N' AND d.TRANSACTION_SUB_TYPE = 'OPENED'
ORDER BY r.BUSINESS_DT
LIMIT 20;


-- T3. The statements themselves, in PROD, each made to match no row: text for text as in the replay file, with ONE
--     added line at the end of the WHERE (AND 1 = 0). Each compiles against PROD's objects under the role that runs it
--     and reports '0 rows updated'. They need the UPDATE privilege (T1), so these are Pete's to run; a syntax, object or
--     privilege error is the only thing that could stop a statement on the day, and it surfaces here instead.
-- T3-C. R3-C, the canary.
UPDATE DAAS_PROD.DAAS_CORE.RATINGS_FACT RF
SET RF.REPLAY_COUNTER = COALESCE(RF.REPLAY_COUNTER, 0) + 1,
    RF.UPDATED_DTTM   = CURRENT_TIMESTAMP(),
    RF.UPDATED_BY     = CURRENT_USER()
WHERE RF.RATINGS_FACT_SK IN (
    WITH ent AS (
        SELECT MAX(VALUE) AS MAX_TRIP_DAYS
        FROM DAAS_PROD.DAAS_CORE.TRIP_CONFIG
        WHERE CONFIG_SUBTYPE = 'ENTERPRISE' AND KEY = 'MAX_TRIP_DAYS' AND ACTIVE_FLG = 'Y'
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
    targets AS (    /* the trips to replay: live BEM/WLM market trips over their cap with no hotel night */
        SELECT m.TRIP_MASTER_ID, m.GUEST_UNIQUE_ID, m.MARKET_CD, m.TRIP_START_DT, m.TRIP_END_DT, m.TRIP_DAYS,
               COALESCE(TRY_TO_NUMBER(c.CAP), TRY_TO_NUMBER(e.MAX_TRIP_DAYS)) AS CAP,
               COALESCE(TRY_TO_NUMBER(c.GAP), 1)                              AS GAP
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
    placed AS (     /* each trip with its run: the passes the merge's loop needs for the whole run, and the trip's place in it */
        SELECT n.*,
               CEIL((DATEDIFF(day, MIN(n.TRIP_START_DT) OVER (PARTITION BY n.GUEST_UNIQUE_ID, n.MARKET_CD, n.RUN_NO),
                                   MAX(n.TRIP_END_DT)   OVER (PARTITION BY n.GUEST_UNIQUE_ID, n.MARKET_CD, n.RUN_NO)) + 1)
                    / MIN(n.CAP) OVER (PARTITION BY n.GUEST_UNIQUE_ID, n.MARKET_CD, n.RUN_NO))                AS RUN_PASSES,
               MAX(n.CAP) OVER (PARTITION BY n.GUEST_UNIQUE_ID, n.MARKET_CD, n.RUN_NO)                        AS RUN_CAP,
               ROW_NUMBER() OVER (PARTITION BY n.GUEST_UNIQUE_ID, n.MARKET_CD, n.RUN_NO
                                  ORDER BY n.TRIP_START_DT, n.TRIP_END_DT, n.TRIP_MASTER_ID)                 AS PLACE_IN_RUN
        FROM numbered n
    ),
    picked AS (     /* a guest's longest run decides the guest's group: more than 30 passes = a long-run guest */
        SELECT p.*, MAX(p.RUN_PASSES) OVER (PARTITION BY p.GUEST_UNIQUE_ID) AS GUEST_PASSES
        FROM placed p
    )
    SELECT d.TRANSACTION_TABLE_SK
    FROM DAAS_PROD.DAAS_CORE.TRIP_DETAIL d
    JOIN picked t ON t.TRIP_MASTER_ID = d.TRIP_MASTER_ID
    WHERE d.TRANSACTION_TABLE = 'RATINGS_FACT' AND d.DELETE_IND = 'N' AND d.TRANSACTION_SUB_TYPE = 'OPENED'
      AND t.GUEST_PASSES <= 30   /* the main group ... */
      AND MOD(ABS(HASH(t.GUEST_UNIQUE_ID)), 100) = 0   /* ... one guest in a hundred */
)
AND 1 = 0;                                           /* the one added line: match nothing */

-- T3-M. R3, the main replay.
UPDATE DAAS_PROD.DAAS_CORE.RATINGS_FACT RF
SET RF.REPLAY_COUNTER = COALESCE(RF.REPLAY_COUNTER, 0) + 1,
    RF.UPDATED_DTTM   = CURRENT_TIMESTAMP(),
    RF.UPDATED_BY     = CURRENT_USER()
WHERE RF.RATINGS_FACT_SK IN (
    WITH ent AS (
        SELECT MAX(VALUE) AS MAX_TRIP_DAYS
        FROM DAAS_PROD.DAAS_CORE.TRIP_CONFIG
        WHERE CONFIG_SUBTYPE = 'ENTERPRISE' AND KEY = 'MAX_TRIP_DAYS' AND ACTIVE_FLG = 'Y'
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
    targets AS (    /* the trips to replay: live BEM/WLM market trips over their cap with no hotel night */
        SELECT m.TRIP_MASTER_ID, m.GUEST_UNIQUE_ID, m.MARKET_CD, m.TRIP_START_DT, m.TRIP_END_DT, m.TRIP_DAYS,
               COALESCE(TRY_TO_NUMBER(c.CAP), TRY_TO_NUMBER(e.MAX_TRIP_DAYS)) AS CAP,
               COALESCE(TRY_TO_NUMBER(c.GAP), 1)                              AS GAP
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
    placed AS (     /* each trip with its run: the passes the merge's loop needs for the whole run, and the trip's place in it */
        SELECT n.*,
               CEIL((DATEDIFF(day, MIN(n.TRIP_START_DT) OVER (PARTITION BY n.GUEST_UNIQUE_ID, n.MARKET_CD, n.RUN_NO),
                                   MAX(n.TRIP_END_DT)   OVER (PARTITION BY n.GUEST_UNIQUE_ID, n.MARKET_CD, n.RUN_NO)) + 1)
                    / MIN(n.CAP) OVER (PARTITION BY n.GUEST_UNIQUE_ID, n.MARKET_CD, n.RUN_NO))                AS RUN_PASSES,
               MAX(n.CAP) OVER (PARTITION BY n.GUEST_UNIQUE_ID, n.MARKET_CD, n.RUN_NO)                        AS RUN_CAP,
               ROW_NUMBER() OVER (PARTITION BY n.GUEST_UNIQUE_ID, n.MARKET_CD, n.RUN_NO
                                  ORDER BY n.TRIP_START_DT, n.TRIP_END_DT, n.TRIP_MASTER_ID)                 AS PLACE_IN_RUN
        FROM numbered n
    ),
    picked AS (     /* a guest's longest run decides the guest's group: more than 30 passes = a long-run guest */
        SELECT p.*, MAX(p.RUN_PASSES) OVER (PARTITION BY p.GUEST_UNIQUE_ID) AS GUEST_PASSES
        FROM placed p
    )
    SELECT d.TRANSACTION_TABLE_SK
    FROM DAAS_PROD.DAAS_CORE.TRIP_DETAIL d
    JOIN picked t ON t.TRIP_MASTER_ID = d.TRIP_MASTER_ID
    WHERE d.TRANSACTION_TABLE = 'RATINGS_FACT' AND d.DELETE_IND = 'N' AND d.TRANSACTION_SUB_TYPE = 'OPENED'
      AND t.GUEST_PASSES <= 30   /* everyone except the long-run guests */
)
AND 1 = 0;                                           /* the one added line: match nothing */

-- T3-L. R3-L, the long-run guests, first step.
UPDATE DAAS_PROD.DAAS_CORE.RATINGS_FACT RF
SET RF.REPLAY_COUNTER = COALESCE(RF.REPLAY_COUNTER, 0) + 1,
    RF.UPDATED_DTTM   = CURRENT_TIMESTAMP(),
    RF.UPDATED_BY     = CURRENT_USER()
WHERE RF.RATINGS_FACT_SK IN (
    WITH ent AS (
        SELECT MAX(VALUE) AS MAX_TRIP_DAYS
        FROM DAAS_PROD.DAAS_CORE.TRIP_CONFIG
        WHERE CONFIG_SUBTYPE = 'ENTERPRISE' AND KEY = 'MAX_TRIP_DAYS' AND ACTIVE_FLG = 'Y'
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
    targets AS (    /* the trips to replay: live BEM/WLM market trips over their cap with no hotel night */
        SELECT m.TRIP_MASTER_ID, m.GUEST_UNIQUE_ID, m.MARKET_CD, m.TRIP_START_DT, m.TRIP_END_DT, m.TRIP_DAYS,
               COALESCE(TRY_TO_NUMBER(c.CAP), TRY_TO_NUMBER(e.MAX_TRIP_DAYS)) AS CAP,
               COALESCE(TRY_TO_NUMBER(c.GAP), 1)                              AS GAP
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
    placed AS (     /* each trip with its run: the passes the merge's loop needs for the whole run, and the trip's place in it */
        SELECT n.*,
               CEIL((DATEDIFF(day, MIN(n.TRIP_START_DT) OVER (PARTITION BY n.GUEST_UNIQUE_ID, n.MARKET_CD, n.RUN_NO),
                                   MAX(n.TRIP_END_DT)   OVER (PARTITION BY n.GUEST_UNIQUE_ID, n.MARKET_CD, n.RUN_NO)) + 1)
                    / MIN(n.CAP) OVER (PARTITION BY n.GUEST_UNIQUE_ID, n.MARKET_CD, n.RUN_NO))                AS RUN_PASSES,
               MAX(n.CAP) OVER (PARTITION BY n.GUEST_UNIQUE_ID, n.MARKET_CD, n.RUN_NO)                        AS RUN_CAP,
               ROW_NUMBER() OVER (PARTITION BY n.GUEST_UNIQUE_ID, n.MARKET_CD, n.RUN_NO
                                  ORDER BY n.TRIP_START_DT, n.TRIP_END_DT, n.TRIP_MASTER_ID)                 AS PLACE_IN_RUN
        FROM numbered n
    ),
    picked AS (     /* a guest's longest run decides the guest's group: more than 30 passes = a long-run guest */
        SELECT p.*, MAX(p.RUN_PASSES) OVER (PARTITION BY p.GUEST_UNIQUE_ID) AS GUEST_PASSES
        FROM placed p
    )
    SELECT d.TRANSACTION_TABLE_SK
    FROM DAAS_PROD.DAAS_CORE.TRIP_DETAIL d
    JOIN picked t ON t.TRIP_MASTER_ID = d.TRIP_MASTER_ID
    WHERE d.TRANSACTION_TABLE = 'RATINGS_FACT' AND d.DELETE_IND = 'N' AND d.TRANSACTION_SUB_TYPE = 'OPENED'
      AND t.GUEST_PASSES > 30   /* the long-run guests ... */
      /* ... less every second trip of a run of theirs that is long and at a one-day cap */
      AND NOT (t.RUN_PASSES > 30 AND t.RUN_CAP = 1 AND MOD(t.PLACE_IN_RUN, 2) = 0)
)
AND 1 = 0;                                           /* the one added line: match nothing */

-- T3-Z. R3-Z, the statement with no grouping.
UPDATE DAAS_PROD.DAAS_CORE.RATINGS_FACT RF
SET RF.REPLAY_COUNTER = COALESCE(RF.REPLAY_COUNTER, 0) + 1,
    RF.UPDATED_DTTM   = CURRENT_TIMESTAMP(),
    RF.UPDATED_BY     = CURRENT_USER()
WHERE RF.RATINGS_FACT_SK IN (
    WITH ent AS (
        SELECT MAX(VALUE) AS MAX_TRIP_DAYS
        FROM DAAS_PROD.DAAS_CORE.TRIP_CONFIG
        WHERE CONFIG_SUBTYPE = 'ENTERPRISE' AND KEY = 'MAX_TRIP_DAYS' AND ACTIVE_FLG = 'Y'
    ),
    multi AS (
        SELECT TRIP_MASTER_ID, GUEST_UNIQUE_ID, MARKET_CD, TRIP_START_DT, TRIP_END_DT - TRIP_START_DT + 1 AS TRIP_DAYS
        FROM DAAS_PROD.DAAS_CORE.TRIP_MASTER
        WHERE DELETE_IND = 'N' AND TRIP_TYPE = 'MARKET' AND MARKET_CD IN ('BEM', 'WLM') AND TRIP_END_DT > TRIP_START_DT
    ),
    caps AS (
        SELECT MARKET_CD, TRIP_START_DT,
               DAAS_PROD.DAAS_COMMON.TRIP_CONFIG_UDF_MARKET('MAX_TRIP_DAYS', MARKET_CD, TRIP_START_DT) AS CAP
        FROM (SELECT DISTINCT MARKET_CD, TRIP_START_DT FROM multi)
    ),
    targets AS (
        SELECT m.TRIP_MASTER_ID
        FROM multi m
        JOIN caps c ON c.MARKET_CD = m.MARKET_CD AND c.TRIP_START_DT = m.TRIP_START_DT
        CROSS JOIN ent e
        WHERE m.TRIP_DAYS > COALESCE(TRY_TO_NUMBER(c.CAP), TRY_TO_NUMBER(e.MAX_TRIP_DAYS))
          AND NOT EXISTS (SELECT 1 FROM DAAS_PROD.DAAS_CORE.TRIP_DETAIL d
                          WHERE d.TRIP_MASTER_ID = m.TRIP_MASTER_ID AND d.DELETE_IND = 'N' AND d.TRANSACTION_TYPE = 'HOTEL')
    )
    SELECT d.TRANSACTION_TABLE_SK
    FROM DAAS_PROD.DAAS_CORE.TRIP_DETAIL d
    JOIN targets t ON t.TRIP_MASTER_ID = d.TRIP_MASTER_ID
    WHERE d.TRANSACTION_TABLE = 'RATINGS_FACT' AND d.DELETE_IND = 'N' AND d.TRANSACTION_SUB_TYPE = 'OPENED'
)
AND 1 = 0;                                           /* the one added line: match nothing */


-- T4. The effect, in UAT, on one guest. UAT's pipeline is idle (root task suspended, no rating task on demand), so the
--     rows go into UAT's ratings stream and stay there; nothing downstream runs. Four statements.
-- T4a. Pick one guest in UAT who holds over-cap no-stay BEM/WLM trips with live ratings (the R3 statements' targeting,
--      pointed at UAT), and keep the rows they would pick for that guest, with their current values.
CREATE OR REPLACE TABLE DAAS_UAT.DAAS_TEMP_WORK.DAASI_3641_R3_CHECK AS
WITH ent AS (
    SELECT MAX(VALUE) AS MAX_TRIP_DAYS
    FROM DAAS_UAT.DAAS_CORE.TRIP_CONFIG
    WHERE CONFIG_SUBTYPE = 'ENTERPRISE' AND KEY = 'MAX_TRIP_DAYS' AND ACTIVE_FLG = 'Y'
),
multi AS (
    SELECT TRIP_MASTER_ID, GUEST_UNIQUE_ID, MARKET_CD, TRIP_START_DT, TRIP_END_DT, TRIP_END_DT - TRIP_START_DT + 1 AS TRIP_DAYS
    FROM DAAS_UAT.DAAS_CORE.TRIP_MASTER
    WHERE DELETE_IND = 'N' AND TRIP_TYPE = 'MARKET' AND MARKET_CD IN ('BEM', 'WLM') AND TRIP_END_DT > TRIP_START_DT
),
caps AS (
    SELECT MARKET_CD, TRIP_START_DT,
           DAAS_UAT.DAAS_COMMON.TRIP_CONFIG_UDF_MARKET('MAX_TRIP_DAYS', MARKET_CD, TRIP_START_DT) AS CAP
    FROM (SELECT DISTINCT MARKET_CD, TRIP_START_DT FROM multi)
),
targets AS (
    SELECT m.*
    FROM multi m
    JOIN caps c ON c.MARKET_CD = m.MARKET_CD AND c.TRIP_START_DT = m.TRIP_START_DT
    CROSS JOIN ent e
    WHERE m.TRIP_DAYS > COALESCE(TRY_TO_NUMBER(c.CAP), TRY_TO_NUMBER(e.MAX_TRIP_DAYS))
      AND NOT EXISTS (SELECT 1 FROM DAAS_UAT.DAAS_CORE.TRIP_DETAIL d
                      WHERE d.TRIP_MASTER_ID = m.TRIP_MASTER_ID AND d.DELETE_IND = 'N' AND d.TRANSACTION_TYPE = 'HOTEL')
),
picked AS (
    SELECT t.GUEST_UNIQUE_ID, t.MARKET_CD, t.TRIP_MASTER_ID, t.TRIP_START_DT, t.TRIP_END_DT, t.TRIP_DAYS, d.TRANSACTION_TABLE_SK
    FROM DAAS_UAT.DAAS_CORE.TRIP_DETAIL d
    JOIN targets t ON t.TRIP_MASTER_ID = d.TRIP_MASTER_ID
    WHERE d.TRANSACTION_TABLE = 'RATINGS_FACT' AND d.DELETE_IND = 'N' AND d.TRANSACTION_SUB_TYPE = 'OPENED'
),
one_guest AS (   -- a guest with a handful of target trips: enough rows to read, few enough to eyeball
    SELECT GUEST_UNIQUE_ID
    FROM picked
    GROUP BY 1
    HAVING COUNT(DISTINCT TRIP_MASTER_ID) BETWEEN 2 AND 5 AND COUNT(*) BETWEEN 5 AND 60
    ORDER BY GUEST_UNIQUE_ID
    LIMIT 1
)
SELECT p.*, r.RATINGS_FACT_SK IS NOT NULL AS in_ratings_fact,
       r.REPLAY_COUNTER AS REPLAY_COUNTER_BEFORE, r.UPDATED_DTTM AS UPDATED_DTTM_BEFORE, r.UPDATED_BY AS UPDATED_BY_BEFORE
FROM picked p
JOIN one_guest g ON g.GUEST_UNIQUE_ID = p.GUEST_UNIQUE_ID
LEFT JOIN DAAS_UAT.DAAS_CORE.RATINGS_FACT r ON r.RATINGS_FACT_SK = p.TRANSACTION_TABLE_SK;

SELECT GUEST_UNIQUE_ID, MARKET_CD, COUNT(DISTINCT TRIP_MASTER_ID) AS target_trips, COUNT(*) AS rating_rows_r3_will_update,
       COUNT_IF(in_ratings_fact) AS in_ratings_fact, MIN(REPLAY_COUNTER_BEFORE) AS counter_min, MAX(REPLAY_COUNTER_BEFORE) AS counter_max
FROM DAAS_UAT.DAAS_TEMP_WORK.DAASI_3641_R3_CHECK
GROUP BY 1, 2;

-- T4b. The write in UAT: R3-Z's text apart from the database and ONE added line (the guest). The other statements
--      write the same three columns the same way. Rows updated must equal rating_rows_r3_will_update above.
UPDATE DAAS_UAT.DAAS_CORE.RATINGS_FACT RF
SET RF.REPLAY_COUNTER = COALESCE(RF.REPLAY_COUNTER, 0) + 1,
    RF.UPDATED_DTTM   = CURRENT_TIMESTAMP(),
    RF.UPDATED_BY     = CURRENT_USER()
WHERE RF.RATINGS_FACT_SK IN (
    WITH ent AS (
        SELECT MAX(VALUE) AS MAX_TRIP_DAYS
        FROM DAAS_UAT.DAAS_CORE.TRIP_CONFIG
        WHERE CONFIG_SUBTYPE = 'ENTERPRISE' AND KEY = 'MAX_TRIP_DAYS' AND ACTIVE_FLG = 'Y'
    ),
    multi AS (
        SELECT TRIP_MASTER_ID, GUEST_UNIQUE_ID, MARKET_CD, TRIP_START_DT, TRIP_END_DT - TRIP_START_DT + 1 AS TRIP_DAYS
        FROM DAAS_UAT.DAAS_CORE.TRIP_MASTER
        WHERE DELETE_IND = 'N' AND TRIP_TYPE = 'MARKET' AND MARKET_CD IN ('BEM', 'WLM') AND TRIP_END_DT > TRIP_START_DT
          AND GUEST_UNIQUE_ID IN (SELECT GUEST_UNIQUE_ID FROM DAAS_UAT.DAAS_TEMP_WORK.DAASI_3641_R3_CHECK)   /* the one added line */
    ),
    caps AS (
        SELECT MARKET_CD, TRIP_START_DT,
               DAAS_UAT.DAAS_COMMON.TRIP_CONFIG_UDF_MARKET('MAX_TRIP_DAYS', MARKET_CD, TRIP_START_DT) AS CAP
        FROM (SELECT DISTINCT MARKET_CD, TRIP_START_DT FROM multi)
    ),
    targets AS (
        SELECT m.TRIP_MASTER_ID
        FROM multi m
        JOIN caps c ON c.MARKET_CD = m.MARKET_CD AND c.TRIP_START_DT = m.TRIP_START_DT
        CROSS JOIN ent e
        WHERE m.TRIP_DAYS > COALESCE(TRY_TO_NUMBER(c.CAP), TRY_TO_NUMBER(e.MAX_TRIP_DAYS))
          AND NOT EXISTS (SELECT 1 FROM DAAS_UAT.DAAS_CORE.TRIP_DETAIL d
                          WHERE d.TRIP_MASTER_ID = m.TRIP_MASTER_ID AND d.DELETE_IND = 'N' AND d.TRANSACTION_TYPE = 'HOTEL')
    )
    SELECT d.TRANSACTION_TABLE_SK
    FROM DAAS_UAT.DAAS_CORE.TRIP_DETAIL d
    JOIN targets t ON t.TRIP_MASTER_ID = d.TRIP_MASTER_ID
    WHERE d.TRANSACTION_TABLE = 'RATINGS_FACT' AND d.DELETE_IND = 'N' AND d.TRANSACTION_SUB_TYPE = 'OPENED'
);

-- T4c. What it did, row by row: every kept row has its counter up by exactly one, a stamp from the last few minutes and
--      your user; and nothing else of that guest's was touched (every rating of the guest stamped in the last few
--      minutes is one of the kept rows). Expect the three 'LOOK' counts at 0 and rows_stamped_now = rows_updated.
WITH kept AS (SELECT * FROM DAAS_UAT.DAAS_TEMP_WORK.DAASI_3641_R3_CHECK),
now_rows AS (
    SELECT r.RATINGS_FACT_SK, r.REPLAY_COUNTER, r.UPDATED_DTTM, r.UPDATED_BY
    FROM DAAS_UAT.DAAS_CORE.RATINGS_FACT r
    WHERE r.RATINGS_FACT_SK IN (SELECT TRANSACTION_TABLE_SK FROM kept)
),
all_of_guest AS (
    SELECT COUNT(*) AS rows_stamped_now
    FROM DAAS_UAT.DAAS_CORE.RATINGS_FACT r
    WHERE r.GUEST_UNIQUE_ID IN (SELECT DISTINCT GUEST_UNIQUE_ID FROM kept)
      AND r.UPDATED_BY = CURRENT_USER()
      AND r.UPDATED_DTTM >= DATEADD(minute, -30, CURRENT_TIMESTAMP())
)
SELECT COUNT(*)                                                                           AS rows_updated,
       COUNT_IF(n.REPLAY_COUNTER = COALESCE(k.REPLAY_COUNTER_BEFORE, 0) + 1)               AS counter_up_by_one,
       COUNT_IF(n.REPLAY_COUNTER <> COALESCE(k.REPLAY_COUNTER_BEFORE, 0) + 1)              AS counter_wrong_LOOK,
       COUNT_IF(n.UPDATED_BY = CURRENT_USER() AND n.UPDATED_DTTM >= DATEADD(minute, -30, CURRENT_TIMESTAMP())) AS stamped_by_you_now,
       COUNT_IF(NOT (n.UPDATED_BY = CURRENT_USER() AND n.UPDATED_DTTM >= DATEADD(minute, -30, CURRENT_TIMESTAMP()))) AS stamp_wrong_LOOK,
       (SELECT rows_stamped_now FROM all_of_guest)                                        AS rows_stamped_now,
       (SELECT rows_stamped_now FROM all_of_guest) - COUNT(*)                             AS other_rows_touched_LOOK
FROM kept k
JOIN now_rows n ON n.RATINGS_FACT_SK = k.TRANSACTION_TABLE_SK;

-- T4d. The rows are in UAT's ratings stream, the way the pipeline would see them: as many INSERT rows flagged as updates
--      as rows updated (plus anything already waiting there from before, counted apart by stamp).
SELECT COUNT_IF(METADATA$ISUPDATE AND UPDATED_BY = CURRENT_USER() AND UPDATED_DTTM >= DATEADD(minute, -30, CURRENT_TIMESTAMP())) AS your_rows_in_the_stream,
       COUNT(*) AS all_insert_rows_waiting
FROM DAAS_UAT.DAAS_CORE.RATINGS_FACT_STREAM
WHERE METADATA$ACTION = 'INSERT';
