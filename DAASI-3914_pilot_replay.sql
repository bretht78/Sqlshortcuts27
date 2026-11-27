-- =====================================================================================================
-- DAASI-3914  Missing WCL theo in DAILY_ACTIVITY_SUMMARY_VW                             pilot replay
-- DRAFT FOR REVIEW. Nothing in this file has been run.
--
-- The cause, in short. (Theo is the casino's expected win on a guest's play. Pit means table games.)
-- Since WCL moved to Hexlite, every edit of a table rating arrives as "void the old transaction, issue
-- a new one". The voided versions are rows with status V, and they keep the start and end time of the
-- rating that replaced them. The trips rating step (TRIP_RATING_DOMAIN_PIPELINE_PROC, command 2_1) sets
-- aside an active rating when a void for the same guest, day, start and end time is in the same batch.
-- So the replacement, the one live rating that carries the theo, is set aside with its voids and never
-- reaches a trip. Replayed over the 11/11 load, the step's void rules account for all 182,305 ratings
-- that were never linked to a trip, and for none of the 6,407,375 that were.
--
-- Why the 11/20 replay changed nothing. It re-sent this guest's whole day: 3 live ratings and 8 voids,
-- together (all 11 rows carry RREDDY2 DAASS-10921). The live ratings were set aside again.
--
-- What this pilot does. It replays the guest's six live ratings and none of the voids: three on 9/25
-- and three on 9/26. With no void in the batch nothing sets them aside, so the step finds the guest's
-- trips (9/24 to 9/26) and links each rating to all three: property, market and enterprise.
--   Expected table theo afterwards:   9/25  162.36      9/26  109.09, the figure in the ticket
--
-- The parts:
--   Part 1  the before picture. Reads only.
--   Part 2  dry run through DATA_REPLAY_PROC. Changes nothing.
--   Part 3  the replay. WRITES TO PROD: REPLAY_COUNTER + 1, UPDATED_BY and UPDATED_DTTM on six rows of
--           DAAS_CORE.RATINGS_FACT. Nothing else. Follow the team's usual sign-off for a PROD replay.
--   Part 4  the after picture. Reads only.
-- There is nothing to undo: what then flows is theo these trips should already hold.
-- Written for PROD because these ratings and trips are PROD data.
-- Run one statement at a time. A procedure call that answers with text starting ERROR: changed nothing.
-- =====================================================================================================


-- =====================================================================================================
-- PART 1. The before picture (reads only)
-- =====================================================================================================

-- 1a. The six live ratings, and every trip link each one has.
--       Before: six rows, the trip columns empty. REPLAY_COUNTER 0 on the 9/25 rows and 1 on the 9/26
--               rows (the 11/20 replay).
--       After:  eighteen rows. Each rating three times: on PROPERTY trip 2912710013, MARKET trip
--               2912709271 and ENTERPRISE trip 2912709338, with LINK_DELETE_IND N. REPLAY_COUNTER one
--               higher, UPDATED_BY ending in DAASI-3914.
SELECT R.BUSINESS_DT,
       R.RATINGS_FACT_SK,
       R.THEO_WIN_AMT,
       R.REPLAY_COUNTER,
       R.UPDATED_BY,
       M.TRIP_TYPE,
       D.TRIP_MASTER_ID,
       D.DELETE_IND      AS LINK_DELETE_IND,
       D.CREATED_DTTM    AS LINKED_ON
FROM DAAS_PROD.DAAS_CORE.RATINGS_FACT R
LEFT JOIN DAAS_PROD.DAAS_CORE.TRIP_DETAIL D
       ON D.TRANSACTION_TABLE_SK = R.RATINGS_FACT_SK
      AND D.TRANSACTION_TYPE = 'RATINGS'
      AND D.CREATED_DTTM >= '2026-11-11'
LEFT JOIN DAAS_PROD.DAAS_CORE.TRIP_MASTER M
       ON M.TRIP_MASTER_ID = D.TRIP_MASTER_ID
WHERE R.RATINGS_FACT_SK IN (9026303479, 9025804234, 9029760811, 9029497547, 9031274669, 9028051857)
  AND R.PROPERTY_CD = 'WCL'
  AND R.BUSINESS_DT BETWEEN '2026-09-25' AND '2026-09-26'
