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
--
-- Run it statement by statement, top to bottom, once. About 30 minutes, most of it PART A's reads and the steps' waits.
-- Roles and warehouse as for the week test (DAAS_TEAM, secondary roles on). The known UAT limits are handled the same
-- way: the merge step's closing stream reset fails on privileges after its data is committed, the POS summary sub-step
-- is switched off for step 5 and back on, and the customer merge itself cannot run.
-- Scratch tables: DAAS_UAT.DAAS_TEMP_WORK.DAASI_3641_RH_* (CAND, GUESTS, LOG, QUEUE, MARKS, TM/TD/TS/DAS_BEFORE, GOING,
-- MARK_ROWS, TASKS, MERGE_CHANGES). Z at the end drops them.

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

-- A4. The setup, guest by guest: the first screenshot. Controls show the trips they hold and 0 rows to mark.
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
       g.TARGETS                    AS trip_master_rows_statement_1_updates,
       g.PARTNERS                   AS neighbours_the_join_rule_adds,
       COALESCE(m.ROWS_TO_MARK, 0)  AS trip_detail_rows_statement_2_updates,
       COALESCE(m.PROPERTY_TRIPS, 0) AS on_this_many_property_trips
FROM DAAS_UAT.DAAS_TEMP_WORK.DAASI_3641_RH_GUESTS x
JOIN g ON g.GUEST_UNIQUE_ID = x.GUEST_UNIQUE_ID
LEFT JOIN m ON m.GUEST_UNIQUE_ID = x.GUEST_UNIQUE_ID
ORDER BY x.GRP DESC, x.MARKET_CD, x.GUEST_UNIQUE_ID;


-- ===================================================================================================
-- PART B. The replay
-- ===================================================================================================

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
            v_log := v_log || 'P4 streams~|~STOP~|~the streams are not empty before the statements: merge check ' || v_n || ', detail summary ' || v_m
                           || '. Their rows would be processed with ours: run B2 and send it#ROW#';
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
--     (they hold no rating) are left out of the comp worth columns.
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


-- C4. Nothing else changed, row for row against the before-pictures. Control guests: all four tables. Test guests:
--     their enterprise trips, their property trips, and their market trips that were not sent to the merge step.
--     Expect 0 on every row but one: the property trips' TRIP_DETAIL rows that changed are the rows statement 2 marked,
--     as many as A3 listed, and nothing else. The property trips' summary rows are rewritten by the run (same figures,
--     new run stamps), so those two rows compare every column except LAST_DML_CD, UPDATED_DTTM, UPDATED_BY and BATCH_ID.
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
ts_fb AS (SELECT * EXCLUDE (LAST_DML_CD, UPDATED_DTTM, UPDATED_BY, BATCH_ID) FROM ts_b),
ts_fn AS (SELECT * EXCLUDE (LAST_DML_CD, UPDATED_DTTM, UPDATED_BY, BATCH_ID) FROM ts_n),
das_fb AS (SELECT * EXCLUDE (LAST_DML_CD, UPDATED_DTTM, UPDATED_BY, BATCH_ID) FROM das_b),
das_fn AS (SELECT * EXCLUDE (LAST_DML_CD, UPDATED_DTTM, UPDATED_BY, BATCH_ID) FROM das_n),
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
n AS (
    SELECT k.CLASS, d.TBL,
           COUNT(*)                                  AS ROWS_ALL,
           COUNT_IF(d.WAS = 1)                       AS ROWS_CHANGED,
           COUNT_IF(m.TRIP_DETAIL_ID IS NULL)        AS ROWS_NOT_MARKED
    FROM diffs d
    JOIN k ON k.TRIP_MASTER_ID = d.TRIP_MASTER_ID
    LEFT JOIN marked m ON m.TRIP_DETAIL_ID = d.TRIP_DETAIL_ID
    GROUP BY k.CLASS, d.TBL
),
board AS (
    SELECT l.N, l.CHECK_NAME,
           IFF(l.WHAT = 'CHANGED', (SELECT COUNT(*) FROM marked), 0)                                                            AS EXPECTED,
           COALESCE(CASE l.WHAT WHEN 'ALL' THEN n.ROWS_ALL WHEN 'CHANGED' THEN n.ROWS_CHANGED ELSE n.ROWS_NOT_MARKED END, 0)    AS ACTUAL
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
                 (12, 3, 'TRIP_SUMMARY figures', 'ALL', 'Test guests, property trips: TRIP_SUMMARY figures that differ (run stamps aside)'),
                 (13, 3, 'DAILY_ACTIVITY_SUMMARY figures', 'ALL', 'Test guests, property trips: DAILY_ACTIVITY_SUMMARY figures that differ (run stamps aside)'),
                 (14, 4, 'TRIP_MASTER', 'ALL', 'Test guests, market trips not sent to the merge step: TRIP_MASTER rows that differ'),
                 (15, 4, 'TRIP_DETAIL', 'ALL', 'Test guests, market trips not sent to the merge step: TRIP_DETAIL rows that differ'),
                 (16, 4, 'TRIP_SUMMARY', 'ALL', 'Test guests, market trips not sent to the merge step: TRIP_SUMMARY rows that differ'),
                 (17, 4, 'DAILY_ACTIVITY_SUMMARY', 'ALL', 'Test guests, market trips not sent to the merge step: DAILY_ACTIVITY_SUMMARY rows that differ')
         ) AS l (N, CLASS, TBL, WHAT, CHECK_NAME)
    LEFT JOIN n ON n.CLASS = l.CLASS AND n.TBL = l.TBL
)
SELECT N, CHECK_NAME, EXPECTED, ACTUAL, IFF(ACTUAL = EXPECTED, 'ok', 'LOOK') AS VERDICT
FROM board
ORDER BY N;


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
-- Z. (After the screenshots are taken.) Drop the scratch tables.
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
