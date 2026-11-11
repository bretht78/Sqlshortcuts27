-- DAASI-3641: PROD repair through the pipeline, with TRIP_MERGE_CHECK_PROC v1.4. What changes anything: the deploy,
-- and the UPDATEs of R3, each of which carries its own target logic and reads nothing but PROD's own tables.
-- Everything else here is read-only, or a scratch table the post-check needs (R1: the before-picture, which must exist
-- before the first UPDATE because the post-check compares against it; no UPDATE uses it).
--
-- Order
--   1. Deploy v1.4 to PROD (GitHub Actions, from main), right after an hourly run has finished (R4a shows none running).
--      Nothing changes on deploy alone: v1.4 only acts on a trip the chain touches, and the chain only touches a trip
--      when something lands on it.
--   2. R0 (the version), R0b (the size), R0c (the pipeline's warehouse and time limits), R0d (how many passes the
--      merge's loop will make), R0e (the longest runs on record): all read-only. Then R1, once (the before-picture:
--      scratch tables in DAAS_TEMP_WORK, minutes on Large), and R2 / R2b / R2c (previews, read-only).
--   3. The replay. Each UPDATE goes right after an hourly run has finished; the next run (TRIP_ROOT_TASK, :15 past every
--      hour, Pacific) does the rest in one pass: ratings step -> merge check (v1.4 nominates) -> merge (re-windows) ->
--      summaries -> comp worth. R3b and R4b after each.
--        R3-C   optional, first: the canary, one guest in a hundred
--        R3     the main replay: everyone except the long-run guests
--        R3-L   the long-run guests, then R3-Z an hour later: any time after R3; they do not hold it up
--   4. The post-check file after each run; R0b at the very end (it must find nothing left to replay).
--
-- Why the replay is split (R0c and R0d, 11 Nov). Each step of the chain has a time limit, two hours on the ratings
-- step, merge check and merge: a step that runs past it is cancelled by Snowflake. It rolls back whole (the ratings step
-- and the merge each do their data work in one transaction, so nothing is left half-done), but its stream is still
-- waiting, so the next hourly run tries the same set again, and the steps after it do not run until it gets through.
-- The merge is the step at risk. It rebuilds the nominated trips in passes, and the number of passes is the longest
-- unbroken run of play days of any one guest, divided by the cap (R0d). Replayed in one UPDATE, PROD's targets need 587
-- passes, because one guest played 587 days in a row at BEM; after 30 passes only 68 of the 58,972 guests are still in
-- the loop, after 100 four, after 200 that one. The yardstick is the week test: its merge made 98 passes in 18 minutes,
-- about 11 seconds a pass, on a working set of 498 thousand rows and a warehouse the same size as PROD's (both Large).
-- At that rate 587 passes is 1 hour 48 minutes of looping alone, and PROD's working set is 13.4 million rows, 27 times
-- UAT's: one UPDATE does not fit in two hours. Split by run length it does, with room: R3 leaves out the long-run
-- guests, so no run needs more than 30 passes; R3-L and R3-Z replay those guests in two short steps (R3 explains).
-- The alternative, for the record: everything in one UPDATE (R3-Z on its own), with the merge task's limit raised to
-- several hours for the day and the hourly trip pipeline paused for as long as that run takes. Both dials are the
-- architect's: the limit (ALTER TASK ... SET USER_TASK_TIMEOUT_MS) and the warehouse the steps run on (the
-- WAREHOUSE_NAME on each job's row in DAAS_COMMON.JOB, DAAS_PROD_IT_WHSRCTORAW_COMPUTE today; the April replay,
-- DAASI-2958, moved the chain's 19 jobs to DAAS_PROD_ADHOC_BULK_LOAD_COMPUTE_XL for its run). A bigger warehouse
-- shortens the early passes, when every guest is in the loop, not the long tail of small ones. Whichever way, the
-- hourly trip pipeline pauses while a run is longer than an hour (the root task waits for a run to finish before it
-- starts the next; the April and August replays paused the same way, with the downstream dynamic tables suspended).
--
-- The canary. R3-C is the first time the whole chain carries this replay end to end in PROD (UAT could not run the
-- ratings step), on about 590 guests instead of 58,900, and it times the ratings step and the merge inside an hour.
--
-- How the replay reaches the trips. An UPDATE on RATINGS_FACT lands in RATINGS_FACT_STREAM. TRIP_RATING_DOMAIN_PIPELINE_PROC
-- takes every rating in the stream through TRIP_IDENTIFIER_PROC again (its step 9 no longer filters out ratings that are
-- already on a trip), finds the trip each one sits on at every grain (property, market, enterprise) and rewrites that
-- TRIP_MASTER row (step 11: end date, UPDATED_DTTM, BATCH_ID, LAST_DML_CD). Those rewritten rows are what merge check's
-- stream shows v1.4. Same route as the August replay (DATA_REPLAY_PROC did the same UPDATE then); what differs is what
-- merge check now does with an over-cap trip. (In UAT the ratings step could not run, so the proof and the week test
-- touched TRIP_DETAIL and TRIP_MASTER directly to the same effect.)
--
-- Scope. Every live BEM/WLM market trip longer than its cap with no hotel night, measured the way v1.4 measures it,
-- reached through its ratings: 377,243 trips of 58,983 guests, 12,074,107 rating rows (29 Oct; R0b gives the day's
-- numbers). 1,633 more hold no live rating and cannot be reached this way; R2c says what they hold, and they are a
-- separate decision after the replay. The same ratings also sit on the property twin (IBE/IWA) and the enterprise trip,
-- so those masters are rewritten too and go through the same rule: a twin within its cap is left alone; R2b counts
-- anything at those grains that is over cap today and so will be re-cut in the same run.
--
-- What else the run will do (week test, 29 Oct): merge check's pre-existing pairing rule will also merge some of these
-- guests' neighbouring trips, at every grain — a touched trip that ends the day before another trip of the same guest
-- and grain, where the later one holds a hotel stay or the earlier one is within its cap. 0.2% of touched trips in the
-- week test; v1.3 does the same on any replay; the post-check lists each one with its partner.
--
-- Roles: DAAS_TEAM for the reads and the scratch tables; the R3 statements need UPDATE on
-- DAAS_PROD.DAAS_CORE.RATINGS_FACT (Pete, or whoever holds it). No session variables; the scratch tables can be dropped
-- after sign-off.

USE ROLE DAAS_TEAM;
USE SECONDARY ROLES ALL;