ORDER BY R.BUSINESS_DT, R.RATINGS_FACT_SK, M.TRIP_TYPE;

-- 1b. The guest's three days in the view the ticket is about. One row per day and kind of trip; the
--     PROPERTY row (WCL) is the one in the ticket.
--       Before: on 9/26, TABLE_THEO_WIN_AMT and TOTAL_THEO_WIN_AMT 0.00 and GAMING_FLG N. On 9/25,
--               0.00 or no row at all.
--       After:  TABLE_THEO_WIN_AMT 162.36 on 9/25 and 109.09 on 9/26, GAMING_FLG Y. On 9/26 the total
--               is 109.09 as well. 9/24 is the control: its figures should not change.
SELECT GUEST_ACTIVITY_DATE,
       TRIP_TYPE,
       PROPERTY_CD,
       MARKET_CD,
       TRIP_MASTER_ID,
       TABLE_THEO_WIN_AMT,
       TOTAL_THEO_WIN_AMT,
       GAMING_FLG,
       UPDATED_DTTM
FROM DAAS_PROD.DAAS_CORE_MARKETING_VW.DAILY_ACTIVITY_SUMMARY_VW
WHERE GUEST_UNIQUE_ID = 14400356783
  AND GUEST_ACTIVITY_DATE BETWEEN '2026-09-24' AND '2026-09-26'
ORDER BY GUEST_ACTIVITY_DATE, TRIP_TYPE;

-- 1c. What the 11/20 replay asked for, from the replay procedure's own log: its condition and how many
--     rows it re-sent. More than 11 rows means it covered more than this guest's day, and every live
--     table rating in it that had a void beside it was set aside again in the same way.
--     After Part 3 this also shows the DAASI-3914 line, with 6.
SELECT CREATED_DTTM,
       CREATED_BY,
       TICKET_ID,
       TABLE_NAME,
       ROWS_UPDATED,
       LEFT(REGEXP_REPLACE(CONDITIONS, '\\s+', ' '), 300)        AS CONDITIONS_START
FROM DAAS_PROD.DAAS_COMMON.DATA_REPLAY_LOG
WHERE CREATED_DTTM >= '2026-11-01'
  AND TABLE_NAME ILIKE 'RATINGS_FACT'
  AND (TICKET_ID ILIKE '%10921%' OR TICKET_ID ILIKE '%3914%')
ORDER BY CREATED_DTTM;


-- =====================================================================================================
-- PART 2. Dry run (changes nothing)
-- =====================================================================================================

-- The last argument is the most rows the procedure may update. With -1 that can never be met, so the
-- procedure counts the rows its condition matches and stops before its UPDATE.
--   Expected answer: Updated Records: 6 Exceeds Threshold: -1
--   Any other count: stop, and send me the answer.
CALL DAAS_PROD.DAAS_COMMON.DATA_REPLAY_PROC(
    'DAAS_CORE',
    'RATINGS_FACT',
    'RATINGS_FACT_SK IN (9026303479, 9025804234, 9029760811, 9029497547, 9031274669, 9028051857)',
    'DAASI-3914',
    -1
);


-- =====================================================================================================
-- PART 3. The replay (WRITES TO PROD: six rows)
-- =====================================================================================================

-- The same call with a limit of 6: if the condition matched more than six rows, nothing would be updated.
--   Expected answer: Records Updated: 6
CALL DAAS_PROD.DAAS_COMMON.DATA_REPLAY_PROC(
    'DAAS_CORE',
    'RATINGS_FACT',
    'RATINGS_FACT_SK IN (9026303479, 9025804234, 9029760811, 9029497547, 9031274669, 9028051857)',
    'DAASI-3914',
    6
);


-- =====================================================================================================
-- PART 4. The after picture (reads only)
-- =====================================================================================================

-- Trips runs every hour, starting at about :15 past. The rating step writes the links in the first
-- minutes of that run, and the summary step rewrites the daily rows near its end, usually within the
-- hour. After the next run, run 1a and 1b again and compare them with their "After" lines.
--   1a shows the 18 links and 1b shows 162.36 and 109.09
--       -> the cause is proven in PROD, and the ticket's check on this guest (109 on 9/26) passes.
--   1a shows the 18 links but 1b has not changed
--       -> the summary step has not finished. Run 1b again later.
--   1a shows no links after two full runs
--       -> stop, and send me 1a and 1b.
