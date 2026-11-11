-- DAASI-3641: PROD repair through the pipeline, with TRIP_MERGE_CHECK_PROC v1.4. Two steps change anything:
-- the deploy, and one UPDATE (R3), which carries its own target logic and reads nothing but PROD's own tables.
-- Everything else here is read-only, or a scratch table the post-check needs (R1: the before-picture, which must exist
-- before R3 runs because the post-check compares against it; R3 itself does not use it).
--
-- Order
--   1. Deploy v1.4 to PROD (GitHub Actions, from main), right after an hourly run has finished (R4a shows none running).
--      Nothing changes on deploy alone: v1.4 only acts on a trip the chain touches, and the chain only touches a trip
--      when something lands on it.
--   2. R0 (the version), R0b (the size, read-only), R0c (the pipeline's warehouse and its task time limits) and R0d
--      (how many passes the merge's loop will make on this data) — together the things that decide whether the replay
--      goes in one UPDATE or two, see below — then R1 (the before-picture the post-check needs: scratch tables in
--      DAAS_TEMP_WORK, minutes on Large; not used by R3), R2 / R2b / R2c (previews, read-only).
--   3. R3, right after an hourly run has finished: the UPDATE. The next run (TRIP_ROOT_TASK, :15 past every hour,
--      Pacific) does the rest in one pass: ratings step → merge check (v1.4 nominates) → merge (re-windows) → summaries
--      → comp worth. R4b watches it.
--   4. The post-check file.
--
-- One UPDATE or two. R3 as written replays everything at once: 377,243 trips, 12.07M rating rows, one hourly run. The
-- steps that grow with the size are the ratings step (every replayed rating goes through it) and the merge, which
-- rebuilds the trips in one transaction: 8,880 trips took 18 minutes of merge in UAT on UAT's job warehouse, which
-- R0c shows is the same size as PROD's (both Large, 11 Nov), so that timing carries over like for like. The merge does
-- not scale by trip count, though: it works in passes, and the number of passes is the longest unbroken run of play
-- days of any one guest, divided by the cap (R0d explains and counts them). Whether the run fits is decided by that
-- count and by two things that belong to the pipeline, not to the session R3 is run from (that warehouse runs the
-- UPDATE and nothing after it). R0c reads both.
--   The warehouse.  Each step runs on the warehouse named on its job's row in DAAS_COMMON.JOB: the task starts on the
--                   warehouse in its own definition, then the step's procedure opens with USE WAREHOUSE on the job's
--                   WAREHOUSE_NAME. For the trip jobs that was DAAS_PROD_IT_WHSRCTORAW_COMPUTE in October. The April
--                   replay (DAASI-2958) moved the trip chain's jobs to DAAS_PROD_ADHOC_BULK_LOAD_COMPUTE_XL with one
--                   UPDATE on that table before resuming the tasks, and August did the same for its replay jobs.
--   The time limit. A step that runs past its task's USER_TASK_TIMEOUT_MS is cancelled by Snowflake: two hours on the
--                   ratings step, merge check and merge in the task definitions, four on the summary load. A cancelled
--                   step rolls back whole (the ratings step and the merge each do their data work in one transaction,
--                   so nothing is left half-done), but its stream is still waiting, so the next hourly run tries the
--                   same set again, and the steps after it do not run until it gets through.
-- Both are the architect's to set for the day and to put back (the JOB rows for the warehouse; ALTER TASK ... SET
-- USER_TASK_TIMEOUT_MS for the limit). The hourly trip pipeline also pauses for as long as the run takes (the root task
-- waits for a run to finish before it starts the next; the April and August replays paused the same way, with the
-- downstream dynamic tables suspended until done). If any of this is in doubt, run R3 twice: first with its targets
-- limited to R1's batch 1 — a canary of 500 guests, about 3,000 trips — then for everyone else (the two one-line
-- additions are in R3's comment). The canary is the first time the whole chain carries this replay end to end (UAT
-- could not run the ratings step), and it times the ratings step and a typical guest's merge inside an hour. It is a
-- random draw, so it will not contain the few guests with the longest runs: R0d is what measures those.
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
-- Roles: DAAS_TEAM for the reads and the scratch tables; R3 needs UPDATE on DAAS_PROD.DAAS_CORE.RATINGS_FACT (Pete, or
-- whoever holds it). No session variables; the scratch tables can be dropped after sign-off.

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