-- R0. Is v1.4 what PROD runs? Expect 'v1.4 is live in PROD'. (UAT's proof and the week test ran on this exact text.)
SELECT IFF(CONTAINS(GET_DDL('PROCEDURE', 'DAAS_PROD.DAAS_COMMON.TRIP_MERGE_CHECK_PROC(FLOAT, VARCHAR, VARCHAR, VARCHAR, VARCHAR)'),
                    'my_sql_command_3A'),
           'v1.4 is live in PROD', 'PROD still runs the old version: deploy v1.4 first') AS merge_check_version;


-- R0b. How many rows the replay is, read-only, before anything is created: the live ratings on every live BEM/WLM market
--      trip that is over its cap with no hotel night, measured the way v1.4 measures it (same logic as R1). The
--      ratings_fact_rows_to_update column is what R3 will report across all batches; trips and guests should agree with
--      the reach check's BEM and WLM rows. trips_with_no_live_rating are the ones a ratings replay cannot reach (R2c).
--      TRIP_DETAIL is read twice: a few minutes on Large.
WITH ent AS (
    SELECT MAX(VALUE) AS MAX_TRIP_DAYS
    FROM DAAS_PROD.DAAS_CORE.TRIP_CONFIG
    WHERE CONFIG_SUBTYPE = 'ENTERPRISE' AND KEY = 'MAX_TRIP_DAYS' AND ACTIVE_FLG = 'Y'
),
multi AS (
    SELECT TRIP_MASTER_ID, GUEST_UNIQUE_ID, MARKET_CD, TRIP_START_DT, TRIP_END_DT,
           TRIP_END_DT - TRIP_START_DT + 1 AS TRIP_DAYS
    FROM DAAS_PROD.DAAS_CORE.TRIP_MASTER
    WHERE DELETE_IND = 'N'
      AND TRIP_TYPE = 'MARKET'
      AND MARKET_CD IN ('BEM', 'WLM')
      AND TRIP_END_DT > TRIP_START_DT
),
caps AS (
    SELECT MARKET_CD, TRIP_START_DT,
           DAAS_PROD.DAAS_COMMON.TRIP_CONFIG_UDF_MARKET('MAX_TRIP_DAYS', MARKET_CD, TRIP_START_DT) AS CAP
    FROM (SELECT DISTINCT MARKET_CD, TRIP_START_DT FROM multi)
),
targets AS (
    SELECT m.*
    FROM multi m
    JOIN caps c ON c.MARKET_CD = m.MARKET_CD AND c.TRIP_START_DT = m.TRIP_START_DT
    CROSS JOIN ent e
    WHERE m.TRIP_DAYS > COALESCE(TRY_TO_NUMBER(c.CAP), TRY_TO_NUMBER(e.MAX_TRIP_DAYS))
      AND NOT EXISTS (SELECT 1
                      FROM DAAS_PROD.DAAS_CORE.TRIP_DETAIL d
                      WHERE d.TRIP_MASTER_ID = m.TRIP_MASTER_ID
                        AND d.DELETE_IND = 'N'
                        AND d.TRANSACTION_TYPE = 'HOTEL')
),
ratings AS (
    SELECT t.TRIP_MASTER_ID, d.TRANSACTION_TABLE_SK
    FROM targets t
    JOIN DAAS_PROD.DAAS_CORE.TRIP_DETAIL d ON d.TRIP_MASTER_ID = t.TRIP_MASTER_ID
    WHERE d.TRANSACTION_TABLE = 'RATINGS_FACT' AND d.DELETE_IND = 'N' AND d.TRANSACTION_SUB_TYPE = 'OPENED'
)
SELECT COALESCE(t.MARKET_CD, 'BEM + WLM')                                   AS market,
       COUNT(DISTINCT t.TRIP_MASTER_ID)                                     AS trips_over_cap_no_stay,
       COUNT(DISTINCT IFF(r.TRIP_MASTER_ID IS NOT NULL, t.TRIP_MASTER_ID, NULL)) AS trips_the_replay_reaches,
       COUNT(DISTINCT IFF(r.TRIP_MASTER_ID IS NULL, t.TRIP_MASTER_ID, NULL)) AS trips_with_no_live_rating,
       COUNT(DISTINCT t.GUEST_UNIQUE_ID)                                    AS guests,
       COUNT(DISTINCT r.TRANSACTION_TABLE_SK)                               AS ratings_fact_rows_to_update,
       MAX(t.TRIP_DAYS)                                                     AS longest_days,
       MIN(t.TRIP_START_DT)                                                 AS earliest_trip_start,
       MAX(t.TRIP_END_DT)                                                   AS latest_trip_end
FROM targets t
LEFT JOIN ratings r ON r.TRIP_MASTER_ID = t.TRIP_MASTER_ID
GROUP BY ROLLUP (t.MARKET_CD)
ORDER BY t.MARKET_CD NULLS LAST;


-- R0c. The pipeline's warehouse and time limits, read-only (see "Why the replay is split" in the header). Four small reads.
--
-- R0c-1. The warehouse each step will run on: the WAREHOUSE_NAME on the job's row. The wrapper reads it and the step's
--        procedure opens with USE WAREHOUSE on it, so this, not the task's own warehouse and not the session R3 is run
--        from, is where the replay's work is done. Keep this output: it is the record of today's values, which is what
--        to put back if the jobs are moved for the day. (October: DAAS_PROD_IT_WHSRCTORAW_COMPUTE for merge check,
--        merge, recalculation and the summaries.) LONG_RUNNING_JOB_THRESHOLD is in minutes: batch control compares it
--        with a batch's running time for the groups in ALERTING_GROUP, so expect the ratings step and the merge to
--        show up as long-running during the replay.
SELECT JOB_ID, JOB_NAME, STORED_PROCEDURE_NAME, WAREHOUSE_NAME, LONG_RUNNING_JOB_THRESHOLD, ALERTING_GROUP
FROM DAAS_PROD.DAAS_COMMON.JOB
WHERE JOB_NAME LIKE 'TRIP%'
ORDER BY JOB_NAME;

-- R0c-2. How big those warehouses are (run the two statements together; a warehouse the role holds no privilege on is
--        simply not listed). UAT's job warehouse is included because the week test's timings were measured on it
--        (18 minutes of merge for 8,880 trips): the two sizes side by side say how far that number carries over.
SHOW WAREHOUSES LIKE 'DAAS%';
SELECT "name", "size", "state"
FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()))
WHERE "name" IN (SELECT WAREHOUSE_NAME FROM DAAS_PROD.DAAS_COMMON.JOB WHERE JOB_NAME LIKE 'TRIP%')
   OR "name" IN (SELECT WAREHOUSE_NAME FROM DAAS_UAT.DAAS_COMMON.JOB WHERE JOB_NAME LIKE 'TRIP%')
   OR "name" IN ('DAAS_PROD_IT_SNFK_COMPUTE', 'DAAS_PROD_ADHOC_BULK_LOAD_COMPUTE_XL')
ORDER BY "name";

