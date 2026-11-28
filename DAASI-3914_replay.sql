-- =====================================================================================================
-- DAASI-3914  Missing WCL theo in DAILY_ACTIVITY_SUMMARY_VW                                the replay
-- DRAFT FOR REVIEW. Nothing in this file has been run.
--
-- What it does. It sends every live WCL rating that trips should hold, and that is not on a trip, through
-- trips again WITHOUT its voids. That is what the six-rating pilot did on 11/26. DATA_REPLAY_PROC adds 1
-- to REPLAY_COUNTER on the listed rows of DAAS_CORE.RATINGS_FACT, the trips stream shows them as changed,
-- and the next hourly run links them and rewrites the daily rows.
-- (Theo is the casino's expected win on a guest's play. A guest-day is one guest on one day of play.)
--
-- Size, from the 11/27 sizing: 193,631 ratings, 15,064 guests, 83,644 guest-days, $29.3M of theo.
--   81% of the guest-days sit inside a trip the guest already has: links are added, as on 11/26.
--    4% fall on the day after a trip: that trip is lengthened.
--   15% have no trip there at all: trips builds new ones. That is 12,700 guest-days, so at most about
--       38,000 new trips across property, market and enterprise. The 11/26 pilot did not go down this
--       road or the one above it, which is why Part 4 is a second small pilot.
-- One batch is comfortable. On 11/11 the rating step took 7.4 million rows and wrote 19.7 million links
-- in one run, all steps SUCCESS. This replay is about 3% of that.
--
-- What it leaves for later, on purpose:
--   - play on the last three days, which the property can still edit;
--   - ratings the loads bring in after the list is built;
--   - the voided ratings still sitting on trips (1,686 on 11/27): only the rule change can take them off;
--   - any Hexlite ratings dated before 2/25, when HETCMS was still loading WCL's play. They are kept in
--     the list as batch 9 and not replayed until we know they are not copies of HETCMS play.
-- Until the rule change is deployed, each day's loads keep dropping new table ratings. A small catch-up
-- replay follows the deployment.
--
-- The parts:
--   Part 0  is trips idle? Reads only.
--   Part 1  the before pictures. Reads only. Save the results.
--   Part 2  builds the list and the before picture of its guest-days: two tables in DAAS_TEMP_WORK and
--           one grant. Build them ONCE, the day of the replay.
--   Part 3  backups: four zero-copy clones.
--   Part 4  the second pilot: 25 guests. WRITES TO PROD.
--   Part 5  the main batch. WRITES TO PROD.
--   Part 6  the after pictures. Reads only.
--   Part 7  cleanup.
-- What the procedure writes: REPLAY_COUNTER + 1, UPDATED_BY and UPDATED_DTTM on the listed rows of
-- RATINGS_FACT. Nothing else, and nothing to undo: what then flows is theo trips should already hold.
-- Any other stream on RATINGS_FACT will show the same rows as changed.
-- Run one statement at a time, on a Large warehouse. If a procedure call answers with anything other
-- than the expected text, stop and send me what it said.
--
-- WHEN. Snowflake's clock is Pacific. Central is two hours later.
--   Trips starts at :15 every hour. A start is skipped while the run before it is still going.
--   Hexlite's loads land at about 02:04, 08:04, 14:04 and 20:04 Pacific. Aim for a run that carries none
--   of them, so no fresh void arrives beside a listed rating. The two best over the last 14 days:
--       12:15 Pacific (2:15 PM Central): 43 minutes on average, never over the hour.
--       19:15 Pacific (9:15 PM Central): 50 minutes on average, never over the hour, started every day.
--   A Sunday plan, in Pacific time: Parts 1 to 3 any time that morning, right after a trips run has
--   finished. The dry runs (4b, 5a) can go straight after them. Pilot call between 12:00 and 12:10.
--   Check it from about 1:15 PM. Main call between 7:00 and 7:10 PM. Part 6 that night or Monday.
--   Or: pilot on Saturday in either run, main batch Sunday at 12:15.
--   Expect the main batch's run to take 5 to 15 minutes longer than usual. The run that followed the
--   11/11 load is the nearest match in size (115,598 rating rows, 21,212 new trips): its summary step
--   took 22 minutes.
--   If a start is skipped, the rows simply wait for the next one. If that run does carry a Hexlite load,
--   the worst case is that a few ratings edited in that load stay unlinked for the catch-up.
--   Keep other WCL replays out of that hour. A whole-day replay like DAASS-10921's on 11/20 brings the
--   voids along, and the listed ratings beside them would be set aside again.
-- =====================================================================================================


-- =====================================================================================================
-- PART 0. Is trips idle? (reads only)
-- =====================================================================================================

-- 0. The newest trips steps. Before a call, nothing should say IN PROGRESS, and the top lines should be
--    the last run's closing steps (TRIP_COMP_WORTH, TRIP_NG_REVENUE_SUMMARY) with SUCCESS.
SELECT J.JOB_NAME,
       B.BATCH_STATUS,
       B.BATCH_START_DATE,
       B.UPDATED_DTTM,
       CURRENT_TIMESTAMP()::TIMESTAMP_NTZ      AS SNOWFLAKE_NOW
FROM DAAS_PROD.DAAS_COMMON.BATCH_S02 B
JOIN DAAS_PROD.DAAS_COMMON.JOB J
  ON J.JOB_ID = B.JOB_ID
WHERE J.JOB_NAME LIKE 'TRIP%'
  AND B.BATCH_START_DATE >= DATEADD(hour, -6, CURRENT_TIMESTAMP()::TIMESTAMP_NTZ)
ORDER BY B.BATCH_ID DESC
LIMIT 20;


