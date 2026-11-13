-- DAASI-3641: the PROD replay, rehearsed in UAT.
--
-- What is different from the proof (26 Oct) and the week test (29 Oct). Both touched the trips by hand, on the belief
-- that a ratings replay rewrites each trip's row in TRIP_MASTER. PROD's scope check (12 Nov) showed it does not: the
-- ratings step re-stamps TRIP_DETAIL and rewrites a trip row only when a rating extends the trip, so merge check never
-- sees a trip whose ratings were merely replayed (August: 12.06 million ratings re-stamped on these trips, 44 of their
-- 378,792 trip rows rewritten). So the replay starts where merge check reads, with two statements and no RATINGS_FACT:
--   1. TRIP_MASTER: REPLAY_COUNTER on each trip to re-cut (a live BEM/WLM market trip over its cap with no hotel night).
--      That puts the trip in merge check's stream, v1.4 sends it to the merge step, and the merge step re-cuts it.
--   2. TRIP_DETAIL: REPLAY_COUNTER on one rating row of each property trip and day those trips share a rating with.
--      That puts the property side in the summary step's stream in the same run. Comp worth (the comp dollars the play
--      earns) needs it there: the comp worth step values a market trip from the property trips in the run with it.
--
-- What this file does. PART B runs those two statements exactly as PROD will, plus one line that keeps them to the
-- test guests, then starts UAT's own tasks for merge check (v1.4), merge, customer merge check, summaries, comp worth
-- and non-gaming revenue, the way the week test did. Nothing is touched by hand this time: the statements are the touch.
--   PART A  picks the guests (up to 4 test and 2 control per market), takes the before-pictures, lists what the two
--           statements will update
--   PART B  one block: the two statements, then the steps (B2 to B4 are for a stop only)
--   PART C  four validations and Tracy's query: the screenshots
--   PART D  the PROD post-check's own queries, tried on these guests before PROD needs them
--
-- Run it statement by statement, top to bottom, once. About 30 minutes, most of it PART A's reads and the steps' waits.
-- Roles and warehouse as for the week test (DAAS_TEAM, secondary roles on). The known UAT limits are handled the same
-- way: the merge step's closing stream reset fails on privileges after its data is committed, the POS summary sub-step
-- is switched off for step 5 and back on, and the customer merge itself cannot run.
-- Scratch tables: DAAS_UAT.DAAS_TEMP_WORK.DAASI_3641_RH_* (CAND, GUESTS, LOG, QUEUE, MARKS, TM/TD/TS/DAS_BEFORE, GOING,
-- MARK_ROWS, TASKS, MERGE_CHANGES, WAITING). Z at the end drops them.

USE ROLE DAAS_TEAM;
USE SECONDARY ROLES ALL;


-- ===================================================================================================
-- PART A. The guests, the before-pictures, and what the two statements will update (nothing here changes DAAS_CORE)
-- ===================================================================================================

-- A0. Is v1.4 what UAT runs? Expect 'v1.4 is live in UAT'.
SELECT IFF(CONTAINS(GET_DDL('PROCEDURE', 'DAAS_UAT.DAAS_COMMON.TRIP_MERGE_CHECK_PROC(FLOAT, VARCHAR, VARCHAR, VARCHAR, VARCHAR)'),
                    'my_sql_command_3A'),
           'v1.4 is live in UAT', 'UAT still runs the old version: deploy v1.4 first') AS merge_check_version;

-- A0b. Are UAT's trip streams still readable? UAT's chain is suspended, so nothing has read them since the week test,
--      and a stream nobody reads goes stale after about two weeks. Run each SHOW together with the SELECT under it.
--      Expect 'ready' on every row. On STALE or MISSING, stop here and send me the result: that stream has to be
--      recreated before the steps can run, and the result tells me the statement for it.
SHOW STREAMS IN SCHEMA DAAS_UAT.DAAS_CORE;

WITH need AS (
    SELECT column1 AS stream_name, column2 AS read_by
    FROM VALUES ('TRIP_MERGE_QUEUE_STREAM',                      'step 3, the merge'),
                ('TRIP_MASTER_TRIP_CUSTOMER_MERGE_CHECK_STREAM', 'step 4, the customer merge check'),
                ('TRIP_DETAIL_SUMMARY_STREAM',                   'step 5, the summaries'),
                ('TRIP_MASTER_DAILY_SUMMARY_WRAPPER_STREAM',     'step 5, the summaries')
)
SELECT n.stream_name, n.read_by, s."table_name" AS on_table, s."mode" AS mode, s."stale" AS stale, s."stale_after" AS stale_after,
       CASE WHEN s."name" IS NULL THEN 'MISSING' WHEN s."stale" = 'true' THEN 'STALE' ELSE 'ready' END AS verdict
FROM need n
LEFT JOIN TABLE(RESULT_SCAN(LAST_QUERY_ID())) s ON s."name" = n.stream_name
ORDER BY n.read_by, n.stream_name;

SHOW STREAMS IN SCHEMA DAAS_UAT.DAAS_TEMP;

SELECT 'TRIP_MASTER_TRIP_MERGE_CHECK_STREAM' AS stream_name, 'step 2, merge check' AS read_by, s."table_name" AS on_table, s."mode" AS mode,
       s."stale" AS stale, s."stale_after" AS stale_after,
       CASE WHEN s."name" IS NULL THEN 'MISSING' WHEN s."stale" = 'true' THEN 'STALE' ELSE 'ready' END AS verdict
FROM (SELECT 1 AS x) d
LEFT JOIN TABLE(RESULT_SCAN(LAST_QUERY_ID())) s ON s."name" = 'TRIP_MASTER_TRIP_MERGE_CHECK_STREAM';