-- R0c-3. The 20 tasks of the hourly chain (run the two statements together). Expect 20 rows, "state" = started on each,
--        the root on its :15 Pacific schedule. The schema holds some 50 other trip tasks (on-demand, initial-load and
--        one-off fix tasks); they are suspended, are not part of the chain, and are left out here.
--        11 Nov: 20 of 20 started, each child after the predecessor the pipeline source shows.
SHOW TASKS LIKE '%TRIP%' IN SCHEMA DAAS_PROD.DAAS_COMMON;
SELECT "name", "state", "warehouse", "schedule", "predecessors"
FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()))
WHERE "name" IN ('TRIP_ROOT_TASK',
                 'CORE2CORE_TRIP_FILTERED_TXNS_TASK',
                 'CORE2CORE_TRIP_RATING_DOMAIN_PIPELINE_TASK',
                 'CORE2CORE_TRIP_HOTEL_DOMAIN_PIPELINE_TASK',
                 'CORE2CORE_TRIP_POS_DOMAIN_PIPELINE_TASK',
                 'CORE2CORE_TRIP_OFFER_DOMAIN_PIPELINE_TASK',
                 'CORE2CORE_TRIP_COMP_DOMAIN_PIPELINE_TASK',
                 'CORE2CORE_TRIP_MARKERS_DOMAIN_PIPELINE_TASK',
                 'CORE2CORE_TRIP_FREEPLAY_DOMAIN_PIPELINE_TASK',
                 'CORE2CORE_TRIP_RECALCULATION_TASK',
                 'CORE2CORE_TRIP_MERGE_CHECK_TASK',
                 'CORE2CORE_TRIP_MERGE_TASK',
                 'CORE2CORE_TRIP_CUSTOMER_MERGE_CHECK_GUEST_GUESTXREF_TASK',
                 'CORE2CORE_TRIP_CUSTOMER_MERGE_CHECK_TRIP_MASTER_TASK',
                 'CORE2CORE_TRIP_CUSTOMER_MERGE_TASK',
                 'CORE2CORE_TRIP_SUMMARY_POS_TENDER_LOAD_TASK',
                 'CORE2CORE_TRIP_SUMMARY_LOAD_TASK',
                 'CORE2CORE_TRIP_COMP_WORTH_LOAD_TASK',
                 'CORE2CORE_TRIP_INACTIVE_TXNS_ARCHIVAL_TASK',
                 'CORE2CORE_TRIP_NG_REVENUE_SUMMARY_LOAD_TASK')
ORDER BY "name";