-- =====================================================================================================
-- PART 1. The before pictures (reads only). Save both results: Part 6 runs them again.
-- =====================================================================================================

-- 1a. WCL month by month: the theo in the ratings that trips should hold, against the theo in the daily
--     view. This is the picture for the ticket. January, the last full month before Hexlite, is the
--     control: it was 6 dollars apart on 11/25.
--       Before: TABLE_THEO_MISSING about 0.64M for February and 2.9M to 3.7M for each month from March
--               to October. SLOT_THEO_MISSING and OTHER_THEO_MISSING near 0.
--       After:  TABLE_THEO_MISSING near 0 for every month through October. November keeps a remainder
--               until the rule change: its last days, and whatever the loads have brought since.
--               DAILY_SLOT_THEO and DAILY_OTHER_THEO should not move.
WITH R AS (
    SELECT DATE_TRUNC('MONTH', BUSINESS_DT)::DATE                      AS MONTH_START,
           SUM(IFF(GAME_TYPE_CD = 'P', THEO_WIN_AMT, 0))               AS TABLE_THEO,
           SUM(IFF(GAME_TYPE_CD = 'S', THEO_WIN_AMT, 0))               AS SLOT_THEO,
           SUM(IFF(GAME_TYPE_CD = 'O', THEO_WIN_AMT, 0))               AS OTHER_THEO
    FROM DAAS_PROD.DAAS_CORE_GAMING_VW.RATINGS_FACT_VW
    WHERE PROPERTY_CD = 'WCL'
      AND DELETE_IND = 'N'
      AND BUSINESS_DT >= '2026-01-01'
      AND GUEST_UNIQUE_ID <> 0
      AND IFNULL(GAME_CD, '') <> '95'
      AND CONTAINS('S,O,P', GAME_TYPE_CD)
    GROUP BY 1
),
D AS (
    SELECT DATE_TRUNC('MONTH', GUEST_ACTIVITY_DATE)::DATE              AS MONTH_START,
           SUM(TABLE_THEO_WIN_AMT)                                     AS TABLE_THEO,
           SUM(SLOT_THEO_WIN_AMT)                                      AS SLOT_THEO,
           SUM(OTHER_THEO_WIN_AMT)                                     AS OTHER_THEO
    FROM DAAS_PROD.DAAS_CORE_MARKETING_VW.DAILY_ACTIVITY_SUMMARY_VW
    WHERE TRIP_TYPE = 'PROPERTY'
      AND PROPERTY_CD = 'WCL'
      AND GUEST_ACTIVITY_DATE >= '2026-01-01'
    GROUP BY 1
)
SELECT COALESCE(R.MONTH_START, D.MONTH_START)                          AS MONTH_START,
       ROUND(R.TABLE_THEO)                                             AS RATINGS_TABLE_THEO,
       ROUND(D.TABLE_THEO)                                             AS DAILY_TABLE_THEO,
       ROUND(COALESCE(R.TABLE_THEO, 0) - COALESCE(D.TABLE_THEO, 0))    AS TABLE_THEO_MISSING,
       ROUND(COALESCE(R.SLOT_THEO, 0) - COALESCE(D.SLOT_THEO, 0))      AS SLOT_THEO_MISSING,
       ROUND(COALESCE(R.OTHER_THEO, 0) - COALESCE(D.OTHER_THEO, 0))    AS OTHER_THEO_MISSING,
       ROUND(D.SLOT_THEO)                                              AS DAILY_SLOT_THEO,
       ROUND(D.OTHER_THEO)                                             AS DAILY_OTHER_THEO
FROM R
FULL OUTER JOIN D ON D.MONTH_START = R.MONTH_START
ORDER BY 1;

-- 1b. How long WCL's trips are today: live property trips (WCL) and market trips (WCM) that start on or
--     after February 1, counted by length in days. Both are capped at 3 days. This is the baseline for
--     the trips the replay will build or lengthen. Note the longest length on each side now: Part 6
--     checks that nothing longer appears.
SELECT TRIP_TYPE,
       DATEDIFF(day, TRIP_START_DT, TRIP_END_DT) + 1       AS TRIP_DAYS,
       COUNT(*)                                            AS TRIPS
FROM DAAS_PROD.DAAS_CORE.TRIP_MASTER
WHERE DELETE_IND = 'N'
  AND TRIP_START_DT >= '2026-02-01'
  AND ((TRIP_TYPE = 'PROPERTY' AND PROPERTY_CD = 'WCL') OR (TRIP_TYPE = 'MARKET' AND MARKET_CD = 'WCM'))
GROUP BY 1, 2
ORDER BY 1, 2;


-- =====================================================================================================
-- PART 2. Build the list and its before picture (two tables in DAAS_TEMP_WORK, one grant)
-- =====================================================================================================