-- R0c. The pipeline's warehouse and time limits, read-only (see "One UPDATE or two" in the header). Four small reads.
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
--      set the count, so it cannot measure it. If the count is in the tens, one UPDATE is comfortable. If it is in the
--      hundreds, the guests in R0d-3 are the reason, and replaying them in an UPDATE of their own (a small working set,
--      many quick passes) apart from everyone else (a large working set, few passes) keeps both runs short.
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


-- R1. The targets and the before-pictures. Five scratch tables in DAAS_TEMP_WORK:
--     _P14_TRIPS       one row per target trip (live BEM/WLM market trip, over its cap, no hotel night) with its batch
--     _P14_TM_BEFORE   every live trip of the target guests at every grain — the guests' whole footprint, which is what
--                      the runs can touch (targets, their twins and enterprise trips, and any neighbour the join rule pairs)
--     _P14_TD_BEFORE   the live TRIP_DETAIL rows of those trips (the ratings R3 replays; the SK-level evidence for the post-check)
--     _P14_TS_BEFORE   their TRIP_SUMMARY rows (theo before)
--     _P14_OTHER       the guests' other over-cap no-stay trips (property and enterprise grains, other markets): what v1.4
--                      will also re-cut when a replayed rating lands on them (R2b reads it)
--     _P14_MARKS       the highest trip id, detail id and batch id before the run: everything the runs build sits above them
--     Same measure as the reach check and as v1.4 itself: TRIP_END_DT - TRIP_START_DT + 1 > cap, cap from the config
--     function for the trip's start date, the enterprise cap as the fallback, trips holding a live HOTEL detail row exempt.
--     Batches: two literals, CANARY_GUESTS (500) and GUESTS_PER_BATCH (set above the guest count, so batch 2 is everyone
--     else). Minutes on Large (TD_BEFORE is the big one).
CREATE OR REPLACE TABLE DAAS_PROD.DAAS_TEMP_WORK.DAASI_3641_P14_TRIPS AS
WITH ent AS (
    SELECT MAX(VALUE) AS MAX_TRIP_DAYS
    FROM DAAS_PROD.DAAS_CORE.TRIP_CONFIG
    WHERE CONFIG_SUBTYPE = 'ENTERPRISE' AND KEY = 'MAX_TRIP_DAYS' AND ACTIVE_FLG = 'Y'
),
multi AS (   -- only a multi-day trip can be over any cap
    SELECT TRIP_MASTER_ID, GUEST_UNIQUE_ID, MARKET_CD, TRIP_START_DT, TRIP_END_DT, UPDATED_DTTM,
           TRIP_END_DT - TRIP_START_DT + 1 AS TRIP_DAYS
    FROM DAAS_PROD.DAAS_CORE.TRIP_MASTER
    WHERE DELETE_IND = 'N'
      AND TRIP_TYPE = 'MARKET'
      AND MARKET_CD IN ('BEM', 'WLM')
      AND TRIP_END_DT > TRIP_START_DT
),
caps AS (    -- one config-function call per market and start date
    SELECT MARKET_CD, TRIP_START_DT,
           DAAS_PROD.DAAS_COMMON.TRIP_CONFIG_UDF_MARKET('MAX_TRIP_DAYS', MARKET_CD, TRIP_START_DT) AS CAP
    FROM (SELECT DISTINCT MARKET_CD, TRIP_START_DT FROM multi)
),
over_cap AS (
    SELECT m.*, COALESCE(TRY_TO_NUMBER(c.CAP), TRY_TO_NUMBER(e.MAX_TRIP_DAYS)) AS MAX_TRIP_DAYS
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
ratings AS (   -- the live ratings each target holds: what R3 replays
    SELECT d.TRIP_MASTER_ID, COUNT(DISTINCT d.TRANSACTION_TABLE_SK) AS RATING_ROWS
    FROM DAAS_PROD.DAAS_CORE.TRIP_DETAIL d
    JOIN over_cap o ON o.TRIP_MASTER_ID = d.TRIP_MASTER_ID
    WHERE d.TRANSACTION_TABLE = 'RATINGS_FACT' AND d.DELETE_IND = 'N' AND d.TRANSACTION_SUB_TYPE = 'OPENED'
    GROUP BY d.TRIP_MASTER_ID
),
guests AS (    -- one batch number per guest: the first CANARY_GUESTS guests (by hash) are batch 1, everyone else batch 2
               -- (GUESTS_PER_BATCH is larger than the guest count; lower it only if the run has to be split further)
    SELECT GUEST_UNIQUE_ID,
           ROW_NUMBER() OVER (ORDER BY ABS(HASH(GUEST_UNIQUE_ID)), GUEST_UNIQUE_ID) AS RN
    FROM (SELECT DISTINCT GUEST_UNIQUE_ID FROM over_cap)
),
batches AS (
    SELECT GUEST_UNIQUE_ID,
           IFF(RN <= 500, 1, 2 + FLOOR((RN - 500 - 1) / 1000000)) AS BATCH_NO   /* 500 = CANARY_GUESTS, 1000000 = GUESTS_PER_BATCH */
    FROM guests
)
SELECT o.TRIP_MASTER_ID, o.GUEST_UNIQUE_ID, o.MARKET_CD, o.TRIP_START_DT, o.TRIP_END_DT, o.TRIP_DAYS, o.MAX_TRIP_DAYS,
       o.UPDATED_DTTM AS UPDATED_DTTM_BEFORE,
       COALESCE(r.RATING_ROWS, 0) AS RATING_ROWS,
       b.BATCH_NO
FROM over_cap o
JOIN batches b ON b.GUEST_UNIQUE_ID = o.GUEST_UNIQUE_ID
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

-- R2. Preview of the before-picture: the same targets R3 will find, in total and by batch (1 the canary, 2 everyone
--     else). Expect trips, guests and rating_rows_to_replay to agree with R0b and with what R3 reports.
SELECT COALESCE(TO_VARCHAR(BATCH_NO), 'all') AS batch,
       COUNT(*)                                  AS trips,
       COUNT_IF(RATING_ROWS > 0)                 AS trips_the_replay_reaches,
       COUNT_IF(RATING_ROWS = 0)                 AS trips_with_no_live_rating,
       COUNT(DISTINCT GUEST_UNIQUE_ID)           AS guests,
       COUNT_IF(MARKET_CD = 'BEM')               AS bem_trips,
       COUNT_IF(MARKET_CD = 'WLM')               AS wlm_trips,
       SUM(RATING_ROWS)                          AS rating_rows_to_replay,
       MAX(TRIP_DAYS)                            AS longest_days,
       MIN(TRIP_START_DT)                        AS earliest_start,
       MAX(TRIP_START_DT)                        AS latest_start
FROM DAAS_PROD.DAAS_TEMP_WORK.DAASI_3641_P14_TRIPS
GROUP BY ROLLUP (BATCH_NO)
ORDER BY BATCH_NO NULLS LAST;

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


-- R3. THE ONE WRITE, self-contained: it reads nothing but PROD's own tables. The replay: every live rating of every live
--     BEM/WLM market trip that is over its cap with no hotel night (the same measure as R0b and v1.4 itself) is marked
--     on RATINGS_FACT, which puts it in RATINGS_FACT_STREAM for the next hourly run. Rows updated must equal R0b's
--     ratings_fact_rows_to_update. The platform's replay pattern (REPLAY_COUNTER up by one, UPDATED_DTTM and UPDATED_BY
--     stamped; the pipeline's own rating step copies UPDATED_DTTM into TRIP_DETAIL.TRANSACTION_MODIFIED_DTTM, as on any
--     replay). Only ratings are replayed: the merge step re-windows everything a nominated trip holds — offers, comps,
--     POS, cage, free play alike — from TRIP_DETAIL (week test, 847,653 transaction-nights, 0 lost, 0 doubled), so one
--     transaction type is enough to touch the trip, and ratings are the one every reachable target holds.
--     For the canary first, add to the targets CTE:  AND m.GUEST_UNIQUE_ID IN (SELECT GUEST_UNIQUE_ID FROM
--     DAAS_PROD.DAAS_TEMP_WORK.DAASI_3641_P14_TRIPS WHERE BATCH_NO = 1)  — and NOT IN for the rest after its run.
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

-- R3b. Right after R3: the stream has the rows and the root task will fire at :15. Expect TRUE and rows = rows updated.
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