-- R0c-4. The time limit on each step the replay passes through, read from the task definitions. A step that runs past
--        its limit is cancelled by Snowflake. On file: 2 hours for the ratings step, merge check, merge, customer merge
--        and non-gaming revenue; 4 for the summary load; none set on comp worth (blank here = not set on the task, so
--        the level above it or Snowflake's one-hour default applies). If the role cannot read a task's definition this
--        fails with 'does not exist or not authorized'; the numbers above then stand as of the definitions on file.
--        One more limit sits on the warehouse: where STATEMENT_TIMEOUT_IN_SECONDS is also set, the lower of the two
--        applies (SHOW PARAMETERS LIKE 'STATEMENT_TIMEOUT_IN_SECONDS' IN WAREHOUSE <the name from R0c-1>).
--        11 Nov: 2.0 hours on the root, ratings step, merge check, merge, customer merge and non-gaming revenue; 4.0 on
--        the summary load; comp worth blank. For comp worth's effective value: SHOW PARAMETERS LIKE
--        'USER_TASK_TIMEOUT_MS' IN TASK DAAS_PROD.DAAS_COMMON.CORE2CORE_TRIP_COMP_WORTH_LOAD_TASK ("value" is
--        milliseconds; a blank "level" means Snowflake's default of 3600000, one hour).
WITH defs AS (
    SELECT 1 AS step, 'TRIP_ROOT_TASK' AS task,
           GET_DDL('TASK', 'DAAS_PROD.DAAS_COMMON.TRIP_ROOT_TASK') AS ddl
    UNION ALL
    SELECT 2, 'CORE2CORE_TRIP_RATING_DOMAIN_PIPELINE_TASK',
           GET_DDL('TASK', 'DAAS_PROD.DAAS_COMMON.CORE2CORE_TRIP_RATING_DOMAIN_PIPELINE_TASK')
    UNION ALL
    SELECT 3, 'CORE2CORE_TRIP_MERGE_CHECK_TASK',
           GET_DDL('TASK', 'DAAS_PROD.DAAS_COMMON.CORE2CORE_TRIP_MERGE_CHECK_TASK')
    UNION ALL
    SELECT 4, 'CORE2CORE_TRIP_MERGE_TASK',
           GET_DDL('TASK', 'DAAS_PROD.DAAS_COMMON.CORE2CORE_TRIP_MERGE_TASK')
    UNION ALL
    SELECT 5, 'CORE2CORE_TRIP_CUSTOMER_MERGE_TASK',
           GET_DDL('TASK', 'DAAS_PROD.DAAS_COMMON.CORE2CORE_TRIP_CUSTOMER_MERGE_TASK')
    UNION ALL
    SELECT 6, 'CORE2CORE_TRIP_SUMMARY_LOAD_TASK',
           GET_DDL('TASK', 'DAAS_PROD.DAAS_COMMON.CORE2CORE_TRIP_SUMMARY_LOAD_TASK')
    UNION ALL
    SELECT 7, 'CORE2CORE_TRIP_COMP_WORTH_LOAD_TASK',
           GET_DDL('TASK', 'DAAS_PROD.DAAS_COMMON.CORE2CORE_TRIP_COMP_WORTH_LOAD_TASK')
    UNION ALL
    SELECT 8, 'CORE2CORE_TRIP_NG_REVENUE_SUMMARY_LOAD_TASK',
           GET_DDL('TASK', 'DAAS_PROD.DAAS_COMMON.CORE2CORE_TRIP_NG_REVENUE_SUMMARY_LOAD_TASK')
)
SELECT step, task,
       REGEXP_SUBSTR(ddl, 'warehouse *= *([A-Za-z0-9_]+)', 1, 1, 'ie', 1)                                         AS warehouse_the_task_starts_on,
       ROUND(TRY_TO_NUMBER(REGEXP_SUBSTR(ddl, 'USER_TASK_TIMEOUT_MS *= *([0-9]+)', 1, 1, 'ie', 1)) / 3600000, 1) AS time_limit_hours
FROM defs
ORDER BY step;


-- R0d. How many passes will the merge make? Read-only; the first statement takes a few minutes on Large and builds a
--      TEMPORARY table (it lives only in this worksheet's session and leaves nothing behind; if the session has
--      been idle and the later statements say the table does not exist, run R0d-1 again).
--
--      Why this number. The merge rebuilds the nominated trips in a loop (TRIP_FIND_START_DATE_END_DATE_PROC). Each
--      pass takes, for every guest at once, each unbroken run of play days among the nominated trips and maps the first
--      cap-days of it (1 day at BEM, 3 at WLM); the rest of the run waits for the next pass. A 5-day BEM trip is done
--      in 5 passes; a guest who played 300 days in a row at BEM, cut into 30-day trips at the time, needs 300, long
--      after every other guest is finished. So the loop's length is set by the longest run of any one guest, not by
--      how many trips are replayed, and three things follow: (1) it can be read off PROD's data before anything runs,
--      which is what this does; (2) a bigger warehouse shortens the early passes, when every guest is still in the
--      loop, not the long tail of small ones; (3) a random canary will almost certainly not contain the guests who
--      set the count, so it cannot measure it.
--      11 Nov: 587 passes (BEM 587, WLM 93); 58,972 guests, 1,118,281 guest-days, 13,411,918 transaction rows. Still in
--      the loop after 10 passes 558 guests, after 30 passes 68, after 100 four, after 200 one. Guard 0. The week test's
--      guests (R0d-4): 98 passes, 498,425 rows, which its merge re-cut in 18 minutes. Hence the split in R3.
--
-- R0d-1. One row per guest, market and business day among what the merge will load for the target trips (every OPENED
--        transaction of each, as the merge reads them), with the run of consecutive days it belongs to and the pass in
--        which the loop will map it. Cap and gap come from the pipeline's own config function, per day, as in the loop.
CREATE OR REPLACE TEMPORARY TABLE DAAS_PROD.DAAS_TEMP_WORK.DAASI_3641_P14_PASSES AS
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
targets AS (   -- R3's own targets
    SELECT m.TRIP_MASTER_ID, m.GUEST_UNIQUE_ID, m.MARKET_CD
    FROM multi m
    JOIN caps c ON c.MARKET_CD = m.MARKET_CD AND c.TRIP_START_DT = m.TRIP_START_DT
    CROSS JOIN ent e
    WHERE m.TRIP_DAYS > COALESCE(TRY_TO_NUMBER(c.CAP), TRY_TO_NUMBER(e.MAX_TRIP_DAYS))
      AND NOT EXISTS (SELECT 1 FROM DAAS_PROD.DAAS_CORE.TRIP_DETAIL d
                      WHERE d.TRIP_MASTER_ID = m.TRIP_MASTER_ID AND d.DELETE_IND = 'N' AND d.TRANSACTION_TYPE = 'HOTEL')
),
days AS (      -- what the merge loads for them, by business day
    SELECT t.GUEST_UNIQUE_ID, t.MARKET_CD, d.BUSINESS_START_DT AS PLAY_DT, COUNT(*) AS DETAIL_ROWS
    FROM targets t
    JOIN DAAS_PROD.DAAS_CORE.TRIP_DETAIL d ON d.TRIP_MASTER_ID = t.TRIP_MASTER_ID
    WHERE d.TRANSACTION_SUB_TYPE = 'OPENED'
    GROUP BY 1, 2, 3
),
cfg AS (       -- the cap and the gap in force on each day, from the function the loop itself calls
    SELECT MARKET_CD, PLAY_DT,
           TRY_TO_NUMBER(DAAS_PROD.DAAS_COMMON.TRIP_CONFIG_UDF_MARKET('MAX_TRIP_DAYS', MARKET_CD, PLAY_DT)) AS CAP,
           TRY_TO_NUMBER(DAAS_PROD.DAAS_COMMON.TRIP_CONFIG_UDF_MARKET('TRIP_GAP_DAYS', MARKET_CD, PLAY_DT)) AS GAP
    FROM (SELECT DISTINCT MARKET_CD, PLAY_DT FROM days)
),
edges AS (     -- a new run starts where a day is more than gap-days after the guest's previous day
    SELECT x.GUEST_UNIQUE_ID, x.MARKET_CD, x.PLAY_DT, x.DETAIL_ROWS, c.CAP, c.GAP,
           IFF(DATEDIFF(day, LAG(x.PLAY_DT) OVER (PARTITION BY x.GUEST_UNIQUE_ID, x.MARKET_CD ORDER BY x.PLAY_DT), x.PLAY_DT) <= c.GAP,
               0, 1) AS STARTS_A_RUN
    FROM days x
    JOIN cfg c ON c.MARKET_CD = x.MARKET_CD AND c.PLAY_DT = x.PLAY_DT
),
numbered AS (
    SELECT e.*,
           SUM(e.STARTS_A_RUN) OVER (PARTITION BY e.GUEST_UNIQUE_ID, e.MARKET_CD ORDER BY e.PLAY_DT
                                     ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS RUN_NO
    FROM edges e
),
placed AS (
    SELECT n.*,
           MIN(n.PLAY_DT) OVER (PARTITION BY n.GUEST_UNIQUE_ID, n.MARKET_CD, n.RUN_NO) AS RUN_START_DT
    FROM numbered n
)
SELECT GUEST_UNIQUE_ID, MARKET_CD, RUN_NO, RUN_START_DT, PLAY_DT, DETAIL_ROWS, CAP, GAP,
       DATEDIFF(day, RUN_START_DT, PLAY_DT) + 1               AS DAY_IN_RUN,
       CEIL((DATEDIFF(day, RUN_START_DT, PLAY_DT) + 1) / CAP) AS PASS_NO   /* the pass that maps this day */
FROM placed;

-- R0d-2. The forecast. The right-hand columns are the same on every row: the number of passes the loop will make (and
--        per market), the longest run in days, and a guard: guest_days_with_no_cap_LOOK must be 0 (a day the config
--        does not cover would never map, and the loop would not end). The left-hand columns are the loop's profile:
--        after each number of passes, how many guests, guest-days and transaction rows are still waiting. Row 0 is
--        everything the merge loads for the targets. A profile that empties in a few passes with a long thin tail is
--        the case described above.
WITH headline AS (
    SELECT MAX(PASS_NO)                               AS passes_the_merge_will_make,
           MAX(IFF(MARKET_CD = 'BEM', PASS_NO, NULL)) AS bem_passes,
           MAX(IFF(MARKET_CD = 'WLM', PASS_NO, NULL)) AS wlm_passes,
           MAX(DAY_IN_RUN)                            AS longest_run_days,
           COUNT_IF(CAP IS NULL)                      AS guest_days_with_no_cap_LOOK
    FROM DAAS_PROD.DAAS_TEMP_WORK.DAASI_3641_P14_PASSES
),
marks AS (
    SELECT column1 AS after_pass
    FROM VALUES (0), (1), (2), (3), (5), (10), (15), (30), (60), (100), (200), (400), (800), (1600)
)
SELECT k.after_pass,
       COUNT(DISTINCT IFF(p.PASS_NO > k.after_pass, p.GUEST_UNIQUE_ID, NULL)) AS guests_still_in_the_loop,
       COUNT_IF(p.PASS_NO > k.after_pass)                                      AS guest_days_still_to_map,
       COALESCE(SUM(IFF(p.PASS_NO > k.after_pass, p.DETAIL_ROWS, 0)), 0)       AS transaction_rows_still_to_map,
       h.passes_the_merge_will_make, h.bem_passes, h.wlm_passes, h.longest_run_days, h.guest_days_with_no_cap_LOOK
FROM marks k
CROSS JOIN DAAS_PROD.DAAS_TEMP_WORK.DAASI_3641_P14_PASSES p
CROSS JOIN headline h
GROUP BY k.after_pass, h.passes_the_merge_will_make, h.bem_passes, h.wlm_passes, h.longest_run_days, h.guest_days_with_no_cap_LOOK
ORDER BY k.after_pass;

-- R0d-3. The runs that set the count: the 20 longest, with the guest, the market, the dates and the passes each needs.
SELECT GUEST_UNIQUE_ID, MARKET_CD, RUN_START_DT, MAX(PLAY_DT) AS run_end_dt, MAX(DAY_IN_RUN) AS run_days,
       MAX(PASS_NO) AS passes, SUM(DETAIL_ROWS) AS transaction_rows
FROM DAAS_PROD.DAAS_TEMP_WORK.DAASI_3641_P14_PASSES
GROUP BY GUEST_UNIQUE_ID, MARKET_CD, RUN_NO, RUN_START_DT
ORDER BY passes DESC, transaction_rows DESC
LIMIT 20;

-- R0d-4. The yardstick (optional; needs the week test's guest list, still in UAT's scratch schema). The week test's
--        batch 1 re-cut the 34 exposure guests' trips in 18 minutes of merge on a Large warehouse, the same size as
--        PROD's. The passes that run needed, counted the same way on the same guests' PROD trips: 18 minutes divided by
--        this number is UAT's time per pass on a small working set, the floor for a pass in PROD.
SELECT COUNT(DISTINCT GUEST_UNIQUE_ID) AS week_test_guests_found,
       MAX(PASS_NO)                    AS passes_their_recut_needed,
       COUNT(*)                        AS guest_days,
       SUM(DETAIL_ROWS)                AS transaction_rows
FROM DAAS_PROD.DAAS_TEMP_WORK.DAASI_3641_P14_PASSES
WHERE GUEST_UNIQUE_ID IN (SELECT GUEST_UNIQUE_ID FROM DAAS_UAT.DAAS_TEMP_WORK.DAASI_3641_WT_POP WHERE GRP = 'EXPOSURE');


-- R0e. The longest runs on record of the steps that grow with a replay, and how their batches have ended. Read-only.
--      The April and August replays put tens of millions of replayed ratings through the ratings step: their batches
--      are the precedent for R3's ratings step (about 12 million rows in one run), and a batch that never reached
--      SUCCESS or FAILURE is what a step cut off at its time limit leaves behind.
SELECT j.JOB_NAME, b.BATCH_ID, b.BATCH_STATUS, b.BATCH_START_DATE,
       ROUND(DATEDIFF(second, b.BATCH_START_DATE, COALESCE(b.BATCH_END_DATE, b.UPDATED_DTTM)) / 60, 1) AS minutes
FROM DAAS_PROD.DAAS_COMMON.BATCH_S02 b
JOIN DAAS_PROD.DAAS_COMMON.JOB j ON j.JOB_ID = b.JOB_ID
WHERE j.JOB_NAME IN ('TRIP_RATING_DOMAIN_PIPELINE', 'TRIP_MERGE_CHECK', 'TRIP_MERGE', 'TRIP_SUMMARY_WRAPPER')
QUALIFY ROW_NUMBER() OVER (PARTITION BY j.JOB_NAME
                           ORDER BY DATEDIFF(second, b.BATCH_START_DATE, COALESCE(b.BATCH_END_DATE, b.UPDATED_DTTM)) DESC) <= 6
ORDER BY j.JOB_NAME, minutes DESC;

SELECT j.JOB_NAME, b.BATCH_STATUS, COUNT(*) AS batches, MIN(b.BATCH_START_DATE) AS first_one, MAX(b.BATCH_START_DATE) AS last_one
FROM DAAS_PROD.DAAS_COMMON.BATCH_S02 b
JOIN DAAS_PROD.DAAS_COMMON.JOB j ON j.JOB_ID = b.JOB_ID
WHERE j.JOB_NAME IN ('TRIP_RATING_DOMAIN_PIPELINE', 'TRIP_MERGE_CHECK', 'TRIP_MERGE', 'TRIP_SUMMARY_WRAPPER')
  AND b.BATCH_START_DATE >= DATEADD(day, -400, CURRENT_TIMESTAMP())
GROUP BY j.JOB_NAME, b.BATCH_STATUS
ORDER BY j.JOB_NAME, b.BATCH_STATUS;


-- R1. The targets and the before-pictures. Scratch tables in DAAS_TEMP_WORK. Build them once, before the first UPDATE,
--     and do not rebuild them between runs: they are what the post-check compares every run against.
--     _P14_TRIPS       one row per target trip (live BEM/WLM market trip, over its cap, no hotel night) with its batch,
--                      its run and the passes the merge needs for it
--     _P14_TM_BEFORE   every live trip of the target guests at every grain — the guests' whole footprint, which is what
--                      the runs can touch (targets, their twins and enterprise trips, and any neighbour the join rule pairs)
--     _P14_TD_BEFORE   the live TRIP_DETAIL rows of those trips (the ratings R3 replays; the SK-level evidence for the post-check)
--     _P14_TS_BEFORE   their TRIP_SUMMARY rows (theo before)
--     _P14_OTHER       the guests' other over-cap no-stay trips (property and enterprise grains, other markets): what v1.4
--                      will also re-cut when a replayed rating lands on them (R2b reads it)
--     _P14_MARKS       the highest trip id, detail id and batch id before the run: everything the runs build sits above them
--     Same measure as the reach check and as v1.4 itself: TRIP_END_DT - TRIP_START_DT + 1 > cap, cap from the config
--     function for the trip's start date, the enterprise cap as the fallback, trips holding a live HOTEL detail row exempt.
--     Batches, by the very logic the R3 statements carry, so the before-picture and the UPDATEs cannot disagree:
--       3  the long-run guests: a run of theirs would take the merge's loop more than 30 passes (R3-L, then R3-Z;
--          LEFT_FOR_R3Z marks the trips the second of the two replays)
--       1  the canary: one guest in a hundred of the rest, by hash (R3-C)
--       2  everyone else (R3)
--     Minutes on Large (TD_BEFORE is the big one).
CREATE OR REPLACE TABLE DAAS_PROD.DAAS_TEMP_WORK.DAASI_3641_P14_TRIPS AS
WITH ent AS (
    SELECT MAX(VALUE) AS MAX_TRIP_DAYS
    FROM DAAS_PROD.DAAS_CORE.TRIP_CONFIG
    WHERE CONFIG_SUBTYPE = 'ENTERPRISE' AND KEY = 'MAX_TRIP_DAYS' AND ACTIVE_FLG = 'Y'
),
multi AS (
    SELECT TRIP_MASTER_ID, GUEST_UNIQUE_ID, MARKET_CD, TRIP_START_DT, TRIP_END_DT, UPDATED_DTTM, TRIP_END_DT - TRIP_START_DT + 1 AS TRIP_DAYS
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
    SELECT m.TRIP_MASTER_ID, m.GUEST_UNIQUE_ID, m.MARKET_CD, m.TRIP_START_DT, m.TRIP_END_DT, m.UPDATED_DTTM, m.TRIP_DAYS,
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
),
ratings AS (    /* the live ratings each target holds: what the UPDATEs replay */
    SELECT d.TRIP_MASTER_ID, COUNT(DISTINCT d.TRANSACTION_TABLE_SK) AS RATING_ROWS
    FROM DAAS_PROD.DAAS_CORE.TRIP_DETAIL d
    JOIN targets o ON o.TRIP_MASTER_ID = d.TRIP_MASTER_ID
    WHERE d.TRANSACTION_TABLE = 'RATINGS_FACT' AND d.DELETE_IND = 'N' AND d.TRANSACTION_SUB_TYPE = 'OPENED'
    GROUP BY d.TRIP_MASTER_ID
)
SELECT o.TRIP_MASTER_ID, o.GUEST_UNIQUE_ID, o.MARKET_CD, o.TRIP_START_DT, o.TRIP_END_DT, o.TRIP_DAYS,
       o.CAP                      AS MAX_TRIP_DAYS,
       o.UPDATED_DTTM             AS UPDATED_DTTM_BEFORE,
       COALESCE(r.RATING_ROWS, 0) AS RATING_ROWS,
       CASE WHEN o.GUEST_PASSES > 30                           THEN 3   /* a long-run guest: R3-L, then R3-Z */
            WHEN MOD(ABS(HASH(o.GUEST_UNIQUE_ID)), 100) = 0    THEN 1   /* the canary: R3-C */
            ELSE 2 END            AS BATCH_NO,                          /* everyone else: R3 */
       o.RUN_NO, o.PLACE_IN_RUN, o.RUN_PASSES, o.GUEST_PASSES,
       (o.GUEST_PASSES > 30 AND o.RUN_PASSES > 30 AND o.RUN_CAP = 1 AND MOD(o.PLACE_IN_RUN, 2) = 0) AS LEFT_FOR_R3Z,
       IFF(o.GUEST_PASSES > 30 AND o.RUN_PASSES > 30 AND o.RUN_CAP = 1,
           CEIL(o.TRIP_DAYS / o.CAP), o.RUN_PASSES)                                                 AS PASSES_AS_REPLAYED
FROM picked o
LEFT JOIN ratings r ON r.TRIP_MASTER_ID = o.TRIP_MASTER_ID;

CREATE OR REPLACE TABLE DAAS_PROD.DAAS_TEMP_WORK.DAASI_3641_P14_TM_BEFORE AS
SELECT m.*, g.BATCH_NO
FROM DAAS_PROD.DAAS_CORE.TRIP_MASTER m
JOIN (SELECT GUEST_UNIQUE_ID, MIN(BATCH_NO) AS BATCH_NO FROM DAAS_PROD.DAAS_TEMP_WORK.DAASI_3641_P14_TRIPS GROUP BY 1) g
  ON g.GUEST_UNIQUE_ID = m.GUEST_UNIQUE_ID
WHERE m.DELETE_IND = 'N';

CREATE OR REPLACE TABLE DAAS_PROD.DAAS_TEMP_WORK.DAASI_3641_P14_TD_BEFORE AS
SELECT d.*
FROM DAAS_PROD.DAAS_CORE.TRIP_DETAIL d
JOIN DAAS_PROD.DAAS_TEMP_WORK.DAASI_3641_P14_TM_BEFORE t ON t.TRIP_MASTER_ID = d.TRIP_MASTER_ID
WHERE d.DELETE_IND = 'N';

CREATE OR REPLACE TABLE DAAS_PROD.DAAS_TEMP_WORK.DAASI_3641_P14_TS_BEFORE AS
SELECT s.*
FROM DAAS_PROD.DAAS_CORE.TRIP_SUMMARY s
JOIN DAAS_PROD.DAAS_TEMP_WORK.DAASI_3641_P14_TM_BEFORE t ON t.TRIP_MASTER_ID = s.TRIP_MASTER_ID;

CREATE OR REPLACE TABLE DAAS_PROD.DAAS_TEMP_WORK.DAASI_3641_P14_OTHER AS
WITH ent AS (
    SELECT MAX(VALUE) AS MAX_TRIP_DAYS
    FROM DAAS_PROD.DAAS_CORE.TRIP_CONFIG
    WHERE CONFIG_SUBTYPE = 'ENTERPRISE' AND KEY = 'MAX_TRIP_DAYS' AND ACTIVE_FLG = 'Y'
),
multi AS (
    SELECT m.TRIP_MASTER_ID, m.GUEST_UNIQUE_ID, m.TRIP_TYPE, m.PROPERTY_CD, m.MARKET_CD, m.TRIP_START_DT, m.TRIP_END_DT, m.BATCH_NO,
           m.TRIP_END_DT - m.TRIP_START_DT + 1 AS TRIP_DAYS
    FROM DAAS_PROD.DAAS_TEMP_WORK.DAASI_3641_P14_TM_BEFORE m
    WHERE m.TRIP_END_DT > m.TRIP_START_DT
      AND NOT (m.TRIP_TYPE = 'MARKET' AND m.MARKET_CD IN ('BEM', 'WLM'))
),
caps AS (
    SELECT TRIP_TYPE, PROPERTY_CD, MARKET_CD, TRIP_START_DT,
           CASE WHEN TRIP_TYPE = 'PROPERTY' THEN DAAS_PROD.DAAS_COMMON.TRIP_CONFIG_UDF_PROPERTY('MAX_TRIP_DAYS', PROPERTY_CD, TRIP_START_DT)
                WHEN TRIP_TYPE = 'MARKET'   THEN DAAS_PROD.DAAS_COMMON.TRIP_CONFIG_UDF_MARKET('MAX_TRIP_DAYS', MARKET_CD, TRIP_START_DT)
           END AS CAP
    FROM (SELECT DISTINCT TRIP_TYPE, PROPERTY_CD, MARKET_CD, TRIP_START_DT FROM multi)
),
hotel AS (
    SELECT DISTINCT TRIP_MASTER_ID FROM DAAS_PROD.DAAS_TEMP_WORK.DAASI_3641_P14_TD_BEFORE WHERE TRANSACTION_TYPE = 'HOTEL'
)
SELECT m.*, COALESCE(TRY_TO_NUMBER(c.CAP), TRY_TO_NUMBER(e.MAX_TRIP_DAYS)) AS MAX_TRIP_DAYS,
       CASE m.TRIP_TYPE WHEN 'PROPERTY' THEN m.PROPERTY_CD WHEN 'MARKET' THEN m.MARKET_CD ELSE 'ENTERPRISE' END AS CODE
FROM multi m
JOIN caps c
  ON c.TRIP_TYPE = m.TRIP_TYPE AND EQUAL_NULL(c.PROPERTY_CD, m.PROPERTY_CD)
 AND EQUAL_NULL(c.MARKET_CD, m.MARKET_CD) AND c.TRIP_START_DT = m.TRIP_START_DT
CROSS JOIN ent e
LEFT JOIN hotel h ON h.TRIP_MASTER_ID = m.TRIP_MASTER_ID
WHERE m.TRIP_DAYS > COALESCE(TRY_TO_NUMBER(c.CAP), TRY_TO_NUMBER(e.MAX_TRIP_DAYS))
  AND h.TRIP_MASTER_ID IS NULL;

CREATE OR REPLACE TABLE DAAS_PROD.DAAS_TEMP_WORK.DAASI_3641_P14_MARKS (
    mark VARCHAR, value NUMBER, noted_at TIMESTAMP_LTZ DEFAULT CURRENT_TIMESTAMP());
INSERT INTO DAAS_PROD.DAAS_TEMP_WORK.DAASI_3641_P14_MARKS (mark, value)
SELECT 'max_trip_master_id_before', MAX(TRIP_MASTER_ID) FROM DAAS_PROD.DAAS_CORE.TRIP_MASTER;
INSERT INTO DAAS_PROD.DAAS_TEMP_WORK.DAASI_3641_P14_MARKS (mark, value)
SELECT 'max_batch_id_before', MAX(BATCH_ID) FROM DAAS_PROD.DAAS_COMMON.BATCH_S02;
INSERT INTO DAAS_PROD.DAAS_TEMP_WORK.DAASI_3641_P14_MARKS (mark, value)
SELECT 'max_trip_detail_id_before', MAX(TRIP_DETAIL_ID) FROM DAAS_PROD.DAAS_CORE.TRIP_DETAIL;

-- R2. Preview of the before-picture by batch: the trips the R3 statements will find. Expect trips, guests and
--     rating_rows_to_replay on the 'all' row to agree with R0b. most_passes_the_merge_needs is the loop's length for
--     each statement: 30 or less for batches 1 and 2; for 3a and 3b about the longest single trip, or WLM's longest run
--     (replayed whole: 93 by day on 11 Nov). most_passes_if_replayed_whole is what one unrestricted UPDATE would need
--     (587 by day on 11 Nov). These are counted from the trips' dates, R0d from the transactions' days: these can only
--     be equal or higher, so a guest R0d would keep in the main group may sit in batch 3 here, never the other way.
SELECT CASE WHEN BATCH_NO IS NULL THEN 'all'
            WHEN BATCH_NO = 1 THEN '1  the canary (R3-C)'
            WHEN BATCH_NO = 2 THEN '2  everyone else (R3)'
            WHEN LEFT_FOR_R3Z THEN '3b long-run guests, the trips left for R3-Z'
            ELSE                   '3a long-run guests, the trips R3-L replays' END AS batch,
       COUNT(*)                                  AS trips,
       COUNT_IF(RATING_ROWS > 0)                 AS trips_the_replay_reaches,
       COUNT_IF(RATING_ROWS = 0)                 AS trips_with_no_live_rating,
       COUNT(DISTINCT GUEST_UNIQUE_ID)           AS guests,
       COUNT_IF(MARKET_CD = 'BEM')               AS bem_trips,
       COUNT_IF(MARKET_CD = 'WLM')               AS wlm_trips,
       SUM(RATING_ROWS)                          AS rating_rows_to_replay,
       MAX(PASSES_AS_REPLAYED)                   AS most_passes_the_merge_needs,
       MAX(RUN_PASSES)                           AS most_passes_if_replayed_whole,
       MAX(TRIP_DAYS)                            AS longest_days
FROM DAAS_PROD.DAAS_TEMP_WORK.DAASI_3641_P14_TRIPS
GROUP BY GROUPING SETS ((BATCH_NO, LEFT_FOR_R3Z), ())
ORDER BY 1;

-- R2b. What else the runs will re-cut: the target guests' other live trips (property and enterprise grains, other
--      markets) that are over their cap with no hotel night today. The ratings step rewrites every master holding a
--      replayed rating, and v1.4 applies the same rule to each. Expect the IBE/IWA property rows at 0 (the twins were
--      corrected earlier); the ENTERPRISE row is the one to read before sign-off. For Pete's record either way.
SELECT TRIP_TYPE, CODE, MAX_TRIP_DAYS,
       COUNT(*)                        AS over_cap_trips,
       COUNT(DISTINCT GUEST_UNIQUE_ID) AS guests,
       MAX(TRIP_DAYS)                  AS longest_days,
       MIN(BATCH_NO)                   AS first_batch,
       MAX(BATCH_NO)                   AS last_batch
FROM DAAS_PROD.DAAS_TEMP_WORK.DAASI_3641_P14_OTHER
GROUP BY ALL
ORDER BY over_cap_trips DESC;

-- R2c. The targets a ratings replay cannot reach (no live rating): what they hold instead, and how old they are. They
--      stay as they are through the replay; what to do with them is a separate decision after it (a direct nomination
--      into TRIP_MERGE_QUEUE is possible, but a trip with nothing to re-window needs a look first).
SELECT t.MARKET_CD,
       COUNT(DISTINCT t.TRIP_MASTER_ID)                                     AS trips_with_no_live_rating,
       COUNT(DISTINCT t.GUEST_UNIQUE_ID)                                    AS guests,
       COUNT(DISTINCT IFF(d.TRIP_MASTER_ID IS NULL, t.TRIP_MASTER_ID, NULL)) AS of_them_with_no_live_transaction_at_all,
       LISTAGG(DISTINCT d.TRANSACTION_TYPE, ', ') WITHIN GROUP (ORDER BY d.TRANSACTION_TYPE) AS transaction_types_they_hold,
       MIN(t.TRIP_START_DT) AS earliest_start, MAX(t.TRIP_END_DT) AS latest_end
FROM DAAS_PROD.DAAS_TEMP_WORK.DAASI_3641_P14_TRIPS t
LEFT JOIN DAAS_PROD.DAAS_TEMP_WORK.DAASI_3641_P14_TD_BEFORE d ON d.TRIP_MASTER_ID = t.TRIP_MASTER_ID
WHERE t.RATING_ROWS = 0
GROUP BY 1
ORDER BY 1;


-- R4a. Just before R3 (and before the deploy): is a trip run in progress? Expect no rows. The root task fires at :15; a
--      run usually ends well before the next one, so the clean moment is right after the last job of a run has finished.
SELECT j.JOB_NAME, b.BATCH_ID, b.BATCH_STATUS, b.BATCH_START_DATE, b.UPDATED_DTTM
FROM DAAS_PROD.DAAS_COMMON.BATCH_S02 b
JOIN DAAS_PROD.DAAS_COMMON.JOB j ON j.JOB_ID = b.JOB_ID
WHERE j.JOB_NAME LIKE 'TRIP%'
  AND b.BATCH_STATUS NOT IN ('SUCCESS', 'FAILURE')
  AND b.BATCH_START_DATE >= DATEADD(hour, -3, CURRENT_TIMESTAMP())
ORDER BY b.BATCH_ID;


-- R3. THE WRITES. Each statement is self-contained: it reads nothing but PROD's own tables. The three grouped
--     statements share one piece of logic, word for word, which is also what R1 used for its batches: the live BEM/WLM
--     market trips over their cap with no hotel night (the same measure as R0b and v1.4 itself), strung into runs (a
--     guest's target trips in a market that follow one another without a break), with the passes the merge's loop
--     needs for each run (R0d). A guest whose longest run needs more than 30 passes is a long-run guest.
--       R3-C  optional, first: the canary. One guest in a hundred of the main group. If it is skipped, R3 covers them.
--       R3    the main replay: everyone except the long-run guests. No run needs more than 30 passes.
--       R3-L  the long-run guests, first step: everything of theirs except every second trip of a long run at a
--             one-day cap. A long BEM run is a string of adjacent trips cut at the old 30-day cap. Replayed together
--             they are one run of hundreds of days for the loop; replayed as every other trip, each is on its own and
--             needs at most its own length in passes. At a one-day cap the result is the same either way, because
--             every play day becomes its own trip whichever trips it arrives with (checked against a re-implementation
--             of the loop: 300 runs, 0 differences). At WLM's three-day cap it is not the same, so a WLM run is never
--             split: it is replayed whole (the longest needs 93 passes).
--       R3-Z  an hour after R3-L: the statement as first written, with no grouping. It replays whatever is still over
--             its cap, which by then is the trips R3-L left.
--     What each does to a row: the platform's replay pattern (REPLAY_COUNTER up by one, UPDATED_DTTM and UPDATED_BY
--     stamped; the pipeline's own rating step copies UPDATED_DTTM into TRIP_DETAIL.TRANSACTION_MODIFIED_DTTM, as on any
--     replay). Only ratings are replayed: the merge step re-windows everything a nominated trip holds — offers, comps,
--     POS, cage, free play alike — from TRIP_DETAIL (week test, 847,653 transaction-nights, 0 lost, 0 doubled), so one
--     transaction type is enough to touch the trip, and ratings are the one every reachable target holds.
--     Each UPDATE goes right after an hourly run has finished (R4a); the next run does the rest. R3b and R4b after
--     each, then the post-check. When all are done, R0b is the closing check: trips_the_replay_reaches at 0.

-- R3-0. Read-only: what each statement would update now, counted by the statements' own logic. The rating_rows of the
--       four lines add up to R0b's ratings_fact_rows_to_update, and each line is what its UPDATE must report as rows
--       updated (R3 reports lines 1 and 2 together if R3-C is skipped).
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

-- R3-C. The canary (optional, first): R3 with one more line. About 590 guests.
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
);