-- 2a. The list. One row per rating, with where its guest-day lands and its batch.
--       LANDS      1 = inside a trip the guest already has   2 = the day after a trip   3 = no trip there
--       BATCH_NBR  0 = the pilot (25 guests)   1 = the main batch   9 = held back (play before 2/25)
--     The pilot takes 10 guests who have a "no trip" day, 10 whose hardest day is a "day after", and 5
--     who are "inside" only, each with 40 listed ratings or fewer. A guest is never split between the
--     pilot and the main batch.
--     Build this ONCE. Built again after the pilot, it would drop the pilot's guests and pick new ones.
CREATE OR REPLACE TABLE DAAS_PROD.DAAS_TEMP_WORK.DAASI_3914_REPLAY AS
WITH LINKS AS (
    SELECT DISTINCT TRANSACTION_TABLE_SK AS SK
    FROM DAAS_PROD.DAAS_CORE.TRIP_DETAIL
    WHERE TRANSACTION_TYPE = 'RATINGS'
      AND DELETE_IND = 'N'
      AND CREATED_DTTM >= '2026-11-11'
),
TO_REPLAY AS (
    SELECT R.RATINGS_FACT_SK,
           R.GUEST_UNIQUE_ID,
           R.BUSINESS_DT,
           R.GAME_TYPE_CD,
           R.THEO_WIN_AMT
    FROM DAAS_PROD.DAAS_CORE_GAMING_VW.RATINGS_FACT_VW R
    LEFT JOIN LINKS L ON L.SK = R.RATINGS_FACT_SK
    WHERE R.PROPERTY_CD = 'WCL'
      AND R.DELETE_IND = 'N'
      AND R.CREATED_DTTM >= '2026-11-11'
      AND R.CREATED_DTTM < DATEADD(hour, -3, CURRENT_TIMESTAMP()::TIMESTAMP_NTZ)
      AND R.BUSINESS_DT < DATEADD(day, -3, CURRENT_DATE())
      AND R.GUEST_UNIQUE_ID <> 0
      AND IFNULL(R.GAME_CD, '') <> '95'
      AND CONTAINS('S,O,P', R.GAME_TYPE_CD)
      AND IFNULL(R.RATING_STATUS_CD, '') NOT IN ('V', 'E')
      AND L.SK IS NULL
),
GUEST_DAYS AS (
    SELECT GUEST_UNIQUE_ID,
           BUSINESS_DT,
           COUNT(*) AS RATINGS
    FROM TO_REPLAY
    GROUP BY 1, 2
),
TRIPS AS (
    SELECT GUEST_UNIQUE_ID,
           TRIP_START_DT,
           TRIP_END_DT
    FROM DAAS_PROD.DAAS_CORE.TRIP_MASTER
    WHERE TRIP_TYPE = 'PROPERTY'
      AND PROPERTY_CD = 'WCL'
      AND DELETE_IND = 'N'
      AND TRIP_END_DT >= '2026-01-15'
),
PLACED AS (
    SELECT G.GUEST_UNIQUE_ID,
           G.BUSINESS_DT,
           G.RATINGS,
           CASE WHEN MAX(IFF(G.BUSINESS_DT BETWEEN T.TRIP_START_DT AND T.TRIP_END_DT, 1, 0)) = 1 THEN 1
                WHEN MAX(IFF(T.TRIP_END_DT < G.BUSINESS_DT
                             AND DATEDIFF(day, T.TRIP_END_DT, G.BUSINESS_DT) <= 1
                             AND DATEDIFF(day, T.TRIP_START_DT, G.BUSINESS_DT) + 1 <= 3, 1, 0)) = 1 THEN 2
                ELSE 3
           END AS LANDS
    FROM GUEST_DAYS G
    LEFT JOIN TRIPS T
           ON T.GUEST_UNIQUE_ID = G.GUEST_UNIQUE_ID
          AND T.TRIP_START_DT <= G.BUSINESS_DT
          AND T.TRIP_END_DT >= DATEADD(day, -1, G.BUSINESS_DT)
    GROUP BY 1, 2, 3
),
GUESTS AS (
    SELECT GUEST_UNIQUE_ID,
           MAX(LANDS)      AS HARDEST_CASE,
           SUM(RATINGS)    AS RATINGS
    FROM PLACED
    WHERE BUSINESS_DT >= '2026-02-25'
    GROUP BY 1
),
PICKED AS (
    SELECT GUEST_UNIQUE_ID
    FROM GUESTS
    WHERE RATINGS <= 40
    QUALIFY ROW_NUMBER() OVER (PARTITION BY HARDEST_CASE ORDER BY HASH(GUEST_UNIQUE_ID)) <= IFF(HARDEST_CASE = 1, 5, 10)
)
SELECT T.RATINGS_FACT_SK,
       T.GUEST_UNIQUE_ID,
       T.BUSINESS_DT,
       T.GAME_TYPE_CD,
       T.THEO_WIN_AMT,
       P.LANDS,
       CASE WHEN T.BUSINESS_DT < '2026-02-25' THEN 9
            WHEN K.GUEST_UNIQUE_ID IS NOT NULL THEN 0
            ELSE 1
       END                                         AS BATCH_NBR,
       CURRENT_TIMESTAMP()::TIMESTAMP_NTZ          AS BUILT_AT
FROM TO_REPLAY T
JOIN PLACED P
  ON P.GUEST_UNIQUE_ID = T.GUEST_UNIQUE_ID
 AND P.BUSINESS_DT = T.BUSINESS_DT
LEFT JOIN PICKED K
       ON K.GUEST_UNIQUE_ID = T.GUEST_UNIQUE_ID;

-- 2b. Lets the replay procedure's owner read the list.
GRANT SELECT ON TABLE DAAS_PROD.DAAS_TEMP_WORK.DAASI_3914_REPLAY TO ROLE DEVOPS_SERVICE_PROD;

-- 2c. The list in summary.
--       Batches 0 and 1 together: close to the 11/27 count of 193,631, less the last three days of play.
--       Batch 0: 25 guests and a few hundred ratings, with lines for LANDS 1, 2 and 3.
--       Batch 9: few or none. Send me its line either way.
--     Note RATINGS_IN_BATCH for batches 0 and 1: the dry runs in Parts 4 and 5 should return them.
SELECT BATCH_NBR,
       LANDS,
       COUNT(DISTINCT GUEST_UNIQUE_ID)                             AS GUESTS,
       COUNT(DISTINCT GUEST_UNIQUE_ID || '|' || BUSINESS_DT)       AS GUEST_DAYS,
       COUNT(*)                                                    AS RATINGS,
       COUNT_IF(GAME_TYPE_CD = 'P')                                AS TABLE_RATINGS,
       ROUND(SUM(THEO_WIN_AMT))                                    AS THEO,
       SUM(COUNT(*)) OVER (PARTITION BY BATCH_NBR)                 AS RATINGS_IN_BATCH,
       MIN(BUSINESS_DT)                                            AS FIRST_PLAY_DAY,
       MAX(BUSINESS_DT)                                            AS LAST_PLAY_DAY,
       MIN(BUILT_AT)                                               AS BUILT_AT
