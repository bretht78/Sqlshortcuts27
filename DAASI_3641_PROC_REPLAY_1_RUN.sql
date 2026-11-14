-- DAASI-3641: the PROD replay carried by DATA_REPLAY_PROC, in batches. Part 1 of 2: the run.
--
-- An alternative to DAASI_3641_PROD_REPLAY_2_RUN.sql that the team can run on its own. The procedure makes the
-- updates, so this needs no role beyond the team's and leaves the root task alone. It is the same replay: the same
-- trips, the same rating rows, the same pipeline doing the re-cut.
--
-- How. As in August, the rows are listed once in scratch tables with a batch number, and a batch is a call of the
-- procedure whose condition is "the rows of batch n". Two lists, so two calls a batch:
--   TRIP_DETAIL  one rating row of each property trip and day the batch's trips share a rating with. It puts the
--                property side in the summary step's stream, so that comp worth (the comp dollars the play earns)
--                is valued in the same run as the re-cut.
--   TRIP_MASTER  the batch's trips: live BEM/WLM market trips longer than their cap with no hotel night. It puts
--                them in merge check's stream; v1.4 sends each to the merge step, which retires it and rebuilds
--                its transactions under the current cap.
-- August's calls did not work because they replayed RATINGS_FACT: a replayed rating does not rewrite its trip's
-- row, so merge check never saw the trips. These calls update the trip rows themselves.
--
-- What the procedure does with a call (its body, read 13 Nov: PROD's version of 23 Aug 2023, the same as UAT's). It
-- counts the rows the condition matches and refuses if that is over the limit given. Otherwise it runs
--     UPDATE <table> SET REPLAY_COUNTER = REPLAY_COUNTER + 1, UPDATED_BY = <user> <ticket>, UPDATED_DTTM = <now>
--     WHERE <condition>
-- itself, before it returns, and writes the call in DAAS_COMMON.DATA_REPLAY_LOG. That is the update the UAT
-- rehearsal made, except that it leaves LAST_DML_CD alone and adds the ticket to UPDATED_BY. The pipeline's steps
-- take these rows from streams and none of them picks its rows by any of those columns (checked in PROD's
-- source), so to the pipeline the two are the same touch.
--
-- The one thing this route cannot do is suspend the root task, so the timing is the batch statement's to keep.
-- Both calls of a batch have to be in between two hourly runs (one starts at :15 Pacific). Rating rows that ride
-- a run without their trips do no harm: their property trips are summarised once more, as the batch has them
-- summarised anyway. Trips that ride a run without their rating rows are re-cut as they should be but valued at
-- no comp worth, which R then has to put right. So the batch statement (B) makes the two calls itself: the rating
-- rows first, the trips only if the run is still at least 10 minutes off. It calls nothing while a run is going,
-- in the 25 minutes before :15 or the 10 after it, and nothing for a batch while an earlier one has not gone through.
-- What decides whether a batch fits between two runs is the TRIP_DETAIL call. Its rows are scattered, one per
-- property trip and day, and an update rewrites every micro-partition that holds one of them, which can be much
-- of the table whatever the size of the batch. B reports each call's seconds. If a batch's rating rows are in
-- too late for its trips, B stops there, which is harmless, and says so; a larger warehouse for the session is
-- the remedy.
--
-- Seven batches, one per hourly run (11 Nov's figures; A5 gives the day's):
--   1       the long runs, as section 1 of the other file: under 2,700 trips of 68 guests, 93 passes of the merge
--           step's loop at most. The first, small test of this route in PROD
--   2       the rest of those guests' trips: about 10,500, 30 passes at most
--   3 to 7  everyone else in 5 batches, a guest always whole: about 73,000 trips each, 30 passes at most. In
--           transaction rows each is about the run PROD's merge step made on its own on 11 Nov (141,228 trips,
--           under 4 minutes), and in trips about half of it, so the trip jobs stay on their usual warehouse
-- About 378,800 trip rows and 1.05 million rating rows in all, none of them in RATINGS_FACT.
--
-- Order of work:
--   before   DAASI_3641_PROD_REPLAY_1_PRECHECK.sql, as for the other route: its P1 as described there (its first
--            line, the long runs, is batch 1 here), and rows 5 and 10 of its P2 at ok
--   A        once: the before-pictures, the two lists, the count
--   B        the batch statement: a dry run, then batch 1 to 7, each after the run before it has finished
--   C        after each run: C1 the run, C2 where every batch stands
--   part 2   the post-check (DAASI_3641_PROC_REPLAY_2_POSTCHECK.sql): after batch 1, and after batch 7
--   R        only if a batch's trips rode a later run than their rating rows
--   Z        after sign-off: drop the scratch tables
-- A and the first batch belong to the same day: the lists are a picture of the trips as A finds them. The calls
-- skip a listed row that is no longer live, and B and C2 count only trips still to replay.
--
-- Needs: what the pre-check needs (SELECT on the trip tables and the batch log), CREATE TABLE in DAAS_TEMP_WORK,
-- and the right to call the procedure. None of this has been run in PROD. A missing privilege shows in A3 (the
-- clones) or in B's dry run, in both cases with nothing changed.
--
-- Not in this route, because the team's role cannot do it: suspending the trip dynamic tables and the TIBCO tasks
-- around the replay, as the April and August runbooks did, and moving the trip jobs to the XL warehouse. Each
-- batch reaches downstream as one hour's changes, a large one. That is worth a word with the architect before
-- batch 3. What else a run does (neighbours, guests merged away, the archival step) is in the other file's header.

USE ROLE DAAS_TEAM;
USE SECONDARY ROLES ALL;

-- Two session settings, to be run in the worksheet that runs B (again if its session is new). The first makes sure
-- the procedure's updates are committed as it makes them, and closes any transaction left open. The second puts
-- UPDATED_DTTM, which the procedure stamps with the caller's session time, in the pipeline's clock.
ALTER SESSION SET AUTOCOMMIT = TRUE;
ALTER SESSION SET TIMEZONE = 'America/Los_Angeles';