-- R3. The main replay: everyone except the long-run guests (after R3-C, everyone of them it did not take: the canary's
--     trips are no longer over their cap).
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
);

-- R3-L. The long-run guests, first step. Any time after R3.
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
);

-- R3-Z. An hour after R3-L, once its run has finished: the statement as first written. It replays whatever is still over
--       its cap: the trips R3-L left.
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
);

-- R3b. Right after each UPDATE: the stream has the rows and the root task will fire at :15. Expect TRUE and rows =
--      rows updated.
SELECT SYSTEM$STREAM_HAS_DATA('DAAS_PROD.DAAS_CORE.RATINGS_FACT_STREAM') AS ratings_stream_has_data;
SELECT COUNT(*) AS replayed_rows_waiting
FROM DAAS_PROD.DAAS_CORE.RATINGS_FACT_STREAM
WHERE METADATA$ACTION = 'INSERT' AND METADATA$ISUPDATE;


-- R4b. Watching the run: the trip jobs' batches since R1, in order. A run is done when TRIP_COMP_WORTH (and the two after
--      it) show SUCCESS. Expect every step SUCCESS; the ratings step and the merge will take longer than usual — note the
--      merge's minutes against the timeout from R0c. Then the post-check file.
SELECT j.JOB_NAME, b.BATCH_ID, b.BATCH_STATUS, b.BATCH_START_DATE, b.UPDATED_DTTM AS last_update,
       ROUND(DATEDIFF(second, b.BATCH_START_DATE, b.UPDATED_DTTM) / 60, 1) AS minutes