FROM DAAS_PROD.DAAS_TEMP_WORK.DAASI_3914_REPLAY
GROUP BY 1, 2
ORDER BY 1, 2;

-- 2d. The before picture of the list's guest-days, as the daily view shows them now: one row per guest,
--     day and kind of trip (property WCL, market WCM, enterprise). 6d sets it against the view afterwards
--     to show the replay added the listed theo and moved nothing else. It also keeps COMP_WORTH, a
--     figure trips works out from the ratings on the trip. Build it once, right after 2a.
CREATE OR REPLACE TABLE DAAS_PROD.DAAS_TEMP_WORK.DAASI_3914_BEFORE AS
WITH GD AS (
    SELECT DISTINCT GUEST_UNIQUE_ID,
           BUSINESS_DT
    FROM DAAS_PROD.DAAS_TEMP_WORK.DAASI_3914_REPLAY
)
SELECT S.GUEST_UNIQUE_ID,
       S.GUEST_ACTIVITY_DATE,
       S.TRIP_TYPE,
       COUNT(*)                                    AS DAILY_ROWS,
       SUM(S.TABLE_THEO_WIN_AMT)                   AS TABLE_THEO,
       SUM(S.TOTAL_THEO_WIN_AMT)                   AS TOTAL_THEO,
       SUM(S.COMP_WORTH)                           AS COMP_WORTH,
       MAX(S.UPDATED_DTTM)                         AS LAST_UPDATED,
       CURRENT_TIMESTAMP()::TIMESTAMP_NTZ          AS TAKEN_AT
FROM DAAS_PROD.DAAS_CORE_MARKETING_VW.DAILY_ACTIVITY_SUMMARY_VW S
JOIN GD
  ON GD.GUEST_UNIQUE_ID = S.GUEST_UNIQUE_ID
 AND GD.BUSINESS_DT = S.GUEST_ACTIVITY_DATE
WHERE S.GUEST_ACTIVITY_DATE >= '2026-02-01'
  AND S.TRIP_MASTER_ID <> -1
  AND ((S.TRIP_TYPE = 'PROPERTY' AND S.PROPERTY_CD = 'WCL')
       OR (S.TRIP_TYPE = 'MARKET' AND S.MARKET_CD = 'WCM')
       OR S.TRIP_TYPE = 'ENTERPRISE')
GROUP BY 1, 2, 3;


-- =====================================================================================================
-- PART 3. Backups: four zero-copy clones, as the earlier trips replays took
-- =====================================================================================================

-- A clone is an instant snapshot and costs nothing until the original changes. Take them while trips is
-- idle (Part 0), before the pilot. If your role cannot create tables in DAAS_BACKUP, put them in
-- DAAS_TEMP_WORK under the same names.
CREATE TABLE DAAS_PROD.DAAS_BACKUP.TRIP_MASTER_DAASI_3914 CLONE DAAS_PROD.DAAS_CORE.TRIP_MASTER;
CREATE TABLE DAAS_PROD.DAAS_BACKUP.TRIP_DETAIL_DAASI_3914 CLONE DAAS_PROD.DAAS_CORE.TRIP_DETAIL;
CREATE TABLE DAAS_PROD.DAAS_BACKUP.TRIP_SUMMARY_DAASI_3914 CLONE DAAS_PROD.DAAS_CORE.TRIP_SUMMARY;
CREATE TABLE DAAS_PROD.DAAS_BACKUP.DAILY_ACTIVITY_SUMMARY_DAASI_3914 CLONE DAAS_PROD.DAAS_CORE.DAILY_ACTIVITY_SUMMARY;
ALTER TABLE DAAS_PROD.DAAS_BACKUP.TRIP_MASTER_DAASI_3914 SET DATA_RETENTION_TIME_IN_DAYS = 0;
ALTER TABLE DAAS_PROD.DAAS_BACKUP.TRIP_DETAIL_DAASI_3914 SET DATA_RETENTION_TIME_IN_DAYS = 0;
ALTER TABLE DAAS_PROD.DAAS_BACKUP.TRIP_SUMMARY_DAASI_3914 SET DATA_RETENTION_TIME_IN_DAYS = 0;
ALTER TABLE DAAS_PROD.DAAS_BACKUP.DAILY_ACTIVITY_SUMMARY_DAASI_3914 SET DATA_RETENTION_TIME_IN_DAYS = 0;


-- =====================================================================================================
-- PART 4. The second pilot: batch 0 (WRITES TO PROD: a few hundred rows)
-- =====================================================================================================