-- ===================================================================================================
-- A. Once: the before-pictures, the lists, the count. Nothing here changes DAAS_CORE.
-- ===================================================================================================

-- A1. Is v1.4 what PROD runs? Expect 'v1.4 is live in PROD'.
SELECT IFF(CONTAINS(GET_DDL('PROCEDURE', 'DAAS_PROD.DAAS_COMMON.TRIP_MERGE_CHECK_PROC(FLOAT, VARCHAR, VARCHAR, VARCHAR, VARCHAR)'),
                    'my_sql_command_3A'),
           'v1.4 is live in PROD', 'PROD still runs the old version: deploy v1.4 first') AS merge_check_version;

-- A2. Is the trip chain idle? Expect 'idle: the last run started at ... and finished at ...'. On WAIT, run it again
--     in a few minutes. The before-pictures are taken while it is idle, so that the four tables agree. B uses the
--     same test before it calls anything: if this never says idle while C1 shows the last run's steps all at
--     SUCCESS, send me both results before going on.
WITH b AS (
    SELECT j.JOB_NAME, x.BATCH_STATUS, x.BATCH_START_DATE, COALESCE(x.BATCH_END_DATE, x.UPDATED_DTTM) AS ENDED
    FROM DAAS_PROD.DAAS_COMMON.BATCH_S02 x
    JOIN DAAS_PROD.DAAS_COMMON.JOB j ON j.JOB_ID = x.JOB_ID
    WHERE j.JOB_NAME LIKE 'TRIP%'
      AND x.BATCH_START_DATE >= DATEADD(hour, -12, CONVERT_TIMEZONE('America/Los_Angeles', CURRENT_TIMESTAMP())::TIMESTAMP_NTZ)
),
r AS (
    SELECT COUNT_IF(BATCH_STATUS = 'IN PROGRESS')                                        AS RUNNING,
           MAX(IFF(JOB_NAME = 'TRIP_FILTERED_TXNS', BATCH_START_DATE, NULL))             AS RUN_STARTED,
           MAX(IFF(JOB_NAME = 'TRIP_COMP_WORTH', BATCH_START_DATE, NULL))                AS COMP_WORTH_STARTED,
           MAX(IFF(JOB_NAME = 'TRIP_NG_REVENUE_SUMMARY', BATCH_START_DATE, NULL))        AS NON_GAMING_STARTED,
           MAX(ENDED)                                                                    AS LAST_ACTIVITY
    FROM b
)
SELECT CASE WHEN RUNNING > 0 THEN 'WAIT: ' || RUNNING || ' trip job(s) still running'
            WHEN RUN_STARTED IS NULL THEN 'LOOK: no run in the last 12 hours'
            WHEN COMP_WORTH_STARTED IS NULL OR NON_GAMING_STARTED IS NULL
              OR COMP_WORTH_STARTED < RUN_STARTED OR NON_GAMING_STARTED < RUN_STARTED
                 THEN 'WAIT: the run that started at ' || TO_VARCHAR(RUN_STARTED, 'HH24:MI') || ' has not reached its last steps'
            ELSE 'idle: the last run started at ' || TO_VARCHAR(RUN_STARTED, 'HH24:MI')
                 || ' and finished at ' || TO_VARCHAR(LAST_ACTIVITY, 'HH24:MI') || ' Pacific'
       END AS trip_chain,
       CONVERT_TIMEZONE('America/Los_Angeles', CURRENT_TIMESTAMP())::TIMESTAMP_NTZ AS now_pacific
FROM r;

-- A3. The before-pictures: zero-copy clones of the four tables the post-check compares, in the team's schema. Run
--     the four together straight after A2, and not between :15 and :25 past the hour, when a run may have started
--     without showing in A2 yet. Then the count: it must return a number. A clone takes seconds and costs no
--     storage until the original changes; the replay changes most of TRIP_DETAIL, so Z is worth running once the
--     post-check is signed off. A second run of this step fails on "already exists", so a before-picture cannot
--     be overwritten.
CREATE TABLE DAAS_PROD.DAAS_TEMP_WORK.DAASI_3641_BEFORE_TRIP_MASTER
CLONE DAAS_PROD.DAAS_CORE.TRIP_MASTER;

CREATE TABLE DAAS_PROD.DAAS_TEMP_WORK.DAASI_3641_BEFORE_TRIP_DETAIL
CLONE DAAS_PROD.DAAS_CORE.TRIP_DETAIL;

CREATE TABLE DAAS_PROD.DAAS_TEMP_WORK.DAASI_3641_BEFORE_TRIP_SUMMARY
CLONE DAAS_PROD.DAAS_CORE.TRIP_SUMMARY;

CREATE TABLE DAAS_PROD.DAAS_TEMP_WORK.DAASI_3641_BEFORE_DAILY_ACTIVITY_SUMMARY
CLONE DAAS_PROD.DAAS_CORE.DAILY_ACTIVITY_SUMMARY;

SELECT COUNT(*) AS trip_master_rows_in_the_before_picture FROM DAAS_PROD.DAAS_TEMP_WORK.DAASI_3641_BEFORE_TRIP_MASTER;