FROM DAAS_PROD.DAAS_COMMON.BATCH_S02 b
JOIN DAAS_PROD.DAAS_COMMON.JOB j ON j.JOB_ID = b.JOB_ID
WHERE j.JOB_NAME LIKE 'TRIP%'
  AND b.BATCH_ID > (SELECT value FROM DAAS_PROD.DAAS_TEMP_WORK.DAASI_3641_P14_MARKS WHERE mark = 'max_batch_id_before')
ORDER BY b.BATCH_ID;

-- R4c. (Only if a step shows FAILURE.) The pipeline's own error log for those batches.
SELECT j.JOB_NAME, e.*
FROM DAAS_PROD.DAAS_COMMON.BATCH_ERROR_LOG_S02 e
JOIN DAAS_PROD.DAAS_COMMON.BATCH_S02 b ON b.BATCH_ID = e.BATCH_ID
JOIN DAAS_PROD.DAAS_COMMON.JOB j ON j.JOB_ID = b.JOB_ID
WHERE e.BATCH_ID > (SELECT value FROM DAAS_PROD.DAAS_TEMP_WORK.DAASI_3641_P14_MARKS WHERE mark = 'max_batch_id_before')
ORDER BY e.BATCH_ID, e.CREATED_DTTM;

-- R4d. First look, before the post-check: per batch, how many targets are retired and how many trips the runs have built
--      for those guests. A replayed batch shows retired = its reachable targets and 0 reachable targets still live;
--      an unreplayed batch shows 0 retired. The post-check does the rest.
WITH built AS (
    SELECT g.BATCH_NO, COUNT(*) AS trips_built_for_these_guests
    FROM DAAS_PROD.DAAS_CORE.TRIP_MASTER n
    JOIN (SELECT GUEST_UNIQUE_ID, MIN(BATCH_NO) AS BATCH_NO FROM DAAS_PROD.DAAS_TEMP_WORK.DAASI_3641_P14_TRIPS GROUP BY 1) g
      ON g.GUEST_UNIQUE_ID = n.GUEST_UNIQUE_ID
    WHERE n.TRIP_MASTER_ID > (SELECT value FROM DAAS_PROD.DAAS_TEMP_WORK.DAASI_3641_P14_MARKS WHERE mark = 'max_trip_master_id_before')
    GROUP BY 1
)
SELECT t.BATCH_NO,
       COUNT(*)                                             AS targets,
       COUNT_IF(t.RATING_ROWS > 0)                          AS reachable,
       COUNT_IF(m.DELETE_IND = 'Y')                         AS retired,
       COUNT_IF(m.DELETE_IND = 'N' AND t.RATING_ROWS > 0)   AS reachable_still_live_over_cap,
       COUNT_IF(m.DELETE_IND = 'N' AND t.RATING_ROWS = 0)   AS unreachable_still_live,
       COALESCE(b.trips_built_for_these_guests, 0)          AS trips_built_for_these_guests
FROM DAAS_PROD.DAAS_TEMP_WORK.DAASI_3641_P14_TRIPS t
JOIN DAAS_PROD.DAAS_CORE.TRIP_MASTER m ON m.TRIP_MASTER_ID = t.TRIP_MASTER_ID
LEFT JOIN built b ON b.BATCH_NO = t.BATCH_NO
GROUP BY t.BATCH_NO, b.trips_built_for_these_guests
ORDER BY t.BATCH_NO;
