-- DAASI-3858  Missing CHECK_ATTRIBUTE_IDs in CHECK_ITEM_FACT_VW
-- Round 4.
--
-- Where round 3 left us. The lines that reached CHECK_ITEM_FACT on 2026-11-06 were a replay. At 07:25 that
-- morning NBANDAPATI built DAAS_TEMP_WORK.CHECK_ITEM_REPLAY_BATCHED (862,418 rows, a list of checks that had
-- a record but no lines), and between 07:52 and 08:05 three oversized runs of the regular item load inserted
-- 1.85 million lines. The example's 14 lines were in the third. It was not a one-off: among checks loaded
-- 10/15 to 11/14, 728,095 got their lines more than a day late, and catch-ups landed again on 11/11 and 11/17.
-- The item load never failed in that time, so it runs and skips lines.
--
-- This round asks why. The suspect: the load reads new lines from a stream and joins them to the check's own
-- raw row (CHECK_SALES_DETAIL_RAW). The POS writes the lines just before that row. If a run picks up the
-- lines before the check's row has landed, the join finds nothing, the stream moves on, and those lines are
-- never tried again. J2 shows whether the statement really works that way. J3 and J4 test it on the example.
--
-- Every statement only reads. Run them one at a time. None depends on another.
-- If one is refused or fails, skip it and send me the error text as it appears.
-- All of these read best as text (download the result, or copy the cells).


-- =====================================================================================================
-- PART J. Why the regular load skips lines
-- =====================================================================================================

-- J1. Every statement of the run that loaded the example's lines (pipeline run 47824694), in order: what
--     the item load does before and after its main statement.
SELECT start_time,
       query_type,
       rows_inserted,
       rows_updated,
       rows_deleted,
       ROUND(total_elapsed_time / 1000)                          AS seconds,
       LEFT(REGEXP_REPLACE(query_text, '\\s+', ' '), 160)        AS statement_start
FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
WHERE start_time >= '2026-11-06 08:00:00'
  AND start_time <  '2026-11-06 08:10:00'
  AND query_tag = '47824694_INFOGEN_ONPREM_CHECK_ITEM_FACT_LOAD_PROC'
ORDER BY start_time;


-- J2. The main statement of that run in full: the MERGE into CHECK_ITEM_FACT. One row, one long cell.
--     Click the cell, copy it from the side panel and send it as text. What I am reading it for: how the
--     new lines are joined to CHECK_SALES_DETAIL_RAW and to the dimension tables, inner or left.
SELECT query_text
FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
WHERE start_time >= '2026-11-06 08:00:00'
  AND start_time <  '2026-11-06 08:10:00'
  AND query_tag = '47824694_INFOGEN_ONPREM_CHECK_ITEM_FACT_LOAD_PROC'
  AND query_type = 'MERGE';


-- J3. The example check in the raw tables: when its own row, its payment and its lines each landed.
--     FIRST_LANDED of the lines earlier than FIRST_LANDED of the check header is what the suspect predicts.
--     LAST_TOUCHED and REPLAY_COUNTER on the lines should show the 11/06 replay.
SELECT '1 check header'                                  AS piece,
       PROPERTY_CODE,
       COUNT(*)                                          AS row_count,
       MIN(CREATED_DATE)                                 AS first_landed,
       MAX(CREATED_DATE)                                 AS last_landed,
       MAX(UPDATED_DATE)                                 AS last_touched,
       MAX(REPLAY_COUNTER)                               AS replay_counter,
       MIN(OPERATION_DATE)                               AS first_source_change,
       MAX(OPERATION_DATE)                               AS last_source_change,
       LISTAGG(DISTINCT OPERATION_TYPE::VARCHAR, ',')    AS operation_types,
       LISTAGG(DISTINCT DQ_CHECK_PASSED_FLAG, ',')       AS dq_flags,
       LISTAGG(DISTINCT UPDATED_BY, ',')                 AS touched_by
FROM DAAS_PROD.DAAS_RAW_INFOGEN_ONPREM.CHECK_SALES_DETAIL_RAW
WHERE TRANSACTION_DATA_ID = 170818751
GROUP BY PROPERTY_CODE
UNION ALL
SELECT '2 payments',
       PROPERTY_CODE,
       COUNT(*),
       MIN(CREATED_DATE),
       MAX(CREATED_DATE),
       MAX(UPDATED_DATE),
       MAX(REPLAY_COUNTER),
       MIN(OPERATION_DATE),
       MAX(OPERATION_DATE),
       LISTAGG(DISTINCT OPERATION_TYPE::VARCHAR, ','),
       LISTAGG(DISTINCT DQ_CHECK_PASSED_FLAG, ','),
       LISTAGG(DISTINCT UPDATED_BY, ',')
FROM DAAS_PROD.DAAS_RAW_INFOGEN_ONPREM.CHECK_TENDER_DETAIL_RAW
WHERE TRANSACTION_DATA_ID = 170818751
GROUP BY PROPERTY_CODE
UNION ALL
SELECT '3 lines',
       PROPERTY_CODE,
       COUNT(*),
       MIN(CREATED_DATE),
       MAX(CREATED_DATE),
       MAX(UPDATED_DATE),
       MAX(REPLAY_COUNTER),
       MIN(OPERATION_DATE),
       MAX(OPERATION_DATE),
       LISTAGG(DISTINCT OPERATION_TYPE::VARCHAR, ','),
       LISTAGG(DISTINCT DQ_CHECK_PASSED_FLAG, ','),
       LISTAGG(DISTINCT UPDATED_BY, ',')