-- A4. The two lists, worked out from the before-pictures by the other file's own target logic, with the batch
--     each row goes in. Both read TRIP_DETAIL more than once: a few minutes each on Large. They can be run again
--     at any time: from the same before-pictures they come out the same.
CREATE OR REPLACE TABLE DAAS_PROD.DAAS_TEMP_WORK.DAASI_3641_REPLAY_TRIPS AS
WITH ent AS (       /* the enterprise settings: merge check's fallback where a market has none of its own */
    SELECT MAX(IFF(KEY = 'MAX_TRIP_DAYS', VALUE, NULL)) AS MAX_TRIP_DAYS,
           MAX(IFF(KEY = 'TRIP_GAP_DAYS', VALUE, NULL)) AS TRIP_GAP_DAYS
    FROM DAAS_PROD.DAAS_CORE.TRIP_CONFIG
    WHERE CONFIG_SUBTYPE = 'ENTERPRISE' AND KEY IN ('MAX_TRIP_DAYS', 'TRIP_GAP_DAYS') AND ACTIVE_FLG = 'Y'
),
multi AS (
    SELECT TRIP_MASTER_ID, GUEST_UNIQUE_ID, MARKET_CD, TRIP_START_DT, TRIP_END_DT, TRIP_END_DT - TRIP_START_DT + 1 AS TRIP_DAYS
    FROM DAAS_PROD.DAAS_TEMP_WORK.DAASI_3641_BEFORE_TRIP_MASTER
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
      AND NOT EXISTS (SELECT 1 FROM DAAS_PROD.DAAS_TEMP_WORK.DAASI_3641_BEFORE_TRIP_DETAIL d
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
SELECT t.TRIP_MASTER_ID, t.GUEST_UNIQUE_ID, t.MARKET_CD, t.TRIP_START_DT, t.TRIP_END_DT, t.TRIP_DAYS, t.CAP, t.GAP,
       CASE WHEN t.RUN_PASSES > 30 AND (t.RUN_CAP > 1 OR MOD(t.PLACE_IN_RUN, 2) = 0) THEN 1      /* the long runs: whole at a cap over one day, every second trip at a one-day cap */
            WHEN t.GUEST_PASSES > 30 THEN 2                                    /* the rest of those guests' trips */
            ELSE 3 + MOD(ABS(HASH(t.GUEST_UNIQUE_ID)), 5)                       /* everyone else in 5 batches, a guest always whole */
       END AS BATCH_NO,
       IFF(t.GUEST_PASSES > 30 AND t.RUN_PASSES > 30 AND t.RUN_CAP = 1, CEIL(t.TRIP_DAYS / t.CAP), t.RUN_PASSES) AS PASSES,
       COALESCE(b.REPLAY_COUNTER, 0) AS REPLAY_COUNTER_WAS
FROM picked t
JOIN DAAS_PROD.DAAS_TEMP_WORK.DAASI_3641_BEFORE_TRIP_MASTER b ON b.TRIP_MASTER_ID = t.TRIP_MASTER_ID;

CREATE OR REPLACE TABLE DAAS_PROD.DAAS_TEMP_WORK.DAASI_3641_REPLAY_MARKS AS
WITH stay AS (       /* trips holding a hotel night */
    SELECT DISTINCT TRIP_MASTER_ID
    FROM DAAS_PROD.DAAS_TEMP_WORK.DAASI_3641_BEFORE_TRIP_DETAIL
    WHERE DELETE_IND = 'N' AND TRANSACTION_TYPE = 'HOTEL'
),
going AS (      /* what each batch sends to the merge step: its trips, and any trip merge check's own rule pairs with one */
    SELECT b.BATCH_NO, b.TRIP_MASTER_ID, b.GUEST_UNIQUE_ID, b.MARKET_CD
    FROM DAAS_PROD.DAAS_TEMP_WORK.DAASI_3641_REPLAY_TRIPS b
    UNION
    SELECT b.BATCH_NO, o.TRIP_MASTER_ID, b.GUEST_UNIQUE_ID, b.MARKET_CD
    FROM DAAS_PROD.DAAS_TEMP_WORK.DAASI_3641_REPLAY_TRIPS b
    JOIN DAAS_PROD.DAAS_TEMP_WORK.DAASI_3641_BEFORE_TRIP_MASTER o
      ON o.GUEST_UNIQUE_ID = b.GUEST_UNIQUE_ID AND o.TRIP_TYPE = 'MARKET' AND o.MARKET_CD = b.MARKET_CD
     AND o.DELETE_IND = 'N' AND o.TRIP_MASTER_ID <> b.TRIP_MASTER_ID
    LEFT JOIN stay s ON s.TRIP_MASTER_ID = o.TRIP_MASTER_ID
    WHERE b.TRIP_START_DT BETWEEN o.TRIP_START_DT AND o.TRIP_END_DT
       OR o.TRIP_START_DT BETWEEN b.TRIP_START_DT AND b.TRIP_END_DT
       OR (s.TRIP_MASTER_ID IS NOT NULL AND DATEADD(day, b.GAP, b.TRIP_END_DT) BETWEEN o.TRIP_START_DT AND o.TRIP_END_DT)
)
SELECT DISTINCT BATCH_NO, TRIP_DETAIL_ID
FROM (
    SELECT g.BATCH_NO, MIN(pd.TRIP_DETAIL_ID) AS TRIP_DETAIL_ID
    FROM going g
    JOIN DAAS_PROD.DAAS_TEMP_WORK.DAASI_3641_BEFORE_TRIP_DETAIL d  ON d.TRIP_MASTER_ID = g.TRIP_MASTER_ID                 /* the ratings the merge step carries over ... */
    JOIN DAAS_PROD.DAAS_TEMP_WORK.DAASI_3641_BEFORE_TRIP_DETAIL pd ON pd.TRANSACTION_TABLE_SK = d.TRANSACTION_TABLE_SK    /* ... where they sit on a property trip */
    JOIN DAAS_PROD.DAAS_TEMP_WORK.DAASI_3641_BEFORE_TRIP_MASTER p  ON p.TRIP_MASTER_ID = pd.TRIP_MASTER_ID
    WHERE d.TRANSACTION_TABLE = 'RATINGS_FACT' AND d.TRANSACTION_SUB_TYPE = 'OPENED'
      AND pd.TRANSACTION_TABLE = 'RATINGS_FACT' AND pd.DELETE_IND = 'N' AND pd.TRANSACTION_SUB_TYPE = 'OPENED'
      AND p.TRIP_TYPE = 'PROPERTY' AND p.DELETE_IND = 'N'
    GROUP BY g.BATCH_NO, pd.TRIP_MASTER_ID, pd.BUSINESS_START_DT, g.GUEST_UNIQUE_ID, g.MARKET_CD
) x;

-- A5. The count: what each batch's two calls will update. One row per batch and the total; ratings_fact_rows is 0
--     because the replay does not touch RATINGS_FACT. Expect a small batch 1 with the long loop (11 Nov: under
--     2,700 trips, 93 passes), and 30 passes or less from batch 2 on. The 'all' line's trip rows are the pre-check's
--     P1 total if both are run the same hour. Two things to send me before B: a batch from 2 on above 30 passes, or
--     an 'all' line far from P1's.
WITH t AS (
    SELECT BATCH_NO, COUNT(*) AS TRIPS, COUNT(DISTINCT GUEST_UNIQUE_ID) AS GUESTS,
           COUNT_IF(MARKET_CD = 'BEM') AS BEM_TRIPS, COUNT_IF(MARKET_CD = 'WLM') AS WLM_TRIPS, MAX(PASSES) AS MOST_PASSES
    FROM DAAS_PROD.DAAS_TEMP_WORK.DAASI_3641_REPLAY_TRIPS
    GROUP BY BATCH_NO
),
m AS (SELECT BATCH_NO, COUNT(*) AS ROWS_TO_MARK FROM DAAS_PROD.DAAS_TEMP_WORK.DAASI_3641_REPLAY_MARKS GROUP BY BATCH_NO),
r AS (
    SELECT t.BATCH_NO, CASE t.BATCH_NO WHEN 1 THEN 'the long runs' WHEN 2 THEN 'the rest of those guests'' trips'
                              ELSE 'everyone else, one batch of 5' END AS WHAT,
           t.TRIPS, COALESCE(m.ROWS_TO_MARK, 0) AS ROWS_TO_MARK, t.GUESTS, t.BEM_TRIPS, t.WLM_TRIPS, t.MOST_PASSES
    FROM t
    LEFT JOIN m ON m.BATCH_NO = t.BATCH_NO
)
SELECT batch, what, trip_master_rows_to_update, trip_detail_rows_to_update, rows_updated_in_all, ratings_fact_rows,
       guests, bem_trips, wlm_trips, most_passes_the_merge_needs
FROM (
    SELECT BATCH_NO AS n, 'batch ' || BATCH_NO AS batch, WHAT AS what, TRIPS AS trip_master_rows_to_update,
           ROWS_TO_MARK AS trip_detail_rows_to_update, TRIPS + ROWS_TO_MARK AS rows_updated_in_all, 0 AS ratings_fact_rows,
           GUESTS AS guests, BEM_TRIPS AS bem_trips, WLM_TRIPS AS wlm_trips, MOST_PASSES AS most_passes_the_merge_needs
    FROM r
    UNION ALL
    SELECT 99, 'all', 'every trip to replay', SUM(TRIPS), SUM(ROWS_TO_MARK), SUM(TRIPS) + SUM(ROWS_TO_MARK), 0,
           (SELECT COUNT(DISTINCT GUEST_UNIQUE_ID) FROM DAAS_PROD.DAAS_TEMP_WORK.DAASI_3641_REPLAY_TRIPS), SUM(BEM_TRIPS), SUM(WLM_TRIPS), MAX(MOST_PASSES)
    FROM r
) x
ORDER BY n;


-- ===================================================================================================
-- B. The batch statement. Run it once as it is (a dry run), then once for each batch, 1 to 7.
-- ===================================================================================================
-- As it stands, v_batch is 0: the dry run. It makes both calls with a condition that matches no row. With nothing
-- changed, that shows this role may call the procedure, that the procedure may update both tables and read both
-- lists, and that the statement runs here. Expect 'dry run ok' on the last row.
-- Then set v_batch to 1 and run it; after that batch's run has finished (C1), set it to 2; and so on. The best
-- moment is soon after an hourly run has ended. The procedure's updates run on this session's warehouse (the
-- first row names it): use the largest this role may use.
-- Read the rows it returns top to bottom. The last one says how it ended:
--   called        both calls went through before the run. Next: C1 after :15, C2, then the next batch
--   WAIT          nothing was called: a run is going, or :15 is under 25 minutes away or under 10 minutes past.
--                 Run it again later
--   STOP          nothing is half done; the row says why (a batch out of turn, a batch already through, a call
--                 the procedure refused, or the rating rows in and too little time left for the trips)
--   LOOK          the trips went in late or unconfirmed; the row says what to check
-- The limit it gives the procedure is the number of rows listed for the batch, so a call can never update more
-- than its list. v_ticket is what the procedure writes on the rows and in its log; change it if the replay has
-- a ticket of its own. v_need and v_need_trips are the two margins, in minutes. Each run reports how long its
-- calls took. If they prove short, v_need can come down to the two calls' time plus ten minutes and v_need_trips
-- to the trips' call time plus five, not lower. Go by a main batch's times for that: batch 1's are a floor.
EXECUTE IMMEDIATE $$
DECLARE
    v_batch      INTEGER DEFAULT 0;              -- <<< 0: the dry run. Then 1, 2 ... 7: the batch to call
    v_ticket     VARCHAR DEFAULT 'DAASI-3641';   -- the procedure writes it on every row it updates and in its log
    v_need       INTEGER DEFAULT 25;             -- minutes that must be left before the next :15 Pacific to start a batch
    v_need_trips INTEGER DEFAULT 10;             -- minutes that must still be left when the trips are called
    v_log        VARCHAR DEFAULT '';
    v_stage      VARCHAR DEFAULT 'nothing had been called';
    v_idle       VARCHAR;
    v_msg        VARCHAR;
    v_cond       VARCHAR;
    v_left       INTEGER;
    v_trips      INTEGER;
    v_rows       INTEGER;
    v_before     INTEGER DEFAULT 0;
    v_todo       INTEGER DEFAULT 0;
    v_secs       INTEGER;
    v_limit      FLOAT;
    v_t0         TIMESTAMP_NTZ;
    v_t1         TIMESTAMP_NTZ;
    res          RESULTSET;
    stop_here    EXCEPTION (-20641, 'DAASI-3641 batch stopped, see the rows');
BEGIN
    ---------------------------------------------------------------- the checks: nothing here changes anything
    v_t0    := (SELECT CURRENT_TIMESTAMP()::TIMESTAMP_NTZ);
    v_left  := (SELECT MOD(75 - MINUTE(CONVERT_TIMEZONE('America/Los_Angeles', CURRENT_TIMESTAMP())), 60));
    v_idle  := (SELECT CASE WHEN r.RUNNING > 0 THEN 'WAIT: ' || r.RUNNING || ' trip job(s) still running'
                    WHEN r.RUN_STARTED IS NULL THEN 'WAIT: no hourly run found in the last 12 hours'
                    WHEN r.COMP_WORTH_STARTED IS NULL OR r.NON_GAMING_STARTED IS NULL
                      OR r.COMP_WORTH_STARTED < r.RUN_STARTED OR r.NON_GAMING_STARTED < r.RUN_STARTED
                         THEN 'WAIT: the run that started at ' || TO_VARCHAR(r.RUN_STARTED, 'HH24:MI') || ' has not reached its last steps'
                    ELSE 'idle: the last run started at ' || TO_VARCHAR(r.RUN_STARTED, 'HH24:MI')
                         || ' and finished at ' || TO_VARCHAR(r.LAST_ACTIVITY, 'HH24:MI') || ' Pacific'
               END
        FROM (SELECT COUNT_IF(x.BATCH_STATUS = 'IN PROGRESS')                                  AS RUNNING,
                     MAX(IFF(j.JOB_NAME = 'TRIP_FILTERED_TXNS', x.BATCH_START_DATE, NULL))      AS RUN_STARTED,
                     MAX(IFF(j.JOB_NAME = 'TRIP_COMP_WORTH', x.BATCH_START_DATE, NULL))         AS COMP_WORTH_STARTED,
                     MAX(IFF(j.JOB_NAME = 'TRIP_NG_REVENUE_SUMMARY', x.BATCH_START_DATE, NULL)) AS NON_GAMING_STARTED,
                     MAX(COALESCE(x.BATCH_END_DATE, x.UPDATED_DTTM))                            AS LAST_ACTIVITY
              FROM DAAS_PROD.DAAS_COMMON.BATCH_S02 x
              JOIN DAAS_PROD.DAAS_COMMON.JOB j ON j.JOB_ID = x.JOB_ID
              WHERE j.JOB_NAME LIKE 'TRIP%'
                AND x.BATCH_START_DATE >= DATEADD(hour, -12, CONVERT_TIMEZONE('America/Los_Angeles', CURRENT_TIMESTAMP())::TIMESTAMP_NTZ)) r);
    v_trips := (SELECT COUNT(*) FROM DAAS_PROD.DAAS_TEMP_WORK.DAASI_3641_REPLAY_TRIPS WHERE BATCH_NO = :v_batch);
    v_rows  := (SELECT COUNT(*) FROM DAAS_PROD.DAAS_TEMP_WORK.DAASI_3641_REPLAY_MARKS WHERE BATCH_NO = :v_batch);
    v_log := v_log || 'session~|~info~|~batch ' || v_batch || ': ' || v_trips || ' trips and ' || v_rows || ' rating rows listed. Role ' || CURRENT_ROLE()
                   || ', warehouse ' || COALESCE(CURRENT_WAREHOUSE(), '(none)') || '. Chain ' || v_idle || '. ' || v_left || ' minutes to the next :15 Pacific#ROW#';
    IF (v_batch <> 0) THEN
        IF (v_trips = 0) THEN
            v_log := v_log || 'order~|~STOP~|~the list has no batch ' || v_batch || '. Nothing was called#ROW#';
            RAISE stop_here;
        END IF;
        SELECT COALESCE(COUNT_IF(l.BATCH_NO < :v_batch), 0), COALESCE(COUNT_IF(l.BATCH_NO = :v_batch), 0)
        INTO :v_before, :v_todo
        FROM DAAS_PROD.DAAS_TEMP_WORK.DAASI_3641_REPLAY_TRIPS l
        JOIN DAAS_PROD.DAAS_CORE.TRIP_MASTER m ON m.TRIP_MASTER_ID = l.TRIP_MASTER_ID
        WHERE l.BATCH_NO <= :v_batch AND m.DELETE_IND = 'N' AND m.TRIP_END_DT - m.TRIP_START_DT + 1 > l.CAP
          AND NOT EXISTS (SELECT 1 FROM DAAS_PROD.DAAS_CORE.TRIP_DETAIL d
                          WHERE d.TRIP_MASTER_ID = m.TRIP_MASTER_ID AND d.DELETE_IND = 'N' AND d.TRANSACTION_TYPE = 'HOTEL');
        IF (v_before > 0) THEN
            v_log := v_log || 'order~|~STOP~|~' || v_before || ' trips of earlier batches are still to replay: their run has not finished, or it left them. '
                           || 'C2 shows which batch. Nothing was called#ROW#';
            RAISE stop_here;
        END IF;
        IF (v_todo = 0) THEN
            v_log := v_log || 'order~|~STOP~|~batch ' || v_batch || ' has gone through: none of its trips is still to replay. Nothing was called#ROW#';
            RAISE stop_here;
        END IF;
        v_log := v_log || 'order~|~ok~|~every earlier batch has gone through; ' || v_todo || ' trips of batch ' || v_batch || ' are still to replay#ROW#';
        IF (NOT STARTSWITH(v_idle, 'idle')) THEN
            v_log := v_log || 'timing~|~WAIT~|~the hourly run has not finished. Nothing was called: run this again when C1 shows it done#ROW#';
            RAISE stop_here;
        END IF;
        IF (v_left > 50) THEN
            v_log := v_log || 'timing~|~WAIT~|~:15 was under 10 minutes ago, and a run that has just started may not show in the batch log yet. '
                           || 'Nothing was called: run this again in a few minutes#ROW#';
            RAISE stop_here;
        END IF;
        IF (v_left < v_need) THEN
            v_log := v_log || 'timing~|~WAIT~|~' || v_left || ' minutes to the next :15 Pacific and ' || v_need
                           || ' are wanted, so that both calls are in before that run starts. Nothing was called: run this again after that run#ROW#';
            RAISE stop_here;
        END IF;
    END IF;

    ---------------------------------------------------------------- call 1: the rating rows (on their own they do no harm)
    v_cond  := 'WHERE DELETE_IND = ''N'' AND TRIP_DETAIL_ID IN (SELECT TRIP_DETAIL_ID FROM DAAS_PROD.DAAS_TEMP_WORK.DAASI_3641_REPLAY_MARKS WHERE BATCH_NO = ' || v_batch || ')';
    v_limit := v_rows;
    v_t1    := (SELECT CURRENT_TIMESTAMP()::TIMESTAMP_NTZ);
    CALL DAAS_PROD.DAAS_COMMON.DATA_REPLAY_PROC('DAAS_CORE', 'TRIP_DETAIL', :v_cond, :v_ticket, :v_limit) INTO :v_msg;
    v_msg   := COALESCE(v_msg, '(the procedure returned nothing)');
    v_secs  := DATEDIFF(second, v_t1, CURRENT_TIMESTAMP()::TIMESTAMP_NTZ);
    IF (NOT STARTSWITH(v_msg, 'Records Updated: ')) THEN
        v_log := v_log || 'rating rows~|~STOP~|~the procedure did not take the rating rows: ' || REPLACE(REPLACE(LEFT(v_msg, 400), '#ROW#', ''), '~|~', '')
                       || '. The trips were not called, so nothing is half done#ROW#';
        RAISE stop_here;
    END IF;
    v_stage := 'the rating rows were in and the trips were not: harmless, call the batch again';
    v_log := v_log || 'rating rows~|~ok~|~TRIP_DETAIL: ' || v_msg || ' (' || v_rows || ' listed), ' || v_secs || ' seconds#ROW#';

    ---------------------------------------------------------------- call 2: the trips, only if both calls are still well ahead of the run
    v_left := v_left - CEIL(DATEDIFF(second, v_t0, CURRENT_TIMESTAMP()::TIMESTAMP_NTZ) / 60);
    IF (v_batch <> 0 AND v_left < v_need_trips) THEN
        v_log := v_log || 'trips~|~STOP~|~only ' || v_left || ' minutes are left before :15 (the rating rows took ' || v_secs || ' seconds), so the trips were not called. '
                       || 'The rating rows on their own do no harm: their property trips are summarised once more, as the batch does anyway. '
                       || 'Run this again for batch ' || v_batch || ' after the next run has finished, earlier in the hour#ROW#';
        RAISE stop_here;
    END IF;
    v_cond  := 'WHERE DELETE_IND = ''N'' AND TRIP_MASTER_ID IN (SELECT TRIP_MASTER_ID FROM DAAS_PROD.DAAS_TEMP_WORK.DAASI_3641_REPLAY_TRIPS WHERE BATCH_NO = ' || v_batch || ')';
    v_limit := v_trips;
    v_t1    := (SELECT CURRENT_TIMESTAMP()::TIMESTAMP_NTZ);
    CALL DAAS_PROD.DAAS_COMMON.DATA_REPLAY_PROC('DAAS_CORE', 'TRIP_MASTER', :v_cond, :v_ticket, :v_limit) INTO :v_msg;
    v_msg   := COALESCE(v_msg, '(the procedure returned nothing)');
    v_secs  := DATEDIFF(second, v_t1, CURRENT_TIMESTAMP()::TIMESTAMP_NTZ);
    IF (NOT STARTSWITH(v_msg, 'Records Updated: ')) THEN
        v_log := v_log || 'trips~|~LOOK~|~the procedure did not confirm the trips: ' || REPLACE(REPLACE(LEFT(v_msg, 400), '#ROW#', ''), '~|~', '')
                       || '. Run C2: if batch ' || v_batch || ' shows no trip called, run this again; if it shows them called, the batch is in#ROW#';
        RAISE stop_here;
    END IF;
    v_stage := 'both calls were in';
    v_log := v_log || 'trips~|~ok~|~TRIP_MASTER: ' || v_msg || ' (' || v_trips || ' listed), ' || v_secs || ' seconds#ROW#';

    v_left := v_left - CEIL(v_secs / 60);
    IF (v_batch = 0) THEN
        v_log := v_log || 'END~|~dry run ok~|~the procedure took both tables and read both lists, and updated nothing. Next: v_batch = 1#ROW#';
    ELSEIF (v_left < 1) THEN
        v_log := v_log || 'END~|~LOOK~|~batch ' || v_batch || ' is in, but the :15 run had started by then: the trips may ride a later run than their rating rows. '
                       || 'After two runs, run the post-check''s PC4: if this batch shows trips valued in different runs, R puts it right#ROW#';
    ELSE
        v_log := v_log || 'END~|~called~|~batch ' || v_batch || ' is in, about ' || v_left || ' minutes before the :15 run. After that run: C1, then C2, then the next batch#ROW#';
    END IF;
    res := (SELECT t.index AS n, SPLIT_PART(t.value, '~|~', 1) AS step, SPLIT_PART(t.value, '~|~', 2) AS verdict, SPLIT_PART(t.value, '~|~', 3) AS detail
            FROM TABLE(SPLIT_TO_TABLE(:v_log, '#ROW#')) t WHERE t.value <> '' ORDER BY t.index);
    RETURN TABLE(res);
EXCEPTION
    WHEN stop_here THEN
        res := (SELECT t.index AS n, SPLIT_PART(t.value, '~|~', 1) AS step, SPLIT_PART(t.value, '~|~', 2) AS verdict, SPLIT_PART(t.value, '~|~', 3) AS detail
                FROM TABLE(SPLIT_TO_TABLE(:v_log, '#ROW#')) t WHERE t.value <> '' ORDER BY t.index);
        RETURN TABLE(res);
    WHEN OTHER THEN
        v_log := v_log || 'error~|~STOP~|~' || REPLACE(REPLACE(LEFT(SQLERRM, 400), '#ROW#', ''), '~|~', '') || '. When it stopped, ' || v_stage || '#ROW#';
        res := (SELECT t.index AS n, SPLIT_PART(t.value, '~|~', 1) AS step, SPLIT_PART(t.value, '~|~', 2) AS verdict, SPLIT_PART(t.value, '~|~', 3) AS detail
                FROM TABLE(SPLIT_TO_TABLE(:v_log, '#ROW#')) t WHERE t.value <> '' ORDER BY t.index);
        RETURN TABLE(res);
END;
$$;


-- ===================================================================================================
-- C. After each run
-- ===================================================================================================

-- C1. The run: the trip jobs' batches of the last three hours, in order. It is done when TRIP_COMP_WORTH and
--     TRIP_NG_REVENUE_SUMMARY show SUCCESS with a start time after this run's TRIP_MERGE_CHECK. Batch 1 is the
--     first reading of each step's minutes; the limits are two hours for the merge step and four for the
--     summaries. If a step shows FAILURE: run C3, keep both results and send them to me before the next batch.
SELECT j.JOB_NAME, b.BATCH_ID, b.BATCH_STATUS, b.BATCH_START_DATE, b.BATCH_END_DATE,
       ROUND(DATEDIFF(second, b.BATCH_START_DATE, COALESCE(b.BATCH_END_DATE, b.UPDATED_DTTM)) / 60, 1) AS minutes,
       CONVERT_TIMEZONE('America/Los_Angeles', CURRENT_TIMESTAMP())::TIMESTAMP_NTZ AS now_pacific
FROM DAAS_PROD.DAAS_COMMON.BATCH_S02 b
JOIN DAAS_PROD.DAAS_COMMON.JOB j ON j.JOB_ID = b.JOB_ID
WHERE j.JOB_NAME LIKE 'TRIP%'
  AND b.BATCH_START_DATE >= DATEADD(hour, -3, CONVERT_TIMEZONE('America/Los_Angeles', CURRENT_TIMESTAMP())::TIMESTAMP_NTZ)
ORDER BY b.BATCH_ID;

-- C2. Where every batch stands, from the lists and the tables as they are now. After a batch's run expect its
--     line at 'done': every listed trip retired_and_re_cut, still_to_replay 0. 'next' is the batch to call.
--     'called: ...' means its trips carry the procedure's update and have not been re-cut yet: its run has not
--     been through. If C1 shows that run finished and the line still says called, call the same batch again.
--     live_but_no_longer_to_replay counts listed trips that are still live but no longer over their cap with no
--     hotel night (one that has gained a hotel night since A, say); v1.4 leaves those alone, and so do B's checks.
WITH stay AS (       /* listed trips holding a hotel night now */
    SELECT DISTINCT d.TRIP_MASTER_ID
    FROM DAAS_PROD.DAAS_CORE.TRIP_DETAIL d
    WHERE d.DELETE_IND = 'N' AND d.TRANSACTION_TYPE = 'HOTEL'
      AND d.TRIP_MASTER_ID IN (SELECT TRIP_MASTER_ID FROM DAAS_PROD.DAAS_TEMP_WORK.DAASI_3641_REPLAY_TRIPS)
),
t AS (          /* each listed trip as it is now. TO_REPLAY 1: live, still over its cap, still with no hotel night */
    SELECT l.BATCH_NO, l.GUEST_UNIQUE_ID,
           IFF(m.TRIP_MASTER_ID IS NULL OR m.DELETE_IND = 'Y', 1, 0) AS RETIRED,
           IFF(m.DELETE_IND = 'N' AND m.TRIP_END_DT - m.TRIP_START_DT + 1 > l.CAP AND s.TRIP_MASTER_ID IS NULL, 1, 0) AS TO_REPLAY,
           IFF(m.DELETE_IND = 'N' AND COALESCE(m.REPLAY_COUNTER, 0) > l.REPLAY_COUNTER_WAS, 1, 0) AS CALLED
    FROM DAAS_PROD.DAAS_TEMP_WORK.DAASI_3641_REPLAY_TRIPS l
    LEFT JOIN DAAS_PROD.DAAS_CORE.TRIP_MASTER m ON m.TRIP_MASTER_ID = l.TRIP_MASTER_ID
    LEFT JOIN stay s ON s.TRIP_MASTER_ID = l.TRIP_MASTER_ID
),
b AS (
    SELECT BATCH_NO, COUNT(*) AS TRIPS, COUNT(DISTINCT GUEST_UNIQUE_ID) AS GUESTS, SUM(RETIRED) AS RETIRED, SUM(TO_REPLAY) AS TO_REPLAY,
           SUM(IFF(TO_REPLAY = 1, CALLED, 0)) AS CALLED, SUM(IFF(RETIRED = 0 AND TO_REPLAY = 0, 1, 0)) AS OTHER
    FROM t
    GROUP BY BATCH_NO
),
k AS (SELECT BATCH_NO, COUNT(*) AS ROWS_LISTED FROM DAAS_PROD.DAAS_TEMP_WORK.DAASI_3641_REPLAY_MARKS GROUP BY BATCH_NO),
x AS (SELECT MIN(IFF(TO_REPLAY > 0, BATCH_NO, NULL)) AS FIRST_OPEN FROM b)
SELECT batch, what, trips_listed, rating_rows_listed, retired_and_re_cut, still_to_replay, of_them_called_and_waiting,
       live_but_no_longer_to_replay, status
FROM (
    SELECT b.BATCH_NO AS n, 'batch ' || b.BATCH_NO AS batch, CASE b.BATCH_NO WHEN 1 THEN 'the long runs' WHEN 2 THEN 'the rest of those guests'' trips'
                              ELSE 'everyone else, one batch of 5' END AS what,
           b.TRIPS AS trips_listed, COALESCE(k.ROWS_LISTED, 0) AS rating_rows_listed, b.RETIRED AS retired_and_re_cut,
           b.TO_REPLAY AS still_to_replay, b.CALLED AS of_them_called_and_waiting, b.OTHER AS live_but_no_longer_to_replay,
           CASE WHEN b.TO_REPLAY = 0 THEN 'done'
                WHEN b.CALLED > 0 THEN 'called: ' || b.CALLED || ' of its trips are waiting for a run'
                WHEN b.BATCH_NO = x.FIRST_OPEN THEN 'next'
                ELSE 'after batch ' || x.FIRST_OPEN END AS status
    FROM b
    LEFT JOIN k ON k.BATCH_NO = b.BATCH_NO
    CROSS JOIN x
    UNION ALL
    SELECT 99, 'all', 'every trip listed', SUM(b.TRIPS), (SELECT COUNT(*) FROM DAAS_PROD.DAAS_TEMP_WORK.DAASI_3641_REPLAY_MARKS),
           SUM(b.RETIRED), SUM(b.TO_REPLAY), SUM(b.CALLED), SUM(b.OTHER),
           IFF(SUM(b.TO_REPLAY) = 0, 'the replay is complete', COUNT_IF(b.TO_REPLAY = 0) || ' of ' || COUNT(*) || ' batches done')
    FROM b
) y
ORDER BY n;

-- C3. (Only if a step shows FAILURE.) The pipeline's own error log for those batches.
SELECT j.JOB_NAME, e.*
FROM DAAS_PROD.DAAS_COMMON.BATCH_ERROR_LOG_S02 e
JOIN DAAS_PROD.DAAS_COMMON.BATCH_S02 b ON b.BATCH_ID = e.BATCH_ID
JOIN DAAS_PROD.DAAS_COMMON.JOB j ON j.JOB_ID = b.JOB_ID
WHERE j.JOB_NAME LIKE 'TRIP%'
  AND b.BATCH_START_DATE >= DATEADD(hour, -3, CONVERT_TIMEZONE('America/Los_Angeles', CURRENT_TIMESTAMP())::TIMESTAMP_NTZ)
ORDER BY e.BATCH_ID;


-- ===================================================================================================
-- R. Only if a batch's trips rode a later run than their rating rows
-- ===================================================================================================
-- How it shows: B ended on LOOK for the batch, or the post-check's PC4 shows most of a batch's trips under
-- left_out_valued_in_different_runs. Those trips are re-cut correctly; what is missing is their comp worth, because
-- the comp worth step values a market trip from the property trips in the run with it.
-- The repair is one call. R1 lists the batch's rating rows again and, with each, the row of the same rating on the
-- market trip built since, so that one run holds both sides. Put the batch number where the arrow is. Run it after
-- C2 shows that batch done. R2 hands the list to the procedure; one call, so any moment will do. The run after it
-- values those trips; PC4 then shows the batch valued in one run. Tested on the pipeline model, not yet in UAT.

-- R1.
CREATE OR REPLACE TABLE DAAS_PROD.DAAS_TEMP_WORK.DAASI_3641_REPLAY_REPAIR AS
WITH k AS (     /* the batch's rating rows on the property trips, those still live */
    SELECT pd.TRIP_DETAIL_ID, pd.TRANSACTION_TABLE_SK
    FROM DAAS_PROD.DAAS_TEMP_WORK.DAASI_3641_REPLAY_MARKS x
    JOIN DAAS_PROD.DAAS_CORE.TRIP_DETAIL pd ON pd.TRIP_DETAIL_ID = x.TRIP_DETAIL_ID
    WHERE x.BATCH_NO = 3          /* <<< the batch to put right */
      AND pd.DELETE_IND = 'N'
)
SELECT TRIP_DETAIL_ID
FROM k
UNION
SELECT md.TRIP_DETAIL_ID            /* and with each, the row of the same rating on the live market trip */
FROM k
JOIN DAAS_PROD.DAAS_CORE.TRIP_DETAIL md ON md.TRANSACTION_TABLE_SK = k.TRANSACTION_TABLE_SK AND md.TRANSACTION_TABLE = 'RATINGS_FACT'
                                  AND md.DELETE_IND = 'N' AND md.TRANSACTION_SUB_TYPE = 'OPENED'
JOIN DAAS_PROD.DAAS_CORE.TRIP_MASTER mm ON mm.TRIP_MASTER_ID = md.TRIP_MASTER_ID AND mm.TRIP_TYPE = 'MARKET' AND mm.DELETE_IND = 'N';

-- R2. Expect 'Records Updated: ' and the number of rows in the list. The limit is a ceiling above any batch's list.
CALL DAAS_PROD.DAAS_COMMON.DATA_REPLAY_PROC('DAAS_CORE', 'TRIP_DETAIL', 'WHERE DELETE_IND = ''N'' AND TRIP_DETAIL_ID IN (SELECT TRIP_DETAIL_ID FROM DAAS_PROD.DAAS_TEMP_WORK.DAASI_3641_REPLAY_REPAIR)', 'DAASI-3641', 2000000);


-- ===================================================================================================
-- Z. After sign-off, and last: drop the scratch tables. The post-check reads the before-pictures and the trips list.
-- ===================================================================================================
DROP TABLE IF EXISTS DAAS_PROD.DAAS_TEMP_WORK.DAASI_3641_REPLAY_TRIPS;
DROP TABLE IF EXISTS DAAS_PROD.DAAS_TEMP_WORK.DAASI_3641_REPLAY_MARKS;
DROP TABLE IF EXISTS DAAS_PROD.DAAS_TEMP_WORK.DAASI_3641_REPLAY_REPAIR;
DROP TABLE IF EXISTS DAAS_PROD.DAAS_TEMP_WORK.DAASI_3641_BEFORE_TRIP_MASTER;
DROP TABLE IF EXISTS DAAS_PROD.DAAS_TEMP_WORK.DAASI_3641_BEFORE_TRIP_DETAIL;
DROP TABLE IF EXISTS DAAS_PROD.DAAS_TEMP_WORK.DAASI_3641_BEFORE_TRIP_SUMMARY;
DROP TABLE IF EXISTS DAAS_PROD.DAAS_TEMP_WORK.DAASI_3641_BEFORE_DAILY_ACTIVITY_SUMMARY;