-- 4a. The pilot's guest-days, one line each: where each one lands and the WCL property trip it sits on.
--     Run it now, and again after the pilot's trips run.
--       Before: LANDS 1 lines show a trip. LANDS 2 and 3 lines show none. RATINGS_ON_A_TRIP is 0.
--       After:  every line shows a trip of 3 days or fewer, and RATINGS_ON_A_TRIP equals RATINGS.
--               LANDS 2: the trip's end date now reaches the day, and TRIP_UPDATED is after the call.
--               LANDS 3: TRIP_CREATED is after the call.
--               Two lines for the same guest and day would mean two trips cover that day: stop.
WITH GD AS (
    SELECT GUEST_UNIQUE_ID,
           BUSINESS_DT,
           MIN(LANDS)          AS LANDS,
           COUNT(*)            AS RATINGS,
           SUM(THEO_WIN_AMT)   AS THEO
    FROM DAAS_PROD.DAAS_TEMP_WORK.DAASI_3914_REPLAY
    WHERE BATCH_NBR = 0
    GROUP BY 1, 2
),
LINKED AS (
    SELECT B.GUEST_UNIQUE_ID,
           B.BUSINESS_DT,
           COUNT(DISTINCT B.RATINGS_FACT_SK) AS RATINGS_ON_A_TRIP
    FROM DAAS_PROD.DAAS_TEMP_WORK.DAASI_3914_REPLAY B
    JOIN DAAS_PROD.DAAS_CORE.TRIP_DETAIL D
      ON D.TRANSACTION_TABLE_SK = B.RATINGS_FACT_SK
     AND D.TRANSACTION_TYPE = 'RATINGS'
     AND D.DELETE_IND = 'N'
     AND D.CREATED_DTTM >= '2026-11-11'
    WHERE B.BATCH_NBR = 0
    GROUP BY 1, 2
)
SELECT GD.GUEST_UNIQUE_ID,
       GD.BUSINESS_DT,
       GD.LANDS,
       GD.RATINGS,
       COALESCE(L.RATINGS_ON_A_TRIP, 0)                        AS RATINGS_ON_A_TRIP,
       ROUND(GD.THEO, 2)                                       AS THEO,
       M.TRIP_MASTER_ID,
       M.TRIP_START_DT,
       M.TRIP_END_DT,
       DATEDIFF(day, M.TRIP_START_DT, M.TRIP_END_DT) + 1       AS TRIP_DAYS,
       M.CREATED_DTTM                                          AS TRIP_CREATED,
       M.UPDATED_DTTM                                          AS TRIP_UPDATED
FROM GD
LEFT JOIN LINKED L
       ON L.GUEST_UNIQUE_ID = GD.GUEST_UNIQUE_ID
      AND L.BUSINESS_DT = GD.BUSINESS_DT
LEFT JOIN DAAS_PROD.DAAS_CORE.TRIP_MASTER M
       ON M.GUEST_UNIQUE_ID = GD.GUEST_UNIQUE_ID
      AND M.TRIP_TYPE = 'PROPERTY'
      AND M.PROPERTY_CD = 'WCL'
      AND M.DELETE_IND = 'N'
      AND GD.BUSINESS_DT BETWEEN M.TRIP_START_DT AND M.TRIP_END_DT
ORDER BY 1, 2;

-- 4b. Dry run. With -1 the limit can never be met, so the procedure counts the rows its condition matches
--     and stops before its UPDATE. It is the real call in every other way.
--       Expected answer: Updated Records: <n> Exceeds Threshold: -1
--       with <n> = batch 0's RATINGS_IN_BATCH from 2c. A slightly lower <n> means a listed rating was
--       voided since the list was built: fine.
--       An ERROR saying the list table does not exist or is not authorized: run 2b, then repeat.
CALL DAAS_PROD.DAAS_COMMON.DATA_REPLAY_PROC(
    'DAAS_CORE',
    'RATINGS_FACT',
    'RATINGS_FACT_SK IN (SELECT B.RATINGS_FACT_SK FROM DAAS_PROD.DAAS_TEMP_WORK.DAASI_3914_REPLAY B WHERE B.BATCH_NBR = 0) AND DELETE_IND = ''N''',
    'DAASI-3914',
    -1
);

-- 4c. The pilot. The limit of 2,000 is a guard: if the condition matched more, nothing would be updated.
--     Check Part 0 first, and make the call between :00 and :10.
--       Expected answer: Records Updated: <n>, the same <n> as 4b.
CALL DAAS_PROD.DAAS_COMMON.DATA_REPLAY_PROC(
    'DAAS_CORE',
    'RATINGS_FACT',
    'RATINGS_FACT_SK IN (SELECT B.RATINGS_FACT_SK FROM DAAS_PROD.DAAS_TEMP_WORK.DAASI_3914_REPLAY B WHERE B.BATCH_NBR = 0) AND DELETE_IND = ''N''',
    'DAASI-3914',
    2000
);

-- 4d. When Part 0 shows that run has finished: run 4a again, then 6a, 6b, 6c and 6d, and read their
--     batch 0 lines. Go on to Part 5 only if every one reads as described. If one does not, stop and send
--     me all five results.
--     To skip the pilot, run 4c and 5b before the same :15 and both batches go through in one run.


-- =====================================================================================================
-- PART 5. The main batch: batch 1 (WRITES TO PROD: about 193,000 rows)
-- =====================================================================================================

-- 5a. Dry run.
--       Expected answer: Updated Records: <n> Exceeds Threshold: -1
--       with <n> = batch 1's RATINGS_IN_BATCH from 2c, or slightly lower.
CALL DAAS_PROD.DAAS_COMMON.DATA_REPLAY_PROC(
    'DAAS_CORE',
    'RATINGS_FACT',
    'RATINGS_FACT_SK IN (SELECT B.RATINGS_FACT_SK FROM DAAS_PROD.DAAS_TEMP_WORK.DAASI_3914_REPLAY B WHERE B.BATCH_NBR = 1) AND DELETE_IND = ''N''',
    'DAASI-3914',
    -1
);