FROM DAAS_PROD.DAAS_RAW_INFOGEN_ONPREM.CHECK_ITEM_DETAIL_RAW
WHERE TRANSACTION_DATA_ID = 170818751
GROUP BY PROPERTY_CODE
ORDER BY 2, 1;


-- J4. The item load's runs on the evening the check closed (2026-10-28, 8 pm to 11 pm Pacific) and how many
--     lines each one inserted. Set beside J3, this shows which run was the one that picked up the lines.
SELECT start_time,
       query_tag,
       rows_inserted,
       rows_updated,
       ROUND(total_elapsed_time / 1000) AS seconds
FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
WHERE start_time >= '2026-10-28 20:00:00'
  AND start_time <  '2026-10-28 23:00:00'
  AND query_tag ILIKE '%INFOGEN_ONPREM_CHECK_ITEM_FACT_LOAD_PROC'
  AND query_type = 'MERGE'
ORDER BY start_time;


-- J5. The four days on which late lines arrived in bulk (10/19, 11/06, 11/11, 11/17): the oversized loads
--     into CHECK_ITEM_FACT and any replay statements, with who ran them.
SELECT start_time,
       user_name,
       role_name,
       query_type,
       rows_inserted,
       rows_updated,
       query_tag,
       LEFT(REGEXP_REPLACE(query_text, '\\s+', ' '), 200)        AS statement_start
FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
WHERE (   (start_time >= '2026-10-19' AND start_time < '2026-10-20')
       OR (start_time >= '2026-11-06' AND start_time < '2026-11-07')
       OR (start_time >= '2026-11-11' AND start_time < '2026-11-12')
       OR (start_time >= '2026-11-17' AND start_time < '2026-11-18'))
  AND query_type <> 'SELECT'
  AND (   (query_type = 'MERGE' AND rows_inserted >= 50000 AND query_text ILIKE '%"DAAS_CORE"."CHECK_ITEM_FACT"%')
       OR (query_text ILIKE '%REPLAY%' AND query_text ILIKE '%CHECK_ITEM%'))
ORDER BY start_time;


-- =====================================================================================================
-- PART K. The day-by-day picture
-- =====================================================================================================

-- K1. This is H1 again, over a longer stretch. Last time the query text came back in place of its results.
--     Live checks loaded from 2026-09-15 to today, by the day the check was loaded: how soon its first line
--     followed. The two LATE columns show when the skipping started and whether it has let up.
--     SALES_BUT_NO_LINES_YET on the last few days is the backlog waiting for the next catch-up.
WITH checks AS (
    SELECT CHECK_ATTRIBUTE_ID,
           PROPERTY_CD,
           MIN(CREATED_DTTM)            AS check_loaded,
           MAX(ABS(SALES_GROSS_AMT))    AS net_sales
    FROM DAAS_PROD.DAAS_CORE.CHECK_SALES_FACT
    WHERE CREATED_DTTM >= '2026-09-15'
      AND CREATED_DTTM <  '2026-11-18'
      AND DELETE_IND = 'N'
    GROUP BY 1, 2
),
lines AS (
    SELECT CHECK_ATTRIBUTE_ID,
           PROPERTY_CD,
           MIN(CREATED_DTTM)            AS lines_loaded
    FROM DAAS_PROD.DAAS_CORE.CHECK_ITEM_FACT
    WHERE CREATED_DTTM >= '2026-09-08'
    GROUP BY 1, 2
)
SELECT c.check_loaded::DATE                                                                AS check_load_day,
       COUNT(*)                                                                            AS checks,
       COUNT_IF(DATEDIFF('minute', c.check_loaded, l.lines_loaded) <= 60)                  AS lines_within_1_hour,
       COUNT_IF(DATEDIFF('minute', c.check_loaded, l.lines_loaded) BETWEEN 61 AND 1440)    AS lines_within_1_day,
       COUNT_IF(DATEDIFF('minute', c.check_loaded, l.lines_loaded) BETWEEN 1441 AND 4320)  AS late_1_to_3_days,
       COUNT_IF(DATEDIFF('minute', c.check_loaded, l.lines_loaded) > 4320)                 AS late_over_3_days,
       COUNT_IF(l.lines_loaded IS NULL AND c.net_sales > 0)                                AS sales_but_no_lines_yet,
       COUNT_IF(l.lines_loaded IS NULL AND COALESCE(c.net_sales, 0) = 0)                   AS no_sales_no_lines,
       MAX(DATEDIFF('day', c.check_loaded, l.lines_loaded))                                AS worst_delay_days
FROM checks c
LEFT JOIN lines l
       ON l.CHECK_ATTRIBUTE_ID = c.CHECK_ATTRIBUTE_ID
      AND l.PROPERTY_CD = c.PROPERTY_CD
GROUP BY 1
ORDER BY 1;