-- A1. The candidates. Every guest of the main group (no run of trips needing more than 30 passes of the merge step's
--     loop) with 5 to 60 trips to re-cut, all in one market, and what stands in the way of a clean comparison for
--     each: a trip going to the merge step without exactly one summary row (UAT stopped summarising new trips in June),
--     a property trip to mark without a summary row, or a soft-deleted row still marked OPENED on one of the trips
--     (the merge step would bring it back; PROD's pre-check counts those). Per market, the usable guests showing most
--     of PROD's shapes come first (a neighbouring trip the join rule will add, a trip holding no rating, trips back to
--     back): the first four are TEST, the next two CONTROL. Reads TRIP_DETAIL several times: a few minutes.
CREATE OR REPLACE TABLE DAAS_UAT.DAAS_TEMP_WORK.DAASI_3641_RH_CAND AS
WITH ent AS (       /* the enterprise settings: merge check's fallback where a market has none of its own */
    SELECT MAX(IFF(KEY = 'MAX_TRIP_DAYS', VALUE, NULL)) AS MAX_TRIP_DAYS,
           MAX(IFF(KEY = 'TRIP_GAP_DAYS', VALUE, NULL)) AS TRIP_GAP_DAYS
    FROM DAAS_UAT.DAAS_CORE.TRIP_CONFIG
    WHERE CONFIG_SUBTYPE = 'ENTERPRISE' AND KEY IN ('MAX_TRIP_DAYS', 'TRIP_GAP_DAYS') AND ACTIVE_FLG = 'Y'
),
multi AS (
    SELECT TRIP_MASTER_ID, GUEST_UNIQUE_ID, MARKET_CD, TRIP_START_DT, TRIP_END_DT, TRIP_END_DT - TRIP_START_DT + 1 AS TRIP_DAYS
    FROM DAAS_UAT.DAAS_CORE.TRIP_MASTER
    WHERE DELETE_IND = 'N' AND TRIP_TYPE = 'MARKET' AND MARKET_CD IN ('BEM', 'WLM') AND TRIP_END_DT > TRIP_START_DT
),
caps AS (
    SELECT MARKET_CD, TRIP_START_DT,
           DAAS_UAT.DAAS_COMMON.TRIP_CONFIG_UDF_MARKET('MAX_TRIP_DAYS', MARKET_CD, TRIP_START_DT) AS CAP,
           DAAS_UAT.DAAS_COMMON.TRIP_CONFIG_UDF_MARKET('TRIP_GAP_DAYS', MARKET_CD, TRIP_START_DT) AS GAP
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
      AND NOT EXISTS (SELECT 1 FROM DAAS_UAT.DAAS_CORE.TRIP_DETAIL d
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
cand AS (       /* guests of the main group with 5 to 60 trips to re-cut, all of them in one market */
    SELECT GUEST_UNIQUE_ID, MIN(MARKET_CD) AS MARKET_CD, COUNT(*) AS TARGETS, MAX(TRIP_DAYS) AS LONGEST_DAYS,
           MAX(PLACE_IN_RUN) AS MOST_BACK_TO_BACK
    FROM picked
    WHERE GUEST_UNIQUE_ID > 0
    GROUP BY GUEST_UNIQUE_ID
    HAVING COUNT(*) BETWEEN 5 AND 60 AND COUNT(DISTINCT MARKET_CD) = 1 AND MAX(GUEST_PASSES) <= 30
),
stay AS (       /* trips holding a hotel night: merge check joins a touched trip to one of these that starts as it ends */
    SELECT DISTINCT TRIP_MASTER_ID
    FROM DAAS_UAT.DAAS_CORE.TRIP_DETAIL
    WHERE DELETE_IND = 'N' AND TRANSACTION_TYPE = 'HOTEL'
),
bumped AS (     /* this statement's trips: the same ones the TRIP_MASTER statement updates */
    SELECT t.TRIP_MASTER_ID, t.GUEST_UNIQUE_ID, t.MARKET_CD, t.TRIP_START_DT, t.TRIP_END_DT, t.GAP
    FROM picked t
    WHERE t.GUEST_PASSES <= 30   /* everyone except the long-run guests */
      AND t.GUEST_UNIQUE_ID IN (SELECT GUEST_UNIQUE_ID FROM cand)   /* the candidates */
),
going AS (      /* what the run sends to the merge step: those trips, and any trip merge check's own rule pairs with one */
    SELECT b.TRIP_MASTER_ID, b.GUEST_UNIQUE_ID, b.MARKET_CD
    FROM bumped b
    UNION
    SELECT o.TRIP_MASTER_ID, b.GUEST_UNIQUE_ID, b.MARKET_CD
    FROM bumped b
    JOIN DAAS_UAT.DAAS_CORE.TRIP_MASTER o
      ON o.GUEST_UNIQUE_ID = b.GUEST_UNIQUE_ID AND o.TRIP_TYPE = 'MARKET' AND o.MARKET_CD = b.MARKET_CD
     AND o.DELETE_IND = 'N' AND o.TRIP_MASTER_ID <> b.TRIP_MASTER_ID
    LEFT JOIN stay s ON s.TRIP_MASTER_ID = o.TRIP_MASTER_ID
    WHERE b.TRIP_START_DT BETWEEN o.TRIP_START_DT AND o.TRIP_END_DT
       OR o.TRIP_START_DT BETWEEN b.TRIP_START_DT AND b.TRIP_END_DT
       OR (s.TRIP_MASTER_ID IS NOT NULL AND DATEADD(day, b.GAP, b.TRIP_END_DT) BETWEEN o.TRIP_START_DT AND o.TRIP_END_DT)
),
facts AS (      /* each trip the statements would send to the merge step: is it the guest's own target, and what does it hold */
    SELECT g.GUEST_UNIQUE_ID, g.TRIP_MASTER_ID,
           MAX(IFF(b.TRIP_MASTER_ID IS NOT NULL, 1, 0))                                                                AS IS_TARGET,
           COUNT_IF(d.TRANSACTION_TABLE = 'RATINGS_FACT' AND d.DELETE_IND = 'N' AND d.TRANSACTION_SUB_TYPE = 'OPENED') AS LIVE_RATINGS,
           COUNT_IF(d.DELETE_IND = 'Y' AND d.TRANSACTION_SUB_TYPE = 'OPENED')                                          AS DEAD_ROWS
    FROM going g
    LEFT JOIN bumped b ON b.TRIP_MASTER_ID = g.TRIP_MASTER_ID
    LEFT JOIN DAAS_UAT.DAAS_CORE.TRIP_DETAIL d ON d.TRIP_MASTER_ID = g.TRIP_MASTER_ID
    GROUP BY g.GUEST_UNIQUE_ID, g.TRIP_MASTER_ID
),
summ AS (       /* how many summary rows each of those trips has (one is right) */
    SELECT g.GUEST_UNIQUE_ID, g.TRIP_MASTER_ID, COUNT(s.TRIP_MASTER_ID) AS SUMMARY_ROWS
    FROM going g
    LEFT JOIN DAAS_UAT.DAAS_CORE.TRIP_SUMMARY s ON s.TRIP_MASTER_ID = g.TRIP_MASTER_ID
    GROUP BY g.GUEST_UNIQUE_ID, g.TRIP_MASTER_ID
),
prop AS (       /* the property trips statement 2 would mark for the guest, and how many of them have no summary row */
    SELECT g.GUEST_UNIQUE_ID,
           COUNT(DISTINCT pd.TRIP_MASTER_ID)                                       AS PROPERTY_TRIPS,
           COUNT(DISTINCT IFF(s.TRIP_MASTER_ID IS NULL, pd.TRIP_MASTER_ID, NULL))  AS PROPERTY_TRIPS_NO_SUMMARY
    FROM going g
    JOIN DAAS_UAT.DAAS_CORE.TRIP_DETAIL d  ON d.TRIP_MASTER_ID = g.TRIP_MASTER_ID
    JOIN DAAS_UAT.DAAS_CORE.TRIP_DETAIL pd ON pd.TRANSACTION_TABLE_SK = d.TRANSACTION_TABLE_SK
    JOIN DAAS_UAT.DAAS_CORE.TRIP_MASTER p  ON p.TRIP_MASTER_ID = pd.TRIP_MASTER_ID
    LEFT JOIN DAAS_UAT.DAAS_CORE.TRIP_SUMMARY s ON s.TRIP_MASTER_ID = p.TRIP_MASTER_ID
    WHERE d.TRANSACTION_TABLE = 'RATINGS_FACT' AND d.TRANSACTION_SUB_TYPE = 'OPENED'
      AND pd.TRANSACTION_TABLE = 'RATINGS_FACT' AND pd.DELETE_IND = 'N' AND pd.TRANSACTION_SUB_TYPE = 'OPENED'
      AND p.TRIP_TYPE = 'PROPERTY' AND p.DELETE_IND = 'N'
    GROUP BY g.GUEST_UNIQUE_ID
),
per_guest AS (
    SELECT c.GUEST_UNIQUE_ID, c.MARKET_CD, c.TARGETS, c.LONGEST_DAYS, c.MOST_BACK_TO_BACK,
           SUM(1 - f.IS_TARGET)                                    AS PARTNERS,
           SUM(IFF(f.IS_TARGET = 1 AND f.LIVE_RATINGS = 0, 1, 0))  AS TARGETS_WITH_NO_RATING,
           SUM(f.DEAD_ROWS)                                        AS DEAD_ROWS,
           SUM(IFF(sm.SUMMARY_ROWS = 1, 0, 1))                     AS TRIPS_WITHOUT_ONE_SUMMARY_ROW,
           COALESCE(MAX(p.PROPERTY_TRIPS), 0)                      AS PROPERTY_TRIPS,
           COALESCE(MAX(p.PROPERTY_TRIPS_NO_SUMMARY), 0)           AS PROPERTY_TRIPS_NO_SUMMARY
    FROM cand c
    JOIN facts f  ON f.GUEST_UNIQUE_ID = c.GUEST_UNIQUE_ID
    JOIN summ sm  ON sm.GUEST_UNIQUE_ID = f.GUEST_UNIQUE_ID AND sm.TRIP_MASTER_ID = f.TRIP_MASTER_ID
    LEFT JOIN prop p ON p.GUEST_UNIQUE_ID = c.GUEST_UNIQUE_ID
    GROUP BY c.GUEST_UNIQUE_ID, c.MARKET_CD, c.TARGETS, c.LONGEST_DAYS, c.MOST_BACK_TO_BACK
),
ranked AS (     /* usable: nothing in the way of a clean comparison. Guests showing more of the shapes PROD has come first */
    SELECT g.*,
           (g.DEAD_ROWS = 0 AND g.TRIPS_WITHOUT_ONE_SUMMARY_ROW = 0 AND g.PROPERTY_TRIPS_NO_SUMMARY = 0) AS USABLE,
           ROW_NUMBER() OVER (PARTITION BY g.MARKET_CD,
                                           (g.DEAD_ROWS = 0 AND g.TRIPS_WITHOUT_ONE_SUMMARY_ROW = 0 AND g.PROPERTY_TRIPS_NO_SUMMARY = 0)
                              ORDER BY IFF(g.PARTNERS > 0, 1, 0) + IFF(g.TARGETS_WITH_NO_RATING > 0, 1, 0) + IFF(g.MOST_BACK_TO_BACK > 1, 1, 0) DESC,
                                       g.TARGETS DESC, g.GUEST_UNIQUE_ID) AS RN
    FROM per_guest g
)
SELECT r.GUEST_UNIQUE_ID, r.MARKET_CD, r.TARGETS, r.LONGEST_DAYS, r.MOST_BACK_TO_BACK, r.PARTNERS, r.TARGETS_WITH_NO_RATING, r.DEAD_ROWS,
       r.TRIPS_WITHOUT_ONE_SUMMARY_ROW, r.PROPERTY_TRIPS, r.PROPERTY_TRIPS_NO_SUMMARY, r.USABLE,
       CASE WHEN r.USABLE AND r.RN <= 4 THEN 'TEST' WHEN r.USABLE AND r.RN <= 6 THEN 'CONTROL' END AS GRP
FROM ranked r;

CREATE OR REPLACE TABLE DAAS_UAT.DAAS_TEMP_WORK.DAASI_3641_RH_GUESTS AS
SELECT GUEST_UNIQUE_ID, MARKET_CD, GRP,
       MARKET_CD || ': ' || TARGETS || ' trips over the cap with no hotel night (longest ' || LONGEST_DAYS || ' days, up to '
                 || MOST_BACK_TO_BACK || ' back to back), ' || TARGETS_WITH_NO_RATING || ' of them holding no rating; '
                 || PARTNERS || ' neighbouring trips the join rule will add' AS PICK_REASON
FROM DAAS_UAT.DAAS_TEMP_WORK.DAASI_3641_RH_CAND
WHERE GRP IS NOT NULL;

-- A1b. Who was picked. Expect up to 4 TEST and 2 CONTROL per market.
SELECT GRP, MARKET_CD, GUEST_UNIQUE_ID, PICK_REASON
FROM DAAS_UAT.DAAS_TEMP_WORK.DAASI_3641_RH_GUESTS
ORDER BY GRP DESC, MARKET_CD, GUEST_UNIQUE_ID;

-- A1c. How the candidates sorted out, per market. If a market shows no test guest, stop and send me this result.
SELECT MARKET_CD                                  AS market,
       COUNT(*)                                   AS guests_with_5_to_60_trips_to_re_cut,
       COUNT_IF(DEAD_ROWS > 0)                    AS set_aside_soft_deleted_rows_on_their_trips,
       COUNT_IF(TRIPS_WITHOUT_ONE_SUMMARY_ROW > 0) AS set_aside_a_trip_without_its_summary_row,
       COUNT_IF(PROPERTY_TRIPS_NO_SUMMARY > 0)    AS set_aside_a_property_trip_without_its_summary_row,
       COUNT_IF(USABLE)                           AS usable,
       COUNT_IF(GRP = 'TEST')                     AS test_guests,
       COUNT_IF(GRP = 'CONTROL')                  AS control_guests
FROM DAAS_UAT.DAAS_TEMP_WORK.DAASI_3641_RH_CAND
GROUP BY MARKET_CD
ORDER BY MARKET_CD;


-- A2. The log and marks, then the before-pictures: every TRIP_MASTER row of the picked guests (every kind of trip,
--     live or not), every TRIP_DETAIL row of those trips, their TRIP_SUMMARY and DAILY_ACTIVITY_SUMMARY rows.
--     Run the nine together. The TRIP_DETAIL one reads the whole table once: minutes.
CREATE OR REPLACE TABLE DAAS_UAT.DAAS_TEMP_WORK.DAASI_3641_RH_LOG (STEP VARCHAR, LOGGED_AT TIMESTAMP_NTZ, NOTE VARCHAR);
INSERT INTO DAAS_UAT.DAAS_TEMP_WORK.DAASI_3641_RH_LOG SELECT 'A_START', CONVERT_TIMEZONE('America/Los_Angeles', CURRENT_TIMESTAMP())::TIMESTAMP_NTZ, 'before-pictures start (Pacific, the batch log''s clock)';
CREATE OR REPLACE TABLE DAAS_UAT.DAAS_TEMP_WORK.DAASI_3641_RH_QUEUE (MERGE_CHECK_BATCH_ID NUMBER(38,0), TRIP_MASTER_ID NUMBER(38,0), ROLE VARCHAR);
CREATE OR REPLACE TABLE DAAS_UAT.DAAS_TEMP_WORK.DAASI_3641_RH_MARKS (MARK VARCHAR, VALUE NUMBER(38,0));
INSERT INTO DAAS_UAT.DAAS_TEMP_WORK.DAASI_3641_RH_MARKS
SELECT 'max_trip_master_id_before', MAX(TRIP_MASTER_ID) FROM DAAS_UAT.DAAS_CORE.TRIP_MASTER;

CREATE OR REPLACE TABLE DAAS_UAT.DAAS_TEMP_WORK.DAASI_3641_RH_TM_BEFORE AS
SELECT m.*
FROM DAAS_UAT.DAAS_CORE.TRIP_MASTER m
WHERE m.GUEST_UNIQUE_ID IN (SELECT GUEST_UNIQUE_ID FROM DAAS_UAT.DAAS_TEMP_WORK.DAASI_3641_RH_GUESTS);

CREATE OR REPLACE TABLE DAAS_UAT.DAAS_TEMP_WORK.DAASI_3641_RH_TD_BEFORE AS
SELECT d.*
FROM DAAS_UAT.DAAS_CORE.TRIP_DETAIL d
JOIN DAAS_UAT.DAAS_TEMP_WORK.DAASI_3641_RH_TM_BEFORE t ON t.TRIP_MASTER_ID = d.TRIP_MASTER_ID;

CREATE OR REPLACE TABLE DAAS_UAT.DAAS_TEMP_WORK.DAASI_3641_RH_TS_BEFORE AS
SELECT s.*
FROM DAAS_UAT.DAAS_CORE.TRIP_SUMMARY s
JOIN DAAS_UAT.DAAS_TEMP_WORK.DAASI_3641_RH_TM_BEFORE t ON t.TRIP_MASTER_ID = s.TRIP_MASTER_ID;

CREATE OR REPLACE TABLE DAAS_UAT.DAAS_TEMP_WORK.DAASI_3641_RH_DAS_BEFORE AS
SELECT s.*
FROM DAAS_UAT.DAAS_CORE.DAILY_ACTIVITY_SUMMARY s
JOIN DAAS_UAT.DAAS_TEMP_WORK.DAASI_3641_RH_TM_BEFORE t ON t.TRIP_MASTER_ID = s.TRIP_MASTER_ID;


-- A3. What the two statements will update, worked out by the statements' own text. GOING: the trips statement 1
--     updates (TARGET) and the neighbours merge check's own join rule will pair with them (PARTNER), for test and
--     control guests alike, so the controls can be shown untouched. MARK_ROWS: the rows statement 2 updates.
CREATE OR REPLACE TABLE DAAS_UAT.DAAS_TEMP_WORK.DAASI_3641_RH_GOING AS
WITH ent AS (       /* the enterprise settings: merge check's fallback where a market has none of its own */
    SELECT MAX(IFF(KEY = 'MAX_TRIP_DAYS', VALUE, NULL)) AS MAX_TRIP_DAYS,
           MAX(IFF(KEY = 'TRIP_GAP_DAYS', VALUE, NULL)) AS TRIP_GAP_DAYS
    FROM DAAS_UAT.DAAS_CORE.TRIP_CONFIG
    WHERE CONFIG_SUBTYPE = 'ENTERPRISE' AND KEY IN ('MAX_TRIP_DAYS', 'TRIP_GAP_DAYS') AND ACTIVE_FLG = 'Y'
),
multi AS (
    SELECT TRIP_MASTER_ID, GUEST_UNIQUE_ID, MARKET_CD, TRIP_START_DT, TRIP_END_DT, TRIP_END_DT - TRIP_START_DT + 1 AS TRIP_DAYS
    FROM DAAS_UAT.DAAS_CORE.TRIP_MASTER
    WHERE DELETE_IND = 'N' AND TRIP_TYPE = 'MARKET' AND MARKET_CD IN ('BEM', 'WLM') AND TRIP_END_DT > TRIP_START_DT
),
caps AS (
    SELECT MARKET_CD, TRIP_START_DT,
           DAAS_UAT.DAAS_COMMON.TRIP_CONFIG_UDF_MARKET('MAX_TRIP_DAYS', MARKET_CD, TRIP_START_DT) AS CAP,
           DAAS_UAT.DAAS_COMMON.TRIP_CONFIG_UDF_MARKET('TRIP_GAP_DAYS', MARKET_CD, TRIP_START_DT) AS GAP
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
      AND NOT EXISTS (SELECT 1 FROM DAAS_UAT.DAAS_CORE.TRIP_DETAIL d
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
stay AS (       /* trips holding a hotel night: merge check joins a touched trip to one of these that starts as it ends */
    SELECT DISTINCT TRIP_MASTER_ID
    FROM DAAS_UAT.DAAS_CORE.TRIP_DETAIL
    WHERE DELETE_IND = 'N' AND TRANSACTION_TYPE = 'HOTEL'
),
bumped AS (     /* this statement's trips: the same ones the TRIP_MASTER statement updates */
    SELECT t.TRIP_MASTER_ID, t.GUEST_UNIQUE_ID, t.MARKET_CD, t.TRIP_START_DT, t.TRIP_END_DT, t.GAP
    FROM picked t
    WHERE t.GUEST_PASSES <= 30   /* everyone except the long-run guests */
      AND t.GUEST_UNIQUE_ID IN (SELECT GUEST_UNIQUE_ID FROM DAAS_UAT.DAAS_TEMP_WORK.DAASI_3641_RH_GUESTS)   /* test and control guests */
),
going AS (      /* what the run sends to the merge step: those trips, and any trip merge check's own rule pairs with one */
    SELECT b.TRIP_MASTER_ID, b.GUEST_UNIQUE_ID, b.MARKET_CD
    FROM bumped b
    UNION
    SELECT o.TRIP_MASTER_ID, b.GUEST_UNIQUE_ID, b.MARKET_CD
    FROM bumped b
    JOIN DAAS_UAT.DAAS_CORE.TRIP_MASTER o
      ON o.GUEST_UNIQUE_ID = b.GUEST_UNIQUE_ID AND o.TRIP_TYPE = 'MARKET' AND o.MARKET_CD = b.MARKET_CD
     AND o.DELETE_IND = 'N' AND o.TRIP_MASTER_ID <> b.TRIP_MASTER_ID
    LEFT JOIN stay s ON s.TRIP_MASTER_ID = o.TRIP_MASTER_ID
    WHERE b.TRIP_START_DT BETWEEN o.TRIP_START_DT AND o.TRIP_END_DT
       OR o.TRIP_START_DT BETWEEN b.TRIP_START_DT AND b.TRIP_END_DT
       OR (s.TRIP_MASTER_ID IS NOT NULL AND DATEADD(day, b.GAP, b.TRIP_END_DT) BETWEEN o.TRIP_START_DT AND o.TRIP_END_DT)
)
SELECT g.TRIP_MASTER_ID, g.GUEST_UNIQUE_ID, g.MARKET_CD, x.GRP,
       IFF(b.TRIP_MASTER_ID IS NOT NULL, 'TARGET', 'PARTNER') AS ROLE
FROM going g
JOIN DAAS_UAT.DAAS_TEMP_WORK.DAASI_3641_RH_GUESTS x ON x.GUEST_UNIQUE_ID = g.GUEST_UNIQUE_ID
LEFT JOIN bumped b ON b.TRIP_MASTER_ID = g.TRIP_MASTER_ID;

CREATE OR REPLACE TABLE DAAS_UAT.DAAS_TEMP_WORK.DAASI_3641_RH_MARK_ROWS AS
SELECT MIN(pd.TRIP_DETAIL_ID) AS TRIP_DETAIL_ID, pd.TRIP_MASTER_ID AS PROPERTY_TRIP_ID, pd.BUSINESS_START_DT,
       g.GUEST_UNIQUE_ID, g.MARKET_CD
FROM (SELECT TRIP_MASTER_ID, GUEST_UNIQUE_ID, MARKET_CD FROM DAAS_UAT.DAAS_TEMP_WORK.DAASI_3641_RH_GOING WHERE GRP = 'TEST') g
JOIN DAAS_UAT.DAAS_CORE.TRIP_DETAIL d  ON d.TRIP_MASTER_ID = g.TRIP_MASTER_ID                 /* the ratings the merge step carries over ... */
JOIN DAAS_UAT.DAAS_CORE.TRIP_DETAIL pd ON pd.TRANSACTION_TABLE_SK = d.TRANSACTION_TABLE_SK    /* ... where they sit on a property trip */
JOIN DAAS_UAT.DAAS_CORE.TRIP_MASTER p  ON p.TRIP_MASTER_ID = pd.TRIP_MASTER_ID
WHERE d.TRANSACTION_TABLE = 'RATINGS_FACT' AND d.TRANSACTION_SUB_TYPE = 'OPENED'
  AND pd.TRANSACTION_TABLE = 'RATINGS_FACT' AND pd.DELETE_IND = 'N' AND pd.TRANSACTION_SUB_TYPE = 'OPENED'
  AND p.TRIP_TYPE = 'PROPERTY' AND p.DELETE_IND = 'N'
GROUP BY pd.TRIP_MASTER_ID, pd.BUSINESS_START_DT, g.GUEST_UNIQUE_ID, g.MARKET_CD;

-- A4. The setup, guest by guest: the first screenshot. Controls show the over-cap trips they hold and 0 rows updated.
WITH g AS (
    SELECT GUEST_UNIQUE_ID, COUNT_IF(ROLE = 'TARGET') AS TARGETS, COUNT_IF(ROLE = 'PARTNER') AS PARTNERS
    FROM DAAS_UAT.DAAS_TEMP_WORK.DAASI_3641_RH_GOING
    GROUP BY GUEST_UNIQUE_ID
),
m AS (
    SELECT GUEST_UNIQUE_ID, COUNT(DISTINCT TRIP_DETAIL_ID) AS ROWS_TO_MARK, COUNT(DISTINCT PROPERTY_TRIP_ID) AS PROPERTY_TRIPS
    FROM DAAS_UAT.DAAS_TEMP_WORK.DAASI_3641_RH_MARK_ROWS
    GROUP BY GUEST_UNIQUE_ID
)
SELECT x.GRP, x.MARKET_CD, x.GUEST_UNIQUE_ID,
       g.TARGETS                           AS trips_over_the_cap_no_hotel_night,
       IFF(x.GRP = 'TEST', g.TARGETS, 0)   AS trip_master_rows_statement_1_updates,
       IFF(x.GRP = 'TEST', g.PARTNERS, 0)  AS neighbours_the_join_rule_adds,
       COALESCE(m.ROWS_TO_MARK, 0)         AS trip_detail_rows_statement_2_updates,
       COALESCE(m.PROPERTY_TRIPS, 0)       AS on_this_many_property_trips
FROM DAAS_UAT.DAAS_TEMP_WORK.DAASI_3641_RH_GUESTS x
JOIN g ON g.GUEST_UNIQUE_ID = x.GUEST_UNIQUE_ID
LEFT JOIN m ON m.GUEST_UNIQUE_ID = x.GUEST_UNIQUE_ID
ORDER BY x.GRP DESC, x.MARKET_CD, x.GUEST_UNIQUE_ID;


-- ===================================================================================================
-- PART B. The replay
-- ===================================================================================================

-- B0. (Only if B1 stops at "P4 streams".) Rows an earlier run left in merge check's stream. In UAT the merge step
--     cannot reset that stream when it finishes (the known privileges failure), so the trip rows it writes stay there
--     after any run that does not move them by hand; PROD's merge step discards them itself. Left there, merge check
--     would treat them as touched trips and send other guests' trips to the merge step in this run.
--     The first query shows what is waiting and which job wrote it (read-only). If that batch started today, someone
--     is using UAT's trip steps: ask before going on. Otherwise set the rows aside, the week test's way, once: the
--     first statement keeps a copy (it refuses to run a second time, so a copy is never overwritten), the second
--     reads the stream and keeps nothing, which moves it, the third must show stream_rows_left_expect_0 = 0.
--     Then run B1 again as it is. PART A does not need running again.
SELECT COALESCE(j.JOB_NAME, 'no batch found')              AS written_by_job,
       s.BATCH_ID,
       TO_VARCHAR(MIN(b.STARTED), 'YYYY-MM-DD HH24:MI')    AS that_batch_started_pacific,
       s.LAST_DML_CD,
       s.DELETE_IND,
       COUNT(*)                                            AS rows_waiting,
       COUNT(DISTINCT s.GUEST_UNIQUE_ID)                   AS guests
FROM DAAS_UAT.DAAS_TEMP.TRIP_MASTER_TRIP_MERGE_CHECK_STREAM s
LEFT JOIN (SELECT BATCH_ID, MIN(JOB_ID) AS JOB_ID, MIN(BATCH_START_DATE) AS STARTED
           FROM DAAS_UAT.DAAS_COMMON.BATCH_S02
           GROUP BY BATCH_ID) b ON b.BATCH_ID = s.BATCH_ID
LEFT JOIN DAAS_UAT.DAAS_COMMON.JOB j ON j.JOB_ID = b.JOB_ID
WHERE s.METADATA$ACTION = 'INSERT'
GROUP BY 1, 2, 4, 5
ORDER BY rows_waiting DESC;

CREATE TABLE DAAS_UAT.DAAS_TEMP_WORK.DAASI_3641_RH_WAITING AS
SELECT CURRENT_TIMESTAMP()::TIMESTAMP_NTZ AS kept_at, s.*
FROM DAAS_UAT.DAAS_TEMP.TRIP_MASTER_TRIP_MERGE_CHECK_STREAM s;

INSERT INTO DAAS_UAT.DAAS_TEMP_WORK.DAASI_3641_RH_WAITING
SELECT CURRENT_TIMESTAMP()::TIMESTAMP_NTZ, s.*
FROM DAAS_UAT.DAAS_TEMP.TRIP_MASTER_TRIP_MERGE_CHECK_STREAM s
WHERE 0 = 1;

SELECT COUNT(*) AS rows_kept,
       (SELECT COUNT(*) FROM DAAS_UAT.DAAS_TEMP.TRIP_MASTER_TRIP_MERGE_CHECK_STREAM WHERE METADATA$ACTION = 'INSERT') AS stream_rows_left_expect_0
FROM DAAS_UAT.DAAS_TEMP_WORK.DAASI_3641_RH_WAITING;


-- B1. One block. It checks first and changes nothing if a check fails: no trip job running, v1.4 live, PART A done,
--     the streams usable and empty, one suspended on-demand task per step. Then the two statements, in its middle under
--     "THE TWO STATEMENTS": the same text as PROD's main-group statements with DAAS_UAT for DAAS_PROD and the one
--     marked line. It checks they updated exactly what A3 listed and that merge check's stream shows exactly those
--     trips, then runs the steps in chain order and reports each. Read the result top to bottom: every row should say
--     ok (or note, or skipped). On STOP, do what the row says; v_resume_at restarts at a step without running the
--     statements again.
EXECUTE IMMEDIATE $$
DECLARE
    v_resume_at  INTEGER DEFAULT 0;      -- 0: a fresh run (the two statements, then steps 2 to 7). 2..7: the statements have run; resume at this step
    v_skip_pos   BOOLEAN DEFAULT TRUE;   -- step 5 runs with UAT's broken POS summary sub-step switched off, and back on right after
    v_max_wait   INTEGER DEFAULT 5400;   -- longest wait for one step, in seconds (90 minutes)
    v_log        VARCHAR DEFAULT '';
    v_txt        VARCHAR;
    v_out        VARCHAR;
    v_job        VARCHAR;
    v_task       VARCHAR;
    v_cmd        VARCHAR;
    v_wait       VARCHAR;
    v_status     VARCHAR;
    v_has        BOOLEAN;
    v_can_read   BOOLEAN DEFAULT TRUE;
    v_n          INTEGER;
    v_m          INTEGER;
    v_k          INTEGER;
    v_c          INTEGER;
    v_step       INTEGER;
    v_waited     INTEGER;
    v_mark       NUMBER(38,0);
    v_batchid    NUMBER(38,0);
    v_targets    INTEGER;
    v_partners   INTEGER;
    v_rows       INTEGER;
    v_bumped     INTEGER DEFAULT 0;
    v_marked     INTEGER DEFAULT 0;
    v_pos_id     INTEGER;
    v_pos_off    BOOLEAN DEFAULT FALSE;
    v_t0         TIMESTAMP_NTZ;
    res          RESULTSET;
    rh_stop      EXCEPTION (-20646, 'DAASI-3641 rehearsal stopped, see the rows');
BEGIN
    v_t0 := (SELECT CURRENT_TIMESTAMP()::TIMESTAMP_NTZ);
    ---------------------------------------------------------------- preflight: nothing here changes anything
    v_n := (SELECT COUNT(*) FROM DAAS_UAT.DAAS_COMMON.BATCH_S02 b JOIN DAAS_UAT.DAAS_COMMON.JOB j ON j.JOB_ID = b.JOB_ID
             WHERE j.JOB_NAME LIKE 'TRIP%' AND b.BATCH_STATUS = 'IN PROGRESS'
               AND b.BATCH_START_DATE >= DATEADD(hour, -6, CURRENT_TIMESTAMP()::TIMESTAMP_NTZ));
    IF (v_n > 0) THEN
        v_log := v_log || 'P0 runs~|~STOP~|~' || v_n || ' trip job(s) IN PROGRESS: let them finish, then run this block again#ROW#';
        RAISE rh_stop;
    END IF;
    v_has := (SELECT CONTAINS(GET_DDL('PROCEDURE', 'DAAS_UAT.DAAS_COMMON.TRIP_MERGE_CHECK_PROC(FLOAT, VARCHAR, VARCHAR, VARCHAR, VARCHAR)'), 'my_sql_command_3A'));
    IF (NOT v_has) THEN
        v_log := v_log || 'P1 version~|~STOP~|~UAT runs the old TRIP_MERGE_CHECK_PROC: deploy v1.4 first#ROW#';
        RAISE rh_stop;
    END IF;
    v_targets  := (SELECT COUNT(*) FROM DAAS_UAT.DAAS_TEMP_WORK.DAASI_3641_RH_GOING WHERE GRP = 'TEST' AND ROLE = 'TARGET');
    v_partners := (SELECT COUNT(*) FROM DAAS_UAT.DAAS_TEMP_WORK.DAASI_3641_RH_GOING WHERE GRP = 'TEST' AND ROLE = 'PARTNER');
    v_rows     := (SELECT COUNT(DISTINCT TRIP_DETAIL_ID) FROM DAAS_UAT.DAAS_TEMP_WORK.DAASI_3641_RH_MARK_ROWS);
    v_c        := (SELECT COUNT(*) FROM DAAS_UAT.DAAS_TEMP_WORK.DAASI_3641_RH_MARKS WHERE MARK = 'max_trip_master_id_before');
    IF (v_targets = 0 OR v_c = 0) THEN
        v_log := v_log || 'P1 part A~|~STOP~|~PART A has not finished (no trips in RH_GOING, or no marks): run PART A first#ROW#';
        RAISE rh_stop;
    END IF;
    v_n := (SELECT COUNT(*) FROM DAAS_UAT.DAAS_TEMP_WORK.DAASI_3641_RH_LOG WHERE STEP = 'STATEMENTS');
    IF (v_resume_at = 0 AND v_n > 0) THEN
        v_log := v_log || 'P1 state~|~STOP~|~the two statements have already run (STATEMENTS is in the log). To carry on, set v_resume_at to the step that stopped; to start over, run PART A again#ROW#';
        RAISE rh_stop;
    END IF;
    IF (v_resume_at > 0 AND v_n = 0) THEN
        v_log := v_log || 'P1 state~|~STOP~|~v_resume_at is ' || v_resume_at || ' but the statements have not run yet: set v_resume_at = 0#ROW#';
        RAISE rh_stop;
    END IF;
    IF (v_resume_at = 0) THEN
        v_n := (SELECT COUNT(*) FROM DAAS_UAT.DAAS_TEMP_WORK.DAASI_3641_RH_GOING g JOIN DAAS_UAT.DAAS_CORE.TRIP_MASTER m ON m.TRIP_MASTER_ID = g.TRIP_MASTER_ID
                 WHERE g.GRP = 'TEST' AND m.DELETE_IND = 'N');
        IF (v_n <> v_targets + v_partners) THEN
            v_log := v_log || 'P1 trips~|~STOP~|~' || (v_targets + v_partners - v_n) || ' of the test guests'' trips are no longer live: run PART A again#ROW#';
            RAISE rh_stop;
        END IF;
    END IF;
    -- UAT's id sequences must be past every id in the tables, or the new trips would reuse ids (the week test's check)
    SHOW SEQUENCES IN SCHEMA DAAS_UAT.DAAS_CORE;
    v_txt := (SELECT COALESCE(LISTAGG(s."name" || ' next value ' || s."next_value" || ' is not past the highest id in UAT ' || m.max_id, '; '), '')
              FROM TABLE(RESULT_SCAN(LAST_QUERY_ID())) s
              JOIN (SELECT 'TRIP_MASTER_SEQ' AS seq, MAX(TRIP_MASTER_ID) AS max_id FROM DAAS_UAT.DAAS_CORE.TRIP_MASTER
                    UNION ALL
                    SELECT 'TRIP_DETAIL_SEQ', MAX(TRIP_DETAIL_ID) FROM DAAS_UAT.DAAS_CORE.TRIP_DETAIL) m ON m.seq = s."name"
              WHERE s."next_value"::NUMBER(38,0) <= m.max_id);
    IF (v_txt <> '') THEN
        v_log := v_log || 'P1 sequences~|~STOP~|~' || v_txt || ': the week test''s part 1, statement L6, sets them#ROW#';
        RAISE rh_stop;
    END IF;
    v_log := v_log || 'P1 setup~|~ok~|~v1.4 live; ' || v_targets || ' trips to replay, ' || v_partners || ' neighbours the join rule will add, '
                   || v_rows || ' rating rows to mark' || IFF(v_resume_at > 0, '; resuming at step ' || v_resume_at, '')
                   || '; role ' || CURRENT_ROLE() || ', warehouse ' || COALESCE(CURRENT_WAREHOUSE(), '(none)') || '#ROW#';

    -- one suspended, standalone on-demand task per step, calling what the chain's task calls (the week test's lookup)
    SHOW TASKS IN SCHEMA DAAS_UAT.DAAS_COMMON;
    CREATE OR REPLACE TABLE DAAS_UAT.DAAS_TEMP_WORK.DAASI_3641_RH_TASKS AS
    WITH steps AS (
        SELECT column1 AS step_no, column2 AS job_name, column3 AS stream_name
        FROM VALUES (2, 'TRIP_MERGE_CHECK',                      'DAAS_TEMP.TRIP_MASTER_TRIP_MERGE_CHECK_STREAM'),
                    (3, 'TRIP_MERGE',                            'DAAS_CORE.TRIP_MERGE_QUEUE_STREAM'),
                    (4, 'TRIP_CUSTOMER_MERGE_CHECK_TRIP_MASTER', 'DAAS_CORE.TRIP_MASTER_TRIP_CUSTOMER_MERGE_CHECK_STREAM'),
                    (5, 'TRIP_SUMMARY_WRAPPER',                  'DAAS_CORE.TRIP_DETAIL_SUMMARY_STREAM'),
                    (6, 'TRIP_COMP_WORTH',                       NULL),
                    (7, 'TRIP_NG_REVENUE_SUMMARY',               NULL)),
    tasks AS (
        SELECT "name"::VARCHAR AS task_name, "state"::VARCHAR AS task_state, "definition"::VARCHAR AS task_definition,
               REPLACE(UPPER("definition"::VARCHAR), ' ', '') AS def_n,
               COALESCE(ARRAY_SIZE("predecessors"), 0) AS predecessor_count
        FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()))
        WHERE "name" ILIKE '%ONDEMAND%')
    SELECT s.step_no, s.job_name, s.stream_name, t.task_name, t.task_state, t.task_definition, t.predecessor_count,
           COUNT(t.task_name) OVER (PARTITION BY s.step_no) AS candidates,
           (t.def_n ILIKE ('%BATCH_CONTROL_DATA_LOAD_WRAPPER_PROC(''' || s.job_name || '''%')
            AND (s.stream_name IS NULL OR REGEXP_COUNT(t.def_n, ',') = 2 OR t.def_n ILIKE ('%' || s.stream_name || '''%'))) AS definition_ok
    FROM steps s
    LEFT JOIN tasks t ON t.task_definition ILIKE ('%''' || s.job_name || '''%')
    QUALIFY ROW_NUMBER() OVER (PARTITION BY s.step_no ORDER BY t.task_name) = 1;
    v_txt := (SELECT COALESCE(LISTAGG('step ' || step_no || ' ' || job_name || ': '
                                      || CASE WHEN task_name IS NULL THEN 'no on-demand task calls this job'
                                              WHEN candidates > 1 THEN candidates || ' on-demand tasks call this job'
                                              WHEN predecessor_count > 0 THEN task_name || ' runs after another task'
                                              WHEN NOT definition_ok THEN task_name || ' calls something else: ' || task_definition
                                              ELSE task_name || ' is ' || task_state || ', so it runs on its own schedule' END, '; ')
                              WITHIN GROUP (ORDER BY step_no), '')
              FROM DAAS_UAT.DAAS_TEMP_WORK.DAASI_3641_RH_TASKS
              WHERE task_name IS NULL OR candidates > 1 OR predecessor_count > 0 OR NOT definition_ok OR task_state <> 'suspended');
    IF (v_txt <> '') THEN
        v_log := v_log || 'P2 tasks~|~STOP~|~' || REPLACE(REPLACE(v_txt, '#ROW#', ''), '~|~', '') || '#ROW#';
        RAISE rh_stop;
    END IF;
    v_txt := (SELECT LISTAGG(step_no || ' ' || task_name, ', ') WITHIN GROUP (ORDER BY step_no) FROM DAAS_UAT.DAAS_TEMP_WORK.DAASI_3641_RH_TASKS);
    v_log := v_log || 'P2 tasks~|~ok~|~' || v_txt || '#ROW#';

    -- the POS switch row
    IF (v_skip_pos) THEN
        v_n := (SELECT COUNT(*) FROM DAAS_UAT.DAAS_CORE.TRIP_SUMMARY_CONFIG
                WHERE transaction_type = 'POS' AND active_flg = 'Y' AND stored_procedure_name ILIKE '%TRIP_POS_SUMMARY_LOAD_PROC');
        v_m := (SELECT COUNT(*) FROM DAAS_UAT.DAAS_CORE.TRIP_SUMMARY_CONFIG WHERE transaction_type = 'POS' AND active_flg = 'N');
        IF (v_n = 0 AND v_m > 0) THEN
            v_log := v_log || 'P3 POS switch~|~STOP~|~UAT''s POS summary row is already switched off: run B4, then this block again#ROW#';
            RAISE rh_stop;
        END IF;
        IF (v_n <> 1) THEN
            v_log := v_log || 'P3 POS switch~|~STOP~|~expected one active POS row in TRIP_SUMMARY_CONFIG, found ' || v_n || '#ROW#';
            RAISE rh_stop;
        END IF;
        v_pos_id := (SELECT MIN(trip_summary_config_id) FROM DAAS_UAT.DAAS_CORE.TRIP_SUMMARY_CONFIG
                     WHERE transaction_type = 'POS' AND active_flg = 'Y' AND stored_procedure_name ILIKE '%TRIP_POS_SUMMARY_LOAD_PROC');
    END IF;

    -- UAT's streams must not be stale: nothing reads them while UAT's chain is suspended (A0b shows the dates)
    SHOW STREAMS IN SCHEMA DAAS_UAT.DAAS_CORE;
    v_txt := (SELECT COALESCE(LISTAGG("name", ', ') WITHIN GROUP (ORDER BY "name"), '')
              FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()))
              WHERE "name" IN ('TRIP_MERGE_QUEUE_STREAM', 'TRIP_MASTER_TRIP_CUSTOMER_MERGE_CHECK_STREAM', 'TRIP_DETAIL_SUMMARY_STREAM',
                               'TRIP_MASTER_DAILY_SUMMARY_WRAPPER_STREAM')
                AND "stale" = 'true');
    SHOW STREAMS IN SCHEMA DAAS_UAT.DAAS_TEMP;
    v_out := (SELECT COALESCE(LISTAGG("name", ', ') WITHIN GROUP (ORDER BY "name"), '')
              FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()))
              WHERE "name" = 'TRIP_MASTER_TRIP_MERGE_CHECK_STREAM' AND "stale" = 'true');
    IF (v_txt <> '' OR v_out <> '') THEN
        v_log := v_log || 'P3 streams~|~STOP~|~stale, so the steps cannot read them: ' || v_txt || IFF(v_txt <> '' AND v_out <> '', ', ', '') || v_out
                       || '. Nothing was changed. Run A0b and send me its result#ROW#';
        RAISE rh_stop;
    END IF;

    -- may this session write the two statements, and read merge check's stream row by row?
    UPDATE DAAS_UAT.DAAS_CORE.TRIP_DETAIL SET REPLAY_COUNTER = REPLAY_COUNTER WHERE 1 = 0;
    UPDATE DAAS_UAT.DAAS_CORE.TRIP_MASTER SET REPLAY_COUNTER = REPLAY_COUNTER WHERE 1 = 0;
    BEGIN
        v_n := (SELECT COUNT(*) FROM DAAS_UAT.DAAS_TEMP.TRIP_MASTER_TRIP_MERGE_CHECK_STREAM WHERE METADATA$ACTION = 'INSERT' AND 1 = 0);
        v_can_read := TRUE;
    EXCEPTION
        WHEN OTHER THEN
            v_can_read := FALSE;
    END;
    v_log := v_log || 'P3 session~|~ok~|~may update TRIP_DETAIL and TRIP_MASTER; merge check''s stream '
                   || IFF(v_can_read, 'readable row by row', 'checked with SYSTEM$STREAM_HAS_DATA only') || '#ROW#';

    IF (v_resume_at = 0) THEN
        ---------------------------------------------------------------- the streams must be empty before the statements
        IF (v_can_read) THEN
            v_n := (SELECT COUNT(*) FROM DAAS_UAT.DAAS_TEMP.TRIP_MASTER_TRIP_MERGE_CHECK_STREAM WHERE METADATA$ACTION = 'INSERT');
        ELSE
            v_has := (SELECT SYSTEM$STREAM_HAS_DATA('DAAS_UAT.DAAS_TEMP.TRIP_MASTER_TRIP_MERGE_CHECK_STREAM'));
            v_n := IFF(v_has, 1, 0);
        END IF;
        v_m := (SELECT COUNT(*) FROM DAAS_UAT.DAAS_CORE.TRIP_DETAIL_SUMMARY_STREAM WHERE METADATA$ACTION = 'INSERT');
        v_k := (SELECT COUNT(*) FROM DAAS_UAT.DAAS_CORE.TRIP_MERGE_QUEUE_STREAM WHERE METADATA$ACTION = 'INSERT');
        BEGIN
            v_c := (SELECT COUNT(*) FROM DAAS_UAT.DAAS_CORE.TRIP_MASTER_DAILY_SUMMARY_WRAPPER_STREAM WHERE METADATA$ACTION = 'INSERT');
        EXCEPTION
            WHEN OTHER THEN v_c := 0;
        END;
        IF (v_n > 0 OR v_m > 0) THEN
            v_log := v_log || 'P4 streams~|~STOP~|~rows from an earlier run are waiting: merge check''s stream ' || v_n || ', the summary step''s stream ' || v_m
                           || '. They would be processed with ours. Nothing was changed. '
                           || IFF(v_m = 0, 'Run B0, then B1 again', 'Send me this row') || '#ROW#';
            RAISE rh_stop;
        END IF;
        IF (v_c > 0) THEN
            v_log := v_log || 'P4 streams~|~note~|~the summary step''s stream on TRIP_MASTER already holds ' || v_c
                           || ' changed trip(s) from earlier; the summary step will re-stamp their daily rows along with ours#ROW#';
        END IF;
        IF (v_k > 0) THEN
            v_log := v_log || 'P4 streams~|~note~|~the merge queue already holds ' || v_k
                           || ' row(s) (a single nomination an earlier run left waiting, as PROD would); they merge with ours#ROW#';
        END IF;

        ---------------------------------------------------------------- THE TWO STATEMENTS, as PROD will run them
        -- Statement 1: the trip rows. REPLAY_COUNTER on each trip to replay, which puts it in merge check's stream.
        UPDATE DAAS_UAT.DAAS_CORE.TRIP_MASTER TM
        SET REPLAY_COUNTER = COALESCE(REPLAY_COUNTER, 0) + 1,
            UPDATED_DTTM   = CURRENT_TIMESTAMP(),
            UPDATED_BY     = CURRENT_USER(),
            LAST_DML_CD    = 'U'
        WHERE TM.TRIP_MASTER_ID IN (
            WITH ent AS (       /* the enterprise settings: merge check's fallback where a market has none of its own */
                SELECT MAX(IFF(KEY = 'MAX_TRIP_DAYS', VALUE, NULL)) AS MAX_TRIP_DAYS,
                       MAX(IFF(KEY = 'TRIP_GAP_DAYS', VALUE, NULL)) AS TRIP_GAP_DAYS
                FROM DAAS_UAT.DAAS_CORE.TRIP_CONFIG
                WHERE CONFIG_SUBTYPE = 'ENTERPRISE' AND KEY IN ('MAX_TRIP_DAYS', 'TRIP_GAP_DAYS') AND ACTIVE_FLG = 'Y'
            ),
            multi AS (
                SELECT TRIP_MASTER_ID, GUEST_UNIQUE_ID, MARKET_CD, TRIP_START_DT, TRIP_END_DT, TRIP_END_DT - TRIP_START_DT + 1 AS TRIP_DAYS
                FROM DAAS_UAT.DAAS_CORE.TRIP_MASTER
                WHERE DELETE_IND = 'N' AND TRIP_TYPE = 'MARKET' AND MARKET_CD IN ('BEM', 'WLM') AND TRIP_END_DT > TRIP_START_DT
            ),
            caps AS (
                SELECT MARKET_CD, TRIP_START_DT,
                       DAAS_UAT.DAAS_COMMON.TRIP_CONFIG_UDF_MARKET('MAX_TRIP_DAYS', MARKET_CD, TRIP_START_DT) AS CAP,
                       DAAS_UAT.DAAS_COMMON.TRIP_CONFIG_UDF_MARKET('TRIP_GAP_DAYS', MARKET_CD, TRIP_START_DT) AS GAP
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
                  AND NOT EXISTS (SELECT 1 FROM DAAS_UAT.DAAS_CORE.TRIP_DETAIL d
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
            )
            SELECT t.TRIP_MASTER_ID
            FROM picked t
            WHERE t.GUEST_PASSES <= 30   /* everyone except the long-run guests */
              AND t.GUEST_UNIQUE_ID IN (SELECT GUEST_UNIQUE_ID FROM DAAS_UAT.DAAS_TEMP_WORK.DAASI_3641_RH_GUESTS WHERE GRP = 'TEST')   /* the one extra line: test guests only */
        );
        v_bumped := SQLROWCOUNT;
        -- Statement 2: comp worth. REPLAY_COUNTER on one rating row of each property trip and day those trips share a
        -- rating with, so the summary and comp worth steps find the property side in the same run.
        UPDATE DAAS_UAT.DAAS_CORE.TRIP_DETAIL TD
        SET REPLAY_COUNTER = COALESCE(REPLAY_COUNTER, 0) + 1,
            UPDATED_DTTM   = CURRENT_TIMESTAMP(),
            UPDATED_BY     = CURRENT_USER(),
            LAST_DML_CD    = 'U'
        WHERE TD.TRIP_DETAIL_ID IN (
            WITH ent AS (       /* the enterprise settings: merge check's fallback where a market has none of its own */
                SELECT MAX(IFF(KEY = 'MAX_TRIP_DAYS', VALUE, NULL)) AS MAX_TRIP_DAYS,
                       MAX(IFF(KEY = 'TRIP_GAP_DAYS', VALUE, NULL)) AS TRIP_GAP_DAYS
                FROM DAAS_UAT.DAAS_CORE.TRIP_CONFIG
                WHERE CONFIG_SUBTYPE = 'ENTERPRISE' AND KEY IN ('MAX_TRIP_DAYS', 'TRIP_GAP_DAYS') AND ACTIVE_FLG = 'Y'
            ),
            multi AS (
                SELECT TRIP_MASTER_ID, GUEST_UNIQUE_ID, MARKET_CD, TRIP_START_DT, TRIP_END_DT, TRIP_END_DT - TRIP_START_DT + 1 AS TRIP_DAYS
                FROM DAAS_UAT.DAAS_CORE.TRIP_MASTER
                WHERE DELETE_IND = 'N' AND TRIP_TYPE = 'MARKET' AND MARKET_CD IN ('BEM', 'WLM') AND TRIP_END_DT > TRIP_START_DT
            ),
            caps AS (
                SELECT MARKET_CD, TRIP_START_DT,
                       DAAS_UAT.DAAS_COMMON.TRIP_CONFIG_UDF_MARKET('MAX_TRIP_DAYS', MARKET_CD, TRIP_START_DT) AS CAP,
                       DAAS_UAT.DAAS_COMMON.TRIP_CONFIG_UDF_MARKET('TRIP_GAP_DAYS', MARKET_CD, TRIP_START_DT) AS GAP
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
                  AND NOT EXISTS (SELECT 1 FROM DAAS_UAT.DAAS_CORE.TRIP_DETAIL d
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
            stay AS (       /* trips holding a hotel night: merge check joins a touched trip to one of these that starts as it ends */
                SELECT DISTINCT TRIP_MASTER_ID
                FROM DAAS_UAT.DAAS_CORE.TRIP_DETAIL
                WHERE DELETE_IND = 'N' AND TRANSACTION_TYPE = 'HOTEL'
            ),
            bumped AS (     /* this statement's trips: the same ones the TRIP_MASTER statement updates */
                SELECT t.TRIP_MASTER_ID, t.GUEST_UNIQUE_ID, t.MARKET_CD, t.TRIP_START_DT, t.TRIP_END_DT, t.GAP
                FROM picked t
                WHERE t.GUEST_PASSES <= 30   /* everyone except the long-run guests */
                  AND t.GUEST_UNIQUE_ID IN (SELECT GUEST_UNIQUE_ID FROM DAAS_UAT.DAAS_TEMP_WORK.DAASI_3641_RH_GUESTS WHERE GRP = 'TEST')   /* the one extra line: test guests only */
            ),
            going AS (      /* what the run sends to the merge step: those trips, and any trip merge check's own rule pairs with one */
                SELECT b.TRIP_MASTER_ID, b.GUEST_UNIQUE_ID, b.MARKET_CD
                FROM bumped b
                UNION
                SELECT o.TRIP_MASTER_ID, b.GUEST_UNIQUE_ID, b.MARKET_CD
                FROM bumped b
                JOIN DAAS_UAT.DAAS_CORE.TRIP_MASTER o
                  ON o.GUEST_UNIQUE_ID = b.GUEST_UNIQUE_ID AND o.TRIP_TYPE = 'MARKET' AND o.MARKET_CD = b.MARKET_CD
                 AND o.DELETE_IND = 'N' AND o.TRIP_MASTER_ID <> b.TRIP_MASTER_ID
                LEFT JOIN stay s ON s.TRIP_MASTER_ID = o.TRIP_MASTER_ID
                WHERE b.TRIP_START_DT BETWEEN o.TRIP_START_DT AND o.TRIP_END_DT
                   OR o.TRIP_START_DT BETWEEN b.TRIP_START_DT AND b.TRIP_END_DT
                   OR (s.TRIP_MASTER_ID IS NOT NULL AND DATEADD(day, b.GAP, b.TRIP_END_DT) BETWEEN o.TRIP_START_DT AND o.TRIP_END_DT)
            )
            SELECT MIN(pd.TRIP_DETAIL_ID)
            FROM going g
            JOIN DAAS_UAT.DAAS_CORE.TRIP_DETAIL d  ON d.TRIP_MASTER_ID = g.TRIP_MASTER_ID                 /* the ratings the merge step carries over ... */
            JOIN DAAS_UAT.DAAS_CORE.TRIP_DETAIL pd ON pd.TRANSACTION_TABLE_SK = d.TRANSACTION_TABLE_SK    /* ... where they sit on a property trip */
            JOIN DAAS_UAT.DAAS_CORE.TRIP_MASTER p  ON p.TRIP_MASTER_ID = pd.TRIP_MASTER_ID
            WHERE d.TRANSACTION_TABLE = 'RATINGS_FACT' AND d.TRANSACTION_SUB_TYPE = 'OPENED'
              AND pd.TRANSACTION_TABLE = 'RATINGS_FACT' AND pd.DELETE_IND = 'N' AND pd.TRANSACTION_SUB_TYPE = 'OPENED'
              AND p.TRIP_TYPE = 'PROPERTY' AND p.DELETE_IND = 'N'
            GROUP BY pd.TRIP_MASTER_ID, pd.BUSINESS_START_DT, g.GUEST_UNIQUE_ID, g.MARKET_CD
        );
        v_marked := SQLROWCOUNT;
        v_txt := v_bumped || ' TRIP_MASTER rows updated (' || v_targets || ' expected), ' || v_marked || ' TRIP_DETAIL rows updated (' || v_rows || ' expected)';
        INSERT INTO DAAS_UAT.DAAS_TEMP_WORK.DAASI_3641_RH_LOG SELECT 'STATEMENTS', CURRENT_TIMESTAMP()::TIMESTAMP_NTZ, :v_txt;
        IF (v_bumped <> v_targets OR v_marked <> v_rows) THEN
            v_log := v_log || 'S1 statements~|~STOP~|~' || v_txt || ': the counts are off, no step started. Send this row#ROW#';
            RAISE rh_stop;
        END IF;
        IF (v_can_read) THEN
            v_m := (SELECT COUNT(DISTINCT s.trip_master_id) FROM DAAS_UAT.DAAS_TEMP.TRIP_MASTER_TRIP_MERGE_CHECK_STREAM s
                    JOIN DAAS_UAT.DAAS_TEMP_WORK.DAASI_3641_RH_GOING g ON g.TRIP_MASTER_ID = s.trip_master_id AND g.GRP = 'TEST' AND g.ROLE = 'TARGET'
                    WHERE s.METADATA$ACTION = 'INSERT');
            v_k := (SELECT COUNT(*) FROM DAAS_UAT.DAAS_TEMP.TRIP_MASTER_TRIP_MERGE_CHECK_STREAM WHERE METADATA$ACTION = 'INSERT');
            IF (v_m <> v_bumped OR v_k > v_m) THEN
                v_log := v_log || 'S1 statements~|~STOP~|~' || v_txt || '; merge check''s stream shows ' || v_m || ' of our trips and '
                               || (v_k - v_m) || ' other rows. No step started#ROW#';
                RAISE rh_stop;
            END IF;
        END IF;
        v_log := v_log || 'S1 statements~|~ok~|~' || v_txt || IFF(v_can_read, '; merge check''s stream shows exactly those trips', '') || '#ROW#';
    ELSE
        v_log := v_log || 'S1 statements~|~skipped~|~resuming at step ' || v_resume_at || '#ROW#';
    END IF;

    ---------------------------------------------------------------- the steps, in chain order
    v_step := GREATEST(v_resume_at, 2);
    WHILE (v_step <= 7) DO
        v_job  := (SELECT job_name  FROM DAAS_UAT.DAAS_TEMP_WORK.DAASI_3641_RH_TASKS WHERE step_no = :v_step);
        v_task := (SELECT task_name FROM DAAS_UAT.DAAS_TEMP_WORK.DAASI_3641_RH_TASKS WHERE step_no = :v_step);

        v_has := TRUE;
        IF (v_job = 'TRIP_MERGE_CHECK') THEN
            v_has := (SELECT SYSTEM$STREAM_HAS_DATA('DAAS_UAT.DAAS_TEMP.TRIP_MASTER_TRIP_MERGE_CHECK_STREAM'));
        ELSEIF (v_job = 'TRIP_MERGE') THEN
            v_has := (SELECT SYSTEM$STREAM_HAS_DATA('DAAS_UAT.DAAS_CORE.TRIP_MERGE_QUEUE_STREAM'));
        ELSEIF (v_job = 'TRIP_CUSTOMER_MERGE_CHECK_TRIP_MASTER') THEN
            v_has := (SELECT SYSTEM$STREAM_HAS_DATA('DAAS_UAT.DAAS_CORE.TRIP_MASTER_TRIP_CUSTOMER_MERGE_CHECK_STREAM'));
        ELSEIF (v_job = 'TRIP_SUMMARY_WRAPPER') THEN
            v_has := (SELECT SYSTEM$STREAM_HAS_DATA('DAAS_UAT.DAAS_CORE.TRIP_DETAIL_SUMMARY_STREAM'));
        ELSEIF (v_job = 'TRIP_NG_REVENUE_SUMMARY') THEN
            BEGIN
                v_has := (SELECT SYSTEM$STREAM_HAS_DATA('DAAS_UAT.DAAS_CORE.TRIP_DETAIL_NG_VW_STREAM'));
            EXCEPTION
                WHEN OTHER THEN v_has := FALSE;
            END;
        END IF;

        IF (NOT v_has) THEN
            IF (v_job = 'TRIP_MERGE_CHECK' OR v_job = 'TRIP_MERGE' OR v_job = 'TRIP_SUMMARY_WRAPPER') THEN
                v_log := v_log || 'S' || v_step || ' ' || v_job || '~|~STOP~|~its stream is empty, so it has nothing to work on: the step before it did not leave what it should have. Send B2#ROW#';
                RAISE rh_stop;
            END IF;
            v_log := v_log || 'S' || v_step || ' ' || v_job || '~|~skipped~|~its stream is empty, so the job has no work#ROW#';
        ELSE
            IF (v_job = 'TRIP_SUMMARY_WRAPPER' AND v_skip_pos) THEN
                UPDATE DAAS_UAT.DAAS_CORE.TRIP_SUMMARY_CONFIG SET active_flg = 'N' WHERE trip_summary_config_id = :v_pos_id AND active_flg = 'Y';
                v_n := SQLROWCOUNT;
                v_pos_off := (v_n > 0);
                INSERT INTO DAAS_UAT.DAAS_TEMP_WORK.DAASI_3641_RH_LOG SELECT 'POS_OFF', CURRENT_TIMESTAMP()::TIMESTAMP_NTZ, :v_n || ' row(s)';
                IF (v_n <> 1) THEN
                    v_log := v_log || 'S5 POS switch~|~STOP~|~switching the POS sub-step off changed ' || v_n || ' rows instead of 1; step 5 not started#ROW#';
                    RAISE rh_stop;
                END IF;
            END IF;

            v_mark := (SELECT COALESCE(MAX(batch_id), 0) FROM DAAS_UAT.DAAS_COMMON.BATCH_S02);
            BEGIN
                v_cmd := 'EXECUTE TASK DAAS_UAT.DAAS_COMMON.' || v_task;
                EXECUTE IMMEDIATE v_cmd;
            EXCEPTION
                WHEN OTHER THEN
                    v_log := v_log || 'S' || v_step || ' ' || v_job || '~|~STOP~|~could not start ' || v_task || ': '
                                   || REPLACE(REPLACE(SQLERRM, '#ROW#', ''), '~|~', '') || '#ROW#';
                    RAISE rh_stop;
            END;

            v_waited := 0;
            v_status := NULL;
            WHILE (v_waited < v_max_wait) DO
                v_wait := (SELECT SYSTEM$WAIT(20));
                v_waited := v_waited + 20;
                v_status := (SELECT MAX_BY(b.batch_status, b.batch_id) FROM DAAS_UAT.DAAS_COMMON.BATCH_S02 b
                             JOIN DAAS_UAT.DAAS_COMMON.JOB j ON j.job_id = b.job_id
                             WHERE j.job_name = :v_job AND b.batch_id > :v_mark);
                IF (v_status IS NOT NULL AND v_status <> 'IN PROGRESS') THEN BREAK; END IF;
                IF (v_status IS NULL AND v_waited >= 900) THEN BREAK; END IF;
                -- every 5 minutes: has Snowflake cancelled the task's run while the batch row still says IN PROGRESS?
                -- TASK_HISTORY may not be readable by this role; then this check is simply skipped.
                IF (MOD(v_waited, 300) = 0) THEN
                    v_out := NULL;
                    BEGIN
                        v_out := (SELECT MAX_BY(STATE || COALESCE(': ' || LEFT(ERROR_MESSAGE, 300), ''), SCHEDULED_TIME)
                                  FROM TABLE(DAAS_UAT.INFORMATION_SCHEMA.TASK_HISTORY(
                                           SCHEDULED_TIME_RANGE_START => DATEADD(hour, -6, CURRENT_TIMESTAMP()), TASK_NAME => :v_task)));
                    EXCEPTION
                        WHEN OTHER THEN v_out := NULL;
                    END;
                    IF (v_out IS NOT NULL AND (STARTSWITH(v_out, 'FAILED') OR STARTSWITH(v_out, 'CANCELLED') OR STARTSWITH(v_out, 'SKIPPED'))) THEN
                        v_status := 'TASK RUN ' || v_out || ' (the batch row stayed IN PROGRESS)';
                        BREAK;
                    END IF;
                END IF;
            END WHILE;
            IF (v_pos_off) THEN
                UPDATE DAAS_UAT.DAAS_CORE.TRIP_SUMMARY_CONFIG SET active_flg = 'Y' WHERE trip_summary_config_id = :v_pos_id AND active_flg = 'N';
                v_pos_off := FALSE;
                INSERT INTO DAAS_UAT.DAAS_TEMP_WORK.DAASI_3641_RH_LOG SELECT 'POS_ON', CURRENT_TIMESTAMP()::TIMESTAMP_NTZ, 'POS row back on';
            END IF;
            IF (v_status IS NULL) THEN
                v_log := v_log || 'S' || v_step || ' ' || v_job || '~|~STOP~|~' || v_task
                               || ' was started but logged no run within 15 minutes; its TASK_HISTORY says why (a SKIPPED run means its WHEN condition was false). '
                               || 'Then rerun with v_resume_at = ' || v_step || '#ROW#';
                RAISE rh_stop;
            END IF;
            v_batchid := (SELECT MAX(b.batch_id) FROM DAAS_UAT.DAAS_COMMON.BATCH_S02 b JOIN DAAS_UAT.DAAS_COMMON.JOB j ON j.job_id = b.job_id
                          WHERE j.job_name = :v_job AND b.batch_id > :v_mark);
            v_txt := LOWER(v_job) || '_batch';
            DELETE FROM DAAS_UAT.DAAS_TEMP_WORK.DAASI_3641_RH_MARKS WHERE MARK = :v_txt;
            INSERT INTO DAAS_UAT.DAAS_TEMP_WORK.DAASI_3641_RH_MARKS (MARK, VALUE) SELECT :v_txt, :v_batchid;
            IF (v_status = 'IN PROGRESS') THEN
                v_log := v_log || 'S' || v_step || ' ' || v_job || '~|~STOP~|~still running after ' || (v_max_wait / 60)::INTEGER
                               || ' minutes (batch ' || v_batchid || '). Let it finish (B2), then rerun with v_resume_at = ' || (v_step + 1) || '#ROW#';
                RAISE rh_stop;
            END IF;

            -- what it did
            IF (v_job = 'TRIP_MERGE_CHECK') THEN
                IF (NOT STARTSWITH(v_status, 'SUCCESS')) THEN
                    v_log := v_log || 'S2 TRIP_MERGE_CHECK~|~STOP~|~' || LEFT(v_status, 400) || ' (batch ' || v_batchid || '). Send B3#ROW#';
                    RAISE rh_stop;
                END IF;
                INSERT INTO DAAS_UAT.DAAS_TEMP_WORK.DAASI_3641_RH_QUEUE
                SELECT :v_batchid, q.trip_master_id, COALESCE(g.ROLE, 'OTHER')
                FROM (SELECT DISTINCT trip_master_id FROM DAAS_UAT.DAAS_CORE.TRIP_MERGE_QUEUE WHERE batch_id = :v_batchid) q
                LEFT JOIN DAAS_UAT.DAAS_TEMP_WORK.DAASI_3641_RH_GOING g ON g.TRIP_MASTER_ID = q.trip_master_id AND g.GRP = 'TEST';
                v_n := (SELECT COUNT(*) FROM DAAS_UAT.DAAS_TEMP_WORK.DAASI_3641_RH_QUEUE WHERE MERGE_CHECK_BATCH_ID = :v_batchid AND ROLE = 'TARGET');
                v_m := (SELECT COUNT(*) FROM DAAS_UAT.DAAS_TEMP_WORK.DAASI_3641_RH_QUEUE WHERE MERGE_CHECK_BATCH_ID = :v_batchid AND ROLE = 'PARTNER');
                v_k := (SELECT COUNT(*) FROM DAAS_UAT.DAAS_TEMP_WORK.DAASI_3641_RH_QUEUE WHERE MERGE_CHECK_BATCH_ID = :v_batchid AND ROLE = 'OTHER');
                v_log := v_log || 'S2 TRIP_MERGE_CHECK~|~' || IFF(v_n = v_targets AND v_m = v_partners AND v_k = 0, 'ok', 'LOOK') || '~|~' || LEFT(v_status, 60)
                               || ' (batch ' || v_batchid || '); sent to the merge step: ' || v_n || ' of the ' || v_targets || ' trips replayed, '
                               || v_m || ' of the ' || v_partners || ' neighbours expected, ' || v_k || ' other trips (0 expected)#ROW#';
            ELSEIF (v_job = 'TRIP_MERGE') THEN
                v_c := (SELECT COUNT(DISTINCT trip_master_id) FROM DAAS_UAT.DAAS_CORE.TRIP_MERGE_PROCESSED WHERE batch_id = :v_batchid);
                v_m := (SELECT COUNT(DISTINCT TRIP_MASTER_ID) FROM DAAS_UAT.DAAS_TEMP_WORK.DAASI_3641_RH_QUEUE);
                IF (NOT (STARTSWITH(v_status, 'SUCCESS') OR STARTSWITH(v_status, 'Alert'))) THEN
                    IF (v_c > 0 AND v_c >= v_m) THEN
                        -- UAT's known failure: the data is committed, only the closing stream reset failed (privileges). Do
                        -- what that statement was for: keep the merge's own changes in a table made from the rows themselves
                        -- (a CTAS does not move a stream), then an INSERT that reads the stream and keeps nothing (moves it).
                        v_n := -1;
                        BEGIN
                            v_cmd := 'CREATE OR REPLACE TABLE DAAS_UAT.DAAS_TEMP_WORK.DAASI_3641_RH_MERGE_CHANGES AS '
                                  || 'SELECT ' || v_batchid || '::NUMBER(38,0) AS merge_batch_id, CURRENT_TIMESTAMP()::TIMESTAMP_NTZ AS kept_at, s.* '
                                  || 'FROM DAAS_UAT.DAAS_TEMP.TRIP_MASTER_TRIP_MERGE_CHECK_STREAM s';
                            EXECUTE IMMEDIATE v_cmd;
                            v_cmd := 'INSERT INTO DAAS_UAT.DAAS_TEMP_WORK.DAASI_3641_RH_MERGE_CHANGES '
                                  || 'SELECT ' || v_batchid || ', CURRENT_TIMESTAMP()::TIMESTAMP_NTZ, s.* '
                                  || 'FROM DAAS_UAT.DAAS_TEMP.TRIP_MASTER_TRIP_MERGE_CHECK_STREAM s WHERE 0 = 1';
                            EXECUTE IMMEDIATE v_cmd;
                            v_n := (SELECT COUNT(*) FROM DAAS_UAT.DAAS_TEMP_WORK.DAASI_3641_RH_MERGE_CHANGES);
                        EXCEPTION
                            WHEN OTHER THEN
                                v_log := v_log || 'S3 TRIP_MERGE~|~STOP~|~merge committed (' || v_c || ' processed) but its stream could not be moved by this session: '
                                               || REPLACE(REPLACE(LEFT(SQLERRM, 160), '#ROW#', ''), '~|~', '') || '. Run B3b by hand, then rerun with v_resume_at = 4#ROW#';
                        END;
                        IF (v_n < 0) THEN
                            RAISE rh_stop;
                        END IF;
                        IF (v_can_read) THEN
                            v_k := (SELECT COUNT(*) FROM DAAS_UAT.DAAS_TEMP.TRIP_MASTER_TRIP_MERGE_CHECK_STREAM WHERE METADATA$ACTION = 'INSERT');
                        ELSE
                            v_has := (SELECT SYSTEM$STREAM_HAS_DATA('DAAS_UAT.DAAS_TEMP.TRIP_MASTER_TRIP_MERGE_CHECK_STREAM'));
                            v_k := IFF(v_has, 1, 0);
                        END IF;
                        IF (v_k > 0) THEN
                            v_log := v_log || 'S3 TRIP_MERGE~|~STOP~|~merge committed (' || v_c || ' processed) and ' || v_n
                                           || ' of its changes were kept, but merge check''s stream still shows rows after the move. Run B3b by hand (its last statement must show 0), then rerun with v_resume_at = 4#ROW#';
                            RAISE rh_stop;
                        END IF;
                        v_log := v_log || 'S3 TRIP_MERGE~|~ok~|~UAT''s expected FAILURE (stream reset, privileges) after committing: '
                                       || v_c || ' trips processed; merge check''s stream moved past the merge''s ' || v_n || ' changes (kept in DAASI_3641_RH_MERGE_CHANGES)#ROW#';
                    ELSE
                        v_log := v_log || 'S3 TRIP_MERGE~|~STOP~|~' || LEFT(v_status, 400) || ' (batch ' || v_batchid || '), '
                                       || v_c || ' of ' || v_m || ' nominated trips processed: the merge did not commit. Send B3#ROW#';
                        RAISE rh_stop;
                    END IF;
                ELSEIF (STARTSWITH(v_status, 'Alert')) THEN
                    v_log := v_log || 'S3 TRIP_MERGE~|~STOP~|~' || LEFT(v_status, 80) || ' (batch ' || v_batchid
                                   || '): the merge found a single nomination and waited for another, which this test does not expect. Send B2#ROW#';
                    RAISE rh_stop;
                ELSE
                    v_log := v_log || 'S3 TRIP_MERGE~|~ok~|~' || LEFT(v_status, 60) || ' (batch ' || v_batchid || '); ' || v_c || ' trips processed#ROW#';
                END IF;
                v_n := (SELECT COUNT(*) FROM DAAS_UAT.DAAS_TEMP_WORK.DAASI_3641_RH_GOING g JOIN DAAS_UAT.DAAS_CORE.TRIP_MASTER m ON m.TRIP_MASTER_ID = g.TRIP_MASTER_ID
                         WHERE g.GRP = 'TEST' AND g.ROLE = 'TARGET' AND m.DELETE_IND = 'Y');
                v_k := (SELECT COUNT(*) FROM DAAS_UAT.DAAS_CORE.TRIP_MASTER WHERE batch_id = :v_batchid AND delete_ind = 'N' AND last_dml_cd = 'I');
                v_log := v_log || 'S3 outcome~|~' || IFF(v_n = v_targets, 'ok', 'LOOK') || '~|~' || v_n || ' of the ' || v_targets
                               || ' trips replayed are retired; ' || v_k || ' trips built in their place#ROW#';
            ELSEIF (v_job = 'TRIP_CUSTOMER_MERGE_CHECK_TRIP_MASTER') THEN
                BEGIN
                    v_n := (SELECT COUNT(*) FROM DAAS_UAT.DAAS_CORE.TRIP_CUSTOMER_MERGE_QUEUE_STREAM WHERE METADATA$ACTION = 'INSERT');
                    v_txt := v_n || ' guest-merge rows waiting in the customer-merge queue (left; that step cannot run in UAT)';
                EXCEPTION
                    WHEN OTHER THEN v_txt := 'the customer-merge queue''s stream could not be read (that step cannot run in UAT anyway)';
                END;
                v_log := v_log || 'S4 TRIP_CUSTOMER_MERGE_CHECK_TRIP_MASTER~|~' || IFF(STARTSWITH(v_status, 'SUCCESS'), 'ok', 'note') || '~|~'
                               || LEFT(v_status, 120) || '; ' || v_txt || '#ROW#';
            ELSEIF (v_job = 'TRIP_SUMMARY_WRAPPER') THEN
                IF (NOT STARTSWITH(v_status, 'SUCCESS')) THEN
                    v_log := v_log || 'S5 TRIP_SUMMARY_WRAPPER~|~STOP~|~' || LEFT(v_status, 400) || ' (batch ' || v_batchid
                                   || '). The trip records are complete and checkable; the summary rows are not. Send B3, then rerun with v_resume_at = 5#ROW#';
                    RAISE rh_stop;
                END IF;
                v_n := (SELECT COUNT(*) FROM DAAS_UAT.DAAS_CORE.TRIP_SUMMARY WHERE batch_id = :v_batchid);
                v_log := v_log || 'S5 TRIP_SUMMARY_WRAPPER~|~ok~|~' || LEFT(v_status, 60) || ' (batch ' || v_batchid || '); ' || v_n || ' summary rows written'
                               || IFF(v_skip_pos, '; POS sub-step off, by design', '') || '#ROW#';
            ELSEIF (v_job = 'TRIP_COMP_WORTH') THEN
                IF (NOT STARTSWITH(v_status, 'SUCCESS')) THEN
                    v_log := v_log || 'S6 TRIP_COMP_WORTH~|~STOP~|~' || LEFT(v_status, 400) || ' (batch ' || v_batchid || '). Send B3, then rerun with v_resume_at = 6#ROW#';
                    RAISE rh_stop;
                END IF;
                v_log := v_log || 'S6 TRIP_COMP_WORTH~|~ok~|~' || LEFT(v_status, 60) || ' (batch ' || v_batchid || ')#ROW#';
            ELSE
                v_log := v_log || 'S' || v_step || ' ' || v_job || '~|~' || IFF(STARTSWITH(v_status, 'SUCCESS'), 'ok', 'note') || '~|~'
                               || LEFT(v_status, 200) || ' (batch ' || v_batchid || ')#ROW#';
            END IF;
        END IF;
        v_step := v_step + 1;
    END WHILE;

    v_txt := 'done in ' || DATEDIFF(minute, v_t0, CURRENT_TIMESTAMP()::TIMESTAMP_NTZ) || ' minutes';
    INSERT INTO DAAS_UAT.DAAS_TEMP_WORK.DAASI_3641_RH_LOG SELECT 'DONE', CURRENT_TIMESTAMP()::TIMESTAMP_NTZ, :v_txt;
    v_log := v_log || 'END~|~done~|~' || v_txt || ': next, PART C#ROW#';
    res := (SELECT t.index AS n, SPLIT_PART(t.value, '~|~', 1) AS step, SPLIT_PART(t.value, '~|~', 2) AS verdict, SPLIT_PART(t.value, '~|~', 3) AS detail
            FROM TABLE(SPLIT_TO_TABLE(:v_log, '#ROW#')) t WHERE t.value <> '' ORDER BY t.index);
    RETURN TABLE(res);
EXCEPTION
    WHEN rh_stop THEN
        IF (v_pos_off) THEN
            BEGIN
                UPDATE DAAS_UAT.DAAS_CORE.TRIP_SUMMARY_CONFIG SET active_flg = 'Y' WHERE trip_summary_config_id = :v_pos_id AND active_flg = 'N';
                v_log := v_log || 'POS switch~|~ok~|~UAT''s POS summary sub-step switched back on#ROW#';
            EXCEPTION
                WHEN OTHER THEN
                    v_log := v_log || 'POS switch~|~STOP~|~could not switch the POS sub-step back on: run B4 now#ROW#';
            END;
        END IF;
        res := (SELECT t.index AS n, SPLIT_PART(t.value, '~|~', 1) AS step, SPLIT_PART(t.value, '~|~', 2) AS verdict, SPLIT_PART(t.value, '~|~', 3) AS detail
                FROM TABLE(SPLIT_TO_TABLE(:v_log, '#ROW#')) t WHERE t.value <> '' ORDER BY t.index);
        RETURN TABLE(res);
    WHEN OTHER THEN
        v_log := v_log || 'error~|~STOP~|~' || REPLACE(REPLACE(SQLERRM, '#ROW#', ''), '~|~', '') || '#ROW#';
        IF (v_pos_off) THEN
            BEGIN
                UPDATE DAAS_UAT.DAAS_CORE.TRIP_SUMMARY_CONFIG SET active_flg = 'Y' WHERE trip_summary_config_id = :v_pos_id AND active_flg = 'N';
                v_log := v_log || 'POS switch~|~ok~|~UAT''s POS summary sub-step switched back on#ROW#';
            EXCEPTION
                WHEN OTHER THEN
                    v_log := v_log || 'POS switch~|~STOP~|~could not switch the POS sub-step back on: run B4 now#ROW#';
            END;
        END IF;
        res := (SELECT t.index AS n, SPLIT_PART(t.value, '~|~', 1) AS step, SPLIT_PART(t.value, '~|~', 2) AS verdict, SPLIT_PART(t.value, '~|~', 3) AS detail
                FROM TABLE(SPLIT_TO_TABLE(:v_log, '#ROW#')) t WHERE t.value <> '' ORDER BY t.index);
        RETURN TABLE(res);
END;
$$;


-- B2. (Only after a STOP, or to watch from another worksheet.) The trip jobs' batches since PART A began.
SELECT j.job_name, b.batch_id, b.batch_status, b.batch_start_date, b.updated_dttm AS last_update,
       ROUND(DATEDIFF(second, b.batch_start_date, b.updated_dttm) / 60, 1) AS minutes
FROM DAAS_UAT.DAAS_COMMON.BATCH_S02 b
JOIN DAAS_UAT.DAAS_COMMON.JOB j ON j.job_id = b.job_id
WHERE j.job_name LIKE 'TRIP%'
  AND b.batch_start_date >= (SELECT MIN(LOGGED_AT) FROM DAAS_UAT.DAAS_TEMP_WORK.DAASI_3641_RH_LOG WHERE STEP = 'A_START')
ORDER BY b.batch_id;

-- B3. (Only if a step failed.) The pipeline's own error log for those batches.
SELECT j.job_name, e.*
FROM DAAS_UAT.DAAS_COMMON.BATCH_ERROR_LOG_S02 e
JOIN DAAS_UAT.DAAS_COMMON.BATCH_S02 b ON b.batch_id = e.batch_id
JOIN DAAS_UAT.DAAS_COMMON.JOB j ON j.job_id = b.job_id
WHERE b.batch_start_date >= (SELECT MIN(LOGGED_AT) FROM DAAS_UAT.DAAS_TEMP_WORK.DAASI_3641_RH_LOG WHERE STEP = 'A_START')
ORDER BY e.batch_id, e.created_dttm;

-- B3b. (Only if B1 says so: the merge committed but its stream could not be moved.) By hand, the week test's way:
--      the first statement keeps the merge's own changes (a CTAS does not move a stream), the second reads the stream
--      and keeps nothing, which moves it, the third must show stream_rows_left 0. Then B1 with v_resume_at = 4.
CREATE OR REPLACE TABLE DAAS_UAT.DAAS_TEMP_WORK.DAASI_3641_RH_MERGE_CHANGES AS
SELECT (SELECT MAX(VALUE) FROM DAAS_UAT.DAAS_TEMP_WORK.DAASI_3641_RH_MARKS WHERE MARK = 'trip_merge_batch')::NUMBER(38,0) AS merge_batch_id,
       CURRENT_TIMESTAMP()::TIMESTAMP_NTZ AS kept_at,
       s.*
FROM DAAS_UAT.DAAS_TEMP.TRIP_MASTER_TRIP_MERGE_CHECK_STREAM s;

INSERT INTO DAAS_UAT.DAAS_TEMP_WORK.DAASI_3641_RH_MERGE_CHANGES
SELECT 0, CURRENT_TIMESTAMP()::TIMESTAMP_NTZ, s.*
FROM DAAS_UAT.DAAS_TEMP.TRIP_MASTER_TRIP_MERGE_CHECK_STREAM s
WHERE 0 = 1;

SELECT COUNT(*) AS merge_changes_kept,
       (SELECT COUNT(*) FROM DAAS_UAT.DAAS_TEMP.TRIP_MASTER_TRIP_MERGE_CHECK_STREAM WHERE METADATA$ACTION = 'INSERT') AS stream_rows_left_expect_0
FROM DAAS_UAT.DAAS_TEMP_WORK.DAASI_3641_RH_MERGE_CHANGES;

-- B4. (Only if B1 says to.) UAT's POS summary sub-step back on by hand.
UPDATE DAAS_UAT.DAAS_CORE.TRIP_SUMMARY_CONFIG SET active_flg = 'Y'
WHERE transaction_type = 'POS' AND active_flg = 'N' AND stored_procedure_name ILIKE '%TRIP_POS_SUMMARY_LOAD_PROC';


-- ===================================================================================================
-- PART C. The validations (read-only). One screenshot each.
-- ===================================================================================================

-- C1. The trips. Per group of guests and market: the trips over the cap with no hotel night before, how many the run
--     retired and re-cut, the neighbours the join rule added, and what was built. Expect, on the TEST rows: every trip
--     retired and re-cut and none left as it was, every neighbour merged, the longest trip built with no stay at the
--     cap (BEM 1, WLM 3), 0 built over the cap. On the CONTROL rows: 0 re-cut, all left as they were, 0 built.
WITH mark AS (SELECT MAX(IFF(MARK = 'max_trip_master_id_before', VALUE, NULL)) AS MAX_TM FROM DAAS_UAT.DAAS_TEMP_WORK.DAASI_3641_RH_MARKS),
ent AS (
    SELECT MAX(VALUE) AS MAX_TRIP_DAYS
    FROM DAAS_UAT.DAAS_CORE.TRIP_CONFIG
    WHERE CONFIG_SUBTYPE = 'ENTERPRISE' AND KEY = 'MAX_TRIP_DAYS' AND ACTIVE_FLG = 'Y'
),
sent AS (       /* the trips the statements were to send to the merge step, and whether each is retired now */
    SELECT x.GRP, x.MARKET_CD, x.ROLE, x.GUEST_UNIQUE_ID, m.DELETE_IND
    FROM DAAS_UAT.DAAS_TEMP_WORK.DAASI_3641_RH_GOING x
    JOIN DAAS_UAT.DAAS_CORE.TRIP_MASTER m ON m.TRIP_MASTER_ID = x.TRIP_MASTER_ID
),
stay AS (
    SELECT DISTINCT TRIP_MASTER_ID
    FROM DAAS_UAT.DAAS_CORE.TRIP_DETAIL
    WHERE DELETE_IND = 'N' AND TRANSACTION_TYPE = 'HOTEL'
),
built AS (      /* the market trips built since the before-picture for the same guests and markets */
    SELECT g.GRP, m.MARKET_CD, m.TRIP_MASTER_ID, m.TRIP_END_DT - m.TRIP_START_DT + 1 AS TRIP_DAYS,
           COALESCE(TRY_TO_NUMBER(DAAS_UAT.DAAS_COMMON.TRIP_CONFIG_UDF_MARKET('MAX_TRIP_DAYS', m.MARKET_CD, m.TRIP_START_DT)),
                    TRY_TO_NUMBER(e.MAX_TRIP_DAYS)) AS CAP,
           (s.TRIP_MASTER_ID IS NOT NULL) AS HAS_STAY
    FROM DAAS_UAT.DAAS_CORE.TRIP_MASTER m
    JOIN DAAS_UAT.DAAS_TEMP_WORK.DAASI_3641_RH_GUESTS g ON g.GUEST_UNIQUE_ID = m.GUEST_UNIQUE_ID AND g.MARKET_CD = m.MARKET_CD
    LEFT JOIN stay s ON s.TRIP_MASTER_ID = m.TRIP_MASTER_ID
    CROSS JOIN ent e
    CROSS JOIN mark k
    WHERE m.TRIP_TYPE = 'MARKET' AND m.DELETE_IND = 'N' AND m.TRIP_MASTER_ID > k.MAX_TM
),
a AS (
    SELECT GRP, MARKET_CD, COUNT(DISTINCT GUEST_UNIQUE_ID) AS GUESTS,
           COUNT_IF(ROLE = 'TARGET')                         AS OVER_CAP_BEFORE,
           COUNT_IF(ROLE = 'TARGET' AND DELETE_IND = 'Y')    AS RECUT,
           COUNT_IF(ROLE = 'TARGET' AND DELETE_IND = 'N')    AS LEFT_AS_THEY_WERE,
           COUNT_IF(ROLE = 'PARTNER')                        AS PARTNERS,
           COUNT_IF(ROLE = 'PARTNER' AND DELETE_IND = 'Y')   AS PARTNERS_MERGED
    FROM sent
    GROUP BY GRP, MARKET_CD
),
b AS (
    SELECT GRP, MARKET_CD, COUNT(*) AS BUILT,
           MAX(IFF(NOT HAS_STAY, TRIP_DAYS, NULL))      AS LONGEST_NO_STAY,
           COUNT_IF(NOT HAS_STAY AND TRIP_DAYS > CAP)   AS OVER_CAP_NO_STAY
    FROM built
    GROUP BY GRP, MARKET_CD
)
SELECT a.GRP                         AS guests,
       a.MARKET_CD                   AS market,
       a.GUESTS                      AS guest_count,
       a.OVER_CAP_BEFORE             AS over_cap_no_stay_before,
       a.RECUT                       AS retired_and_re_cut,
       a.LEFT_AS_THEY_WERE           AS left_as_they_were,
       a.PARTNERS                    AS neighbours_the_join_rule_adds,
       a.PARTNERS_MERGED             AS neighbours_merged,
       COALESCE(b.BUILT, 0)          AS market_trips_built,
       b.LONGEST_NO_STAY             AS longest_trip_built_no_stay_days,
       COALESCE(b.OVER_CAP_NO_STAY, 0) AS built_over_cap_no_stay
FROM a
LEFT JOIN b ON b.GRP = a.GRP AND b.MARKET_CD = a.MARKET_CD
ORDER BY a.GRP DESC, a.MARKET_CD;


-- C2. The transactions, by SK. Every transaction-night (one row per transaction and business date) that sat on a
--     market trip the run retired, and where it sits now. Expect every one on exactly one live market trip of the same
--     guest and market, on a trip that covers its date: 0 lost, 0 doubled, 0 outside, and 0 transactions on the new
--     trips that the old trips did not hold.
WITH mark AS (SELECT MAX(IFF(MARK = 'max_trip_master_id_before', VALUE, NULL)) AS MAX_TM FROM DAAS_UAT.DAAS_TEMP_WORK.DAASI_3641_RH_MARKS),
test AS (SELECT GUEST_UNIQUE_ID FROM DAAS_UAT.DAAS_TEMP_WORK.DAASI_3641_RH_GUESTS WHERE GRP = 'TEST'),
retired AS (    /* the test guests' market trips that were live in the before-picture and are retired now */
    SELECT b.TRIP_MASTER_ID, b.GUEST_UNIQUE_ID, b.MARKET_CD
    FROM DAAS_UAT.DAAS_TEMP_WORK.DAASI_3641_RH_TM_BEFORE b
    JOIN DAAS_UAT.DAAS_CORE.TRIP_MASTER m ON m.TRIP_MASTER_ID = b.TRIP_MASTER_ID
    WHERE b.TRIP_TYPE = 'MARKET' AND b.DELETE_IND = 'N' AND m.DELETE_IND = 'Y'
      AND b.GUEST_UNIQUE_ID IN (SELECT GUEST_UNIQUE_ID FROM test)
),
was AS (        /* every transaction-night those trips held: one row per transaction and business date */
    SELECT DISTINCT r.GUEST_UNIQUE_ID, r.MARKET_CD, d.TRANSACTION_TABLE, d.TRANSACTION_TABLE_SK, d.BUSINESS_START_DT
    FROM retired r
    JOIN DAAS_UAT.DAAS_TEMP_WORK.DAASI_3641_RH_TD_BEFORE d ON d.TRIP_MASTER_ID = r.TRIP_MASTER_ID
    WHERE d.DELETE_IND = 'N' AND d.TRANSACTION_SUB_TYPE = 'OPENED'
),
now_ AS (       /* the same guests' live market trips now: how many of them hold each transaction-night */
    SELECT m.GUEST_UNIQUE_ID, m.MARKET_CD, d.TRANSACTION_TABLE, d.TRANSACTION_TABLE_SK, d.BUSINESS_START_DT,
           COUNT(DISTINCT m.TRIP_MASTER_ID)                                               AS TRIPS,
           COUNT_IF(d.BUSINESS_START_DT NOT BETWEEN m.TRIP_START_DT AND m.TRIP_END_DT)    AS OUTSIDE,
           MAX(IFF(m.TRIP_MASTER_ID > k.MAX_TM, 1, 0))                                    AS ON_A_NEW_TRIP
    FROM DAAS_UAT.DAAS_CORE.TRIP_MASTER m
    JOIN DAAS_UAT.DAAS_CORE.TRIP_DETAIL d ON d.TRIP_MASTER_ID = m.TRIP_MASTER_ID
    CROSS JOIN mark k
    WHERE m.TRIP_TYPE = 'MARKET' AND m.DELETE_IND = 'N' AND d.DELETE_IND = 'N' AND d.TRANSACTION_SUB_TYPE = 'OPENED'
      AND m.GUEST_UNIQUE_ID IN (SELECT GUEST_UNIQUE_ID FROM test)
    GROUP BY m.GUEST_UNIQUE_ID, m.MARKET_CD, d.TRANSACTION_TABLE, d.TRANSACTION_TABLE_SK, d.BUSINESS_START_DT
),
added AS (      /* transactions on a trip the run built that no retired trip held */
    SELECT n.MARKET_CD, COUNT(*) AS N
    FROM (SELECT DISTINCT GUEST_UNIQUE_ID, MARKET_CD, TRANSACTION_TABLE, TRANSACTION_TABLE_SK FROM now_ WHERE ON_A_NEW_TRIP = 1) n
    LEFT JOIN (SELECT DISTINCT GUEST_UNIQUE_ID, MARKET_CD, TRANSACTION_TABLE, TRANSACTION_TABLE_SK FROM was) o
           ON o.GUEST_UNIQUE_ID = n.GUEST_UNIQUE_ID AND o.MARKET_CD = n.MARKET_CD
          AND o.TRANSACTION_TABLE = n.TRANSACTION_TABLE AND o.TRANSACTION_TABLE_SK = n.TRANSACTION_TABLE_SK
    WHERE o.TRANSACTION_TABLE_SK IS NULL
    GROUP BY n.MARKET_CD
)
SELECT w.MARKET_CD                              AS market,
       COUNT(*)                                 AS transaction_nights_on_the_retired_trips,
       COUNT_IF(COALESCE(n.TRIPS, 0) = 1)       AS now_on_exactly_one_live_trip,
       COUNT_IF(COALESCE(n.TRIPS, 0) = 0)       AS lost,
       COUNT_IF(n.TRIPS >= 2)                   AS doubled,
       COUNT_IF(n.OUTSIDE > 0)                  AS on_a_trip_that_does_not_cover_its_date,
       COALESCE(MAX(a.N), 0)                    AS on_the_new_trips_but_not_on_the_old
FROM was w
LEFT JOIN now_ n ON n.GUEST_UNIQUE_ID = w.GUEST_UNIQUE_ID AND n.MARKET_CD = w.MARKET_CD
                AND n.TRANSACTION_TABLE = w.TRANSACTION_TABLE AND n.TRANSACTION_TABLE_SK = w.TRANSACTION_TABLE_SK
                AND n.BUSINESS_START_DT = w.BUSINESS_START_DT
LEFT JOIN added a ON a.MARKET_CD = w.MARKET_CD
GROUP BY w.MARKET_CD
ORDER BY w.MARKET_CD;


-- C3. The figures. Theo (the house's expected win from the play): the retired trips' total against the total of the
--     trips built from them; expect a difference of 0.00. Comp worth (the comp dollars the play earns): each trip
--     built, against what the comp worth step adds up from the property trips holding the same ratings (each
--     different comp worth among them, once); expect comp_worth_differs 0, which shows comp worth was valued in the
--     same run as the re-cut, from statement 2's rows alone. Trips built that share no rating with a property trip
--     are left out of the comp worth columns; C3b shows what they hold.
WITH mark AS (SELECT MAX(IFF(MARK = 'max_trip_master_id_before', VALUE, NULL)) AS MAX_TM FROM DAAS_UAT.DAAS_TEMP_WORK.DAASI_3641_RH_MARKS),
test AS (SELECT GUEST_UNIQUE_ID FROM DAAS_UAT.DAAS_TEMP_WORK.DAASI_3641_RH_GUESTS WHERE GRP = 'TEST'),
retired AS (    /* the test guests' market trips that were live in the before-picture and are retired now */
    SELECT b.TRIP_MASTER_ID, b.GUEST_UNIQUE_ID, b.MARKET_CD
    FROM DAAS_UAT.DAAS_TEMP_WORK.DAASI_3641_RH_TM_BEFORE b
    JOIN DAAS_UAT.DAAS_CORE.TRIP_MASTER m ON m.TRIP_MASTER_ID = b.TRIP_MASTER_ID
    WHERE b.TRIP_TYPE = 'MARKET' AND b.DELETE_IND = 'N' AND m.DELETE_IND = 'Y'
      AND b.GUEST_UNIQUE_ID IN (SELECT GUEST_UNIQUE_ID FROM test)
),
before_ AS (
    SELECT r.MARKET_CD, COUNT(DISTINCT r.TRIP_MASTER_ID) AS TRIPS, SUM(s.TOTAL_THEO_WIN_AMT) AS THEO
    FROM retired r
    LEFT JOIN DAAS_UAT.DAAS_TEMP_WORK.DAASI_3641_RH_TS_BEFORE s ON s.TRIP_MASTER_ID = r.TRIP_MASTER_ID
    GROUP BY r.MARKET_CD
),
today AS (      /* the retired trips' own ratings, valued from UAT's RATINGS_FACT as it stands today, the way the summary step adds them up */
    SELECT r.MARKET_CD, SUM(IFF(f.GAME_TYPE_CD IN ('S', 'P', 'O'), f.THEO_WIN_AMT, 0)) AS THEO
    FROM retired r
    JOIN DAAS_UAT.DAAS_TEMP_WORK.DAASI_3641_RH_TD_BEFORE d ON d.TRIP_MASTER_ID = r.TRIP_MASTER_ID
    JOIN DAAS_UAT.DAAS_CORE.RATINGS_FACT f ON f.RATINGS_FACT_SK = d.TRANSACTION_TABLE_SK
    WHERE d.TRANSACTION_TYPE = 'RATINGS' AND d.DELETE_IND = 'N' AND d.TRANSACTION_SUB_TYPE = 'OPENED'
    GROUP BY r.MARKET_CD
),
built AS (      /* the market trips the run built for the test guests */
    SELECT m.TRIP_MASTER_ID, m.MARKET_CD, s.TOTAL_THEO_WIN_AMT AS THEO, s.COMP_WORTH
    FROM DAAS_UAT.DAAS_CORE.TRIP_MASTER m
    CROSS JOIN mark k
    LEFT JOIN DAAS_UAT.DAAS_CORE.TRIP_SUMMARY s ON s.TRIP_MASTER_ID = m.TRIP_MASTER_ID
    WHERE m.TRIP_TYPE = 'MARKET' AND m.DELETE_IND = 'N' AND m.TRIP_MASTER_ID > k.MAX_TM
      AND m.GUEST_UNIQUE_ID IN (SELECT GUEST_UNIQUE_ID FROM test)
),
shares AS (     /* each of them with the live property trips that hold one of its ratings */
    SELECT DISTINCT b.TRIP_MASTER_ID AS MARKET_TRIP, p.TRIP_MASTER_ID AS PROPERTY_TRIP
    FROM built b
    JOIN DAAS_UAT.DAAS_CORE.TRIP_DETAIL d  ON d.TRIP_MASTER_ID = b.TRIP_MASTER_ID
    JOIN DAAS_UAT.DAAS_CORE.TRIP_DETAIL pd ON pd.TRANSACTION_TABLE_SK = d.TRANSACTION_TABLE_SK
    JOIN DAAS_UAT.DAAS_CORE.TRIP_MASTER p  ON p.TRIP_MASTER_ID = pd.TRIP_MASTER_ID
    WHERE d.TRANSACTION_TYPE = 'RATINGS' AND d.DELETE_IND = 'N'
      AND pd.TRANSACTION_TYPE = 'RATINGS' AND pd.DELETE_IND = 'N'
      AND p.TRIP_TYPE = 'PROPERTY' AND p.DELETE_IND = 'N'
),
side AS (       /* what the comp worth step adds up for a market trip: each different comp worth among those property trips, once */
    SELECT x.MARKET_TRIP, COUNT(*) AS PROPERTY_TRIPS, SUM(DISTINCT ROUND(COALESCE(s.COMP_WORTH, 0), 2)) AS PROPERTY_SIDE
    FROM shares x
    LEFT JOIN DAAS_UAT.DAAS_CORE.TRIP_SUMMARY s ON s.TRIP_MASTER_ID = x.PROPERTY_TRIP
    GROUP BY x.MARKET_TRIP
),
after_ AS (
    SELECT b.MARKET_CD,
           COUNT(*)                                                                                        AS TRIPS,
           SUM(b.THEO)                                                                                     AS THEO,
           COUNT(x.MARKET_TRIP)                                                                            AS WITH_A_PROPERTY_SIDE,
           COUNT_IF(ABS(ROUND(COALESCE(b.COMP_WORTH, 0), 2) - x.PROPERTY_SIDE) <= 0.01 * x.PROPERTY_TRIPS) AS COMP_WORTH_AGREES,
           SUM(IFF(x.MARKET_TRIP IS NOT NULL, ROUND(COALESCE(b.COMP_WORTH, 0), 2), 0))                     AS COMP_WORTH_MARKET,
           SUM(x.PROPERTY_SIDE)                                                                            AS COMP_WORTH_PROPERTY
    FROM built b
    LEFT JOIN side x ON x.MARKET_TRIP = b.TRIP_MASTER_ID
    GROUP BY b.MARKET_CD
)
SELECT o.MARKET_CD                                         AS market,
       o.TRIPS                                             AS trips_retired,
       ROUND(o.THEO, 2)                                    AS theo_before,
       n.TRIPS                                             AS trips_built,
       ROUND(n.THEO, 2)                                    AS theo_after,
       ROUND(COALESCE(n.THEO, 0) - COALESCE(o.THEO, 0), 2) AS theo_difference,
       ROUND(y.THEO, 2)                                    AS theo_of_the_same_ratings_today,
       n.WITH_A_PROPERTY_SIDE                              AS built_trips_sharing_a_rating_with_a_property_trip,
       n.COMP_WORTH_AGREES                                 AS comp_worth_agrees_with_the_property_side,
       n.WITH_A_PROPERTY_SIDE - n.COMP_WORTH_AGREES        AS comp_worth_differs,
       n.COMP_WORTH_MARKET                                 AS comp_worth_market_trips,
       n.COMP_WORTH_PROPERTY                               AS comp_worth_property_side
FROM before_ o
LEFT JOIN after_ n ON n.MARKET_CD = o.MARKET_CD
LEFT JOIN today y  ON y.MARKET_CD = o.MARKET_CD
ORDER BY o.MARKET_CD;

-- C3b. The built market trips C3 left out of its comp worth columns (those sharing no rating with a property trip):
--      what they hold. Expect them under holding_no_rating_at_all, with theo 0 and comp worth 0: days of the old trips
--      with no rated play, only other transactions. A trip under holding_a_rating_no_property_trip_holds carries play
--      that no live property trip carries, so the comp worth step has nothing to value it from; their_theo is that play.
WITH mark AS (SELECT MAX(IFF(MARK = 'max_trip_master_id_before', VALUE, NULL)) AS MAX_TM FROM DAAS_UAT.DAAS_TEMP_WORK.DAASI_3641_RH_MARKS),
test AS (SELECT GUEST_UNIQUE_ID FROM DAAS_UAT.DAAS_TEMP_WORK.DAASI_3641_RH_GUESTS WHERE GRP = 'TEST'),
built AS (      /* the market trips the run built for the test guests */
    SELECT m.TRIP_MASTER_ID, m.MARKET_CD, s.TOTAL_THEO_WIN_AMT AS THEO, s.COMP_WORTH
    FROM DAAS_UAT.DAAS_CORE.TRIP_MASTER m
    CROSS JOIN mark k
    LEFT JOIN DAAS_UAT.DAAS_CORE.TRIP_SUMMARY s ON s.TRIP_MASTER_ID = m.TRIP_MASTER_ID
    WHERE m.TRIP_TYPE = 'MARKET' AND m.DELETE_IND = 'N' AND m.TRIP_MASTER_ID > k.MAX_TM
      AND m.GUEST_UNIQUE_ID IN (SELECT GUEST_UNIQUE_ID FROM test)
),
shares AS (     /* those that hold a rating a live property trip holds too: the ones C3 compared */
    SELECT DISTINCT b.TRIP_MASTER_ID
    FROM built b
    JOIN DAAS_UAT.DAAS_CORE.TRIP_DETAIL d  ON d.TRIP_MASTER_ID = b.TRIP_MASTER_ID
    JOIN DAAS_UAT.DAAS_CORE.TRIP_DETAIL pd ON pd.TRANSACTION_TABLE_SK = d.TRANSACTION_TABLE_SK
    JOIN DAAS_UAT.DAAS_CORE.TRIP_MASTER p  ON p.TRIP_MASTER_ID = pd.TRIP_MASTER_ID
    WHERE d.TRANSACTION_TYPE = 'RATINGS' AND d.DELETE_IND = 'N'
      AND pd.TRANSACTION_TYPE = 'RATINGS' AND pd.DELETE_IND = 'N'
      AND p.TRIP_TYPE = 'PROPERTY' AND p.DELETE_IND = 'N'
),
held AS (       /* the rest, each with what it holds */
    SELECT b.TRIP_MASTER_ID, b.MARKET_CD, b.THEO, b.COMP_WORTH,
           COUNT_IF(d.DELETE_IND = 'N' AND d.TRANSACTION_TYPE = 'RATINGS')  AS LIVE_RATING_ROWS
    FROM built b
    LEFT JOIN DAAS_UAT.DAAS_CORE.TRIP_DETAIL d ON d.TRIP_MASTER_ID = b.TRIP_MASTER_ID
    WHERE b.TRIP_MASTER_ID NOT IN (SELECT TRIP_MASTER_ID FROM shares)
    GROUP BY b.TRIP_MASTER_ID, b.MARKET_CD, b.THEO, b.COMP_WORTH
)
SELECT MARKET_CD                                                    AS market,
       COUNT(*)                                                     AS built_trips_not_compared_in_c3,
       COUNT_IF(LIVE_RATING_ROWS = 0)                               AS holding_no_rating_at_all,
       COUNT_IF(LIVE_RATING_ROWS > 0)                               AS holding_a_rating_no_property_trip_holds,
       ROUND(SUM(COALESCE(THEO, 0)), 2)                             AS their_theo,
       ROUND(SUM(COALESCE(COMP_WORTH, 0)), 2)                       AS their_comp_worth
FROM held
GROUP BY MARKET_CD
ORDER BY MARKET_CD;


-- C4. Nothing else changed, row for row against the before-pictures. Control guests: all four tables. Test guests:
--     their enterprise trips, their property trips, and their market trips that were not sent to the merge step.
--     Expect ok on every row (row 14 is a count for the record).
--     Rows 10 and 11: the property trips' TRIP_DETAIL rows that changed are the rows statement 2 marked, as many as A3
--     listed, and no others.
--     Rows 12 and 13: the run writes the property trips' summary and daily rows again, with the same figures. They are
--     compared on every column except the four run stamps (LAST_DML_CD, UPDATED_DTTM, UPDATED_BY, BATCH_ID) and
--     MOST_PLAYED_DENOM_AMT.
--     Rows 14 and 15 are that column: the slot denomination (the machine's bet size: a cent, a quarter, a dollar) the
--     guest played most on the trip. The summary step ranks a trip's denominations by number of ratings, then by
--     latest day played, and keeps the first. When two tie on both, nothing decides between them, so the step can
--     keep either each time it summarises the trip, and its trip-level and daily statements each rank on their own.
--     Row 14 counts the trips where the value changed; row 15 those where the old and the new value are both among
--     the denominations tied for first. The two must be equal. C4c lists them.
WITH k AS (        /* every trip of the before-picture in its class; class 0, the trips sent to the merge step, is C1 to C3's subject */
    SELECT b.TRIP_MASTER_ID,
           CASE WHEN g.GRP = 'CONTROL'            THEN 1
                WHEN s.TRIP_MASTER_ID IS NOT NULL THEN 0
                WHEN b.TRIP_TYPE = 'ENTERPRISE'   THEN 2
                WHEN b.TRIP_TYPE = 'PROPERTY'     THEN 3
                ELSE 4 END AS CLASS
    FROM DAAS_UAT.DAAS_TEMP_WORK.DAASI_3641_RH_TM_BEFORE b
    JOIN DAAS_UAT.DAAS_TEMP_WORK.DAASI_3641_RH_GUESTS g ON g.GUEST_UNIQUE_ID = b.GUEST_UNIQUE_ID
    LEFT JOIN (SELECT DISTINCT TRIP_MASTER_ID FROM DAAS_UAT.DAAS_TEMP_WORK.DAASI_3641_RH_GOING WHERE GRP = 'TEST') s ON s.TRIP_MASTER_ID = b.TRIP_MASTER_ID
),
tm_b AS (SELECT * FROM DAAS_UAT.DAAS_TEMP_WORK.DAASI_3641_RH_TM_BEFORE),
tm_n AS (SELECT * FROM DAAS_UAT.DAAS_CORE.TRIP_MASTER WHERE TRIP_MASTER_ID IN (SELECT TRIP_MASTER_ID FROM DAAS_UAT.DAAS_TEMP_WORK.DAASI_3641_RH_TM_BEFORE)),
td_b AS (SELECT * FROM DAAS_UAT.DAAS_TEMP_WORK.DAASI_3641_RH_TD_BEFORE),
td_n AS (SELECT * FROM DAAS_UAT.DAAS_CORE.TRIP_DETAIL WHERE TRIP_MASTER_ID IN (SELECT TRIP_MASTER_ID FROM DAAS_UAT.DAAS_TEMP_WORK.DAASI_3641_RH_TM_BEFORE)),
ts_b AS (SELECT * FROM DAAS_UAT.DAAS_TEMP_WORK.DAASI_3641_RH_TS_BEFORE),
ts_n AS (SELECT * FROM DAAS_UAT.DAAS_CORE.TRIP_SUMMARY WHERE TRIP_MASTER_ID IN (SELECT TRIP_MASTER_ID FROM DAAS_UAT.DAAS_TEMP_WORK.DAASI_3641_RH_TM_BEFORE)),
das_b AS (SELECT * FROM DAAS_UAT.DAAS_TEMP_WORK.DAASI_3641_RH_DAS_BEFORE),
das_n AS (SELECT * FROM DAAS_UAT.DAAS_CORE.DAILY_ACTIVITY_SUMMARY WHERE TRIP_MASTER_ID IN (SELECT TRIP_MASTER_ID FROM DAAS_UAT.DAAS_TEMP_WORK.DAASI_3641_RH_TM_BEFORE)),
ts_fb AS (SELECT * EXCLUDE (LAST_DML_CD, UPDATED_DTTM, UPDATED_BY, BATCH_ID, MOST_PLAYED_DENOM_AMT) FROM ts_b),
ts_fn AS (SELECT * EXCLUDE (LAST_DML_CD, UPDATED_DTTM, UPDATED_BY, BATCH_ID, MOST_PLAYED_DENOM_AMT) FROM ts_n),
das_fb AS (SELECT * EXCLUDE (LAST_DML_CD, UPDATED_DTTM, UPDATED_BY, BATCH_ID, MOST_PLAYED_DENOM_AMT) FROM das_b),
das_fn AS (SELECT * EXCLUDE (LAST_DML_CD, UPDATED_DTTM, UPDATED_BY, BATCH_ID, MOST_PLAYED_DENOM_AMT) FROM das_n),
diffs AS (      /* rows of the before-picture no longer there as they were (WAS 1), and rows there now that were not (WAS 0) */
    SELECT 'TRIP_MASTER' AS TBL, TRIP_MASTER_ID, NULL::NUMBER(38,0) AS TRIP_DETAIL_ID, 1 AS WAS FROM (SELECT * FROM tm_b MINUS SELECT * FROM tm_n)
    UNION ALL
    SELECT 'TRIP_MASTER', TRIP_MASTER_ID, NULL::NUMBER(38,0), 0 FROM (SELECT * FROM tm_n MINUS SELECT * FROM tm_b)
    UNION ALL
    SELECT 'TRIP_DETAIL' AS TBL, TRIP_MASTER_ID, TRIP_DETAIL_ID AS TRIP_DETAIL_ID, 1 AS WAS FROM (SELECT * FROM td_b MINUS SELECT * FROM td_n)
    UNION ALL
    SELECT 'TRIP_DETAIL', TRIP_MASTER_ID, TRIP_DETAIL_ID, 0 FROM (SELECT * FROM td_n MINUS SELECT * FROM td_b)
    UNION ALL
    SELECT 'TRIP_SUMMARY' AS TBL, TRIP_MASTER_ID, NULL::NUMBER(38,0) AS TRIP_DETAIL_ID, 1 AS WAS FROM (SELECT * FROM ts_b MINUS SELECT * FROM ts_n)
    UNION ALL
    SELECT 'TRIP_SUMMARY', TRIP_MASTER_ID, NULL::NUMBER(38,0), 0 FROM (SELECT * FROM ts_n MINUS SELECT * FROM ts_b)
    UNION ALL
    SELECT 'TRIP_SUMMARY figures' AS TBL, TRIP_MASTER_ID, NULL::NUMBER(38,0) AS TRIP_DETAIL_ID, 1 AS WAS FROM (SELECT * FROM ts_fb MINUS SELECT * FROM ts_fn)
    UNION ALL
    SELECT 'TRIP_SUMMARY figures', TRIP_MASTER_ID, NULL::NUMBER(38,0), 0 FROM (SELECT * FROM ts_fn MINUS SELECT * FROM ts_fb)
    UNION ALL
    SELECT 'DAILY_ACTIVITY_SUMMARY' AS TBL, TRIP_MASTER_ID, NULL::NUMBER(38,0) AS TRIP_DETAIL_ID, 1 AS WAS FROM (SELECT * FROM das_b MINUS SELECT * FROM das_n)
    UNION ALL
    SELECT 'DAILY_ACTIVITY_SUMMARY', TRIP_MASTER_ID, NULL::NUMBER(38,0), 0 FROM (SELECT * FROM das_n MINUS SELECT * FROM das_b)
    UNION ALL
    SELECT 'DAILY_ACTIVITY_SUMMARY figures' AS TBL, TRIP_MASTER_ID, NULL::NUMBER(38,0) AS TRIP_DETAIL_ID, 1 AS WAS FROM (SELECT * FROM das_fb MINUS SELECT * FROM das_fn)
    UNION ALL
    SELECT 'DAILY_ACTIVITY_SUMMARY figures', TRIP_MASTER_ID, NULL::NUMBER(38,0), 0 FROM (SELECT * FROM das_fn MINUS SELECT * FROM das_fb)
),
marked AS (SELECT DISTINCT TRIP_DETAIL_ID FROM DAAS_UAT.DAAS_TEMP_WORK.DAASI_3641_RH_MARK_ROWS),
n AS (          /* a changed row shows on both sides, as it was and as it is: it is counted once */
    SELECT k.CLASS, d.TBL,
           GREATEST(COUNT_IF(d.WAS = 1), COUNT_IF(d.WAS = 0))                    AS ROWS_ALL,
           COUNT_IF(d.WAS = 1)                                                   AS ROWS_CHANGED,
           GREATEST(COUNT_IF(d.WAS = 1 AND m.TRIP_DETAIL_ID IS NULL),
                    COUNT_IF(d.WAS = 0 AND m.TRIP_DETAIL_ID IS NULL))            AS ROWS_NOT_MARKED
    FROM diffs d
    JOIN k ON k.TRIP_MASTER_ID = d.TRIP_MASTER_ID
    LEFT JOIN marked m ON m.TRIP_DETAIL_ID = d.TRIP_DETAIL_ID
    GROUP BY k.CLASS, d.TBL
),
prop AS (SELECT TRIP_MASTER_ID FROM k WHERE CLASS = 3),
moved AS (      /* summary rows (S) and daily rows (D) whose MOST_PLAYED_DENOM_AMT is not what it was */
    SELECT o.TRIP_MASTER_ID, 'S' AS LVL, o.MOST_PLAYED_DENOM_AMT AS WAS, c.MOST_PLAYED_DENOM_AMT AS NOW_
    FROM DAAS_UAT.DAAS_TEMP_WORK.DAASI_3641_RH_TS_BEFORE o
    JOIN DAAS_UAT.DAAS_CORE.TRIP_SUMMARY c ON c.TRIP_MASTER_ID = o.TRIP_MASTER_ID
    WHERE o.TRIP_MASTER_ID IN (SELECT TRIP_MASTER_ID FROM prop)
      AND NOT EQUAL_NULL(o.MOST_PLAYED_DENOM_AMT, c.MOST_PLAYED_DENOM_AMT)
    UNION ALL
    SELECT o.TRIP_MASTER_ID, 'D', o.MOST_PLAYED_DENOM_AMT, c.MOST_PLAYED_DENOM_AMT
    FROM DAAS_UAT.DAAS_TEMP_WORK.DAASI_3641_RH_DAS_BEFORE o
    JOIN DAAS_UAT.DAAS_CORE.DAILY_ACTIVITY_SUMMARY c ON c.TRIP_MASTER_ID = o.TRIP_MASTER_ID AND c.GUEST_ACTIVITY_DATE = o.GUEST_ACTIVITY_DATE
    WHERE o.TRIP_MASTER_ID IN (SELECT TRIP_MASTER_ID FROM prop)
      AND NOT EQUAL_NULL(o.MOST_PLAYED_DENOM_AMT, c.MOST_PLAYED_DENOM_AMT)
),
played AS (     /* as the summary step counts them: the trip's ratings per denomination, and the last day each was played */
    SELECT d.TRIP_MASTER_ID, r.DENOM_AMT, COUNT(r.DENOM_AMT) AS RATINGS, MAX(r.BUSINESS_DT) AS LAST_PLAYED
    FROM DAAS_UAT.DAAS_CORE.TRIP_DETAIL d
    JOIN DAAS_UAT.DAAS_CORE.RATINGS_FACT r ON r.RATINGS_FACT_SK = d.TRANSACTION_TABLE_SK
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
board AS (
    SELECT l.N, l.CHECK_NAME,
           CASE l.WHAT WHEN 'CHANGED'    THEN (SELECT COUNT(*) FROM marked)
                       WHEN 'DENOM'      THEN NULL
                       WHEN 'DENOM TIED' THEN (SELECT COUNT(*) FROM judged)
                       ELSE 0 END                                                                                                AS EXPECTED,
           CASE l.WHAT WHEN 'ALL'        THEN COALESCE(n.ROWS_ALL, 0)
                       WHEN 'CHANGED'    THEN COALESCE(n.ROWS_CHANGED, 0)
                       WHEN 'NOT MARKED' THEN COALESCE(n.ROWS_NOT_MARKED, 0)
                       WHEN 'DENOM'      THEN (SELECT COUNT(*) FROM judged)
                       ELSE (SELECT COALESCE(COUNT_IF(TIED >= 2 AND VALUES_NOT_FIRST = 0), 0) FROM judged) END                  AS ACTUAL
    FROM (VALUES
                 ( 1, 1, 'TRIP_MASTER', 'ALL', 'Control guests: TRIP_MASTER rows that differ from the before-picture'),
                 ( 2, 1, 'TRIP_DETAIL', 'ALL', 'Control guests: TRIP_DETAIL rows that differ'),
                 ( 3, 1, 'TRIP_SUMMARY', 'ALL', 'Control guests: TRIP_SUMMARY rows that differ'),
                 ( 4, 1, 'DAILY_ACTIVITY_SUMMARY', 'ALL', 'Control guests: DAILY_ACTIVITY_SUMMARY rows that differ'),
                 ( 5, 2, 'TRIP_MASTER', 'ALL', 'Test guests, enterprise trips: TRIP_MASTER rows that differ'),
                 ( 6, 2, 'TRIP_DETAIL', 'ALL', 'Test guests, enterprise trips: TRIP_DETAIL rows that differ'),
                 ( 7, 2, 'TRIP_SUMMARY', 'ALL', 'Test guests, enterprise trips: TRIP_SUMMARY rows that differ'),
                 ( 8, 2, 'DAILY_ACTIVITY_SUMMARY', 'ALL', 'Test guests, enterprise trips: DAILY_ACTIVITY_SUMMARY rows that differ'),
                 ( 9, 3, 'TRIP_MASTER', 'ALL', 'Test guests, property trips: TRIP_MASTER rows that differ'),
                 (10, 3, 'TRIP_DETAIL', 'CHANGED', 'Test guests, property trips: TRIP_DETAIL rows changed (expected: the rows statement 2 marked)'),
                 (11, 3, 'TRIP_DETAIL', 'NOT MARKED', 'Test guests, property trips: TRIP_DETAIL changes on any other row'),
                 (12, 3, 'TRIP_SUMMARY figures', 'ALL', 'Test guests, property trips: TRIP_SUMMARY rows with a figure that differs (run stamps and most-played denomination aside)'),
                 (13, 3, 'DAILY_ACTIVITY_SUMMARY figures', 'ALL', 'Test guests, property trips: DAILY_ACTIVITY_SUMMARY rows with a figure that differs (same two aside)'),
                 (14, 3, '-', 'DENOM', 'Test guests, property trips: trips whose most-played denomination changed, on the summary row or a daily row'),
                 (15, 3, '-', 'DENOM TIED', '... of them, trips where the old and the new value are two of the denominations tied for most played'),
                 (16, 4, 'TRIP_MASTER', 'ALL', 'Test guests, market trips not sent to the merge step: TRIP_MASTER rows that differ'),
                 (17, 4, 'TRIP_DETAIL', 'ALL', 'Test guests, market trips not sent to the merge step: TRIP_DETAIL rows that differ'),
                 (18, 4, 'TRIP_SUMMARY', 'ALL', 'Test guests, market trips not sent to the merge step: TRIP_SUMMARY rows that differ'),
                 (19, 4, 'DAILY_ACTIVITY_SUMMARY', 'ALL', 'Test guests, market trips not sent to the merge step: DAILY_ACTIVITY_SUMMARY rows that differ')
         ) AS l (N, CLASS, TBL, WHAT, CHECK_NAME)
    LEFT JOIN n ON n.CLASS = l.CLASS AND n.TBL = l.TBL
)
SELECT N, CHECK_NAME, EXPECTED, ACTUAL,
       CASE WHEN EXPECTED IS NULL THEN 'for the record' WHEN ACTUAL = EXPECTED THEN 'ok' ELSE 'LOOK' END AS VERDICT
FROM board
ORDER BY N;

-- C4b. (Only if row 12 or 13 of C4 is not 0.) Which columns differ on the property trips' summary and daily rows,
--      MOST_PLAYED_DENOM_AMT included: one line per column, with how many rows, the largest difference where it is a
--      number, and one example. The four run stamps are left out, as in C4.
WITH prop AS (       /* the test guests' property trips: the trips rows 12 and 13 of C4 are about */
    SELECT b.TRIP_MASTER_ID, b.PROPERTY_CD, b.TRIP_START_DT, b.TRIP_END_DT
    FROM DAAS_UAT.DAAS_TEMP_WORK.DAASI_3641_RH_TM_BEFORE b
    JOIN DAAS_UAT.DAAS_TEMP_WORK.DAASI_3641_RH_GUESTS g ON g.GUEST_UNIQUE_ID = b.GUEST_UNIQUE_ID
    WHERE g.GRP = 'TEST' AND b.TRIP_TYPE = 'PROPERTY'
),
was AS (        /* each row as it was, as one object of column: value (a trip's summary row carries a stand-in date) */
    SELECT 'TRIP_SUMMARY' AS TBL, TRIP_MASTER_ID, '1900-01-01'::DATE AS ACTIVITY_DATE, OBJECT_CONSTRUCT_KEEP_NULL(*) AS R
    FROM DAAS_UAT.DAAS_TEMP_WORK.DAASI_3641_RH_TS_BEFORE
    WHERE TRIP_MASTER_ID IN (SELECT TRIP_MASTER_ID FROM prop)
    UNION ALL
    SELECT 'DAILY_ACTIVITY_SUMMARY', TRIP_MASTER_ID, GUEST_ACTIVITY_DATE, OBJECT_CONSTRUCT_KEEP_NULL(*)
    FROM DAAS_UAT.DAAS_TEMP_WORK.DAASI_3641_RH_DAS_BEFORE
    WHERE TRIP_MASTER_ID IN (SELECT TRIP_MASTER_ID FROM prop)
),
now_ AS (       /* the same rows as they are now */
    SELECT 'TRIP_SUMMARY' AS TBL, TRIP_MASTER_ID, '1900-01-01'::DATE AS ACTIVITY_DATE, OBJECT_CONSTRUCT_KEEP_NULL(*) AS R
    FROM DAAS_UAT.DAAS_CORE.TRIP_SUMMARY
    WHERE TRIP_MASTER_ID IN (SELECT TRIP_MASTER_ID FROM prop)
    UNION ALL
    SELECT 'DAILY_ACTIVITY_SUMMARY', TRIP_MASTER_ID, GUEST_ACTIVITY_DATE, OBJECT_CONSTRUCT_KEEP_NULL(*)
    FROM DAAS_UAT.DAAS_CORE.DAILY_ACTIVITY_SUMMARY
    WHERE TRIP_MASTER_ID IN (SELECT TRIP_MASTER_ID FROM prop)
),
paired AS (
    SELECT COALESCE(w.TBL, n.TBL) AS TBL, COALESCE(w.TRIP_MASTER_ID, n.TRIP_MASTER_ID) AS TRIP_MASTER_ID,
           w.R AS R_WAS, n.R AS R_NOW
    FROM was w
    FULL OUTER JOIN now_ n ON n.TBL = w.TBL AND n.TRIP_MASTER_ID = w.TRIP_MASTER_ID AND n.ACTIVITY_DATE = w.ACTIVITY_DATE
),
cells AS (      /* one row per column whose value is not what it was, the four run stamps aside */
    SELECT p.TBL, p.TRIP_MASTER_ID, f.KEY AS COLUMN_NAME,
           f.VALUE::VARCHAR AS V_WAS, GET(p.R_NOW, f.KEY)::VARCHAR AS V_NOW
    FROM paired p,
         LATERAL FLATTEN(INPUT => p.R_WAS) f
    WHERE p.R_NOW IS NOT NULL
      AND f.KEY NOT IN ('LAST_DML_CD', 'UPDATED_DTTM', 'UPDATED_BY', 'BATCH_ID')
      AND NOT EQUAL_NULL(f.VALUE::VARCHAR, GET(p.R_NOW, f.KEY)::VARCHAR)
)
SELECT TBL                                                                    AS table_name,
       COLUMN_NAME                                                            AS column_that_differs,
       COUNT(*)                                                               AS rows_where_it_differs,
       COUNT(DISTINCT TRIP_MASTER_ID)                                         AS on_this_many_trips,
       MAX(ABS(TRY_TO_DOUBLE(V_WAS) - TRY_TO_DOUBLE(V_NOW)))                  AS largest_difference_if_a_number,
       MIN(COALESCE(V_WAS, 'null') || '  ->  ' || COALESCE(V_NOW, 'null'))    AS an_example_was_to_now
FROM cells
GROUP BY TBL, COLUMN_NAME
UNION ALL
SELECT TBL, IFF(R_NOW IS NULL, '(a row of the before-picture that is gone)', '(a row that was not there before)'),
       COUNT(*), COUNT(DISTINCT TRIP_MASTER_ID), NULL, NULL
FROM paired
WHERE R_WAS IS NULL OR R_NOW IS NULL
GROUP BY 1, 2
ORDER BY 1 DESC, 3 DESC, 2;

-- C4c. The trips of row 14 of C4, one line each: what the most-played denomination was and is on the summary row
--      and on the daily rows, and the denominations the summary step's own ranking puts in first place on that trip.
--      Expect two or more tied on every line and 'yes' in the last column: the same trip, summarised again, with
--      another of its equally-played denominations. The second screenshot for C4.
WITH prop AS (       /* the test guests' property trips: the trips rows 12 and 13 of C4 are about */
    SELECT b.TRIP_MASTER_ID, b.PROPERTY_CD, b.TRIP_START_DT, b.TRIP_END_DT
    FROM DAAS_UAT.DAAS_TEMP_WORK.DAASI_3641_RH_TM_BEFORE b
    JOIN DAAS_UAT.DAAS_TEMP_WORK.DAASI_3641_RH_GUESTS g ON g.GUEST_UNIQUE_ID = b.GUEST_UNIQUE_ID
    WHERE g.GRP = 'TEST' AND b.TRIP_TYPE = 'PROPERTY'
),
moved AS (      /* summary rows (S) and daily rows (D) whose MOST_PLAYED_DENOM_AMT is not what it was */
    SELECT o.TRIP_MASTER_ID, 'S' AS LVL, o.MOST_PLAYED_DENOM_AMT AS WAS, c.MOST_PLAYED_DENOM_AMT AS NOW_
    FROM DAAS_UAT.DAAS_TEMP_WORK.DAASI_3641_RH_TS_BEFORE o
    JOIN DAAS_UAT.DAAS_CORE.TRIP_SUMMARY c ON c.TRIP_MASTER_ID = o.TRIP_MASTER_ID
    WHERE o.TRIP_MASTER_ID IN (SELECT TRIP_MASTER_ID FROM prop)
      AND NOT EQUAL_NULL(o.MOST_PLAYED_DENOM_AMT, c.MOST_PLAYED_DENOM_AMT)
    UNION ALL
    SELECT o.TRIP_MASTER_ID, 'D', o.MOST_PLAYED_DENOM_AMT, c.MOST_PLAYED_DENOM_AMT
    FROM DAAS_UAT.DAAS_TEMP_WORK.DAASI_3641_RH_DAS_BEFORE o
    JOIN DAAS_UAT.DAAS_CORE.DAILY_ACTIVITY_SUMMARY c ON c.TRIP_MASTER_ID = o.TRIP_MASTER_ID AND c.GUEST_ACTIVITY_DATE = o.GUEST_ACTIVITY_DATE
    WHERE o.TRIP_MASTER_ID IN (SELECT TRIP_MASTER_ID FROM prop)
      AND NOT EQUAL_NULL(o.MOST_PLAYED_DENOM_AMT, c.MOST_PLAYED_DENOM_AMT)
),
played AS (     /* as the summary step counts them: the trip's ratings per denomination, and the last day each was played */
    SELECT d.TRIP_MASTER_ID, r.DENOM_AMT, COUNT(r.DENOM_AMT) AS RATINGS, MAX(r.BUSINESS_DT) AS LAST_PLAYED
    FROM DAAS_UAT.DAAS_CORE.TRIP_DETAIL d
    JOIN DAAS_UAT.DAAS_CORE.RATINGS_FACT r ON r.RATINGS_FACT_SK = d.TRANSACTION_TABLE_SK
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
firsts AS (
    SELECT TRIP_MASTER_ID,
           LISTAGG(DENOM_AMT::VARCHAR || ' (' || RATINGS || ' ratings, last ' || LAST_PLAYED::VARCHAR || ')', ';  ')
               WITHIN GROUP (ORDER BY DENOM_AMT) AS THE_TIED
    FROM first_place
    GROUP BY TRIP_MASTER_ID
),
vals AS (       /* what the value was and is, on the summary row and on the daily rows */
    SELECT TRIP_MASTER_ID,
           MAX(IFF(LVL = 'S', WAS::VARCHAR || ' -> ' || NOW_::VARCHAR, NULL)) AS ON_THE_SUMMARY_ROW,
           MAX(IFF(LVL = 'D', WAS::VARCHAR || ' -> ' || NOW_::VARCHAR, NULL)) AS ON_THE_DAILY_ROWS
    FROM moved
    GROUP BY TRIP_MASTER_ID
)
SELECT j.TRIP_MASTER_ID, t.PROPERTY_CD, t.TRIP_START_DT, t.TRIP_END_DT,
       COALESCE(v.ON_THE_SUMMARY_ROW, 'unchanged')                      AS summary_row_was_to_now,
       j.DAILY_ROWS                                                     AS daily_rows_changed,
       COALESCE(v.ON_THE_DAILY_ROWS, 'unchanged')                       AS daily_rows_was_to_now,
       j.TIED                                                           AS denominations_tied_for_first,
       f.THE_TIED                                                       AS the_tied,
       IFF(j.TIED >= 2 AND j.VALUES_NOT_FIRST = 0, 'yes', 'NO')         AS old_and_new_are_among_them
FROM judged j
JOIN prop t ON t.TRIP_MASTER_ID = j.TRIP_MASTER_ID
LEFT JOIN vals v ON v.TRIP_MASTER_ID = j.TRIP_MASTER_ID
LEFT JOIN firsts f ON f.TRIP_MASTER_ID = j.TRIP_MASTER_ID
ORDER BY t.PROPERTY_CD, t.TRIP_START_DT, j.TRIP_MASTER_ID;


-- C5. Tracy's query from DAASI-3376 on the test guests: the longest market trip per end date, hotel stays left out,
--     longest first. As for the proof, the hotel-stay test reads TRIP_DETAIL (the proc's own test) because UAT's
--     reloaded hotel table lacks reservations PROD has. Expect every BEM row at 1 and every WLM row at 3 or less.
SELECT v.market_cd, v.trip_end_dt, MAX(v.trip_days) AS max_trip_days
FROM DAAS_UAT.DAAS_CORE_MARKETING_VW.TRIP_SUMMARY_VW v
WHERE v.market_cd IN ('BEM', 'WLM')
  AND v.trip_type = 'MARKET'
  AND v.guest_unique_id IN (SELECT GUEST_UNIQUE_ID FROM DAAS_UAT.DAAS_TEMP_WORK.DAASI_3641_RH_GUESTS WHERE GRP = 'TEST')
  AND NOT EXISTS (SELECT 1
                  FROM DAAS_UAT.DAAS_CORE.TRIP_DETAIL d
                  WHERE d.trip_master_id = v.trip_master_id
                    AND d.transaction_type = 'HOTEL'
                    AND d.delete_ind = 'N')
GROUP BY 1, 2
ORDER BY 3 DESC, 1, 2 DESC;


-- ===================================================================================================
-- PART D. The PROD post-check, tried here first (read-only). Run it before Z.
-- ===================================================================================================
-- The five queries PROD's post-check runs after each section (part 3 of the PROD files, PC1 to PC5), word for word,
-- with these guests' before-pictures standing in for PROD's backups and DAAS_UAT for DAAS_PROD. They reach the
-- rehearsal's figures by another road: by transaction key, from the before-pictures alone, with no list of guests
-- or of trips sent. So the answers are known before they run (the figures below are this rehearsal's, 12 Nov). If
-- one of them fails or reads differently, send me that result: it is the post-check that needs the fix, and this
-- is the place to find out. Z drops the before-pictures they read.

-- D1. PC1, the trips. Expect, over its lines: BEM 291 trips to replay, 171 retired and re-cut, 120 still as they
--     were; WLM 345, 233 and 112. The trips still as they were are the control guests', which PROD does not have.
--     Close to 614 and 529 market trips cut from them (a trip cut from a neighbour's own days is not counted), the
--     longest with no stay at 1 and 3 days, 0 over the cap.
WITH ent AS (       /* the enterprise settings: merge check's fallback where a market has none of its own */
    SELECT MAX(IFF(KEY = 'MAX_TRIP_DAYS', VALUE, NULL)) AS MAX_TRIP_DAYS,
           MAX(IFF(KEY = 'TRIP_GAP_DAYS', VALUE, NULL)) AS TRIP_GAP_DAYS
    FROM DAAS_UAT.DAAS_CORE.TRIP_CONFIG
    WHERE CONFIG_SUBTYPE = 'ENTERPRISE' AND KEY IN ('MAX_TRIP_DAYS', 'TRIP_GAP_DAYS') AND ACTIVE_FLG = 'Y'
),
multi AS (
    SELECT TRIP_MASTER_ID, GUEST_UNIQUE_ID, MARKET_CD, TRIP_START_DT, TRIP_END_DT, TRIP_END_DT - TRIP_START_DT + 1 AS TRIP_DAYS
    FROM DAAS_UAT.DAAS_TEMP_WORK.DAASI_3641_RH_TM_BEFORE
    WHERE DELETE_IND = 'N' AND TRIP_TYPE = 'MARKET' AND MARKET_CD IN ('BEM', 'WLM') AND TRIP_END_DT > TRIP_START_DT
),
caps AS (
    SELECT MARKET_CD, TRIP_START_DT,
           DAAS_UAT.DAAS_COMMON.TRIP_CONFIG_UDF_MARKET('MAX_TRIP_DAYS', MARKET_CD, TRIP_START_DT) AS CAP,
           DAAS_UAT.DAAS_COMMON.TRIP_CONFIG_UDF_MARKET('TRIP_GAP_DAYS', MARKET_CD, TRIP_START_DT) AS GAP
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
      AND NOT EXISTS (SELECT 1 FROM DAAS_UAT.DAAS_TEMP_WORK.DAASI_3641_RH_TD_BEFORE d
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
sect AS (       /* each trip to replay as the backup shows it, with the section of part 2 that takes it */
    SELECT t.TRIP_MASTER_ID, t.GUEST_UNIQUE_ID, t.MARKET_CD, t.TRIP_START_DT, t.TRIP_END_DT,
           CASE WHEN t.GUEST_PASSES <= 30 AND MOD(ABS(HASH(t.GUEST_UNIQUE_ID)), 100) = 0
                     THEN '1 the canary'
                WHEN t.GUEST_PASSES <= 30
                     THEN '2 the main run'
                WHEN t.GUEST_PASSES > 30 AND NOT (t.RUN_PASSES > 30 AND t.RUN_CAP = 1 AND MOD(t.PLACE_IN_RUN, 2) = 0)
                     THEN '3 the long-run guests, first cut'
                ELSE '4 the rest' END AS SECTION
    FROM picked t
),
a AS (          /* retired: its row says so, or the archival step has already deleted it */
    SELECT s.SECTION, s.MARKET_CD, COUNT(*) AS TRIPS, COUNT(DISTINCT s.GUEST_UNIQUE_ID) AS GUESTS,
           COUNT_IF(m.TRIP_MASTER_ID IS NULL OR m.DELETE_IND = 'Y') AS RETIRED
    FROM sect s
    LEFT JOIN DAAS_UAT.DAAS_CORE.TRIP_MASTER m ON m.TRIP_MASTER_ID = s.TRIP_MASTER_ID
    GROUP BY s.SECTION, s.MARKET_CD
),
mx AS (SELECT MAX(TRIP_MASTER_ID) AS MAX_TM FROM DAAS_UAT.DAAS_TEMP_WORK.DAASI_3641_RH_TM_BEFORE),
cut AS (        /* the market trips cut from them: created since the backup, same guest and market, starting inside the old trip's dates */
    SELECT m.TRIP_MASTER_ID, m.MARKET_CD, m.TRIP_START_DT, m.TRIP_END_DT - m.TRIP_START_DT + 1 AS TRIP_DAYS,
           MIN(s.SECTION) AS SECTION
    FROM sect s
    JOIN DAAS_UAT.DAAS_CORE.TRIP_MASTER m ON m.GUEST_UNIQUE_ID = s.GUEST_UNIQUE_ID AND m.MARKET_CD = s.MARKET_CD
                                         AND m.TRIP_START_DT BETWEEN s.TRIP_START_DT AND s.TRIP_END_DT
    CROSS JOIN mx
    WHERE m.TRIP_TYPE = 'MARKET' AND m.DELETE_IND = 'N' AND m.TRIP_MASTER_ID > mx.MAX_TM
    GROUP BY m.TRIP_MASTER_ID, m.MARKET_CD, m.TRIP_START_DT, m.TRIP_END_DT
),
stay AS (       /* trips holding a hotel night now */
    SELECT DISTINCT TRIP_MASTER_ID
    FROM DAAS_UAT.DAAS_CORE.TRIP_DETAIL
    WHERE DELETE_IND = 'N' AND TRANSACTION_TYPE = 'HOTEL'
),
caps_now AS (
    SELECT MARKET_CD, TRIP_START_DT,
           DAAS_UAT.DAAS_COMMON.TRIP_CONFIG_UDF_MARKET('MAX_TRIP_DAYS', MARKET_CD, TRIP_START_DT) AS CAP
    FROM (SELECT DISTINCT MARKET_CD, TRIP_START_DT FROM cut)
),
b AS (
    SELECT x.SECTION, x.MARKET_CD, COUNT(*) AS TRIPS,
           MAX(IFF(s.TRIP_MASTER_ID IS NULL, x.TRIP_DAYS, NULL)) AS LONGEST_NO_STAY,
           COUNT_IF(s.TRIP_MASTER_ID IS NULL
                    AND x.TRIP_DAYS > COALESCE(TRY_TO_NUMBER(c.CAP), TRY_TO_NUMBER(e.MAX_TRIP_DAYS))) AS OVER_CAP_NO_STAY
    FROM cut x
    JOIN caps_now c ON c.MARKET_CD = x.MARKET_CD AND c.TRIP_START_DT = x.TRIP_START_DT
    LEFT JOIN stay s ON s.TRIP_MASTER_ID = x.TRIP_MASTER_ID
    CROSS JOIN ent e
    GROUP BY x.SECTION, x.MARKET_CD
)
SELECT a.SECTION                        AS section,
       a.MARKET_CD                      AS market,
       a.GUESTS                         AS guests,
       a.TRIPS                          AS trips_to_replay_in_the_backup,
       a.RETIRED                        AS retired_and_re_cut,
       a.TRIPS - a.RETIRED              AS still_as_they_were,
       COALESCE(b.TRIPS, 0)             AS market_trips_cut_from_them,
       b.LONGEST_NO_STAY                AS longest_of_them_no_stay_days,
       COALESCE(b.OVER_CAP_NO_STAY, 0)  AS of_them_over_cap_no_stay
FROM a
LEFT JOIN b ON b.SECTION = a.SECTION AND b.MARKET_CD = a.MARKET_CD
ORDER BY a.SECTION, a.MARKET_CD;


-- D2. PC2, the transactions. Expect C2's figures: BEM 176 trips retired and 7,742 transaction-nights, all 7,742 on
--     exactly one live trip; WLM 241, 8,796 and 8,796; 0 in every other column.
WITH gone AS (       /* the BEM/WLM market trips that were live in the backup and are retired now (or retired and since archived) */
    SELECT b.TRIP_MASTER_ID, b.MARKET_CD
    FROM DAAS_UAT.DAAS_TEMP_WORK.DAASI_3641_RH_TM_BEFORE b
    LEFT JOIN DAAS_UAT.DAAS_CORE.TRIP_MASTER m ON m.TRIP_MASTER_ID = b.TRIP_MASTER_ID
    WHERE b.TRIP_TYPE = 'MARKET' AND b.MARKET_CD IN ('BEM', 'WLM') AND b.DELETE_IND = 'N'
      AND (m.TRIP_MASTER_ID IS NULL OR m.DELETE_IND = 'Y')
),
keys AS (       /* every transaction-night on those trips in the backup: one row per transaction and business date.
                   WAS_LIVE 1: the row counted there (not soft-deleted, still OPENED) */
    SELECT g.MARKET_CD, d.TRANSACTION_TABLE, d.TRANSACTION_TABLE_SK, d.BUSINESS_START_DT,
           MAX(IFF(d.DELETE_IND = 'N' AND d.TRANSACTION_SUB_TYPE = 'OPENED', 1, 0)) AS WAS_LIVE
    FROM gone g
    JOIN DAAS_UAT.DAAS_TEMP_WORK.DAASI_3641_RH_TD_BEFORE d ON d.TRIP_MASTER_ID = g.TRIP_MASTER_ID
    GROUP BY g.MARKET_CD, d.TRANSACTION_TABLE, d.TRANSACTION_TABLE_SK, d.BUSINESS_START_DT
),
found AS (      /* where each sits now: on how many live market trips of its market, and on how many live trips of the other kinds */
    SELECT k.MARKET_CD, k.TRANSACTION_TABLE, k.TRANSACTION_TABLE_SK, k.BUSINESS_START_DT, k.WAS_LIVE,
           COUNT(DISTINCT IFF(m.TRIP_TYPE = 'MARKET' AND m.MARKET_CD = k.MARKET_CD, m.TRIP_MASTER_ID, NULL)) AS MARKET_TRIPS,
           COUNT_IF(m.TRIP_TYPE = 'MARKET' AND m.MARKET_CD = k.MARKET_CD
                    AND k.BUSINESS_START_DT NOT BETWEEN m.TRIP_START_DT AND m.TRIP_END_DT)                    AS OUTSIDE,
           COUNT_IF(m.TRIP_TYPE <> 'MARKET')                                                                 AS OTHER_KINDS
    FROM keys k
    LEFT JOIN DAAS_UAT.DAAS_CORE.TRIP_DETAIL d
           ON d.TRANSACTION_TABLE = k.TRANSACTION_TABLE AND d.TRANSACTION_TABLE_SK = k.TRANSACTION_TABLE_SK
          AND d.BUSINESS_START_DT = k.BUSINESS_START_DT AND d.DELETE_IND = 'N' AND d.TRANSACTION_SUB_TYPE = 'OPENED'
    LEFT JOIN DAAS_UAT.DAAS_CORE.TRIP_MASTER m ON m.TRIP_MASTER_ID = d.TRIP_MASTER_ID AND m.DELETE_IND = 'N'
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


-- D3. PC3, theo. Expect C3's figures: 92,455.00 (BEM) and 92,848.26 (WLM) in every theo column, 0.00 in the two
--     "of it" columns and in the two differences, and the ratings sitting on 540 and 524 trips.
WITH gone AS (       /* the BEM/WLM market trips that were live in the backup and are retired now (or retired and since archived) */
    SELECT b.TRIP_MASTER_ID, b.MARKET_CD
    FROM DAAS_UAT.DAAS_TEMP_WORK.DAASI_3641_RH_TM_BEFORE b
    LEFT JOIN DAAS_UAT.DAAS_CORE.TRIP_MASTER m ON m.TRIP_MASTER_ID = b.TRIP_MASTER_ID
    WHERE b.TRIP_TYPE = 'MARKET' AND b.MARKET_CD IN ('BEM', 'WLM') AND b.DELETE_IND = 'N'
      AND (m.TRIP_MASTER_ID IS NULL OR m.DELETE_IND = 'Y')
),
held_before AS (        /* the live ratings on those trips in the backup, one row per trip and rating, as their summaries counted them */
    SELECT g.MARKET_CD, d.TRANSACTION_TABLE_SK AS SK
    FROM gone g
    JOIN DAAS_UAT.DAAS_TEMP_WORK.DAASI_3641_RH_TD_BEFORE d ON d.TRIP_MASTER_ID = g.TRIP_MASTER_ID
    WHERE d.TRANSACTION_TYPE = 'RATINGS' AND d.DELETE_IND = 'N' AND d.TRANSACTION_SUB_TYPE = 'OPENED'
),
keys AS (       /* each of those ratings once, valued from RATINGS_FACT as it stands today, the way the summary step adds theo up */
    SELECT h.MARKET_CD, h.SK, COUNT(*) AS TIMES_BEFORE, MAX(IFF(f.GAME_TYPE_CD IN ('S', 'P', 'O'), f.THEO_WIN_AMT, 0)) AS THEO
    FROM held_before h
    JOIN DAAS_UAT.DAAS_CORE.RATINGS_FACT f ON f.RATINGS_FACT_SK = h.SK
    GROUP BY h.MARKET_CD, h.SK
),
live AS (       /* every live row of those ratings now, with the trip it sits on */
    SELECT k.MARKET_CD, k.SK, m.TRIP_MASTER_ID,
           IFF(m.TRIP_TYPE = 'MARKET' AND m.MARKET_CD = k.MARKET_CD, 1, 0) AS ON_ITS_MARKET
    FROM keys k
    JOIN DAAS_UAT.DAAS_CORE.TRIP_DETAIL d ON d.TRANSACTION_TABLE_SK = k.SK AND d.TRANSACTION_TYPE = 'RATINGS' AND d.DELETE_IND = 'N'
    JOIN DAAS_UAT.DAAS_CORE.TRIP_MASTER m ON m.TRIP_MASTER_ID = d.TRIP_MASTER_ID AND m.DELETE_IND = 'N'
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
    JOIN DAAS_UAT.DAAS_CORE.TRIP_DETAIL d ON d.TRIP_MASTER_ID = h.TRIP_MASTER_ID
    JOIN DAAS_UAT.DAAS_CORE.RATINGS_FACT f ON f.RATINGS_FACT_SK = d.TRANSACTION_TABLE_SK
    WHERE d.TRANSACTION_TYPE = 'RATINGS' AND d.DELETE_IND = 'N'
    GROUP BY h.MARKET_CD
),
summ AS (       /* and what those trips' summary rows say */
    SELECT h.MARKET_CD, SUM(s.TOTAL_THEO_WIN_AMT) AS THEO
    FROM holders h
    LEFT JOIN DAAS_UAT.DAAS_CORE.TRIP_SUMMARY s ON s.TRIP_MASTER_ID = h.TRIP_MASTER_ID
    GROUP BY h.MARKET_CD
),
before_ AS (
    SELECT g.MARKET_CD, COUNT(*) AS TRIPS, SUM(s.TOTAL_THEO_WIN_AMT) AS THEO
    FROM gone g
    LEFT JOIN DAAS_UAT.DAAS_TEMP_WORK.DAASI_3641_RH_TS_BEFORE s ON s.TRIP_MASTER_ID = g.TRIP_MASTER_ID
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


-- D4. PC4, comp worth. Expect C3's figures: 540 of 540 (BEM) and 524 of 524 (WLM) valued in one run and agreeing,
--     0 differing, 0 left out, 6,298.60 and 2,189.35 on both sides.
WITH gone AS (       /* the BEM/WLM market trips that were live in the backup and are retired now (or retired and since archived) */
    SELECT b.TRIP_MASTER_ID, b.MARKET_CD
    FROM DAAS_UAT.DAAS_TEMP_WORK.DAASI_3641_RH_TM_BEFORE b
    LEFT JOIN DAAS_UAT.DAAS_CORE.TRIP_MASTER m ON m.TRIP_MASTER_ID = b.TRIP_MASTER_ID
    WHERE b.TRIP_TYPE = 'MARKET' AND b.MARKET_CD IN ('BEM', 'WLM') AND b.DELETE_IND = 'N'
      AND (m.TRIP_MASTER_ID IS NULL OR m.DELETE_IND = 'Y')
),
keys AS (       /* the ratings those trips held, live, in the backup */
    SELECT DISTINCT g.MARKET_CD, d.TRANSACTION_TABLE_SK AS SK
    FROM gone g
    JOIN DAAS_UAT.DAAS_TEMP_WORK.DAASI_3641_RH_TD_BEFORE d ON d.TRIP_MASTER_ID = g.TRIP_MASTER_ID
    WHERE d.TRANSACTION_TYPE = 'RATINGS' AND d.DELETE_IND = 'N' AND d.TRANSACTION_SUB_TYPE = 'OPENED'
),
holders AS (    /* the live market trips those ratings sit on now */
    SELECT DISTINCT m.MARKET_CD, m.TRIP_MASTER_ID
    FROM keys k
    JOIN DAAS_UAT.DAAS_CORE.TRIP_DETAIL d ON d.TRANSACTION_TABLE_SK = k.SK AND d.TRANSACTION_TYPE = 'RATINGS' AND d.DELETE_IND = 'N'
    JOIN DAAS_UAT.DAAS_CORE.TRIP_MASTER m ON m.TRIP_MASTER_ID = d.TRIP_MASTER_ID
    WHERE m.TRIP_TYPE = 'MARKET' AND m.MARKET_CD = k.MARKET_CD AND m.DELETE_IND = 'N'
),
shares AS (     /* each of those trips with the live property trips that hold one of its ratings */
    SELECT DISTINCT h.TRIP_MASTER_ID AS MARKET_TRIP, p.TRIP_MASTER_ID AS PROPERTY_TRIP
    FROM holders h
    JOIN DAAS_UAT.DAAS_CORE.TRIP_DETAIL d  ON d.TRIP_MASTER_ID = h.TRIP_MASTER_ID
    JOIN DAAS_UAT.DAAS_CORE.TRIP_DETAIL pd ON pd.TRANSACTION_TABLE_SK = d.TRANSACTION_TABLE_SK
    JOIN DAAS_UAT.DAAS_CORE.TRIP_MASTER p  ON p.TRIP_MASTER_ID = pd.TRIP_MASTER_ID
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
    LEFT JOIN DAAS_UAT.DAAS_CORE.TRIP_SUMMARY s ON s.TRIP_MASTER_ID = x.PROPERTY_TRIP
    GROUP BY x.MARKET_TRIP
),
j AS (          /* TOGETHER 1: the trip and all its property trips were last valued by one and the same run of the comp worth step */
    SELECT h.MARKET_CD, x.PROPERTY_TRIPS, x.ONCE_EACH,
           ROUND(COALESCE(s.COMP_WORTH, 0), 2) AS MARKET_SIDE,
           IFF(x.RUNS = 1 AND x.LAST_RUN = s.BATCH_ID, 1, 0) AS TOGETHER,
           IFF(ABS(ROUND(COALESCE(s.COMP_WORTH, 0), 2) - x.ONCE_EACH) <= 0.01 * x.PROPERTY_TRIPS
               OR ABS(ROUND(COALESCE(s.COMP_WORTH, 0), 2) - x.EVERY_ONE) <= 0.01 * x.PROPERTY_TRIPS, 1, 0) AS AGREES
    FROM holders h
    LEFT JOIN DAAS_UAT.DAAS_CORE.TRIP_SUMMARY s ON s.TRIP_MASTER_ID = h.TRIP_MASTER_ID
    LEFT JOIN side x ON x.MARKET_TRIP = h.TRIP_MASTER_ID
)
SELECT MARKET_CD                                                    AS market,
       COUNT(*)                                                     AS trips_the_ratings_sit_on_now,
       COUNT_IF(TOGETHER = 1)                                       AS valued_in_one_run_with_their_property_trips,
       COUNT_IF(TOGETHER = 1 AND AGREES = 1)                        AS comp_worth_agrees_with_the_property_side,
       COUNT_IF(TOGETHER = 1 AND AGREES = 0)                        AS comp_worth_differs,
       COUNT_IF(PROPERTY_TRIPS IS NOT NULL AND TOGETHER = 0)        AS left_out_valued_in_different_runs,
       COUNT_IF(PROPERTY_TRIPS IS NULL)                             AS left_out_no_property_trip_holds_their_ratings,
       SUM(IFF(TOGETHER = 1, MARKET_SIDE, 0))                       AS comp_worth_market_trips,
       SUM(IFF(TOGETHER = 1, ONCE_EACH, 0))                         AS comp_worth_property_side
FROM j
GROUP BY MARKET_CD
ORDER BY MARKET_CD;


-- D5. PC5, the property side. Expect C4's figures: row 1 at 1,070, row 2 at 1,863, row 3 at 0, row 4 at 1,070,
--     rows 5 to 8 at 0, and rows 9 and 10 equal to each other and to C4's rows 14 and 15.
WITH gone AS (       /* the BEM/WLM market trips that were live in the backup and are retired now (or retired and since archived) */
    SELECT b.TRIP_MASTER_ID, b.MARKET_CD
    FROM DAAS_UAT.DAAS_TEMP_WORK.DAASI_3641_RH_TM_BEFORE b
    LEFT JOIN DAAS_UAT.DAAS_CORE.TRIP_MASTER m ON m.TRIP_MASTER_ID = b.TRIP_MASTER_ID
    WHERE b.TRIP_TYPE = 'MARKET' AND b.MARKET_CD IN ('BEM', 'WLM') AND b.DELETE_IND = 'N'
      AND (m.TRIP_MASTER_ID IS NULL OR m.DELETE_IND = 'Y')
),
pt AS (         /* the property trips that held, live, a rating of one of those trips in the backup */
    SELECT DISTINCT p.TRIP_MASTER_ID
    FROM gone g
    JOIN DAAS_UAT.DAAS_TEMP_WORK.DAASI_3641_RH_TD_BEFORE d  ON d.TRIP_MASTER_ID = g.TRIP_MASTER_ID
    JOIN DAAS_UAT.DAAS_TEMP_WORK.DAASI_3641_RH_TD_BEFORE pd ON pd.TRANSACTION_TABLE_SK = d.TRANSACTION_TABLE_SK
    JOIN DAAS_UAT.DAAS_TEMP_WORK.DAASI_3641_RH_TM_BEFORE p  ON p.TRIP_MASTER_ID = pd.TRIP_MASTER_ID
    WHERE d.TRANSACTION_TABLE = 'RATINGS_FACT' AND d.TRANSACTION_SUB_TYPE = 'OPENED'
      AND pd.TRANSACTION_TABLE = 'RATINGS_FACT' AND pd.DELETE_IND = 'N' AND pd.TRANSACTION_SUB_TYPE = 'OPENED'
      AND p.TRIP_TYPE = 'PROPERTY' AND p.DELETE_IND = 'N'
),
tm_b AS (SELECT * FROM DAAS_UAT.DAAS_TEMP_WORK.DAASI_3641_RH_TM_BEFORE WHERE TRIP_MASTER_ID IN (SELECT TRIP_MASTER_ID FROM pt)),
tm_n AS (SELECT * FROM DAAS_UAT.DAAS_CORE.TRIP_MASTER WHERE TRIP_MASTER_ID IN (SELECT TRIP_MASTER_ID FROM pt)),
td_b AS (SELECT * FROM DAAS_UAT.DAAS_TEMP_WORK.DAASI_3641_RH_TD_BEFORE WHERE TRIP_MASTER_ID IN (SELECT TRIP_MASTER_ID FROM pt)),
td_n AS (SELECT * FROM DAAS_UAT.DAAS_CORE.TRIP_DETAIL WHERE TRIP_MASTER_ID IN (SELECT TRIP_MASTER_ID FROM pt)),
marked AS (
    SELECT n.TRIP_DETAIL_ID
    FROM td_n n
    JOIN td_b o ON o.TRIP_DETAIL_ID = n.TRIP_DETAIL_ID
    WHERE COALESCE(n.REPLAY_COUNTER, 0) > COALESCE(o.REPLAY_COUNTER, 0)
),
tdx_b AS (SELECT * EXCLUDE (REPLAY_COUNTER, UPDATED_DTTM, UPDATED_BY, LAST_DML_CD) FROM td_b),
tdx_n AS (SELECT * EXCLUDE (REPLAY_COUNTER, UPDATED_DTTM, UPDATED_BY, LAST_DML_CD) FROM td_n),
busy AS (       /* the trip's own row is not what it was, or a transaction row was added, removed or changed
                   in any column other than the four statement 2 sets */
    SELECT TRIP_MASTER_ID FROM (SELECT * FROM tm_b MINUS SELECT * FROM tm_n)
    UNION
    SELECT TRIP_MASTER_ID FROM (SELECT * FROM tdx_b MINUS SELECT * FROM tdx_n)
    UNION
    SELECT TRIP_MASTER_ID FROM (SELECT * FROM tdx_n MINUS SELECT * FROM tdx_b)
),
quiet AS (SELECT TRIP_MASTER_ID FROM pt WHERE TRIP_MASTER_ID NOT IN (SELECT TRIP_MASTER_ID FROM busy)),
ts_b AS (
    SELECT * EXCLUDE (LAST_DML_CD, UPDATED_DTTM, UPDATED_BY, BATCH_ID, MOST_PLAYED_DENOM_AMT, COMP_WORTH)
    FROM DAAS_UAT.DAAS_TEMP_WORK.DAASI_3641_RH_TS_BEFORE
    WHERE TRIP_MASTER_ID IN (SELECT TRIP_MASTER_ID FROM quiet)
),
ts_n AS (
    SELECT * EXCLUDE (LAST_DML_CD, UPDATED_DTTM, UPDATED_BY, BATCH_ID, MOST_PLAYED_DENOM_AMT, COMP_WORTH)
    FROM DAAS_UAT.DAAS_CORE.TRIP_SUMMARY
    WHERE TRIP_MASTER_ID IN (SELECT TRIP_MASTER_ID FROM quiet)
),
das_b AS (
    SELECT * EXCLUDE (LAST_DML_CD, UPDATED_DTTM, UPDATED_BY, BATCH_ID, MOST_PLAYED_DENOM_AMT, COMP_WORTH)
    FROM DAAS_UAT.DAAS_TEMP_WORK.DAASI_3641_RH_DAS_BEFORE
    WHERE TRIP_MASTER_ID IN (SELECT TRIP_MASTER_ID FROM quiet)
),
das_n AS (
    SELECT * EXCLUDE (LAST_DML_CD, UPDATED_DTTM, UPDATED_BY, BATCH_ID, MOST_PLAYED_DENOM_AMT, COMP_WORTH)
    FROM DAAS_UAT.DAAS_CORE.DAILY_ACTIVITY_SUMMARY
    WHERE TRIP_MASTER_ID IN (SELECT TRIP_MASTER_ID FROM quiet)
),
cw AS (         /* comp worth, to the cent: the summary row (S) and the daily rows (D) */
    SELECT o.TRIP_MASTER_ID, 'S' AS LVL, ABS(COALESCE(n.COMP_WORTH, 0) - COALESCE(o.COMP_WORTH, 0)) AS CHANGE
    FROM DAAS_UAT.DAAS_TEMP_WORK.DAASI_3641_RH_TS_BEFORE o
    JOIN DAAS_UAT.DAAS_CORE.TRIP_SUMMARY n ON n.TRIP_MASTER_ID = o.TRIP_MASTER_ID
    WHERE o.TRIP_MASTER_ID IN (SELECT TRIP_MASTER_ID FROM quiet)
      AND ROUND(COALESCE(o.COMP_WORTH, 0), 2) <> ROUND(COALESCE(n.COMP_WORTH, 0), 2)
    UNION ALL
    SELECT o.TRIP_MASTER_ID, 'D', 0
    FROM DAAS_UAT.DAAS_TEMP_WORK.DAASI_3641_RH_DAS_BEFORE o
    JOIN DAAS_UAT.DAAS_CORE.DAILY_ACTIVITY_SUMMARY n ON n.TRIP_MASTER_ID = o.TRIP_MASTER_ID AND n.GUEST_ACTIVITY_DATE = o.GUEST_ACTIVITY_DATE
    WHERE o.TRIP_MASTER_ID IN (SELECT TRIP_MASTER_ID FROM quiet)
      AND ROUND(COALESCE(o.COMP_WORTH, 0), 2) <> ROUND(COALESCE(n.COMP_WORTH, 0), 2)
),
moved AS (      /* summary rows (S) and daily rows (D) whose MOST_PLAYED_DENOM_AMT is not what it was */
    SELECT o.TRIP_MASTER_ID, 'S' AS LVL, o.MOST_PLAYED_DENOM_AMT AS WAS, c.MOST_PLAYED_DENOM_AMT AS NOW_
    FROM DAAS_UAT.DAAS_TEMP_WORK.DAASI_3641_RH_TS_BEFORE o
    JOIN DAAS_UAT.DAAS_CORE.TRIP_SUMMARY c ON c.TRIP_MASTER_ID = o.TRIP_MASTER_ID
    WHERE o.TRIP_MASTER_ID IN (SELECT TRIP_MASTER_ID FROM quiet)
      AND NOT EQUAL_NULL(o.MOST_PLAYED_DENOM_AMT, c.MOST_PLAYED_DENOM_AMT)
    UNION ALL
    SELECT o.TRIP_MASTER_ID, 'D', o.MOST_PLAYED_DENOM_AMT, c.MOST_PLAYED_DENOM_AMT
    FROM DAAS_UAT.DAAS_TEMP_WORK.DAASI_3641_RH_DAS_BEFORE o
    JOIN DAAS_UAT.DAAS_CORE.DAILY_ACTIVITY_SUMMARY c ON c.TRIP_MASTER_ID = o.TRIP_MASTER_ID AND c.GUEST_ACTIVITY_DATE = o.GUEST_ACTIVITY_DATE
    WHERE o.TRIP_MASTER_ID IN (SELECT TRIP_MASTER_ID FROM quiet)
      AND NOT EQUAL_NULL(o.MOST_PLAYED_DENOM_AMT, c.MOST_PLAYED_DENOM_AMT)
),
played AS (     /* as the summary step counts them: the trip's ratings per denomination, and the last day each was played */
    SELECT d.TRIP_MASTER_ID, r.DENOM_AMT, COUNT(r.DENOM_AMT) AS RATINGS, MAX(r.BUSINESS_DT) AS LAST_PLAYED
    FROM DAAS_UAT.DAAS_CORE.TRIP_DETAIL d
    JOIN DAAS_UAT.DAAS_CORE.RATINGS_FACT r ON r.RATINGS_FACT_SK = d.TRANSACTION_TABLE_SK
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
                 ( 1, 'PT', 'Property trips that held a rating of a retired trip in the backup: the trips statement 2 marks'),
                 ( 2, 'MARK', 'Rating rows on them with a replay counter higher than in the backup: the rows it marked'),
                 ( 3, 'BUSY', 'Of those trips, changed by other activity since the backup (set aside; expect few)'),
                 ( 4, 'QUIET', 'The rest, compared below with the backup'),
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


-- ===================================================================================================
-- Z. (After the screenshots and PART D.) Drop the scratch tables.
-- ===================================================================================================
DROP TABLE IF EXISTS DAAS_UAT.DAAS_TEMP_WORK.DAASI_3641_RH_CAND;
DROP TABLE IF EXISTS DAAS_UAT.DAAS_TEMP_WORK.DAASI_3641_RH_GUESTS;
DROP TABLE IF EXISTS DAAS_UAT.DAAS_TEMP_WORK.DAASI_3641_RH_LOG;
DROP TABLE IF EXISTS DAAS_UAT.DAAS_TEMP_WORK.DAASI_3641_RH_QUEUE;
DROP TABLE IF EXISTS DAAS_UAT.DAAS_TEMP_WORK.DAASI_3641_RH_MARKS;
DROP TABLE IF EXISTS DAAS_UAT.DAAS_TEMP_WORK.DAASI_3641_RH_TM_BEFORE;
DROP TABLE IF EXISTS DAAS_UAT.DAAS_TEMP_WORK.DAASI_3641_RH_TD_BEFORE;
DROP TABLE IF EXISTS DAAS_UAT.DAAS_TEMP_WORK.DAASI_3641_RH_TS_BEFORE;
DROP TABLE IF EXISTS DAAS_UAT.DAAS_TEMP_WORK.DAASI_3641_RH_DAS_BEFORE;
DROP TABLE IF EXISTS DAAS_UAT.DAAS_TEMP_WORK.DAASI_3641_RH_GOING;
DROP TABLE IF EXISTS DAAS_UAT.DAAS_TEMP_WORK.DAASI_3641_RH_MARK_ROWS;
DROP TABLE IF EXISTS DAAS_UAT.DAAS_TEMP_WORK.DAASI_3641_RH_TASKS;
DROP TABLE IF EXISTS DAAS_UAT.DAAS_TEMP_WORK.DAASI_3641_RH_MERGE_CHANGES;
DROP TABLE IF EXISTS DAAS_UAT.DAAS_TEMP_WORK.DAASI_3641_RH_WAITING;