-- 5b. The replay. With no limit the procedure refuses anything over 100,000 rows, so this passes 250,000:
--     room for the whole batch, and still a guard against a condition that matches far more.
--     Check Part 0 first, and make the call between :00 and :10.
--       Expected answer: Records Updated: <n>, the same <n> as 5a.
CALL DAAS_PROD.DAAS_COMMON.DATA_REPLAY_PROC(
    'DAAS_CORE',
    'RATINGS_FACT',
    'RATINGS_FACT_SK IN (SELECT B.RATINGS_FACT_SK FROM DAAS_PROD.DAAS_TEMP_WORK.DAASI_3914_REPLAY B WHERE B.BATCH_NBR = 1) AND DELETE_IND = ''N''',
    'DAASI-3914',
    250000
);


-- =====================================================================================================
-- PART 6. The after pictures (reads only). Run them once the trips run that took the batch has finished.
--         Links show up a few minutes after :15. The daily view follows when the run's summary step ends.
-- =====================================================================================================

-- 6a. Is every listed rating on its three trips (property, market, enterprise)? One line per batch and
--     landing.
--       After a batch's run: ON_ALL_THREE_TRIPS equals RATINGS, and the other three columns are 0.
--       NOT_ON_A_TRIP above 0 by a handful -> ratings voided since the list was built. The list also
--           holds about 90 ratings (85 of them slot) that were off trips with no void beside them. If
--           those stay off, they show here: that is the separate item, not the replay failing.
--       ON_MORE_THAN_THREE above 0 -> two trips of one kind cover the same day. Stop and send it to me,
--           and the same for ON_FEWER_THAN_THREE or a NOT_ON_A_TRIP in the hundreds.
--       Batch 9 stays NOT_ON_A_TRIP: it is not replayed.
WITH LINKS AS (
    SELECT D.TRANSACTION_TABLE_SK              AS SK,
           COUNT(DISTINCT D.TRIP_MASTER_ID)    AS TRIPS_ON
    FROM DAAS_PROD.DAAS_CORE.TRIP_DETAIL D
    WHERE D.TRANSACTION_TYPE = 'RATINGS'
      AND D.DELETE_IND = 'N'
      AND D.CREATED_DTTM >= '2026-11-11'
      AND D.TRANSACTION_TABLE_SK IN (SELECT RATINGS_FACT_SK FROM DAAS_PROD.DAAS_TEMP_WORK.DAASI_3914_REPLAY)
    GROUP BY 1
)
SELECT B.BATCH_NBR,
       B.LANDS,
       COUNT(*)                                    AS RATINGS,
       COUNT_IF(K.TRIPS_ON = 3)                    AS ON_ALL_THREE_TRIPS,
       COUNT_IF(K.TRIPS_ON < 3)                    AS ON_FEWER_THAN_THREE,
       COUNT_IF(K.TRIPS_ON > 3)                    AS ON_MORE_THAN_THREE,
       COUNT_IF(K.SK IS NULL)                      AS NOT_ON_A_TRIP
FROM DAAS_PROD.DAAS_TEMP_WORK.DAASI_3914_REPLAY B
LEFT JOIN LINKS K ON K.SK = B.RATINGS_FACT_SK
GROUP BY 1, 2
ORDER BY 1, 2;

-- 6b. Is each day now right in the daily view? For every listed guest-day: the theo of all the guest's
--     live WCL table ratings that day, against TABLE_THEO_WIN_AMT in the view's PROPERTY row.
--       Before a batch's run: DAILY_MATCHES_RATINGS near 0.
--       After:  DAILY_MATCHES_RATINGS equals GUEST_DAYS and the two theo totals agree. A handful under
--               DAILY_DIFFERS are days with a rating loaded or edited since the list was built.
--       Batch 9 stays different: it is not replayed.
WITH GD AS (
    SELECT DISTINCT BATCH_NBR,
           LANDS,
           GUEST_UNIQUE_ID,
           BUSINESS_DT
    FROM DAAS_PROD.DAAS_TEMP_WORK.DAASI_3914_REPLAY
),
R AS (
    SELECT V.GUEST_UNIQUE_ID,
           V.BUSINESS_DT,
           SUM(V.THEO_WIN_AMT) AS TABLE_THEO
    FROM DAAS_PROD.DAAS_CORE_GAMING_VW.RATINGS_FACT_VW V
    JOIN GD
      ON GD.GUEST_UNIQUE_ID = V.GUEST_UNIQUE_ID
     AND GD.BUSINESS_DT = V.BUSINESS_DT
    WHERE V.PROPERTY_CD = 'WCL'
      AND V.DELETE_IND = 'N'
      AND V.GAME_TYPE_CD = 'P'
      AND IFNULL(V.GAME_CD, '') <> '95'
      AND IFNULL(V.RATING_STATUS_CD, '') NOT IN ('V', 'E')
    GROUP BY 1, 2
),
D AS (
    SELECT S.GUEST_UNIQUE_ID,
           S.GUEST_ACTIVITY_DATE,
           SUM(S.TABLE_THEO_WIN_AMT) AS TABLE_THEO
    FROM DAAS_PROD.DAAS_CORE_MARKETING_VW.DAILY_ACTIVITY_SUMMARY_VW S
    JOIN GD
      ON GD.GUEST_UNIQUE_ID = S.GUEST_UNIQUE_ID
     AND GD.BUSINESS_DT = S.GUEST_ACTIVITY_DATE
    WHERE S.TRIP_TYPE = 'PROPERTY'
      AND S.PROPERTY_CD = 'WCL'
    GROUP BY 1, 2
)
SELECT GD.BATCH_NBR,
       GD.LANDS,
       COUNT(*)                                                                            AS GUEST_DAYS,
       COUNT_IF(ABS(COALESCE(R.TABLE_THEO, 0) - COALESCE(D.TABLE_THEO, 0)) < 0.01)         AS DAILY_MATCHES_RATINGS,
       COUNT_IF(ABS(COALESCE(R.TABLE_THEO, 0) - COALESCE(D.TABLE_THEO, 0)) >= 0.01)        AS DAILY_DIFFERS,
       ROUND(SUM(R.TABLE_THEO))                                                            AS RATINGS_TABLE_THEO,
       ROUND(SUM(D.TABLE_THEO))                                                            AS DAILY_TABLE_THEO
