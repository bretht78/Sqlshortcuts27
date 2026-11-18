-- DAASI-3858  The September checks with sales and no item lines: a replay through DATA_REPLAY_PROC
-- DRAFT FOR REVIEW. Nothing in this file has been run.
--
-- What a replay does here. DATA_REPLAY_PROC adds 1 to REPLAY_COUNTER on the rows it is pointed at in the raw
-- lines table. The table's stream then shows those rows as changed, the item load reads them again on its next
-- run (about every 30 minutes) and inserts the lines that are missing from CHECK_ITEM_FACT. The DAASI-3881
-- replays of 11/06, 11/11 and 11/17 were done this way, with a list table and one call per batch.
--
-- What it cannot reach. A replay only re-sends rows that are already in the raw table. A check whose lines
-- never arrived in raw cannot be repaired by it. Part 1 counts which checks are which. (Raw tables are where
-- InfoGenesis rows first land in Snowflake, before the loads build the fact tables.)
--
-- The parts:
--   Part 1  reads only. Safe to run at any time. It decides whether the rest is worth doing.
--   Part 2  creates one work table in DAAS_TEMP_WORK: the list of checks to replay.
--   Part 3  dry run through the procedure. Changes nothing.
--   Part 4  replays a pilot of 10 checks, then checks that their lines arrived.
--   Part 5  replays the rest, checks, and drops the work table.
-- Before Parts 2 to 5: confirm with Nishit that this set is not already on his list under DAASI-3881, so it is
-- not replayed twice, and follow the team's usual sign-off for a PROD replay.
--
-- Size. 52,793 checks at about 2.2 raw rows a check is about 115,000 raw rows if every one is replayable.
-- Downstream. The inserted lines also reach trips (POS spend on those guests' trips) and the analytics
-- team's daily copy of CHECK_ITEM_FACT, as the lines from the DAASI-3881 replays did.
-- No undo is needed. The replay itself only bumps a counter on raw rows. What the load then inserts are the
-- lines that were missing.
--
-- Written for PROD because the missing lines are PROD data. There is nothing to replay in UAT.
-- Run one statement at a time. A procedure call that answers with text starting ERROR: changed nothing. Stop there.


-- =====================================================================================================
-- PART 1. Read only: which of the checks can a replay reach?
-- =====================================================================================================

-- 1. The checks loaded 9/15 through 10/1 that have sales and no item lines, by source system.
--    CHECKS_MISSING_LINES should add up to the 52,793 of the September check. Give this one a few minutes.
--      LINES_UNDER_ANOTHER_PROPERTY_CD  the lines are in CHECK_ITEM_FACT, filed under a different property code
--                                       than the check. Not a replay case. It is a different problem.
--      REPLAYABLE                       raw lines and the raw check header both exist. These are the ones Part 2 lists.
--      RAW_LINES_BUT_NO_RAW_HEADER      the lines are in raw, the check's header row is not. Left out of the list:
--                                       the load has needed that header to place the lines.
--      NO_RAW_LINES                     the lines never reached the raw table. A replay cannot help. This is a
--                                       question for whoever owns the ingestion.
--    The last three columns are counted for INFOGEN_ONPREM only, the source these raw tables belong to.
--    A row for any other source system is a different pipeline, outside this replay.
WITH checks AS (
    SELECT CHECK_ATTRIBUTE_ID,
           PROPERTY_CD,
           MAX(SRC_PROPERTY_CD)         AS src_property_cd,
           MAX(SOURCE_SYSTEM_NM)        AS source_system,
           MAX(ABS(SALES_GROSS_AMT))    AS net_sales
    FROM DAAS_PROD.DAAS_CORE.CHECK_SALES_FACT
    WHERE CREATED_DTTM >= '2026-09-15'
      AND CREATED_DTTM <  '2026-10-02'
      AND DELETE_IND = 'N'
    GROUP BY 1, 2
),
lines AS (
    SELECT CHECK_ATTRIBUTE_ID,
           PROPERTY_CD,
           SRC_PROPERTY_CD
    FROM DAAS_PROD.DAAS_CORE.CHECK_ITEM_FACT
    WHERE CREATED_DTTM >= '2026-09-01'
    GROUP BY 1, 2, 3
),
gaps AS (
    SELECT c.CHECK_ATTRIBUTE_ID,
           c.PROPERTY_CD,
           c.src_property_cd,
           c.source_system,
           TRY_TO_NUMBER(TRIM(c.CHECK_ATTRIBUTE_ID))     AS id_num
    FROM checks c
    LEFT JOIN lines l
           ON l.CHECK_ATTRIBUTE_ID = c.CHECK_ATTRIBUTE_ID
          AND l.PROPERTY_CD = c.PROPERTY_CD
    WHERE l.CHECK_ATTRIBUTE_ID IS NULL
      AND c.net_sales > 0
),
other_property AS (
    SELECT DISTINCT
           g.CHECK_ATTRIBUTE_ID,
           g.PROPERTY_CD
    FROM gaps g
    JOIN lines l
      ON l.CHECK_ATTRIBUTE_ID = g.CHECK_ATTRIBUTE_ID
     AND l.SRC_PROPERTY_CD = g.src_property_cd
),
onprem AS (
    SELECT DISTINCT
           id_num,
           src_property_cd
    FROM gaps
    WHERE source_system = 'INFOGEN_ONPREM'
      AND id_num IS NOT NULL
),
raw_lines AS (
    SELECT r.TRANSACTION_DATA_ID,
           r.PROPERTY_CODE,
           COUNT(*)                     AS raw_line_rows
    FROM DAAS_PROD.DAAS_RAW_INFOGEN_ONPREM.CHECK_ITEM_DETAIL_RAW r
    JOIN onprem o
      ON o.id_num = r.TRANSACTION_DATA_ID
     AND o.src_property_cd = r.PROPERTY_CODE
    GROUP BY 1, 2
),
raw_headers AS (
    SELECT DISTINCT
           r.TRANSACTION_DATA_ID,
           r.PROPERTY_CODE
    FROM DAAS_PROD.DAAS_RAW_INFOGEN_ONPREM.CHECK_SALES_DETAIL_RAW r
    JOIN onprem o
      ON o.id_num = r.TRANSACTION_DATA_ID
     AND o.src_property_cd = r.PROPERTY_CODE
)
SELECT g.source_system,
       COUNT(*)                                                                                  AS checks_missing_lines,
       COUNT_IF(op.CHECK_ATTRIBUTE_ID IS NOT NULL)                                               AS lines_under_another_property_cd,
       COUNT_IF(op.CHECK_ATTRIBUTE_ID IS NULL AND rl.TRANSACTION_DATA_ID IS NOT NULL
                AND rh.TRANSACTION_DATA_ID IS NOT NULL)                                          AS replayable,
       COUNT_IF(op.CHECK_ATTRIBUTE_ID IS NULL AND rl.TRANSACTION_DATA_ID IS NOT NULL
                AND rh.TRANSACTION_DATA_ID IS NULL)                                              AS raw_lines_but_no_raw_header,
       COUNT_IF(op.CHECK_ATTRIBUTE_ID IS NULL AND rl.TRANSACTION_DATA_ID IS NULL
                AND g.source_system = 'INFOGEN_ONPREM')                                          AS no_raw_lines
FROM gaps g
LEFT JOIN other_property op
       ON op.CHECK_ATTRIBUTE_ID = g.CHECK_ATTRIBUTE_ID
      AND op.PROPERTY_CD = g.PROPERTY_CD
LEFT JOIN raw_lines rl
       ON rl.TRANSACTION_DATA_ID = g.id_num
      AND rl.PROPERTY_CODE = g.src_property_cd
      AND g.source_system = 'INFOGEN_ONPREM'
LEFT JOIN raw_headers rh
       ON rh.TRANSACTION_DATA_ID = g.id_num
      AND rh.PROPERTY_CODE = g.src_property_cd
      AND g.source_system = 'INFOGEN_ONPREM'
GROUP BY 1
ORDER BY 2 DESC;


-- =====================================================================================================
-- PART 2. The list (creates one table in DAAS_PROD.DAAS_TEMP_WORK)
-- =====================================================================================================

-- 2a. Creating a table needs DAAS_TEAM as the primary role.
USE ROLE DAAS_TEAM;

-- 2b. The list: one row per check counted as REPLAYABLE in Part 1, and nothing else. BATCH_NBR 0 is the pilot,
--     10 checks picked by a hash of the key so the pick is the same on every run. BATCH_NBR 1 is the rest.
--     It fails if the table already exists, so a list in use cannot be overwritten by accident.
CREATE TABLE DAAS_PROD.DAAS_TEMP_WORK.DAASI_3858_SEPT_REPLAY AS
WITH checks AS (
    SELECT CHECK_ATTRIBUTE_ID,
           PROPERTY_CD,
           MAX(SRC_PROPERTY_CD)         AS src_property_cd,
           MAX(SOURCE_SYSTEM_NM)        AS source_system,
           MAX(ABS(SALES_GROSS_AMT))    AS net_sales
    FROM DAAS_PROD.DAAS_CORE.CHECK_SALES_FACT
    WHERE CREATED_DTTM >= '2026-09-15'
      AND CREATED_DTTM <  '2026-10-02'
      AND DELETE_IND = 'N'
    GROUP BY 1, 2
),
lines AS (
    SELECT CHECK_ATTRIBUTE_ID,
           PROPERTY_CD,
           SRC_PROPERTY_CD
    FROM DAAS_PROD.DAAS_CORE.CHECK_ITEM_FACT
    WHERE CREATED_DTTM >= '2026-09-01'
    GROUP BY 1, 2, 3
),
gaps AS (
    SELECT c.CHECK_ATTRIBUTE_ID,
           c.PROPERTY_CD,
           c.src_property_cd,
           c.source_system,
           TRY_TO_NUMBER(TRIM(c.CHECK_ATTRIBUTE_ID))     AS id_num
    FROM checks c
    LEFT JOIN lines l
           ON l.CHECK_ATTRIBUTE_ID = c.CHECK_ATTRIBUTE_ID
          AND l.PROPERTY_CD = c.PROPERTY_CD
    WHERE l.CHECK_ATTRIBUTE_ID IS NULL
      AND c.net_sales > 0
),
other_property AS (
    SELECT DISTINCT
           g.CHECK_ATTRIBUTE_ID,
           g.PROPERTY_CD
    FROM gaps g
    JOIN lines l
      ON l.CHECK_ATTRIBUTE_ID = g.CHECK_ATTRIBUTE_ID
     AND l.SRC_PROPERTY_CD = g.src_property_cd
),
onprem AS (
    SELECT DISTINCT
           id_num,
           src_property_cd
    FROM gaps
    WHERE source_system = 'INFOGEN_ONPREM'
      AND id_num IS NOT NULL
),
raw_lines AS (
    SELECT r.TRANSACTION_DATA_ID,
           r.PROPERTY_CODE,
           COUNT(*)                     AS raw_line_rows
    FROM DAAS_PROD.DAAS_RAW_INFOGEN_ONPREM.CHECK_ITEM_DETAIL_RAW r
    JOIN onprem o
      ON o.id_num = r.TRANSACTION_DATA_ID
     AND o.src_property_cd = r.PROPERTY_CODE
    GROUP BY 1, 2
),
raw_headers AS (
    SELECT DISTINCT
           r.TRANSACTION_DATA_ID,
           r.PROPERTY_CODE
    FROM DAAS_PROD.DAAS_RAW_INFOGEN_ONPREM.CHECK_SALES_DETAIL_RAW r
    JOIN onprem o
      ON o.id_num = r.TRANSACTION_DATA_ID
     AND o.src_property_cd = r.PROPERTY_CODE
)
SELECT k.PROPERTY_CODE,
       k.TRANSACTION_DATA_ID,
       k.RAW_LINE_ROWS,
       IFF(ROW_NUMBER() OVER (ORDER BY HASH(k.TRANSACTION_DATA_ID, k.PROPERTY_CODE)) <= 10, 0, 1)   AS BATCH_NBR
FROM (
    SELECT DISTINCT
           rl.PROPERTY_CODE,
           rl.TRANSACTION_DATA_ID,
           rl.raw_line_rows             AS RAW_LINE_ROWS
    FROM gaps g
    LEFT JOIN other_property op
           ON op.CHECK_ATTRIBUTE_ID = g.CHECK_ATTRIBUTE_ID
          AND op.PROPERTY_CD = g.PROPERTY_CD
    LEFT JOIN raw_lines rl
           ON rl.TRANSACTION_DATA_ID = g.id_num
          AND rl.PROPERTY_CODE = g.src_property_cd
          AND g.source_system = 'INFOGEN_ONPREM'
    LEFT JOIN raw_headers rh
           ON rh.TRANSACTION_DATA_ID = g.id_num
          AND rh.PROPERTY_CODE = g.src_property_cd
          AND g.source_system = 'INFOGEN_ONPREM'
    WHERE op.CHECK_ATTRIBUTE_ID IS NULL
      AND rl.TRANSACTION_DATA_ID IS NOT NULL
      AND rh.TRANSACTION_DATA_ID IS NOT NULL
) k;

-- 2c. What the list holds. CHECKS should match REPLAYABLE from Part 1. RAW_ROWS is what each call should update.
SELECT BATCH_NBR,
       COUNT(*)                         AS checks,
       SUM(RAW_LINE_ROWS)               AS raw_rows,
       COUNT(DISTINCT PROPERTY_CODE)    AS source_codes
FROM DAAS_PROD.DAAS_TEMP_WORK.DAASI_3858_SEPT_REPLAY
GROUP BY 1
ORDER BY 1;

-- 2d. The raw rows as they stand, for the record. Keep the result. Run it again after Part 5 for the after picture:
--     LOWEST_REPLAY_COUNTER one higher and every row stamped with the ticket.
SELECT b.BATCH_NBR,
       COUNT(*)                                             AS raw_rows,
       MIN(COALESCE(r.REPLAY_COUNTER, 0))                   AS lowest_replay_counter,
       MAX(COALESCE(r.REPLAY_COUNTER, 0))                   AS highest_replay_counter,
       MAX(r.UPDATED_DATE)                                  AS last_touched,
       COUNT_IF(r.UPDATED_BY ILIKE '%DAASI-3858')             AS rows_stamped_with_this_ticket
FROM DAAS_PROD.DAAS_RAW_INFOGEN_ONPREM.CHECK_ITEM_DETAIL_RAW r
JOIN DAAS_PROD.DAAS_TEMP_WORK.DAASI_3858_SEPT_REPLAY b
  ON b.TRANSACTION_DATA_ID = r.TRANSACTION_DATA_ID
 AND b.PROPERTY_CODE = r.PROPERTY_CODE
GROUP BY 1
ORDER BY 1;


-- =====================================================================================================
-- PART 3. Dry run (changes nothing)
-- =====================================================================================================

-- The last argument is the most rows the procedure may update. A limit of -1 can never be met, so the procedure
-- counts the rows its condition matches and stops before its UPDATE. It is the real call in every other way:
-- the same condition, read under the procedure's own rights.
--   Expected answer: Updated Records: <n> Exceeds Threshold: -1     with <n> equal to RAW_ROWS from 2c.
--   An ERROR saying the list table does not exist or is not authorized means the procedure's owner cannot read
--   the table. Run this grant, then repeat the dry run:
--       GRANT SELECT ON TABLE DAAS_PROD.DAAS_TEMP_WORK.DAASI_3858_SEPT_REPLAY TO ROLE DEVOPS_SERVICE_PROD;

-- 3a. The pilot.
CALL DAAS_PROD.DAAS_COMMON.DATA_REPLAY_PROC(
    'DAAS_RAW_INFOGEN_ONPREM',
    'CHECK_ITEM_DETAIL_RAW',
    'EXISTS (SELECT 1 FROM DAAS_PROD.DAAS_TEMP_WORK.DAASI_3858_SEPT_REPLAY B WHERE B.PROPERTY_CODE = CHECK_ITEM_DETAIL_RAW.PROPERTY_CODE AND B.TRANSACTION_DATA_ID = CHECK_ITEM_DETAIL_RAW.TRANSACTION_DATA_ID AND B.BATCH_NBR = 0)',
    'DAASI-3858',
    -1
);

-- 3b. The rest.
CALL DAAS_PROD.DAAS_COMMON.DATA_REPLAY_PROC(
    'DAAS_RAW_INFOGEN_ONPREM',
    'CHECK_ITEM_DETAIL_RAW',
    'EXISTS (SELECT 1 FROM DAAS_PROD.DAAS_TEMP_WORK.DAASI_3858_SEPT_REPLAY B WHERE B.PROPERTY_CODE = CHECK_ITEM_DETAIL_RAW.PROPERTY_CODE AND B.TRANSACTION_DATA_ID = CHECK_ITEM_DETAIL_RAW.TRANSACTION_DATA_ID AND B.BATCH_NBR = 1)',
    'DAASI-3858',
    -1
);


-- =====================================================================================================
-- PART 4. The pilot: 10 checks
-- =====================================================================================================

-- 4a. Replays the pilot's raw rows. The limit of 1,000 is a guard: if the condition matched more than that,
--     nothing would be updated. Expected answer: Records Updated: <n>, the pilot's RAW_ROWS from 2c.
CALL DAAS_PROD.DAAS_COMMON.DATA_REPLAY_PROC(
    'DAAS_RAW_INFOGEN_ONPREM',
    'CHECK_ITEM_DETAIL_RAW',
    'EXISTS (SELECT 1 FROM DAAS_PROD.DAAS_TEMP_WORK.DAASI_3858_SEPT_REPLAY B WHERE B.PROPERTY_CODE = CHECK_ITEM_DETAIL_RAW.PROPERTY_CODE AND B.TRANSACTION_DATA_ID = CHECK_ITEM_DETAIL_RAW.TRANSACTION_DATA_ID AND B.BATCH_NBR = 0)',
    'DAASI-3858',
    1000
);

-- 4b. Wait for the item load's next run, up to 45 minutes, then run this. CHECKS_WITH_LINES should equal CHECKS
--     for batch 0. If it does not, stop and do not run Part 5: the load is not picking these up, and that is
--     worth knowing before replaying the rest.
SELECT b.BATCH_NBR,
       COUNT(*)                         AS checks,
       COUNT(f.CHECK_ATTRIBUTE_ID)      AS checks_with_lines,
       SUM(f.line_rows)                 AS lines_loaded,
       MIN(f.first_loaded)              AS first_loaded,
       MAX(f.first_loaded)              AS last_loaded
FROM DAAS_PROD.DAAS_TEMP_WORK.DAASI_3858_SEPT_REPLAY b
LEFT JOIN (
    SELECT CHECK_ATTRIBUTE_ID,
           SRC_PROPERTY_CD,
           COUNT(*)                     AS line_rows,
           MIN(CREATED_DTTM)            AS first_loaded
    FROM DAAS_PROD.DAAS_CORE.CHECK_ITEM_FACT
    WHERE CREATED_DTTM >= '2026-11-18'
    GROUP BY 1, 2
) f
       ON f.CHECK_ATTRIBUTE_ID = TO_VARCHAR(b.TRANSACTION_DATA_ID)
      AND f.SRC_PROPERTY_CD = b.PROPERTY_CODE
GROUP BY 1
ORDER BY 1;


-- =====================================================================================================
-- PART 5. The rest, the checks, and cleanup
-- =====================================================================================================

-- 5a. Replays the rest in one call. The procedure's own cap is 100,000 rows when no limit is given, so this
--     passes 200,000: enough for the whole list, and still a guard against a condition that matches far more.
--     Expected answer: Records Updated: <n>, batch 1's RAW_ROWS from 2c.
CALL DAAS_PROD.DAAS_COMMON.DATA_REPLAY_PROC(
    'DAAS_RAW_INFOGEN_ONPREM',
    'CHECK_ITEM_DETAIL_RAW',
    'EXISTS (SELECT 1 FROM DAAS_PROD.DAAS_TEMP_WORK.DAASI_3858_SEPT_REPLAY B WHERE B.PROPERTY_CODE = CHECK_ITEM_DETAIL_RAW.PROPERTY_CODE AND B.TRANSACTION_DATA_ID = CHECK_ITEM_DETAIL_RAW.TRANSACTION_DATA_ID AND B.BATCH_NBR = 1)',
    'DAASI-3858',
    200000
);

-- 5b. After the item load's next run: run 4b again (CHECKS_WITH_LINES equal to CHECKS on both rows), run 2d
--     again for the after picture, and run DAASI_3858_SEPT_CHECK.sql: HAS_SALES_BUT_NO_ITEMS should have dropped
--     by the number of checks in the list.

-- 5c. The procedure's own record of the calls: one row per replay, none for the dry runs.
SELECT CREATED_DTTM,
       CREATED_BY,
       TICKET_ID,
       TABLE_NAME,
       ROWS_UPDATED,
       THRESHOLD
FROM DAAS_PROD.DAAS_COMMON.DATA_REPLAY_LOG
WHERE TICKET_ID = 'DAASI-3858'
ORDER BY CREATED_DTTM;

-- 5d. Cleanup, once 5b is clean.
DROP TABLE DAAS_PROD.DAAS_TEMP_WORK.DAASI_3858_SEPT_REPLAY;