FROM GD
LEFT JOIN R
       ON R.GUEST_UNIQUE_ID = GD.GUEST_UNIQUE_ID
      AND R.BUSINESS_DT = GD.BUSINESS_DT
LEFT JOIN D
       ON D.GUEST_UNIQUE_ID = GD.GUEST_UNIQUE_ID
      AND D.GUEST_ACTIVITY_DATE = GD.BUSINESS_DT
GROUP BY 1, 2
ORDER BY 1, 2;

-- 6c. The trips themselves. Every live trip of a listed guest that was built or changed since the list
--     was built, by kind of trip and length in days.
--       PROPERTY and MARKET: nothing longer than 1b's longest (3 days is the cap). ENTERPRISE: nothing
--       longer than 30. "new trip" lines are the trips built for the "no trip there" days.
--       A longer trip than that -> stop and send it to me before the main batch.
WITH G AS (
    SELECT DISTINCT GUEST_UNIQUE_ID,
           BATCH_NBR
    FROM DAAS_PROD.DAAS_TEMP_WORK.DAASI_3914_REPLAY
    WHERE BATCH_NBR IN (0, 1)
),
S AS (
    SELECT MIN(BUILT_AT) AS BUILT_AT
    FROM DAAS_PROD.DAAS_TEMP_WORK.DAASI_3914_REPLAY
)
SELECT G.BATCH_NBR,
       M.TRIP_TYPE,
       IFF(M.CREATED_DTTM >= S.BUILT_AT, 'new trip', 'older trip, changed')    AS WHAT,
       DATEDIFF(day, M.TRIP_START_DT, M.TRIP_END_DT) + 1                       AS TRIP_DAYS,
       COUNT(*)                                                                AS TRIPS
FROM DAAS_PROD.DAAS_CORE.TRIP_MASTER M
JOIN G
  ON G.GUEST_UNIQUE_ID = M.GUEST_UNIQUE_ID
CROSS JOIN S
WHERE M.DELETE_IND = 'N'
  AND (M.CREATED_DTTM >= S.BUILT_AT OR M.UPDATED_DTTM >= S.BUILT_AT)
  AND ((M.TRIP_TYPE = 'PROPERTY' AND M.PROPERTY_CD = 'WCL')
       OR (M.TRIP_TYPE = 'MARKET' AND M.MARKET_CD = 'WCM')
       OR M.TRIP_TYPE = 'ENTERPRISE')
GROUP BY 1, 2, 3, 4
ORDER BY 1, 2, 3, 4;

-- 6d. Did the replay add the listed theo and move nothing else? For every listed guest-day and kind of
--     trip, the daily view now against the before picture from 2d.
--       AS_EXPECTED  the day's total theo rose by exactly the theo of its listed ratings
--       NOT_YET      the day has not changed (its batch has not run, or is batch 9)
--       DIFFERENT    anything else
--     Before a batch's run its lines read NOT_YET. (A day whose listed ratings carry no theo reads
--     AS_EXPECTED from the start.)
--     After a batch's run, on all three of its lines:
--       AS_EXPECTED equals GUEST_DAYS, THEO_ADDED equals LISTED_THEO, and NON_TABLE_THEO_MOVED and
--       COMP_WORTH_LOWER are 0. COMP_WORTH_NOW should not be below COMP_WORTH_BEFORE on any line: the
--       replay only adds play, so I expect it to rise.
--       A handful under DIFFERENT is normal: ratings loaded or edited in between. One possible cause in
--       November: a day that was still counting a rating voided since. More than a handful, or anything
--       under NON_TABLE_THEO_MOVED or COMP_WORTH_LOWER -> stop and send it to me.
WITH LISTED AS (
    SELECT BATCH_NBR,
           GUEST_UNIQUE_ID,
           BUSINESS_DT,
           SUM(THEO_WIN_AMT)                                   AS LISTED_THEO,
           SUM(IFF(GAME_TYPE_CD = 'P', THEO_WIN_AMT, 0))       AS LISTED_TABLE_THEO
    FROM DAAS_PROD.DAAS_TEMP_WORK.DAASI_3914_REPLAY
    GROUP BY 1, 2, 3
),
KINDS AS (
    SELECT L.BATCH_NBR,
           L.GUEST_UNIQUE_ID,
           L.BUSINESS_DT,
           L.LISTED_THEO,
           L.LISTED_TABLE_THEO,
           K.TRIP_TYPE
    FROM LISTED L
    CROSS JOIN (SELECT 'PROPERTY' AS TRIP_TYPE UNION ALL SELECT 'MARKET' UNION ALL SELECT 'ENTERPRISE') K
),
NOW_ROWS AS (
    SELECT S.GUEST_UNIQUE_ID,
           S.GUEST_ACTIVITY_DATE,
           S.TRIP_TYPE,
           SUM(S.TABLE_THEO_WIN_AMT)                           AS TABLE_THEO,
           SUM(S.TOTAL_THEO_WIN_AMT)                           AS TOTAL_THEO,
           SUM(S.COMP_WORTH)                                   AS COMP_WORTH
    FROM DAAS_PROD.DAAS_CORE_MARKETING_VW.DAILY_ACTIVITY_SUMMARY_VW S
    JOIN (SELECT DISTINCT GUEST_UNIQUE_ID, BUSINESS_DT FROM LISTED) GD
      ON GD.GUEST_UNIQUE_ID = S.GUEST_UNIQUE_ID
     AND GD.BUSINESS_DT = S.GUEST_ACTIVITY_DATE
    WHERE S.GUEST_ACTIVITY_DATE >= '2026-02-01'
      AND S.TRIP_MASTER_ID <> -1
      AND ((S.TRIP_TYPE = 'PROPERTY' AND S.PROPERTY_CD = 'WCL')
           OR (S.TRIP_TYPE = 'MARKET' AND S.MARKET_CD = 'WCM')
           OR S.TRIP_TYPE = 'ENTERPRISE')
    GROUP BY 1, 2, 3
),
PAIRED AS (
    SELECT K.BATCH_NBR,
           K.TRIP_TYPE,
           K.LISTED_THEO,
           K.LISTED_THEO - K.LISTED_TABLE_THEO                                             AS LISTED_NON_TABLE_THEO,
           COALESCE(N.TOTAL_THEO, 0) - COALESCE(B.TOTAL_THEO, 0)                           AS THEO_ADDED,
           (COALESCE(N.TOTAL_THEO, 0) - COALESCE(N.TABLE_THEO, 0))
             - (COALESCE(B.TOTAL_THEO, 0) - COALESCE(B.TABLE_THEO, 0))                     AS NON_TABLE_THEO_ADDED,
           COALESCE(B.COMP_WORTH, 0)                                                       AS COMP_WORTH_BEFORE,
           COALESCE(N.COMP_WORTH, 0)                                                       AS COMP_WORTH_NOW
    FROM KINDS K
    LEFT JOIN DAAS_PROD.DAAS_TEMP_WORK.DAASI_3914_BEFORE B
           ON B.GUEST_UNIQUE_ID = K.GUEST_UNIQUE_ID
          AND B.GUEST_ACTIVITY_DATE = K.BUSINESS_DT
          AND B.TRIP_TYPE = K.TRIP_TYPE
    LEFT JOIN NOW_ROWS N
           ON N.GUEST_UNIQUE_ID = K.GUEST_UNIQUE_ID
          AND N.GUEST_ACTIVITY_DATE = K.BUSINESS_DT
          AND N.TRIP_TYPE = K.TRIP_TYPE
)
SELECT BATCH_NBR,
       TRIP_TYPE,
       COUNT(*)                                                                            AS GUEST_DAYS,
       ROUND(SUM(LISTED_THEO))                                                             AS LISTED_THEO,
       ROUND(SUM(THEO_ADDED))                                                              AS THEO_ADDED,
       COUNT_IF(ABS(THEO_ADDED - LISTED_THEO) < 0.01)                                      AS AS_EXPECTED,
       COUNT_IF(ABS(THEO_ADDED - LISTED_THEO) >= 0.01 AND ABS(THEO_ADDED) < 0.01)          AS NOT_YET,
       COUNT_IF(ABS(THEO_ADDED - LISTED_THEO) >= 0.01 AND ABS(THEO_ADDED) >= 0.01)         AS DIFFERENT,
       COUNT_IF(ABS(THEO_ADDED) >= 0.01
                AND ABS(NON_TABLE_THEO_ADDED - LISTED_NON_TABLE_THEO) >= 0.01)             AS NON_TABLE_THEO_MOVED,
       COUNT_IF(COMP_WORTH_NOW < COMP_WORTH_BEFORE - 0.01)                                 AS COMP_WORTH_LOWER,
       ROUND(SUM(COMP_WORTH_BEFORE))                                                       AS COMP_WORTH_BEFORE,
       ROUND(SUM(COMP_WORTH_NOW))                                                          AS COMP_WORTH_NOW
FROM PAIRED
GROUP BY 1, 2
ORDER BY 1, 2;

-- 6e. After the main batch: run 1a and 1b again and set them beside the saved results. 1a is the picture
--     for the ticket: table theo missing month by month, before and after.

-- 6f. The replay log for this ticket: one line per call that updated rows.
SELECT CREATED_DTTM,
       CREATED_BY,
       TICKET_ID,
       TABLE_NAME,
       ROWS_UPDATED,
       LEFT(REGEXP_REPLACE(CONDITIONS, '\\s+', ' '), 160)        AS CONDITIONS_START
FROM DAAS_PROD.DAAS_COMMON.DATA_REPLAY_LOG
WHERE CREATED_DTTM >= '2026-11-26'
  AND TABLE_NAME ILIKE 'RATINGS_FACT'
  AND TICKET_ID ILIKE '%3914%'
ORDER BY CREATED_DTTM;


-- =====================================================================================================
-- PART 7. Cleanup, once the results are signed off. Remove the leading dashes to run.
-- =====================================================================================================

-- DROP TABLE DAAS_PROD.DAAS_TEMP_WORK.DAASI_3914_REPLAY;
-- DROP TABLE DAAS_PROD.DAAS_TEMP_WORK.DAASI_3914_BEFORE;
-- DROP TABLE DAAS_PROD.DAAS_BACKUP.TRIP_MASTER_DAASI_3914;
-- DROP TABLE DAAS_PROD.DAAS_BACKUP.TRIP_DETAIL_DAASI_3914;
-- DROP TABLE DAAS_PROD.DAAS_BACKUP.TRIP_SUMMARY_DAASI_3914;
-- DROP TABLE DAAS_PROD.DAAS_BACKUP.DAILY_ACTIVITY_SUMMARY_DAASI_3914;
